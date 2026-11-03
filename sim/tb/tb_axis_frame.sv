`timescale 1ns/1ps
module tb_axis_frame #(parameter THIRD=0);
    reg clk=0,resetn=0;always #5 clk=~clk;
    reg [31:0] sd=0;reg [3:0] sk=15;reg sl=0,sv=0,mr=0;
    wire sr,mv,ml,busy;wire [31:0] md;wire [3:0] mk;
`ifdef Y26_GRAPH_TOP
    y26_axis_graph_top dut(.aclk(clk),.aresetn(resetn),
`elsif Y26_UNIFIED_TOP
    y26_axis_unified_top dut(.aclk(clk),.aresetn(resetn),
`elsif Y26_HOTSPOT_TOP
    y26_axis_hotspot56_top dut(.aclk(clk),.aresetn(resetn),
`elsif Y26_THREE_TOP
    y26_axis_three_top dut(.aclk(clk),.aresetn(resetn),
`else
    y26_axis_frame_top #(.ENABLE_THIRD(THIRD)) dut(.aclk(clk),.aresetn(resetn),
`endif
        .s_axis_tdata(sd),.s_axis_tkeep(sk),.s_axis_tlast(sl),.s_axis_tvalid(sv),.s_axis_tready(sr),
        .m_axis_tdata(md),.m_axis_tkeep(mk),.m_axis_tlast(ml),.m_axis_tvalid(mv),.m_axis_tready(mr),.config_busy(busy));
    reg [31:0] tx[0:131071],gold[0:131071],held;
    reg lastheld,stalled=0;reg [3:0] keepheld;
    integer f,rf,rc,count,n,ntx,nrx,bad,si,ri,ticks=0,compared=0;
    reg [4095:0] vectors,responses;
    always @(posedge clk)begin
        ticks<=ticks+1;if(ticks>30000000)$fatal(1,"FRAME watchdog frame=%0d tx=%0d rx=%0d",n,si,ri);
        if(!resetn)stalled<=0;
        else begin
            if(stalled&&(!mv||md!==held||ml!==lastheld||mk!==keepheld))$fatal(1,"FRAME changed while stalled");
            stalled<=mv&&!mr;held<=md;lastheld<=ml;keepheld<=mk;
        end
    end
    initial begin
        if(!$value$plusargs("VECTORS=%s",vectors)||!$value$plusargs("RESPONSES=%s",responses))$fatal;
        f=$fopen(vectors,"r");rf=$fopen(responses,"w");if(!f||!rf)$fatal;
        repeat(4)@(negedge clk);resetn=1;rc=$fscanf(f,"%d\n",count);
        for(n=0;n<count;n=n+1)begin
            rc=$fscanf(f,"%d %d %d\n",ntx,nrx,bad);
            if(rc!=3||ntx>131072||nrx>131072)$fatal(1,"FRAME vector format");
            for(si=0;si<ntx;si=si+1)rc=$fscanf(f,"%h\n",tx[si]);
            for(ri=0;ri<nrx;ri=ri+1)rc=$fscanf(f,"%h\n",gold[ri]);
            fork
                begin
                    for(si=0;si<ntx;si=si+1)begin
                        @(negedge clk);sv=0;if(si%7==3)@(negedge clk);
                        sd=tx[si];sk=si==bad?7:15;sl=si==ntx-1&&bad!=-3;sv=1;
                        @(posedge clk);while(!sr)@(posedge clk);
                    end
                    @(negedge clk);sv=0;sl=0;sk=15;
                    if(bad==-2||bad==-3)begin
                        repeat(bad==-3?8000:100)@(negedge clk);resetn=0;repeat(4)@(negedge clk);resetn=1;
                    end
                end
                begin
                    ri=0;
                    while(ri<nrx)begin
                        @(negedge clk);mr=ticks%11!=2&&ticks%11!=3&&ticks%11!=4;
                        @(posedge clk);
                        if(mv&&mr)begin
                            if(mk!==15||ml!==(ri==nrx-1&&bad!=-3))$fatal(1,"FRAME framing n=%0d ri=%0d",n,ri);
                            if(gold[ri]!==32'hffffffff&&md!==gold[ri])$fatal(1,"FRAME mismatch n=%0d ri=%0d got=%h expected=%h",n,ri,md,gold[ri]);
                            $fdisplay(rf,"%0d %08x",n,md);ri=ri+1;compared=compared+1;
                        end
                    end
                    @(negedge clk);mr=0;
                end
            join
            $display("FRAME case %0d/%0d PASS ticks=%0d",n+1,count,ticks);
        end
        $fclose(f);$fclose(rf);$display("Y26 RAW FRAME PASS compared_words=%0d",compared);$finish;
    end
endmodule
