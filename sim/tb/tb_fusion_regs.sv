`timescale 1ns/1ps
module tb_fusion_regs;
    reg clk=0;always #5 clk=~clk;
    reg resetn=0,busy=0;
    reg [11:0] awaddr=0,araddr=0;reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
    reg [31:0] wdata=0;reg [3:0] wstrb=0;
    wire awready,wready,bvalid,arready,rvalid;wire [1:0] bresp,rresp;wire [31:0] rdata;
    wire enable,relu;wire [511:0] multipliers;wire [767:0] biases;wire [79:0] shifts;
    y26_fusion_regs dut(.aclk(clk),.aresetn(resetn),.busy(busy),
        .s_axi_awaddr(awaddr),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_araddr(araddr),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
        .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
        .enable(enable),.relu(relu),.multipliers(multipliers),.biases(biases),.shifts(shifts));
    task write_reg(input [11:0] address,input [31:0] data,input [3:0] strobes,input integer aw_delay,input integer w_delay,input [1:0] response);
        begin
            fork
                begin repeat(aw_delay)@(negedge clk);awaddr=address;awvalid=1;@(posedge clk);while(!awready)@(posedge clk);@(negedge clk);awvalid=0;end
                begin repeat(w_delay)@(negedge clk);wdata=data;wstrb=strobes;wvalid=1;@(posedge clk);while(!wready)@(posedge clk);@(negedge clk);wvalid=0;end
            join
            wait(bvalid);if(bresp!==response)$fatal(1,"BRESP mismatch %h",address);
            repeat(3)begin @(posedge clk);if(!bvalid||bresp!==response)$fatal(1,"B not held");end
            @(negedge clk);bready=1;@(posedge clk);@(negedge clk);bready=0;
        end
    endtask
    task read_reg(input [11:0] address,input [31:0] data,input [1:0] response);
        begin
            @(negedge clk);araddr=address;arvalid=1;@(posedge clk);while(!arready)@(posedge clk);
            @(negedge clk);arvalid=0;wait(rvalid);
            repeat(3)begin @(posedge clk);if(!rvalid||rdata!==data||rresp!==response)$fatal(1,"R mismatch %h actual=%h",address,rdata);end
            @(negedge clk);rready=1;@(posedge clk);@(negedge clk);rready=0;
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);resetn=1;
        read_reg(12'h008,32'h59324631,0);read_reg(0,0,0);
        write_reg(12'h100,32'h12345678,15,1,4,0);read_reg(12'h100,32'h12345678,0);
        write_reg(12'h100,32'habcd0000,12,4,1,0);read_reg(12'h100,32'habcd5678,0);
        write_reg(12'h104,31,15,1,1,0);read_reg(12'h104,31,0);
        write_reg(12'h108,32'h89abcdef,15,1,1,0);write_reg(12'h10c,32'hffff,15,1,2,0);
        if(biases[47:0]!==48'hffff89abcdef)$fatal(1,"Bias48 register bank");
        write_reg(12'h1f0,32'hffffffff,15,3,1,0);read_reg(12'h1f0,32'hffffffff,0);
        write_reg(0,3,15,1,1,0);if(!enable||!relu)$fatal(1,"Control register");
        busy=1;read_reg(4,1,0);write_reg(12'h100,0,15,1,1,2);read_reg(12'h100,32'habcd5678,0);
        busy=0;write_reg(12'h104,32,15,1,1,2);read_reg(12'h104,31,0);
        write_reg(12'h10c,32'h10000,15,1,1,2);write_reg(12'h00c,1,15,1,1,2);
        read_reg(12'h300,0,2);write_reg(12'h101,1,15,1,1,2);
        @(negedge clk);awaddr=12'h100;awvalid=1;@(posedge clk);@(negedge clk);awvalid=0;resetn=0;
        repeat(3)@(negedge clk);resetn=1;read_reg(0,0,0);read_reg(12'h100,0,0);
        $display("Y26 FUSION REGS PASS aw_w_independent=1 strobes=1 busy_lock=1 held_responses=1 reset=1");$finish;
    end
    initial begin #200000;$fatal(1,"Timeout");end
endmodule
