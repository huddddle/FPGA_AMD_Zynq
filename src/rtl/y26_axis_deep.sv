`timescale 1ns/1ps
// A sequenced 12..20 subgraph. One layer's weights at a time, one external PE.
// All addresses are words in the three existing 17408-word feature lanes.
module y26_axis_deep(
 input wire aclk,aresetn,resident_ready,input wire input_ready,
 input wire [31:0] s_axis_tdata,input wire [3:0] s_axis_tkeep,
 input wire s_axis_tlast,s_axis_tvalid,output wire s_axis_tready,
 output reg [31:0] m_axis_tdata,output wire [3:0] m_axis_tkeep,
 output reg m_axis_tlast,output wire m_axis_tvalid,input wire m_axis_tready,
 output wire [185:0] compute_core_command,output wire [137:0] compute_tail_command,
 input wire [802:0] external_core_response,input wire [10:0] external_tail_response,
 output wire [191:0] feature_command,input wire [95:0] feature_response,
 output wire [77:0] weight_command,input wire [47:0] weight_response,
 output reg completed
);
 localparam HEAD=0,CHECK=1,META=2,INPUT=3,LHEAD=4,COEFF=5,WEIGHTS=6,
  WR=7,W0=8,WS=9,PR=10,P0=11,PS=12,D0=13,D1=14,START=15,WAIT=16,FUSE=17,
  FDRAIN=18,LNEXT=19,BSET=20,BR0=21,BR1=22,BR2=23,BM0=24,BM1=25,
  BRB0=26,BRB1=27,BRB2=28,BM2=29,BM3=30,BSUM=31,BPACK=32,BWRITE=33,
  BNEXT=34,FINAL=35,ACK=36,DROP=37,REPORT=38,SKHEAD=39,SK0=40,SK1=41,
  SK2=42,SKSEND=43,SKFOOT=44,LCHECK=45,BADDR=46;
 reg [5:0] state;reg [2:0] hi;reg [4:0] ri;reg [31:0] h[0:7],lh[0:7];
 reg bad,header_last,packet_ended,job_active;reg [31:0] status,count,body_count,low_word;
 reg [3:0] stage;reg [31:0] ratios[0:7];
 reg [31:0] multiplier[0:127];reg [4:0] shift[0:127];reg [47:0] bias[0:127];
 reg [31:0] job_cycles,core_cycles,feed_cycles,fusion_cycles,bridge_cycles,stage_cycles[0:8];
 reg [2:0] ob;reg [5:0] ib;reg [4:0] row;reg [7:0] wi;reg [3:0] wo,wt;
 reg [13:0] weight_base,ob_weight_base;
 reg [4:0] px;reg [2:0] py;reg [8:0] patch_index;reg pad_q;
 reg [3:0] oc,read_oc;reg [6:0] pixel;reg read_done,read_valid,read_last;
 reg [1:0] lane,out_bank,out_bank_base;reg [5:0] out_group,out_group_base;
 reg [4:0] save_word;reg [31:0] pack_word;reg [1:0] drain;
 reg [2:0] fill_ob,fill_stripe;reg [3:0] fill_ch;reg [4:0] fill_word;
 reg [1:0] fill_bank,fill_bank_base;reg [5:0] fill_group,fill_group_base;
 wire k3=stage>=2&&stage<=5;
 wire [7:0] ci=stage==0?8'd128:stage==1||stage==6||stage==7?8'd64:stage==8?8'd192:8'd32;
 wire [7:0] co=stage==0||stage==8?8'd128:stage==7?8'd64:8'd32;
 wire [5:0] last_ib=stage==0?6'd42:stage==1||stage==6||stage==7?6'd21:stage==8?6'd63:6'd10;
 wire [2:0] last_ob=stage==0||stage==8?3'd7:stage==7?3'd3:3'd1;
 wire [1:0] active_ci=ib!=last_ib?2'd3:stage==1||stage==6||stage==7?2'd1:stage==8?2'd3:2'd2;
 wire [14:0] source_base=stage==0||stage==7||stage==8?15'd0:stage==1||stage==6?15'd4300:stage==2?15'd8600:stage==3||stage==5?15'd9700:15'd10800;
 wire [14:0] destination_base=stage==0?15'd4300:stage==1||stage==5||stage==8?15'd8600:stage==2||stage==4?15'd9700:stage==3?15'd10800:stage==6?15'd11900:15'd13000;
 wire rotated=stage==1||stage==6;
 wire [13:0] block_weight_words=stage==0?14'd688:stage==1||stage==6||stage==7?14'd352:stage==8?14'd1024:14'd1584;
 wire [14:0] stage_weight_words=stage==0?15'd11008:stage==1||stage==6?15'd1408:stage==7?15'd2816:stage==8?15'd16384:15'd6336;
 wire signed [6:0] sy=$signed({2'd0,row})+$signed({4'd0,py})-(k3?7'sd1:7'sd0);
 wire [4:0] sx=k3?px-1:px;
 wire pad=k3&&(px==0||px==21||sy<0||sy>=20);
 wire [8:0] last_patch=k3?9'd131:9'd79;
 wire cb,cd,ce,qr,qv,ql;wire [31:0] cc;wire [767:0] data;wire [7:0] q;
 wire [31:0] mq[0:2];
 generate for(genvar b=0;b<3;b=b+1)begin: values
  assign mq[b]=feature_response[b*32+:32];
 end endgenerate
 wire [7:0] a0=rotated?mq[1][sx[1:0]*8+:8]:mq[0][sx[1:0]*8+:8];
 wire [7:0] a1=rotated?mq[2][sx[1:0]*8+:8]:mq[1][sx[1:0]*8+:8];
 wire [7:0] a2=rotated?mq[0][sx[1:0]*8+:8]:mq[2][sx[1:0]*8+:8];
 wire [47:0] triplet={{8{a2[7]}},a2,{8{a1[7]}},a1,{8{a0[7]}},a0};
 wire [6:0] coefficient_index={ob,4'd0}+{3'd0,read_oc};
 assign compute_core_command={aresetn,state==START,k3?2'd3:2'd1,2'd1,active_ci,5'd16,8'd20,3'd4,ib==0,
  32'h12000000|({28'd0,stage}<<16)|({29'd0,ob}<<8)|{27'd0,row},
  state==PS,{3'd0,patch_index},pad_q?48'd0:triplet,state==WS,wo,wt,weight_response,state==FUSE&&!read_done&&qr,{3'd0,pixel}};
 assign compute_tail_command={aresetn,state==FUSE&&read_valid,1'b1,data[read_oc*48+:48],bias[coefficient_index],multiplier[coefficient_index],shift[coefficient_index],1'b1,read_last};
 assign {cb,cd,ce,cc,data}=external_core_response;assign {qr,qv,ql,q}=external_tail_response;
 reg [191:0] feature_request;wire [191:0] feature_next;reg [77:0] weight_request;
 assign feature_command=feature_request;assign weight_command=weight_request;
 always @(posedge aclk)begin
  if(!aresetn)begin feature_request<=0;weight_request<=0;end
  else begin
   feature_request<=feature_next;
   weight_request<={state==WEIGHTS&&s_axis_tvalid&&s_axis_tready&&count[0],count[14:1],s_axis_tdata[15:0],low_word,state==WR,weight_base+{6'd0,wi}};
  end
 end
 reg [2:0] bridge_kind;reg [7:0] bridge_channel;reg [6:0] bridge_word_index;
 reg [1:0] ba_bank,bb_bank,bd_bank,bridge_lane;reg [5:0] ba_group,bb_group,bd_group;
 reg [14:0] ba_base,bb_base,bd_base,ba_addr,bb_addr,bd_addr;
 reg [31:0] bridge_ma,bridge_mb,word_a,word_b,bridge_word;reg [7:0] rounded_byte;
 reg signed [8:0] scale_value;reg [31:0] scale_multiplier;
 (* use_dsp="yes" *) reg signed [41:0] product;
 reg signed [41:0] product_a;reg signed [47:0] sum;
 wire [7:0] local_channel=bridge_kind==2&&bridge_channel>=32?bridge_channel-8'd32:bridge_kind==3&&bridge_channel>=128?bridge_channel-8'd128:bridge_channel;
 wire [7:0] bridge_last=bridge_kind<2?8'd31:bridge_kind==2?8'd63:bridge_kind==3?8'd191:8'd127;
 function [7:0] rounded;
  input signed [47:0] v;reg [47:0] mag,vv;begin
   mag=v<0?-v:v;vv=mag>>24;
   if(mag[23:0]>24'h800000||(mag[23:0]==24'h800000&&vv[0]))vv=vv+1;
   if(v<0)rounded=vv>=128?8'h80:-vv[7:0];else rounded=vv>127?8'd127:vv[7:0];
  end
 endfunction
 reg [1:0] skip_bank;reg [5:0] skip_group;reg [6:0] skip_channel,skip_word;
 reg [31:0] skip_data;
 generate for(genvar b=0;b<3;b=b+1)begin: banks
  wire [14:0] readaddr=state==BR0?ba_addr:state==BRB0?bb_addr:state==SK0?{9'd0,skip_group}*15'd100+{8'd0,skip_word}:
   source_base+({9'd0,ib}+(rotated?15'd21:15'd0)+(rotated&&b==0?15'd1:15'd0))*15'd100+{8'd0,sy[6:0]}*15'd5+{12'd0,sx[4:2]};
  wire re=state==PR&&!pad||(state==BR0&&ba_bank==b)||(state==BRB0&&bb_bank==b)||(state==SK0&&skip_bank==b);
  wire fw=state==FUSE&&qv&&lane==3&&out_bank==b;
  wire iw=state==INPUT&&s_axis_tvalid&&s_axis_tready&&fill_bank==b;
  wire bw=state==BWRITE&&bd_bank==b;
  wire [14:0] address=iw?{9'd0,fill_group}*15'd100+{12'd0,fill_stripe}*15'd20+{10'd0,fill_word}:bw?bd_addr:
   destination_base+{9'd0,out_group}*15'd100+{10'd0,row}*15'd5+{10'd0,save_word};
  wire [31:0] wd=iw?s_axis_tdata:bw?bridge_word:{q,pack_word[23:0]};
  assign feature_next[b*64+:64]={iw||fw||bw,address,wd,re,readaddr};
 end endgenerate
 assign s_axis_tready=aresetn&&(state==HEAD||state==META||state==INPUT||state==LHEAD||state==COEFF||state==WEIGHTS||state==DROP);
 assign m_axis_tkeep=15;
 assign m_axis_tvalid=aresetn&&(state==ACK||state==REPORT||state==SKHEAD||state==SKSEND||state==SKFOOT);
 always @*begin
  m_axis_tdata=0;m_axis_tlast=0;
  if(state==ACK||state==REPORT&&ri<8||state==SKHEAD)begin
   case(ri)0:m_axis_tdata=32'h59323652;1:m_axis_tdata=h[1];2:m_axis_tdata=h[2];3:m_axis_tdata=status;
    4:m_axis_tdata=state==ACK?0:32'h140014;5:m_axis_tdata=state==ACK?0:128;6:m_axis_tdata=state==ACK?0:state==SKHEAD?12808:16;default:m_axis_tdata=0;endcase
   m_axis_tlast=state==ACK&&ri==7;
  end else if(state==REPORT)begin
   case(ri)8:m_axis_tdata=status;9:m_axis_tdata=job_cycles;10:m_axis_tdata=core_cycles;11:m_axis_tdata=feed_cycles;12:m_axis_tdata=fusion_cycles;13:m_axis_tdata=bridge_cycles;23:m_axis_tdata=1;default:m_axis_tdata=stage_cycles[ri-14];endcase
   m_axis_tlast=ri==23;
  end else if(state==SKSEND)m_axis_tdata=skip_data;
  else if(state==SKFOOT)begin m_axis_tdata=ri==1?12800:0;m_axis_tlast=ri==7;end
 end
 integer i;
 always @(posedge aclk)begin
  if(!aresetn)begin
   state<=HEAD;hi<=0;ri<=0;bad<=0;header_last<=0;packet_ended<=0;job_active<=0;status<=0;count<=0;body_count<=0;low_word<=0;stage<=0;completed<=0;
   job_cycles<=0;core_cycles<=0;feed_cycles<=0;fusion_cycles<=0;bridge_cycles<=0;ob<=0;ib<=0;row<=0;wi<=0;wo<=0;wt<=0;weight_base<=0;ob_weight_base<=0;px<=0;py<=0;patch_index<=0;pad_q<=0;
   oc<=0;read_oc<=0;pixel<=0;read_done<=0;read_valid<=0;read_last<=0;lane<=0;out_bank<=0;out_bank_base<=0;out_group<=0;out_group_base<=0;save_word<=0;pack_word<=0;drain<=0;
   fill_ob<=0;fill_stripe<=0;fill_ch<=0;fill_word<=0;fill_bank<=0;fill_group<=0;fill_bank_base<=0;fill_group_base<=0;
   bridge_kind<=0;bridge_channel<=0;bridge_word_index<=0;ba_bank<=0;bb_bank<=0;bd_bank<=0;ba_group<=0;bb_group<=0;bd_group<=0;ba_base<=0;bb_base<=0;bd_base<=0;ba_addr<=0;bb_addr<=0;bd_addr<=0;bridge_lane<=0;
   bridge_ma<=0;bridge_mb<=0;word_a<=0;word_b<=0;bridge_word<=0;rounded_byte<=0;scale_value<=0;scale_multiplier<=0;product<=0;product_a<=0;sum<=0;skip_bank<=0;skip_group<=0;skip_channel<=0;skip_word<=0;skip_data<=0;
   for(i=0;i<8;i=i+1)begin h[i]<=0;lh[i]<=0;ratios[i]<=0;end
   for(i=0;i<9;i=i+1)stage_cycles[i]<=0;
  end else begin
   completed<=0;
   if(job_active)job_cycles<=job_cycles+1;
   if(state>=WR&&state<=D1)feed_cycles<=feed_cycles+1;
   if(state==FUSE)fusion_cycles<=fusion_cycles+1;
   if(state>=BSET&&state<=BNEXT||state==BADDR)bridge_cycles<=bridge_cycles+1;
   if(s_axis_tvalid&&s_axis_tready&&state!=HEAD&&state!=DROP)begin body_count<=body_count+1;if(s_axis_tlast)packet_ended<=1;end
   if(state==WEIGHTS&&s_axis_tvalid&&s_axis_tready&&!count[0])low_word<=s_axis_tdata;
   if(state==COEFF&&s_axis_tvalid&&s_axis_tready)begin
    case(count[1:0])0:multiplier[count[8:2]]<=s_axis_tdata;1:shift[count[8:2]]<=s_axis_tdata[4:0];2:bias[count[8:2]][31:0]<=s_axis_tdata;3:bias[count[8:2]][47:32]<=s_axis_tdata[15:0];endcase
   end
   case(state)
    HEAD:if(s_axis_tvalid&&s_axis_tready)begin
     h[hi]<=s_axis_tdata;if(hi==0)bad<=s_axis_tkeep!=15;else if(s_axis_tkeep!=15)bad<=1;header_last<=s_axis_tlast;
     if(s_axis_tlast&&hi!=7)begin hi<=0;ri<=0;status<=2;state<=ACK;end else if(hi==7)begin hi<=0;state<=CHECK;end else hi<=hi+1;
    end
    CHECK:begin
     status<=0;ri<=0;count<=0;body_count<=0;packet_ended<=0;
     if(bad||h[0]!=32'h59323643)begin status<=1;state<=header_last?ACK:DROP;end
     else if(h[1]==32'h10062&&resident_ready&&header_last&&h[4]==32'h140014&&h[5]==128&&h[6]==0&&h[7]==12816)begin skip_bank<=0;skip_group<=0;skip_channel<=0;skip_word<=0;state<=SKHEAD;end
     else if((h[1]==32'h10060||h[1]==32'h10061&&input_ready)&&!header_last&&h[4]==32'h140014&&h[5]==128&&h[6]==(h[1]==32'h10061 ?60500:73300)&&h[7]==24)begin
      stage<=0;job_cycles<=0;core_cycles<=0;feed_cycles<=0;fusion_cycles<=0;bridge_cycles<=0;job_active<=1;
      for(i=0;i<9;i=i+1)stage_cycles[i]<=0;
      state<=META;
     end else begin status<=1;state<=header_last?ACK:DROP;end
    end
    META:if(s_axis_tvalid&&s_axis_tready)begin
     if(count>=4)ratios[count-4]<=s_axis_tdata;
     if(count==0&&s_axis_tdata!=32'h44313250||count==1&&s_axis_tdata!=1||count==2&&s_axis_tdata!=(h[1]==32'h10061 ?0:12800)||count==3&&s_axis_tdata!=9)begin status<=1;state<=DROP;end
     else if(count==11)begin count<=0;fill_ob<=0;fill_stripe<=0;fill_ch<=0;fill_word<=0;fill_bank<=0;fill_group<=0;fill_bank_base<=0;fill_group_base<=0;state<=h[1]==32'h10061 ?LHEAD:INPUT;end else count<=count+1;
    end
    INPUT:if(s_axis_tvalid&&s_axis_tready)begin
     count<=count+1;
     if(fill_word==19)begin
      fill_word<=0;
      if(fill_ch==15)begin
       fill_ch<=0;
       if(fill_stripe==4)begin fill_stripe<=0;fill_ob<=fill_ob+1;fill_bank_base<=fill_bank_base==2?0:fill_bank_base+1;fill_group_base<=fill_group_base+6'd5+(fill_bank_base==2);fill_bank<=fill_bank_base==2?0:fill_bank_base+1;fill_group<=fill_group_base+6'd5+(fill_bank_base==2);end
       else begin fill_stripe<=fill_stripe+1;fill_bank<=fill_bank_base;fill_group<=fill_group_base;end
      end else begin fill_ch<=fill_ch+1;fill_bank<=fill_bank==2?0:fill_bank+1;if(fill_bank==2)fill_group<=fill_group+1;end
     end else fill_word<=fill_word+1;
     if(count==12799)begin count<=0;state<=LHEAD;end
    end
    LHEAD:if(s_axis_tvalid&&s_axis_tready)begin lh[count[2:0]]<=s_axis_tdata;if(count==7)begin count<=0;state<=LCHECK;end else count<=count+1;end
    LCHECK:begin
     if(lh[0]!=stage+12||lh[1]!=ci||lh[2]!=co||lh[3]!=(k3?3:1)||lh[4]!=({24'd0,co}<<2)||lh[5]!=stage_weight_words||lh[6]||lh[7])begin status<=1;state<=DROP;end else state<=COEFF;
    end
    COEFF:if(s_axis_tvalid&&s_axis_tready)begin if(count==({24'd0,co}<<2)-1)begin count<=0;state<=WEIGHTS;end else count<=count+1;end
    WEIGHTS:if(s_axis_tvalid&&s_axis_tready)begin
     if(count==stage_weight_words-1)begin
      count<=0;ob<=0;ib<=0;row<=0;wi<=0;wo<=0;wt<=0;weight_base<=0;ob_weight_base<=0;out_bank_base<=0;out_group_base<=0;state<=WR;
      if(stage==8&&(!s_axis_tlast||body_count!=(h[1]==32'h10061 ?60499:73299)))begin status<=2;state<=s_axis_tlast?ACK:DROP;end
     end else count<=count+1;
    end
    WR:state<=W0;
    W0:state<=WS;
    WS:begin
     if(wi==(k3?143:15))begin px<=0;py<=0;patch_index<=0;state<=PR;end
     else begin wi<=wi+1;if(wt==(k3?8:0))begin wt<=0;wo<=wo+1;end else wt<=wt+1;state<=WR;end
    end
    PR:begin pad_q<=pad;state<=P0;end
    P0:state<=PS;
    PS:begin
     if(patch_index==last_patch)state<=D0;
     else begin patch_index<=patch_index+1;if(px==(k3?21:19))begin px<=0;py<=py+1;end else px<=px+1;state<=PR;end
    end
    D0:state<=D1;
    D1:state<=START;
    START:state<=WAIT;
    WAIT:if(cd)begin
     core_cycles<=core_cycles+cc;stage_cycles[stage]<=stage_cycles[stage]+cc;
     if(ce)begin status<=4;ri<=0;state<=packet_ended?ACK:DROP;end
     else if(ib<last_ib)begin ib<=ib+1;wi<=0;wo<=0;wt<=0;weight_base<=weight_base+(k3?14'd144:14'd16);state<=WR;end
     else begin oc<=0;pixel<=0;read_done<=0;read_valid<=0;read_last<=0;lane<=0;save_word<=0;out_bank<=out_bank_base;out_group<=out_group_base;state<=FUSE;end
    end
    FUSE:begin
     if(qr)begin read_valid<=!read_done;if(!read_done)begin read_oc<=oc;read_last<=oc==15&&pixel==79;if(pixel==79)begin pixel<=0;if(oc==15)read_done<=1;else oc<=oc+1;end else pixel<=pixel+1;end end
     if(qv)begin
      case(lane)0:pack_word[7:0]<=q;1:pack_word[15:8]<=q;2:pack_word[23:16]<=q;default:begin end endcase
      lane<=lane+1;
      if(lane==3)begin if(save_word==19)begin save_word<=0;out_bank<=out_bank==2?0:out_bank+1;if(out_bank==2)out_group<=out_group+1;end else save_word<=save_word+1;end
      if(ql)begin read_valid<=0;drain<=0;state<=FDRAIN;end
     end
    end
    FDRAIN:begin if(drain==2)begin
     if(row<16)begin row<=row+4;ib<=0;wi<=0;wo<=0;wt<=0;weight_base<=ob_weight_base;state<=WR;end
     else if(ob<last_ob)begin ob<=ob+1;row<=0;ib<=0;wi<=0;wo<=0;wt<=0;ob_weight_base<=ob_weight_base+block_weight_words;weight_base<=ob_weight_base+block_weight_words;out_bank_base<=out_bank_base==2?0:out_bank_base+1;out_group_base<=out_group_base+6'd5+(out_bank_base==2);state<=WR;end
     else state<=LNEXT;
    end else drain<=drain+1;end
    LNEXT:begin
     if(stage==3||stage>=5)begin bridge_kind<=stage==3?0:stage==5?1:stage==6?2:stage==7?3:4;bridge_channel<=0;bridge_word_index<=0;state<=BSET;end
     else begin stage<=stage+1;count<=0;state<=LHEAD;end
    end
    BSET:begin
     ba_bank<=local_channel%8'd3;ba_group<=local_channel/8'd3;bb_bank<=bridge_channel%8'd3;bb_group<=bridge_channel/8'd3;bd_bank<=bridge_channel%8'd3;bd_group<=bridge_channel/8'd3;
     ba_base<=bridge_kind==0?15'd8600:bridge_kind==1?15'd10800:bridge_kind==2?(bridge_channel<32?15'd8600:15'd11900):bridge_kind==3?(bridge_channel<128?15'd4300:15'd13000):15'd8600;
     bb_base<=bridge_kind==0?15'd10800:15'd8600;bd_base<=bridge_kind==0?15'd10800:bridge_kind==1?15'd8600:15'd0;
     bridge_ma<=bridge_kind==0?ratios[0]:bridge_kind==1?ratios[2]:bridge_kind==2?(bridge_channel<32?ratios[4]:ratios[5]):bridge_kind==3?(bridge_channel<128?ratios[6]:ratios[7]):32'h1000000;
     bridge_mb<=bridge_kind==0?ratios[1]:bridge_kind==1?ratios[3]:32'd0;bridge_lane<=0;state<=BADDR;
    end
    BADDR:begin ba_addr<=ba_base+{9'd0,ba_group}*15'd100+{8'd0,bridge_word_index};bb_addr<=bb_base+{9'd0,bb_group}*15'd100+{8'd0,bridge_word_index};bd_addr<=bd_base+{9'd0,bd_group}*15'd100+{8'd0,bridge_word_index};state<=BR0;end
    BR0:state<=BR1;
    BR1:state<=BR2;
    BR2:begin word_a<=mq[ba_bank];if(bridge_kind==4)begin bridge_word<=mq[ba_bank];state<=BWRITE;end else state<=bridge_kind<2?BRB0:BM0;end
    BRB0:state<=BRB1;
    BRB1:state<=BRB2;
    BRB2:begin word_b<=mq[bb_bank];state<=BM0;end
    BM0:begin product<=$signed({word_a[bridge_lane*8+7],word_a[bridge_lane*8+:8]})*$signed({1'b0,bridge_ma});state<=BM1;end
    BM1:begin product_a<=product;if(bridge_kind<2)state<=BM2;else begin sum<=product;state<=BSUM;end end
    BM2:begin product<=$signed({word_b[bridge_lane*8+7],word_b[bridge_lane*8+:8]})*$signed({1'b0,bridge_mb});state<=BM3;end
    BM3:begin sum<=$signed(product_a)+$signed(product);state<=BSUM;end
    BSUM:begin rounded_byte<=rounded(sum);state<=BPACK;end
    BPACK:begin bridge_word[bridge_lane*8+:8]<=rounded_byte;if(bridge_lane==3)state<=BWRITE;else begin bridge_lane<=bridge_lane+1;state<=BM0;end end
    BWRITE:state<=BNEXT;
    BNEXT:begin
     if(bridge_word_index==99)begin bridge_word_index<=0;if(bridge_channel==bridge_last)begin if(bridge_kind==4)state<=FINAL;else begin stage<=stage+1;count<=0;state<=LHEAD;end end else begin bridge_channel<=bridge_channel+1;state<=BSET;end end
     else begin bridge_word_index<=bridge_word_index+1;state<=BSET;end
    end
    FINAL:begin job_active<=0;completed<=1;ri<=0;state<=REPORT;end
    ACK:if(m_axis_tready)begin if(ri==7)begin hi<=0;job_active<=0;state<=HEAD;end else ri<=ri+1;end
    REPORT:if(m_axis_tready)begin if(ri==23)begin hi<=0;state<=HEAD;end else ri<=ri+1;end
    DROP:if(s_axis_tvalid&&s_axis_tready&&s_axis_tlast)begin ri<=0;state<=ACK;end
    SKHEAD:if(m_axis_tready)begin if(ri==7)state<=SK0;else ri<=ri+1;end
    SK0:state<=SK1;
    SK1:state<=SK2;
    SK2:begin skip_data<=mq[skip_bank];state<=SKSEND;end
    SKSEND:if(m_axis_tready)begin
     if(skip_word==99)begin skip_word<=0;if(skip_channel==127)begin ri<=0;state<=SKFOOT;end else begin skip_channel<=skip_channel+1;skip_bank<=skip_bank==2?0:skip_bank+1;if(skip_bank==2)skip_group<=skip_group+1;state<=SK0;end end else begin skip_word<=skip_word+1;state<=SK0;end
    end
    SKFOOT:if(m_axis_tready)begin if(ri==7)begin hi<=0;state<=HEAD;end else ri<=ri+1;end
    default:state<=HEAD;
   endcase
   // Early/invalid framing never leaves a partially written tensor valid.
   if(s_axis_tvalid&&s_axis_tready&&(state==META||state==INPUT||state==LHEAD||state==COEFF||state==WEIGHTS))begin
    if(s_axis_tkeep!=15)begin status<=2;ri<=0;state<=s_axis_tlast?ACK:DROP;end
    else if(s_axis_tlast&&!(state==WEIGHTS&&stage==8&&count==stage_weight_words-1&&body_count==(h[1]==32'h10061 ?60499:73299)))begin status<=2;ri<=0;state<=ACK;end
   end
  end
 end
endmodule
