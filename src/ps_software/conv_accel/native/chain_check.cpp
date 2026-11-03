// Independent validation tool: production model and HTTP files are not rewritten.
#include "two_layer.hpp"
#include <chrono>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
static std::string read(const std::string& p){std::ifstream f(p,std::ios::binary);if(!f)throw std::runtime_error("Cannot read "+p);return std::string(std::istreambuf_iterator<char>(f),{});}
static void dump(const std::string& p,const ncnn::Mat& m){
    if(m.elempack!=1||m.elemsize!=4u)throw std::runtime_error("Expected unpacked FP32 export");
    std::ofstream f(p,std::ios::binary);for(int c=0;c<m.c;++c){const float* v=m.channel(c);f.write(reinterpret_cast<const char*>(v),m.w*m.h*4);}
    if(!f)throw std::runtime_error("Output write failed: "+p);
}
int main(int argc,char** argv){
    try{
        std::map<std::string,std::string> a;
        const std::set<std::string> options={"--param","--bin","--input","--output-dir","--backend","--parameters","--device","--warmup","--runs"};
        for(int i=1;i<argc;++i){std::string k=argv[i];
            if(k=="--help"){std::cout<<"y26-chain-check --param model.param --bin model.bin --input input.f32 --output-dir existing_dir --backend baseline|reference|dma [--parameters parameters.txt] [--device path] [--warmup 2] [--runs 7] [--profile] [--no-capture]\n";return 0;}
            if(k=="--profile"||k=="--no-capture"){a[k]="1";continue;}
            if(!options.count(k)||i+1==argc)throw std::runtime_error("Unknown option or missing value: "+k);
            a[k]=argv[++i];
        }
        for(const char* n:{"--param","--bin","--input","--output-dir","--backend"})if(!a.count(n))throw std::runtime_error(std::string("Missing ")+n);
        const std::string backend=a["--backend"];
        if(backend!="baseline"&&backend!="reference"&&backend!="dma")throw std::runtime_error("Invalid backend");
        int warmup=a.count("--warmup")?std::stoi(a["--warmup"]):0,runs=a.count("--runs")?std::stoi(a["--runs"]):1;
        if(warmup<0||warmup>5||runs<1||runs>20)throw std::runtime_error("Invalid warmup/runs");
        auto input=read(a["--input"]);if(input.size()!=3*320*320*4)throw std::runtime_error("Expected exactly 3x320x320 FP32 input");
        y26::ChainContext context;context.dma=backend=="dma";context.capture=!a.count("--no-capture");context.profile_enabled=a.count("--profile");
        if(a.count("--device"))context.device=a["--device"];
        if(backend!="baseline"){if(!a.count("--parameters"))throw std::runtime_error("Missing --parameters");context.parameters=y26::load_chain_parameters(a["--parameters"]);}
        ncnn::Net net;net.opt.num_threads=1;net.opt.use_packing_layout=true;net.opt.use_vulkan_compute=false;
        net.opt.use_fp16_packed=net.opt.use_fp16_storage=net.opt.use_fp16_arithmetic=net.opt.use_bf16_storage=false;
        auto graph=read(a["--param"]);
        if(backend!="baseline"){if(y26::register_two_layer(net,context))throw std::runtime_error("Custom registration failed");graph=y26::adapt_two_layer_graph(graph);}
        if(net.load_param_mem(graph.c_str())||net.load_model(a["--bin"].c_str()))throw std::runtime_error("Model load failed");
        ncnn::Mat tensor(320,320,3);for(int c=0;c<3;++c){float* d=tensor.channel(c);std::memcpy(d,input.data()+c*320*320*4,320*320*4);}
        ncnn::Mat second,output;double mean=0;std::vector<std::string> samples;
        for(int i=0;i<warmup+runs;++i){
            auto ex=net.create_extractor();ex.set_light_mode(true);if(ex.input("in0",tensor))throw std::runtime_error("Input failed");
            auto t0=std::chrono::steady_clock::now();if(ex.extract("2",second))throw std::runtime_error("First two layers failed; no fallback");
            auto t1=std::chrono::steady_clock::now();if(ex.extract("out0",output))throw std::runtime_error("Remaining network failed");
            auto t2=std::chrono::steady_clock::now();
            double total=std::chrono::duration<double,std::milli>(t2-t0).count();
            if(i<warmup)continue;
            mean+=total;std::ostringstream s;s<<std::setprecision(12);
            const auto& p=context.profile.cpu;const auto& t=p.transfer;
            s<<"{\"forward_ms\":"<<total<<",\"subgraph_ms\":"<<std::chrono::duration<double,std::milli>(t1-t0).count()<<",\"remaining_ms\":"<<std::chrono::duration<double,std::milli>(t2-t1).count()
             <<",\"input_quantize_ms\":"<<p.input_quantize_ms<<",\"config_and_load_ms\":"<<p.fusion_config_ms<<",\"encode_ms\":"<<p.encode_ms<<",\"transfer_and_wait_ms\":"<<p.backend_ms<<",\"decode_ms\":"<<p.decode_ms<<",\"compatibility_ms\":"<<p.restore_ms
             <<",\"ioctl_ms_nested\":"<<t.ioctl_ms<<",\"transactions\":"<<t.calls<<",\"tx_bytes\":"<<t.tx_bytes<<",\"rx_bytes\":"<<t.rx_bytes
             <<",\"conv0_cycles\":"<<context.profile.conv0_cycles<<",\"conv1_cycles\":"<<context.profile.conv1_cycles<<",\"pl_job_cycles_nested\":"<<context.profile.pl_job_cycles<<",\"internal_tx_words\":"<<context.profile.internal_tx_words<<",\"internal_rx_words\":"<<context.profile.internal_rx_words<<'}';
            samples.push_back(s.str());
        }
        if(second.w!=80||second.h!=80||second.c!=32||output.w!=2100||output.h!=9)throw std::runtime_error("Unexpected output shape");
        dump(a["--output-dir"]+"/second.f32",second);dump(a["--output-dir"]+"/output.f32",output);
        if(!context.second_output.empty()){
            std::ofstream f(a["--output-dir"]+"/second.i8",std::ios::binary);f.write(reinterpret_cast<const char*>(context.second_output.data()),context.second_output.size());if(!f)throw std::runtime_error("INT8 write failed");
        }
        std::ofstream f(a["--output-dir"]+"/report.json");
        f<<std::setprecision(12)<<"{\"backend\":\""<<backend<<"\",\"packing\":true,\"lightmode\":true,\"warmup_runs\":"<<warmup<<",\"measured_runs\":"<<runs<<",\"forward_ms\":"<<mean/runs<<",\"first_feature_dma_bytes\":0,\"first_feature_resident_on_pl\":"<<(context.dma?"true":"false")<<",\"ps_compatibility_at\":\""<<(backend=="baseline"?"none":"second_layer_output")<<"\",\"samples\":[";
        for(size_t i=0;i<samples.size();++i){f<<(i?",":"")<<samples[i];}
        f<<"]}\n";if(!f)throw std::runtime_error("Report write failed");
        std::cout<<"TWO LAYER MODEL PASS backend="<<backend<<" shape=32x80x80 forward_ms="<<mean/runs<<'\n';
    }catch(const std::exception& e){std::cerr<<"ERROR: "<<e.what()<<'\n';return 1;}
}
