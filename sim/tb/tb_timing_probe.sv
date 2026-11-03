`timescale 1ns/1ps
// Functional clock-buffer model only. Vivado hardware synthesis uses its BUFG.
module BUFG(input wire I, output wire O);
    assign O=I;
endmodule

module tb_timing_probe;
    reg clk=0; always #5 clk=~clk;
    reg shift_enable=0,commit=0,capture=0,serial_in=0;
    wire serial_out;
    y26_timing_probe dut(.clk(clk),.shift_enable(shift_enable),.commit(commit),
        .capture(capture),.serial_in(serial_in),.serial_out(serial_out));

    reg rn=0,go=0,first=1,iwe=0,wwe=0,re=0;
    reg [1:0] k=1,s=1,ci=1;
    reg [4:0] co=2;
    reg [7:0] width=1;
    reg [2:0] height=1;
    reg [31:0] tag=32'h13579bdf;
    reg [11:0] ia=0;
    reg [47:0] id=0,wd=0;
    reg [3:0] wo=0,wt=0;
    reg [9:0] ra=0;
    reg [802:0] response,second_response;
    integer checked=0,j;
    reg signed [47:0] spatial_expected[0:3];

    function [185:0] command_frame;
        input dummy;
        begin
            command_frame={rn,go,k,s,ci,co,width,height,first,tag,
                           iwe,ia,id,wwe,wo,wt,wd,re,ra};
        end
    endfunction

    task send_command;
        reg [185:0] frame;
        integer i;
        begin
            frame=command_frame(0);
            for(i=185;i>=0;i=i-1) begin
                @(negedge clk); shift_enable=1; serial_in=frame[i];
            end
            @(negedge clk); shift_enable=0; serial_in=0; commit=1;
            @(negedge clk); commit=0;
            repeat(3) @(negedge clk);
        end
    endtask

    task read_snapshot;
        output [802:0] value;
        integer i;
        begin
            @(negedge clk); capture=1;
            @(negedge clk); capture=0;
            for(i=0;i<803;i=i+1) begin
                value[i]=serial_out;
                shift_enable=1; serial_in=0;
                @(negedge clk);
            end
            shift_enable=0;
        end
    endtask

    task expect_idle_success;
        input [802:0] value;
        begin
            if(value[770:768]!==3'b010)
                $fatal(1,"expected error=0 done_seen=1 busy=0, got %b",value[770:768]);
            if(value[802:771]===32'b0 || ^value[802:771]===1'bx)
                $fatal(1,"invalid completed-cycle counter");
        end
    endtask

    initial begin
        // Reset and all stimulus go through the public serial command interface.
        send_command(); rn=1; send_command();
        read_snapshot(response);
        if(response[770:768]!==3'b000) $fatal(1,"serial reset failed");

        // Two independent output channels: 3*(-7)=-21 and 3*5=15.
        wwe=1; wo=0; wd=48'h00000000fff9; send_command();
        wo=1; wd=48'd5; send_command(); wwe=0;
        iwe=1; id=48'd3; send_command(); iwe=0;
        go=1; send_command(); go=0;
        repeat(50) @(negedge clk);
        read_snapshot(response); expect_idle_success(response);
        // Reading shifts the next frame but must never execute it or replay go=1.
        repeat(100) @(negedge clk);
        read_snapshot(second_response); expect_idle_success(second_response);
        if(response[802:771]!==second_response[802:771])
            $fatal(1,"a latched start bit replayed a command without commit");
        re=1; send_command(); re=0;
        read_snapshot(response);
        if($signed(response[47:0])!==-48'sd21 || $signed(response[95:48])!==48'sd15)
            $fatal(1,"signed two-lane convolution mismatch");
        checked=checked+2;

        // A second input-channel block adds (-2)*[-7,5] to the resident sums.
        iwe=1; id=48'h00000000fffe; send_command(); iwe=0;
        first=0; go=1; send_command(); go=0;
        repeat(50) @(negedge clk);
        re=1; send_command(); re=0; read_snapshot(response);
        expect_idle_success(response);
        if($signed(response[47:0])!==-48'sd7 || $signed(response[95:48])!==48'sd5)
            $fatal(1,"partial-sum reuse mismatch");
        checked=checked+2;

        // Known exact INT48 result: 3*(-32768)*(-32768)=3221225472, above INT32.
        ci=3; co=1; tag=tag+1; first=1;
        wwe=1; wo=0; wd=48'h800080008000; send_command(); wwe=0;
        iwe=1; id=48'h800080008000; send_command(); iwe=0;
        go=1; send_command(); go=0; repeat(50) @(negedge clk);
        re=1; send_command(); re=0; read_snapshot(response);
        expect_idle_success(response);
        if($signed(response[47:0])!==48'sd3221225472) $fatal(1,"INT48 readback mismatch");
        checked=checked+1;

        // Hand-worked 5x5 patch, 3x3 all-one kernel, stride 2: [63,81;153,171].
        ci=1; co=1; k=3; s=2; width=2; height=2; tag=tag+1; first=1;
        wwe=1; wo=0; wd=48'd1;
        for(j=0;j<9;j=j+1) begin wt=j; send_command(); end
        wwe=0; iwe=1;
        for(j=0;j<25;j=j+1) begin ia=j; id=j+1; send_command(); end
        iwe=0; go=1; send_command(); go=0; repeat(200) @(negedge clk);
        spatial_expected[0]=63; spatial_expected[1]=81;
        spatial_expected[2]=153; spatial_expected[3]=171;
        re=1;
        for(j=0;j<4;j=j+1) begin
            ra=j; send_command(); read_snapshot(response); expect_idle_success(response);
            if($signed(response[47:0])!==spatial_expected[j]) $fatal(1,"3x3 stride2 readback mismatch");
            checked=checked+1;
        end
        re=0;

        // Invalid accumulation must reach the caller as error/done, not busy.
        first=0; tag=tag+1; go=1; send_command(); go=0;
        repeat(20) @(negedge clk); read_snapshot(response);
        if(response[770:768]!==3'b110) $fatal(1,"stale tag not rejected through serial API");
        $display("Y26 TIMING PROBE SIM PASS jobs=5 compared=%0d serial_only=1 no_start_replay=1",checked);
        $finish;
    end
    initial begin #2000000; $fatal(1,"watchdog"); end
endmodule
