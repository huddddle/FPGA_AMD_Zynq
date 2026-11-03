`timescale 1ns/1ps
// 72 feature RAMB36: old graph view, in-place C6/C10, 16-row C7,
// C8/Concat scratch reused by phase, eight-row C9. No second full tensor.
module y26_resident_memory #(parameter LINK=0)(
 input wire link_we,link_re,input wire [5:0] link_ws,link_rs,input wire [11:0] link_wa,link_ra,input wire [31:0] link_wd,output wire [31:0] link_rd,
 input wire clk,input wire [1:0] owner,input wire resident_layout,
 input wire [1797:0] graph_command,output wire [991:0] graph_response,
 input wire [767:0] middle_command,output wire [383:0] middle_response,
 input wire [191:0] conv_command,output wire [95:0] conv_response,
 input wire [77:0] graph_weights,middle_weights,conv_weights,
 output wire [47:0] weight_response
);
 wire [31:0] q[0:44];
 generate for(genvar s=0;s<45;s=s+1)begin: slots
  localparam LARGE=s>=16&&s<25;
  localparam SI=s<16?s:s>=25?s-9:-1;
  localparam ML=LARGE?(s-16)%3:SI<15?SI/5:SI<27?3+(SI-15)/4:SI<33?6+(SI-27)/2:9+(SI-33);
  localparam MR=LARGE?(s-16)/3:SI<15?12+SI%5:SI<27?(SI-15)%4:SI<33?(SI-27)%2:0;
  localparam CL=LARGE?(s-16)%3:SI/6;
  localparam CR=LARGE?(s-16)/3:12+SI%6;
  localparam DEPTH=LARGE?4096:1024;
  localparam AW=LARGE?12:10;
  wire [57:0] gc;
  if(s<31)assign gc=graph_command[s*58+:58];else assign gc=0;
  wire [63:0] mc=middle_command[ML*64+:64];
  wire [63:0] cc;
  if(LARGE||SI<18)assign cc=conv_command[CL*64+:64];else assign cc=0;
  // conv11 reuses the full tensor logical lanes only; scratch is never written.
  wire [63:0] cv;
  if(ML<3)assign cv=resident_layout?conv_command[ML*64+:64]:cc;
  else assign cv=resident_layout?64'd0:cc;
  wire [63:0] c=owner==1?mc:cv;
  wire [14:0] wa=c[62:48],ra=c[14:0];
  wire mw=LARGE?wa[14:12]==MR:wa[14:10]==MR;
  wire mr=LARGE?ra[14:12]==MR:ra[14:10]==MR;
  wire cw=LARGE?wa[14:12]==CR:wa[14:10]==CR;
  wire cr=LARGE?ra[14:12]==CR:ra[14:10]==CR;
  wire mapped=owner==1||resident_layout;
  wire link_write=LINK&&link_we&&link_ws==s;
  wire link_read=LINK&&link_re&&link_rs==s;
  wire we=link_write||(owner==0?gc[57]:c[63]&&(mapped?mw:cw));
  wire re=link_read||(owner==0?gc[12]:c[15]&&(mapped?mr:cr));
  wire [11:0] waddr=link_write?link_wa:owner==0?gc[56:45]:wa[11:0];
  wire [11:0] raddr=link_read?link_ra:owner==0?gc[11:0]:ra[11:0];
  wire [31:0] wd=link_write?link_wd:owner==0?gc[44:13]:c[47:16];
  (* ram_style="block" *) reg [31:0] values[0:DEPTH-1];reg [31:0] result;
  reg store_we;reg [AW-1:0] store_address;reg [31:0] store_data;
  always @(posedge clk)begin
   store_we<=we;
   if(we)begin store_address<=waddr[AW-1:0];store_data<=wd;end
   if(store_we)values[store_address]<=store_data;
   if(re)result<=values[raddr[AW-1:0]];
  end
  assign q[s]=result;
  if(s<31)assign graph_response[s*32+:32]=result;
 end endgenerate
 generate for(genvar b=0;b<12;b=b+1)begin: responses
  localparam COUNT=b<3?8:b<6?4:b<9?2:1;
  wire [14:0] ra=middle_command[b*64+:15];reg [4:0] region;
  wire [31:0] small_q[0:COUNT-1];
  for(genvar k=0;k<COUNT;k=k+1)begin: small_slots
   localparam I=b<3?b*5+k:b<6?15+(b-3)*4+k:b<9?27+(b-6)*2+k:33+(b-9)+k;
   localparam S=I<16?I:I+9;
   if(b<3&&k>=5)assign small_q[k]=0;else assign small_q[k]=q[S];
  end
  always @(posedge clk)if(owner==1&&middle_command[b*64+15])region<=b<3?(ra<12288?{2'd0,ra[14:12]}:5'd3+(ra[14:10]-5'd12)):ra[14:10];
  if(b<3)assign middle_response[b*32+:32]=region==0?q[16+b]:region==1?q[19+b]:region==2?q[22+b]:small_q[region-3];
  else assign middle_response[b*32+:32]=small_q[region];
 end endgenerate
 generate for(genvar b=0;b<3;b=b+1)begin: conv_responses
  wire [14:0] ra=conv_command[b*64+:15];reg [3:0] region;
  wire [31:0] resident_q[0:4],legacy_q[0:5];
  for(genvar k=0;k<6;k=k+1)begin: small_slots
   localparam I=b*6+k;localparam S=I<16?I:I+9;assign legacy_q[k]=q[S];
   if(k<5)begin: resident_small
    localparam J=b*5+k;localparam T=J<16?J:J+9;assign resident_q[k]=q[T];
   end
  end
  always @(posedge clk)if(owner==2&&conv_command[b*64+15])region<=ra<12288?{1'b0,ra[14:12]}:4'd3+(ra[14:10]-5'd12);
  assign conv_response[b*32+:32]=region==0?q[16+b]:region==1?q[19+b]:region==2?q[22+b]:resident_layout?resident_q[region-3]:legacy_q[region-3];
 end endgenerate
 reg [5:0] link_read_slot;always @(posedge clk)if(LINK&&link_re)link_read_slot<=link_rs;
 assign link_rd=LINK?q[link_read_slot]:32'd0;
 wire [77:0] wc=owner==0?graph_weights:owner==1?middle_weights:conv_weights;
 (* ram_style="block" *) reg [47:0] weights[0:13695];reg [47:0] wq;
 always @(posedge clk)begin
  if(wc[77])weights[wc[76:63]]<=wc[62:15];
  if(wc[14])wq<=weights[wc[13:0]];
 end
 assign weight_response=wq;
endmodule
