`timescale 1ns/1ps
// Independent closed-form integer cases, including values beyond signed INT32.
module tb_partial_storage;
 parameter PSUM_BITS=36;
 reg clk=0;always #5 clk=~clk;
 reg resetn=0,start=0,first=1,iwe=0,wwe=0,re=0;
 reg [1:0] k=3,stride=1,ci=3;reg [7:0] width=2;reg [2:0] height=1;
 reg [31:0] tag=1;reg [11:0] ia=0;reg [47:0] id=0,wd=0;reg [3:0] wo=0,wt=0;reg [9:0] ra=0;
 wire [767:0] data;wire busy,done,error;wire [31:0] cycles;
 y26_conv_tile #(.PSUM_BITS(PSUM_BITS)) dut(.clk(clk),.resetn(resetn),.start(start),.cfg_kernel(k),.cfg_stride(stride),.cfg_ci(ci),.cfg_co(5'd16),.cfg_width(width),.cfg_height(height),.cfg_first(first),.cfg_tag(tag),.input_we(iwe),.input_addr(ia),.input_data(id),.weight_we(wwe),.weight_oc(wo),.weight_tap(wt),.weight_data(wd),.result_re(re),.result_addr(ra),.result_data(data),.busy(busy),.done(done),.error(error),.cycles(cycles));
 integer blockno,oc,tap,p,case_id,total_ci,activation,seen=0;longint signed expected,actual;
 task read_check(input integer addr,input longint signed gold);
 begin
  @(negedge clk);ra=addr;re=1;@(negedge clk);
  for(integer o=0;o<16;o=o+1)begin
   actual=$signed(data[o*48+:48]);
   if(actual!==gold)$fatal(1,"PSUM mismatch bits=%0d case=%0d block=%0d pixel=%0d oc=%0d actual=%0d gold=%0d",PSUM_BITS,case_id,blockno,addr,o,actual,gold);
   seen=seen+1;
  end
  re=0;
 end endtask
 initial begin
  repeat(4)@(negedge clk);resetn=1;
  for(case_id=0;case_id<(PSUM_BITS==48?6:5);case_id=case_id+1)begin
   k=case_id<2||case_id>=4?3:1;width=k==3?2:160;height=k==3?1:4;
   activation=case_id==4?255:case_id==5?-32768:case_id%2==0?-128:127;tag=case_id+1;total_ci=0;
   for(blockno=0;blockno<(case_id==4?1:43);blockno=blockno+1)begin
    ci=blockno==42?2:3;first=blockno==0;
    for(p=0;p<(k==3?12:640);p=p+1)begin
     @(negedge clk);iwe=1;ia=p;id={16'(activation),16'(activation),16'(activation)};
    end
    @(negedge clk);iwe=0;
    for(oc=0;oc<16;oc=oc+1)for(tap=0;tap<(k==3?9:1);tap=tap+1)begin
     @(negedge clk);wwe=1;wo=oc;wt=tap;wd={16'h8000,16'h8000,16'h8000};
    end
    @(negedge clk);wwe=0;repeat(2)@(negedge clk);start=1;@(negedge clk);start=0;
    wait(done);if(error)$fatal(1,"Core error");total_ci=total_ci+ci;
    expected=longint'(total_ci)*activation*(-32768)*(k==3?9:1);
    read_check(0,expected);read_check(k==3?1:639,expected);
   end
   $display("PSUM CLOSED FORM case=%0d bits=%0d last=%0d PASS",case_id,PSUM_BITS,expected);
  end
  $display("PSUM STORAGE PASS checked=%0d",seen);$finish;
 end
 initial begin #100000000;$fatal(1,"Timeout");end
endmodule
