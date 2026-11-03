`timescale 1ns/1ps
module tb_mac;
    reg clk=0; always #5 clk=~clk;
    reg resetn=0, valid=0, first=0, last=0;
    reg [47:0] a=0;
    reg [95:0] w=0, base=0;
    wire ov;
    wire [95:0] result;
    integer count=0;
    y26_mac_array #(.OC(2)) dut(.clk(clk),.resetn(resetn),.in_valid(valid),
        .in_first(first),.in_last(last),.activations(a),.weights(w),.base(base),
        .out_valid(ov),.result(result));
    always @(negedge clk) if(ov) begin
        if(count==0 && ($signed(result[47:0])!=103 || $signed(result[95:48])!=5))
            $fatal(1,"signed/bubble/base mismatch");
        if(count==1 && ($signed(result[47:0])!=48'sd28991029248 || $signed(result[95:48])!=48'sd28991029248))
            $fatal(1,"48-bit accumulation mismatch");
        count=count+1;
    end
    task beat(input bit f,input bit l);
        @(negedge clk); valid=1; first=f; last=l;
        @(negedge clk); valid=0; first=0; last=0;
    endtask
    integer t;
    initial begin
        repeat(3) @(negedge clk); resetn=1;
        a={16'sd4,-16'sd2,16'sd3};
        w={16'sd3,16'sd2,-16'sd1,16'sd7,16'sd6,16'sd5};
        base={-48'sd10,48'sd10};
        beat(1,0); repeat(2) @(negedge clk); beat(0,0); beat(0,1);
        repeat(6) @(negedge clk);
        a={3{16'h8000}}; w={6{16'h8000}}; base=0;
        for(t=0;t<9;t=t+1) beat(t==0,t==8);
        repeat(6) @(negedge clk);
        if(count!=2) $fatal(1,"result count mismatch");
        $display("Y26 MAC PASS: signed arithmetic, valid bubbles, base, 48-bit sum"); $finish;
    end
    initial begin #20000; $fatal(1,"watchdog"); end
endmodule
