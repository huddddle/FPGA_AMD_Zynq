`timescale 1ns/1ps
// Public stream/read interfaces only: RGB byte order, circular reuse and restart.
module tb_rgb_rows;
    reg clk=0,rst=0,start=0,advance=0,sv=0,sl=0,re=0;
    always #5 clk=~clk;
    reg [31:0] sd=0;reg [3:0] sk=15;reg [11:0] ra=0;
    wire sr,ready,ended,error;wire [23:0] rd;wire [31:0] words;
    y26_rgb_rows #(.WIDTH(8),.HEIGHT(24)) dut(.clk(clk),.resetn(rst),.start(start),.advance(advance),
        .s_data(sd),.s_keep(sk),.s_last(sl),.s_valid(sv),.s_ready(sr),
        .block_ready(ready),.ended(ended),.error(error),.accepted_words(words),
        .read_en(re),.read_addr(ra),.read_data(rd));
    integer i,j,b,x,y,cycles=0;
    reg [7:0] bytes[0:575];
    always @(posedge clk)begin cycles<=cycles+1;if(cycles>10000)$fatal(1,"RGB rows watchdog");end
    task restart;
        begin @(negedge clk);start=1;@(negedge clk);start=0;end
    endtask
    task beat(input [31:0] data,input last,input [3:0] keep);
        begin @(negedge clk);sv=1;sd=data;sl=last;sk=keep;@(posedge clk);while(!sr)@(posedge clk);@(negedge clk);sv=0;end
    endtask
    task check_pixel(input integer yy,input integer xx);
        reg [23:0] expected;
        begin
            expected={bytes[(yy*8+xx)*3+2],bytes[(yy*8+xx)*3+1],bytes[(yy*8+xx)*3]};
            @(negedge clk);ra=(yy%9)*8+xx;re=1;@(negedge clk);re=0;
            if(rd!==expected)$fatal(1,"RGB row mismatch y=%0d x=%0d got=%h expected=%h",yy,xx,rd,expected);
        end
    endtask
    initial begin
        for(i=0;i<576;i=i+1)bytes[i]=(i*73+129)%256;
        repeat(3)@(negedge clk);rst=1;restart;
        for(b=0;b<3;b=b+1)begin
            for(j=0;j<48;j=j+1)begin
                i=b*192+j*4;beat({bytes[i+3],bytes[i+2],bytes[i+1],bytes[i]},b==2&&j==47,15);
            end
            wait(ready);if(error)$fatal(1,"Unexpected frame error");
            // Previous block's final row survives while the next eight replace older rows.
            for(y=(b==0?0:b*8-1);y<(b+1)*8;y=y+1)
                for(x=0;x<8;x=x+1)check_pixel(y,x);
            @(negedge clk);advance=1;@(negedge clk);advance=0;
        end
        if(!ended||words!=144)$fatal(1,"RGB end/word count mismatch");
        restart;beat(32'hdeadbeef,1,7);repeat(8)@(negedge clk);
        if(!error||!ended)$fatal(1,"Bad keep/early TLAST not rejected");
        restart;if(error||ended||ready||words!=0)$fatal(1,"Frame restart retained state");
        $display("Y26 RGB ROWS PASS: 9-row reuse, unsigned RGB order, malformed frame and restart");$finish;
    end
endmodule
