`timescale 1ns/1ps
// One RGB transaction, resident branch, one PE. Old LOAD14/20 plus LOAD30/RUN31.
module y26_axis_graph #(parameter EXTERNAL_COMPUTE=0,parameter EXTERNAL_MEMORY=0)(
 input wire aclk,aresetn,input wire [31:0] s_axis_tdata,input wire [3:0] s_axis_tkeep,
 input wire s_axis_tlast,s_axis_tvalid,output wire s_axis_tready,
 output reg [31:0] m_axis_tdata,output wire [3:0] m_axis_tkeep,
 output reg m_axis_tlast,output reg m_axis_tvalid,input wire m_axis_tready,output wire config_busy,
 output wire [185:0] compute_core_command,output wire [137:0] compute_tail_command,
 input wire [802:0] external_core_response,input wire [10:0] external_tail_response,
 output wire [1797:0] feature_command,input wire [991:0] feature_response,
 output wire [77:0] weight_command,input wire [47:0] weight_response
);
 localparam HEAD=0,CHECK=1,REPLAY=2,LOAD=3,ACK=4,BRLOAD=5,HOTHEAD=6,PREFHEAD=7,PRODUCE=8,BRSTART=9,BRIDGE=10,HOTRUN=11,FINISH=12,FOOT=13,DROP=14;
 reg [3:0] state;reg [31:0] h[0:7];reg [2:0] hi,ri;reg selected,branch_loaded,invalid;reg [31:0] count,status;
 reg [3:0] stripe;reg [31:0] pref_out,hot_out,job_cycles;reg [31:0] pf[0:10],hf[0:9];reg [4:0] fi;
 reg [16:0] need_words;
 reg [4:0] prefix_word_count,prefix_channel_count;
 reg [1:0] prefix_row_count;reg [6:0] prefix_base;
 reg prefix_write;reg [4:0] prefix_word_q,prefix_channel_q;
 reg [6:0] prefix_row_q;reg [31:0] prefix_data_q;
 wire [31:0] pd,hd;wire pv,pl,pr,hr,hv,hl,pwait,hwait;wire [185:0] pc,hc,bc;wire [137:0] pt,ht,bt;
 wire [802:0] cr;wire [10:0] tr;wire bb,bd,be,catv,catl;wire [31:0] catd,c3,c4,bfeed,bfusion,bcat;
 wire run=state>=HOTHEAD&&state<=FINISH;
 wire pref_owner=state==PREFHEAD||state==PRODUCE||state==FINISH;
 wire bridge_owner=state==BRSTART||state==BRIDGE;
 wire [185:0] command=bridge_owner?bc:pref_owner?pc:hc;
 wire [137:0] tail=bridge_owner?bt:pref_owner?pt:ht;
 assign compute_core_command=command;assign compute_tail_command=tail;
 generate if(!EXTERNAL_COMPUTE)begin: local_compute
 y26_compute_unit compute(.clk(aclk),.core_command(command),.core_response(cr),.tail_command(tail),.tail_response(tr));
 end else begin: shared_compute
 assign cr=external_core_response;assign tr=external_tail_response;
 end endgenerate
 reg [31:0] pin,hin;reg piv,pil,hiv,hil;reg por,hor;
 wire pre_res=state==PRODUCE&&pwait&&pref_out<need_words;
 y26_axis_frame #(.ENABLE_THIRD(1),.EXTERNAL_COMPUTE(1),.STRIPE_PAUSE(1),.SECOND_RAM_STYLE("distributed"),.EXTERNAL_MEMORY(EXTERNAL_MEMORY)) prefix(
 .aclk(aclk),.aresetn(aresetn),.s_axis_tdata(pin),.s_axis_tkeep(4'hf),.s_axis_tlast(pil),.s_axis_tvalid(piv),.s_axis_tready(pr),
 .m_axis_tdata(pd),.m_axis_tkeep(),.m_axis_tlast(pl),.m_axis_tvalid(pv),.m_axis_tready(por),.config_busy(),
 .compute_core_command(pc),.compute_tail_command(pt),.external_core_response(cr),.external_tail_response(tr),.stripe_resume(pre_res),.stripe_waiting(pwait),.feature_command(feature_command[0+:928]),.feature_response(feature_response[0+:512]));
 y26_axis_hotspot56 #(.EXTERNAL_COMPUTE(1),.STRIPE_PAUSE(1),.EXTERNAL_MEMORY(EXTERNAL_MEMORY)) hotspot(
 .aclk(aclk),.aresetn(aresetn),.s_axis_tdata(hin),.s_axis_tkeep(4'hf),.s_axis_tlast(hil),.s_axis_tvalid(hiv),.s_axis_tready(hr),
 .m_axis_tdata(hd),.m_axis_tkeep(),.m_axis_tlast(hl),.m_axis_tvalid(hv),.m_axis_tready(hor),.config_busy(),
 .compute_core_command(hc),.compute_tail_command(ht),.external_core_response(cr),.external_tail_response(tr),.stripe_resume(state==PRODUCE),.stripe_waiting(hwait),.feature_command(feature_command[928+:348]),.feature_response(feature_response[512+:192]),.weight_command(weight_command),.weight_response(weight_response));
 wire prefix_we=run&&por&&pv&&pref_out>=8&&pref_out<51208;
 y26_graph_bridge #(.EXTERNAL_MEMORY(EXTERNAL_MEMORY)) branch(.clk(aclk),.resetn(aresetn),.clear_counters(state==CHECK&&h[1]==32'h10031),
 .cfg_we(state==BRLOAD&&s_axis_tvalid&&s_axis_tready),.cfg_addr(count[11:0]),.cfg_data(s_axis_tdata),
 .prefix_we(prefix_write),.prefix_channel(prefix_channel_q),.prefix_row(prefix_row_q),.prefix_word(prefix_word_q),.prefix_data(prefix_data_q),
 .start(state==BRSTART),.stripe(stripe),.busy(bb),.done(bd),.error(be),.core_command(bc),.core_response(cr),.tail_command(bt),.tail_response(tr),
 .cat_data(catd),.cat_valid(catv),.cat_last(catl),.cat_ready(state==BRIDGE&&hr),
 .cycles3(c3),.cycles4(c4),.feed_cycles(bfeed),.fusion_cycles(bfusion),.cat_cycles(bcat),.feature_command(feature_command[1276+:522]),.feature_response(feature_response[704+:288]));
 assign s_axis_tready=aresetn&&(state==HEAD||state==BRLOAD||state==DROP||(state==LOAD&&(selected?hr:pr))||(state==PRODUCE&&pr));
 assign config_busy=state!=HEAD||hi!=0;assign m_axis_tkeep=15;
 always @*begin
 pin=0;hin=0;piv=0;pil=0;hiv=0;hil=0;por=0;hor=0;
 m_axis_tdata=0;m_axis_tvalid=0;m_axis_tlast=0;
 if(state==REPLAY)begin
  if(selected)begin hin=h[ri];hiv=1;end else begin pin=h[ri];piv=1;end
 end
 if(state==LOAD)begin
  pin=s_axis_tdata;hin=s_axis_tdata;piv=s_axis_tvalid&&!selected;hiv=s_axis_tvalid&&selected;pil=s_axis_tlast;hil=s_axis_tlast;
 end
 if(state==ACK)begin
  if(h[1]==32'h10030||status!=0)begin
   m_axis_tvalid=1;m_axis_tlast=ri==7;
   case(ri)0:m_axis_tdata=32'h59323652;1:m_axis_tdata=h[1];2:m_axis_tdata=h[2];3:m_axis_tdata=status;default:m_axis_tdata=0;endcase
  end else begin
   m_axis_tdata=selected?hd:pd;m_axis_tvalid=selected?hv:pv;m_axis_tlast=selected?hl:pl;por=!selected&&m_axis_tready;hor=selected&&m_axis_tready;
  end
 end
 if(state==HOTHEAD)begin
  hiv=1;case(ri)0:hin=32'h59323643;1:hin=32'h10021;2:hin=h[2];3:hin=0;4:hin=32'h500050;5:hin=48;6:hin=76800;7:hin=25618;endcase
 end
 if(state==PREFHEAD)begin
  piv=1;case(ri)0:pin=32'h59323643;1:pin=32'h10015;2:pin=h[2];3:pin=0;4:pin=32'h1400140;5:pin=0;6:pin=76800;7:pin=51219;endcase
 end
 if(state==PRODUCE)begin pin=s_axis_tdata;piv=s_axis_tvalid;pil=s_axis_tlast;por=1;end
 if(state==BRIDGE)begin hin=catd;hiv=catv;hil=catl&&stripe==9;end
 if(run)begin
  if(hot_out<25608)begin
   m_axis_tvalid=hv;m_axis_tdata=hot_out==1?32'h10031:hot_out==6?32'd25620:hd;hor=m_axis_tready;
  end else hor=1;
 end
 if(state==FINISH)por=1;
 if(state==FOOT)begin
  m_axis_tvalid=1;m_axis_tlast=fi==19;
  if(fi<10)m_axis_tdata=hf[fi];
  else case(fi)10:m_axis_tdata=c3;11:m_axis_tdata=c4;12:m_axis_tdata=bfeed;13:m_axis_tdata=bfusion;14:m_axis_tdata=bcat;15:m_axis_tdata=pf[1];16:m_axis_tdata=job_cycles;17:m_axis_tdata=pf[10];18:m_axis_tdata=pf[2];19:m_axis_tdata=pf[3];endcase
 end
 end
 integer i;
 // Counters replace a 32-bit chain of /2560, %2560, /80 and /20.
 // Register the write metadata with its data before the BRAM address decoder.
 always @(posedge aclk)begin
  if(!aresetn)begin
   prefix_write<=0;prefix_word_count<=0;prefix_channel_count<=0;prefix_row_count<=0;prefix_base<=0;
   prefix_word_q<=0;prefix_channel_q<=0;prefix_row_q<=0;prefix_data_q<=0;
  end else begin
   prefix_write<=prefix_we;
   if(state==CHECK)begin prefix_word_count<=0;prefix_channel_count<=0;prefix_row_count<=0;prefix_base<=0;end
   if(prefix_we)begin
    prefix_word_q<=prefix_word_count;prefix_channel_q<=prefix_channel_count;prefix_row_q<=prefix_base+prefix_row_count;prefix_data_q<=pd;
    if(prefix_word_count==19)begin
     prefix_word_count<=0;
     if(prefix_row_count==3)begin
      prefix_row_count<=0;
      if(prefix_channel_count==31)begin prefix_channel_count<=0;prefix_base<=prefix_base+4;end
      else prefix_channel_count<=prefix_channel_count+1;
     end else prefix_row_count<=prefix_row_count+1;
    end else prefix_word_count<=prefix_word_count+1;
   end
  end
 end
 always @(posedge aclk)begin
 if(!aresetn)begin state<=HEAD;hi<=0;ri<=0;count<=0;selected<=0;branch_loaded<=0;invalid<=0;status<=0;stripe<=0;pref_out<=0;hot_out<=0;job_cycles<=0;fi<=0;need_words<=7688;for(i=0;i<8;i=i+1)h[i]<=0;for(i=0;i<11;i=i+1)pf[i]<=0;for(i=0;i<10;i=i+1)hf[i]<=0;end
 else begin
  if(run)job_cycles<=job_cycles+1;
  if(run&&pv&&por)begin if(pref_out>=51208&&pref_out<51219)pf[pref_out-51208]<=pd;pref_out<=pref_out+1;end
  if(run&&hv&&hor)begin if(hot_out>=25608)hf[hot_out-25608]<=hd;hot_out<=hot_out+1;end
  case(state)
   HEAD:if(s_axis_tvalid&&s_axis_tready)begin h[hi]<=s_axis_tdata;if(s_axis_tkeep!=15)invalid<=1;if(s_axis_tlast&&hi!=7)begin status<=2;ri<=0;state<=ACK;end else if(hi==7)begin hi<=0;state<=CHECK;end else hi<=hi+1;end
   CHECK:begin ri<=0;count<=0;status<=0;selected<=h[1]==32'h10020;
    if(invalid||h[0]!=32'h59323643)begin status<=1;state<=DROP;end
    else if(h[1]==32'h10014||h[1]==32'h10020)state<=REPLAY;
    else if(h[1]==32'h10030&&h[6]==2696)begin branch_loaded<=0;state<=BRLOAD;end
    else if(h[1]==32'h10031&&branch_loaded&&h[6]==76800&&h[7]==25628)begin stripe<=0;pref_out<=0;hot_out<=0;job_cycles<=0;need_words<=7688;state<=HOTHEAD;end
    else begin status<=1;state<=DROP;end
   end
   REPLAY:if(selected?hr:pr)begin if(ri==7)state<=LOAD;else ri<=ri+1;end
   LOAD:if(s_axis_tvalid&&s_axis_tready&&s_axis_tlast)begin ri<=0;state<=ACK;end
   BRLOAD:if(s_axis_tvalid&&s_axis_tready)begin
    count<=count+1;if(s_axis_tlast)begin branch_loaded<=count==2695;status<=count==2695?0:2;ri<=0;state<=ACK;end
   end
   ACK:if(m_axis_tvalid&&m_axis_tready)begin if(m_axis_tlast)begin state<=HEAD;hi<=0;invalid<=0;status<=0;end else ri<=ri+1;end
   HOTHEAD:if(hr)begin if(ri==7)begin ri<=0;state<=PREFHEAD;end else ri<=ri+1;end
   PREFHEAD:if(pr)begin if(ri==7)state<=PRODUCE;else ri<=ri+1;end
   PRODUCE:if((pwait&&pref_out>=need_words)||pref_out>=51219)state<=BRSTART;
   BRSTART:state<=BRIDGE;
   BRIDGE:if(catv&&hr&&catl)state<=HOTRUN;
   HOTRUN:if(hwait)begin stripe<=stripe+1;need_words<=stripe==8?17'd51208:need_words+17'd5120;state<=PRODUCE;end else if(hot_out>=25618)state<=FINISH;
   FINISH:if(pref_out>=51219)begin fi<=0;state<=FOOT;end
   FOOT:if(m_axis_tready)begin if(fi==19)begin state<=HEAD;hi<=0;end else fi<=fi+1;end
   DROP:if(s_axis_tvalid&&s_axis_tlast)begin ri<=0;state<=ACK;end
   default:state<=HEAD;
  endcase
 end end
endmodule
