#pragma once
#include <cstdint>
#include <vector>
namespace y26 {
struct FusionChannel {
    std::int64_t bias=0;
    std::uint32_t multiplier=0;
    unsigned shift=0;
};
struct ConvGeometry {
    int inputs,outputs,height,width,kernel,stride,padding;
    ConvGeometry(int ci,int co,int h,int w,int k=3,int s=2,int p=1);
    int output_height()const{return (height+2*padding-kernel)/stride+1;}
    int output_width()const{return (width+2*padding-kernel)/stride+1;}
};
std::vector<std::int8_t> fused_conv_reference(const std::vector<std::int16_t>&,
    const std::vector<std::int16_t>&,const ConvGeometry&,const std::vector<FusionChannel>&);
std::vector<std::int16_t> quantize_conv_weights(const float*,int outputs,int per_output);
}
