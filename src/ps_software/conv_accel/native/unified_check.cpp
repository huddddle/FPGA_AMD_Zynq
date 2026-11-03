// Prepared RGB888 is the common timing boundary. Models/scales/PS packing stay unchanged.
#include "raw_frame.hpp"
#include "hotspot56.hpp"
#include <chrono>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
namespace {
using Clock=std::chrono::steady_clock;
double ms(Clock::time_point a,Clock::time_point b){return std::chrono::duration<double,std::milli>(b-a).count();}
std::string read(const std::string& p){std::ifstream f(p,std::ios::binary);if(!f)throw std::runtime_error("Cannot read "+p);return std::string(std::istreambuf_iterator<char>(f),{});}
void bytes(const std::string& p,const void* data,std::size_t n){std::ofstream f(p,std::ios::binary);f.write(static_cast<const char*>(data),n);if(!f)throw std::runtime_error("Cannot write "+p);}
void dump(const std::string& p,const ncnn::Mat& m){
    ncnn::Mat v;ncnn::convert_packing(m,v,1);std::ofstream f(p,std::ios::binary);
    if(v.dims==3)for(int c=0;c<v.c;++c)f.write(static_cast<const char*>(v.channel(c).data),v.w*v.h*4);
    else f.write(static_cast<const char*>(v.data),v.w*v.h*4);
    if(!f)throw std::runtime_error("Cannot dump "+p);
}
void profile(std::ostream& s,const char* name,const y26::FirstProfile& p){
    s<<",\""<<name<<"_quantize_ms\":"<<p.input_quantize_ms<<",\""<<name<<"_copy_ms\":"<<p.encode_ms
     <<",\""<<name<<"_load_ms\":"<<p.fusion_config_ms<<",\""<<name<<"_wait_ms\":"<<p.backend_ms
     <<",\""<<name<<"_check_ms\":"<<p.decode_ms<<",\""<<name<<"_compat_ms\":"<<p.restore_ms
     <<",\""<<name<<"_ioctl_ms_nested\":"<<p.transfer.ioctl_ms<<",\""<<name<<"_transactions\":"<<p.transfer.calls
     <<",\""<<name<<"_tx_bytes\":"<<p.transfer.tx_bytes<<",\""<<name<<"_rx_bytes\":"<<p.transfer.rx_bytes;
}
}
int main(int argc,char** argv){try{
    std::map<std::string,std::string> a;
    const std::set<std::string> options={"--param","--bin","--rgb","--output-dir","--backend","--prefix-parameters","--hotspot-parameters","--bit-sha256","--warmup","--runs","--device","--export-requests"};
    for(int i=1;i<argc;++i){std::string k=argv[i];if(k=="--help"){std::cout<<"y26-unified-check --backend cpu|prefix|hotspot|both|reference_prefix|reference_hotspot|reference_both --param model.param --bin model.bin --rgb input.rgb --prefix-parameters parameters_three.txt --hotspot-parameters parameters.y56 --output-dir existing_dir [--bit-sha256 SHA256] [--warmup 2 --runs 1]\n";return 0;}if(!options.count(k)||i+1==argc)throw std::runtime_error("Unknown option/missing value: "+k);a[k]=argv[++i];}
    for(const char* k:{"--param","--bin","--rgb","--output-dir","--backend"})if(!a.count(k))throw std::runtime_error(std::string("Missing ")+k);
    const auto mode=a["--backend"];
    if(!std::set<std::string>{"cpu","prefix","hotspot","both","reference_prefix","reference_hotspot","reference_both"}.count(mode))throw std::runtime_error("Invalid backend");
    const bool prefix=mode=="prefix"||mode=="both"||mode=="reference_prefix"||mode=="reference_both";
    const bool hotspot=mode=="hotspot"||mode=="both"||mode=="reference_hotspot"||mode=="reference_both";
    const bool dma=mode=="prefix"||mode=="hotspot"||mode=="both";
    const std::string bit=a["--bit-sha256"],device=a.count("--device")?a["--device"]:"/dev/y26_dma_loopback";
    if(dma&&bit.size()!=64)throw std::runtime_error("DMA requires locked bit SHA256");
    int warm=a.count("--warmup")?std::stoi(a["--warmup"]):0,runs=a.count("--runs")?std::stoi(a["--runs"]):1;
    if(warm<0||warm>5||runs<1||runs>20)throw std::runtime_error("Invalid warmup/runs");
    const auto rgb=read(a["--rgb"]),graph=read(a["--param"]);if(rgb.size()!=307200)throw std::runtime_error("Expected RGB888 320x320");
    y26::adapt_two_layer_graph(graph);y26::validate_hotspot_graph(graph);
    std::unique_ptr<y26::RawFrame> pfx;std::unique_ptr<y26::Hotspot56> hot;
    if(prefix){if(!a.count("--prefix-parameters"))throw std::runtime_error("Missing prefix parameters");auto p=y26::load_chain_parameters(a["--prefix-parameters"]);if(p.third.size()!=32)throw std::runtime_error("Expected calibrated third layer");pfx.reset(new y26::RawFrame(a["--bin"],p));}
    if(hotspot){if(!a.count("--hotspot-parameters"))throw std::runtime_error("Missing hotspot parameters");hot.reset(new y26::Hotspot56(a["--hotspot-parameters"]));}
    ncnn::Net net;net.opt.num_threads=1;net.opt.use_packing_layout=true;net.opt.use_vulkan_compute=false;
    net.opt.use_fp16_packed=net.opt.use_fp16_storage=net.opt.use_fp16_arithmetic=net.opt.use_bf16_storage=false;
    if(net.load_param_mem(graph.c_str())||net.load_model(a["--bin"].c_str()))throw std::runtime_error("NCNN load failed");
    ncnn::Mat prefix_out,hotspot_in,hotspot_out,output;std::vector<std::string> samples;double sum=0;
    for(int run=0;run<warm+runs;++run){
        auto begin=Clock::now();auto ex=net.create_extractor();ex.set_light_mode(true);double pm=0,hm=0,bm=0,tm=0;
        if(prefix){auto t=Clock::now();prefix_out=pfx->run(reinterpret_cast<const std::uint8_t*>(rgb.data()),dma,device.c_str(),true,bit);pm=ms(t,Clock::now());if(ex.input("3",prefix_out))throw std::runtime_error("Prefix reinjection failed");}
        else{auto input=ncnn::Mat::from_pixels(reinterpret_cast<const unsigned char*>(rgb.data()),ncnn::Mat::PIXEL_RGB,320,320);const float norm[]={1/255.f,1/255.f,1/255.f};input.substract_mean_normalize(nullptr,norm);if(ex.input("in0",input))throw std::runtime_error("Input failed");}
        auto bridge_start=Clock::now();
        if(hotspot){if(ex.extract("12",hotspot_in))throw std::runtime_error("Bridge to blob12 failed");bm=ms(bridge_start,Clock::now());auto t=Clock::now();hotspot_out=hot->run(hotspot_in,dma,device.c_str(),bit);hm=ms(t,Clock::now());auto tail=net.create_extractor();tail.set_light_mode(true);auto t2=Clock::now();if(tail.input("14",hotspot_out)||tail.extract("out0",output))throw std::runtime_error("Hotspot reinjection failed");tm=ms(t2,Clock::now());}
        else{if(ex.extract("out0",output))throw std::runtime_error("Tail failed");tm=ms(bridge_start,Clock::now());}
        const double elapsed=ms(begin,Clock::now());if(run<warm)continue;sum+=elapsed;
        std::ostringstream extra;extra<<std::setprecision(12)<<"{\"prefix_ms\":"<<pm<<",\"cpu_bridge_ms\":"<<bm<<",\"hotspot_ms\":"<<hm<<",\"tail_ms\":"<<tm<<",\"forward_ms\":"<<elapsed;
        if(prefix){profile(extra,"prefix",pfx->profile.cpu);extra<<",\"prefix_job_cycles_nested\":"<<pfx->profile.job_cycles<<",\"conv0_cycles\":"<<pfx->profile.conv0_cycles<<",\"conv1_cycles\":"<<pfx->profile.conv1_cycles<<",\"conv2_cycles\":"<<pfx->profile.conv2_cycles;}
        if(hotspot){profile(extra,"hotspot",hot->profile.cpu);extra<<",\"hotspot_job_cycles_nested\":"<<hot->profile.job_cycles<<",\"conv5_cycles\":"<<hot->profile.conv5_cycles<<",\"conv6_cycles\":"<<hot->profile.conv6_cycles<<",\"feed_cycles\":"<<hot->profile.feed_cycles<<",\"fusion_cycles\":"<<hot->profile.fusion_cycles<<",\"fill_cycles\":"<<hot->profile.fill_cycles<<",\"stall_cycles\":"<<hot->profile.stall_cycles;}
        extra<<'}';samples.push_back(extra.str());
    }
    if(output.w!=2100||output.h!=9)throw std::runtime_error("Expected 9x2100 output");
    const auto out=a["--output-dir"];dump(out+"/output.f32",output);
    if(prefix){dump(out+"/prefix.f32",prefix_out);bytes(out+"/prefix.i8",pfx->captured.data(),pfx->captured.size());}
    if(hotspot){dump(out+"/hotspot_input.f32",hotspot_in);dump(out+"/hotspot.f32",hotspot_out);bytes(out+"/hotspot.i8",hot->captured.data(),hot->captured.size());}
    if(a.count("--export-requests")){if(prefix)pfx->export_requests(a["--export-requests"]+"/prefix",reinterpret_cast<const std::uint8_t*>(rgb.data()));if(hotspot)hot->export_requests(a["--export-requests"]+"/hotspot");}
    std::ofstream f(out+"/report.json");f<<std::setprecision(12)<<"{\"backend\":\""<<mode<<"\",\"pl_acceleration\":"<<(dma?"true":"false")<<",\"prefix3_accelerated\":"<<(prefix&&dma?"true":"false")<<",\"hotspot56_accelerated\":"<<(hotspot&&dma?"true":"false")<<",\"threads\":1,\"packing\":true,\"lightmode\":true,\"warmup_runs\":"<<warm<<",\"measured_runs\":"<<runs<<",\"forward_ms\":"<<sum/runs<<",\"samples\":[";
    for(unsigned i=0;i<samples.size();++i)f<<(i?",":"")<<samples[i];
    f<<"]}\n";if(!f)throw std::runtime_error("Report write failed");
    std::cout<<"UNIFIED PASS backend="<<mode<<" forward_ms="<<sum/runs<<'\n';return 0;
}catch(const std::exception& e){std::cerr<<"ERROR: "<<e.what()<<'\n';return 1;}}
