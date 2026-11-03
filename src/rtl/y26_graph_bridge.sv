`timescale 1ns/1ps
// B16 -> conv3/conv4 -> residual -> [A16,B16,R16], in eight-row stripes.
// The prefix ring has sixteen rows. All arithmetic shares the external PE/tail.
module y26_graph_bridge #(parameter EXTERNAL_MEMORY=0)(
    input wire clk,resetn,clear_counters,
    input wire cfg_we,input wire [11:0] cfg_addr,input wire [31:0] cfg_data,
    input wire prefix_we,input wire [4:0] prefix_channel,input wire [6:0] prefix_row,
    input wire [4:0] prefix_word,input wire [31:0] prefix_data,
    input wire start,input wire [3:0] stripe,
    output wire busy,output reg done,output reg error,
    output wire [185:0] core_command,input wire [802:0] core_response,
    output wire [137:0] tail_command,input wire [10:0] tail_response,
    output reg [31:0] cat_data,output wire cat_valid,cat_last,input wire cat_ready,
    output reg [31:0] cycles3,cycles4,feed_cycles,fusion_cycles,cat_cycles,
    output wire [521:0] feature_command,input wire [287:0] feature_response
);
    localparam IDLE=0,WR=1,WS=2,PR=3,PS=4,D0=5,D1=6,START=7,WAIT=8,FUSE=9,
        CR=10,CP=11,CS=12,CQ=13,SEND=14;
    reg [3:0] state;reg stage;reg [1:0] block;reg [2:0] ib;reg [3:0] stripe_q;
    reg [7:0] wi;reg [3:0] wo,wt;reg [47:0] weight_q;
    reg [6:0] px;reg [2:0] py;reg [9:0] patch_index;reg pad_q;
    reg [3:0] oc,read_oc,save_oc;reg [8:0] pixel,save_pixel;reg read_done,read_valid,read_last;
    reg [31:0] pack_word;reg [1:0] lane;
    reg [5:0] cat_channel;reg [2:0] cat_row;reg [4:0] cat_word;
    reg [31:0] ma,mb,low_word;reg [31:0] multiplier[0:23];reg [4:0] shift[0:23];reg [47:0] bias[0:23];
    (* ram_style="block" *) reg [47:0] weights[0:1295];
    wire [31:0] pq[0:2],c3q[0:2],c4q[0:2];
    wire [2:0] height=stage?3'd4:block==2?3'd2:3'd4;
    wire [8:0] pixels=height*9'd80;
    wire signed [10:0] source_y=$signed({4'd0,stripe_q,3'd0})-11'sd2+$signed({7'd0,block,2'd0})+$signed({8'd0,py});
    wire signed [10:0] result_y=$signed({4'd0,stripe_q,3'd0})-11'sd1+$signed({7'd0,block,2'd0})+$signed({2'd0,save_pixel/9'd80});
    wire pad=px==0||px==81||(!stage&&(source_y<0||source_y>=80));
    wire [6:0] sx=px-1;
    wire [4:0] input_channel=5'd16+ib*5'd3;
    wire [6:0] cat_prefix_channel=cat_channel<16?{1'b0,cat_channel}:7'd16+{3'd0,cat_channel[3:0]};
    wire [3:0] cat_c=cat_channel[3:0];
    wire [11:0] prefix_read=state==CR?(cat_prefix_channel/3)*12'd320+({8'd0,stripe_q[0],3'd0}+cat_row)*12'd20+cat_word:
        (input_channel/3)*12'd320+{8'd0,source_y[3:0]}*12'd20+{7'd0,sx[6:2]};
    wire [11:0] prefix_write=(prefix_channel/3)*12'd320+{8'd0,prefix_row[3:0]}*12'd20+prefix_word;
    wire [9:0] c3_read=ib*10'd200+({6'd0,block,2'd0}+py)*10'd20+{5'd0,sx[6:2]};
    wire [9:0] c3_write=(save_oc/3)*10'd200+({6'd0,block,2'd0}+save_pixel/80)*10'd20+(save_pixel%80)/4;
    wire [9:0] c4_write=(save_oc/3)*10'd160+({6'd0,block,2'd0}+save_pixel/80)*10'd20+(save_pixel%80)/4;
    wire [9:0] c4_read=(cat_c/3)*10'd160+cat_row*10'd20+cat_word;
    wire [7:0] a0=stage?c3q[0][sx[1:0]*8+:8]:pq[input_channel%3][sx[1:0]*8+:8];
    wire [7:0] a1=stage?c3q[1][sx[1:0]*8+:8]:pq[(input_channel+1)%3][sx[1:0]*8+:8];
    wire [7:0] a2=stage?c3q[2][sx[1:0]*8+:8]:pq[(input_channel+2)%3][sx[1:0]*8+:8];
    // Prefix IC groups can cross a modulo-three bank group (B starts at 16).
    // Each bank therefore reads the address for its actual requested channel.
    wire [47:0] triplet={{8{a2[7]}},a2,{8{a1[7]}},a1,{8{a0[7]}},a0};
    wire [10:0] weight_address=(stage?11'd864:11'd0)+ib*11'd144+wi;
    wire cb,cd,ce;wire [31:0] cc;wire [767:0] data;
    wire qr,qv,ql;wire [7:0] q;
    wire [4:0] co=stage?5'd16:5'd8;
    wire [4:0] channel_index=(stage?5'd8:5'd0)+read_oc;
    wire issue=state==FUSE&&!read_done&&qr;
    assign core_command={resetn,state==START,2'd3,2'd1,ib==(stage?2:5)?(stage?2'd2:2'd1):2'd3,co,8'd80,height,ib==0,
        32'h67000000|({28'd0,stripe_q}<<8)|({31'd0,stage}<<4)|{30'd0,block},
        state==PS,{2'd0,patch_index},pad_q?48'd0:triplet,state==WS,wo,wt,weight_q,issue,{1'b0,pixel}};
    assign {cb,cd,ce,cc,data}=core_response;
    assign tail_command={resetn,state==FUSE&&read_valid,1'b1,data[read_oc*48+:48],bias[channel_index],multiplier[channel_index],shift[channel_index],1'b1,read_last};
    assign {qr,qv,ql,q}=tail_response;
    wire [7:0] stored_q=!stage&&(result_y<0||result_y>=80)?8'd0:q;
    generate for(genvar bank=0;bank<3;bank=bank+1)begin: banks
        wire [5:0] channel_for_bank=input_channel+((bank+3-input_channel%3)%3);
        wire [11:0] paddr=state==CR?prefix_read:(channel_for_bank/3)*12'd320+{8'd0,source_y[3:0]}*12'd20+{7'd0,sx[6:2]};
        wire pwe=prefix_we&&prefix_channel%3==bank;
        wire pre=state==CR||(state==PR&&!stage&&!pad);
        wire w3=state==FUSE&&qv&&lane==3&&save_oc%3==bank&&!stage;
        wire w4=state==FUSE&&qv&&lane==3&&save_oc%3==bank&&stage;
        assign feature_command[bank*58+:58]={pwe,prefix_write,prefix_data,pre,paddr};
        assign feature_command[(bank+3)*58+:58]={w3,2'd0,c3_write,{stored_q,pack_word[23:0]},state==PR&&stage&&!pad,2'd0,c3_read};
        assign feature_command[(bank+6)*58+:58]={w4,2'd0,c4_write,{stored_q,pack_word[23:0]},state==CR,2'd0,c4_read};
        if(EXTERNAL_MEMORY)begin: shared_storage
            assign pq[bank]=feature_response[bank*32+:32];assign c3q[bank]=feature_response[(bank+3)*32+:32];assign c4q[bank]=feature_response[(bank+6)*32+:32];
        end else begin: private_storage
            (* ram_style="block" *) reg [31:0] prefix_mem[0:3519];reg [31:0] pr;
            (* ram_style="block" *) reg [31:0] conv3_mem[0:599];reg [31:0] r3;
            (* ram_style="block" *) reg [31:0] conv4_mem[0:959];reg [31:0] r4;
            always @(posedge clk)begin
                if(pwe)prefix_mem[prefix_write]<=prefix_data;
                if(pre)pr<=prefix_mem[paddr];
                if(state==PR&&stage&&!pad)r3<=conv3_mem[c3_read];
                if(state==CR)r4<=conv4_mem[c4_read];
                if(w3)conv3_mem[c3_write]<={stored_q,pack_word[23:0]};
                if(w4)conv4_mem[c4_write]<={stored_q,pack_word[23:0]};
            end
            assign pq[bank]=pr;assign c3q[bank]=r3;assign c4q[bank]=r4;
        end
    end endgenerate
    always @(posedge clk)begin
        if(cfg_we)begin
            if(cfg_addr==2)ma<=cfg_data;
            if(cfg_addr==3)mb<=cfg_data;
            if(cfg_addr>=8&&cfg_addr<104)begin
                case(cfg_addr[1:0])
                    0:multiplier[(cfg_addr-8)>>2]<=cfg_data;
                    1:shift[(cfg_addr-8)>>2]<=cfg_data[4:0];
                    2:bias[(cfg_addr-8)>>2][31:0]<=cfg_data;
                    3:bias[(cfg_addr-8)>>2][47:32]<=cfg_data[15:0];
                endcase
            end
            if(cfg_addr>=104)begin if(!cfg_addr[0])low_word<=cfg_data;else weights[(cfg_addr-104)>>1]<={cfg_data[15:0],low_word};end
        end
        if(state==WR)weight_q<=weights[weight_address];
    end
    reg signed [40:0] pa[0:3],pb[0:3];reg signed [47:0] sums[0:3];
    function [7:0] rounded;
        input signed [47:0] v;reg [47:0] mag,base;begin
            mag=v<0?-v:v;base=mag>>24;
            if(mag[23:0]>24'h800000||(mag[23:0]==24'h800000&&base[0]))base=base+1;
            if(v<0)rounded=base>=128?8'h80:-base[7:0];else rounded=base>127?8'd127:base[7:0];
        end
    endfunction
    assign busy=state!=IDLE;assign cat_valid=state==SEND;
    assign cat_last=cat_channel==47&&cat_row==7&&cat_word==19;
    integer i;
    always @(posedge clk)begin
        if(!resetn)begin
            state<=IDLE;stage<=0;block<=0;ib<=0;stripe_q<=0;wi<=0;wo<=0;wt<=0;px<=0;py<=0;patch_index<=0;pad_q<=0;
            oc<=0;pixel<=0;read_done<=0;read_valid<=0;read_last<=0;read_oc<=0;save_oc<=0;save_pixel<=0;pack_word<=0;lane<=0;
            cat_channel<=0;cat_row<=0;cat_word<=0;cat_data<=0;done<=0;error<=0;
            cycles3<=0;cycles4<=0;feed_cycles<=0;fusion_cycles<=0;cat_cycles<=0;
        end else begin
            done<=0;
            if(clear_counters)begin cycles3<=0;cycles4<=0;feed_cycles<=0;fusion_cycles<=0;cat_cycles<=0;error<=0;end
            if(state==WR||state==WS||state==PR||state==PS||state==D0||state==D1)feed_cycles<=feed_cycles+1;
            if(state==FUSE)fusion_cycles<=fusion_cycles+1;
            if(state>=CR&&state<=SEND)cat_cycles<=cat_cycles+1;
            case(state)
                IDLE:if(start)begin stripe_q<=stripe;stage<=0;block<=0;ib<=0;wi<=0;wo<=0;wt<=0;state<=WR;end
                WR:state<=WS;
                WS:begin
                    if(wt==8)begin wt<=0;wo<=wo+1;end else wt<=wt+1;
                    if(wi==143)begin px<=0;py<=0;patch_index<=0;state<=PR;end else begin wi<=wi+1;state<=WR;end
                end
                PR:begin pad_q<=pad;state<=PS;end
                PS:begin
                    if(px==81)begin px<=0;py<=py+1;end else px<=px+1;
                    if(patch_index==(height+2)*82-1)state<=D0;else begin patch_index<=patch_index+1;state<=PR;end
                end
                D0:state<=D1;
                D1:state<=START;
                START:state<=WAIT;
                WAIT:if(cd)begin
                    if(ce)begin error<=1;state<=IDLE;end
                    else begin
                        if(stage)cycles4<=cycles4+cc;else cycles3<=cycles3+cc;
                        if(ib!=(stage?2:5))begin ib<=ib+1;wi<=0;wo<=0;wt<=0;state<=WR;end
                        else begin oc<=0;pixel<=0;read_done<=0;read_valid<=0;read_last<=0;save_oc<=0;save_pixel<=0;pack_word<=0;lane<=0;state<=FUSE;end
                    end
                end
                FUSE:begin
                    if(qr)begin
                        read_valid<=!read_done;
                        if(!read_done)begin
                            read_oc<=oc;read_last<=oc==co-1&&pixel==pixels-1;
                            if(pixel==pixels-1)begin pixel<=0;if(oc==co-1)read_done<=1;else oc<=oc+1;end else pixel<=pixel+1;
                        end
                    end
                    if(qv)begin
                        case(lane)0:pack_word<={24'd0,stored_q};1:pack_word[15:8]<=stored_q;2:pack_word[23:16]<=stored_q;3:pack_word[31:24]<=stored_q;endcase
                        lane<=lane+1;
                        if(save_pixel==pixels-1)begin save_pixel<=0;save_oc<=save_oc+1;end else save_pixel<=save_pixel+1;
                        if(ql)begin
                            read_valid<=0;ib<=0;wi<=0;wo<=0;wt<=0;
                            if(block==(stage?1:2))begin
                                block<=0;
                                if(stage)begin done<=1;cat_channel<=0;cat_row<=0;cat_word<=0;state<=CR;end
                                else begin stage<=1;state<=WR;end
                            end else begin block<=block+1;state<=WR;end
                        end
                    end
                end
                CR:state<=CP;
                CP:begin
                    for(i=0;i<4;i=i+1)begin
                        pa[i]<=$signed(pq[cat_prefix_channel%3][i*8+:8])*$signed({1'b0,ma});
                        pb[i]<=cat_channel>=32?$signed(c4q[cat_c%3][i*8+:8])*$signed({1'b0,mb}):41'sd0;
                    end
                    state<=CS;
                end
                CS:begin for(i=0;i<4;i=i+1)sums[i]<=pa[i]+pb[i];state<=CQ;end
                CQ:begin for(i=0;i<4;i=i+1)cat_data[i*8+:8]<=rounded(sums[i]);state<=SEND;end
                SEND:if(cat_ready)begin
                    if(cat_word==19)begin
                        cat_word<=0;
                        if(cat_row==7)begin cat_row<=0;if(cat_channel==47)state<=IDLE;else begin cat_channel<=cat_channel+1;state<=CR;end end
                        else begin cat_row<=cat_row+1;state<=CR;end
                    end else begin cat_word<=cat_word+1;state<=CR;end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
