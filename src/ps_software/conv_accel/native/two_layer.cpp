#include "two_layer.hpp"
#include "tile_transport.hpp"
#include "layer.h"
#include <algorithm>
#include <cmath>
#include <cfenv>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
namespace y26 {
namespace {
void put(std::vector<std::uint8_t>& b,std::uint32_t v){for(unsigned i=0;i<4;++i)b.push_back(std::uint8_t(v>>(i*8)));}
std::uint32_t get(const std::vector<std::uint8_t>& b,unsigned i){if(i*4+4>b.size())throw std::runtime_error("Short chain response");std::uint32_t v;std::memcpy(&v,b.data()+i*4,4);return v;}
void triplet(std::vector<std::uint8_t>& b,std::int16_t a,std::int16_t c,std::int16_t d){put(b,std::uint16_t(a)|(std::uint32_t(std::uint16_t(c))<<16));put(b,std::uint16_t(d));}
void header(std::vector<std::uint8_t>& b,unsigned op,unsigned tag,unsigned config,unsigned dim,unsigned words,unsigned rx){
    b.clear();for(auto v:std::vector<std::uint32_t>{0x59323643,0x10000|op,tag,config,dim,0,words,rx})put(b,v);
}
void response(const std::vector<std::uint8_t>& b,unsigned op,unsigned tag,unsigned dim,unsigned channels,unsigned words){
    if(b.size()!=(8+words)*4||get(b,0)!=0x59323652||get(b,1)!=(0x10000|op)||get(b,2)!=tag||get(b,3)!=0||get(b,4)!=dim||get(b,5)!=channels||get(b,6)!=words)
        throw std::runtime_error("Chain response magic/version/tag/status/shape/length mismatch");
}
std::vector<std::uint8_t> load_packet(const std::vector<std::int16_t>& a,const std::vector<std::int16_t>& b,const ChainParameters& p){
    std::vector<std::uint8_t> out;out.reserve(15776);header(out,0x10,0x32020000,0,0,3936,8);
    for(const auto* v:{&p.first,&p.second})for(const auto& c:*v){put(out,c.multiplier);put(out,c.shift);put(out,std::uint32_t(c.bias));put(out,std::uint32_t(std::uint64_t(c.bias)>>32)&65535);}
    for(int set=0;set<13;++set)for(int oc=0;oc<16;++oc)for(int tap=0;tap<9;++tap){
        std::int16_t v[3]={};
        for(int lane=0;lane<3;++lane){
            if(set==0)v[lane]=a[(oc*3+lane)*9+tap];
            else{int ob=(set-1)/6,ic=((set-1)%6)*3+lane;if(ic<16)v[lane]=b[((ob*16+oc)*16+ic)*9+tap];}
        }
        triplet(out,v[0],v[1],v[2]);
    }
    return out;
}
void stripe_packet(const std::vector<std::int16_t>& image,unsigned stripe,unsigned tag,std::vector<std::uint8_t>& out){
    out.reserve(23144);header(out,0x11,tag,stripe,0x400a0,5778,12+(stripe%2?2560:0));
    for(int py=0;py<9;++py)for(int px=0;px<321;++px){
        int y=int(stripe)*8-1+py,x=px-1;std::int16_t r=0,g=0,b=0;
        if(y>=0&&y<320&&x>=0&&x<320){r=image[y*320+x];g=image[320*320+y*320+x];b=image[2*320*320+y*320+x];}
        triplet(out,r,g,b);
    }
}
void require_chain_system(){
    std::ifstream f("/proc/device-tree/model",std::ios::binary);std::string s((std::istreambuf_iterator<char>(f)),{});
    if(s.find("two-layer INT8 fusion")==std::string::npos)throw std::runtime_error("Boot matched two-layer bit/DT before DMA; no CPU fallback");
}
class TwoLayer : public ncnn::Layer {
    ChainContext* context;
    std::vector<std::int16_t> w0,w1;
public:
    explicit TwoLayer(ChainContext* c):context(c){one_blob_only=true;support_inplace=false;support_packing=false;}
    int load_param(const ncnn::ParamDict& p)override{
        return p.get(0,0)==16&&p.get(6,0)==432&&p.get(9,0)==1&&p.get(20,0)==32&&p.get(21,0)==4608?0:-200;
    }
    int load_model(const ncnn::ModelBin& mb)override{
        try{
            auto a=mb.load(432,0),ab=mb.load(16,1),b=mb.load(4608,0),bb=mb.load(32,1);
            if(a.empty()||ab.empty()||b.empty()||bb.empty()||a.total()!=432||b.total()!=4608||a.elemsize!=4u||b.elemsize!=4u) return -200;
            w0=quantize_conv_weights(a,16,27);w1=quantize_conv_weights(b,32,144);return 0;
        }catch(const std::exception&){return -200;}
    }
    int forward(const ncnn::Mat& in,ncnn::Mat& out,const ncnn::Option& opt)const override{
        if(!context||in.dims!=3||in.w!=320||in.h!=320||in.c!=3||in.elempack!=1||in.elemsize!=4u)return -200;
        try{
            if(context->parameters.first.size()!=16||context->parameters.second.size()!=32)throw std::runtime_error("Missing calibrated chain parameters");
            context->profile=ChainProfile();FirstProfile* p=context->profile_enabled?&context->profile.cpu:nullptr;
            ScopeTimer total(p?&p->total_ms:nullptr);std::vector<std::int16_t> image(3*320*320);std::vector<std::int8_t> q;
            {ScopeTimer t(p?&p->allocation_ms:nullptr);out.create(80,80,32,4u,opt.blob_allocator);if(out.empty())return -100;}
            {ScopeTimer t(p?&p->input_quantize_ms:nullptr);
                bool nearest=std::fegetround()==FE_TONEAREST;
                for(int c=0;c<3;++c){const float* x=in.channel(c);for(int i=0;i<320*320;++i){
                    if(!(x[i]>=0&&x[i]<=1.000001f))throw std::runtime_error("Expected normalized RGB input");
                    double v=double(x[i])*255.;image[c*320*320+i]=std::int16_t(nearest?int(v+.5):int(std::nearbyint(v)));
                }}
            }
            if(!context->dma){
                ScopeTimer t(p?&p->backend_ms:nullptr);
                auto first=fused_conv_reference(image,w0,ConvGeometry(3,16,320,320),context->parameters.first);
                std::vector<std::int16_t> next(first.begin(),first.end());
                q=fused_conv_reference(next,w1,ConvGeometry(16,32,160,160),context->parameters.second);
            }else{
                require_chain_system();DmaSession session(context->device.c_str(),p?&p->transfer:nullptr);
                std::vector<std::uint8_t> tx,rx;
                {ScopeTimer t(p?&p->fusion_config_ms:nullptr);tx=load_packet(w0,w1,context->parameters);session.transfer(tx,rx,32);response(rx,0x10,0x32020000,0,0,0);}
                q.resize(32*80*80);
                for(unsigned i=0;i<40;++i){
                    const unsigned tag=0xc2000000+i,count=i%2?2560:0;
                    {ScopeTimer t(p?&p->encode_ms:nullptr);stripe_packet(image,i,tag,tx);}
                    {ScopeTimer t(p?&p->backend_ms:nullptr);session.transfer(tx,rx,(12+count)*4);}
                    {ScopeTimer t(p?&p->decode_ms:nullptr);
                        response(rx,0x11,tag,i%2?0x40050:0,i%2?32:0,4+count);
                        context->profile.pl_job_cycles+=get(rx,7);context->profile.conv0_cycles+=get(rx,8);context->profile.conv1_cycles+=get(rx,9);
                        context->profile.internal_tx_words+=get(rx,10);context->profile.internal_rx_words+=get(rx,11);
                        if(count)for(unsigned c=0;c<32;++c)std::memcpy(q.data()+c*80*80+(i/2)*4*80,rx.data()+48+c*4*80,4*80);
                    }
                }
            }
            {ScopeTimer t(p?&p->restore_ms:nullptr);
                for(int c=0;c<32;++c){float* d=out.channel(c);for(int i=0;i<80*80;++i)d[i]=float(q[c*80*80+i])*context->parameters.second_scale;}
            }
            if(context->capture)context->second_output=q;else context->second_output.clear();
            return 0;
        }catch(const std::exception& e){std::fprintf(stderr,"Y26 two-layer failed: %s; no fallback\n",e.what());return -201;}
    }
};
ncnn::Layer* create(void* p){return new TwoLayer(static_cast<ChainContext*>(p));}
std::vector<std::string> fields(const std::string& line){std::istringstream s(line);std::vector<std::string> v;std::string x;while(s>>x)v.push_back(x);return v;}
void check_conv(const std::vector<std::string>& v,int co,int weights){
    if(v.size()<6||v[0]!="Convolution"||v[2]!="1"||v[3]!="1")throw std::runtime_error("Expected two adjacent ordinary convolutions");
    std::map<int,double> p;for(unsigned i=6;i<v.size();++i){auto eq=v[i].find('=');if(eq!=std::string::npos)p[std::stoi(v[i].substr(0,eq))]=std::stod(v[i].substr(eq+1));}
    auto get=[&](int k,double d){return p.count(k)?p[k]:d;};
    if(get(0,0)!=co||get(1,0)!=3||get(11,3)!=3||get(2,1)!=1||get(12,1)!=1||get(3,1)!=2||get(13,2)!=2||get(4,0)!=1||get(14,1)!=1||get(15,1)!=1||get(16,1)!=1||get(5,0)!=1||get(6,0)!=weights||get(9,0)!=1||get(8,0)!=0||get(18,0)!=0||get(19,0)!=0)
        throw std::runtime_error("Two-layer geometry/activation contract changed");
}
}
ChainParameters load_chain_parameters(const std::string& path){
    std::ifstream f(path);std::string magic;ChainParameters p;
    if(!(f>>magic>>p.first_scale>>p.second_scale)||(magic!="Y26C2"&&magic!="Y26C3")||!std::isfinite(p.first_scale)||!std::isfinite(p.second_scale)||p.first_scale<=0||p.second_scale<=0)throw std::runtime_error("Invalid chain parameter header");
    if(magic=="Y26C3"){
        if(!(f>>p.third_scale)||!std::isfinite(p.third_scale)||p.third_scale<=0)throw std::runtime_error("Invalid third-layer scale");
        p.third.resize(32);
    }
    p.first.resize(16);p.second.resize(32);
    for(auto* v:{&p.first,&p.second,&p.third})for(auto& c:*v){
        unsigned long long m,n;long long b;
        if(!(f>>m>>n>>b)||m>0xffffffffULL||n>31||b<-(1LL<<47)||b>=(1LL<<47))throw std::runtime_error("Invalid chain channel parameters");
        c.multiplier=std::uint32_t(m);c.shift=unsigned(n);c.bias=b;
    }
    std::string extra;if(f>>extra)throw std::runtime_error("Unexpected chain parameter suffix");return p;
}
std::vector<std::uint8_t> encode_chain_load(const std::vector<std::int16_t>& a,const std::vector<std::int16_t>& b,const ChainParameters& p){return load_packet(a,b,p);}
int register_two_layer(ncnn::Net& net,ChainContext& c){return net.register_custom_layer("Y26TwoConv",create,nullptr,&c);}
std::string adapt_two_layer_graph(const std::string& graph){
    std::istringstream stream(graph);std::vector<std::string> lines;std::string l;while(std::getline(stream,l))if(!l.empty())lines.push_back(l);
    int a=-1,b=-1;for(unsigned i=2;i<lines.size();++i){auto v=fields(lines[i]);if(v.size()>1&&v[1]=="convrelu_0")a=int(i);if(v.size()>1&&v[1]=="convrelu_1")b=int(i);}
    if(a<2||b!=a+1)throw std::runtime_error("Expected adjacent first two layers in model weight order");
    auto x=fields(lines[a]),y=fields(lines[b]);check_conv(x,16,432);check_conv(y,32,4608);
    if(x[4]!="in0"||y[4]!=x[5])throw std::runtime_error("First two layers are not connected");
    int consumers=0;for(unsigned i=2;i<lines.size();++i){auto v=fields(lines[i]);int n=std::stoi(v.at(2));for(int j=0;j<n;++j)if(v.at(4+j)==x[5])++consumers;}
    if(consumers!=1)throw std::runtime_error("Intermediate first-layer feature has a branch");
    lines[a]="Y26TwoConv convrelu_0_1 1 1 "+x[4]+" "+y[5];for(unsigned i=6;i<x.size();++i)lines[a]+=" "+x[i];lines[a]+=" 20=32 21=4608";
    lines.erase(lines.begin()+b);std::set<std::string> blobs;
    for(unsigned i=2;i<lines.size();++i){auto v=fields(lines[i]);int n=std::stoi(v.at(2))+std::stoi(v.at(3));for(int j=0;j<n;++j)blobs.insert(v.at(4+j));}
    lines[1]=std::to_string(lines.size()-2)+" "+std::to_string(blobs.size());std::string result;for(const auto& row:lines)result+=row+'\n';return result;
}
}
