`timescale 1ns/1ps
// Three packet owners; one PE and physical memory pool. C10 stays resident
// across the middle -> conv11 task switch. Only a final skip read exports it.
module y26_axis_resident #(parameter ALLOW_BLOCK2230=0,parameter ALLOW_CONTINUOUS30=0)(
 input wire aclk,aresetn,input wire [31:0] s_axis_tdata,input wire [3:0] s_axis_tkeep,
 input wire s_axis_tlast,s_axis_tvalid,output wire s_axis_tready,
 output wire [31:0] m_axis_tdata,output wire [3:0] m_axis_tkeep,
 output wire m_axis_tlast,m_axis_tvalid,input wire m_axis_tready,output wire config_busy
);
 localparam IDLE=0,SELECT=1,REPLAY0=2,REPLAY1=3,PAYLOAD=4,RESPONSE=5;
 reg [2:0] state;reg [2:0] owner;reg [31:0] d0,d1;reg [3:0] k0,k1;reg l0,l1;
 reg resident,layout,deep_ready;wire completed,deep_completed;
 wire active=state!=IDLE;
 wire [31:0] ed=state==REPLAY0?d0:state==REPLAY1?d1:s_axis_tdata;
 wire [3:0] ek=state==REPLAY0?k0:state==REPLAY1?k1:s_axis_tkeep;
 wire el=state==REPLAY0?l0:state==REPLAY1?l1:s_axis_tlast;
 wire ev=state==REPLAY0||state==REPLAY1||(state==PAYLOAD&&s_axis_tvalid);
 wire [5:0] er,mv,ml;wire [31:0] md[0:5];wire [3:0] mk[0:5];
 wire [185:0] cc[0:5];wire [137:0] tc[0:5];wire [802:0] cr;wire [10:0] tr;
 wire [1797:0] gm;wire [991:0] gq;wire [191:0] cm;wire [95:0] cq;
 wire [767:0] mm;wire [383:0] mq;wire [77:0] gw,mw,cw;wire [47:0] wq;
 reg [31:0] response_word,packet_command;reg [2:0] request_word;reg [3:0] packet_block;
 wire compact_graph=ALLOW_CONTINUOUS30&&packet_command==32'h10032;
 wire compact11=ALLOW_CONTINUOUS30&&packet_command==32'h10047;
 wire compact21=ALLOW_CONTINUOUS30&&packet_command==32'h10048;
 wire discard_data=compact_graph&&response_word>=8&&response_word<25608||compact11&&response_word>=8&&response_word<1608||compact21&&response_word>=8&&response_word<408;
 wire response_ready=discard_data||m_axis_tready;
 wire [31:0] engine_data=state==REPLAY1&&packet_command==32'h10032 ?32'h10031:state==REPLAY1&&packet_command==32'h10047 ?32'h10041:state==REPLAY1&&packet_command==32'h10048 ?32'h10044:ed;
 wire link_we,link_re;wire [5:0] link_ws,link_rs;wire [11:0] link_wa,link_ra;wire [31:0] link_wd,link_rd;wire ready6,ready11,ready21;
 wire selecting=state==SELECT&&s_axis_tvalid&&s_axis_tready;
 wire [1:0] capture_begin=ALLOW_CONTINUOUS30&&selecting?(s_axis_tdata==32'h10032 ?2'd1:s_axis_tdata==32'h10047 ?2'd2:s_axis_tdata==32'h10048 ?2'd3:2'd0):2'd0;
 wire [1:0] capture_kind=compact_graph?2'd1:compact11?2'd2:compact21?2'd3:2'd0;
 wire capture_valid=discard_data&&active&&mv[owner];
 wire [191:0] dm,nm;wire [77:0] dw,nw;
 y26_compute_unit #(.PSUM_BITS(36)) compute(.clk(aclk),.core_command({active&&cc[owner][185],cc[owner][184:0]}),.core_response(cr),.tail_command({active&&tc[owner][137],tc[owner][136:0]}),.tail_response(tr));
 y26_resident_memory #(.LINK(ALLOW_CONTINUOUS30)) memory(.link_we(link_we),.link_ws(link_ws),.link_wa(link_wa),.link_wd(link_wd),.link_re(link_re),.link_rs(link_rs),.link_ra(link_ra),.link_rd(link_rd),.clk(aclk),.owner(owner==5?2'd3:owner>=3?2'd1:owner[1:0]),.resident_layout(layout),.graph_command(gm),.graph_response(gq),.middle_command(owner==4?{576'd0,nm}:owner==3?{576'd0,dm}:owner==5?768'd0:mm),.middle_response(mq),.conv_command(cm),.conv_response(cq),.graph_weights(gw),.middle_weights(owner==4?nw:owner==3?dw:mw),.conv_weights(cw),.weight_response(wq));
 y26_axis_graph #(.EXTERNAL_COMPUTE(1),.EXTERNAL_MEMORY(1)) graph(
 .aclk(aclk),.aresetn(aresetn&&owner==0),.s_axis_tdata(engine_data),.s_axis_tkeep(ek),.s_axis_tlast(el),.s_axis_tvalid(ev&&owner==0),.s_axis_tready(er[0]),
 .m_axis_tdata(md[0]),.m_axis_tkeep(mk[0]),.m_axis_tlast(ml[0]),.m_axis_tvalid(mv[0]),.m_axis_tready(response_ready&&active&&owner==0),.config_busy(),
 .compute_core_command(cc[0]),.compute_tail_command(tc[0]),.external_core_response(cr),.external_tail_response(tr),.feature_command(gm),.feature_response(gq),.weight_command(gw),.weight_response(wq));
 y26_axis_middle middle(
 .aclk(aclk),.aresetn(aresetn&&owner==1),.resident_ready(resident),.input_ready(ALLOW_CONTINUOUS30&&ready6),.s_axis_tdata(engine_data),.s_axis_tkeep(ek),.s_axis_tlast(el),.s_axis_tvalid(ev&&owner==1),.s_axis_tready(er[1]),
 .m_axis_tdata(md[1]),.m_axis_tkeep(mk[1]),.m_axis_tlast(ml[1]),.m_axis_tvalid(mv[1]),.m_axis_tready(response_ready&&active&&owner==1),
 .compute_core_command(cc[1]),.compute_tail_command(tc[1]),.external_core_response(cr),.external_tail_response(tr),.feature_command(mm),.feature_response(mq),.weight_command(mw),.weight_response(wq),.completed(completed));
 y26_axis_conv11 #(.EXTERNAL_COMPUTE(1),.EXTERNAL_MEMORY(1),.ALLOW_RESIDENT_INIT(1),.ALLOW_CONV21(1),.ALLOW_DEEP_INIT(1)) conv11(
 .aclk(aclk),.aresetn(aresetn&&owner==2),.resident_ready(resident),.resident21_ready(deep_ready),.s_axis_tdata(engine_data),.s_axis_tkeep(ek),.s_axis_tlast(el),.s_axis_tvalid(ev&&owner==2),.s_axis_tready(er[2]),
 .m_axis_tdata(md[2]),.m_axis_tkeep(mk[2]),.m_axis_tlast(ml[2]),.m_axis_tvalid(mv[2]),.m_axis_tready(response_ready&&active&&owner==2),.config_busy(),
 .compute_core_command(cc[2]),.compute_tail_command(tc[2]),.external_core_response(cr),.external_tail_response(tr),.feature_command(cm),.feature_response(cq),.weight_command(cw),.weight_response(wq));
 y26_axis_deep deep(
 .aclk(aclk),.aresetn(aresetn&&owner==3),.resident_ready(deep_ready),.input_ready(ALLOW_CONTINUOUS30&&ready11),.s_axis_tdata(engine_data),.s_axis_tkeep(ek),.s_axis_tlast(el),.s_axis_tvalid(ev&&owner==3),.s_axis_tready(er[3]),
 .m_axis_tdata(md[3]),.m_axis_tkeep(mk[3]),.m_axis_tlast(ml[3]),.m_axis_tvalid(mv[3]),.m_axis_tready(response_ready&&active&&owner==3),
 .compute_core_command(cc[3]),.compute_tail_command(tc[3]),.external_core_response(cr),.external_tail_response(tr),.feature_command(dm),.feature_response(mq[95:0]),.weight_command(dw),.weight_response(wq),.completed(deep_completed));
 generate if(ALLOW_BLOCK2230)begin: block2230_mode
  y26_axis_block2230 block2230(
   .input_ready(ALLOW_CONTINUOUS30&&ready21),.aclk(aclk),.aresetn(aresetn&&owner==4),.s_axis_tdata(engine_data),.s_axis_tkeep(ek),.s_axis_tlast(el),.s_axis_tvalid(ev&&owner==4),.s_axis_tready(er[4]),
   .m_axis_tdata(md[4]),.m_axis_tkeep(mk[4]),.m_axis_tlast(ml[4]),.m_axis_tvalid(mv[4]),.m_axis_tready(response_ready&&active&&owner==4),
   .compute_core_command(cc[4]),.compute_tail_command(tc[4]),.external_core_response(cr),.external_tail_response(tr),.feature_command(nm),.feature_response(mq[95:0]),.weight_command(nw),.weight_response(wq));
 end else begin: no_block2230
  assign er[4]=0;assign md[4]=0;assign mk[4]=0;assign ml[4]=0;assign mv[4]=0;assign cc[4]=0;assign tc[4]=0;assign nm=0;assign nw=0;
 end endgenerate
 generate if(ALLOW_CONTINUOUS30)begin: resident_links
 y26_resident_link link(.aclk(aclk),.aresetn(aresetn),.capture_begin(capture_begin),.capture_kind(capture_kind),.capture_block(selecting?s_axis_tdata[3:0]:packet_block),.capture_valid(capture_valid),.capture_data(md[owner]),
 .s_axis_tdata(ed),.s_axis_tkeep(ek),.s_axis_tlast(el),.s_axis_tvalid(ev&&owner==5),.s_axis_tready(er[5]),.m_axis_tdata(md[5]),.m_axis_tkeep(mk[5]),.m_axis_tlast(ml[5]),.m_axis_tvalid(mv[5]),.m_axis_tready(m_axis_tready&&active&&owner==5),
 .memory_we(link_we),.memory_ws(link_ws),.memory_wa(link_wa),.memory_wd(link_wd),.memory_re(link_re),.memory_rs(link_rs),.memory_ra(link_ra),.memory_rd(link_rd),.ready6(ready6),.ready11(ready11),.ready21(ready21));
 end else begin: no_links
 assign link_we=0;assign link_re=0;assign link_ws=0;assign link_rs=0;assign link_wa=0;assign link_ra=0;assign link_wd=0;assign ready6=0;assign ready11=0;assign ready21=0;
 assign er[5]=0;assign md[5]=0;assign mk[5]=0;assign ml[5]=0;assign mv[5]=0;
 end endgenerate
 assign cc[5]=0;assign tc[5]=0;
 assign s_axis_tready=aresetn&&(state==IDLE||state==SELECT||(state==PAYLOAD&&er[owner]));
 assign m_axis_tdata=response_word==1&&(compact_graph||compact11||compact21)?packet_command:response_word==6&&compact_graph?32'd20:response_word==6&&(compact11||compact21)?32'd8:md[owner];assign m_axis_tkeep=mk[owner];
 assign m_axis_tlast=active&&ml[owner];assign m_axis_tvalid=aresetn&&active&&mv[owner]&&!discard_data;
 assign config_busy=active||s_axis_tvalid;
 always @(posedge aclk)begin
  if(!aresetn)begin state<=IDLE;owner<=0;response_word<=0;packet_command<=0;packet_block<=0;request_word<=0;resident<=0;deep_ready<=0;layout<=0;d0<=0;d1<=0;k0<=0;k1<=0;l0<=0;l1<=0;end
  else begin
   if(active&&mv[owner]&&response_ready)response_word<=response_word+1;
   if(state==PAYLOAD&&s_axis_tvalid&&s_axis_tready&&request_word<7)begin request_word<=request_word+1;if(request_word==5)packet_block<=s_axis_tdata[3:0];end
   if(completed&&owner==1)resident<=1;
   if(deep_completed&&owner==3)deep_ready<=1;
   case(state)
    IDLE:if(s_axis_tvalid&&s_axis_tready)begin d0<=s_axis_tdata;k0<=s_axis_tkeep;l0<=s_axis_tlast;state<=s_axis_tlast?REPLAY0:SELECT;end
    SELECT:if(s_axis_tvalid&&s_axis_tready)begin
     d1<=s_axis_tdata;k1<=s_axis_tkeep;l1<=s_axis_tlast;packet_command<=s_axis_tdata;response_word<=0;request_word<=2;
     if(ALLOW_CONTINUOUS30&&(s_axis_tdata==32'h10080||s_axis_tdata==32'h10081||s_axis_tdata==32'h10082))owner<=5;
     else if(ALLOW_BLOCK2230&&(s_axis_tdata==32'h10073||s_axis_tdata==32'h10070||s_axis_tdata==32'h10071||s_axis_tdata==32'h10072))owner<=4;
     else if(s_axis_tdata==32'h10061||s_axis_tdata==32'h10060||s_axis_tdata==32'h10062)owner<=3;
     else if(s_axis_tdata==32'h10051||s_axis_tdata==32'h10050||s_axis_tdata==32'h10052)owner<=1;
     else if(s_axis_tdata==32'h10047||s_axis_tdata==32'h10048||s_axis_tdata==32'h10040||s_axis_tdata==32'h10041||s_axis_tdata==32'h10042||s_axis_tdata==32'h10043||s_axis_tdata==32'h10044||s_axis_tdata==32'h10045)owner<=2;
     else owner<=0;
     case(s_axis_tdata)
      32'h10073,32'h10070,32'h10071,32'h10072:begin resident<=0;deep_ready<=0;layout<=1;end
      32'h10051,32'h10061,32'h10050,32'h10060:begin resident<=0;deep_ready<=0;layout<=1;end
      32'h10042:begin layout<=1;deep_ready<=0;end
      32'h10045:begin layout<=1;resident<=0;end
      32'h10047,32'h10048,32'h10080,32'h10081,32'h10082,32'h10041,32'h10044,32'h10052,32'h10062:begin end
      default:begin resident<=0;deep_ready<=0;layout<=0;end
     endcase
     state<=REPLAY0;
    end
    REPLAY0:if(er[owner])state<=l0?RESPONSE:REPLAY1;
    REPLAY1:if(er[owner])state<=l1?RESPONSE:PAYLOAD;
    PAYLOAD:if(s_axis_tvalid&&s_axis_tready&&s_axis_tlast)state<=RESPONSE;
    default:begin end
   endcase
   if(m_axis_tvalid&&m_axis_tready&&m_axis_tlast)state<=IDLE;
  end
 end
endmodule
