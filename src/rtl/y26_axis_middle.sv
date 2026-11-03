`timescale 1ns/1ps
// One PE, C7/C8/C9/C10 sequential stripe schedule. All intermediate tensors
// remain in resident memory. C10 overwrites C6 only after C7 consumes the rows.
module y26_axis_middle(
 input wire aclk,aresetn,input wire resident_ready,input wire input_ready,
 input wire [31:0] s_axis_tdata,input wire [3:0] s_axis_tkeep,
 input wire s_axis_tlast,s_axis_tvalid,output wire s_axis_tready,
 output reg [31:0] m_axis_tdata,output wire [3:0] m_axis_tkeep,
 output reg m_axis_tlast,output wire m_axis_tvalid,input wire m_axis_tready,
 output wire [185:0] compute_core_command,output wire [137:0] compute_tail_command,
 input wire [802:0] external_core_response,input wire [10:0] external_tail_response,
 output wire [767:0] feature_command,input wire [383:0] feature_response,
 output wire [77:0] weight_command,input wire [47:0] weight_response,
 output reg completed
);
 localparam HEAD=0,CHECK=1,LOAD=2,DROP=3,ACK=4,WR=5,WS=6,PR=7,PS=8,D0=9,D1=10,
  START=11,WAIT=12,FUSE=13,CR=14,CP=15,CS=16,CQ=17,CW=18,FINISH=19,
  SH=20,SR=21,SS=22,SEND=23,SF=24,W0=25,P0=26,C0=27,CM=28,S0=29;
 reg [4:0] state;reg [2:0] hi;reg [4:0] ri;reg [31:0] h[0:7];reg header_last,bad;
 reg [31:0] status,count,low_word,ma,mb;
 reg [31:0] multiplier[0:239];reg [4:0] shift[0:239];reg [47:0] bias[0:239];
 reg [1:0] stage;reg [5:0] base_row,generated;reg [1:0] block;reg half;
 reg [2:0] ob;reg [5:0] ib;reg [7:0] wi;reg [3:0] wo,wt;
 reg [5:0] px;reg [2:0] py;reg [8:0] patch_index;reg pad_q;
 reg [3:0] oc,read_oc,save_oc;reg [7:0] pixel;reg read_done,read_valid,read_last;
 reg [5:0] save_x;reg [2:0] save_y;reg [1:0] lane;reg [31:0] pack_word;
 reg [6:0] cat_channel;reg [1:0] cat_row;reg [3:0] cat_word;
 reg [6:0] fill_channel,skip_channel;reg [1:0] fill_row;reg [3:0] fill_word;reg [5:0] fill_stripe;
 reg [8:0] skip_word;reg [31:0] skip_data;
 reg [31:0] job_cycles,c7_cycles,c8_cycles,c9_cycles,c10_cycles,feed_cycles,fusion_cycles,cat_cycles;
 wire [5:0] target=base_row<32?base_row+6'd10:6'd40;
 wire [2:0] height=stage==0?(target-generated<4?target-generated:3'd4):stage==1&&block==2?3'd2:3'd4;
 wire k3=stage==1||stage==2;
 wire [5:0] last_ib=stage==0?21:stage==1?10:stage==2?5:31;
 wire [2:0] last_ob=stage==0?3:stage==1?0:stage==2?1:7;
 wire [1:0] ci=ib!=last_ib?3:stage==0?1:stage==1?2:stage==2?1:3;
 wire [8:0] patch_size=(k3?9'd42:9'd40)*(height+(k3?2:0));
 wire [7:0] pixels=height*8'd40;
 wire signed [9:0] sy=stage==0?$signed({4'd0,generated})+$signed({7'd0,py}):
  stage==1?$signed({4'd0,base_row})-10'sd2+$signed({6'd0,block,2'd0})+$signed({7'd0,py}):
  stage==2?$signed({6'd0,block,2'd0})+$signed({7'd0,py}):$signed({7'd0,py});
 wire [5:0] sx=k3?px-1:px;
 wire pad=k3&&(px==0||px==41||(stage==1&&(sy<0||sy>=40)));
 wire [6:0] input_c=ib*7'd3+(stage==1?7'd32:7'd0);
 wire [6:0] global_oc={ob,4'd0}+save_oc;
 wire signed [9:0] output_y=stage==0?$signed({4'd0,generated})+$signed({7'd0,save_y}):
  stage==1?$signed({4'd0,base_row})-10'sd1+$signed({6'd0,block,2'd0})+$signed({7'd0,save_y}):
  $signed({4'd0,base_row})+$signed({6'd0,block,2'd0})+$signed({7'd0,save_y});
 wire [7:0] channel_index=(stage==0?8'd0:stage==1?8'd64:stage==2?8'd80:8'd112)+{ob,4'd0}+read_oc;
 wire cb,cd,ce;wire [31:0] cc;wire [767:0] data;wire qr,qv,ql;wire [7:0] q;
 wire [31:0] mq[0:11];
 generate for(genvar b=0;b<12;b=b+1)begin: read_values
  assign mq[b]=feature_response[b*32+:32];
 end endgenerate
 wire [1:0] rotation=input_c%3;
 wire [7:0] a0=stage==0?mq[0][sx[1:0]*8+:8]:stage==1?mq[3+rotation][sx[1:0]*8+:8]:stage==2?mq[6][sx[1:0]*8+:8]:mq[6][sx[1:0]*8+:8];
 wire [7:0] a1=stage==0?mq[1][sx[1:0]*8+:8]:stage==1?mq[3+(rotation==2?0:rotation+1)][sx[1:0]*8+:8]:mq[7][sx[1:0]*8+:8];
 wire [7:0] a2=stage==0?mq[2][sx[1:0]*8+:8]:stage==1?mq[3+(rotation==0?2:rotation-1)][sx[1:0]*8+:8]:mq[8][sx[1:0]*8+:8];
 wire [47:0] triplet={{8{a2[7]}},a2,{8{a1[7]}},a1,{8{a0[7]}},a0};
 assign compute_core_command={aresetn,state==START,k3?2'd3:2'd1,2'd1,ci,5'd16,8'd40,height,ib==0,
  32'h71000000|({30'd0,stage}<<20)|({26'd0,generated}<<12)|({26'd0,base_row}<<6)|({29'd0,ob}<<3)|{30'd0,block},
  state==PS,{3'd0,patch_index},pad_q?48'd0:triplet,state==WS,wo,wt,weight_response,state==FUSE&&!read_done&&qr,{2'd0,pixel}};
 assign {cb,cd,ce,cc,data}=external_core_response;
 assign compute_tail_command={aresetn,state==FUSE&&read_valid,1'b1,data[read_oc*48+:48],bias[channel_index],multiplier[channel_index],shift[channel_index],1'b1,read_last};
 assign {qr,qv,ql,q}=external_tail_response;
 wire [7:0] stored_q=stage==1&&(output_y<0||output_y>=40)?8'd0:q;
 wire [13:0] wa=stage==0?{12'd0,ob[1:0]}*14'd352+{8'd0,ib}*14'd16+wi:
  stage==1?14'd1408+{8'd0,ib}*14'd144+wi:
  stage==2?14'd2992+{13'd0,ob[0]}*14'd864+{8'd0,ib}*14'd144+wi:
  14'd4720+{11'd0,ob}*14'd512+{8'd0,ib}*14'd16+wi;
 wire cfg_write=state==LOAD&&s_axis_tvalid&&s_axis_tready;
 wire [31:0] weight_index=(count-968)>>1;
 reg [77:0] weight_request;reg [767:0] feature_request;
 wire [767:0] feature_next;
 assign weight_command=weight_request;assign feature_command=feature_request;
 always @(posedge aclk)begin
  if(!aresetn)begin weight_request<=0;feature_request<=0;end
  else begin
   weight_request<={cfg_write&&count>=968&&count<18600&&count[0],weight_index[13:0],s_axis_tdata[15:0],low_word,state==WR,wa};
   feature_request<=feature_next;
  end
 end
 wire [14:0] load_address=(fill_channel/3)*15'd400+(fill_stripe+fill_row)*15'd10+fill_word;
 wire [6:0] cat_pc=cat_channel<64?cat_channel:7'd32+(cat_channel-64);
 wire [4:0] cat_rc=cat_channel-64;
 wire [14:0] cat_paddr=(cat_pc/3)*15'd160+((base_row+{5'd0,half,2'd0}+cat_row)&15)*15'd10+cat_word;
 wire [14:0] cat_raddr=(cat_rc/3)*15'd80+({5'd0,half,2'd0}+cat_row)*15'd10+cat_word;
 wire [14:0] cat_waddr=(cat_channel/3)*15'd40+cat_row*15'd10+cat_word;
 reg signed [40:0] pa[0:3],pb[0:3];reg signed [47:0] sums[0:3];reg [31:0] cat_data,cat_a_word,cat_b_word;
 function [7:0] rounded;
  input signed [47:0] v;reg [47:0] mag,vv;begin
   mag=v<0?-v:v;vv=mag>>24;
   if(mag[23:0]>24'h800000||(mag[23:0]==24'h800000&&vv[0]))vv=vv+1;
   if(v<0)rounded=vv>=128?8'h80:-vv[7:0];else rounded=vv>127?8'd127:vv[7:0];
  end
 endfunction
 generate for(genvar b=0;b<12;b=b+1)begin: banks
  localparam BANK=b%3;
  wire [6:0] ac=input_c+((BANK+3-input_c%3)%3);
  wire [14:0] readaddr=b<3?(state==SR?(skip_channel/3)*15'd400+skip_word:ib*15'd400+sy[5:0]*15'd10+sx[5:2]):
   b<6?(state==CR?cat_paddr:(ac/3)*15'd160+sy[3:0]*15'd10+sx[5:2]):
   b<9?ib*(stage==2?15'd100:15'd40)+sy[3:0]*15'd10+sx[5:2]:cat_raddr;
  wire re=b<3?(state==SR&&skip_channel%3==BANK)||(state==PR&&stage==0):
   b<6?state==CR||(state==PR&&stage==1&&!pad):b<9?state==PR&&stage>=2&&!pad:state==CR&&cat_channel>=64;
  wire fw=state==FUSE&&qv&&lane==3&&global_oc%3==BANK;
  wire we=b<3?(cfg_write&&count>=18600&&fill_channel%3==BANK)||(fw&&stage==3):
   b<6?fw&&stage==0:b<9?(fw&&stage==1)||(state==CW&&cat_channel%3==BANK):fw&&stage==2;
  wire [14:0] storeaddr=b<3?(cfg_write?load_address:(global_oc/3)*15'd400+(base_row+{5'd0,half,2'd0}+save_y)*15'd10+save_x[5:2]):
   b<6?(global_oc/3)*15'd160+output_y[3:0]*15'd10+save_x[5:2]:
   b<9?(state==CW?cat_waddr:(global_oc/3)*15'd100+({6'd0,block,2'd0}+save_y)*15'd10+save_x[5:2]):
   (global_oc/3)*15'd80+({6'd0,block,2'd0}+save_y)*15'd10+save_x[5:2];
  wire [31:0] wd=cfg_write?s_axis_tdata:state==CW?cat_data:{stored_q,pack_word[23:0]};
  assign feature_next[b*64+:64]={we,storeaddr,wd,re,readaddr};
 end endgenerate
 assign s_axis_tready=aresetn&&(state==HEAD||state==LOAD||state==DROP);
 assign m_axis_tkeep=15;
 assign m_axis_tvalid=aresetn&&(state==ACK||state==FINISH||state==SH||state==SEND||state==SF);
 always @*begin
  m_axis_tdata=0;m_axis_tlast=0;
  if(state==ACK||state==SH||state==FINISH&&ri<8)begin
   case(ri)0:m_axis_tdata=32'h59323652;1:m_axis_tdata=h[1];2:m_axis_tdata=h[2];3:m_axis_tdata=status;
    4:m_axis_tdata=state==ACK?0:32'h280028;5:m_axis_tdata=state==ACK?0:128;
    6:m_axis_tdata=state==ACK?0:state==SH?51208:12;default:m_axis_tdata=0;endcase
   m_axis_tlast=state==ACK&&ri==7;
  end else if(state==FINISH)begin
   case(ri)8:m_axis_tdata=status;9:m_axis_tdata=job_cycles;10:m_axis_tdata=c7_cycles;11:m_axis_tdata=c8_cycles;
    12:m_axis_tdata=c9_cycles;13:m_axis_tdata=c10_cycles;14:m_axis_tdata=feed_cycles;15:m_axis_tdata=fusion_cycles;
    16:m_axis_tdata=25600;17:m_axis_tdata=40;18:m_axis_tdata=1;default:m_axis_tdata=0;endcase
   m_axis_tlast=ri==19;
  end else if(state==SEND)m_axis_tdata=skip_data;
  else if(state==SF)begin m_axis_tdata=ri==1?51200:0;m_axis_tlast=ri==7;end
 end
 integer i;
 always @(posedge aclk)begin
  if(cfg_write)begin
   if(count==2)ma<=s_axis_tdata;if(count==3)mb<=s_axis_tdata;
   if(count>=8&&count<968)begin
    case(count[1:0])0:multiplier[(count-8)>>2]<=s_axis_tdata;1:shift[(count-8)>>2]<=s_axis_tdata[4:0];2:bias[(count-8)>>2][31:0]<=s_axis_tdata;3:bias[(count-8)>>2][47:32]<=s_axis_tdata[15:0];endcase
   end
   if(count>=968&&count<18600&&!count[0])low_word<=s_axis_tdata;
  end
  if(!aresetn)begin
   state<=HEAD;hi<=0;ri<=0;status<=0;count<=0;header_last<=0;bad<=0;completed<=0;
   stage<=0;base_row<=0;generated<=0;block<=0;half<=0;ob<=0;ib<=0;wi<=0;wo<=0;wt<=0;px<=0;py<=0;patch_index<=0;pad_q<=0;
   oc<=0;read_oc<=0;save_oc<=0;pixel<=0;read_done<=0;read_valid<=0;read_last<=0;save_x<=0;save_y<=0;lane<=0;pack_word<=0;
   cat_channel<=0;cat_row<=0;cat_word<=0;fill_channel<=0;fill_row<=0;fill_word<=0;fill_stripe<=0;skip_channel<=0;skip_word<=0;skip_data<=0;
   job_cycles<=0;c7_cycles<=0;c8_cycles<=0;c9_cycles<=0;c10_cycles<=0;feed_cycles<=0;fusion_cycles<=0;cat_cycles<=0;
   for(i=0;i<8;i=i+1)h[i]<=0;
  end else begin
   completed<=0;
   if(state>=WR&&state<=CW||state==W0||state==P0||state==C0||state==CM)job_cycles<=job_cycles+1;
   if(state>=WR&&state<=D1||state==W0||state==P0)feed_cycles<=feed_cycles+1;
   if(state==FUSE)fusion_cycles<=fusion_cycles+1;
   if(state>=CR&&state<=CW||state==C0||state==CM)cat_cycles<=cat_cycles+1;
   case(state)
    HEAD:if(s_axis_tvalid&&s_axis_tready)begin
     h[hi]<=s_axis_tdata;header_last<=s_axis_tlast;
     if(hi==0)bad<=s_axis_tkeep!=15;else if(s_axis_tkeep!=15)bad<=1;
     if(s_axis_tlast&&hi!=7)begin hi<=0;ri<=0;status<=2;state<=ACK;end
     else if(hi==7)begin hi<=0;state<=CHECK;end else hi<=hi+1;
    end
    CHECK:begin
     count<=0;ri<=0;status<=0;
     if(!bad&&h[0]==32'h59323643&&h[1]==32'h10052&&header_last&&h[4]==32'h280028&&h[5]==128&&h[6]==0&&h[7]==51216&&resident_ready)begin skip_channel<=0;skip_word<=0;state<=SH;end
     else if(!bad&&h[0]==32'h59323643&&(h[1]==32'h10050||h[1]==32'h10051&&input_ready)&&!header_last&&h[4]==32'h280028&&h[5]==64&&h[6]==(h[1]==32'h10051 ?18600:44200)&&h[7]==20)begin
      fill_channel<=0;fill_row<=0;fill_word<=0;fill_stripe<=0;state<=LOAD;
     end else begin status<=1;state<=header_last?ACK:DROP;end
    end
    LOAD:if(s_axis_tvalid&&s_axis_tready)begin
     count<=count+1;
     if(s_axis_tkeep!=15)bad<=1;
     if(count>=18600)begin
      if(fill_word==9)begin fill_word<=0;if(fill_row==3)begin fill_row<=0;if(fill_channel==63)begin fill_channel<=0;fill_stripe<=fill_stripe+4;end else fill_channel<=fill_channel+1;end else fill_row<=fill_row+1;end else fill_word<=fill_word+1;
     end
     if(s_axis_tlast)begin
      if(count!=(h[1]==32'h10051 ?18599:44199)||bad||s_axis_tkeep!=15)begin status<=2;state<=ACK;end
      else begin
       state<=WR;stage<=0;base_row<=0;generated<=0;block<=0;half<=0;ob<=0;ib<=0;wi<=0;wo<=0;wt<=0;
       job_cycles<=0;c7_cycles<=0;c8_cycles<=0;c9_cycles<=0;c10_cycles<=0;feed_cycles<=0;fusion_cycles<=0;cat_cycles<=0;
      end
     end
    end
    WR:state<=W0;
    W0:state<=WS;
    WS:begin
     if(wt==(k3?8:0))begin wt<=0;wo<=wo+1;end else wt<=wt+1;
     if(wi==(k3?143:15))begin px<=0;py<=0;patch_index<=0;state<=PR;end else begin wi<=wi+1;state<=WR;end
    end
    PR:begin pad_q<=pad;state<=P0;end
    P0:state<=PS;
    PS:begin
     if(px==(k3?41:39))begin px<=0;py<=py+1;end else px<=px+1;
     if(patch_index==patch_size-1)state<=D0;else begin patch_index<=patch_index+1;state<=PR;end
    end
    D0:state<=D1;
    D1:state<=START;
    START:state<=WAIT;
    WAIT:if(cd)begin
     case(stage)0:c7_cycles<=c7_cycles+cc;1:c8_cycles<=c8_cycles+cc;2:c9_cycles<=c9_cycles+cc;3:c10_cycles<=c10_cycles+cc;endcase
     if(ce)begin status<=4;ri<=0;state<=ACK;end
     else if(ib!=last_ib)begin ib<=ib+1;wi<=0;wo<=0;wt<=0;state<=WR;end
     else begin oc<=0;pixel<=0;read_done<=0;read_valid<=0;read_last<=0;save_oc<=0;save_x<=0;save_y<=0;lane<=0;pack_word<=0;state<=FUSE;end
    end
    FUSE:begin
     if(qr)begin
      read_valid<=!read_done;
      if(!read_done)begin read_oc<=oc;read_last<=oc==15&&pixel==pixels-1;if(pixel==pixels-1)begin pixel<=0;if(oc==15)read_done<=1;else oc<=oc+1;end else pixel<=pixel+1;end
     end
     if(qv)begin
      case(lane)0:pack_word<={24'd0,stored_q};1:pack_word[15:8]<=stored_q;2:pack_word[23:16]<=stored_q;3:pack_word[31:24]<=stored_q;endcase
      lane<=lane+1;
      if(save_x==39)begin save_x<=0;if(save_y==height-1)begin save_y<=0;save_oc<=save_oc+1;end else save_y<=save_y+1;end else save_x<=save_x+1;
      if(ql)begin
       read_valid<=0;ib<=0;wi<=0;wo<=0;wt<=0;state<=WR;
       if(ob!=last_ob)ob<=ob+1;
       else begin
        ob<=0;
        if(stage==0)begin
         generated<=generated+height;
         if(generated+height==target)begin stage<=1;block<=0;end
        end else if(stage==1)begin if(block==2)begin block<=0;stage<=2;end else block<=block+1;end
        else if(stage==2)begin if(block==1)begin block<=0;half<=0;cat_channel<=0;cat_row<=0;cat_word<=0;state<=CR;end else block<=block+1;end
        else begin
         if(!half)begin half<=1;cat_channel<=0;cat_row<=0;cat_word<=0;state<=CR;end
         else if(base_row==32)begin ri<=0;completed<=1;state<=FINISH;end
         else begin base_row<=base_row+8;stage<=0;block<=0;end
        end
       end
      end
     end
    end
    CR:state<=C0;
    C0:state<=CP;
    CP:begin cat_a_word<=mq[3+cat_pc%3];cat_b_word<=mq[9+cat_rc%3];state<=CM;end
    CM:begin
     for(i=0;i<4;i=i+1)begin
      pa[i]<=$signed(cat_a_word[i*8+:8])*$signed({1'b0,ma});
      pb[i]<=cat_channel>=64?$signed(cat_b_word[i*8+:8])*$signed({1'b0,mb}):41'sd0;
     end
     state<=CS;
    end
    CS:begin for(i=0;i<4;i=i+1)sums[i]<=pa[i]+pb[i];state<=CQ;end
    CQ:begin for(i=0;i<4;i=i+1)cat_data[i*8+:8]<=rounded(sums[i]);state<=CW;end
    CW:begin
     if(cat_word==9)begin cat_word<=0;if(cat_row==3)begin cat_row<=0;if(cat_channel==95)begin stage<=3;ob<=0;ib<=0;wi<=0;wo<=0;wt<=0;state<=WR;end else begin cat_channel<=cat_channel+1;state<=CR;end end else begin cat_row<=cat_row+1;state<=CR;end end
     else begin cat_word<=cat_word+1;state<=CR;end
    end
    ACK:if(m_axis_tready)begin if(ri==7)begin state<=HEAD;hi<=0;end else ri<=ri+1;end
    FINISH:if(m_axis_tready)begin if(ri==19)begin state<=HEAD;hi<=0;end else ri<=ri+1;end
    SH:if(m_axis_tready)begin if(ri==7)state<=SR;else ri<=ri+1;end
    SR:state<=S0;
    S0:state<=SS;
    SS:begin skip_data<=mq[skip_channel%3];state<=SEND;end
    SEND:if(m_axis_tready)begin
     if(skip_word==399)begin skip_word<=0;if(skip_channel==127)begin ri<=0;state<=SF;end else begin skip_channel<=skip_channel+1;state<=SR;end end
     else begin skip_word<=skip_word+1;state<=SR;end
    end
    SF:if(m_axis_tready)begin if(ri==7)begin state<=HEAD;hi<=0;end else ri<=ri+1;end
    DROP:if(s_axis_tvalid&&s_axis_tready&&s_axis_tlast)begin ri<=0;state<=ACK;end
    default:state<=HEAD;
   endcase
  end
 end
endmodule
