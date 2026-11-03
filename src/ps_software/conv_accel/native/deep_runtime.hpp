#pragma once
// One 293KB graph transaction; no PS operator between its nine convolutions.
struct Deep {
 Bytes packet,reference_skip,skip_reply,skip_bytes;
 double copy_ms=0,run_ms=0,skip_ms=0,restore_ms=0;
 std::uint32_t counters[16]={};
 explicit Deep(const std::map<std::string,std::string>& args){
  packet=read(args.at("--deep-packet"));if(packet.size()!=293232||word(packet,0)!=0x59323643||word(packet,1)!=0x10060||word(packet,6)!=73300)throw std::runtime_error("Deep packet format");
  auto it=args.find("--reference20-skip");if(it!=args.end()){reference_skip=read(it->second);if(reference_skip.size()!=51200)throw std::runtime_error("Deep skip reference");}
 }
 void run(y26::DmaSession* session,const std::vector<Bytes>& rx11){
  copy_ms=run_ms=0;for(auto& c:counters)c=0;
  if(session){auto t=Clock::now();for(unsigned ob=0;ob<8;++ob){if(rx11[ob].size()!=6464)throw std::runtime_error("Deep input conv11 block");std::memcpy(packet.data()+80+ob*6400,rx11[ob].data()+32,6400);}copy_ms=ms(t,Clock::now());
   Bytes reply;t=Clock::now();session->transfer(packet,reply,96);run_ms=ms(t,Clock::now());
   if(reply.size()!=96||word(reply,0)!=0x59323652||word(reply,1)!=0x10060||word(reply,2)!=word(packet,2)||word(reply,3)||word(reply,4)!=0x140014||word(reply,5)!=128||word(reply,6)!=16)throw std::runtime_error("Deep response");
   for(unsigned i=0;i<16;++i)counters[i]=word(reply,8+i);
   if(counters[0]||counters[15]!=1)throw std::runtime_error("Deep ready");
  }
 }
 void finish(ncnn::Extractor& ex,y26::DmaSession* session,Conv21& c21){
  skip_ms=0;const std::uint8_t* q=reference_skip.data();
  if(session){Bytes request(32);std::uint32_t h[]={0x59323643,0x10062,0x12220000,0,0x140014,128,0,12816};for(unsigned i=0;i<8;++i)put(request,i,h[i]);auto t=Clock::now();session->transfer(request,skip_reply,51264);skip_ms=ms(t,Clock::now());
   if(skip_reply.size()!=51264||word(skip_reply,0)!=0x59323652||word(skip_reply,1)!=0x10062||word(skip_reply,2)!=0x12220000||word(skip_reply,3)||word(skip_reply,4)!=0x140014||word(skip_reply,5)!=128||word(skip_reply,6)!=12808||word(skip_reply,12808)||word(skip_reply,12809)!=12800)throw std::runtime_error("Deep final skip");
   q=skip_reply.data()+32;
  }else if(reference_skip.size()!=51200)throw std::runtime_error("Deep reference missing");
  auto t=Clock::now();c21.skip.create(20,20,128);skip_bytes.assign(q,q+51200);
  for(int c=0;c<128;++c)for(int i=0;i<400;++i)c21.skip.channel(c)[i]=float(std::int8_t(q[c*400+i]))*c21.sx;
  c21.input=c21.skip;if(ex.input("51",c21.skip))throw std::runtime_error("Deep skip51 injection");restore_ms=ms(t,Clock::now());
 }
 void write(std::ostream& f)const{
  f<<",\"deep_copy_ms\":"<<copy_ms<<",\"deep_run_ms\":"<<run_ms<<",\"deep_skip_ms\":"<<skip_ms<<",\"deep_restore_ms\":"<<restore_ms<<",\"deep_counters\":[";
  for(unsigned i=0;i<16;++i){f<<(i?",":"")<<counters[i];}f<<"]";
 }
 void save(const std::string& dir)const{dump_bytes(dir+"/conv20.i8",skip_bytes);dump_bytes(dir+"/deep.packet",packet);}
};
