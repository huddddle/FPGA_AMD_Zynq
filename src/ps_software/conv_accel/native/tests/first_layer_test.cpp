#include "first_layer.hpp"
#include <cmath>
#include <cfenv>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <vector>
int main() {
    try {
        const std::string graph="7767517\n2 2\nInput in0 0 1 in0\nConvolution convrelu_0 1 1 in0 1 0=16 1=3 2=1 3=2 4=1 5=1 6=432 9=1\n";
        std::vector<float> raw(1+432+16,0);
        raw[1+4]=-7;raw[1+27+4]=5;raw[1+432]=.25f;raw[1+433]=-.5f;
        y26::Context context;ncnn::Net net;
        net.opt.use_packing_layout=false;net.opt.num_threads=1;
        if(y26::register_first_layer(net,context)!=0||net.load_param_mem(y26::adapt_first_layer_graph(graph).c_str())!=0||
           net.load_model(reinterpret_cast<const unsigned char*>(raw.data()))<=0)throw std::runtime_error("tiny model load");
        ncnn::Mat input(320,320,3);input.fill(.8f);auto ex=net.create_extractor();
        ncnn::Mat output;if(ex.input("in0",input)||ex.extract("1",output))throw std::runtime_error("tiny forward");
        if(output.w!=160||output.h!=160||output.c!=16||context.transactions!=40)throw std::runtime_error("shape/tiles");
        const float* negative=output.channel(0);const float* positive=output.channel(1);
        for(int i=0;i<160*160;++i)if(negative[i]!=0||std::abs(positive[i]-3.5f)>1e-5f)throw std::runtime_error("PS ReLU/bias/scales mismatch");
        context.profile_enabled=true;
        auto profiled_ex=net.create_extractor();ncnn::Mat profiled;
        if(profiled_ex.input("in0",input)||profiled_ex.extract("1",profiled))throw std::runtime_error("profiled forward");
        const auto& timing=context.profile;
        if(timing.total_ms<=0||timing.input_quantize_ms<=0||timing.backend_ms<=0||timing.transfer.calls!=0||timing.core_cycles!=0)
            throw std::runtime_error("profile scope/counters");
        for(int c=0;c<16;++c)if(std::memcmp(profiled.channel(c),output.channel(c),160*160*4))throw std::runtime_error("profiling changed output");
        std::cout<<"PROFILE NUMERIC PASS enabled_output_identical=1 reference_has_no_dma=1\n";
        std::vector<float> probes={0.f,-0.f,1.f,1.000001f,std::nextafter(0.f,1.f)};
        for(int i=0;i<256;++i)probes.push_back(float(i)/255.f);
        for(int i=0;i<255;++i){
            const float midpoint=float((double(i)+.5)/255.);
            probes.push_back(std::nextafter(midpoint,0.f));probes.push_back(midpoint);
            probes.push_back(std::nextafter(midpoint,1.f));
        }
        float* pixels=input.channel(0);
        for(int y=0;y<160;++y)for(int x=0;x<160;++x)pixels[y*2*320+x*2]=probes[(y*160+x)%probes.size()];
        for(int mode:{FE_TONEAREST,FE_DOWNWARD,FE_UPWARD,FE_TOWARDZERO}){
            if(std::fesetround(mode))throw std::runtime_error("set rounding mode");
            auto edge_ex=net.create_extractor();ncnn::Mat edge;
            if(edge_ex.input("in0",input)||edge_ex.extract("1",edge))throw std::runtime_error("rounding edge forward");
            for(int y=0;y<160;++y)for(int x=0;x<160;++x){
                const auto q=std::int64_t(std::nearbyint(double(pixels[y*2*320+x*2])*255.));
                if(context.accumulator[(160+y)*160+x]!=q*32767)throw std::runtime_error("RGB quantization rounding changed");
            }
        }
        std::fesetround(FE_TONEAREST);
        auto capture_ex=net.create_extractor();ncnn::Mat captured;
        if(capture_ex.input("in0",input)||capture_ex.extract("1",captured))throw std::runtime_error("capture reference");
        context.capture_accumulator=false;
        auto lean_ex=net.create_extractor();ncnn::Mat lean;
        if(lean_ex.input("in0",input)||lean_ex.extract("1",lean)||!context.accumulator.empty())throw std::runtime_error("optional capture not disabled");
        for(int c=0;c<16;++c)if(std::memcmp(lean.channel(c),captured.channel(c),160*160*4))throw std::runtime_error("capture flag changed output");
        std::cout<<"PS DATAPATH NUMERIC PASS rounding_modes=4 boundary_probes="<<probes.size()<<" no_capture_identical=1\n";
        context.backend=y26::Backend::Dma;context.device="/dev/y26-does-not-exist";
        auto hardware_ex=net.create_extractor();ncnn::Mat failed;hardware_ex.input("in0",input);
        if(hardware_ex.extract("1",failed)==0)throw std::runtime_error("DMA mode silently used CPU");
        std::cout<<"NCNN FIRST LAYER PASS relu_on_cpu=1 tiles=40 no_hardware_fallback=1\n";
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
