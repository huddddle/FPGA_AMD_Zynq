// Continuous graph acceptance. Prepared RGB boundary, no HTTP or dataset sweep.
#include "raw_frame.hpp"
#include "tile_transport.hpp"
#include "net.h"
#include <chrono>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <map>
#include <sstream>
#include <stdexcept>
using Clock=std::chrono::steady_clock;
static std::string read(const std::string& p){std::ifstream f(p,std::ios::binary);if(!f)throw std::runtime_error("Cannot read "+p);return std::string(std::istreambuf_iterator<char>(f),{});}
static std::vector<std::uint8_t> blob(const std::string& p){auto s=read(p);return {s.begin(),s.end()};}
static std::uint32_t word(const std::vector<std::uint8_t>& b,unsigned i){std::uint32_t x;if(i*4+4>b.size())throw std::runtime_error("Short response");std::memcpy(&x,b.data()+i*4,4);return x;}
static void put(std::vector<std::uint8_t>& b,unsigned i,std::uint32_t x){std::memcpy(b.data()+i*4,&x,4);}
static double ms(Clock::time_point a,Clock::time_point b){return std::chrono::duration<double,std::milli>(b-a).count();}
static void dump(const std::string& p,const ncnn::Mat& m){ncnn::Mat v;ncnn::convert_packing(m,v,1);std::ofstream f(p,std::ios::binary);if(v.dims==3)for(int c=0;c<v.c;++c)f.write(static_cast<const char*>(v.channel(c).data),v.w*v.h*4);else f.write(static_cast<const char*>(v.data),v.w*v.h*4);if(!f)throw std::runtime_error("Dump failed");}
int main(int argc,char** argv){try{
 std::map<std::string,std::string> a;for(int i=1;i<argc;i+=2){if(i+1>=argc)throw std::runtime_error("Option value");a[argv[i]]=argv[i+1];}
 for(const char* k:{"--param","--bin","--rgb","--output-dir","--backend"})if(!a.count(k))throw std::runtime_error(std::string("Missing ")+k);
 const auto mode=a["--backend"];if(mode!="cpu"&&mode!="pl"&&mode!="reference")throw std::runtime_error("backend cpu|pl|reference");
 const auto rgb=blob(a["--rgb"]);if(rgb.size()!=307200)throw std::runtime_error("RGB320 required");
 ncnn::Net net;net.opt.num_threads=1;net.opt.use_packing_layout=true;net.opt.use_vulkan_compute=false;net.opt.use_fp16_packed=net.opt.use_fp16_storage=net.opt.use_fp16_arithmetic=net.opt.use_bf16_storage=false;
 if(net.load_param(a["--param"].c_str())||net.load_model(a["--bin"].c_str()))throw std::runtime_error("NCNN load");
 std::vector<std::vector<std::uint8_t>> loads;std::vector<std::uint8_t> tx,rx,reference;
 if(mode=="pl"){
  auto identity=read("/proc/device-tree/model"),bit=read("/proc/device-tree/chosen/y26,bitstream-sha256");identity.resize(identity.find('\0'));bit.resize(bit.find('\0'));
  if(identity!="Embedfire Zynq7020 continuous graph INT8 fusion"||a["--bit-sha256"].size()!=64||bit!=a["--bit-sha256"])throw std::runtime_error("Matched graph bit/DT required; no DMA");
  for(const char* n:{"prefix.load","hotspot.load","graph.load"})loads.push_back(blob(a["--package"]+"/"+n));
  tx.resize(307232);std::uint32_t h[]={0x59323643,0x10031,0x67030000,0,0x1400140,0,76800,25628};for(unsigned i=0;i<8;++i)put(tx,i,h[i]);
 }
 if(mode=="reference"){reference=blob(a["--reference-exit"]);if(reference.size()!=102400)throw std::runtime_error("Reference INT8 shape");}
 int warm=a.count("--warmup")?std::stoi(a["--warmup"]):0,runs=a.count("--runs")?std::stoi(a["--runs"]):1;if(warm<0||warm>5||runs<1||runs>20)throw std::runtime_error("Run bounds");
 const float scale=0.12315747141838074f;ncnn::Mat exit,output;std::vector<std::int8_t> captured;std::vector<std::string> samples;double sum=0;
 for(int run=0;run<warm+runs;++run){
  auto begin=Clock::now();double load_ms=0,copy_ms=0,wait_ms=0,compat_ms=0;std::uint32_t counters[20]={};y26::TransferProfile profile;
  auto ex=net.create_extractor();ex.set_light_mode(true);
  if(mode=="cpu"){auto input=ncnn::Mat::from_pixels(rgb.data(),ncnn::Mat::PIXEL_RGB,320,320);float norm[]={1/255.f,1/255.f,1/255.f};input.substract_mean_normalize(nullptr,norm);if(ex.input("in0",input))throw std::runtime_error("Input");}
  else{
   const std::uint8_t* q=reference.data();
   if(mode=="pl"){
    y26::DmaSession session("/dev/y26_dma_loopback",&profile);auto t=Clock::now();
    for(const auto& packet:loads){session.transfer(packet,rx,32);if(rx.size()!=32||word(rx,0)!=0x59323652||word(rx,1)!=word(packet,1)||word(rx,2)!=word(packet,2)||word(rx,3))throw std::runtime_error("LOAD ack");}
    load_ms=ms(t,Clock::now());t=Clock::now();std::memcpy(tx.data()+32,rgb.data(),rgb.size());copy_ms=ms(t,Clock::now());t=Clock::now();session.transfer(tx,rx,102512);wait_ms=ms(t,Clock::now());
    if(rx.size()!=102512||word(rx,0)!=0x59323652||word(rx,1)!=0x10031||word(rx,2)!=0x67030000||word(rx,3)||word(rx,4)!=0x280028||word(rx,5)!=64||word(rx,6)!=25620)throw std::runtime_error("RUN header");
    for(unsigned i=0;i<20;++i)counters[i]=word(rx,25608+i);
    if(counters[0]||counters[8]!=76800||counters[9]!=25600)throw std::runtime_error("RUN footer");
    q=rx.data()+32;
   }
   auto t=Clock::now();exit.create(40,40,64);captured.resize(102400);
   for(int stripe=0;stripe<10;++stripe)for(int c=0;c<64;++c)for(int i=0;i<160;++i){auto v=std::int8_t(q[mode=="pl"?(stripe*64+c)*160+i:c*1600+stripe*160+i]);exit.channel(c)[stripe*160+i]=float(v)*scale;captured[c*1600+stripe*160+i]=v;}
   compat_ms=ms(t,Clock::now());if(ex.input("14",exit))throw std::runtime_error("Exit reinjection");
  }
  auto tail=Clock::now();if(ex.extract("out0",output))throw std::runtime_error("Forward");auto end=Clock::now();double elapsed=ms(begin,end);if(run<warm)continue;sum+=elapsed;
  std::ostringstream s;s<<std::setprecision(12)<<"{\"forward_ms\":"<<elapsed<<",\"load_ms\":"<<load_ms<<",\"copy_ms\":"<<copy_ms<<",\"wait_ms\":"<<wait_ms<<",\"compat_ms\":"<<compat_ms<<",\"tail_ms\":"<<ms(tail,end)<<",\"transactions\":"<<profile.calls<<",\"tx_bytes\":"<<profile.tx_bytes<<",\"rx_bytes\":"<<profile.rx_bytes<<",\"counters\":[";for(int i=0;i<20;++i)s<<(i?",":"")<<counters[i];s<<"]}";samples.push_back(s.str());
 }
 auto dir=a["--output-dir"];dump(dir+"/output.f32",output);if(mode!="cpu"){dump(dir+"/exit.f32",exit);std::ofstream f(dir+"/exit.i8",std::ios::binary);f.write(reinterpret_cast<const char*>(captured.data()),captured.size());}
 std::ofstream f(dir+"/report.json");f<<std::setprecision(12)<<"{\"backend\":\""<<mode<<"\",\"warmup\":"<<warm<<",\"runs\":"<<runs<<",\"forward_ms\":"<<sum/runs<<",\"samples\":[";for(unsigned i=0;i<samples.size();++i)f<<(i?",":"")<<samples[i];f<<"]}\n";
 std::cout<<"GRAPH PASS backend="<<mode<<" forward_ms="<<sum/runs<<'\n';return 0;
}catch(const std::exception& e){std::cerr<<"ERROR: "<<e.what()<<'\n';return 1;}}
