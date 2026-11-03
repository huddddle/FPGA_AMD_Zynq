`timescale 1ns/1ps
// Independent conv11: CHW INT8 input resident, one 16OC weight block, shared PE.
// INIT40 loads 128 coefficients + input. RUN41 loads 43x16x9 triplet weights.
module y26_axis_conv11 #(parameter EXTERNAL_COMPUTE=0,parameter EXTERNAL_MEMORY=0,parameter ALLOW_RESIDENT_INIT=0,parameter ALLOW_CONV21=0,parameter ALLOW_DEEP_INIT=0)(
 input wire aclk,aresetn,input wire [31:0] s_axis_tdata,input wire [3:0] s_axis_tkeep,
 input wire s_axis_tlast,s_axis_tvalid,output wire s_axis_tready,
 output reg [31:0] m_axis_tdata,output wire [3:0] m_axis_tkeep,
 output reg m_axis_tlast,output wire m_axis_tvalid,input wire m_axis_tready,output wire config_busy,
 output wire [185:0] compute_core_command,output wire [137:0] compute_tail_command,
 input wire [802:0] external_core_response,input wire [10:0] external_tail_response,
 output wire [191:0] feature_command,input wire [95:0] feature_response,
 output wire [77:0] weight_command,input wire [47:0] weight_response,
 input wire resident_ready,input wire resident21_ready
);
 localparam HEAD=0,CHECK=1,INIT=2,LOAD=3,ACK=4,OUT_HEAD=5,WREAD=6,PREAD=7,D0=8,D1=9,START=10,WAIT=11,FUSE=12,FLUSH=13,FOOT=14,DROP=15;
 reg [3:0] state;reg [2:0] hi,reply_hi,stripe;reg [3:0] ob;reg [31:0] h[0:7];reg bad_header,header_last,loaded,coeff_only,layer21;
 localparam COEFFICIENTS=ALLOW_CONV21?256:128;
 wire [10:0] coefficient_words=layer21?11'd1024:11'd512;
 wire [31:0] expected_init=coeff_only?(layer21?32'd1024:32'd512):layer21?32'd13824:32'd51712;
 wire [2:0] tile_height=layer21&&stripe==2?3'd2:3'd4;
 wire [7:0] tile_width=layer21?8'd10:8'd20;
 wire [6:0] last_pixel=layer21?(stripe==2?7'd19:7'd39):7'd79;
 wire [8:0] last_patch=layer21?(stripe==2?9'd104:9'd188):9'd368;
 reg [31:0] count,status,low_word,job_cycles,core_cycles,feed_cycles,fusion_cycles,output_words;
 reg [1:0] fill_bank;reg [5:0] fill_group,ib;reg [8:0] fill_word;
 reg [31:0] multiplier[0:COEFFICIENTS-1];reg [4:0] shift[0:COEFFICIENTS-1];reg [47:0] bias[0:COEFFICIENTS-1];
 (* ram_style="block" *) reg [47:0] weights[0:6191];wire [47:0] weight_q;reg [47:0] private_weight_q;
 reg [7:0] wi;reg [3:0] wo,wt;reg [5:0] px;reg [3:0] py;reg [8:0] patch_index;
 reg feed_valid,feed_done,pad_q;reg [1:0] lane_q;reg [8:0] patch_q;reg [3:0] wo_q,wt_q;
 wire signed [9:0] source_y=$signed({4'd0,stripe,3'd0})-10'sd1+$signed({6'd0,py});
 wire [5:0] source_x=px-1;wire is_pad=px==0||source_y<0||source_y>=(layer21?20:40);
 wire [14:0] input_read=layer21?{9'd0,ib}*15'd100+{9'd0,source_y[5:0]}*15'd5+{11'd0,source_x[5:2]}:{9'd0,ib}*15'd400+{9'd0,source_y[5:0]}*15'd10+{11'd0,source_x[5:2]};
 wire [14:0] input_write=(layer21?{9'd0,fill_group}*15'd100:{9'd0,fill_group}*15'd400)+{6'd0,fill_word};
 wire [12:0] weight_addr={7'd0,ib}*13'd144+{5'd0,wi};
 wire [31:0] iq[0:2];
 generate for(genvar b=0;b<3;b=b+1)begin: banks
  assign feature_command[b*64+:64]={state==INIT&&s_axis_tvalid&&s_axis_tready&&count>=coefficient_words&&fill_bank==b,input_write,s_axis_tdata,state==PREAD&&!feed_done&&!is_pad,input_read};
  if(EXTERNAL_MEMORY)begin: shared_storage
   assign iq[b]=feature_response[b*32+:32];
  end else begin: private_storage
  // Avoid rounding a 17200-deep TDP bank up to the 32768-deep geometry.
  // Two synchronous memories retain the same one-cycle read contract.
  (* ram_style="block" *) reg [31:0] features_main[0:16383];
  (* ram_style="block" *) reg [31:0] features_tail[0:815];
  reg [31:0] main_q,tail_q;reg tail_selected;
  always @(posedge aclk)begin
   if(state==INIT&&s_axis_tvalid&&s_axis_tready&&count>=coefficient_words&&fill_bank==b)begin
    if(input_write[14])features_tail[input_write[9:0]]<=s_axis_tdata;else features_main[input_write[13:0]]<=s_axis_tdata;
   end
   if(state==PREAD&&!feed_done&&!is_pad)begin
    tail_selected<=input_read[14];
    if(input_read[14])tail_q<=features_tail[input_read[9:0]];else main_q<=features_main[input_read[13:0]];
   end
  end
  assign iq[b]=tail_selected?tail_q:main_q;
 end end endgenerate
 wire [7:0] a0=iq[0][lane_q*8+:8],a1=iq[1][lane_q*8+:8],a2=iq[2][lane_q*8+:8];
 wire [47:0] triplet={{8{a2[7]}},a2,{8{a1[7]}},a1,{8{a0[7]}},a0};
 reg [3:0] oc,read_oc;reg [6:0] pixel;reg read_done,read_valid,read_last;
 wire [7:0] channel_index={ob,4'd0}+{4'd0,read_oc};
 wire [185:0] command;wire [802:0] response;wire [137:0] tail;wire [10:0] tail_response;
 wire cb,cd,ce;wire [31:0] cc;wire [767:0] data;wire qr,qv,ql;wire [7:0] q;
 reg [31:0] packed_data;reg [1:0] packed_lane;reg packed_valid;
 wire qo=!packed_valid||m_axis_tready;
 assign command={aresetn,state==START,2'd3,2'd2,ib==42?2'd2:2'd3,5'd16,tile_width,tile_height,ib==0,
  32'h11000000|({28'd0,ob}<<8)|{29'd0,stripe},state==PREAD&&feed_valid,{3'd0,patch_q},pad_q?48'd0:triplet,state==WREAD&&feed_valid,wo_q,wt_q,weight_q,state==FUSE&&!read_done&&qr,{3'd0,pixel}};
 assign tail={aresetn,state==FUSE&&read_valid,qo,data[read_oc*48+:48],bias[channel_index],multiplier[channel_index],shift[channel_index],1'b1,read_last};
 assign {cb,cd,ce,cc,data}=response;assign {qr,qv,ql,q}=tail_response;
 assign compute_core_command=command;assign compute_tail_command=tail;
 generate if(!EXTERNAL_COMPUTE)begin: local_compute
 y26_compute_unit compute(.clk(aclk),.core_command(command),.core_response(response),.tail_command(tail),.tail_response(tail_response));
 end else begin: shared_compute
 assign response=external_core_response;assign tail_response=external_tail_response;
 end endgenerate
 assign weight_command={state==LOAD&&s_axis_tvalid&&s_axis_tready&&count[0],1'b0,count[13:1],s_axis_tdata[15:0],low_word,state==WREAD&&!feed_done,1'b0,weight_addr};
 assign weight_q=EXTERNAL_MEMORY?weight_response:private_weight_q;
 assign s_axis_tready=aresetn&&(state==HEAD||state==INIT||state==LOAD||state==DROP);
 assign m_axis_tkeep=15;assign config_busy=state!=HEAD||hi!=0;
 assign m_axis_tvalid=aresetn&&(state==ACK||state==OUT_HEAD||state==FOOT||((state==FUSE||state==FLUSH)&&packed_valid));
 always @*begin
  m_axis_tdata=0;m_axis_tlast=0;
  if(state==ACK||state==OUT_HEAD)begin
   case(reply_hi)0:m_axis_tdata=32'h59323652;1:m_axis_tdata=h[1];2:m_axis_tdata=h[2];3:m_axis_tdata=status;
    4:m_axis_tdata=state==OUT_HEAD?(layer21?32'ha000a:32'h140014):0;5:m_axis_tdata=state==OUT_HEAD?16:0;6:m_axis_tdata=state==OUT_HEAD?(layer21?408:1608):0;default:m_axis_tdata=0;endcase
   m_axis_tlast=state==ACK&&reply_hi==7;
  end else if(state==FUSE||state==FLUSH)m_axis_tdata=packed_data;
  else if(state==FOOT)begin
   case(reply_hi)0:m_axis_tdata=status;1:m_axis_tdata=job_cycles;2:m_axis_tdata=core_cycles;3:m_axis_tdata=feed_cycles;4:m_axis_tdata=fusion_cycles;5:m_axis_tdata=output_words;6:m_axis_tdata={28'd0,ob};default:m_axis_tdata=0;endcase
   m_axis_tlast=reply_hi==7;
  end
 end
 always @(posedge aclk)begin
  if(state==INIT&&s_axis_tvalid&&s_axis_tready&&count<coefficient_words)begin
   case(count[1:0])0:multiplier[count[9:2]]<=s_axis_tdata;1:shift[count[9:2]]<=s_axis_tdata[4:0];2:bias[count[9:2]][31:0]<=s_axis_tdata;3:bias[count[9:2]][47:32]<=s_axis_tdata[15:0];endcase
  end
  if(!EXTERNAL_MEMORY&&state==LOAD&&s_axis_tvalid&&s_axis_tready)begin
   if(count[0])weights[count[13:1]]<={s_axis_tdata[15:0],low_word};
  end
  if(state==LOAD&&s_axis_tvalid&&s_axis_tready&&!count[0])low_word<=s_axis_tdata;
  if(!EXTERNAL_MEMORY&&state==WREAD&&!feed_done)private_weight_q<=weights[weight_addr];
 end
 always @(posedge aclk)begin
  if(!aresetn)begin feed_valid<=0;feed_done<=0;pad_q<=0;lane_q<=0;patch_q<=0;wo_q<=0;wt_q<=0;end
  else if(state==WREAD||state==PREAD)begin
   feed_valid<=!feed_done;
   if(!feed_done)begin
    if(state==WREAD)begin wo_q<=wo;wt_q<=wt;if(wi==143)feed_done<=1;end
    else begin pad_q<=is_pad;lane_q<=source_x[1:0];patch_q<=patch_index;if(patch_index==last_patch)feed_done<=1;end
   end else feed_done<=0;
  end else begin feed_valid<=0;feed_done<=0;end
 end
 integer i;
 always @(posedge aclk)begin
  if(!aresetn)begin
   state<=HEAD;hi<=0;reply_hi<=0;stripe<=0;ob<=0;bad_header<=0;header_last<=0;loaded<=0;coeff_only<=0;layer21<=0;count<=0;status<=0;
   job_cycles<=0;core_cycles<=0;feed_cycles<=0;fusion_cycles<=0;output_words<=0;fill_bank<=0;fill_group<=0;fill_word<=0;ib<=0;wi<=0;wo<=0;wt<=0;px<=0;py<=0;patch_index<=0;
   oc<=0;pixel<=0;read_done<=0;read_valid<=0;read_last<=0;read_oc<=0;packed_data<=0;packed_lane<=0;packed_valid<=0;
   for(i=0;i<8;i=i+1)h[i]<=0;
  end else begin
   if(state>=OUT_HEAD&&state<=FLUSH)job_cycles<=job_cycles+1;
   if(state==WREAD||state==PREAD||state==D0||state==D1)feed_cycles<=feed_cycles+1;
   if(state==FUSE)fusion_cycles<=fusion_cycles+1;
   if(packed_valid&&m_axis_tready&&(state==FUSE||state==FLUSH))begin packed_valid<=0;output_words<=output_words+1;end
   case(state)
    HEAD:if(s_axis_tvalid&&s_axis_tready)begin
     h[hi]<=s_axis_tdata;if(hi==0)bad_header<=s_axis_tkeep!=15;else if(s_axis_tkeep!=15)bad_header<=1;
     header_last<=s_axis_tlast;
     if(s_axis_tlast&&hi!=7)begin hi<=0;reply_hi<=0;status<=2;state<=ACK;end else if(hi==7)begin hi<=0;state<=CHECK;end else hi<=hi+1;
    end
    CHECK:begin
     count<=0;reply_hi<=0;status<=0;
     if(bad_header||h[0]!=32'h59323643||header_last)begin status<=1;state<=header_last?ACK:DROP;end
     else if(ALLOW_DEEP_INIT&&resident21_ready&&h[1]==32'h10045&&h[4]==32'h140014&&h[5]==128&&h[6]==1024&&h[7]==8)begin loaded<=0;layer21<=1;coeff_only<=1;state<=INIT;end
     else if(ALLOW_CONV21&&h[1]==32'h10043&&h[4]==32'h140014&&h[5]==128&&h[6]==13824&&h[7]==8)begin loaded<=0;layer21<=1;coeff_only<=0;fill_bank<=0;fill_group<=0;fill_word<=0;state<=INIT;end
     else if(layer21&&h[1]==32'h10044&&loaded&&h[4]==32'ha000a&&h[5]<16&&h[6]==12384&&h[7]==416)begin ob<=h[5][3:0];state<=LOAD;end
     else if(h[1]==32'h10040&&h[4]==32'h280028&&h[5]==128&&h[6]==51712&&h[7]==8)begin loaded<=0;layer21<=0;coeff_only<=0;fill_bank<=0;fill_group<=0;fill_word<=0;state<=INIT;end
     else if(ALLOW_RESIDENT_INIT&&resident_ready&&h[1]==32'h10042&&h[4]==32'h280028&&h[5]==128&&h[6]==512&&h[7]==8)begin loaded<=0;layer21<=0;coeff_only<=1;state<=INIT;end
     else if(h[1]==32'h10041&&!layer21&&loaded&&h[4]==32'h140014&&h[5]<8&&h[6]==12384&&h[7]==1616)begin ob<=h[5][3:0];state<=LOAD;end
     else begin status<=1;state<=DROP;end
    end
    INIT:if(s_axis_tvalid&&s_axis_tready)begin
     count<=count+1;
     if(count>=coefficient_words)begin
      if(fill_word==(layer21?99:399))begin fill_word<=0;if(fill_bank==2)begin fill_bank<=0;fill_group<=fill_group+1;end else fill_bank<=fill_bank+1;end else fill_word<=fill_word+1;
     end
     if(s_axis_tlast)begin loaded<=count==expected_init-1;status<=count==expected_init-1?0:2;reply_hi<=0;state<=ACK;end
    end
    LOAD:if(s_axis_tvalid&&s_axis_tready)begin
     count<=count+1;
     if(s_axis_tlast)begin
      reply_hi<=0;
      if(count!=12383)begin status<=2;state<=ACK;end
      else begin stripe<=0;ib<=0;wi<=0;wo<=0;wt<=0;job_cycles<=0;core_cycles<=0;feed_cycles<=0;fusion_cycles<=0;output_words<=0;packed_valid<=0;state<=OUT_HEAD;end
     end
    end
    ACK:if(m_axis_tready)begin if(reply_hi==7)begin hi<=0;state<=HEAD;end else reply_hi<=reply_hi+1;end
    OUT_HEAD:if(m_axis_tready)begin if(reply_hi==7)state<=WREAD;else reply_hi<=reply_hi+1;end
    WREAD:begin
     if(!feed_done)begin
      if(wt==8)begin wt<=0;wo<=wo+1;end else wt<=wt+1;
      if(wi!=143)wi<=wi+1;
     end else begin px<=0;py<=0;patch_index<=0;state<=PREAD;end
    end
    PREAD:begin
     if(!feed_done)begin
      if(px==(layer21?20:40))begin px<=0;py<=py+1;end else px<=px+1;
      if(patch_index!=last_patch)patch_index<=patch_index+1;
     end else state<=D0;
    end
    D0:state<=D1;
    D1:state<=START;
    START:state<=WAIT;
    WAIT:if(cd)begin
     core_cycles<=core_cycles+cc;
     if(ce)begin status<=4;reply_hi<=0;state<=FOOT;end
     else if(ib<42)begin ib<=ib+1;wi<=0;wo<=0;wt<=0;state<=WREAD;end
     else begin oc<=0;pixel<=0;read_done<=0;read_valid<=0;read_last<=0;packed_lane<=0;state<=FUSE;end
    end
    FUSE:begin
     if(qr)begin
      read_valid<=!read_done;
      if(!read_done)begin read_oc<=oc;read_last<=oc==15&&pixel==last_pixel;if(pixel==last_pixel)begin pixel<=0;if(oc==15)read_done<=1;else oc<=oc+1;end else pixel<=pixel+1;end
     end
     if(qv&&qo)begin
      case(packed_lane)0:packed_data<={24'd0,q};1:packed_data[15:8]<=q;2:packed_data[23:16]<=q;3:begin packed_data[31:24]<=q;packed_valid<=1;end endcase
      packed_lane<=packed_lane+1;
      if(ql)begin read_valid<=0;state<=FLUSH;end
     end
    end
    FLUSH:if(!packed_valid)begin
     if(stripe==(layer21?2:4))begin reply_hi<=0;state<=FOOT;end
     else begin stripe<=stripe+1;ib<=0;wi<=0;wo<=0;wt<=0;state<=WREAD;end
    end
    FOOT:if(m_axis_tready)begin if(reply_hi==7)begin hi<=0;state<=HEAD;end else reply_hi<=reply_hi+1;end
    DROP:if(s_axis_tvalid&&s_axis_tready&&s_axis_tlast)begin reply_hi<=0;state<=ACK;end
    default:state<=HEAD;
   endcase
  end
 end
endmodule
