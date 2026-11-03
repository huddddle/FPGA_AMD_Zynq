`timescale 1ns/1ps
// Capture into proven-dead physical addresses; copy only after the producer ends.
// No RAM here: all data lives in the existing 72-RAMB36 feature pool.
module y26_resident_link(
 input wire aclk,aresetn,input wire [1:0] capture_begin,capture_kind,
 input wire [3:0] capture_block,input wire capture_valid,input wire [31:0] capture_data,
 input wire [31:0] s_axis_tdata,input wire [3:0] s_axis_tkeep,input wire s_axis_tlast,s_axis_tvalid,
 output wire s_axis_tready,output reg [31:0] m_axis_tdata,output wire [3:0] m_axis_tkeep,
 output wire m_axis_tlast,m_axis_tvalid,input wire m_axis_tready,
 output wire memory_we,output wire [5:0] memory_ws,output wire [11:0] memory_wa,output wire [31:0] memory_wd,
 output wire memory_re,output wire [5:0] memory_rs,output wire [11:0] memory_ra,input wire [31:0] memory_rd,
 output reg ready6,ready11,ready21
);
 localparam HEAD=0,CHECK=1,CALC=2,R0=3,R1=4,R2=5,S0=6,S1=7,S2=8,WRITE=9,NEXT=10,DRAIN0=11,DRAIN1=12,ACK=13,DROP=14;
 reg [3:0] state;reg [2:0] hi,ri;reg [31:0] h[0:7],status;reg bad,ended;
 reg [1:0] mode;reg [15:0] index;reg stage6;
 reg [5:0] rs,ws;reg [11:0] ra,wa;reg [31:0] data0,data1,wd;
 reg [8:0] channel;reg [5:0] row;reg [4:0] xword;reg [3:0] stripe;reg [1:0] row4;reg [3:0] ob,local_ch;
 reg [1:0] byte_shift;reg pad_channel;
 reg [5:0] source_slot,staging_slot;reg [11:0] source_address;reg [9:0] staging_address;
 reg [1:0] source_phase,target_lane,block_lane;reg [14:0] target_group,target_stripe,block_group;
 reg [5:0] local_word;reg [15:0] first_base,tail_base;
 reg [14:0] capture_index;reg [5:0] cap_slot;reg [11:0] cap_addr;
 reg [7:0] mask11;reg [15:0] mask21;reg captured6;
 wire [15:0] full_capture=capture_kind==1?{1'b0,capture_index}:capture_kind==2?{12'd0,capture_block}*16'd1600+{1'b0,capture_index}:{12'd0,capture_block}*16'd400+{1'b0,capture_index};
 wire [5:0] capture_slot=capture_kind==1?cap_slot:6'd25+full_capture[15:10];
 wire [11:0] capture_address=capture_kind==1?cap_addr:{2'd0,full_capture[9:0]};
 // Register the producer's stream before broadcasting into the shared banks.
 // Each producer emits a footer after its last data word, so the final capture
 // drains before another owner can issue a memory read or write.
 reg capture_pending;reg [5:0] capture_slot_q;reg [11:0] capture_address_q;reg [31:0] capture_data_q;
 always @(posedge aclk)begin
  if(!aresetn)capture_pending<=0;
  else begin
   capture_pending<=capture_valid;
   if(capture_valid)begin capture_slot_q<=capture_slot;capture_address_q<=capture_address;capture_data_q<=capture_data;end
  end
 end
 assign memory_we=capture_pending||state==WRITE;
 assign memory_ws=capture_pending?capture_slot_q:ws;assign memory_wa=capture_pending?capture_address_q:wa;assign memory_wd=capture_pending?capture_data_q:wd;
 assign memory_re=state==R0||state==S0;assign memory_rs=rs;assign memory_ra=ra;
 assign s_axis_tready=aresetn&&(state==HEAD||state==DROP);assign m_axis_tkeep=15;
 assign m_axis_tvalid=aresetn&&state==ACK;assign m_axis_tlast=state==ACK&&ri==7;
 always @*begin
  m_axis_tdata=0;
  case(ri)0:m_axis_tdata=32'h59323652;1:m_axis_tdata=h[1];2:m_axis_tdata=h[2];3:m_axis_tdata=status;default:m_axis_tdata=0;endcase
 end
 function [17:0] lane_address;
  input [1:0] lane;input [14:0] address;begin lane_address={6'd16+{4'd0,lane}+{3'd0,address[14:12]}*6'd3,address[11:0]};end
 endfunction
 reg [17:0] destination;reg [14:0] addr;reg [15:0] byte_index;
 always @*begin
  addr=target_group+target_stripe+{9'd0,local_word};
  if(mode==2)addr=target_group+{9'd0,row}*15'd3+{10'd0,xword};
  destination=lane_address(target_lane,addr);
  if(mode==0&&!stage6)destination={staging_slot,2'd0,staging_address};
  byte_index=(row<8?first_base+(row[2]?16'd640:16'd0):tail_base)+{14'd0,row[1:0]}*16'd10+{11'd0,xword}*16'd4;
 end
 wire [63:0] aligned={memory_rd,data0}>>(byte_shift*8);
 integer i;
 always @(posedge aclk)begin
  if(!aresetn)begin
   state<=HEAD;hi<=0;ri<=0;status<=0;bad<=0;ended<=0;mode<=0;index<=0;stage6<=0;rs<=0;ws<=0;ra<=0;wa<=0;data0<=0;data1<=0;wd<=0;
   channel<=0;row<=0;xword<=0;stripe<=0;row4<=0;ob<=0;local_ch<=0;byte_shift<=0;pad_channel<=0;
   source_slot<=16;source_address<=2560;staging_slot<=0;staging_address<=0;source_phase<=0;target_lane<=0;target_group<=0;target_stripe<=0;block_lane<=0;block_group<=0;local_word<=0;first_base<=0;tail_base<=1280;
   capture_index<=0;cap_slot<=31;cap_addr<=0;mask11<=0;mask21<=0;captured6<=0;ready6<=0;ready11<=0;ready21<=0;
   for(i=0;i<8;i=i+1)h[i]<=0;
  end else begin
   if(capture_begin!=0)begin
    capture_index<=0;
    if(capture_begin==1)begin cap_slot<=31;cap_addr<=0;captured6<=0;mask11<=0;mask21<=0;ready6<=0;ready11<=0;ready21<=0;end
    if(capture_begin==2&&capture_block==0)begin mask11<=0;ready11<=0;end
    if(capture_begin==3&&capture_block==0)begin mask21<=0;ready21<=0;end
   end
   if(capture_valid)begin
    capture_index<=capture_index+1;
    if(capture_kind==1)begin
     if(capture_index==25599)captured6<=1;
     if(cap_slot>=31)begin if(cap_addr==1023)begin cap_addr<=cap_slot==44?640:0;cap_slot<=cap_slot==44?0:cap_slot+1;end else cap_addr<=cap_addr+1;end
     else if(cap_slot<16)begin if(cap_addr==1023)begin cap_addr<=cap_slot==15?2560:640;cap_slot<=cap_slot+1;end else cap_addr<=cap_addr+1;end
     else if(cap_slot<19)begin if(cap_addr==4095)begin cap_slot<=cap_slot==18?22:cap_slot+1;cap_addr<=cap_slot==18?3520:2560;end else cap_addr<=cap_addr+1;end
     else cap_addr<=cap_addr+1;
    end else if(capture_kind==2&&capture_index==1599)mask11[capture_block[2:0]]<=1;
    else if(capture_kind==3&&capture_index==399)mask21[capture_block]<=1;
   end
   case(state)
    HEAD:if(s_axis_tvalid&&s_axis_tready)begin
     h[hi]<=s_axis_tdata;ended<=s_axis_tlast;if(hi==0)bad<=s_axis_tkeep!=15;else if(s_axis_tkeep!=15)bad<=1;
     if(s_axis_tlast&&hi!=7)begin status<=2;ri<=0;hi<=0;state<=ACK;end else if(hi==7)begin hi<=0;state<=CHECK;end else hi<=hi+1;
    end
    CHECK:begin
     ri<=0;status<=0;index<=0;stage6<=0;source_slot<=16;source_address<=2560;staging_slot<=0;staging_address<=0;source_phase<=0;target_lane<=0;target_group<=0;target_stripe<=0;block_lane<=0;block_group<=0;local_word<=0;first_base<=0;tail_base<=1280;channel<=0;row<=0;xword<=0;stripe<=0;row4<=0;ob<=0;local_ch<=0;
     if(bad||!ended||h[0]!=32'h59323643||h[3]||h[4]||h[5]||h[6]||h[7]!=8)begin status<=1;state<=ended?ACK:DROP;end
     else if(h[1]==32'h10080&&captured6)begin mode<=0;state<=CALC;end
     else if(h[1]==32'h10081&&mask11==255)begin mode<=1;state<=CALC;end
     else if(h[1]==32'h10082&&mask21==65535)begin mode<=2;state<=CALC;end
     else begin status<=1;state<=ACK;end
    end
    CALC:begin
     ws<=destination[17:12];wa<=destination[11:0];byte_shift<=byte_index[1:0];pad_channel<=channel>=256;
     if(mode==0)begin rs<=source_slot;ra<=source_address;end
     else if(mode==1)begin rs<=25+index[15:10];ra<={2'd0,index[9:0]};end
     else begin rs<=25+byte_index[15:12];ra<={2'd0,byte_index[11:2]};end
     if(mode==2&&channel>=256)begin wd<=0;state<=WRITE;end else state<=R0;
    end
    R0:state<=R1;R1:state<=R2;
    R2:begin data0<=memory_rd;if(mode==2)begin if(ra==1023)begin rs<=rs+1;ra<=0;end else ra<=ra+1;state<=S0;end else begin wd<=memory_rd;state<=WRITE;end end
    S0:state<=S1;S1:state<=S2;
    S2:begin wd<=xword==2?{16'd0,aligned[15:0]}:aligned[31:0];state<=WRITE;end
    WRITE:state<=NEXT;
    NEXT:begin
     index<=index+1;state<=CALC;
     if(mode==0&&!stage6)begin
      if(source_address==4095&&source_slot<19)begin source_slot<=source_slot==18?22:source_slot+1;source_address<=source_slot==18?3520:2560;end else source_address<=source_address+1;
      if(staging_address==639)begin staging_address<=0;staging_slot<=staging_slot+1;end else staging_address<=staging_address+1;
      if(index==5119)begin stage6<=1;index<=0;source_slot<=31;source_address<=0;source_phase<=0;end
     end else if(mode==0)begin
      if(index==14335)begin source_phase<=1;source_slot<=0;source_address<=640;end
      else if(index==20479)begin source_phase<=2;source_slot<=0;source_address<=0;end
      else if(source_address==(source_phase==2?639:1023))begin source_slot<=source_slot+1;source_address<=source_phase==1?640:0;end else source_address<=source_address+1;
      if(local_word==39)begin
       local_word<=0;
       if(channel==63)begin channel<=0;stripe<=stripe+1;target_stripe<=target_stripe+40;target_lane<=0;target_group<=0;end
       else begin channel<=channel+1;target_lane<=target_lane==2?0:target_lane+1;if(target_lane==2)target_group<=target_group+400;end
      end else local_word<=local_word+1;
      if(index==25599)begin ready6<=1;state<=DRAIN0;end
     end else if(mode==1)begin
      if(local_word==19)begin
       local_word<=0;
       if(local_ch==15)begin
        local_ch<=0;
        if(stripe==4)begin
         stripe<=0;ob<=ob+1;target_stripe<=0;
         block_lane<=block_lane==2?0:block_lane+1;target_lane<=block_lane==2?0:block_lane+1;
         block_group<=block_group+(block_lane==2?600:500);target_group<=block_group+(block_lane==2?600:500);
        end else begin stripe<=stripe+1;target_stripe<=target_stripe+20;target_lane<=block_lane;target_group<=block_group;end
       end else begin local_ch<=local_ch+1;target_lane<=target_lane==2?0:target_lane+1;if(target_lane==2)target_group<=target_group+100;end
      end else local_word<=local_word+1;
      if(index==12799)begin ready11<=1;state<=DRAIN0;end
     end else begin
      if(xword==2)begin
       xword<=0;
       if(row==9)begin
        row<=0;channel<=channel+1;target_lane<=target_lane==2?0:target_lane+1;if(target_lane==2)target_group<=target_group+30;
        first_base<=first_base+(channel[3:0]==15?1000:40);tail_base<=tail_base+(channel[3:0]==15?1300:20);
       end else row<=row+1;
      end else xword<=xword+1;
      if(channel==257&&row==9&&xword==2)begin ready21<=1;state<=DRAIN0;end
     end
    end
    DRAIN0:state<=DRAIN1;DRAIN1:state<=ACK;
    ACK:if(m_axis_tready)begin if(ri==7)begin state<=HEAD;hi<=0;end else ri<=ri+1;end
    DROP:if(s_axis_tvalid&&s_axis_tlast)begin ri<=0;state<=ACK;end
    default:state<=HEAD;
   endcase
  end
 end
endmodule
