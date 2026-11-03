#include "hotspot56.hpp"
#include "net.h"
#include <chrono>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <map>
#include <memory>
#include <sstream>
#include <stdexcept>
namespace {
std::string read(const std::string& path){std::ifstream f(path,std::ios::binary);if(!f)throw std::runtime_error("Cannot read "+path);return std::string((std::istreambuf_iterator<char>(f)),{});}
void dump(const std::string& path,const ncnn::Mat& m){std::ofstream f(path,std::ios::binary);if(m.dims==3){for(int c=0;c<m.c;++c)f.write(reinterpret_cast<const char*>(m.channel(c).data),m.w*m.h*4);}else f.write(reinterpret_cast<const char*>(m.data),m.w*m.h*4);if(!f)throw std::runtime_error("Cannot write "+path);}
double ms(std::chrono::steady_clock::time_point a,std::chrono::steady_clock::time_point b){return std::chrono::duration<double,std::milli>(b-a).count();}
}
int main(int argc,char** argv){
    try{
        std::map<std::string,std::string> a;
        for(int i=1;i<argc;++i){std::string key=argv[i];if(i+1==argc)throw std::runtime_error("Missing argument value");a[key]=argv[++i];}
        for(const auto* key:{"--param","--bin","--rgb","--output-dir","--backend"})if(!a.count(key))throw std::runtime_error(std::string("Missing ")+key);
        const auto mode=a["--backend"];
        if(mode!="full"&&mode!="baseline"&&mode!="reinjection"&&mode!="reference"&&mode!="dma")throw std::runtime_error("Invalid backend");
        const bool accel=mode=="reference"||mode=="dma";
        const int warm=a.count("--warmup")?std::stoi(a["--warmup"]):0,runs=a.count("--runs")?std::stoi(a["--runs"]):1;
        if(warm<0||warm>5||runs<1||runs>20)throw std::runtime_error("Invalid warmup/runs");
        auto graph=read(a["--param"]);y26::validate_hotspot_graph(graph);
        auto rgb=read(a["--rgb"]);if(rgb.size()!=307200)throw std::runtime_error("Expected prepared RGB888 320x320");
        ncnn::Net net;net.opt.num_threads=1;net.opt.use_packing_layout=true;net.opt.use_vulkan_compute=false;
        net.opt.use_fp16_packed=net.opt.use_fp16_storage=net.opt.use_fp16_arithmetic=net.opt.use_bf16_storage=false;
        if(net.load_param_mem(graph.c_str())||net.load_model(a["--bin"].c_str()))throw std::runtime_error("NCNN load failed");
        std::unique_ptr<y26::Hotspot56> device;
        if(accel){if(!a.count("--parameters"))throw std::runtime_error("Missing --parameters");device.reset(new y26::Hotspot56(a["--parameters"]));}
        ncnn::Mat feature,output,diagnostic_source;std::vector<std::string> samples;double sum=0;
        for(int run=0;run<warm+runs;++run){
            auto start=std::chrono::steady_clock::now();
            auto input=ncnn::Mat::from_pixels(reinterpret_cast<const unsigned char*>(rgb.data()),ncnn::Mat::PIXEL_RGB,320,320);
            const float norm[]={1/255.f,1/255.f,1/255.f};input.substract_mean_normalize(nullptr,norm);
            auto ex=net.create_extractor();ex.set_light_mode(true);if(ex.input("in0",input))throw std::runtime_error("Input failed");
            double front_ms=0,sub_ms=0,remaining_ms=0;
            if(mode=="full"){
                if(ex.extract("out0",output))throw std::runtime_error("Full forward failed");
            }else{
                ncnn::Mat source;if(ex.extract("12",source))throw std::runtime_error("Front to blob12 failed");
                if(a.count("--input-feature")){
                    if(!accel)throw std::runtime_error("Feature override is a diagnostic for reference/dma only");
                    auto bytes=read(a["--input-feature"]);if(bytes.size()!=307200*4)throw std::runtime_error("Expected FP32 [48,80,80] diagnostic feature");
                    source.create(80,80,48);for(int c=0;c<48;++c)std::memcpy(source.channel(c).data,bytes.data()+c*6400*4,6400*4);
                }
                if(run==warm+runs-1&&accel)diagnostic_source=source;
                auto t0=std::chrono::steady_clock::now();front_ms=ms(start,t0);
                if(accel)feature=device->run(source,mode=="dma",a.count("--device")?a["--device"].c_str():"/dev/y26_dma_loopback",a["--bit-sha256"]);
                else if(ex.extract("14",feature))throw std::runtime_error("CPU 5->6 failed");
                auto t1=std::chrono::steady_clock::now();sub_ms=ms(t0,t1);
                if(mode=="baseline"){
                    if(ex.extract("out0",output))throw std::runtime_error("CPU remainder failed");
                }else{
                    auto tail=net.create_extractor();tail.set_light_mode(true);
                    if(tail.input("14",feature)||tail.extract("out0",output))throw std::runtime_error("Exit reinjection failed");
                }
                remaining_ms=ms(t1,std::chrono::steady_clock::now());
            }
            auto end=std::chrono::steady_clock::now();if(run<warm)continue;
            const double forward=ms(start,end);sum+=forward;
            std::ostringstream s;s<<std::setprecision(12)<<"{\"forward_ms\":"<<forward<<",\"front_ms\":"<<front_ms<<",\"subgraph_ms\":"<<sub_ms<<",\"remaining_ms\":"<<remaining_ms;
            if(device){const auto& p=device->profile;const auto& c=p.cpu;
                s<<",\"quantize_and_pack_ms\":"<<c.input_quantize_ms<<",\"load_ms\":"<<c.fusion_config_ms<<",\"transfer_wait_ms\":"<<c.backend_ms<<",\"check_ms\":"<<c.decode_ms<<",\"compatibility_ms\":"<<c.restore_ms
                 <<",\"transactions\":"<<c.transfer.calls<<",\"tx_bytes\":"<<c.transfer.tx_bytes<<",\"rx_bytes\":"<<c.transfer.rx_bytes<<",\"ioctl_ms_nested\":"<<c.transfer.ioctl_ms
                 <<",\"pl_job_cycles_nested\":"<<p.job_cycles<<",\"conv5_cycles\":"<<p.conv5_cycles<<",\"conv6_cycles\":"<<p.conv6_cycles<<",\"feed_cycles\":"<<p.feed_cycles<<",\"fusion_cycles\":"<<p.fusion_cycles<<",\"fill_cycles\":"<<p.fill_cycles<<",\"stall_cycles\":"<<p.stall_cycles;
            }s<<'}';samples.push_back(s.str());
        }
        if(output.w!=2100||output.h!=9)throw std::runtime_error("Expected 9x2100 decoded output");
        if(accel)dump(a["--output-dir"]+"/input.f32",diagnostic_source);
        if(mode!="full"){dump(a["--output-dir"]+"/exit.f32",feature);}
        dump(a["--output-dir"]+"/output.f32",output);
        if(device){
            std::ofstream q(a["--output-dir"]+"/exit.i8",std::ios::binary);q.write(reinterpret_cast<const char*>(device->captured.data()),device->captured.size());if(!q)throw std::runtime_error("INT8 output failed");
            if(a.count("--export-requests"))device->export_requests(a["--export-requests"]);
        }
        std::ofstream report(a["--output-dir"]+"/report.json");report<<std::setprecision(12)<<"{\"backend\":\""<<mode<<"\",\"pl_acceleration\":"<<(mode=="dma"?"true":"false")<<",\"subgraph\":\"convrelu_5->6\",\"prefix3_accelerated\":false,\"diagnostic_feature_override\":"<<(a.count("--input-feature")?"true":"false")<<",\"threads\":1,\"packing\":true,\"lightmode\":true,\"warmup_runs\":"<<warm<<",\"measured_runs\":"<<runs<<",\"forward_ms\":"<<sum/runs<<",\"samples\":[";
        for(unsigned i=0;i<samples.size();++i)report<<(i?",":"")<<samples[i];
        report<<"]}\n";
        if(!report)throw std::runtime_error("Report failed");
        std::cout<<"HOTSPOT56 PASS backend="<<mode<<" forward_ms="<<sum/runs<<'\n';return 0;
    }catch(const std::exception& e){std::cerr<<"ERROR: "<<e.what()<<'\n';return 1;}
}
