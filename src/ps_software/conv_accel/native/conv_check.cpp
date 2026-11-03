// Explicit validation executable, independent of the production HTTP service.
#include "first_layer.hpp"
#include "tile_transport.hpp"
#include <chrono>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iomanip>
#include <iterator>
#include <map>
#include <stdexcept>
#include <sys/stat.h>

static std::string read(const std::string& path){std::ifstream f(path,std::ios::binary);if(!f)throw std::runtime_error("Cannot read "+path);return std::string(std::istreambuf_iterator<char>(f),{});}
static void dump(const std::string& path,const ncnn::Mat& m){
    std::ofstream f(path,std::ios::binary);if(!f)throw std::runtime_error("Cannot write "+path);
    for(int c=0;c<m.c;++c){const float* p=m.channel(c);f.write(reinterpret_cast<const char*>(p),m.w*m.h*4);}
    if(!f)throw std::runtime_error("Output write failed");
}
struct Sample {
    double forward_ms=0,first_ms=0,remaining_ms=0;
    unsigned transactions=0;
    y26::FirstProfile profile;
};
static void write_profile(std::ostream& f,const y26::FirstProfile& p){
    const double parts=p.allocation_ms+p.input_quantize_ms+p.patch_ms+p.result_allocation_ms+p.encode_ms+p.backend_ms+p.decode_ms+p.restore_ms+p.fusion_config_ms;
    f<<"{\"callback_ms\":"<<p.total_ms<<",\"allocation_ms\":"<<p.allocation_ms
     <<",\"input_quantize_ms\":"<<p.input_quantize_ms<<",\"patch_ms\":"<<p.patch_ms
     <<",\"result_allocation_ms\":"<<p.result_allocation_ms<<",\"encode_ms\":"<<p.encode_ms
     <<",\"backend_ms\":"<<p.backend_ms<<",\"decode_ms\":"<<p.decode_ms<<",\"restore_ms\":"<<p.restore_ms
     <<",\"fusion_config_ms\":"<<p.fusion_config_ms<<",\"unattributed_ms\":"<<p.total_ms-parts<<",\"core_cycles\":"<<p.core_cycles
     <<",\"transfer\":{\"calls\":"<<p.transfer.calls<<",\"tx_bytes\":"<<p.transfer.tx_bytes<<",\"rx_bytes\":"<<p.transfer.rx_bytes
     <<",\"open_ms\":"<<p.transfer.open_ms<<",\"rx_allocate_ms\":"<<p.transfer.rx_allocate_ms
     <<",\"ioctl_ms\":"<<p.transfer.ioctl_ms<<",\"close_ms\":"<<p.transfer.close_ms<<"},\"tile_cycles\":[";
    for(size_t i=0;i<p.tile_cycles.size();++i)f<<(i?",":"")<<p.tile_cycles[i];
    f<<"]}";
}
int main(int argc,char** argv){
    try{
        std::map<std::string,std::string> a;
        for(int i=1;i<argc;++i){std::string k=argv[i];if(k=="--help"){
            std::cout<<"y26-conv-check --param file --bin file --input input.f32 --output-dir existing_dir --backend baseline|reference|dma [--device /dev/y26_dma_loopback] [--profile] [--warmup 2] [--runs 7] [--no-capture] [--fusion-config parameters.txt]\ny26-conv-check --echo --device path\n";return 0;}
            if(k=="--echo"||k=="--profile"||k=="--no-capture"){a[k]="1";continue;}if(i+1>=argc)throw std::runtime_error("Missing option value");a[k]=argv[++i];}
        std::string device=a.count("--device")?a["--device"]:"/dev/y26_dma_loopback";
        if(a.count("--echo")){y26::framed_echo(device.c_str());std::cout<<"FRAMED ECHO PASS bytes=48 backend=PL_DMA\n";return 0;}
        for(const char* k:{"--param","--bin","--input","--output-dir","--backend"})if(!a.count(k))throw std::runtime_error(std::string("Missing ")+k);
        const auto backend=a["--backend"];if(backend!="baseline"&&backend!="reference"&&backend!="dma")throw std::runtime_error("Unknown backend");
        const int warmup=a.count("--warmup")?std::stoi(a["--warmup"]):0;
        const int runs=a.count("--runs")?std::stoi(a["--runs"]):1;
        if(warmup<0||warmup>5||runs<1||runs>20)throw std::runtime_error("Invalid warmup/runs");
        const auto input=read(a["--input"]);if(input.size()!=3*320*320*4)throw std::runtime_error("Input must be exactly 3x320x320 FP32");
        y26::Context context;context.backend=backend=="dma"?y26::Backend::Dma:y26::Backend::IntegerReference;context.device=device;context.profile_enabled=a.count("--profile");
        context.capture_accumulator=!a.count("--no-capture");
        context.fused=a.count("--fusion-config");
        if(context.fused){if(backend=="baseline")throw std::runtime_error("FP32 baseline must not use fusion config");context.fusion=y26::load_fusion_parameters(a["--fusion-config"]);}
        ncnn::Net net;net.opt.num_threads=1;net.opt.use_packing_layout=false;net.opt.use_vulkan_compute=false;
        net.opt.use_fp16_packed=false;net.opt.use_fp16_storage=false;net.opt.use_fp16_arithmetic=false;net.opt.use_bf16_storage=false;
        auto graph=read(a["--param"]);
        if(backend!="baseline"){if(y26::register_first_layer(net,context))throw std::runtime_error("Custom registration failed");graph=y26::adapt_first_layer_graph(graph);}
        if(net.load_param_mem(graph.c_str())||net.load_model(a["--bin"].c_str()))throw std::runtime_error("Model load failed");
        ncnn::Mat tensor(320,320,3);for(int c=0;c<3;++c){float* p=tensor.channel(c);std::memcpy(p,input.data()+c*320*320*4,320*320*4);}
        std::vector<Sample> samples;samples.reserve(runs);std::vector<double> warmup_ms;
        ncnn::Mat first,output;double ms=0;
        for(int iteration=0;iteration<warmup+runs;++iteration){
            auto ex=net.create_extractor();ex.set_light_mode(false);if(ex.input("in0",tensor))throw std::runtime_error("Input failed");
            ncnn::Mat current_first,current_output;
            const auto begin=std::chrono::steady_clock::now();
            if(ex.extract("1",current_first))throw std::runtime_error("First layer failed; no fallback");
            const auto middle=std::chrono::steady_clock::now();
            if(ex.extract("out0",current_output))throw std::runtime_error("Remaining inference failed");
            const auto end=std::chrono::steady_clock::now();
            Sample s;s.forward_ms=std::chrono::duration<double,std::milli>(end-begin).count();
            s.first_ms=std::chrono::duration<double,std::milli>(middle-begin).count();
            s.remaining_ms=std::chrono::duration<double,std::milli>(end-middle).count();
            s.transactions=context.transactions;if(context.profile_enabled)s.profile=context.profile;
            if(iteration<warmup)warmup_ms.push_back(s.forward_ms);else{samples.push_back(s);ms+=s.forward_ms;}
            first=current_first;output=current_output;
        }
        ms/=runs;
        if(first.w!=160||first.h!=160||first.c!=16||output.w!=2100||output.h!=9)throw std::runtime_error("Unexpected new model shapes");
        dump(a["--output-dir"]+"/first.f32",first);dump(a["--output-dir"]+"/output.f32",output);
        if(backend!="baseline"&&context.capture_accumulator&&!context.fused){
            std::ofstream f(a["--output-dir"]+"/accumulator.i64",std::ios::binary);
            f.write(reinterpret_cast<const char*>(context.accumulator.data()),context.accumulator.size()*8);
            if(!f)throw std::runtime_error("Accumulator write failed");
        }
        if(context.fused&&!context.quantized_output.empty()){
            std::ofstream f(a["--output-dir"]+"/quantized.i8",std::ios::binary);
            f.write(reinterpret_cast<const char*>(context.quantized_output.data()),context.quantized_output.size());
            if(!f)throw std::runtime_error("Quantized output write failed");
        }
        std::ofstream report(a["--output-dir"]+"/report.json");
        report<<std::setprecision(12)<<"{\"backend\":\""<<backend<<"\",\"transactions\":"<<context.transactions<<",\"forward_ms\":"<<ms<<",\"input_chw\":[3,320,320],\"first_chw\":[16,160,160],\"output_hw\":[9,2100],\"relu_location\":\""<<(context.fused ? (backend=="dma" ? "PL" : "CPU_integer_reference") : "PS")<<"\""
              <<",\"first_fused\":"<<(context.fused?"true":"false")<<",\"ps_int8_to_fp32_compatibility\":"<<(context.fused?"true":"false")
              <<",\"accumulator_capture\":"<<((backend!="baseline"&&context.capture_accumulator&&!context.fused)?"true":"false")
              <<",\"quantized_capture\":"<<((context.fused&&context.capture_accumulator)?"true":"false")
              <<",\"profile_enabled\":"<<(context.profile_enabled?"true":"false")<<",\"warmup_runs\":"<<warmup<<",\"measured_runs\":"<<runs<<",\"warmup_ms\":[";
        for(size_t i=0;i<warmup_ms.size();++i)report<<(i?",":"")<<warmup_ms[i];
        report<<"],\"samples\":[";
        for(size_t i=0;i<samples.size();++i){const auto& s=samples[i];report<<(i?",":"")<<"{\"forward_ms\":"<<s.forward_ms<<",\"first_extract_ms\":"<<s.first_ms<<",\"remaining_ms\":"<<s.remaining_ms<<",\"transactions\":"<<s.transactions<<",\"first_profile\":";
            if(context.profile_enabled&&backend!="baseline")write_profile(report,s.profile);else report<<"null";report<<'}';}
        report<<"]}\n";
        if(!report)throw std::runtime_error("Report write failed");
        std::cout<<"MODEL FIRST LAYER PASS backend="<<backend<<" transactions="<<context.transactions<<" forward_ms="<<ms<<'\n';
    }catch(const std::exception& e){std::cerr<<"ERROR: "<<e.what()<<'\n';return 1;}
}
