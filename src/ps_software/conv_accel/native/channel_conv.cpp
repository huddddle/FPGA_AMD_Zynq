#include "channel_conv.hpp"
#include "fusion.hpp"
#include <algorithm>
#include <cmath>
#include <stdexcept>
namespace y26 {
ConvGeometry::ConvGeometry(int ci,int co,int h,int w,int k,int s,int p):
    inputs(ci),outputs(co),height(h),width(w),kernel(k),stride(s),padding(p){
    if(ci<1||co<1||h<1||w<1||(k!=1&&k!=3)||(s!=1&&s!=2)||(p!=0&&p!=1)||
       h+2*p<k||w+2*p<k||std::int64_t(ci)*k*k*32768*32768>=(1LL<<47))
        throw std::runtime_error("Unsupported convolution geometry/INT48 bound");
}
std::vector<std::int16_t> quantize_conv_weights(const float* w,int outputs,int per_output){
    std::vector<std::int16_t> q(outputs*per_output);
    for(int c=0;c<outputs;++c){
        double peak=0;
        for(int i=0;i<per_output;++i){double v=w[c*per_output+i];if(!std::isfinite(v))throw std::runtime_error("Nonfinite weight");peak=std::max(peak,std::abs(v));}
        const double scale=peak==0?1:peak/32767.;
        for(int i=0;i<per_output;++i)q[c*per_output+i]=std::int16_t(std::nearbyint(double(w[c*per_output+i])/scale));
    }
    return q;
}
std::vector<std::int8_t> fused_conv_reference(const std::vector<std::int16_t>& x,
    const std::vector<std::int16_t>& w,const ConvGeometry& s,const std::vector<FusionChannel>& p){
    if(x.size()!=size_t(s.inputs*s.height*s.width)||w.size()!=size_t(s.outputs*s.inputs*s.kernel*s.kernel)||p.size()!=size_t(s.outputs))
        throw std::runtime_error("Convolution tensor/parameter shape mismatch");
    const int oh=s.output_height(),ow=s.output_width();std::vector<std::int8_t> q(s.outputs*oh*ow);
    for(int oc=0;oc<s.outputs;++oc)for(int y=0;y<oh;++y)for(int z=0;z<ow;++z){
        std::int64_t sum=0;
        for(int ib=0;ib<s.inputs;ib+=3)for(int lane=0;lane<3&&ib+lane<s.inputs;++lane)
            for(int ky=0;ky<s.kernel;++ky)for(int kx=0;kx<s.kernel;++kx){
                const int iy=y*s.stride-s.padding+ky,ix=z*s.stride-s.padding+kx,ic=ib+lane;
                if(iy>=0&&iy<s.height&&ix>=0&&ix<s.width)
                    sum+=std::int64_t(x[(ic*s.height+iy)*s.width+ix])*w[((oc*s.inputs+ic)*s.kernel+ky)*s.kernel+kx];
            }
        q[(oc*oh+y)*ow+z]=requantize_int8(sum,p[oc].bias,p[oc].multiplier,p[oc].shift,true);
    }
    return q;
}
}
