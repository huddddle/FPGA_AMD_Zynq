#include "first_layer.hpp"
#include "tile_transport.hpp"
#include "layer.h"
#include <algorithm>
#include <cmath>
#include <cfenv>
#include <cstdio>
#include <cstring>
#include <sstream>
#include <memory>
#include <stdexcept>

namespace y26 {
namespace {
class FirstLayer : public ncnn::Layer {
    Context* context;
    ncnn::Mat weights,bias;
    std::vector<std::int16_t> quantized_weights;
    double scale[16];
    int activation=0;
public:
    explicit FirstLayer(Context* c):context(c){one_blob_only=true;support_inplace=false;support_packing=false;}
    int load_param(const ncnn::ParamDict& p) override {
        const int kw=p.get(1,0),dw=p.get(2,1),sw=p.get(3,1),pl=p.get(4,0),pt=p.get(14,pl);
        activation=p.get(9,0);
        if(p.get(0,0)!=16||kw!=3||p.get(11,kw)!=3||dw!=1||p.get(12,dw)!=1||sw!=2||p.get(13,sw)!=2||
           pl!=1||p.get(15,pl)!=1||pt!=1||p.get(16,pt)!=1||p.get(18,0.f)!=0||p.get(5,0)!=1||
           p.get(6,0)!=432||p.get(8,0)!=0||p.get(19,0)!=0||(activation!=0&&activation!=1))return -200;
        return 0;
    }
    int load_model(const ncnn::ModelBin& mb) override {
        weights=mb.load(432,0);bias=mb.load(16,1);
        if(weights.empty()||bias.empty()||weights.elempack!=1||weights.elemsize!=4u||weights.total()!=432||bias.total()!=16)return -200;
        const float* w=weights;quantized_weights.resize(16*9*3,0);
        for(int oc=0;oc<16;++oc){
            double peak=0;
            for(int i=0;i<27;++i){if(!std::isfinite(w[oc*27+i]))return -200;peak=std::max(peak,std::abs(double(w[oc*27+i])));}
            scale[oc]=peak==0?1:peak/32767.;
            for(int tap=0;tap<9;++tap)for(int ic=0;ic<3;++ic)
                quantized_weights[(oc*9+tap)*3+ic]=std::int16_t(std::nearbyint(double(w[oc*27+ic*9+tap])/scale[oc]));
        }
        return 0;
    }
    int forward(const ncnn::Mat& in,ncnn::Mat& out,const ncnn::Option& opt) const override {
        if(!context||in.dims!=3||in.w!=320||in.h!=320||in.c!=3||in.elempack!=1||in.elemsize!=4u)return -200;
        try {
            FirstProfile* profile=nullptr;
            if(context->profile_enabled){context->profile=FirstProfile();context->profile.tile_cycles.reserve(40);profile=&context->profile;}
            ScopeTimer callback_timer(profile?&profile->total_ms:nullptr);
            std::vector<std::int16_t> qimage;
            std::vector<std::int16_t> patch;
            std::vector<std::int64_t> values;
            std::vector<std::int8_t> quantized;
            std::vector<std::uint8_t> request,response;
            std::unique_ptr<DmaSession> dma;
            std::unique_ptr<FusionRegisters> registers;
            {ScopeTimer timer(profile?&profile->allocation_ms:nullptr);
                out.create(160,160,16,4u,opt.blob_allocator);if(out.empty())return -100;
                context->transactions=0;
                if(context->capture_accumulator&&!context->fused)context->accumulator.resize(16*160*160);else context->accumulator.clear();
                if(context->capture_accumulator&&context->fused)context->quantized_output.resize(16*160*160);else context->quantized_output.clear();
                qimage.resize(3*320*320);
            }
            {ScopeTimer timer(profile?&profile->input_quantize_ms:nullptr);
                const bool nearest=std::fegetround()==FE_TONEAREST;
                for(int ic=0;ic<3;++ic){const float* p=in.channel(ic);for(int i=0;i<320*320;++i){
                    if(!(p[i]>=0.f&&p[i]<=1.000001f))throw std::runtime_error("First input must be RGB/255");
                    const double value=double(p[i])*255.;
                    int q;
                    if(nearest){
                        // In this FP32 RGB interval the only exact half-integer product is .5*255=127.5;
                        // its nearest-even result is 128, so positive half-up is identical to nearbyint.
                        q=int(value+.5);
                    }else q=int(std::nearbyint(value));
                    qimage[ic*320*320+i]=std::int16_t(q);
                }}
            }
            if(context->backend==Backend::Dma){
                if(context->fused){ScopeTimer timer(profile?&profile->fusion_config_ms:nullptr);registers.reset(new FusionRegisters());registers->program(context->fusion,activation==1);}
                ScopeTimer timer(profile?&profile->backend_ms:nullptr);dma.reset(new DmaSession(context->device.c_str(),profile?&profile->transfer:nullptr));
            }
            for(int y0=0;y0<160;y0+=4){
                Tile tile;tile.tag=0x32000000U+unsigned(y0/4);
                {ScopeTimer timer(profile?&profile->patch_ms:nullptr);patch.resize(9*321*3);
                    for(int py=0;py<9;++py){
                        const int iy=y0*2-1+py;auto dest=patch.data()+py*321*3;
                        if(iy<0||iy>=320){std::fill(dest,dest+321*3,0);continue;}
                        dest[0]=dest[1]=dest[2]=0;
                        const auto r=qimage.data()+iy*320,g=r+320*320,b=g+320*320;
                        for(int x=0;x<320;++x){dest[3+x*3]=r[x];dest[4+x*3]=g[x];dest[5+x*3]=b[x];}
                    }
                }
                {ScopeTimer timer(profile?&profile->result_allocation_ms:nullptr);
                    if(context->fused)quantized.resize(16*4*160);
                    if(!context->fused||context->backend==Backend::IntegerReference)values.resize(16*4*160);
                }
                if(context->backend==Backend::Dma){
                    {ScopeTimer timer(profile?&profile->encode_ms:nullptr);
                        if(context->fused)encode_fused_tile_into(tile,patch,quantized_weights,request);else encode_tile_into(tile,patch,quantized_weights,request);
                    }
                    {ScopeTimer timer(profile?&profile->backend_ms:nullptr);dma->transfer(request,response,context->fused ? 32+(quantized.size()+3)/4*4 : 32+values.size()*8);}
                    std::uint32_t cycles=0;
                    {ScopeTimer timer(profile?&profile->decode_ms:nullptr);
                        if(context->fused)decode_fused_tile_into(tile,response,quantized,profile?&cycles:nullptr);else decode_tile_into(tile,response,values,profile?&cycles:nullptr);
                    }
                    if(profile){profile->core_cycles+=cycles;profile->tile_cycles.push_back(cycles);}
                }else if(context->backend==Backend::IntegerReference){
                    ScopeTimer timer(profile?&profile->backend_ms:nullptr);
                    for(int oc=0;oc<16;++oc)for(int y=0;y<4;++y)for(int x=0;x<160;++x){
                        std::int64_t sum=0;
                        for(int ky=0;ky<3;++ky)for(int kx=0;kx<3;++kx)for(int ic=0;ic<3;++ic)
                            sum+=std::int64_t(patch[((y*2+ky)*321+x*2+kx)*3+ic])*quantized_weights[(oc*9+ky*3+kx)*3+ic];
                        values[(oc*4+y)*160+x]=sum;
                    }
                }else return -200;
                ++context->transactions;
                {ScopeTimer timer(profile?&profile->restore_ms:nullptr);
                const float* b=bias;
                if(context->fused){
                    if(context->backend==Backend::IntegerReference)for(int oc=0;oc<16;++oc)for(int i=0;i<4*160;++i)
                        quantized[oc*4*160+i]=requantize_int8(values[oc*4*160+i],context->fusion.bias[oc],context->fusion.multiplier[oc],context->fusion.shift[oc],activation==1);
                    for(int oc=0;oc<16;++oc){
                        const auto source=quantized.data()+oc*4*160;float* dest=out.channel(oc);dest+=y0*160;
                        if(context->capture_accumulator)std::memcpy(context->quantized_output.data()+(oc*160+y0)*160,source,4*160);
                        for(int i=0;i<4*160;++i)dest[i]=float(source[i])*context->fusion.output_scale;
                    }
                }else{
                for(int oc=0;oc<16;++oc){float* dest=out.channel(oc);dest+=y0*160;
                    const auto source=values.data()+oc*4*160;
                    if(context->capture_accumulator)std::memcpy(context->accumulator.data()+(oc*160+y0)*160,source,4*160*8);
                    const float weight_scale=float(scale[oc]),offset=b[oc];
                    // First-layer bound: 27*255*32767=225600795. Check before the faster exact INT32 conversion.
                    for(int i=0;i<4*160;++i)if(std::int64_t(std::int32_t(source[i]))!=source[i])throw std::runtime_error("First convolution result exceeds INT32");
                    // Same staged FP32 operations as the Python golden; no bias/activation in PL.
                    // Four independent scalar VFP chains hide latency without NEON's different subnormal/rounding rules.
                    for(int i=0;i<4*160;i+=4){
                        float r0=float(std::int32_t(source[i]))*float(1./255.);
                        float r1=float(std::int32_t(source[i+1]))*float(1./255.);
                        float r2=float(std::int32_t(source[i+2]))*float(1./255.);
                        float r3=float(std::int32_t(source[i+3]))*float(1./255.);
                        r0=r0*weight_scale+offset;r1=r1*weight_scale+offset;
                        r2=r2*weight_scale+offset;r3=r3*weight_scale+offset;
                        dest[i]=activation==1?std::max(0.f,r0):r0;
                        dest[i+1]=activation==1?std::max(0.f,r1):r1;
                        dest[i+2]=activation==1?std::max(0.f,r2):r2;
                        dest[i+3]=activation==1?std::max(0.f,r3):r3;
                }}
                }
                }
            }
            if(dma){ScopeTimer timer(profile?&profile->backend_ms:nullptr);dma.reset();}
            if(registers){ScopeTimer timer(profile?&profile->fusion_config_ms:nullptr);registers.reset();}
            return 0;
        }catch(const std::exception& e){std::fprintf(stderr,"Y26 first layer failed (%s); no CPU fallback\n",e.what());return -201;}
    }
};
ncnn::Layer* create(void* userdata){return new FirstLayer(static_cast<Context*>(userdata));}
} // namespace
int register_first_layer(ncnn::Net& net,Context& c){return net.register_custom_layer("Y26FirstConv",create,nullptr,&c);}
std::string adapt_first_layer_graph(const std::string& graph){
    std::istringstream stream(graph);std::string line,result,input;int changed=0;
    while(std::getline(stream,line)){
        std::istringstream fields(line);std::string type,name,bottom,top;int ni=0,no=0;
        fields>>type>>name>>ni>>no;
        if(type=="Input"&&ni==0&&no==1){fields>>input;}
        if(type=="Convolution"&&ni==1&&no==1){
            fields>>bottom>>top;
            if(!input.empty()&&bottom==input){line.replace(0,type.size(),"Y26FirstConv");++changed;}
        }
        result+=line+'\n';
    }
    if(changed!=1)throw std::runtime_error("Expected exactly one first convolution attached to input");
    return result;
}
} // namespace y26
