`timescale 1ns/1ps
// Independent blob12 -> convrelu_5 -> convrelu_6 -> blob14.
// One shared PE. PS submits ten [48,8,80] INT8 stripes in one DMA frame.
// No im2col on PS and no intermediate DDR round trip. 3-bank memories read 3 IC.
module y26_axis_hotspot56 #(parameter PIPELINE_FEED=1, parameter EXTERNAL_COMPUTE=0, parameter STRIPE_PAUSE=0, parameter EXTERNAL_MEMORY=0)(
    input wire aclk,aresetn,
    input wire [31:0] s_axis_tdata,input wire [3:0] s_axis_tkeep,
    input wire s_axis_tlast,s_axis_tvalid,output wire s_axis_tready,
    output reg [31:0] m_axis_tdata,output wire [3:0] m_axis_tkeep,
    output reg m_axis_tlast,output wire m_axis_tvalid,input wire m_axis_tready,
    output wire config_busy,
    output wire [185:0] compute_core_command,
    output wire [137:0] compute_tail_command,
    input wire [802:0] external_core_response,
    input wire [10:0] external_tail_response,
    input wire stripe_resume,output wire stripe_waiting,
    output wire [347:0] feature_command,input wire [191:0] feature_response,
    output wire [77:0] weight_command,input wire [47:0] weight_response
);
    localparam HEAD=0,CHECK=1,LOAD=2,DROP=3,ACK=4,OUT_HEAD=5,FILL=6,
        WREAD=7,WSEND=8,PREAD=9,PSEND=10,DRAIN0=11,DRAIN1=12,START=13,
        WAIT_CORE=14,FUSE=15,NEXT=16,FOOT=17,PAD=18,RAW_DROP=19,ABORT=20,
        BULK_HEAD=21,BULK_DATA=22,BULK_PAD=23,BULK_DROP=24,BULK_FOOT=25;
    reg [4:0] state;
    assign stripe_waiting=state==NEXT;
    reg [31:0] header[0:7];reg [2:0] hi,reply_hi;
    reg header_last,bad_header,loaded,active;
    reg [31:0] status,body_index,low_word,job_cycles,cycles5,cycles6;
    reg [31:0] feed_cycles,fusion_cycles,fill_cycles,stall_cycles,input_words,output_words;
    reg [3:0] footer_index;
    (* ram_style="block" *) reg [47:0] weight_mem[0:13695];
    reg [31:0] multiplier[0:127];reg [4:0] shift[0:127];reg [47:0] bias[0:127];
    reg stage,half;reg [1:0] oc_block;reg [4:0] ic_block;reg [3:0] stripe,base_slot;
    reg [7:0] wi;reg [3:0] weight_oc,weight_tap;wire [47:0] weight_q;reg [47:0] private_weight_q;
    reg [6:0] px;reg [3:0] py,read_slot;reg [11:0] patch_index;reg pad_q;
    reg [7:0] fill_word;reg [1:0] fill_bank;reg [3:0] fill_group;reg [5:0] fill_channel;
    reg fill_error,fill_ended;
    reg [3:0] oc,read_oc,save_channel;reg [9:0] pixel;reg [6:0] save_word;
    reg read_done,read_valid,read_last;
    reg [31:0] packed_data;reg [1:0] packed_lane;reg packed_valid,packed_last;
    reg feed_valid,feed_read_done;
    reg [11:0] feed_patch_addr;
    reg [3:0] feed_weight_oc,feed_weight_tap;
    reg [1:0] feed_lane;
    wire in_fire=s_axis_tvalid&&s_axis_tready,out_fire=m_axis_tvalid&&m_axis_tready;
    wire [31:0] iq[0:2],rq[0:2];
    wire [6:0] sx=px-7'd1;
    wire is_pad=stage&&(px==0||(stripe==0&&py==0));
    wire [11:0] input_address=ic_block*12'd160+(half?12'd80:12'd0)+py*12'd20+{7'd0,px[6:2]};
    wire [11:0] ring_address=ic_block*12'd180+read_slot*12'd20+{7'd0,sx[6:2]};
    wire [1:0] lane_index=PIPELINE_FEED?feed_lane:stage?sx[1:0]:px[1:0];
    wire [7:0] a0=stage?rq[0][lane_index*8+:8]:iq[0][lane_index*8+:8];
    wire [7:0] a1=stage?rq[1][lane_index*8+:8]:iq[1][lane_index*8+:8];
    wire [7:0] a2=stage?rq[2][lane_index*8+:8]:iq[2][lane_index*8+:8];
    wire [47:0] triplet={{8{a2[7]}},a2,{8{a1[7]}},a1,{8{a0[7]}},a0};
    wire [13:0] weight_address=stage?14'd1024+(oc_block*14'd22+ic_block)*14'd144+wi:
        (oc_block*14'd16+ic_block)*14'd16+{10'd0,wi[3:0]};
    wire [6:0] channel_index=(stage?7'd64:7'd0)+{1'b0,oc_block,4'd0}+read_oc;
    wire [5:0] save_global={oc_block,4'd0}+save_channel;
    wire [4:0] write_slot_sum={1'b0,base_slot}+5'd1+(half?5'd4:5'd0)+save_word/20;
    wire [3:0] write_slot=write_slot_sum>=9?write_slot_sum-9:write_slot_sum;
    wire [11:0] ring_write_address=(save_global/3)*12'd180+write_slot*12'd20+save_word%20;
    wire [31:0] core_tag=32'h56000000|({28'd0,stripe}<<5)|({31'd0,stage}<<4)|({31'd0,half}<<2)|{30'd0,oc_block};
    wire core_busy,core_done,core_error;wire [31:0] core_cycles;wire [767:0] core_data;
    wire qr,qv,ql,qo;wire [7:0] q;
    wire issue=state==FUSE&&!read_done&&qr;
    // Internal compute link: reset/start/config/write/read request, then response.
    // EXTERNAL_COMPUTE removes this controller's PE/tail from the unified netlist.
    wire [802:0] local_core_response;wire [10:0] local_tail_response;
    assign compute_core_command={aresetn&&state!=ABORT,state==START,stage?2'd3:2'd1,stage?2'd2:2'd1,stage&&ic_block==21?2'd1:2'd3,5'd16,stage?8'd40:8'd80,3'd4,ic_block==0,core_tag,PIPELINE_FEED?(state==PREAD&&feed_valid):state==PSEND,PIPELINE_FEED?feed_patch_addr:patch_index,pad_q?48'd0:triplet,PIPELINE_FEED?(state==WREAD&&feed_valid):state==WSEND,PIPELINE_FEED?feed_weight_oc:weight_oc,PIPELINE_FEED?feed_weight_tap:weight_tap,weight_q,issue,pixel};
    assign compute_tail_command={aresetn&&state!=ABORT,state==FUSE&&read_valid,qo,core_data[read_oc*48+:48],bias[channel_index],multiplier[channel_index],shift[channel_index],1'b1,read_last};
    assign {core_busy,core_done,core_error,core_cycles,core_data}=EXTERNAL_COMPUTE?external_core_response:local_core_response;
    assign {qr,qv,ql,q}=EXTERNAL_COMPUTE?external_tail_response:local_tail_response;
    generate if(!EXTERNAL_COMPUTE)begin: local_compute
        y26_compute_unit unit(.clk(aclk),.core_command(compute_core_command),.core_response(local_core_response),
            .tail_command(compute_tail_command),.tail_response(local_tail_response));
    end else begin: external_compute
        assign local_core_response=0;assign local_tail_response=0;
    end endgenerate

    assign qo=state==FUSE&&(!stage||!packed_valid||m_axis_tready);

    generate for(genvar b=0;b<3;b=b+1)begin: feature_banks
        wire iwe=state==FILL&&in_fire&&fill_bank==b;
        wire ire=state==PREAD&&!stage&&(!PIPELINE_FEED||!feed_read_done);
        wire rwe=state==FUSE&&!stage&&qv&&qo&&packed_lane==3&&save_global%3==b;
        wire rre=state==PREAD&&stage&&!is_pad&&(!PIPELINE_FEED||!feed_read_done);
        assign feature_command[b*58+:58]={iwe,fill_group*12'd160+{4'd0,fill_word},s_axis_tdata,ire,input_address};
        assign feature_command[(b+3)*58+:58]={rwe,ring_write_address,{q,packed_data[23:0]},rre,ring_address};
        if(EXTERNAL_MEMORY)begin: shared_storage
            assign iq[b]=feature_response[b*32+:32];assign rq[b]=feature_response[(b+3)*32+:32];
        end else begin: private_storage
            (* ram_style="block" *) reg [31:0] input_store[0:2559];reg [31:0] ir;
            (* ram_style="block" *) reg [31:0] ring_store[0:3959];reg [31:0] rr;
            assign iq[b]=ir;assign rq[b]=rr;
            always @(posedge aclk)begin
                if(iwe)input_store[fill_group*12'd160+fill_word]<=s_axis_tdata;
                if(ire)ir<=input_store[input_address];
                if(rwe)ring_store[ring_write_address]<={q,packed_data[23:0]};
                if(rre)rr<=ring_store[ring_address];
            end
        end
    end endgenerate
    wire wwe=state==LOAD&&in_fire&&body_index>=512&&body_index<27904&&body_index[0];
    wire wre=state==WREAD&&(!PIPELINE_FEED||!feed_read_done);
    assign weight_command={wwe,14'((body_index-512)>>1),s_axis_tdata[15:0],low_word,wre,weight_address};
    assign weight_q=EXTERNAL_MEMORY?weight_response:private_weight_q;
    always @(posedge aclk)begin
        if(!EXTERNAL_MEMORY&&wwe)weight_mem[(body_index-512)>>1]<={s_axis_tdata[15:0],low_word};
        if(!EXTERNAL_MEMORY&&wre)private_weight_q<=weight_mem[weight_address];
    end
    // Read and write independent synchronous memories concurrently. The metadata
    // follows the BRAM response; the final response drains before core start.
    always @(posedge aclk)begin
        if(!aresetn)begin feed_valid<=0;feed_read_done<=0;feed_patch_addr<=0;feed_weight_oc<=0;feed_weight_tap<=0;feed_lane<=0;end
        else if(PIPELINE_FEED&&(state==WREAD||state==PREAD))begin
            feed_valid<=!feed_read_done;
            if(!feed_read_done)begin
                if(state==WREAD)begin
                    feed_weight_oc<=weight_oc;feed_weight_tap<=weight_tap;
                    if(wi==(stage?143:15))feed_read_done<=1;
                end else begin
                    feed_patch_addr<=patch_index;feed_lane<=stage?sx[1:0]:px[1:0];
                    if(patch_index==(stage?728:319))feed_read_done<=1;
                end
            end else feed_read_done<=0;
        end else begin feed_valid<=0;feed_read_done<=0;end
    end
    assign config_busy=state!=HEAD||hi!=0||s_axis_tvalid;
    assign s_axis_tready=aresetn&&(state==HEAD||state==LOAD||state==DROP||state==RAW_DROP||state==BULK_DROP||state==FILL||(state==BULK_DATA&&m_axis_tready));
    assign m_axis_tkeep=15;
    assign m_axis_tvalid=aresetn&&(state==ACK||state==OUT_HEAD||state==FOOT||state==PAD||state==BULK_HEAD||state==BULK_PAD||state==BULK_FOOT||
        (state==FUSE&&stage&&packed_valid)||(state==BULK_DATA&&s_axis_tvalid));
    always @*begin
        m_axis_tdata=0;m_axis_tlast=0;
        if(state==ACK||state==OUT_HEAD||state==BULK_HEAD)begin
            case(reply_hi)
                0:m_axis_tdata=32'h59323652;1:m_axis_tdata=header[1];2:m_axis_tdata=header[2];3:m_axis_tdata=status;
                4:m_axis_tdata=state==OUT_HEAD?32'h280028:0;
                5:m_axis_tdata=state==OUT_HEAD?32'd64:0;
                6:m_axis_tdata=state==OUT_HEAD?32'd25610:state==BULK_HEAD?header[6]+1:0;
                default:m_axis_tdata=0;
            endcase
            m_axis_tlast=state==ACK&&reply_hi==7;
        end else if(state==FUSE)m_axis_tdata=packed_data;
        else if(state==FOOT)begin
            case(footer_index)
                0:m_axis_tdata=status;1:m_axis_tdata=job_cycles;2:m_axis_tdata=cycles5;3:m_axis_tdata=cycles6;
                4:m_axis_tdata=feed_cycles;5:m_axis_tdata=fusion_cycles;6:m_axis_tdata=fill_cycles;
                7:m_axis_tdata=stall_cycles;8:m_axis_tdata=input_words;9:m_axis_tdata=output_words;
            endcase
            m_axis_tlast=footer_index==9;
        end else if(state==BULK_DATA)m_axis_tdata=s_axis_tdata;
        else if(state==BULK_FOOT)begin m_axis_tdata=status;m_axis_tlast=1;end
    end
    always @(posedge aclk)begin
        if(!aresetn)begin
            state<=HEAD;hi<=0;reply_hi<=0;header_last<=0;bad_header<=0;loaded<=0;active<=0;status<=0;
            body_index<=0;low_word<=0;job_cycles<=0;cycles5<=0;cycles6<=0;feed_cycles<=0;fusion_cycles<=0;fill_cycles<=0;stall_cycles<=0;
            input_words<=0;output_words<=0;footer_index<=0;stage<=0;half<=0;oc_block<=0;ic_block<=0;stripe<=0;base_slot<=8;
            wi<=0;weight_oc<=0;weight_tap<=0;px<=0;py<=0;read_slot<=8;patch_index<=0;pad_q<=0;
            fill_word<=0;fill_bank<=0;fill_group<=0;fill_channel<=0;fill_error<=0;fill_ended<=0;
            oc<=0;read_oc<=0;save_channel<=0;pixel<=0;save_word<=0;read_done<=0;read_valid<=0;read_last<=0;
            packed_data<=0;packed_lane<=0;packed_valid<=0;packed_last<=0;
        end else begin
            if(active)job_cycles<=job_cycles+1;
            if(active&&(state==WREAD||state==WSEND||state==PREAD||state==PSEND||state==DRAIN0||state==DRAIN1))feed_cycles<=feed_cycles+1;
            if(active&&state==FUSE)fusion_cycles<=fusion_cycles+1;
            if(active&&state==FILL)fill_cycles<=fill_cycles+1;
            if(active&&m_axis_tvalid&&!m_axis_tready)stall_cycles<=stall_cycles+1;
            case(state)
                HEAD:if(in_fire)begin
                    header[hi]<=s_axis_tdata;
                    if(hi==0)bad_header<=s_axis_tkeep!=15;else if(s_axis_tkeep!=15)bad_header<=1;
                    if(s_axis_tlast&&hi!=7)begin status<=2;loaded<=0;reply_hi<=0;hi<=0;state<=ACK;end
                    else if(hi==7)begin hi<=0;header_last<=s_axis_tlast;state<=CHECK;end else hi<=hi+1;
                end
                CHECK:begin
                    status<=0;reply_hi<=0;body_index<=0;
                    if(bad_header||header[0]!=32'h59323643||header[1][31:16]!=1)begin status<=1;loaded<=0;state<=header_last?ACK:DROP;end
                    else if(header[1]==32'h10020&&header[3]==0&&header[4]==0&&header[5]==0&&header[6]==27904&&header[7]==8&&!header_last)begin loaded<=0;state<=LOAD;end
                    else if(header[1]==32'h10021&&loaded&&header[3]==0&&header[4]==32'h500050&&header[5]==48&&header[6]==76800&&header[7]==25618&&!header_last)begin
                        stripe<=0;base_slot<=8;input_words<=0;output_words<=0;
                        job_cycles<=0;cycles5<=0;cycles6<=0;feed_cycles<=0;fusion_cycles<=0;fill_cycles<=0;stall_cycles<=0;
                        fill_word<=0;fill_channel<=0;fill_bank<=0;fill_group<=0;fill_error<=0;fill_ended<=0;
                        active<=1;state<=OUT_HEAD;
                    end else if(header[1]==32'h10012&&header[3]==0&&header[4]==0&&header[5]==0&&header[6]>0&&header[6]<=131063&&header[7]==header[6]+9&&!header_last)state<=BULK_HEAD;
                    else begin status<=1;loaded<=0;state<=header_last?ACK:DROP;end
                end
                LOAD:if(in_fire)begin
                    if(s_axis_tkeep!=15)status<=2;
                    if(body_index<512)begin
                        case(body_index[1:0])
                            0:multiplier[body_index[8:2]]<=s_axis_tdata;
                            1:begin shift[body_index[8:2]]<=s_axis_tdata[4:0];if(s_axis_tdata>31)status<=2;end
                            2:bias[body_index[8:2]][31:0]<=s_axis_tdata;
                            3:begin bias[body_index[8:2]][47:32]<=s_axis_tdata[15:0];if(s_axis_tdata[31:16]!=0)status<=2;end
                        endcase
                    end else if(!body_index[0])low_word<=s_axis_tdata;
                    else if(s_axis_tdata[31:16]!=0)status<=2;
                    if(s_axis_tlast)begin
                        if(body_index!=27903||status!=0||s_axis_tkeep!=15||s_axis_tdata[31:16]!=0)begin status<=2;loaded<=0;end else loaded<=1;
                        state<=ACK;
                    end else if(body_index>=27903)begin status<=2;state<=DROP;end else body_index<=body_index+1;
                end
                DROP:if(in_fire&&s_axis_tlast)begin loaded<=0;reply_hi<=0;state<=ACK;end
                ACK:if(out_fire)begin if(reply_hi==7)state<=HEAD;else reply_hi<=reply_hi+1;end
                OUT_HEAD:if(out_fire)begin if(reply_hi==7)state<=FILL;else reply_hi<=reply_hi+1;end
                FILL:if(in_fire)begin
                    input_words<=input_words+1;
                    if(s_axis_tkeep!=15||s_axis_tlast!=(input_words==76799))begin status<=2;loaded<=0;state<=s_axis_tlast?ABORT:RAW_DROP;end
                    else if(fill_word==159)begin
                        fill_word<=0;
                        if(fill_channel==47)begin stage<=0;half<=0;oc_block<=0;ic_block<=0;wi<=0;weight_oc<=0;weight_tap<=0;state<=WREAD;end
                        else begin fill_channel<=fill_channel+1;if(fill_bank==2)begin fill_bank<=0;fill_group<=fill_group+1;end else fill_bank<=fill_bank+1;end
                    end else fill_word<=fill_word+1;
                end
                WREAD:if(!PIPELINE_FEED)state<=WSEND;
                else if(feed_read_done)begin px<=0;py<=0;patch_index<=0;read_slot<=base_slot;state<=PREAD;end
                else begin
                    if(weight_tap==(stage?8:0))begin weight_tap<=0;weight_oc<=weight_oc+1;end else weight_tap<=weight_tap+1;
                    if(wi!=(stage?143:15))wi<=wi+1;
                end
                WSEND:begin
                    if(weight_tap==(stage?8:0))begin weight_tap<=0;weight_oc<=weight_oc+1;end else weight_tap<=weight_tap+1;
                    if(wi==(stage?143:15))begin px<=0;py<=0;patch_index<=0;read_slot<=base_slot;state<=PREAD;end
                    else begin wi<=wi+1;state<=WREAD;end
                end
                PREAD:if(!PIPELINE_FEED)begin pad_q<=is_pad;state<=PSEND;end
                else if(feed_read_done)state<=DRAIN0;
                else begin
                    pad_q<=is_pad;
                    if(px==(stage?80:79))begin px<=0;py<=py+1;read_slot<=read_slot==8?0:read_slot+1;end else px<=px+1;
                    if(patch_index!=(stage?728:319))patch_index<=patch_index+1;
                end
                PSEND:begin
                    if(px==(stage?80:79))begin px<=0;py<=py+1;read_slot<=read_slot==8?0:read_slot+1;end else px<=px+1;
                    if(patch_index==(stage?728:319))state<=DRAIN0;else begin patch_index<=patch_index+1;state<=PREAD;end
                end
                DRAIN0:state<=DRAIN1;
                DRAIN1:state<=START;
                START:state<=WAIT_CORE;
                WAIT_CORE:if(core_done)begin
                    if(core_error)begin status<=3;loaded<=0;state<=ABORT;end else begin
                        if(stage)cycles6<=cycles6+core_cycles;else cycles5<=cycles5+core_cycles;
                        if(ic_block!=(stage?21:15))begin ic_block<=ic_block+1;wi<=0;weight_oc<=0;weight_tap<=0;state<=WREAD;end
                        else begin oc<=0;pixel<=0;read_done<=0;read_valid<=0;read_last<=0;save_channel<=0;save_word<=0;packed_data<=0;packed_lane<=0;packed_valid<=0;packed_last<=0;state<=FUSE;end
                    end
                end
                FUSE:begin
                    if(qr)begin
                        read_valid<=!read_done;
                        if(!read_done)begin
                            read_oc<=oc;read_last<=oc==15&&pixel==(stage?159:319);
                            if(pixel==(stage?159:319))begin pixel<=0;if(oc==15)read_done<=1;else oc<=oc+1;end else pixel<=pixel+1;
                        end
                    end
                    if(stage&&out_fire)begin
                        packed_valid<=0;output_words<=output_words+1;
                        if(packed_last)begin
                            read_valid<=0;
                            if(oc_block!=3)begin oc_block<=oc_block+1;ic_block<=0;wi<=0;weight_oc<=0;weight_tap<=0;state<=WREAD;end
                            else if(stripe==9)begin active<=0;footer_index<=0;state<=FOOT;end else state<=NEXT;
                        end
                    end
                    if(qv&&qo)begin
                        case(packed_lane)
                            0:packed_data<={24'd0,q};1:packed_data[15:8]<=q;2:packed_data[23:16]<=q;3:packed_data[31:24]<=q;
                        endcase
                        if(packed_lane==3)begin
                            packed_lane<=0;
                            if(stage)begin packed_valid<=1;packed_last<=ql;end
                            else if(save_word==79)begin save_word<=0;save_channel<=save_channel+1;end else save_word<=save_word+1;
                        end else packed_lane<=packed_lane+1;
                        if(ql&&!stage)begin
                            read_valid<=0;ic_block<=0;wi<=0;weight_oc<=0;weight_tap<=0;state<=WREAD;
                            if(oc_block!=3)oc_block<=oc_block+1;
                            else begin oc_block<=0;if(!half)half<=1;else stage<=1;end
                        end
                    end
                end
                NEXT:if(!STRIPE_PAUSE||stripe_resume)begin
                    stripe<=stripe+1;base_slot<=base_slot==0?8:base_slot-1;
                    fill_channel<=0;fill_bank<=0;fill_group<=0;fill_word<=0;state<=FILL;
                end
                RAW_DROP:if(in_fire&&s_axis_tlast)state<=ABORT;
                ABORT:begin read_valid<=0;packed_valid<=0;state<=PAD;end
                PAD:if(out_fire)begin output_words<=output_words+1;if(output_words==25599)begin active<=0;footer_index<=0;state<=FOOT;end end
                FOOT:if(out_fire)begin if(footer_index==9)state<=HEAD;else footer_index<=footer_index+1;end
                BULK_HEAD:if(out_fire)begin if(reply_hi==7)begin body_index<=0;state<=BULK_DATA;end else reply_hi<=reply_hi+1;end
                BULK_DATA:if(in_fire)begin
                    if(s_axis_tkeep!=15)status<=2;body_index<=body_index+1;
                    if(s_axis_tlast)begin if(body_index==header[6]-1)state<=BULK_FOOT;else begin status<=2;state<=BULK_PAD;end end
                    else if(body_index==header[6]-1)begin status<=2;state<=BULK_DROP;end
                end
                BULK_PAD:if(out_fire)begin body_index<=body_index+1;if(body_index==header[6]-1)state<=BULK_FOOT;end
                BULK_DROP:if(in_fire&&s_axis_tlast)state<=BULK_FOOT;
                BULK_FOOT:if(out_fire)state<=HEAD;
                default:begin loaded<=0;active<=0;state<=HEAD;end
            endcase
        end
    end
endmodule
