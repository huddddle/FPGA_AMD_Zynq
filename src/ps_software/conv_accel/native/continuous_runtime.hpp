#pragma once
// One feature-resident0..30 schedule. Only final long skips and C30 return to PS.
struct Continuous30Runtime {
 std::string directory;std::vector<Bytes> loads,p11;Conv21 c21;Block2230 block;
 Bytes graph,middle,init11,deep,init21,start22,skip10,skip20,output30;
 float scale10;std::string profile;double prefix_ms=0,remaining_ms=0;
 explicit Continuous30Runtime(const std::string& d):directory(d),c21({{"--parameters21",d+"/parameters.y21"}}),block({{"--block2230",d}}),graph(307232){
  for(const char* n:{"prefix.load","hotspot.load","graph.load"})loads.push_back(read(d+"/"+n));
  std::uint32_t gh[]={0x59323643,0x10032,0x67030000,0,0x1400140,0,76800,25628};for(unsigned i=0;i<8;++i)put(graph,i,gh[i]);
  middle=read(d+"/middle.packet");if(middle.size()!=176832)throw std::runtime_error("PL30 middle");middle.resize(74432);put(middle,1,0x10051);put(middle,6,18600);
  auto p=read(d+"/parameters.y11");if(p.size()!=296992)throw std::runtime_error("PL30 conv11");std::memcpy(&scale10,p.data()+8,4);
  init11.resize(2080);std::uint32_t h[]={0x59323643,0x10042,0x11020000,0,0x280028,128,512,8};for(unsigned i=0;i<8;++i)put(init11,i,h[i]);std::memcpy(init11.data()+32,p.data()+32,2048);
  const auto* w=p.data()+2080;
  for(unsigned ob=0;ob<8;++ob){Bytes b(49568);std::uint32_t bh[]={0x59323643,0x10047,0x11030000+ob,0,0x140014,ob,12384,1616};for(unsigned i=0;i<8;++i)put(b,i,bh[i]);unsigned j=8;
   for(unsigned ib=0;ib<43;++ib)for(unsigned oc=0;oc<16;++oc)for(unsigned t=0;t<9;++t){std::uint16_t v[3]={};for(unsigned l=0;l<3;++l)if(ib*3+l<128)std::memcpy(&v[l],w+(((ob*16+oc)*128+ib*3+l)*9+t)*2,2);put(b,j++,v[0]|(std::uint32_t(v[1])<<16));put(b,j++,v[2]);}p11.push_back(std::move(b));
  }
  auto dp=read(d+"/deep.packet");if(dp.size()!=293232)throw std::runtime_error("PL30 deep");deep.assign(dp.begin(),dp.begin()+80);deep.insert(deep.end(),dp.begin()+51280,dp.end());put(deep,1,0x10061);put(deep,6,60500);put(deep,10,0);
  init21.assign(c21.init.begin(),c21.init.begin()+4128);put(init21,1,0x10045);put(init21,6,1024);
  for(auto& p:c21.packets)put(p,1,0x10048);
  start22.assign(block.packets[0].begin(),block.packets[0].begin()+64);put(start22,1,0x10073);put(start22,6,8);
 }
 static Bytes move(unsigned code){Bytes p(32);std::uint32_t h[]={0x59323643,0x10000+code,0x30000000+code,0,0,0,0,8};for(unsigned i=0;i<8;++i)put(p,i,h[i]);return p;}
 static Bytes skip(unsigned code){Bytes p(32);bool middle=code==0x52;std::uint32_t h[]={0x59323643,0x10000+code,middle?0x70200000U:0x12220000U,0,middle?0x280028U:0x140014U,128,0,middle?51216U:12816U};for(unsigned i=0;i<8;++i)put(p,i,h[i]);return p;}
 ncnn::Mat run(ncnn::Net& net,const std::vector<unsigned char>& rgb,const char* device){
  if(rgb.size()!=307200)throw std::runtime_error("PL30 RGB320");
  auto ex=net.create_extractor();ex.set_light_mode(true);y26::TransferProfile io;y26::DmaSession session(device,&io);Bytes reply;auto begin=Clock::now();
  auto transfer=[&](const Bytes& tx,unsigned n){session.transfer(tx,reply,n);if(reply.size()!=n||word(reply,0)!=0x59323652||word(reply,1)!=word(tx,1)||word(reply,2)!=word(tx,2)||word(reply,3))throw std::runtime_error("PL30 packet response");};
  auto link=[&](unsigned code){auto tx=move(code);transfer(tx,32);};
  auto t=Clock::now();for(const auto& tx:loads)transfer(tx,32);double load_ms=ms(t,Clock::now());
  t=Clock::now();std::memcpy(graph.data()+32,rgb.data(),rgb.size());double copy_ms=ms(t,Clock::now());
  t=Clock::now();transfer(graph,112);if(word(reply,6)!=20||word(reply,8)||word(reply,16)!=76800||word(reply,17)!=25600)throw std::runtime_error("PL30 graph footer");double graph_ms=ms(t,Clock::now());
  t=Clock::now();link(0x80);double link6_ms=ms(t,Clock::now());
  t=Clock::now();transfer(middle,80);if(word(reply,8)||word(reply,16)!=25600||word(reply,18)!=1)throw std::runtime_error("PL30 middle footer");double middle_ms=ms(t,Clock::now());
  t=Clock::now();transfer(init11,32);for(unsigned ob=0;ob<8;++ob){transfer(p11[ob],64);if(word(reply,6)!=8||word(reply,8)||word(reply,13)!=1600||word(reply,14)!=ob)throw std::runtime_error("PL30 conv11 footer");}double conv11_ms=ms(t,Clock::now());
  t=Clock::now();transfer(skip(0x52),204864);if(word(reply,51208)||word(reply,51209)!=51200)throw std::runtime_error("PL30 C10 skip");skip10.assign(reply.begin()+32,reply.begin()+204832);double skip10_ms=ms(t,Clock::now());
  t=Clock::now();link(0x81);double link11_ms=ms(t,Clock::now());
  t=Clock::now();transfer(deep,96);if(word(reply,8)||word(reply,23)!=1)throw std::runtime_error("PL30 deep footer");double deep_ms=ms(t,Clock::now());
  t=Clock::now();transfer(init21,32);for(unsigned ob=0;ob<16;++ob){transfer(c21.packets[ob],64);if(word(reply,6)!=8||word(reply,8)||word(reply,13)!=400||word(reply,14)!=ob)throw std::runtime_error("PL30 conv21 footer");}double conv21_ms=ms(t,Clock::now());
  t=Clock::now();transfer(skip(0x62),51264);if(word(reply,12808)||word(reply,12809)!=12800)throw std::runtime_error("PL30 C20 skip");skip20.assign(reply.begin()+32,reply.begin()+51232);double skip20_ms=ms(t,Clock::now());
  t=Clock::now();link(0x82);double link21_ms=ms(t,Clock::now());
  t=Clock::now();transfer(start22,32);for(unsigned i=1;i<=8;++i){transfer(block.packets[i],96);if(word(reply,8)||word(reply,23)!=unsigned(i==8))throw std::runtime_error("PL30 block22 footer");}transfer(block.packets[9],30784);if(word(reply,7688)||word(reply,7689)!=7680)throw std::runtime_error("PL30 C30 footer");double block22_ms=ms(t,Clock::now());
  t=Clock::now();ncnn::Mat a(40,40,128),b(20,20,128),c(10,10,256);output30.resize(25600);
  for(int ch=0;ch<128;++ch){for(int i=0;i<1600;++i)a.channel(ch)[i]=float(std::int8_t(skip10[ch*1600+i]))*scale10;for(int i=0;i<400;++i)b.channel(ch)[i]=float(std::int8_t(skip20[ch*400+i]))*c21.sx;}
  for(int ch=0;ch<256;++ch)for(int y=0;y<10;++y)for(int x=0;x<10;++x){auto q=std::int8_t(reply[32+ch*120+y*12+x]);output30[ch*100+y*10+x]=std::uint8_t(q);c.channel(ch)[y*10+x]=float(q)*block.scale;}
  if(ex.input("26",a)||ex.input("51",b)||ex.input("75",c))throw std::runtime_error("PL30 final boundary injection");double restore_ms=ms(t,Clock::now());prefix_ms=ms(begin,Clock::now());
  t=Clock::now();ncnn::Mat output;if(ex.extract("out0",output)||output.empty())throw std::runtime_error("PL30 tail");remaining_ms=ms(t,Clock::now());
  if(io.calls!=47||io.tx_bytes!=2911888||io.rx_bytes!=289792)throw std::runtime_error("PL30 complete path evidence");
  std::ostringstream s;s<<std::setprecision(12)<<"{\"transactions\":"<<io.calls<<",\"tx_bytes\":"<<io.tx_bytes<<",\"rx_bytes\":"<<io.rx_bytes<<",\"hardware_errors\":0,\"feature_ddr_reimports\":0,\"graph_load_ms\":"<<load_ms<<",\"graph_copy_ms\":"<<copy_ms<<",\"graph_wait_ms\":"<<graph_ms<<",\"link6_ms\":"<<link6_ms<<",\"middle_ms\":"<<middle_ms<<",\"conv11_ms\":"<<conv11_ms<<",\"skip10_ms\":"<<skip10_ms<<",\"link11_ms\":"<<link11_ms<<",\"deep_run_ms\":"<<deep_ms<<",\"conv21_ms\":"<<conv21_ms<<",\"skip20_ms\":"<<skip20_ms<<",\"link21_ms\":"<<link21_ms<<",\"block22_ms\":"<<block22_ms<<",\"restore_ms\":"<<restore_ms<<"}";profile=s.str();return output;
 }
 void save(const std::string& d)const{dump_bytes(d+"/conv10.i8",skip10);dump_bytes(d+"/conv20.i8",skip20);dump_bytes(d+"/conv30.i8",output30);}
};
