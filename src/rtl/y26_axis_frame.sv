`timescale 1ns/1ps
// Full RGB888 frame -> one shared tile PE -> two fused layers -> tile-major INT8.
// 0x10 LOAD retains the chain parameter format; 0x13 is a NEW frame protocol.
// This controller uses the core's memory ports directly, never framed self-feed.
module y26_axis_frame #(parameter ENABLE_THIRD=0, parameter EXTERNAL_COMPUTE=0, parameter STRIPE_PAUSE=0, parameter SECOND_RAM_STYLE="block", parameter EXTERNAL_MEMORY=0)(
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER="XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF S_AXIS:M_AXIS, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000" *) input wire aclk,
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER="XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *) input wire aresetn,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 S_AXIS TDATA" *) input wire [31:0] s_axis_tdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 S_AXIS TKEEP" *) input wire [3:0] s_axis_tkeep,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 S_AXIS TLAST" *) input wire s_axis_tlast,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 S_AXIS TVALID" *) input wire s_axis_tvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 S_AXIS TREADY" *) output wire s_axis_tready,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS TDATA" *) output reg [31:0] m_axis_tdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS TKEEP" *) output wire [3:0] m_axis_tkeep,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS TLAST" *) output reg m_axis_tlast,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS TVALID" *) output wire m_axis_tvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS TREADY" *) input wire m_axis_tready,
    output wire config_busy,
    output wire [185:0] compute_core_command,
    output wire [137:0] compute_tail_command,
    input wire [802:0] external_core_response,
    input wire [10:0] external_tail_response,
    input wire stripe_resume,
    output wire stripe_waiting,
    output wire [927:0] feature_command, input wire [511:0] feature_response
);
    localparam HEAD=0,CHECK=1,LOAD=2,DROP=3,ACK=4,RAW_HEAD=5,FILL=6,
        WEIGHT_READ=7,WEIGHT_SEND=8,PATCH_READ=9,PATCH_SEND=10,
        DRAIN0=11,DRAIN1=12,START=13,WAIT_CORE=14,FUSE=15,NEXT=16,
        FOOT=17,PAD=18,RAW_DROP=19,ABORT=20,BULK_HEAD=21,BULK_DATA=22,
        BULK_PAD=23,BULK_DROP=24,BULK_FOOT=25;
    reg [4:0] state;
    assign stripe_waiting=state==NEXT;
    reg [31:0] header[0:7];reg [2:0] hi,reply_hi;
    reg header_last,bad_header,loaded,loaded_three,request_three,raw_active,job_active;
    reg [31:0] status,body_index,low_word,job_cycles,cycles0,cycles1,cycles2;
    reg [31:0] feed_cycles,fusion_cycles,fill_cycles,stall_cycles,output_words;
    reg [3:0] footer_index;
    (* ram_style="block" *) reg [47:0] weight_mem[0:(ENABLE_THIRD?2223:1871)];
    reg [31:0] multiplier[0:(ENABLE_THIRD?79:47)];reg [4:0] shift[0:(ENABLE_THIRD?79:47)];reg [47:0] bias[0:(ENABLE_THIRD?79:47)];
    reg stage,third,oc_block;reg [3:0] ic_block;reg [5:0] stripe;
    reg [7:0] wi;reg [3:0] weight_oc,weight_tap;reg [47:0] weight_q;
    reg [8:0] patch_x;reg [3:0] patch_y,raw_slot,base_slot;
    reg [11:0] patch_index;reg pad_q;
    reg [7:0] row_tag[0:15];reg [15:0] row_valid;
    reg [3:0] save_channel;reg [7:0] save_word;
    wire [31:0] ring_q[0:15];
    wire signed [10:0] source_y=$signed({5'd0,stripe,2'b00})-11'sd5+$signed({7'd0,patch_y});
    wire [8:0] source_x=patch_x-9'd1;
    wire source_pad=patch_x==0||source_y<0||source_y>=160;
    wire first_pad=patch_x==0||(stripe==0&&patch_y==0);
    wire [9:0] ring_address={6'd0,source_y[3:0]}*10'd40+{3'd0,source_x[8:2]};
    wire [9:0] ring_write_address={8'd0,stripe[1:0]}*10'd160+{2'd0,save_word};
    wire [5:0] input_channel={2'd0,ic_block}*6'd3;
    wire [7:0] b0=ring_q[input_channel][source_x[1:0]*8+:8];
    wire [7:0] b1=input_channel<15?ring_q[input_channel+1][source_x[1:0]*8+:8]:8'd0;
    wire [7:0] b2=input_channel<14?ring_q[input_channel+2][source_x[1:0]*8+:8]:8'd0;
    wire [47:0] ring_triplet={{8{b2[7]}},b2,{8{b1[7]}},b1,{8{b0[7]}},b0};
    wire [31:0] second_q[0:31];
    wire [7:0] s0=second_q[input_channel][patch_x[1:0]*8+:8];
    wire [7:0] s1=input_channel<31?second_q[input_channel+1][patch_x[1:0]*8+:8]:8'd0;
    wire [7:0] s2=input_channel<30?second_q[input_channel+2][patch_x[1:0]*8+:8]:8'd0;
    wire [47:0] second_triplet={{8{s2[7]}},s2,{8{s1[7]}},s1,{8{s0[7]}},s0};
    wire output_stage=third||(stage&&!request_three);
    wire load_three=ENABLE_THIRD&&header[1]==32'h10014;
    wire [31:0] parameter_words=load_three?32'd320:32'd192;
    wire [31:0] load_words=load_three?32'd4768:32'd3936;
    wire [3:0] last_ic=third?4'd10:4'd5;
    wire rows_ready,rows_ended,rows_error,rows_sr;
    wire [23:0] rgb_q;wire [31:0] input_words;
    wire rows_start=state==CHECK&&!bad_header&&header[0]==32'h59323643&&
        (header[1]==32'h10013||(ENABLE_THIRD&&loaded_three&&header[1]==32'h10015))&&loaded&&header[3]==0&&header[4]==32'h1400140&&
        header[5]==0&&header[6]==76800&&header[7]==(header[1]==32'h10015 ? 32'd51219 : 32'd51218)&&!header_last;
    y26_rgb_rows rows(.clk(aclk),.resetn(aresetn),.start(rows_start),.advance(state==NEXT&&(!STRIPE_PAUSE||stripe_resume)),
        .s_data(s_axis_tdata),.s_keep(s_axis_tkeep),.s_last(s_axis_tlast),
        .s_valid(s_axis_tvalid&&state==FILL),.s_ready(rows_sr),.block_ready(rows_ready),
        .ended(rows_ended),.error(rows_error),.accepted_words(input_words),
        .read_en(state==PATCH_READ&&!stage&&!first_pad),
        .read_addr(raw_slot*12'd320+{3'd0,source_x}),.read_data(rgb_q));
    wire [47:0] rgb_triplet={8'd0,rgb_q[23:16],8'd0,rgb_q[15:8],8'd0,rgb_q[7:0]};
    wire [10:0] weight_set=stage?11'd1+(oc_block?11'd6:11'd0)+ic_block:11'd0;
    wire [11:0] weight_address=third?12'd1872+(oc_block?12'd176:12'd0)+{4'd0,ic_block,4'd0}+{8'd0,wi[3:0]}:
        {1'b0,weight_set}*12'd144+{4'd0,wi};
    wire [767:0] core_data;wire core_busy,core_done,core_error;wire [31:0] core_cycles;
    reg [3:0] oc,read_oc;reg [9:0] pixel;reg read_done,read_valid,read_last;
    wire q_ready,q_valid,q_last,q_out_ready;wire [7:0] q_value;
    reg [31:0] packed_data;reg [1:0] packed_lane;reg packed_valid,packed_last;
    wire fused_issue=state==FUSE&&!read_done&&q_ready;
    wire [6:0] channel_index=(third?(oc_block?7'd64:7'd48):stage?(oc_block?7'd32:7'd16):7'd0)+read_oc;
    wire [31:0] core_tag=third?32'hc2020000|({26'd0,stripe}<<1)|{31'd0,oc_block}:
        stage?32'hc2010000|({26'd0,stripe}<<1)|{31'd0,oc_block}:32'hc2000000|{26'd0,stripe};
    // Internal compute link: reset/start/config/write/read request, then response.
    // EXTERNAL_COMPUTE removes this controller's PE/tail from the unified netlist.
    wire [802:0] local_core_response;wire [10:0] local_tail_response;
    assign compute_core_command={aresetn&&state!=ABORT,state==START,third?2'd1:2'd3,third?2'd1:2'd2,third&&ic_block==10?2'd2:stage&&!third&&ic_block==5?2'd1:2'd3,5'd16,stage?8'd80:8'd160,3'd4,!stage||ic_block==0,core_tag,state==PATCH_SEND,patch_index,pad_q?48'd0:third?second_triplet:stage?ring_triplet:rgb_triplet,state==WEIGHT_SEND,weight_oc,weight_tap,weight_q,fused_issue,pixel};
    assign compute_tail_command={aresetn&&state!=ABORT,state==FUSE&&read_valid,q_out_ready,core_data[read_oc*48+:48],bias[channel_index],multiplier[channel_index],shift[channel_index],1'b1,read_last};
    assign {core_busy,core_done,core_error,core_cycles,core_data}=EXTERNAL_COMPUTE?external_core_response:local_core_response;
    assign {q_ready,q_valid,q_last,q_value}=EXTERNAL_COMPUTE?external_tail_response:local_tail_response;
    generate if(!EXTERNAL_COMPUTE)begin: local_compute
        y26_compute_unit unit(.clk(aclk),.core_command(compute_core_command),.core_response(local_core_response),
            .tail_command(compute_tail_command),.tail_response(local_tail_response));
    end else begin: external_compute
        assign local_core_response=0;assign local_tail_response=0;
    end endgenerate

    assign q_out_ready=state==FUSE&&(!output_stage||!packed_valid||m_axis_tready);

    generate for(genvar c=0;c<16;c=c+1)begin: bank
        wire we=state==FUSE&&!stage&&q_valid&&q_out_ready&&packed_lane==3&&save_channel==c;
        wire re=state==PATCH_READ&&stage&&!source_pad;
        assign feature_command[c*58+:58]={we,2'd0,ring_write_address,{q_value,packed_data[23:0]},re,2'd0,ring_address};
        if(EXTERNAL_MEMORY)begin: shared_storage
            assign ring_q[c]=feature_response[c*32+:32];
        end else begin: private_storage
            (* ram_style="block" *) reg [31:0] values[0:639];reg [31:0] q;
            assign ring_q[c]=q;
            always @(posedge aclk)begin
                if(we)values[ring_write_address]<={q_value,packed_data[23:0]};
                if(re)q<=values[ring_address];
            end
        end
    end endgenerate
    generate if(ENABLE_THIRD)begin: second_storage
        for(genvar b=0;b<32;b=b+1)begin: bank
            (* ram_style=SECOND_RAM_STYLE *) reg [31:0] values[0:79];reg [31:0] q;
            assign second_q[b]=q;
            always @(posedge aclk)begin
                if(state==FUSE&&stage&&!third&&request_three&&q_valid&&q_out_ready&&packed_lane==3&&({1'b0,save_channel}+(oc_block?5'd16:5'd0))==b)
                    values[save_word[6:0]]<={q_value,packed_data[23:0]};
                if(state==PATCH_READ&&third)q<=values[patch_index[8:2]];
            end
        end
    end else begin: no_second_storage
        for(genvar b=0;b<32;b=b+1)assign second_q[b]=0;
    end endgenerate
    always @(posedge aclk)begin
        if(state==LOAD&&s_axis_tvalid&&s_axis_tready&&body_index>=parameter_words&&body_index<load_words&&body_index[0])
            weight_mem[(body_index-parameter_words)>>1]<={s_axis_tdata[15:0],low_word};
        if(state==WEIGHT_READ)weight_q<=weight_mem[weight_address];
    end
    assign config_busy=state!=HEAD||hi!=0||s_axis_tvalid;
    assign s_axis_tready=aresetn&&(state==HEAD||state==LOAD||state==DROP||state==RAW_DROP||state==BULK_DROP||
        (state==FILL&&rows_sr)||(state==BULK_DATA&&m_axis_tready));
    assign m_axis_tkeep=4'hf;
    assign m_axis_tvalid=aresetn&&(state==ACK||state==RAW_HEAD||state==FOOT||state==PAD||state==BULK_HEAD||
        state==BULK_PAD||state==BULK_FOOT||(state==FUSE&&output_stage&&packed_valid)||(state==BULK_DATA&&s_axis_tvalid));
    wire in_fire=s_axis_tvalid&&s_axis_tready;
    wire out_fire=m_axis_tvalid&&m_axis_tready;
    always @*begin
        m_axis_tdata=0;m_axis_tlast=0;
        if(state==ACK||state==RAW_HEAD||state==BULK_HEAD)begin
            case(reply_hi)
                0:m_axis_tdata=32'h59323652;
                1:m_axis_tdata=header[1];
                2:m_axis_tdata=header[2];
                3:m_axis_tdata=status;
                4:m_axis_tdata=state==RAW_HEAD?32'h500050:0;
                5:m_axis_tdata=state==RAW_HEAD?32'd32:0;
                6:m_axis_tdata=state==RAW_HEAD?(request_three?32'd51211:32'd51210):state==BULK_HEAD?header[6]+1:0;
                default:m_axis_tdata=0;
            endcase
            m_axis_tlast=state==ACK&&reply_hi==7;
        end else if(state==FUSE)begin m_axis_tdata=packed_data;end
        else if(state==FOOT)begin
            case(footer_index)
                0:m_axis_tdata=status;
                1:m_axis_tdata=job_cycles;
                2:m_axis_tdata=cycles0;
                3:m_axis_tdata=cycles1;
                4:m_axis_tdata=feed_cycles;
                5:m_axis_tdata=fusion_cycles;
                6:m_axis_tdata=fill_cycles;
                7:m_axis_tdata=stall_cycles;
                8:m_axis_tdata=input_words;
                9:m_axis_tdata=output_words;
                10:m_axis_tdata=cycles2;
            endcase
            m_axis_tlast=footer_index==(request_three?10:9);
        end else if(state==BULK_DATA)m_axis_tdata=s_axis_tdata;
        else if(state==BULK_FOOT)begin m_axis_tdata=status;m_axis_tlast=1;end
    end
    integer r;
    always @(posedge aclk)begin
        if(!aresetn)begin
            state<=HEAD;hi<=0;reply_hi<=0;header_last<=0;bad_header<=0;loaded<=0;loaded_three<=0;request_three<=0;raw_active<=0;job_active<=0;
            status<=0;body_index<=0;low_word<=0;job_cycles<=0;cycles0<=0;cycles1<=0;cycles2<=0;
            feed_cycles<=0;fusion_cycles<=0;fill_cycles<=0;stall_cycles<=0;output_words<=0;footer_index<=0;
            stage<=0;third<=0;oc_block<=0;ic_block<=0;stripe<=0;wi<=0;weight_oc<=0;weight_tap<=0;
            patch_x<=0;patch_y<=0;raw_slot<=8;base_slot<=8;patch_index<=0;pad_q<=0;row_valid<=0;
            save_channel<=0;save_word<=0;oc<=0;pixel<=0;read_done<=0;read_valid<=0;read_oc<=0;read_last<=0;
            packed_data<=0;packed_lane<=0;packed_valid<=0;packed_last<=0;
        end else begin
            if(job_active)job_cycles<=job_cycles+1;
            if(job_active&&(state==WEIGHT_READ||state==WEIGHT_SEND||state==PATCH_READ||state==PATCH_SEND||state==DRAIN0||state==DRAIN1))feed_cycles<=feed_cycles+1;
            if(job_active&&state==FUSE)fusion_cycles<=fusion_cycles+1;
            if(job_active&&state==FILL)fill_cycles<=fill_cycles+1;
            if(job_active&&m_axis_tvalid&&!m_axis_tready)stall_cycles<=stall_cycles+1;
            case(state)
                HEAD:if(in_fire)begin
                    header[hi]<=s_axis_tdata;
                    if(hi==0)bad_header<=s_axis_tkeep!=15;else if(s_axis_tkeep!=15)bad_header<=1;
                    if(s_axis_tlast&&hi!=7)begin status<=2;loaded<=0;reply_hi<=0;hi<=0;state<=ACK;end
                    else if(hi==7)begin hi<=0;header_last<=s_axis_tlast;state<=CHECK;end else hi<=hi+1;
                end
                CHECK:begin
                    status<=0;reply_hi<=0;body_index<=0;raw_active<=header[1][15:0]==16'h13||header[1][15:0]==16'h15;request_three<=ENABLE_THIRD&&header[1][15:0]==16'h15;
                    if(bad_header||header[0]!=32'h59323643||header[1][31:16]!=1)begin
                        status<=1;loaded<=0;state<=header_last?ACK:DROP;
                    end else if((header[1][15:0]==16'h10||load_three)&&header[3]==0&&header[4]==0&&header[5]==0&&header[6]==load_words&&header[7]==8&&!header_last)begin loaded<=0;loaded_three<=0;state<=LOAD;end
                    else if(rows_start)begin
                        stripe<=0;base_slot<=8;row_valid<=0;output_words<=0;
                        job_cycles<=0;cycles0<=0;cycles1<=0;cycles2<=0;feed_cycles<=0;fusion_cycles<=0;fill_cycles<=0;stall_cycles<=0;
                        job_active<=1;state<=RAW_HEAD;
                    end else if(header[1][15:0]==16'h12&&header[3]==0&&header[4]==0&&header[5]==0&&header[6]>0&&header[6]<=131063&&header[7]==header[6]+9&&!header_last)state<=BULK_HEAD;
                    else begin status<=1;loaded<=0;state<=header_last?ACK:DROP;end
                end
                LOAD:if(in_fire)begin
                    if(s_axis_tkeep!=15)status<=2;
                    if(body_index<parameter_words)begin
                        case(body_index[1:0])
                            0:multiplier[body_index[8:2]]<=s_axis_tdata;
                            1:begin shift[body_index[8:2]]<=s_axis_tdata[4:0];if(s_axis_tdata>31)status<=2;end
                            2:bias[body_index[8:2]][31:0]<=s_axis_tdata;
                            3:begin bias[body_index[8:2]][47:32]<=s_axis_tdata[15:0];if(s_axis_tdata[31:16]!=0)status<=2;end
                        endcase
                    end else if(!body_index[0])low_word<=s_axis_tdata;
                    else if(s_axis_tdata[31:16]!=0)status<=2;
                    if(s_axis_tlast)begin
                        if(body_index!=load_words-1||status!=0||s_axis_tkeep!=15||s_axis_tdata[31:16]!=0)begin status<=2;loaded<=0;loaded_three<=0;end
                        else begin loaded<=1;loaded_three<=load_three;end
                        state<=ACK;
                    end else if(body_index>=load_words-1)begin status<=2;state<=DROP;end else body_index<=body_index+1;
                end
                DROP:if(in_fire&&s_axis_tlast)begin loaded<=0;reply_hi<=0;state<=ACK;end
                ACK:if(out_fire)begin if(reply_hi==7)state<=HEAD;else reply_hi<=reply_hi+1;end
                RAW_HEAD:if(out_fire)begin if(reply_hi==7)state<=FILL;else reply_hi<=reply_hi+1;end
                FILL:begin
                    if(rows_error)begin status<=2;loaded<=0;state<=rows_ended?ABORT:RAW_DROP;end
                    else if(rows_ready)begin
                        stage<=0;third<=0;oc_block<=0;ic_block<=0;wi<=0;weight_oc<=0;weight_tap<=0;state<=WEIGHT_READ;
                    end
                end
                WEIGHT_READ:state<=WEIGHT_SEND;
                WEIGHT_SEND:begin
                    if(weight_tap==(third?0:8))begin weight_tap<=0;weight_oc<=weight_oc+1;end else weight_tap<=weight_tap+1;
                    if(wi==(third?15:143))begin patch_x<=0;patch_y<=0;patch_index<=0;raw_slot<=base_slot;state<=PATCH_READ;end
                    else begin wi<=wi+1;state<=WEIGHT_READ;end
                end
                PATCH_READ:begin
                    pad_q<=third?1'b0:stage?source_pad:first_pad;
                    if(stage&&!third&&!source_pad&&(!row_valid[source_y[3:0]]||row_tag[source_y[3:0]]!=source_y[7:0]))begin status<=3;loaded<=0;state<=ABORT;end
                    else state<=PATCH_SEND;
                end
                PATCH_SEND:begin
                    if(patch_x==(third?79:stage?160:320))begin patch_x<=0;patch_y<=patch_y+1;raw_slot<=raw_slot==8?0:raw_slot+1;end
                    else patch_x<=patch_x+1;
                    if(patch_index==(third?319:stage?1448:2888))state<=DRAIN0;
                    else begin patch_index<=patch_index+1;state<=PATCH_READ;end
                end
                DRAIN0:state<=DRAIN1;
                DRAIN1:state<=START;
                START:state<=WAIT_CORE;
                WAIT_CORE:if(core_done)begin
                    if(core_error)begin status<=3;loaded<=0;state<=ABORT;end
                    else begin
                        if(third)cycles2<=cycles2+core_cycles;else if(stage)cycles1<=cycles1+core_cycles;else cycles0<=cycles0+core_cycles;
                        if(stage&&ic_block!=last_ic)begin ic_block<=ic_block+1;wi<=0;weight_oc<=0;weight_tap<=0;state<=WEIGHT_READ;end
                        else begin
                            oc<=0;pixel<=0;read_done<=0;read_valid<=0;read_last<=0;
                            save_channel<=0;save_word<=0;packed_data<=0;packed_lane<=0;packed_valid<=0;packed_last<=0;state<=FUSE;
                        end
                    end
                end
                FUSE:begin
                    if(q_ready)begin
                        read_valid<=!read_done;
                        if(!read_done)begin
                            read_oc<=oc;read_last<=oc==15&&pixel==(stage?319:639);
                            if(pixel==(stage?319:639))begin pixel<=0;if(oc==15)read_done<=1;else oc<=oc+1;end
                            else pixel<=pixel+1;
                        end
                    end
                    if(output_stage&&out_fire)begin
                        packed_valid<=0;output_words<=output_words+1;
                        if(packed_last)begin
                            read_valid<=0;
                            if(!oc_block)begin oc_block<=1;ic_block<=0;wi<=0;weight_oc<=0;weight_tap<=0;state<=WEIGHT_READ;end
                            else if(stripe==39)begin job_active<=0;footer_index<=0;state<=FOOT;end
                            else state<=NEXT;
                        end
                    end
                    if(q_valid&&q_out_ready)begin
                        case(packed_lane)
                            0:packed_data<={24'd0,q_value};1:packed_data[15:8]<=q_value;
                            2:packed_data[23:16]<=q_value;3:packed_data[31:24]<=q_value;
                        endcase
                        if(packed_lane==3)begin
                            packed_lane<=0;
                            if(output_stage)begin packed_valid<=1;packed_last<=q_last;end
                            else if(save_word==(stage?79:159))begin save_word<=0;save_channel<=save_channel+1;end else save_word<=save_word+1;
                        end else packed_lane<=packed_lane+1;
                        if(q_last&&!output_stage)begin
                            read_valid<=0;
                            if(!stage)begin
                                for(r=0;r<4;r=r+1)begin row_tag[{stripe[1:0],2'b00}+r]<=stripe*4+r;row_valid[{stripe[1:0],2'b00}+r]<=1;end
                                if(!stripe[0])state<=NEXT;
                                else begin stage<=1;oc_block<=0;ic_block<=0;wi<=0;weight_oc<=0;weight_tap<=0;state<=WEIGHT_READ;end
                            end else begin
                                if(oc_block)begin third<=1;oc_block<=0;end else oc_block<=1;
                                ic_block<=0;wi<=0;weight_oc<=0;weight_tap<=0;state<=WEIGHT_READ;
                            end
                        end
                    end
                end
                NEXT:if(!STRIPE_PAUSE||stripe_resume)begin stripe<=stripe+1;base_slot<=base_slot==0?8:base_slot-1;state<=FILL;end
                RAW_DROP:if(in_fire&&s_axis_tlast)state<=ABORT;
                ABORT:begin read_valid<=0;packed_valid<=0;state<=PAD;end
                PAD:if(out_fire)begin
                    output_words<=output_words+1;
                    if(output_words==51199)begin job_active<=0;footer_index<=0;state<=FOOT;end
                end
                FOOT:if(out_fire)begin if(footer_index==(request_three?10:9))begin raw_active<=0;state<=HEAD;end else footer_index<=footer_index+1;end
                BULK_HEAD:if(out_fire)begin if(reply_hi==7)begin body_index<=0;state<=BULK_DATA;end else reply_hi<=reply_hi+1;end
                BULK_DATA:if(in_fire)begin
                    if(s_axis_tkeep!=15)status<=2;body_index<=body_index+1;
                    if(s_axis_tlast)begin if(body_index==header[6]-1)state<=BULK_FOOT;else begin status<=2;state<=BULK_PAD;end end
                    else if(body_index==header[6]-1)begin status<=2;state<=BULK_DROP;end
                end
                BULK_PAD:if(out_fire)begin body_index<=body_index+1;if(body_index==header[6]-1)state<=BULK_FOOT;end
                BULK_DROP:if(in_fire&&s_axis_tlast)state<=BULK_FOOT;
                BULK_FOOT:if(out_fire)state<=HEAD;
                default:begin loaded<=0;job_active<=0;state<=HEAD;end
            endcase
        end
    end
endmodule
