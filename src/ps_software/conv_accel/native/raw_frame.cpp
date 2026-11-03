#include "raw_frame.hpp"
#include "raw_system.hpp"
#include "tile_transport.hpp"
#include "datareader.h"
#include "modelbin.h"
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <memory>
#include <stdexcept>
namespace y26 {
namespace {
void put(std::vector<std::uint8_t>& v,unsigned index,std::uint32_t x){std::memcpy(v.data()+index*4,&x,4);}
std::uint32_t get(const std::vector<std::uint8_t>& v,unsigned index){std::uint32_t x;std::memcpy(&x,v.data()+index*4,4);return x;}
void require_raw_system(bool three,const std::string& expected){
    std::ifstream f("/proc/device-tree/model",std::ios::binary);std::string s((std::istreambuf_iterator<char>(f)),{});
    std::ifstream b("/proc/device-tree/chosen/y26,bitstream-sha256",std::ios::binary);std::string bit((std::istreambuf_iterator<char>(b)),{});
    if(!s.empty()&&s.back()=='\0')s.pop_back();
    if(!bit.empty()&&bit.back()=='\0')bit.pop_back();
    if(!raw_system_supports(s,bit,three,expected))throw std::runtime_error("Boot matched RGB "+std::string(three?"three-layer ":"")+"frame bit/DT before DMA; no CPU fallback; verified bit SHA required");
}
}
void validate_raw_system(bool three,const std::string& expected){require_raw_system(three,expected);}
RawFrame::RawFrame(const std::string& model,const ChainParameters& p):parameters(p){
    if(p.first.size()!=16||p.second.size()!=32)throw std::runtime_error("Expected 16/32 fusion parameters");
    std::unique_ptr<FILE,decltype(&std::fclose)> f(std::fopen(model.c_str(),"rb"),&std::fclose);
    if(!f)throw std::runtime_error("Cannot open model weights");
    ncnn::DataReaderFromStdio dr(f.get());ncnn::ModelBinFromDataReader mb(dr);
    ncnn::Mat a=mb.load(432,0),ab=mb.load(16,1),b=mb.load(4608,0),bb=mb.load(32,1);
    if(a.empty()||ab.empty()||b.empty()||bb.empty())throw std::runtime_error("Prefix model weights unavailable");
    first_weights=quantize_conv_weights(a,16,27);second_weights=quantize_conv_weights(b,32,144);
    load=encode_chain_load(first_weights,second_weights,p);tx.resize(307232);
    if(!p.third.empty()){
        if(p.third.size()!=32||p.third_scale<=0)throw std::runtime_error("Expected 32 calibrated third-layer coefficients");
        ncnn::Mat c=mb.load(1024,0),cb=mb.load(32,1);
        if(c.empty()||cb.empty())throw std::runtime_error("Third-layer weights unavailable");
        third_weights=quantize_conv_weights(c,32,32);auto old=load;load.resize(19104);
        const std::uint32_t h[]={0x59323643,0x10014,0x32020000,0,0,0,4768,8};
        for(unsigned i=0;i<8;++i)put(load,i,h[i]);
        std::memcpy(load.data()+32,old.data()+32,192*4);
        unsigned at=8+192;
        for(const auto& v:p.third){put(load,at++,v.multiplier);put(load,at++,v.shift);put(load,at++,std::uint32_t(v.bias));put(load,at++,std::uint32_t(std::uint64_t(v.bias)>>32)&65535);}
        std::memcpy(load.data()+32+320*4,old.data()+32+192*4,3744*4);at=8+320+3744;
        for(unsigned ob=0;ob<2;++ob)for(unsigned ib=0;ib<11;++ib)for(unsigned oc=0;oc<16;++oc){
            std::uint16_t v[3]={};for(unsigned lane=0;lane<3;++lane)if(ib*3+lane<32)v[lane]=std::uint16_t(third_weights[(ob*16+oc)*32+ib*3+lane]);
            put(load,at++,v[0]|(std::uint32_t(v[1])<<16));put(load,at++,v[2]);
        }
    }
    const bool three=!p.third.empty();
    const std::uint32_t h[]={0x59323643,three?0x10015u:0x10013u,0x32030000,0,0x1400140,0,76800,three?51219u:51218u};
    for(unsigned i=0;i<8;++i)put(tx,i,h[i]);
}
void RawFrame::export_requests(const std::string& directory,const std::uint8_t* rgb){
    std::memcpy(tx.data()+32,rgb,307200);
    for(const auto& entry:std::vector<std::pair<std::string,const std::vector<std::uint8_t>*>>{{"load.packet",&load},{"frame.packet",&tx}}){
        std::ofstream out(directory+"/"+entry.first,std::ios::binary);out.write(reinterpret_cast<const char*>(entry.second->data()),entry.second->size());
        if(!out)throw std::runtime_error("Packet export failed");
    }
}
ncnn::Mat RawFrame::run(const std::uint8_t* rgb,bool dma,const char* device,bool capture,const std::string& expected){
    profile=RawProfile();captured.clear();auto* p=&profile.cpu;ScopeTimer total(&p->total_ms);
    ncnn::Mat output;{ScopeTimer t(&p->allocation_ms);output.create(80,80,32);if(output.empty())throw std::bad_alloc();}
    if(!dma){
        std::vector<std::int16_t> image(307200);std::vector<std::int8_t> q;
        {ScopeTimer t(&p->input_quantize_ms);for(unsigned c=0;c<3;++c)for(unsigned i=0;i<102400;++i)image[c*102400+i]=rgb[i*3+c];}
        {ScopeTimer t(&p->backend_ms);
            auto a=fused_conv_reference(image,first_weights,ConvGeometry(3,16,320,320),parameters.first);
            q=fused_conv_reference(std::vector<std::int16_t>(a.begin(),a.end()),second_weights,ConvGeometry(16,32,160,160),parameters.second);
            if(!third_weights.empty())q=fused_conv_reference(std::vector<std::int16_t>(q.begin(),q.end()),third_weights,ConvGeometry(32,32,80,80,1,1,0),parameters.third);
        }
        {ScopeTimer t(&p->restore_ms);const float scale=third_weights.empty()?parameters.second_scale:parameters.third_scale;for(int c=0;c<32;++c){float* d=output.channel(c);for(int i=0;i<6400;++i)d[i]=float(q[c*6400+i])*scale;}}
        if(capture)captured=std::move(q);
        return output;
    }
    const bool three=!third_weights.empty();
    require_raw_system(three,expected);DmaSession session(device,&p->transfer);
    {ScopeTimer t(&p->fusion_config_ms);session.transfer(load,rx,32);
        if(rx.size()!=32||get(rx,0)!=0x59323652||get(rx,1)!=(three?0x10014u:0x10010u)||get(rx,2)!=0x32020000||get(rx,3)||get(rx,4)||get(rx,5)||get(rx,6))throw std::runtime_error("Raw LOAD response mismatch");
    }
    {ScopeTimer t(&p->encode_ms);std::memcpy(tx.data()+32,rgb,307200);}
    {ScopeTimer t(&p->backend_ms);session.transfer(tx,rx,three?204876:204872);}
    {ScopeTimer t(&p->decode_ms);
        if(rx.size()!=(three?204876u:204872u)||get(rx,0)!=0x59323652||get(rx,1)!=(three?0x10015u:0x10013u)||get(rx,2)!=0x32030000||get(rx,3)||get(rx,4)!=0x500050||get(rx,5)!=32||get(rx,6)!=(three?51211u:51210u))throw std::runtime_error("Raw header/tag/status/shape mismatch");
        const unsigned f=8+51200;
        if(get(rx,f)||get(rx,f+8)!=76800||get(rx,f+9)!=51200)throw std::runtime_error("Raw footer status/length mismatch");
        profile.job_cycles=get(rx,f+1);profile.conv0_cycles=get(rx,f+2);profile.conv1_cycles=get(rx,f+3);
        profile.feed_cycles=get(rx,f+4);profile.fusion_cycles=get(rx,f+5);profile.input_fill_cycles=get(rx,f+6);profile.output_stall_cycles=get(rx,f+7);
        if(three)profile.conv2_cycles=get(rx,f+10);
    }
    {ScopeTimer t(&p->restore_ms);
        if(capture)captured.resize(204800);
        const auto* source=reinterpret_cast<const std::int8_t*>(rx.data()+32);
        for(int tile=0;tile<20;++tile)for(int c=0;c<32;++c){
            float* d=output.channel(c);d+=tile*320;const auto* q=source+(tile*32+c)*320;
            for(int i=0;i<320;++i)d[i]=float(q[i])*(three?parameters.third_scale:parameters.second_scale);
            if(capture)std::memcpy(captured.data()+c*6400+tile*320,q,320);
        }
    }
    return output;
}
} // namespace y26
