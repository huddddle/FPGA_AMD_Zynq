#include "hotspot56.hpp"
#include "tile_transport.hpp"
#include "raw_system.hpp"
#include "layer.h"
#include <cmath>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>
#include <sstream>
#include <stdexcept>
namespace y26 {
namespace {
void put(std::vector<std::uint8_t>& v,unsigned index,std::uint32_t x){std::memcpy(v.data()+index*4,&x,4);}
std::uint32_t get(const std::vector<std::uint8_t>& v,unsigned index){std::uint32_t x;if(index*4+4>v.size())throw std::runtime_error("Short hotspot packet");std::memcpy(&x,v.data()+index*4,4);return x;}
float as_float(std::uint32_t v){float x;std::memcpy(&x,&v,4);return x;}
std::string read(const std::string& path){std::ifstream f(path,std::ios::binary);if(!f)throw std::runtime_error("Cannot read "+path);std::string s((std::istreambuf_iterator<char>(f)),{});if(!s.empty()&&s.back()=='\0')s.pop_back();return s;}
}
void validate_hotspot_graph(const std::string& graph){
    unsigned matched=0,c13=0,c14=0;std::istringstream input(graph);std::string line;
    while(std::getline(input,line)){
        std::istringstream row(line);std::string type,name;int ni,no;
        if(!(row>>type>>name>>ni>>no)||ni<0||ni>16||no<0||no>16)continue;
        std::vector<std::string> ins(ni),outs(no);for(auto& s:ins)row>>s;for(auto& s:outs)row>>s;
        for(const auto& s:ins){if(s=="13"){++c13;if(name!="convrelu_6")throw std::runtime_error("Hotspot middle escapes");}if(s=="14"){++c14;if(name!="convrelu_7")throw std::runtime_error("Hotspot exit consumer changed");}}
        if(name!="convrelu_5"&&name!="convrelu_6")continue;
        const bool six=name=="convrelu_6";std::map<int,int> p;std::string item;
        while(row>>item){auto pos=item.find('=');if(pos!=std::string::npos)p[std::stoi(item.substr(0,pos))]=std::stoi(item.substr(pos+1));}
        if(type!="Convolution"||ni!=1||no!=1||ins[0]!=(six?"13":"12")||outs[0]!=(six?"14":"13")||p[0]!=64||p[1]!=(six?3:1)||p[3]!=(six?2:1)||p[4]!=(six?1:0)||p[5]!=1||p[6]!=(six?36864:3072)||p[9]!=1||p[2]!=1||p[12]!=1||p[11]!=(six?3:1)||p[13]!=(six?2:1)||p[14]!=(six?1:0)||p[8]!=0)throw std::runtime_error("Hotspot graph geometry changed");
        ++matched;
    }
    if(matched!=2||c13!=1||c14!=1)throw std::runtime_error("Expected unique 5->6 boundary");
}
Hotspot56::Hotspot56(const std::string& path){
    std::ifstream f(path,std::ios::binary);if(!f)throw std::runtime_error("Cannot open hotspot parameters");
    std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(f)),{});
    if(bytes.size()!=81952||get(bytes,0)!=0x59353650||get(bytes,1)!=1||get(bytes,5)!=3072||get(bytes,6)!=36864||get(bytes,7)!=128)throw std::runtime_error("Invalid hotspot parameter header/size");
    input_scale=as_float(get(bytes,2));output_scale=as_float(get(bytes,4));const float middle=as_float(get(bytes,3));
    if(!std::isfinite(input_scale)||input_scale<=0||!std::isfinite(output_scale)||output_scale<=0||!std::isfinite(middle)||middle<=0)throw std::runtime_error("Invalid hotspot scale");
    p5.resize(64);p6.resize(64);unsigned at=8;
    for(auto* p:{&p5,&p6})for(auto& c:*p){
        c.multiplier=get(bytes,at++);c.shift=get(bytes,at++);
        std::uint64_t b=get(bytes,at++);b|=std::uint64_t(get(bytes,at++))<<32;std::memcpy(&c.bias,&b,8);
        if(!c.multiplier||c.shift>31||c.bias<-(1LL<<47)||c.bias>=(1LL<<47))throw std::runtime_error("Hotspot coefficient range");
    }
    w5.resize(3072);w6.resize(36864);std::memcpy(w5.data(),bytes.data()+2080,6144);std::memcpy(w6.data(),bytes.data()+8224,73728);
    load.resize(111648);const std::uint32_t head[]={0x59323643,0x10020,0x56020000,0,0,0,27904,8};
    for(unsigned i=0;i<8;++i)put(load,i,head[i]);
    at=8;
    for(const auto* p:{&p5,&p6})for(const auto& c:*p){put(load,at++,c.multiplier);put(load,at++,c.shift);put(load,at++,std::uint32_t(c.bias));put(load,at++,std::uint32_t(std::uint64_t(c.bias)>>32)&65535);}
    for(int stage=0;stage<2;++stage){const int ci=stage?64:48,k=stage?9:1;const auto& w=stage?w6:w5;
        for(int ob=0;ob<4;++ob)for(int ib=0;ib<(ci+2)/3;++ib)for(int oc=0;oc<16;++oc)for(int tap=0;tap<k;++tap){
            std::uint16_t v[3]={};for(int lane=0;lane<3;++lane)if(ib*3+lane<ci)v[lane]=std::uint16_t(w[((ob*16+oc)*ci+ib*3+lane)*k+tap]);
            put(load,at++,v[0]|(std::uint32_t(v[1])<<16));put(load,at++,v[2]);
        }
    }
    if(at!=27912)throw std::runtime_error("Hotspot LOAD size calculation");
    tx.resize(307232);const std::uint32_t h[]={0x59323643,0x10021,0x56030000,0,0x500050,48,76800,25618};
    for(unsigned i=0;i<8;++i)put(tx,i,h[i]);
}
ncnn::Mat Hotspot56::run(const ncnn::Mat& packed,bool dma,const char* device,const std::string& bit,bool capture){
    profile=HotspotProfile();captured.clear();auto& p=profile.cpu;ScopeTimer total(&p.total_ms);
    if(packed.dims!=3||packed.w!=80||packed.h!=80||packed.c*packed.elempack!=48||packed.elemsize/packed.elempack!=4u)throw std::runtime_error("Expected FP32 blob12 [48,80,80]");
    ncnn::Mat input,output(40,40,64);if(output.empty())throw std::bad_alloc();
    {ScopeTimer t(&p.input_quantize_ms);ncnn::convert_packing(packed,input,1);
        auto* out=reinterpret_cast<std::int8_t*>(tx.data()+32);
        for(int tile=0;tile<10;++tile)for(int c=0;c<48;++c){const float* x=input.channel(c);x+=tile*640;
            for(int i=0;i<640;++i){if(!std::isfinite(x[i]))throw std::runtime_error("Nonfinite hotspot input");
                const double q=std::nearbyint(double(x[i])/double(input_scale));*out++=std::int8_t(q<-128?-128:q>127?127:q);}}
    }
    std::vector<std::int8_t> q;
    if(!dma){
        std::vector<std::int16_t> image(307200);
        const auto* src=reinterpret_cast<const std::int8_t*>(tx.data()+32);
        for(int tile=0;tile<10;++tile)for(int c=0;c<48;++c)for(int i=0;i<640;++i)image[c*6400+tile*640+i]=src[(tile*48+c)*640+i];
        ScopeTimer t(&p.backend_ms);
        auto first=fused_conv_reference(image,w5,ConvGeometry(48,64,80,80,1,1,0),p5);
        q=fused_conv_reference(std::vector<std::int16_t>(first.begin(),first.end()),w6,ConvGeometry(64,64,80,80),p6);
    }else{
        const auto machine=read("/proc/device-tree/model"),loaded_bit=read("/proc/device-tree/chosen/y26,bitstream-sha256");
        if(bit.size()!=64||!((machine=="Embedfire Zynq7020 hotspot56 INT8 fusion"&&loaded_bit==bit)||unified_system_supports(machine,loaded_bit,bit)))throw std::runtime_error("Boot matched verified hotspot56/unified bit/DT; no CPU fallback");
        DmaSession session(device,&p.transfer);
        {ScopeTimer t(&p.fusion_config_ms);session.transfer(load,rx,32);
            if(rx.size()!=32||get(rx,0)!=0x59323652||get(rx,1)!=0x10020||get(rx,2)!=0x56020000||get(rx,3)||get(rx,4)||get(rx,5)||get(rx,6))throw std::runtime_error("Hotspot LOAD response");}
        {ScopeTimer t(&p.backend_ms);session.transfer(tx,rx,102472);}
        {ScopeTimer t(&p.decode_ms);
            if(rx.size()!=102472||get(rx,0)!=0x59323652||get(rx,1)!=0x10021||get(rx,2)!=0x56030000||get(rx,3)||get(rx,4)!=0x280028||get(rx,5)!=64||get(rx,6)!=25610)throw std::runtime_error("Hotspot response header");
            const unsigned f=25608;if(get(rx,f)||get(rx,f+8)!=76800||get(rx,f+9)!=25600)throw std::runtime_error("Hotspot footer status/length");
            profile.job_cycles=get(rx,f+1);profile.conv5_cycles=get(rx,f+2);profile.conv6_cycles=get(rx,f+3);profile.feed_cycles=get(rx,f+4);profile.fusion_cycles=get(rx,f+5);profile.fill_cycles=get(rx,f+6);profile.stall_cycles=get(rx,f+7);
        }
    }
    {ScopeTimer t(&p.restore_ms);if(capture)captured.resize(102400);
        const auto* src=dma?reinterpret_cast<const std::int8_t*>(rx.data()+32):q.data();
        for(int tile=0;tile<10;++tile)for(int c=0;c<64;++c){float* out=output.channel(c);out+=tile*160;
            const auto* row=dma?src+(tile*64+c)*160:src+c*1600+tile*160;
            for(int i=0;i<160;++i)out[i]=float(row[i])*output_scale;
            if(capture)std::memcpy(captured.data()+c*1600+tile*160,row,160);
        }
    }
    return output;
}
void Hotspot56::export_requests(const std::string& directory){
    for(const auto& v:std::vector<std::pair<std::string,const std::vector<std::uint8_t>*>>{{"load.packet",&load},{"frame.packet",&tx}}){std::ofstream f(directory+"/"+v.first,std::ios::binary);f.write(reinterpret_cast<const char*>(v.second->data()),v.second->size());if(!f)throw std::runtime_error("Hotspot packet export");}
}
}
