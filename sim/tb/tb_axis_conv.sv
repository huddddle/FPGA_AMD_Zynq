`timescale 1ns/1ps
// Only public AXIS pins are used. Source gaps and sink backpressure are independent.
module tb_axis_conv;
    reg clk=0, resetn=0;
    always #5 clk=~clk;
    reg [31:0] sdata=0;
    reg [3:0] skeep=15;
    reg slast=0,svalid=0;
    wire sready;
    wire [31:0] mdata;
    wire [3:0] mkeep;
    wire mlast,mvalid;
    reg mready=0;
    y26_axis_conv dut(.aclk(clk),.aresetn(resetn),
        .s_axis_tdata(sdata),.s_axis_tkeep(skeep),.s_axis_tlast(slast),
        .s_axis_tvalid(svalid),.s_axis_tready(sready),
        .m_axis_tdata(mdata),.m_axis_tkeep(mkeep),.m_axis_tlast(mlast),
        .m_axis_tvalid(mvalid),.m_axis_tready(mready));
    reg [31:0] tx[0:32767],gold[0:32767];
    reg [31:0] held_data;
    reg [3:0] held_keep;
    reg held_last,stalled=0;
    integer f,rf,rc,cases,n,ntx,nrx,badkeep,si,ri,ticks=0,compared=0;
    reg [4095:0] vector_path,response_path;
    always @(posedge clk) begin
        if(!resetn) stalled<=0;
        else begin
            if(stalled && (!mvalid || mdata!==held_data || mkeep!==held_keep || mlast!==held_last))
                $fatal(1,"AXIS response changed under backpressure");
            stalled<=mvalid&&!mready;
            held_data<=mdata; held_keep<=mkeep; held_last<=mlast;
        end
        ticks<=ticks+1;
        if(ticks>6000000) $fatal(1,"AXIS watchdog timeout");
    end
    initial begin
        if(!$value$plusargs("VECTORS=%s",vector_path)) $fatal(1,"Missing vectors");
        f=$fopen(vector_path,"r"); if(!f) $fatal(1,"Cannot open vectors");
        if(!$value$plusargs("RESPONSES=%s",response_path)) $fatal(1,"Missing response path");
        rf=$fopen(response_path,"w"); if(!rf) $fatal(1,"Cannot create responses");
        repeat(4) @(negedge clk); resetn=1;
        // Reset in the middle of a header must discard it, with no stale response.
        sdata=32'h59323643; svalid=1; @(negedge clk);
        sdata=32'h00010001; @(negedge clk);
        svalid=0; resetn=0; repeat(3) @(negedge clk); resetn=1;
        rc=$fscanf(f,"%d\n",cases); if(rc!=1) $fatal(1,"Bad case count");
        for(n=0;n<cases;n=n+1) begin
            rc=$fscanf(f,"%d %d %d\n",ntx,nrx,badkeep);
            if(rc!=3 || ntx>32768 || nrx>32768) $fatal(1,"Bad frame lengths");
            for(si=0;si<ntx;si=si+1) rc=$fscanf(f,"%h\n",tx[si]);
            for(ri=0;ri<nrx;ri=ri+1) rc=$fscanf(f,"%h\n",gold[ri]);
            fork
                begin
                    for(si=0;si<ntx;si=si+1) begin
                        @(negedge clk); svalid=0;
                        if(si%7==3) @(negedge clk);
                        sdata=tx[si]; skeep=si==badkeep ? 4'h7 : 4'hf;
                        slast=si==ntx-1; svalid=1;
                        @(posedge clk); while(!sready) @(posedge clk);
                    end
                    @(negedge clk); svalid=0; slast=0; skeep=15;
                end
                begin
                    ri=0;
                    while(ri<nrx) begin
                        @(negedge clk); mready=(ticks%11!=2 && ticks%11!=3 && ticks%11!=4);
                        @(posedge clk);
                        if(mvalid&&mready) begin
                            $fdisplay(rf,"%0d %08x",n,mdata);
                            if(mkeep!==15 || mlast!==(ri==nrx-1))
                                $fatal(1,"Response framing case=%0d word=%0d",n,ri);
                            if(!(ri==7 && gold[ri]==32'hffffffff) && mdata!==gold[ri])
                                $fatal(1,"Mismatch case=%0d word=%0d got=%h expected=%h",n,ri,mdata,gold[ri]);
                            if(ri==7 && gold[ri]==32'hffffffff && !mdata)
                                $fatal(1,"Convolution cycle counter is zero");
                            ri=ri+1; compared=compared+1;
                        end
                    end
                    @(negedge clk); mready=0;
                end
            join
        end
        $fclose(f);$fclose(rf);
        $display("Y26 AXIS PASS frames=%0d compared_words=%0d reset_mid_header=1 backpressure=1",cases,compared);
        $finish;
    end
endmodule
