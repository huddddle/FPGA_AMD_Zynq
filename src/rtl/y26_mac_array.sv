`timescale 1ns/1ps
// Shared 16-output x 3-input integer MAC. Bias/activation are outside this MAC;
// current integrated systems apply them in the PL fusion tail.
module y26_mac_array #(parameter OC=16)(
    input wire clk, resetn,
    input wire in_valid, in_first, in_last,
    input wire [47:0] activations,
    input wire [OC*48-1:0] weights,
    input wire [OC*48-1:0] base,
    output reg out_valid,
    output wire [OC*48-1:0] result
);
    reg vm,vs,fm,fs,lm,ls;
    always @(posedge clk) begin
        if(!resetn) begin vm<=0; vs<=0; fm<=0; fs<=0; lm<=0; ls<=0; out_valid<=0; end
        else begin
            vm<=in_valid; vs<=vm;
            fm<=in_first; fs<=fm; lm<=in_last; ls<=lm;
            out_valid<=vs && ls;
        end
    end
    genvar o;
    generate for(o=0;o<OC;o=o+1) begin: lane
        (* use_dsp="yes" *) reg signed [31:0] p0,p1,p2;
        reg signed [47:0] sum3,acc,out_result;
        wire signed [47:0] incoming=fs ? $signed(base[o*48+:48]) : acc;
        wire signed [47:0] next_sum=incoming+sum3;
        assign result[o*48+:48]=out_result;
        always @(posedge clk) begin
            if(in_valid) begin
                p0<=$signed(activations[15:0])*$signed(weights[o*48+:16]);
                p1<=$signed(activations[31:16])*$signed(weights[o*48+16+:16]);
                p2<=$signed(activations[47:32])*$signed(weights[o*48+32+:16]);
            end
            if(vm) sum3<={{16{p0[31]}},p0}+{{16{p1[31]}},p1}+{{16{p2[31]}},p2};
            if(!resetn) begin acc<=0; out_result<=0; end
            else if(vs) begin
                acc<=next_sum;
                if(ls) out_result<=next_sum;
            end
        end
    end endgenerate
endmodule
