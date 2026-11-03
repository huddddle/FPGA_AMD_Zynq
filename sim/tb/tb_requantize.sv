`timescale 1ns/1ps
module tb_requantize;
    reg clk=0;always #5 clk=~clk;
    reg resetn=0,in_valid=0,out_ready=0;
    wire in_ready,out_valid;
    reg signed [47:0] acc,bias;
    reg [31:0] m0;reg [4:0] shift;
    reg relu,in_last;
    wire [7:0] value;wire out_last;
    y26_requantize dut(.clk(clk),.resetn(resetn),.in_valid(in_valid),.in_ready(in_ready),
        .accumulator(acc),.bias(bias),.multiplier(m0),.shift(shift),.relu(relu),.in_last(in_last),
        .out_valid(out_valid),.out_ready(out_ready),.value(value),.out_last(out_last));
    reg [47:0] av[0:12000],bv[0:12000];reg [31:0] mv[0:12000];
    reg [4:0] nv[0:12000];reg rv[0:12000];reg [7:0] expected[0:12000];
    integer file,count,i,scanned,send_count=0,receive_count=0,cycles=0,total_compared=0;
    reg stalled=0,accepted_input=0;reg [7:0] held;reg held_last;
    reg [2047:0] vector_path;
    initial begin
        if(!$value$plusargs("VECTORS=%s",vector_path))$fatal(1,"Missing VECTORS");
        file=$fopen(vector_path,"r");scanned=$fscanf(file,"%d\n",count);
        if(count>12000||count<1)$fatal(1,"Vector size");
        for(i=0;i<count;i=i+1)scanned=$fscanf(file,"%h %h %h %h %h %h\n",av[i],bv[i],mv[i],nv[i],rv[i],expected[i]);
        $fclose(file);repeat(4)@(negedge clk);resetn=1;
    end
    always @(negedge clk)if(resetn)begin
        cycles=cycles+1;out_ready=(cycles%7!=2)&&(cycles%11!=4);
        if(!in_valid||accepted_input)begin
            if(send_count<count&&cycles%5!=1)begin
                acc=av[send_count];bias=bv[send_count];m0=mv[send_count];shift=nv[send_count];
                relu=rv[send_count];in_last=send_count%11==10;in_valid=1;
            end else in_valid=0;
        end
        if(cycles>100000)$fatal(1,"Timeout");
    end
    always @(posedge clk)if(resetn)begin
        accepted_input=in_valid&&in_ready;
        if(stalled&&(!out_valid||value!==held||out_last!==held_last))$fatal(1,"Unstable backpressure");
        stalled=out_valid&&!out_ready;held=value;held_last=out_last;
        if(in_valid&&in_ready)send_count=send_count+1;
        if(out_valid&&out_ready)begin
            if(receive_count>=count||value!==expected[receive_count]||out_last!==(receive_count%11==10))
                $fatal(1,"Mismatch index=%0d expected=%h actual=%h",receive_count,expected[receive_count],value);
            receive_count=receive_count+1;total_compared=total_compared+1;
            if(receive_count==count)begin
                $display("Y26 REQUANTIZE PASS compared=%0d cycles=%0d backpressure=1",total_compared,cycles);$finish;
            end
        end
    end
endmodule
