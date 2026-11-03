`timescale 1ns/1ps
// Runtime-configurable convolution tile. Global padding/groups/channel tiling are
// planned by PS. One job: <=3 input channels, <=16 output channels, <=4x160 output.
// first=0 adds the next input-channel block to resident 48-bit partial sums.
// No bias, scaling, SiLU, ReLU, Linux addresses, or clocks generated in this core.
module y26_conv_tile #(parameter PIPELINE_K1=1, parameter PSUM_BITS=48)(
    input wire clk,resetn,start,
    input wire [1:0] cfg_kernel,cfg_stride,cfg_ci,
    input wire [4:0] cfg_co,
    input wire [7:0] cfg_width,
    input wire [2:0] cfg_height,
    input wire cfg_first,
    input wire [31:0] cfg_tag,
    input wire input_we,
    input wire [11:0] input_addr,
    input wire [47:0] input_data,
    input wire weight_we,
    input wire [3:0] weight_oc,weight_tap,
    input wire [47:0] weight_data,
    input wire result_re,
    input wire [9:0] result_addr,
    output wire [767:0] result_data,
    output reg busy,done,error,
    output reg [31:0] cycles
);
    localparam IDLE=0,BASE=1,ISSUE=2,WAIT_RESULT=3,FINISH=4,K1_RUN=5,K1_DRAIN=6;
    reg [2:0] state;
    reg [1:0] k,s,ci,ty,tx;
    reg [4:0] co;
    reg [7:0] ow,px;
    reg [2:0] oh,py;
    reg first_block,psum_valid;
    reg [31:0] saved_tag;
    reg [9:0] pixel;
    reg [11:0] pixel_base,row_base;
    reg [9:0] patch_width;
    (* ram_style="block" *) reg [47:0] input_mem[0:2888];
    reg [47:0] input_q;
    // Register the external write interface before BRAM/LUTRAM. Accepted writes
    // drain one cycle later, including the final idle-cycle write before start.
    reg input_pending,weight_pending;
    reg [11:0] input_addr_q;
    reg [3:0] weight_oc_q,weight_tap_q;
    reg [47:0] input_data_q,weight_data_q;
    reg rv,rf,rl;
    wire [11:0] tap_row=ty==0 ? 12'd0 : ty==1 ? {2'b0,patch_width} : {1'b0,patch_width,1'b0};
    wire [11:0] input_read_addr=pixel_base+tap_row+tx;
    wire [3:0] tap_index=ty*3+tx;
    wire last_tap=(tx==k-1 && ty==k-1);
    wire [47:0] active_input={ci>=3 ? input_q[47:32] : 16'b0,
                             ci>=2 ? input_q[31:16] : 16'b0,input_q[15:0]};
    wire [767:0] wq,base_vector,mac_result;
    wire mac_valid;
    wire k1_mode=PIPELINE_K1 && k==1;
    reg k1_read_valid;
    reg [9:0] k1_addr[0:3];
    reg [767:0] k1_base0,k1_base1;
    wire [9:0] write_pixel=k1_mode?k1_addr[3]:pixel;
    wire valid_cfg=(cfg_kernel==1 || cfg_kernel==3) && (cfg_stride==1 || cfg_stride==2)
                   && cfg_ci>=1 && cfg_ci<=3 && cfg_co>=1 && cfg_co<=16
                   && cfg_width>=1 && cfg_width<=160 && cfg_height>=1 && cfg_height<=4;
    wire compatible=psum_valid && saved_tag==cfg_tag && ow==cfg_width && oh==cfg_height
                    && co==cfg_co && k==cfg_kernel && s==cfg_stride;
    wire partial_read=(state==BASE || state==K1_RUN) || (!busy && result_re && result_addr<640);
    wire [9:0] partial_addr=(state==BASE || state==K1_RUN) ? pixel : result_addr;

    // A 1x1 pixel has no tap recurrence. Keep different pixels in flight;
    // align the BRAM base with the MAC's multiply/sum/accumulate pipeline.
    integer ai;
    always @(posedge clk) begin
        if(!resetn) begin
            k1_read_valid<=0;k1_base0<=0;k1_base1<=0;
            for(ai=0;ai<4;ai=ai+1)k1_addr[ai]<=0;
        end else begin
            k1_read_valid<=state==K1_RUN;
            if(state==K1_RUN)k1_addr[0]<=pixel;
            for(ai=1;ai<4;ai=ai+1)k1_addr[ai]<=k1_addr[ai-1];
            if(k1_read_valid)k1_base0<=base_vector;
            k1_base1<=k1_base0;
        end
    end

    always @(posedge clk) begin
        if(!resetn) begin input_pending<=0; weight_pending<=0; end
        else begin
            input_pending<=!busy && input_we && input_addr<2889;
            weight_pending<=!busy && weight_we && weight_tap<9;
            if(!busy && input_we) begin input_addr_q<=input_addr; input_data_q<=input_data; end
            if(!busy && weight_we) begin
                weight_oc_q<=weight_oc; weight_tap_q<=weight_tap; weight_data_q<=weight_data;
            end
        end
    end

    y26_mac_array mac(.clk(clk),.resetn(resetn),.in_valid(k1_mode?k1_read_valid:rv),
                     .in_first(k1_mode?1'b1:rf),.in_last(k1_mode?1'b1:rl),
                     .activations(active_input),.weights(wq),.base(k1_mode?k1_base1:base_vector),
                     .out_valid(mac_valid),.result(mac_result));
    genvar o;
    generate for(o=0;o<16;o=o+1) begin: output_bank
        reg [47:0] weights[0:8];
        reg [47:0] weight_q;
        reg [PSUM_BITS-1:0] stored_q;
        wire [47:0] read_q={{(48-PSUM_BITS){stored_q[PSUM_BITS-1]}},stored_q};
        (* ram_style="block" *) reg [PSUM_BITS-1:0] partial[0:639];
        assign wq[o*48+:48]=weight_q;
        assign base_vector[o*48+:48]=first_block ? 48'd0 : read_q;
        assign result_data[o*48+:48]=read_q;
        always @(posedge clk) begin
            if(weight_pending && weight_oc_q==o) weights[weight_tap_q]<=weight_data_q;
            if(state==ISSUE || state==K1_RUN) weight_q<=weights[k1_mode?4'd0:tap_index];
            if((state==WAIT_RESULT || state==K1_RUN || state==K1_DRAIN) && mac_valid)
                partial[write_pixel]<=mac_result[o*48+:PSUM_BITS];
            if(partial_read) stored_q<=partial[partial_addr];
        end
        // The narrowed instance is allowed only with the documented activation
        // and channel bounds. Never silently wrap a value outside that contract.
        // synthesis translate_off
        if(PSUM_BITS<48)begin: check_storage_range
            always @(posedge clk)if(resetn&&(state==WAIT_RESULT||state==K1_RUN||state==K1_DRAIN)&&mac_valid)
                assert(mac_result[o*48+:48]=={{(48-PSUM_BITS){mac_result[o*48+PSUM_BITS-1]}},mac_result[o*48+:PSUM_BITS]})
                else $fatal(1,"Partial sum exceeds selected storage width");
        end
        // synthesis translate_on
    end endgenerate
    always @(posedge clk) begin
        if(input_pending) input_mem[input_addr_q]<=input_data_q;
        if(state==ISSUE || state==K1_RUN) input_q<=input_mem[input_read_addr];
    end
    always @(posedge clk) begin
        if(!resetn) begin
            state<=IDLE; busy<=0; done<=0; error<=0; cycles<=0; psum_valid<=0;
            rv<=0; rf<=0; rl<=0; k<=0; s<=0; ci<=0; co<=0; ow<=0; oh<=0;
            px<=0; py<=0; tx<=0; ty<=0; pixel<=0; pixel_base<=0; row_base<=0;
            patch_width<=0; saved_tag<=0; first_block<=0;
        end else begin
            done<=0; rv<=0; rf<=0; rl<=0;
            if(busy) cycles<=cycles+1;
            case(state)
                IDLE: if(start) begin
                    if(!valid_cfg || (!cfg_first && !compatible)) begin
                        error<=1; done<=1; psum_valid<=0;
                    end else begin
                        k<=cfg_kernel; s<=cfg_stride; ci<=cfg_ci; co<=cfg_co;
                        ow<=cfg_width; oh<=cfg_height; saved_tag<=cfg_tag;
                        first_block<=cfg_first; psum_valid<=0;
                        patch_width<=({2'b0,cfg_width}-10'd1)*cfg_stride+cfg_kernel;
                        px<=0; py<=0; tx<=0; ty<=0; pixel<=0; pixel_base<=0; row_base<=0;
                        cycles<=0; busy<=1; error<=0; state<=PIPELINE_K1&&cfg_kernel==1?K1_RUN:BASE;
                    end
                end
                BASE: begin tx<=0; ty<=0; state<=ISSUE; end
                ISSUE: begin
                    rv<=1; rf<=(tx==0 && ty==0); rl<=last_tap;
                    if(last_tap) state<=WAIT_RESULT;
                    else if(tx==k-1) begin tx<=0; ty<=ty+1; end
                    else tx<=tx+1;
                end
                WAIT_RESULT: if(mac_valid) begin
                    if(px==ow-1 && py==oh-1) state<=FINISH;
                    else begin
                        pixel<=pixel+1;
                        if(px==ow-1) begin
                            px<=0; py<=py+1;
                            row_base<=row_base+(s==2 ? {1'b0,patch_width,1'b0} : {2'b0,patch_width});
                            pixel_base<=row_base+(s==2 ? {1'b0,patch_width,1'b0} : {2'b0,patch_width});
                        end else begin px<=px+1; pixel_base<=pixel_base+s; end
                        state<=BASE;
                    end
                end
                K1_RUN: begin
                    if(px==ow-1 && py==oh-1) state<=K1_DRAIN;
                    else begin
                        pixel<=pixel+1;
                        if(px==ow-1) begin
                            px<=0;py<=py+1;
                            row_base<=row_base+(s==2 ? {1'b0,patch_width,1'b0} : {2'b0,patch_width});
                            pixel_base<=row_base+(s==2 ? {1'b0,patch_width,1'b0} : {2'b0,patch_width});
                        end else begin px<=px+1;pixel_base<=pixel_base+s;end
                    end
                end
                K1_DRAIN: if(mac_valid && write_pixel==ow*oh-1) state<=FINISH;
                FINISH: begin busy<=0; done<=1; psum_valid<=1; state<=IDLE; end
                default: begin busy<=0; error<=1; psum_valid<=0; state<=IDLE; end
            endcase
        end
    end
endmodule

// Internal shared compute fabric. Kept with the tile so existing standalone
// project source lists still contain its definition. Only one instance is used
// by the unified system; controller-local instances are elaborated out.
module y26_compute_unit #(parameter PSUM_BITS=48)(
    input wire clk,
    input wire [185:0] core_command,output wire [802:0] core_response,
    input wire [137:0] tail_command,output wire [10:0] tail_response
);
    wire cr,cs,first,iwe,wwe,re;
    wire [1:0] k,s,ci;wire [4:0] co;wire [7:0] width;wire [2:0] height;
    wire [31:0] tag;wire [11:0] ia;wire [47:0] id,wd;wire [3:0] wo,wt;wire [9:0] ra;
    wire busy,done,error;wire [31:0] cycles;wire [767:0] data;
    // High to low: reset,start,kernel,stride,ci,co,width,height,first,tag,
    // input_we/addr/data, weight_we/oc/tap/data, result_re/addr.
    assign {cr,cs,k,s,ci,co,width,height,first,tag,iwe,ia,id,wwe,wo,wt,wd,re,ra}=core_command;
    y26_conv_tile #(.PSUM_BITS(PSUM_BITS)) core(.clk(clk),.resetn(cr),.start(cs),.cfg_kernel(k),.cfg_stride(s),.cfg_ci(ci),.cfg_co(co),
        .cfg_width(width),.cfg_height(height),.cfg_first(first),.cfg_tag(tag),
        .input_we(iwe),.input_addr(ia),.input_data(id),.weight_we(wwe),.weight_oc(wo),.weight_tap(wt),.weight_data(wd),
        .result_re(re),.result_addr(ra),.result_data(data),.busy(busy),.done(done),.error(error),.cycles(cycles));
    assign core_response={busy,done,error,cycles,data};
    wire tr,tv,tor,rel,last,ready,valid,out_last;wire signed [47:0] acc,bias;
    wire [31:0] m;wire [4:0] n;wire [7:0] value;
    assign {tr,tv,tor,acc,bias,m,n,rel,last}=tail_command;
    y26_requantize tail(.clk(clk),.resetn(tr),.in_valid(tv),.in_ready(ready),.accumulator(acc),.bias(bias),
        .multiplier(m),.shift(n),.relu(rel),.in_last(last),.out_valid(valid),.out_ready(tor),.value(value),.out_last(out_last));
    assign tail_response={ready,valid,out_last,value};
endmodule
