`timescale 1ns/1ps
// One resumable nine-layer task. Arithmetic, weights and feature banks are external.
// START70 imports INT8 once, RUN71 streams output-channel weight blocks,
// READ72 exports C30 only. The 3-lane row-padded view uses <=9090 words/lane.
module y26_axis_block2230(
 input wire aclk,aresetn,input wire input_ready,input wire [31:0] s_axis_tdata,input wire [3:0] s_axis_tkeep,
 input wire s_axis_tlast,s_axis_tvalid,output wire s_axis_tready,
 output reg [31:0] m_axis_tdata,output wire [3:0] m_axis_tkeep,
 output reg m_axis_tlast,output wire m_axis_tvalid,input wire m_axis_tready,
 output wire [185:0] compute_core_command,output wire [137:0] compute_tail_command,
 input wire [802:0] external_core_response,input wire [10:0] external_tail_response,
 output wire [191:0] feature_command,input wire [95:0] feature_response,
 output wire [77:0] weight_command,input wire [47:0] weight_response
);
 localparam HEAD=0,CHECK=1,META=2,INPUT=3,LHEAD=4,LCHECK=5,COEFF=6,WEIGHTS=7,
  WR=8,W0=9,WS=10,PR=11,P0=12,PS=13,D0=14,D1=15,START=16,WAIT=17,FUSE=18,
  FDRAIN=19,LNEXT=20,BSET=21,BADDR=22,BR0=23,BR1=24,BR2=25,BRB0=26,BRB1=27,
  BRB2=28,BM0=29,BM1=30,BM2=31,BM3=32,BSUM=33,BPACK=34,BWRITE=35,BNEXT=36,
  RETURN=37,ACK=38,REPORT=39,DROP=40,SKHEAD=41,SK0=42,SK1=43,SK2=44,SKSEND=45,SKFOOT=46;
 reg [5:0] state;reg [2:0] hi;reg [4:0] ri;reg [31:0] h[0:7],lh[0:7];
 reg header_last,packet_ended,loaded,finished,job_active;reg [31:0] status,count,body_count,low_word;
 reg [3:0] stage,ob;reg [6:0] ib,next_block;reg [3:0] batch_block,row;
 reg [31:0] ratios[0:7],multiplier[0:15];reg [4:0] shift[0:15];reg [47:0] bias[0:15];
 reg [31:0] job_cycles,core_cycles,feed_cycles,fusion_cycles,bridge_cycles,stage_cycles[0:8];
 reg [7:0] wi;reg [3:0] wo,wt;reg [13:0] weight_base;
 reg [3:0] px;reg [2:0] py;reg [6:0] patch_index;reg pad_q;
 reg [3:0] oc,read_oc;reg [6:0] pixel;reg read_done,read_valid,read_last;
 reg [1:0] lane,out_bank,out_bank_base;reg [6:0] out_group,out_group_base;
 reg [3:0] save_x;reg [2:0] save_row;reg [1:0] save_word,drain;reg [31:0] pack_word;
 reg [1:0] fill_bank;reg [14:0] fill_addr;
 wire k3=stage>=2&&stage<=5;
 wire [9:0] ci=stage==0?10'd256:stage==1||stage==6||stage==7?10'd128:stage==8?10'd384:10'd64;
 wire [8:0] co=stage==0||stage==8?9'd256:stage==7?9'd128:9'd64;
 wire [6:0] last_ib=stage==0?7'd85:stage==1||stage==6||stage==7?7'd42:stage==8?7'd127:7'd21;
 wire [3:0] last_ob=stage==0||stage==8?4'd15:stage==7?4'd7:4'd3;
 wire [1:0] active_ci=ib!=last_ib?2'd3:stage==0||stage>=2&&stage<=5?2'd1:stage==8?2'd3:2'd2;
 wire [14:0] source_base=stage==0||stage>=7?15'd0:stage==1||stage==6?15'd2580:stage==2?15'd5160:stage==3||stage==5?15'd5820:15'd6480;
 wire [14:0] destination_base=stage==0?15'd2580:stage==1||stage==5||stage==8?15'd5160:stage==2||stage==4?15'd5820:stage==3?15'd6480:stage==6?15'd7140:15'd7800;
 wire rotated=stage==1||stage==6;
 wire [2:0] stripe_h=row==8?3'd2:3'd4;
 wire [6:0] last_pixel=row==8?7'd19:7'd39;
 wire [6:0] last_patch=k3?(row==8?7'd47:7'd71):(row==8?7'd19:7'd39);
 wire [31:0] block_weight_words=k3?32'd6336:stage==0?32'd2752:stage==8?32'd4096:32'd1376;
 wire signed [6:0] sy=$signed({3'd0,row})+$signed({4'd0,py})-(k3?7'sd1:7'sd0);
 wire [3:0] sx=k3?px-1:px;
 wire pad=k3&&(px==0||px==11||sy<0||sy>=10);
 wire cb,cd,ce,qr,qv,ql;wire [31:0] cc;wire [767:0] data;wire [7:0] q;wire [31:0] mq[0:2];
 generate for(genvar b=0;b<3;b=b+1)begin: values
  assign mq[b]=feature_response[b*32+:32];
 end endgenerate
 wire [7:0] a0=rotated?mq[2][sx[1:0]*8+:8]:mq[0][sx[1:0]*8+:8];
 wire [7:0] a1=rotated?mq[0][sx[1:0]*8+:8]:mq[1][sx[1:0]*8+:8];
 wire [7:0] a2=rotated?mq[1][sx[1:0]*8+:8]:mq[2][sx[1:0]*8+:8];
 wire [47:0] triplet={{8{a2[7]}},a2,{8{a1[7]}},a1,{8{a0[7]}},a0};
 assign compute_core_command={aresetn,state==START,k3?2'd3:2'd1,2'd1,active_ci,5'd16,8'd10,stripe_h,ib==0,
  32'h22000000|({28'd0,stage}<<16)|({28'd0,ob}<<8)|{28'd0,row},
  state==PS,{5'd0,patch_index},pad_q?48'd0:triplet,state==WS,wo,wt,weight_response,state==FUSE&&!read_done&&qr,{3'd0,pixel}};
 assign compute_tail_command={aresetn,state==FUSE&&read_valid,1'b1,data[read_oc*48+:48],bias[read_oc],multiplier[read_oc],shift[read_oc],1'b1,read_last};
 assign {cb,cd,ce,cc,data}=external_core_response;assign {qr,qv,ql,q}=external_tail_response;
 reg [191:0] feature_request;wire [191:0] feature_next;reg [77:0] weight_request;
 assign feature_command=feature_request;assign weight_command=weight_request;
 always @(posedge aclk)begin
  if(!aresetn)begin feature_request<=0;weight_request<=0;end
  else begin
   feature_request<=feature_next;
   weight_request<={state==WEIGHTS&&s_axis_tvalid&&s_axis_tready&&count[0],1'b0,count[13:1],s_axis_tdata[15:0],low_word,state==WR,weight_base+{6'd0,wi}};
  end
 end
 reg [2:0] bridge_kind;reg [8:0] bridge_channel;reg [4:0] bridge_word_index;
 reg [1:0] ba_bank,bb_bank,bd_bank,bridge_lane;reg [6:0] ba_group,bb_group,bd_group;
 reg [14:0] ba_base,bb_base,bd_base,ba_addr,bb_addr,bd_addr;
 reg [31:0] bridge_ma,bridge_mb,word_a,word_b,bridge_word;reg [7:0] rounded_byte;
 (* use_dsp="yes" *) reg signed [41:0] product;
 reg signed [41:0] product_a;reg signed [47:0] sum;
 wire [8:0] local_channel=bridge_kind==2&&bridge_channel>=64?bridge_channel-9'd64:bridge_kind==3&&bridge_channel>=256?bridge_channel-9'd256:bridge_channel;
 wire [8:0] bridge_last=bridge_kind<2?9'd63:bridge_kind==2?9'd127:bridge_kind==3?9'd383:9'd255;
 function [7:0] rounded;
  input signed [47:0] v;reg [47:0] mag,vv;begin
   mag=v<0?-v:v;vv=mag>>24;
   if(mag[23:0]>24'h800000||(mag[23:0]==24'h800000&&vv[0]))vv=vv+1;
   if(v<0)rounded=vv>=128?8'h80:-vv[7:0];else rounded=vv>127?8'd127:vv[7:0];
  end
 endfunction
 reg [1:0] skip_bank;reg [6:0] skip_group;reg [7:0] skip_channel;reg [4:0] skip_word;reg [31:0] skip_data;
 generate for(genvar b=0;b<3;b=b+1)begin: banks
  wire [14:0] readaddr=state==BR0?ba_addr:state==BRB0?bb_addr:state==SK0?{8'd0,skip_group}*15'd30+{10'd0,skip_word}:
   source_base+({8'd0,ib}+(rotated?15'd42:15'd0)+(rotated&&b<2?15'd1:15'd0))*15'd30+{8'd0,sy[6:0]}*15'd3+{13'd0,sx[3:2]};
  wire re=state==PR&&!pad||(state==BR0&&ba_bank==b)||(state==BRB0&&bb_bank==b)||(state==SK0&&skip_bank==b);
  wire fw=state==FUSE&&qv&&(lane==3||save_x==9)&&out_bank==b;
  wire iw=state==INPUT&&s_axis_tvalid&&s_axis_tready&&fill_bank==b;
  wire bw=state==BWRITE&&bd_bank==b;
  wire [14:0] address=iw?fill_addr:bw?bd_addr:destination_base+{8'd0,out_group}*15'd30+({11'd0,row}+{12'd0,save_row})*15'd3+{13'd0,save_word};
  wire [31:0] wd=iw?s_axis_tdata:bw?bridge_word:save_x==9?{16'd0,q,pack_word[7:0]}:{q,pack_word[23:0]};
  assign feature_next[b*64+:64]={iw||fw||bw,address,wd,re,readaddr};
 end endgenerate
 assign s_axis_tready=aresetn&&(state==HEAD||state==META||state==INPUT||state==LHEAD||state==COEFF||state==WEIGHTS||state==DROP);
 assign m_axis_tkeep=15;
 assign m_axis_tvalid=aresetn&&(state==ACK||state==REPORT||state==SKHEAD||state==SKSEND||state==SKFOOT);
 always @*begin
  m_axis_tdata=0;m_axis_tlast=0;
  if(state==ACK||state==REPORT&&ri<8||state==SKHEAD)begin
   case(ri)0:m_axis_tdata=32'h59323652;1:m_axis_tdata=h[1];2:m_axis_tdata=h[2];3:m_axis_tdata=status;
    4:m_axis_tdata=state==ACK?0:32'ha000a;5:m_axis_tdata=state==ACK?0:256;6:m_axis_tdata=state==ACK?0:state==SKHEAD?7688:16;default:m_axis_tdata=0;endcase
   m_axis_tlast=state==ACK&&ri==7;
  end else if(state==REPORT)begin
   case(ri)8:m_axis_tdata=status;9:m_axis_tdata=job_cycles;10:m_axis_tdata=core_cycles;11:m_axis_tdata=feed_cycles;12:m_axis_tdata=fusion_cycles;13:m_axis_tdata=bridge_cycles;23:m_axis_tdata={31'd0,finished};default:m_axis_tdata=stage_cycles[ri-14];endcase
   m_axis_tlast=ri==23;
  end else if(state==SKSEND)m_axis_tdata=skip_data;
  else if(state==SKFOOT)begin m_axis_tdata=ri==1?7680:0;m_axis_tlast=ri==7;end
 end
 integer i;
 always @(posedge aclk)begin
  if(!aresetn)begin
   state<=HEAD;hi<=0;ri<=0;header_last<=0;packet_ended<=0;loaded<=0;finished<=0;job_active<=0;status<=0;count<=0;body_count<=0;low_word<=0;
   stage<=0;ob<=0;ib<=0;next_block<=0;batch_block<=0;row<=0;wi<=0;wo<=0;wt<=0;weight_base<=0;px<=0;py<=0;patch_index<=0;pad_q<=0;
   job_cycles<=0;core_cycles<=0;feed_cycles<=0;fusion_cycles<=0;bridge_cycles<=0;
   oc<=0;read_oc<=0;pixel<=0;read_done<=0;read_valid<=0;read_last<=0;lane<=0;out_bank<=0;out_bank_base<=0;out_group<=0;out_group_base<=0;
   save_x<=0;save_row<=0;save_word<=0;drain<=0;pack_word<=0;fill_bank<=0;fill_addr<=0;
   bridge_kind<=0;bridge_channel<=0;bridge_word_index<=0;ba_bank<=0;bb_bank<=0;bd_bank<=0;bridge_lane<=0;ba_group<=0;bb_group<=0;bd_group<=0;
   ba_base<=0;bb_base<=0;bd_base<=0;ba_addr<=0;bb_addr<=0;bd_addr<=0;bridge_ma<=0;bridge_mb<=0;word_a<=0;word_b<=0;bridge_word<=0;rounded_byte<=0;product<=0;product_a<=0;sum<=0;
   skip_bank<=0;skip_group<=0;skip_channel<=0;skip_word<=0;skip_data<=0;
   for(i=0;i<8;i=i+1)begin h[i]<=0;lh[i]<=0;ratios[i]<=0;end
   for(i=0;i<9;i=i+1)stage_cycles[i]<=0;
  end else begin
   if(job_active)job_cycles<=job_cycles+1;
   if(state>=WR&&state<=D1)feed_cycles<=feed_cycles+1;
   if(state==FUSE)fusion_cycles<=fusion_cycles+1;
   if(state>=BSET&&state<=BNEXT)bridge_cycles<=bridge_cycles+1;
   if(s_axis_tvalid&&s_axis_tready&&state!=HEAD&&state!=DROP)begin body_count<=body_count+1;if(s_axis_tlast)packet_ended<=1;end
   if(state==WEIGHTS&&s_axis_tvalid&&s_axis_tready&&!count[0])low_word<=s_axis_tdata;
   if(state==COEFF&&s_axis_tvalid&&s_axis_tready)begin
    case(count[1:0])0:multiplier[count[5:2]]<=s_axis_tdata;1:shift[count[5:2]]<=s_axis_tdata[4:0];2:bias[count[5:2]][31:0]<=s_axis_tdata;3:bias[count[5:2]][47:32]<=s_axis_tdata[15:0];endcase
   end
   case(state)
    HEAD:if(s_axis_tvalid&&s_axis_tready)begin
     h[hi]<=s_axis_tdata;
     if(hi==0)begin status<=s_axis_tkeep==15?0:2;packet_ended<=0;body_count<=0;end
     else if(s_axis_tkeep!=15)status<=2;
     if(hi==7)begin hi<=0;header_last<=s_axis_tlast;state<=CHECK;end
     else if(s_axis_tlast)begin hi<=0;status<=2;header_last<=1;ri<=0;state<=ACK;loaded<=0;finished<=0;end
     else hi<=hi+1;
    end
    CHECK:begin
     ri<=0;count<=0;batch_block<=0;
     if(status||h[0]!=32'h59323643||h[4]!=32'ha000a)begin status<=1;loaded<=0;finished<=0;state<=header_last?ACK:DROP;end
     else if((h[1]==32'h10070||h[1]==32'h10073&&input_ready)&&h[3]==0&&h[5]==256&&h[6]==(h[1]==32'h10073 ?8:7748)&&h[7]==8&&!header_last)begin
      loaded<=0;finished<=0;stage<=0;ob<=0;next_block<=0;fill_bank<=0;fill_addr<=0;
      job_cycles<=0;core_cycles<=0;feed_cycles<=0;fusion_cycles<=0;bridge_cycles<=0;for(i=0;i<9;i=i+1)stage_cycles[i]<=0;
      job_active<=1;state<=META;
     end else if(h[1]==32'h10071&&loaded&&!finished&&h[3]=={25'd0,next_block}&&h[5]>=1&&h[5]<=8&&h[3]+h[5]<=64&&h[7]==24&&!header_last)begin job_active<=1;state<=LHEAD;end
     else if(h[1]==32'h10072&&finished&&h[3]==0&&h[5]==256&&h[6]==0&&h[7]==7696&&header_last)begin skip_channel<=0;skip_bank<=0;skip_group<=0;skip_word<=0;state<=SKHEAD;end
     else begin status<=1;loaded<=0;finished<=0;state<=header_last?ACK:DROP;end
    end
    META:if(s_axis_tvalid&&s_axis_tready)begin ratios[count[2:0]]<=s_axis_tdata;if(count==7)begin count<=0;if(h[1]==32'h10073)begin loaded<=1;job_active<=0;ri<=0;state<=ACK;end else state<=INPUT;end else count<=count+1;end
    INPUT:if(s_axis_tvalid&&s_axis_tready)begin
     if(fill_bank==2)begin fill_bank<=0;fill_addr<=fill_addr+1;end else fill_bank<=fill_bank+1;
     if(count==7739)begin loaded<=1;job_active<=0;count<=0;ri<=0;state<=ACK;end else count<=count+1;
    end
    LHEAD:if(s_axis_tvalid&&s_axis_tready)begin lh[count[2:0]]<=s_axis_tdata;if(count==7)begin count<=0;state<=LCHECK;end else count<=count+1;end
    LCHECK:begin
     if(lh[0]!=stage+22||lh[1]!={22'd0,ci}||lh[2]!={23'd0,co}||lh[3]!=(k3?3:1)||lh[4]!={28'd0,ob}||lh[5]!=64||lh[6]!=block_weight_words||lh[7])begin status<=1;loaded<=0;finished<=0;state<=packet_ended?ACK:DROP;end
     else begin out_bank_base<=({28'd0,ob}*16)%3;out_group_base<=({28'd0,ob}*16)/3;state<=COEFF;end
    end
    COEFF:if(s_axis_tvalid&&s_axis_tready)begin if(count==63)begin count<=0;state<=WEIGHTS;end else count<=count+1;end
    WEIGHTS:if(s_axis_tvalid&&s_axis_tready)begin
     if(count==block_weight_words-1)begin count<=0;row<=0;ib<=0;wi<=0;wo<=0;wt<=0;weight_base<=0;state<=WR;end else count<=count+1;
    end
    WR:state<=W0;
    W0:state<=WS;
    WS:begin if(wi==(k3?143:15))begin px<=0;py<=0;patch_index<=0;state<=PR;end else begin wi<=wi+1;if(wt==(k3?8:0))begin wt<=0;wo<=wo+1;end else wt<=wt+1;state<=WR;end end
    PR:begin pad_q<=pad;state<=P0;end
    P0:state<=PS;
    PS:begin if(patch_index==last_patch)state<=D0;else begin patch_index<=patch_index+1;if(px==(k3?11:9))begin px<=0;py<=py+1;end else px<=px+1;state<=PR;end end
    D0:state<=D1;
    D1:state<=START;
    START:state<=WAIT;
    WAIT:if(cd)begin
     core_cycles<=core_cycles+cc;stage_cycles[stage]<=stage_cycles[stage]+cc;
     if(ce)begin status<=4;loaded<=0;finished<=0;job_active<=0;ri<=0;state<=packet_ended?ACK:DROP;end
     else if(ib<last_ib)begin ib<=ib+1;wi<=0;wo<=0;wt<=0;weight_base<=weight_base+(k3?14'd144:14'd16);state<=WR;end
     else begin oc<=0;pixel<=0;read_done<=0;read_valid<=0;read_last<=0;lane<=0;save_x<=0;save_row<=0;save_word<=0;pack_word<=0;out_bank<=out_bank_base;out_group<=out_group_base;state<=FUSE;end
    end
    FUSE:begin
     if(qr)begin read_valid<=!read_done;if(!read_done)begin read_oc<=oc;read_last<=oc==15&&pixel==last_pixel;if(pixel==last_pixel)begin pixel<=0;if(oc==15)read_done<=1;else oc<=oc+1;end else pixel<=pixel+1;end end
     if(qv)begin
      case(lane)0:pack_word[7:0]<=q;1:pack_word[15:8]<=q;2:pack_word[23:16]<=q;default:begin end endcase
      if(save_x==9)begin
       lane<=0;save_x<=0;save_word<=0;pack_word<=0;
       if(save_row==stripe_h-1)begin save_row<=0;out_bank<=out_bank==2?0:out_bank+1;if(out_bank==2)out_group<=out_group+1;end else save_row<=save_row+1;
      end else begin save_x<=save_x+1;lane<=lane+1;if(lane==3)save_word<=save_word+1;end
      if(ql)begin read_valid<=0;drain<=0;state<=FDRAIN;end
     end
    end
    FDRAIN:if(drain==2)begin
     if(row<8)begin row<=row+4;ib<=0;wi<=0;wo<=0;wt<=0;weight_base<=0;state<=WR;end else state<=LNEXT;
    end else drain<=drain+1;
    LNEXT:begin
     next_block<=next_block+1;
     if(ob<last_ob)begin ob<=ob+1;state<=RETURN;end
     else if(stage==3||stage>=5)begin bridge_kind<=stage==3?0:stage==5?1:stage==6?2:stage==7?3:4;bridge_channel<=0;bridge_word_index<=0;state<=BSET;end
     else begin stage<=stage+1;ob<=0;state<=RETURN;end
    end
    BSET:begin
     ba_bank<=local_channel%9'd3;ba_group<=local_channel/9'd3;bb_bank<=bridge_channel%9'd3;bb_group<=bridge_channel/9'd3;bd_bank<=bridge_channel%9'd3;bd_group<=bridge_channel/9'd3;
     ba_base<=bridge_kind==0?15'd5160:bridge_kind==1?15'd6480:bridge_kind==2?(bridge_channel<64?15'd5160:15'd7140):bridge_kind==3?(bridge_channel<256?15'd2580:15'd7800):15'd5160;
     bb_base<=bridge_kind==0?15'd6480:15'd5160;bd_base<=bridge_kind==0?15'd6480:bridge_kind==1?15'd5160:15'd0;
     bridge_ma<=bridge_kind==0?ratios[0]:bridge_kind==1?ratios[2]:bridge_kind==2?(bridge_channel<64?ratios[4]:ratios[5]):bridge_kind==3?(bridge_channel<256?ratios[6]:ratios[7]):32'h1000000;
     bridge_mb<=bridge_kind==0?ratios[1]:bridge_kind==1?ratios[3]:32'd0;bridge_lane<=0;state<=BADDR;
    end
    BADDR:begin ba_addr<=ba_base+{8'd0,ba_group}*15'd30+{10'd0,bridge_word_index};bb_addr<=bb_base+{8'd0,bb_group}*15'd30+{10'd0,bridge_word_index};bd_addr<=bd_base+{8'd0,bd_group}*15'd30+{10'd0,bridge_word_index};state<=BR0;end
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
     if(bridge_word_index==29)begin bridge_word_index<=0;if(bridge_channel==bridge_last)begin
      if(bridge_kind==4)begin finished<=1;stage<=9;end else stage<=stage+1;
      ob<=0;state<=RETURN;
     end else begin bridge_channel<=bridge_channel+1;state<=BSET;end end
     else begin bridge_word_index<=bridge_word_index+1;state<=BSET;end
    end
    RETURN:begin count<=0;if(batch_block==h[5]-1)begin ri<=0;job_active<=0;state<=REPORT;end else begin batch_block<=batch_block+1;state<=LHEAD;end end
    ACK:if(m_axis_tready)begin if(ri==7)begin hi<=0;job_active<=0;state<=HEAD;end else ri<=ri+1;end
    REPORT:if(m_axis_tready)begin if(ri==23)begin hi<=0;state<=HEAD;end else ri<=ri+1;end
    DROP:if(s_axis_tvalid&&s_axis_tready&&s_axis_tlast)begin ri<=0;job_active<=0;state<=ACK;end
    SKHEAD:if(m_axis_tready)begin if(ri==7)state<=SK0;else ri<=ri+1;end
    SK0:state<=SK1;
    SK1:state<=SK2;
    SK2:begin skip_data<=mq[skip_bank];state<=SKSEND;end
    SKSEND:if(m_axis_tready)begin
     if(skip_word==29)begin skip_word<=0;if(skip_channel==255)begin ri<=0;state<=SKFOOT;end else begin skip_channel<=skip_channel+1;skip_bank<=skip_bank==2?0:skip_bank+1;if(skip_bank==2)skip_group<=skip_group+1;state<=SK0;end end
     else begin skip_word<=skip_word+1;state<=SK0;end
    end
    SKFOOT:if(m_axis_tready)begin if(ri==7)begin hi<=0;state<=HEAD;end else ri<=ri+1;end
    default:state<=HEAD;
   endcase
   // Exact packet ends are checked before consuming the next descriptor or committing a task.
   if(s_axis_tvalid&&s_axis_tready&&(state==META||state==INPUT||state==LHEAD||state==COEFF||state==WEIGHTS))begin
    if(s_axis_tkeep!=15||s_axis_tlast&&!(state==META&&count==7&&h[1]==32'h10073||state==INPUT&&count==7739||state==WEIGHTS&&count==block_weight_words-1&&batch_block==h[5]-1&&body_count==h[6]-1))begin
     status<=2;loaded<=0;finished<=0;job_active<=0;ri<=0;state<=s_axis_tlast?ACK:DROP;
    end else if((state==INPUT&&count==7739||state==WEIGHTS&&count==block_weight_words-1&&batch_block==h[5]-1)&&!s_axis_tlast)begin
     status<=2;loaded<=0;finished<=0;job_active<=0;ri<=0;state<=DROP;
    end
   end
  end
 end
endmodule
