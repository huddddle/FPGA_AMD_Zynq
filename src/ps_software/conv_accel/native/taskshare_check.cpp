// Same-bit graph/conv11/both acceptance, preserving the long FP32 skip blob26.
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
#include <memory>
#include <sstream>
#include <stdexcept>
#ifdef Y26_TAIL_PROFILE
#include "tail_profile.hpp"
#endif
using Clock=std::chrono::steady_clock;
using Bytes=std::vector<std::uint8_t>;
static Bytes read(const std::string& p){std::ifstream f(p,std::ios::binary);if(!f)throw std::runtime_error("Cannot read "+p);return Bytes(std::istreambuf_iterator<char>(f),{});}
static std::uint32_t word(const Bytes& p,unsigned i){std::uint32_t v;if(i*4+4>p.size())throw std::runtime_error("Short packet");std::memcpy(&v,p.data()+i*4,4);return v;}
static void put(Bytes& p,unsigned i,std::uint32_t v){std::memcpy(p.data()+i*4,&v,4);}
static double ms(Clock::time_point a,Clock::time_point b){return std::chrono::duration<double,std::milli>(b-a).count();}
static void dump(const std::string& p,const ncnn::Mat& m){ncnn::Mat v;ncnn::convert_packing(m,v,1);std::ofstream f(p,std::ios::binary);if(v.dims==3)for(int c=0;c<v.c;++c)f.write(static_cast<const char*>(v.channel(c).data),v.w*v.h*4);else f.write(static_cast<const char*>(v.data),v.w*v.h*4);if(!f)throw std::runtime_error("Dump failed");}
static void dump_bytes(const std::string& p,const Bytes& b){std::ofstream f(p,std::ios::binary);f.write(reinterpret_cast<const char*>(b.data()),b.size());if(!f)throw std::runtime_error("Dump bytes failed");}
static void ack(const Bytes& rx,const Bytes& tx){if(rx.size()!=32||word(rx,0)!=0x59323652||word(rx,1)!=word(tx,1)||word(rx,2)!=word(tx,2)||word(rx,3))throw std::runtime_error("LOAD/INIT ack");}
#include "conv21_runtime.hpp"
#include "deep_runtime.hpp"
#include "block2230_runtime.hpp"
int main(int argc,char** argv){try{
 std::map<std::string,std::string> a;
 for(int i=1;i<argc;i+=2){if(i+1>=argc)throw std::runtime_error("Option value");a[argv[i]]=argv[i+1];}
 for(const char* k:{"--param","--bin","--rgb","--output-dir","--backend"})if(!a.count(k))throw std::runtime_error(std::string("Missing ")+k);
 const auto mode=a["--backend"];
 if(mode!="cpu"&&mode!="graph"&&mode!="conv11"&&mode!="both"&&mode!="resident"&&mode!="resident21"&&mode!="conv21"&&mode!="resident_deep"&&mode!="resident_block2230")throw std::runtime_error("Invalid task backend");
 const bool do_block=mode=="resident_block2230",do_deep=mode=="resident_deep"||do_block,do21=mode=="resident21"||mode=="conv21"||do_deep,resident=mode=="resident"||mode=="resident21"||do_deep;
 const bool graph=mode=="graph"||mode=="both"||resident,conv=mode=="conv11"||mode=="both"||resident,reference=a["--reference"]=="1";
 const bool dma=(graph||conv||do21)&&!reference;
 std::unique_ptr<Conv21> c21;if(do21)c21.reset(new Conv21(a));
 std::unique_ptr<Deep> deep;if(do_deep)deep.reset(new Deep(a));
 std::unique_ptr<Block2230> block;if(do_block)block.reset(new Block2230(a));
 auto rgb=read(a["--rgb"]);if(rgb.size()!=307200)throw std::runtime_error("RGB320 required");
 ncnn::Net net;net.opt.num_threads=1;net.opt.use_packing_layout=true;net.opt.use_vulkan_compute=false;
 net.opt.use_fp16_packed=net.opt.use_fp16_storage=net.opt.use_fp16_arithmetic=net.opt.use_bf16_storage=false;
 if(net.load_param(a["--param"].c_str())||net.load_model(a["--bin"].c_str()))throw std::runtime_error("NCNN load");
 Bytes init(206880),ref11,refgraph,graph_tx(307232),graph_rx,middle,refskip,skip_reply;std::vector<Bytes> loads,packets,rxs(8);float sx=1,sy=1;
 if(resident){
  middle=read(a["--middle-packet"]);
  if(middle.size()!=176832||word(middle,0)!=0x59323643||word(middle,1)!=0x10050||word(middle,6)!=44200)throw std::runtime_error("Middle packet format");
  if(reference){refskip=read(a["--reference-skip"]);if(refskip.size()!=204800)throw std::runtime_error("Skip reference size");}
 }
 if(graph){
  if(reference){refgraph=read(a["--reference-prefix"]);if(refgraph.size()!=102400)throw std::runtime_error("Prefix reference size");}
  else for(const char* n:{"prefix.load","hotspot.load","graph.load"})loads.push_back(read(a["--package"]+"/"+n));
  std::uint32_t h[]={0x59323643,0x10031,0x67030000,0,0x1400140,0,76800,25628};for(unsigned i=0;i<8;++i)put(graph_tx,i,h[i]);
 }
 if(conv){
  auto p=read(a["--parameters"]);if(p.size()!=296992||word(p,0)!=0x59313150||word(p,1)!=1)throw std::runtime_error("Conv11 parameter format");
  std::memcpy(&sx,p.data()+8,4);std::memcpy(&sy,p.data()+12,4);if(!(sx>0&&sy>0))throw std::runtime_error("Scale");
  std::uint32_t h[]={0x59323643,0x10040,0x11020000,0,0x280028,128,51712,8};for(unsigned i=0;i<8;++i)put(init,i,h[i]);std::memcpy(init.data()+32,p.data()+32,2048);
  const auto* w=p.data()+2080;
  for(unsigned ob=0;ob<8;++ob){Bytes b(49568);std::uint32_t bh[]={0x59323643,0x10041,0x11030000+ob,0,0x140014,ob,12384,1616};for(unsigned i=0;i<8;++i)put(b,i,bh[i]);unsigned j=8;
   for(unsigned ib=0;ib<43;++ib)for(unsigned oc=0;oc<16;++oc)for(unsigned t=0;t<9;++t){std::uint16_t v[3]={};for(unsigned lane=0;lane<3;++lane)if(ib*3+lane<128)std::memcpy(&v[lane],w+(((ob*16+oc)*128+ib*3+lane)*9+t)*2,2);put(b,j++,v[0]|(std::uint32_t(v[1])<<16));put(b,j++,v[2]);}
   packets.push_back(std::move(b));
  }
  if(reference){ref11=read(a["--reference-exit"]);if(ref11.size()!=51200)throw std::runtime_error("Conv11 reference size");}
  if(resident){init.resize(2080);put(init,1,0x10042);put(init,6,512);}
 }
 if(dma){
  auto d=read("/proc/device-tree/model"),b=read("/proc/device-tree/chosen/y26,bitstream-sha256");std::string dt(reinterpret_cast<const char*>(d.data())),bit(reinterpret_cast<const char*>(b.data()));
  bool block_dt=dt=="Embedfire Zynq7020 independent22to30 shared INT8 fusion",deep_dt=dt=="Embedfire Zynq7020 resident12to21 shared INT8 fusion"||block_dt,extended=dt=="Embedfire Zynq7020 resident conv21 shared INT8 fusion"||deep_dt;
  if(do_block&&!block_dt)throw std::runtime_error("Matched block22 bit/DT required; no DMA");
  if((dt!="Embedfire Zynq7020 task shared graph conv11 INT8 fusion"&&dt!="Embedfire Zynq7020 resident middle conv11 INT8 fusion"&&!extended)||(resident&&dt!="Embedfire Zynq7020 resident middle conv11 INT8 fusion"&&!extended)||(do21&&!extended)||(do_deep&&!deep_dt)||a["--bit-sha256"].size()!=64||bit!=a["--bit-sha256"])throw std::runtime_error("Matched taskshare/resident bit/DT required; no DMA");
 }
 const int warm=a.count("--warmup")?std::stoi(a["--warmup"]):0,runs=a.count("--runs")?std::stoi(a["--runs"]):1;
 if(warm<0||warm>5||runs<1||runs>20)throw std::runtime_error("Run count");
 ncnn::Mat prefix,skip,input,exit,output,input21,skip21;Bytes captured,captured_prefix;std::vector<std::string> samples;double sum=0;
 for(int run=0;run<warm+runs;++run){
  auto begin=Clock::now();auto ex=net.create_extractor();ex.set_light_mode(true);
  double graph_load=0,graph_copy=0,graph_wait=0,graph_compat=0,front_ms=0,layout_ms=0,quant_pack_ms=0,init_ms=0,blocks_ms=0,compat_ms=0,tail_ms=0,middle_copy_ms=0,middle_ms=0,skip_ms=0,skip_compat_ms=0;
  std::uint32_t gc[20]={},mc[12]={};std::uint64_t cc[5]={};y26::TransferProfile profile;
  std::unique_ptr<y26::DmaSession> session;if(dma)session.reset(new y26::DmaSession("/dev/y26_dma_loopback",&profile));
  if(graph){
   const auto* q=refgraph.data();
   if(dma){
    Bytes reply;auto t=Clock::now();for(const auto& packet:loads){session->transfer(packet,reply,32);ack(reply,packet);}graph_load=ms(t,Clock::now());
    t=Clock::now();std::memcpy(graph_tx.data()+32,rgb.data(),rgb.size());graph_copy=ms(t,Clock::now());
    t=Clock::now();session->transfer(graph_tx,graph_rx,102512);graph_wait=ms(t,Clock::now());
    if(graph_rx.size()!=102512||word(graph_rx,0)!=0x59323652||word(graph_rx,1)!=0x10031||word(graph_rx,2)!=0x67030000||word(graph_rx,3)||word(graph_rx,4)!=0x280028||word(graph_rx,5)!=64||word(graph_rx,6)!=25620)throw std::runtime_error("Graph RUN header");
    for(unsigned i=0;i<20;++i)gc[i]=word(graph_rx,25608+i);
    if(gc[0]||gc[8]!=76800||gc[9]!=25600)throw std::runtime_error("Graph RUN footer");
    q=graph_rx.data()+32;
   }
   auto t=Clock::now();
   if(!resident){prefix.create(40,40,64);captured_prefix.resize(102400);
   for(int stripe=0;stripe<10;++stripe)for(int c=0;c<64;++c)for(int i=0;i<160;++i){int idx=c*1600+stripe*160+i;auto v=std::int8_t(q[dma?(stripe*64+c)*160+i:idx]);prefix.channel(c)[stripe*160+i]=float(v)*0.12315747141838074f;captured_prefix[idx]=std::uint8_t(v);}
   if(ex.input("14",prefix))throw std::runtime_error("Prefix injection");}
   graph_compat=ms(t,Clock::now());
  }else{
   auto image=ncnn::Mat::from_pixels(rgb.data(),ncnn::Mat::PIXEL_RGB,320,320);float norm[]={1/255.f,1/255.f,1/255.f};image.substract_mean_normalize(nullptr,norm);if(ex.input("in0",image))throw std::runtime_error("Image input");
  }
  if(conv){
   auto t=Clock::now();
   if(resident){
    if(dma){
     std::memcpy(middle.data()+74432,graph_rx.data()+32,102400);middle_copy_ms=ms(t,Clock::now());t=Clock::now();
     Bytes reply;session->transfer(middle,reply,80);middle_ms=ms(t,Clock::now());
     if(reply.size()!=80||word(reply,0)!=0x59323652||word(reply,1)!=0x10050||word(reply,2)!=word(middle,2)||word(reply,3)||word(reply,4)!=0x280028||word(reply,5)!=128||word(reply,6)!=12)throw std::runtime_error("Middle response header");
     for(unsigned i=0;i<12;++i)mc[i]=word(reply,8+i);
     if(mc[0]||mc[8]!=25600||mc[9]!=40||mc[10]!=1)throw std::runtime_error("Middle response footer");
    }
   }else{
   if(ex.extract("26",skip)||ex.extract("27",input)){throw std::runtime_error("Front/skip extract");}front_ms=ms(t,Clock::now());
   t=Clock::now();ncnn::Mat plain;ncnn::convert_packing(input,plain,1);layout_ms=ms(t,Clock::now());t=Clock::now();
   if(plain.w!=40||plain.h!=40||plain.c!=128)throw std::runtime_error("Conv11 input shape");
   for(int c=0;c<128;++c)for(int i=0;i<1600;++i){double v=std::nearbyint(double(plain.channel(c)[i])/double(sx));v=v< -128?-128:v>127?127:v;init[2080+c*1600+i]=std::uint8_t(std::int8_t(v));}
   quant_pack_ms=ms(t,Clock::now());}
   if(dma){
    Bytes reply;t=Clock::now();session->transfer(init,reply,32);ack(reply,init);init_ms=ms(t,Clock::now());
    t=Clock::now();for(unsigned ob=0;ob<8;++ob){auto& rx=rxs[ob];session->transfer(packets[ob],rx,6464);
     if(rx.size()!=6464||word(rx,0)!=0x59323652||word(rx,1)!=0x10041||word(rx,2)!=0x11030000+ob||word(rx,3)||word(rx,4)!=0x140014||word(rx,5)!=16||word(rx,6)!=1608||word(rx,1608)||word(rx,1613)!=1600||word(rx,1614)!=ob)throw std::runtime_error("Conv11 BLOCK response");
     for(unsigned i=0;i<5;++i)cc[i]+=word(rx,1608+i);
    }blocks_ms=ms(t,Clock::now());
   }
   if(resident){
    t=Clock::now();const std::uint8_t* sq=refskip.data();
    if(dma){
     Bytes request(32);std::uint32_t sh[]={0x59323643,0x10052,0x70200000,0,0x280028,128,0,51216};for(unsigned i=0;i<8;++i)put(request,i,sh[i]);
     session->transfer(request,skip_reply,204864);skip_ms=ms(t,Clock::now());
     if(skip_reply.size()!=204864||word(skip_reply,0)!=0x59323652||word(skip_reply,1)!=0x10052||word(skip_reply,2)!=0x70200000||word(skip_reply,3)||word(skip_reply,4)!=0x280028||word(skip_reply,5)!=128||word(skip_reply,6)!=51208||word(skip_reply,51208)||word(skip_reply,51209)!=51200)throw std::runtime_error("Final skip response");
     sq=skip_reply.data()+32;
    }
    t=Clock::now();skip.create(40,40,128);
    for(int c=0;c<128;++c)for(int i=0;i<1600;++i)skip.channel(c)[i]=float(std::int8_t(sq[c*1600+i]))*sx;
    input=skip;skip_compat_ms=ms(t,Clock::now());
   }
   t=Clock::now();
   if(!do_deep){exit.create(20,20,128);captured.resize(51200);
   for(int ob=0;ob<8;++ob)for(int stripe=0;stripe<5;++stripe)for(int c=0;c<16;++c)for(int i=0;i<80;++i){int idx=(ob*16+c)*400+stripe*80+i;auto v=std::int8_t(dma?rxs[ob][32+(stripe*16+c)*80+i]:ref11[idx]);captured[idx]=std::uint8_t(v);exit.channel(ob*16+c)[stripe*80+i]=float(v)*sy;}
   if(ex.input("28",exit))throw std::runtime_error("Exit injection");}
   compat_ms=ms(t,Clock::now());if(ex.input("26",skip))throw std::runtime_error("Skip injection");
  }
  if(deep){deep->run(session.get(),rxs);c21->run_resident(ex,session.get());deep->finish(ex,session.get(),*c21);}
  else if(c21)c21->run(ex,session.get());
  if(block)block->run(ex,session.get(),c21->quantized);
  if(a["--capture-21"]=="1"){
   if(ex.extract("51",skip21)||ex.extract("52",input21))throw std::runtime_error("Conv21 boundary capture");
  }
#ifdef Y26_TAIL_PROFILE
  y26_tail_profile::start();
#endif
  auto tail=Clock::now();if(ex.extract("out0",output))throw std::runtime_error("Tail");session.reset();auto end=Clock::now();tail_ms=ms(tail,end);
#ifdef Y26_TAIL_PROFILE
  y26_tail_profile::stop();
#endif
  const double elapsed=ms(begin,end);if(run<warm)continue;sum+=elapsed;
  std::ostringstream s;s<<std::setprecision(12)<<"{\"forward_ms\":"<<elapsed<<",\"graph_load_ms\":"<<graph_load<<",\"graph_copy_ms\":"<<graph_copy<<",\"graph_wait_ms\":"<<graph_wait<<",\"graph_compat_ms\":"<<graph_compat<<",\"front_ms\":"<<front_ms<<",\"layout_ms\":"<<layout_ms<<",\"quant_pack_ms\":"<<quant_pack_ms<<",\"init_transfer_ms\":"<<init_ms<<",\"blocks_transfer_ms\":"<<blocks_ms<<",\"compat_ms\":"<<compat_ms<<",\"tail_ms\":"<<tail_ms<<",\"transactions\":"<<profile.calls<<",\"tx_bytes\":"<<profile.tx_bytes<<",\"rx_bytes\":"<<profile.rx_bytes<<",\"graph_counters\":[";
  for(unsigned i=0;i<20;++i)s<<(i?",":"")<<gc[i];
  s<<"],\"conv11_counters\":[";for(unsigned i=0;i<5;++i)s<<(i?",":"")<<cc[i];
  s<<"],\"middle_copy_ms\":"<<middle_copy_ms<<",\"middle_ms\":"<<middle_ms<<",\"skip_ms\":"<<skip_ms<<",\"skip_compat_ms\":"<<skip_compat_ms<<",\"middle_counters\":[";
  for(unsigned i=0;i<12;++i){s<<(i?",":"")<<mc[i];}s<<"]";
  if(c21)c21->write(s);
  if(deep)deep->write(s);
  if(block)block->write(s);
#ifdef Y26_TAIL_PROFILE
  s<<",\"tail_events\":";y26_tail_profile::write(s);
#endif
  s<<"}";samples.push_back(s.str());
 }
 const auto dir=a["--output-dir"];dump(dir+"/output.f32",output);
 if(deep){
  deep->save(dir);exit.create(20,20,128);captured.resize(51200);
  for(int ob=0;ob<8;++ob)for(int stripe=0;stripe<5;++stripe)for(int c=0;c<16;++c)for(int i=0;i<80;++i){int idx=(ob*16+c)*400+stripe*80+i;auto q=std::int8_t(dma?rxs[ob][32+(stripe*16+c)*80+i]:ref11[idx]);captured[idx]=std::uint8_t(q);exit.channel(ob*16+c)[stripe*80+i]=float(q)*sy;}
 }
 if(c21)c21->save(dir);
 if(block)block->save(dir);
 if(a["--capture-21"]=="1"){dump(dir+"/input21.f32",input21);dump(dir+"/skip21.f32",skip21);}
 if(graph&&!resident){dump(dir+"/prefix.f32",prefix);dump_bytes(dir+"/prefix.i8",captured_prefix);}
 if(resident){dump_bytes(dir+"/conv10.i8",reference?refskip:Bytes(skip_reply.begin()+32,skip_reply.begin()+204832));}
 if(conv){dump(dir+"/skip.f32",skip);dump(dir+"/input.f32",input);dump(dir+"/exit.f32",exit);dump_bytes(dir+"/exit.i8",captured);}
 std::ofstream f(dir+"/report.json");f<<std::setprecision(12)<<"{\"backend\":\""<<mode<<"\",\"reference\":"<<(reference?"true":"false")<<",\"warmup\":"<<warm<<",\"runs\":"<<runs<<",\"forward_ms\":"<<sum/runs<<",\"samples\":[";
 for(unsigned i=0;i<samples.size();++i){f<<(i?",":"")<<samples[i];}
 f<<"]}\n";
 std::cout<<"TASKSHARE PASS backend="<<mode<<" reference="<<reference<<" forward_ms="<<sum/runs<<'\n';return 0;
}catch(const std::exception& e){std::cerr<<"ERROR: "<<e.what()<<'\n';return 1;}}
