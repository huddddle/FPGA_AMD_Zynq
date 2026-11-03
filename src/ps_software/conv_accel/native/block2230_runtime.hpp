#pragma once
// Explicit DDR boundary after21; all nine following layers execute in one resident task.
struct Block2230 {
 std::vector<Bytes> packets;Bytes reference,quantized;float scale;
 double layout_ms=0,transfer_ms=0,compat_ms=0;std::uint32_t counters[16]={};ncnn::Mat exit;
 explicit Block2230(const std::map<std::string,std::string>& args){
  const auto d=args.at("--block2230");auto s=read(d+"/output.scale");if(s.size()!=4)throw std::runtime_error("Block30 output scale");std::memcpy(&scale,s.data(),4);if(!(scale>0))throw std::runtime_error("Block30 invalid scale");
  packets.push_back(read(d+"/start.packet"));for(unsigned i=0;i<8;++i)packets.push_back(read(d+"/batch"+std::to_string(i)+".packet"));packets.push_back(read(d+"/read.packet"));
  if(packets[0].size()!=31024||packets[9].size()!=32)throw std::runtime_error("Block22 packet lengths");
  auto it=args.find("--reference22-exit");if(it!=args.end()){reference=read(it->second);if(reference.size()!=25600)throw std::runtime_error("Block30 reference size");}
 }
 void run(ncnn::Extractor& ex,y26::DmaSession* session,const Bytes& q21){
  if(q21.size()!=25600)throw std::runtime_error("Block22 requires conv21 INT8 channels");
  auto t=Clock::now();auto& start=packets[0];
  for(unsigned g=0;g<86;++g)for(unsigned y=0;y<10;++y)for(unsigned xw=0;xw<3;++xw)for(unsigned lane=0;lane<3;++lane)for(unsigned b=0;b<4;++b){
   unsigned c=g*3+lane,x=xw*4+b,index=64+((((g*10+y)*3+xw)*3+lane)*4+b);start[index]=c<256&&x<10?q21[c*100+y*10+x]:0;
  }layout_ms=ms(t,Clock::now());t=Clock::now();Bytes reply;
  if(session){
   session->transfer(start,reply,32);ack(reply,start);
   for(unsigned i=1;i<=8;++i){const auto& tx=packets[i];session->transfer(tx,reply,96);
    if(reply.size()!=96||word(reply,0)!=0x59323652||word(reply,1)!=0x10071||word(reply,2)!=0x22300000+i||word(reply,3)||word(reply,4)!=0xa000a||word(reply,5)!=256||word(reply,6)!=16)throw std::runtime_error("Block22 batch header");
    for(unsigned j=0;j<16;++j)counters[j]=word(reply,8+j);
    if(counters[0]||counters[15]!=unsigned(i==8))throw std::runtime_error("Block22 status/complete");
   }
   session->transfer(packets[9],reply,30784);
   if(reply.size()!=30784||word(reply,0)!=0x59323652||word(reply,1)!=0x10072||word(reply,2)!=0x22300009||word(reply,3)||word(reply,4)!=0xa000a||word(reply,5)!=256||word(reply,6)!=7688||word(reply,7688)||word(reply,7689)!=7680)throw std::runtime_error("Block30 result frame");
  }else if(reference.size()!=25600)throw std::runtime_error("Block30 CPU reference required");
  transfer_ms=ms(t,Clock::now());t=Clock::now();exit.create(10,10,256);quantized.resize(25600);
  for(int c=0;c<256;++c)for(int y=0;y<10;++y)for(int x=0;x<10;++x){auto q=std::int8_t(session?reply[32+c*120+y*12+x]:reference[c*100+y*10+x]);quantized[c*100+y*10+x]=std::uint8_t(q);exit.channel(c)[y*10+x]=float(q)*scale;}
  if(ex.input("75",exit))throw std::runtime_error("Block30 output injection");
  compat_ms=ms(t,Clock::now());
 }
 void write(std::ostream& f)const{f<<",\"block22_layout_ms\":"<<layout_ms<<",\"block22_transfer_ms\":"<<transfer_ms<<",\"block30_compat_ms\":"<<compat_ms<<",\"block22_counters\":[";for(unsigned i=0;i<16;++i)f<<(i?",":"")<<counters[i];f<<"]";}
 void save(const std::string& d)const{dump_bytes(d+"/conv30.i8",quantized);dump(d+"/conv30.f32",exit);dump_bytes(d+"/start22.packet",packets[0]);}
};
