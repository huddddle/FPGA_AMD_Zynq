`timescale 1ns/1ps
module tb_tile;
    reg clk=0; always #5 clk=~clk;
    reg resetn=0,start=0,first=0;
    reg [1:0] kernel=3,stride=2,ci=3;
    reg [4:0] co=16;
    reg [7:0] width=1;
    reg [2:0] height=1;
    reg [31:0] tag=0;
    reg iwe=0,wwe=0,re=0;
    reg [11:0] ia=0;
    reg [3:0] wo=0,wt=0;
    reg [47:0] id=0,wd=0;
    reg [9:0] ra=0;
    wire [767:0] rd;
    wire busy,done,error;
    wire [31:0] cycles;
    y26_conv_tile dut(.clk(clk),.resetn(resetn),.start(start),.cfg_kernel(kernel),
        .cfg_stride(stride),.cfg_ci(ci),.cfg_co(co),.cfg_width(width),.cfg_height(height),
        .cfg_first(first),.cfg_tag(tag),.input_we(iwe),.input_addr(ia),.input_data(id),
        .weight_we(wwe),.weight_oc(wo),.weight_tap(wt),.weight_data(wd),
        .result_re(re),.result_addr(ra),.result_data(rd),.busy(busy),.done(done),.error(error),.cycles(cycles));
    integer fileh,r,ncases,c,i,o,t,ph,pw,tries,pixels,checked=0,total_cycles=0;
    integer ki,si,cii,coi,wi,hi,fi,ti;
    reg [47:0] hexvalue,expected;
    reg [2047:0] vectorpath;
    initial begin
        if(!$value$plusargs("VECTORS=%s",vectorpath)) $fatal(1,"missing VECTORS");
        fileh=$fopen(vectorpath,"r"); if(!fileh) $fatal(1,"cannot open vectors");
        r=$fscanf(fileh,"%d",ncases);
        repeat(3) @(negedge clk); resetn=1;
        for(c=0;c<ncases;c=c+1) begin
            r=$fscanf(fileh,"%d %d %d %d %d %d %d %d",ki,si,cii,coi,wi,hi,fi,ti);
            if(r!=8) $fatal(1,"bad case header");
            kernel=ki; stride=si; ci=cii; co=coi; width=wi; height=hi; first=fi; tag=ti;
            ph=(hi-1)*si+ki; pw=(wi-1)*si+ki;
            for(i=0;i<ph*pw;i=i+1) begin
                r=$fscanf(fileh,"%h",hexvalue);
                @(negedge clk); iwe=1; ia=i; id=hexvalue;
            end
            @(negedge clk); iwe=0;
            for(o=0;o<16;o=o+1) for(t=0;t<9;t=t+1) begin
                r=$fscanf(fileh,"%h",hexvalue);
                @(negedge clk); wwe=1; wo=o; wt=t; wd=hexvalue;
            end
            @(negedge clk); wwe=0; start=1;
            @(negedge clk); start=0;
            tries=0;
            while(!done && tries<100000) begin @(negedge clk); tries=tries+1; end
            if(!done || error) $fatal(1,"case %0d failed: done=%b error=%b",c,done,error);
            if($test$plusargs("REQUIRE_K1_PIPELINE") && ki==1 && cycles>wi*hi+12)
                $fatal(1,"1x1 throughput failed case=%0d pixels=%0d cycles=%0d limit=%0d",c,wi*hi,cycles,wi*hi+12);
            total_cycles=total_cycles+cycles;
            pixels=wi*hi;
            for(i=0;i<pixels;i=i+1) begin
                @(negedge clk); re=1; ra=i;
                @(negedge clk); re=0;
                for(o=0;o<coi;o=o+1) begin
                    r=$fscanf(fileh,"%h",expected);
                    if(rd[o*48+:48]!==expected)
                        $fatal(1,"case=%0d pixel=%0d oc=%0d actual=%0d expected=%0d",c,i,o,$signed(rd[o*48+:48]),$signed(expected));
                    checked=checked+1;
                end
            end
        end
        // A stale partial-sum tag must be rejected before computation.
        @(negedge clk); first=0; tag=tag+1; start=1;
        @(negedge clk); start=0;
        if(!done || !error || busy) $fatal(1,"stale accumulation was accepted");
        @(negedge clk); resetn=0;
        repeat(2) @(negedge clk);
        if(busy || done || error) $fatal(1,"reset failed");
        // Reset during a running tile must cancel valid state and partial-sum reuse.
        @(negedge clk); resetn=1; first=1; start=1;
        @(negedge clk); start=0;
        if(!busy) $fatal(1,"restart did not begin");
        repeat(2) @(negedge clk); resetn=0;
        repeat(2) @(negedge clk);
        if(busy || done || error) $fatal(1,"busy reset failed");
        @(negedge clk); resetn=1; first=0; start=1;
        @(negedge clk); start=0;
        if(!done || !error) $fatal(1,"reset left stale partial sums valid");
        $display("Y26 TILE PASS cases=%0d compared=%0d compute_cycles=%0d",ncases,checked,total_cycles);
        $finish;
    end
    initial begin #200000000; $fatal(1,"watchdog"); end
endmodule
