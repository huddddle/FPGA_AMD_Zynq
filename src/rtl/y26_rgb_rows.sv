`timescale 1ns/1ps
// Nine-row circular FIFO storage. Each block adds eight rows and retains its
// predecessor's final row. AXIS backpressure prevents overwrite during compute.
// WIDTH must be a multiple of four; HEIGHT a multiple of eight.
module y26_rgb_rows #(parameter WIDTH=320,HEIGHT=320)(
    input wire clk,resetn,start,advance,
    input wire [31:0] s_data,input wire [3:0] s_keep,
    input wire s_last,s_valid,output wire s_ready,
    output reg block_ready,ended,error,output reg [31:0] accepted_words,
    input wire read_en,input wire [11:0] read_addr,output reg [23:0] read_data
);
    (* ram_style="block" *) reg [23:0] rows[0:WIDTH*9-1];
    reg active;reg [95:0] bytes_q;reg [1:0] words_q,pixel_q;
    reg [8:0] write_x;reg [3:0] slot;reg [2:0] block_row;
    assign s_ready=resetn&&active&&!block_ready&&!error&&words_q!=3;
    always @(posedge clk)begin
        if(read_en)read_data<=rows[read_addr];
        if(resetn&&active&&!block_ready&&!error&&words_q==3)
            rows[slot*WIDTH+write_x]<=bytes_q[23:0];
    end
    always @(posedge clk)begin
        if(!resetn||start)begin
            active<=resetn&&start;bytes_q<=0;words_q<=0;pixel_q<=0;
            write_x<=0;slot<=0;block_row<=0;block_ready<=0;ended<=0;error<=0;accepted_words<=0;
        end else begin
            if(advance&&block_ready)begin block_ready<=0;block_row<=0;end
            if(s_valid&&s_ready)begin
                bytes_q[words_q*32+:32]<=s_data;words_q<=words_q+1;
                accepted_words<=accepted_words+1;
                if(s_last)ended<=1;
                if(s_keep!=15||s_last!=(accepted_words==WIDTH*HEIGHT*3/4-1))error<=1;
            end
            if(active&&!block_ready&&!error&&words_q==3)begin
                bytes_q<={24'd0,bytes_q[95:24]};
                if(pixel_q==3)begin pixel_q<=0;words_q<=0;end else pixel_q<=pixel_q+1;
                if(write_x==WIDTH-1)begin
                    write_x<=0;slot<=slot==8?0:slot+1;
                    if(block_row==7)block_ready<=1;else block_row<=block_row+1;
                end else write_x<=write_x+1;
            end
        end
    end
endmodule
