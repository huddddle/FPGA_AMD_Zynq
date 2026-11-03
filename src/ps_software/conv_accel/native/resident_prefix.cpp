// Same packet sequence and integer boundaries as the frozen resident_deep runner.
#include "resident_prefix.hpp"
#include "tile_transport.hpp"
#include <chrono>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <map>
#include <sstream>
#include <stdexcept>
namespace {
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
#include "continuous_runtime.hpp"
static std::map<std::string,std::string> config(const std::string& d){return {{"--parameters21",d+"/parameters.y21"},{"--deep-packet",d+"/deep.packet"}};}
}
namespace y26 {
struct ResidentPrefix::Impl {
 std::unique_ptr<Continuous30Runtime> full;std::string directory;
 Conv21 c21;Deep deep;Bytes init,graph_tx,graph_rx,middle,skip_reply;std::vector<Bytes> loads,packets,rxs;
 float sx; ncnn::Mat skip;bool captured=false;
 explicit Impl(const std::string& d,bool continuous):c21(config(d)),deep(config(d)),init(2080),graph_tx(307232),middle(read(d+"/middle.packet")),rxs(8){
  directory=d;if(continuous){full.reset(new Continuous30Runtime(d));return;}
  if(middle.size()!=176832||word(middle,0)!=0x59323643||word(middle,1)!=0x10050||word(middle,6)!=44200)throw std::runtime_error("Middle packet format");
  for(const char* n:{"prefix.load","hotspot.load","graph.load"})loads.push_back(read(d+"/"+n));
  std::uint32_t gh[]={0x59323643,0x10031,0x67030000,0,0x1400140,0,76800,25628};for(unsigned i=0;i<8;++i)put(graph_tx,i,gh[i]);
  auto p=read(d+"/parameters.y11");if(p.size()!=296992||word(p,0)!=0x59313150||word(p,1)!=1)throw std::runtime_error("Conv11 parameters");
  std::memcpy(&sx,p.data()+8,4);if(!(sx>0))throw std::runtime_error("Conv11 scale");
  std::uint32_t h[]={0x59323643,0x10042,0x11020000,0,0x280028,128,512,8};for(unsigned i=0;i<8;++i)put(init,i,h[i]);std::memcpy(init.data()+32,p.data()+32,2048);
  const auto* w=p.data()+2080;
  for(unsigned ob=0;ob<8;++ob){Bytes b(49568);std::uint32_t bh[]={0x59323643,0x10041,0x11030000+ob,0,0x140014,ob,12384,1616};for(unsigned i=0;i<8;++i)put(b,i,bh[i]);unsigned j=8;
   for(unsigned ib=0;ib<43;++ib)for(unsigned oc=0;oc<16;++oc)for(unsigned t=0;t<9;++t){std::uint16_t v[3]={};for(unsigned l=0;l<3;++l)if(ib*3+l<128)std::memcpy(&v[l],w+(((ob*16+oc)*128+ib*3+l)*9+t)*2,2);put(b,j++,v[0]|(std::uint32_t(v[1])<<16));put(b,j++,v[2]);}
   packets.push_back(std::move(b));
  }
 }
};
ResidentPrefix::ResidentPrefix(const std::string& d,bool continuous):impl(new Impl(d,continuous)){}
ResidentPrefix::~ResidentPrefix()=default;
void ResidentPrefix::validate_system(const std::string& directory){
 auto text=[](const std::string& p){auto b=read(p);while(!b.empty()&&b.back()==0)b.pop_back();return std::string(b.begin(),b.end());};
 if(!directory.empty()&&text("/proc/device-tree/model")=="Embedfire Zynq7020 continuous0to30 shared INT8 fusion"){validate_continuous_system(directory);return;}
 if(text("/proc/device-tree/model")!="Embedfire Zynq7020 resident12to21 shared INT8 fusion"||text("/proc/device-tree/chosen/y26,bitstream-sha256")!="5c3dae46439a385387d1c64bce5270ece4fceb5f3369974866f001b0e98c5fe4")throw std::runtime_error("PL21 matched bit/DT required; no DMA. Boot /home/root/y26_deep320/boot_deep.scr first.");
}
void ResidentPrefix::validate_continuous_system(const std::string& directory){
 auto text=[](const std::string& p){auto b=read(p);while(!b.empty()&&(b.back()==0||b.back()=='\n'||b.back()=='\r'))b.pop_back();return std::string(b.begin(),b.end());};
 auto expected=text(directory+"/bit.sha256");if(expected.size()!=64||text("/proc/device-tree/model")!="Embedfire Zynq7020 continuous0to30 shared INT8 fusion"||text("/proc/device-tree/chosen/y26,bitstream-sha256")!=expected)throw std::runtime_error("PL30 matched bit/DT required; no DMA. Boot continuous30 package first.");
}
ncnn::Mat ResidentPrefix::run(ncnn::Net& net,const std::vector<unsigned char>& rgb,const char* device,bool capture){
 if(rgb.size()!=307200)throw std::runtime_error("PL prefix requires RGB320");auto& p=*impl;p.captured=capture;
 if(p.full){validate_continuous_system(p.full->directory);auto output=p.full->run(net,rgb,device);prefix_ms=p.full->prefix_ms;remaining_ms=p.full->remaining_ms;profile_json=p.full->profile;return output;}validate_system(p.directory);
 auto begin=Clock::now();auto ex=net.create_extractor();ex.set_light_mode(true);TransferProfile io;
 std::unique_ptr<DmaSession> session(new DmaSession(device,&io));Bytes reply;
 auto t=Clock::now();for(const auto& tx:p.loads){session->transfer(tx,reply,32);ack(reply,tx);}double load_ms=ms(t,Clock::now());
 t=Clock::now();std::memcpy(p.graph_tx.data()+32,rgb.data(),rgb.size());double copy_ms=ms(t,Clock::now());
 t=Clock::now();session->transfer(p.graph_tx,p.graph_rx,102512);double graph_ms=ms(t,Clock::now());
 if(p.graph_rx.size()!=102512||word(p.graph_rx,0)!=0x59323652||word(p.graph_rx,1)!=0x10031||word(p.graph_rx,2)!=0x67030000||word(p.graph_rx,3)||word(p.graph_rx,4)!=0x280028||word(p.graph_rx,5)!=64||word(p.graph_rx,6)!=25620||word(p.graph_rx,25608)||word(p.graph_rx,25616)!=76800||word(p.graph_rx,25617)!=25600)throw std::runtime_error("PL21 graph response");
 t=Clock::now();std::memcpy(p.middle.data()+74432,p.graph_rx.data()+32,102400);double mid_copy_ms=ms(t,Clock::now());
 t=Clock::now();session->transfer(p.middle,reply,80);double middle_ms=ms(t,Clock::now());
 if(reply.size()!=80||word(reply,0)!=0x59323652||word(reply,1)!=0x10050||word(reply,2)!=word(p.middle,2)||word(reply,3)||word(reply,4)!=0x280028||word(reply,5)!=128||word(reply,6)!=12||word(reply,8)||word(reply,16)!=25600||word(reply,17)!=40||word(reply,18)!=1)throw std::runtime_error("PL21 middle response");
 auto middle_job=word(reply,9);t=Clock::now();session->transfer(p.init,reply,32);ack(reply,p.init);double init_ms=ms(t,Clock::now());
 std::uint64_t job11=0;t=Clock::now();
 for(unsigned ob=0;ob<8;++ob){auto& rx=p.rxs[ob];session->transfer(p.packets[ob],rx,6464);
  if(rx.size()!=6464||word(rx,0)!=0x59323652||word(rx,1)!=0x10041||word(rx,2)!=0x11030000+ob||word(rx,3)||word(rx,4)!=0x140014||word(rx,5)!=16||word(rx,6)!=1608||word(rx,1608)||word(rx,1613)!=1600||word(rx,1614)!=ob)throw std::runtime_error("PL21 conv11 response");job11+=word(rx,1609);
 }double blocks11_ms=ms(t,Clock::now());
 Bytes request(32);std::uint32_t sh[]={0x59323643,0x10052,0x70200000,0,0x280028,128,0,51216};for(unsigned i=0;i<8;++i)put(request,i,sh[i]);
 t=Clock::now();session->transfer(request,p.skip_reply,204864);double skip10_ms=ms(t,Clock::now());
 if(p.skip_reply.size()!=204864||word(p.skip_reply,0)!=0x59323652||word(p.skip_reply,1)!=0x10052||word(p.skip_reply,2)!=0x70200000||word(p.skip_reply,3)||word(p.skip_reply,4)!=0x280028||word(p.skip_reply,5)!=128||word(p.skip_reply,6)!=51208||word(p.skip_reply,51208)||word(p.skip_reply,51209)!=51200)throw std::runtime_error("PL21 skip10 response");
 t=Clock::now();p.skip.create(40,40,128);for(int c=0;c<128;++c)for(int i=0;i<1600;++i)p.skip.channel(c)[i]=float(std::int8_t(p.skip_reply[32+c*1600+i]))*p.sx;
 if(ex.input("26",p.skip))throw std::runtime_error("PL21 skip26 injection");double restore10_ms=ms(t,Clock::now());
 p.deep.run(session.get(),p.rxs);p.c21.run_resident(ex,session.get());p.deep.finish(ex,session.get(),p.c21);prefix_ms=ms(begin,Clock::now());
 t=Clock::now();ncnn::Mat output;if(ex.extract("out0",output)||output.empty())throw std::runtime_error("PL21 NCNN tail");session.reset();remaining_ms=ms(t,Clock::now());
 if(io.calls!=34||io.tx_bytes!=2114768||io.rx_bytes!=437312)throw std::runtime_error("PL21 incomplete task path");
 std::ostringstream s;s<<std::setprecision(12)<<"{\"transactions\":"<<io.calls<<",\"tx_bytes\":"<<io.tx_bytes<<",\"rx_bytes\":"<<io.rx_bytes<<",\"hardware_errors\":0,\"sample\":\"last measured run\",\"graph_load_ms\":"<<load_ms<<",\"graph_copy_ms\":"<<copy_ms<<",\"graph_wait_ms\":"<<graph_ms<<",\"middle_copy_ms\":"<<mid_copy_ms<<",\"middle_ms\":"<<middle_ms<<",\"conv11_init_ms\":"<<init_ms<<",\"conv11_blocks_ms\":"<<blocks11_ms<<",\"skip10_transfer_ms\":"<<skip10_ms<<",\"skip10_restore_ms\":"<<restore10_ms<<",\"graph_job_cycles_nested\":"<<word(p.graph_rx,25609)<<",\"middle_job_cycles_nested\":"<<middle_job<<",\"conv11_job_cycles_nested\":"<<job11;
 p.c21.write(s);p.deep.write(s);s<<"}";profile_json=s.str();return output;
}
void ResidentPrefix::save(const std::string& d)const{if(!impl->captured)throw std::runtime_error("PL21 capture not requested");if(impl->full){impl->full->save(d);return;}impl->deep.save(d);impl->c21.save(d);dump(d+"/skip10.f32",impl->skip);}
}
