`timescale 1ns/1ps
// Seven-stage scalar tail. Six 17x16 partial products avoid a single wide multiplier path.
// Bias is in accumulator units. RNE rounding, symmetric zero point 0, optional ReLU.
module y26_requantize(
    input wire clk,resetn,in_valid,
    output wire in_ready,
    input wire signed [47:0] accumulator,bias,
    input wire [31:0] multiplier,
    input wire [4:0] shift,
    input wire relu,in_last,
    output wire out_valid,
    input wire out_ready,
    output reg [7:0] value,
    output reg out_last
);
    reg [6:0] valid;
    wire advance=!valid[6]||out_ready;
    assign in_ready=resetn&&advance;
    assign out_valid=resetn&&valid[6];
    reg signed [48:0] sum0;
    reg [48:0] magnitude1;
    reg [31:0] m[0:1];
    reg [4:0] n[0:5];
    reg negative[0:5],activation[0:5],last[0:5];
    reg [30:0] mask[0:4],half[0:4];
    (* use_dsp="yes" *) reg [32:0] p00,p01,p10,p11,p20,p21;
    reg [64:0] low3,high3;
    reg [80:0] product4,quotient5;
    reg round_greater5,round_equal5;
    wire round_up=round_greater5||(round_equal5&&quotient5[0]);
    integer i;
    always @(posedge clk)begin
        if(!resetn)begin
            valid<=0;value<=0;out_last<=0;
            for(i=0;i<6;i=i+1)begin n[i]<=0;negative[i]<=0;activation[i]<=0;last[i]<=0;end
        end else if(advance)begin
            valid<={valid[5:0],in_valid};
            sum0<={accumulator[47],accumulator}+{bias[47],bias};
            m[0]<=multiplier;m[1]<=m[0];n[0]<=shift;activation[0]<=relu;last[0]<=in_last;negative[0]<=0;
            mask[0]<=(32'd1<<shift)-1;
            half[0]<=shift==0 ? 0 : 32'd1<<(shift-1);
            for(i=1;i<6;i=i+1)begin n[i]<=n[i-1];activation[i]<=activation[i-1];last[i]<=last[i-1];negative[i]<=negative[i-1];end
            for(i=1;i<5;i=i+1)begin mask[i]<=mask[i-1];half[i]<=half[i-1];end
            magnitude1<=sum0[48] ? -sum0 : sum0;negative[1]<=sum0[48];
            p00<=magnitude1[16:0]*m[1][15:0];p01<=magnitude1[16:0]*m[1][31:16];
            p10<=magnitude1[33:17]*m[1][15:0];p11<=magnitude1[33:17]*m[1][31:16];
            p20<=magnitude1[48:34]*m[1][15:0];p21<=magnitude1[48:34]*m[1][31:16];
            low3<={32'd0,p00}+({32'd0,p10}<<17)+({32'd0,p20}<<34);
            high3<={32'd0,p01}+({32'd0,p11}<<17)+({32'd0,p21}<<34);
            product4<={16'd0,low3}+{high3,16'd0};
            quotient5<=product4>>n[4];
            round_greater5<=n[4]!=0&&((product4[30:0]&mask[4])>half[4]);
            round_equal5<=n[4]!=0&&((product4[30:0]&mask[4])==half[4]);
            out_last<=last[5];
            if(activation[5]&&negative[5])value<=0;
            else if(negative[5])begin
                if(quotient5>=81'd128)value<=8'h80;
                else value<=-(quotient5[7:0]+round_up);
            end else begin
                if(quotient5>=81'd127)value<=8'h7f;
                else value<=quotient5[7:0]+round_up;
            end
        end
    end
endmodule
