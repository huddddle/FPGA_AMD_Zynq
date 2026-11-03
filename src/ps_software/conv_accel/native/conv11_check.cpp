// Independent conv11, same NCNN extractor preserves the long skip blob26.
#include "tile_transport.hpp"
#include "net.h"
#include <chrono>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <map>
#include <sstream>
#include <stdexcept>
using Clock=std::chrono::steady_clock;
using Bytes=std::vector<std::uint8_t>;
static Bytes read(const std::string& p){std::ifstream f(p,std::ios::binary);if(!f)throw std::runtime_error("Cannot read "+p);return Bytes(std::istreambuf_iterator<char>(f),{});}
static std::uint32_t word(const Bytes& p,unsigned i){std::uint32_t v;if(i*4+4>p.size())throw std::runtime_error("Short packet");std::memcpy(&v,p.data()+i*4,4);return v;}
static void put(Bytes& p,unsigned i,std::uint32_t v){std::memcpy(p.data()+i*4,&v,4);}
static double ms(Clock::time_point a,Clock::time_point b){return std::chrono::duration<double,std::milli>(b-a).count();}
static void dump(const std::string& p,const ncnn::Mat& m){ncnn::Mat v;ncnn::convert_packing(m,v,1);std::ofstream f(p,std::ios::binary);if(v.dims==3)for(int c=0;c<v.c;++c)f.write(static_cast<const char*>(v.channel(c).data),v.w*v.h*4);else f.write(static_cast<const char*>(v.data),v.w*v.h*4);if(!f)throw std::runtime_error("Dump failed");}
int main(int argc,char** argv){try{
 std::map<std::string,std::string> a;for(int i=1;i<argc;i+=2){if(i+1>=argc)throw std::runtime_error("Option value");a[argv[i]]=argv[i+1];}
 for(const char* k:{"--param","--bin","--rgb","--output-dir","--backend"})if(!a.count(k))throw std::runtime_error(std::string("Missing ")+k);
 const auto mode=a["--backend"];if(mode!="cpu"&&mode!="boundary"&&mode!="reference"&&mode!="pl")throw std::runtime_error("backend cpu|boundary|reference|pl");
 auto rgb=read(a["--rgb"]);if(rgb.size()!=307200)throw std::runtime_error("RGB320 required");
 ncnn::Net net;net.opt.num_threads=1;net.opt.use_packing_layout=true;net.opt.use_vulkan_compute=false;net.opt.use_fp16_packed=net.opt.use_fp16_storage=net.opt.use_fp16_arithmetic=net.opt.use_bf16_storage=false;
 if(net.load_param(a["--param"].c_str())||net.load_model(a["--bin"].c_str()))throw std::runtime_error("NCNN load");
 Bytes init(206880),ref;std::vector<Bytes> packets,rxs(8);float sx=1,sy=1;
 if(mode=="pl"||mode=="reference"){
  auto p=read(a["--parameters"]);if(p.size()!=296992||word(p,0)!=0x59313150||word(p,1)!=1)throw std::runtime_error("Conv11 parameter format");
  std::memcpy(&sx,p.data()+8,4);std::memcpy(&sy,p.data()+12,4);if(!(sx>0&&sy>0))throw std::runtime_error("Scale");
  std::uint32_t h[]={0x59323643,0x10040,0x11020000,0,0x280028,128,51712,8};for(unsigned i=0;i<8;++i)put(init,i,h[i]);std::memcpy(init.data()+32,p.data()+32,2048);
  const auto* w=p.data()+2080;
  for(unsigned ob=0;ob<8;++ob){Bytes b(49568);std::uint32_t bh[]={0x59323643,0x10041,0x11030000+ob,0,0x140014,ob,12384,1616};for(unsigned i=0;i<8;++i)put(b,i,bh[i]);unsigned j=8;
   for(unsigned ib=0;ib<43;++ib)for(unsigned oc=0;oc<16;++oc)for(unsigned t=0;t<9;++t){std::uint16_t v[3]={};for(unsigned lane=0;lane<3;++lane)if(ib*3+lane<128)std::memcpy(&v[lane],w+(((ob*16+oc)*128+ib*3+lane)*9+t)*2,2);put(b,j++,v[0]|(std::uint32_t(v[1])<<16));put(b,j++,v[2]);}
   packets.push_back(std::move(b));
  }
  if(mode=="reference"){ref=read(a["--reference-exit"]);if(ref.size()!=51200)throw std::runtime_error("Reference size");}
 }
 if(mode=="pl"){
  auto d=read("/proc/device-tree/model"),b=read("/proc/device-tree/chosen/y26,bitstream-sha256");std::string dt(reinterpret_cast<const char*>(d.data())),bit(reinterpret_cast<const char*>(b.data()));
  if(dt!="Embedfire Zynq7020 independent conv11 INT8 fusion"||a["--bit-sha256"].size()!=64||bit!=a["--bit-sha256"])throw std::runtime_error("Matched conv11 bit/DT required; no DMA");
 }
 int warm=a.count("--warmup")?std::stoi(a["--warmup"]):0,runs=a.count("--runs")?std::stoi(a["--runs"]):1;if(warm<0||warm>5||runs<1||runs>20)throw std::runtime_error("Run count");
 ncnn::Mat skip,input,exit,output;Bytes captured;std::vector<std::string> samples;double sum=0;
 for(int run=0;run<warm+runs;++run){
  auto begin=Clock::now();auto ex=net.create_extractor();ex.set_light_mode(true);auto image=ncnn::Mat::from_pixels(rgb.data(),ncnn::Mat::PIXEL_RGB,320,320);float norm[]={1/255.f,1/255.f,1/255.f};image.substract_mean_normalize(nullptr,norm);if(ex.input("in0",image))throw std::runtime_error("Image input");
  double front_ms=0,cpu_conv_ms=0,layout_ms=0,quant_pack_ms=0,init_ms=0,blocks_ms=0,compat_ms=0,tail_ms=0;std::uint64_t counters[5]={};y26::TransferProfile profile;
  if(mode!="cpu"){
   if(ex.extract("26",skip)||ex.extract("27",input))throw std::runtime_error("Front/skip extract");
   front_ms=ms(begin,Clock::now());
   if(mode=="boundary"){auto t=Clock::now();if(ex.extract("28",exit))throw std::runtime_error("CPU conv11");cpu_conv_ms=ms(t,Clock::now());}
   else{
    auto t=Clock::now();ncnn::Mat plain;ncnn::convert_packing(input,plain,1);layout_ms=ms(t,Clock::now());t=Clock::now();
    if(plain.w!=40||plain.h!=40||plain.c!=128)throw std::runtime_error("Conv11 input shape");
    for(int c=0;c<128;++c)for(int i=0;i<1600;++i){double v=std::nearbyint(double(plain.channel(c)[i])/double(sx));v=v< -128?-128:v>127?127:v;init[2080+c*1600+i]=std::uint8_t(std::int8_t(v));}
    quant_pack_ms=ms(t,Clock::now());
    if(mode=="pl"){
     y26::DmaSession session("/dev/y26_dma_loopback",&profile);Bytes ack;t=Clock::now();session.transfer(init,ack,32);init_ms=ms(t,Clock::now());
     if(ack.size()!=32||word(ack,0)!=0x59323652||word(ack,1)!=0x10040||word(ack,2)!=0x11020000||word(ack,3))throw std::runtime_error("INIT ack");
     t=Clock::now();for(unsigned ob=0;ob<8;++ob){auto& rx=rxs[ob];session.transfer(packets[ob],rx,6464);
      if(rx.size()!=6464||word(rx,0)!=0x59323652||word(rx,1)!=0x10041||word(rx,2)!=0x11030000+ob||word(rx,3)||word(rx,4)!=0x140014||word(rx,5)!=16||word(rx,6)!=1608||word(rx,1608)||word(rx,1613)!=1600||word(rx,1614)!=ob)throw std::runtime_error("BLOCK response");
      for(unsigned i=0;i<5;++i)counters[i]+=word(rx,1608+i);
     }blocks_ms=ms(t,Clock::now());
    }
    t=Clock::now();exit.create(20,20,128);captured.resize(51200);
    for(int ob=0;ob<8;++ob)for(int stripe=0;stripe<5;++stripe)for(int c=0;c<16;++c)for(int i=0;i<80;++i){int idx=(ob*16+c)*400+stripe*80+i;auto v=std::int8_t(mode=="pl"?rxs[ob][32+(stripe*16+c)*80+i]:ref[idx]);captured[idx]=std::uint8_t(v);exit.channel(ob*16+c)[stripe*80+i]=float(v)*sy;}
    compat_ms=ms(t,Clock::now());if(ex.input("28",exit))throw std::runtime_error("Conv11 exit reinjection");
   }
   // Keep the original FP32 skip from conv10; no new tail extractor/recomputation.
   if(ex.input("26",skip))throw std::runtime_error("Skip preserve");
  }
  auto tail=Clock::now();if(ex.extract("out0",output))throw std::runtime_error("Tail");auto end=Clock::now();tail_ms=ms(tail,end);double elapsed=ms(begin,end);if(run<warm)continue;sum+=elapsed;
  std::ostringstream s;s<<std::setprecision(12)<<"{\"forward_ms\":"<<elapsed<<",\"front_ms\":"<<front_ms<<",\"cpu_conv_ms\":"<<cpu_conv_ms<<",\"layout_ms\":"<<layout_ms<<",\"quant_pack_ms\":"<<quant_pack_ms<<",\"init_transfer_ms\":"<<init_ms<<",\"blocks_transfer_ms\":"<<blocks_ms<<",\"compat_ms\":"<<compat_ms<<",\"tail_ms\":"<<tail_ms<<",\"transactions\":"<<profile.calls<<",\"tx_bytes\":"<<profile.tx_bytes<<",\"rx_bytes\":"<<profile.rx_bytes<<",\"counters\":[";for(unsigned i=0;i<5;++i)s<<(i?",":"")<<counters[i];s<<"]}";samples.push_back(s.str());
 }
 auto dir=a["--output-dir"];dump(dir+"/output.f32",output);if(mode!="cpu"){dump(dir+"/skip.f32",skip);dump(dir+"/input.f32",input);dump(dir+"/exit.f32",exit);}if(mode=="pl"||mode=="reference"){std::ofstream f(dir+"/exit.i8",std::ios::binary);f.write(reinterpret_cast<const char*>(captured.data()),captured.size());}
 std::ofstream f(dir+"/report.json");f<<std::setprecision(12)<<"{\"backend\":\""<<mode<<"\",\"skip_blob\":\"26\",\"warmup\":"<<warm<<",\"runs\":"<<runs<<",\"forward_ms\":"<<sum/runs<<",\"samples\":[";for(unsigned i=0;i<samples.size();++i)f<<(i?",":"")<<samples[i];f<<"]}\n";
 std::cout<<"CONV11 PASS backend="<<mode<<" forward_ms="<<sum/runs<<'\n';return 0;
}catch(const std::exception& e){std::cerr<<"ERROR: "<<e.what()<<'\n';return 1;}}
