// Reuse the existing block transport and the same PE. No CPU fallback on DMA failure.
#pragma once
struct Conv21 {
 Bytes init,reference,quantized;
 std::vector<Bytes> packets,rxs;
 float sx,sy;
 bool resident_input=false;
 ncnn::Mat input,skip,exit;
 double front_ms=0,layout_ms=0,quant_ms=0,init_ms=0,blocks_ms=0,compat_ms=0;
 std::uint64_t counters[5]={};
 explicit Conv21(const std::map<std::string,std::string>& args){
  auto p=read(args.at("--parameters21"));
  if(p.size()!=593952||word(p,0)!=0x59323150||word(p,1)!=1)throw std::runtime_error("Conv21 parameters");
  std::memcpy(&sx,p.data()+8,4);std::memcpy(&sy,p.data()+12,4);if(!(sx>0&&sy>0))throw std::runtime_error("Conv21 scales");
  init.resize(55328);std::uint32_t h[]={0x59323643,0x10043,0x21020000,0,0x140014,128,13824,8};for(unsigned i=0;i<8;++i)put(init,i,h[i]);std::memcpy(init.data()+32,p.data()+32,4096);
  for(unsigned co=0;co<256;++co)put(init,8+4*co+3,word(init,8+4*co+3)&0xffffU);
  const auto* w=p.data()+4128;
  for(unsigned ob=0;ob<16;++ob){Bytes b(49568);std::uint32_t bh[]={0x59323643,0x10044,0x21030000+ob,0,0xa000a,ob,12384,416};for(unsigned i=0;i<8;++i)put(b,i,bh[i]);unsigned j=8;
   for(unsigned ib=0;ib<43;++ib)for(unsigned oc=0;oc<16;++oc)for(unsigned t=0;t<9;++t){std::uint16_t v[3]={};for(unsigned l=0;l<3;++l)if(ib*3+l<128)std::memcpy(&v[l],w+(((ob*16+oc)*128+ib*3+l)*9+t)*2,2);put(b,j++,v[0]|(std::uint32_t(v[1])<<16));put(b,j++,v[2]);}
   packets.push_back(std::move(b));
  }
  rxs.resize(16);
  const auto it=args.find("--reference21-exit");if(it!=args.end()){reference=read(it->second);if(reference.size()!=25600)throw std::runtime_error("Conv21 reference size");}
 }
 void run(ncnn::Extractor& ex,y26::DmaSession* session){
  resident_input=false;
  for(auto& c:counters)c=0;
  auto t=Clock::now();if(ex.extract("51",skip)||ex.extract("52",input))throw std::runtime_error("Conv21 input/skip");front_ms=ms(t,Clock::now());
  t=Clock::now();ncnn::Mat plain;ncnn::convert_packing(input,plain,1);layout_ms=ms(t,Clock::now());if(plain.w!=20||plain.h!=20||plain.c!=128)throw std::runtime_error("Conv21 input shape");
  t=Clock::now();for(int c=0;c<128;++c)for(int i=0;i<400;++i){double v=std::nearbyint(double(plain.channel(c)[i])/double(sx));v=v< -128?-128:v>127?127:v;init[4128+c*400+i]=std::uint8_t(std::int8_t(v));}quant_ms=ms(t,Clock::now());
  transfer(session,init);restore(ex,session,true);
 }
 void run_resident(ncnn::Extractor& ex,y26::DmaSession* session){
  resident_input=true;
  for(auto& c:counters)c=0;
  front_ms=layout_ms=quant_ms=0;
  Bytes coefficients(init.begin(),init.begin()+4128);put(coefficients,1,0x10045);put(coefficients,6,1024);
  transfer(session,coefficients);restore(ex,session,false);
 }
 void transfer(y26::DmaSession* session,const Bytes& request){
  init_ms=blocks_ms=0;
  if(session){Bytes reply;auto t=Clock::now();session->transfer(request,reply,32);ack(reply,request);init_ms=ms(t,Clock::now());
   t=Clock::now();for(unsigned ob=0;ob<16;++ob){auto& rx=rxs[ob];session->transfer(packets[ob],rx,1664);
    if(rx.size()!=1664||word(rx,0)!=0x59323652||word(rx,1)!=0x10044||word(rx,2)!=0x21030000+ob||word(rx,3)||word(rx,4)!=0xa000a||word(rx,5)!=16||word(rx,6)!=408||word(rx,408)||word(rx,413)!=400||word(rx,414)!=ob)throw std::runtime_error("Conv21 block response");
    for(unsigned i=0;i<5;++i)counters[i]+=word(rx,408+i);
   }blocks_ms=ms(t,Clock::now());
  }else if(reference.size()!=25600)throw std::runtime_error("Conv21 requires integer reference without DMA");
 }
 void restore(ncnn::Extractor& ex,y26::DmaSession* session,bool attach_skip){
  auto t=Clock::now();exit.create(10,10,256);quantized.resize(25600);
  for(int ob=0;ob<16;++ob){unsigned offset=32;for(int y=0;y<10;y+=4){int n=std::min(4,10-y)*10;for(int c=0;c<16;++c)for(int i=0;i<n;++i){int idx=(ob*16+c)*100+y*10+i;auto q=std::int8_t(session?rxs[ob][offset++]:reference[idx]);quantized[idx]=std::uint8_t(q);exit.channel(ob*16+c)[y*10+i]=float(q)*sy;}}}
  if(ex.input("53",exit)||(attach_skip&&ex.input("51",skip)))throw std::runtime_error("Conv21 output/skip injection");
  compat_ms=ms(t,Clock::now());
 }
 void write(std::ostream& f)const{
  f<<",\"pre21_ms\":"<<front_ms<<",\"layer21_layout_ms\":"<<layout_ms<<",\"layer21_quant_ms\":"<<quant_ms<<",\"layer21_init_ms\":"<<init_ms<<",\"layer21_blocks_ms\":"<<blocks_ms<<",\"layer21_compat_ms\":"<<compat_ms<<",\"layer21_counters\":[";
  for(unsigned i=0;i<5;++i)f<<(i?",":"")<<counters[i];
  f<<"]";
 }
 void save(const std::string& dir)const{
  dump(dir+"/input21.f32",input);dump(dir+"/skip21.f32",skip);dump(dir+"/exit21.f32",exit);dump_bytes(dir+"/exit21.i8",quantized);
  if(resident_input){Bytes c(init.begin(),init.begin()+4128);put(c,1,0x10045);put(c,6,1024);dump_bytes(dir+"/init21.packet",c);}else dump_bytes(dir+"/init21.packet",init);
 }
};
