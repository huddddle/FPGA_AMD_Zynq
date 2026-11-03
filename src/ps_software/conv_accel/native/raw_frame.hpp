#pragma once
#include "two_layer.hpp"
namespace y26 {
void validate_raw_system(bool three,const std::string& verified_bit="");
struct RawProfile {
    FirstProfile cpu;
    std::uint32_t job_cycles=0,conv0_cycles=0,conv1_cycles=0,conv2_cycles=0,feed_cycles=0;
    std::uint32_t fusion_cycles=0,input_fill_cycles=0,output_stall_cycles=0;
};
class RawFrame {
    ChainParameters parameters;
    std::vector<std::int16_t> first_weights,second_weights,third_weights;
    std::vector<std::uint8_t> load,tx,rx;
public:
    RawProfile profile;
    std::vector<std::int8_t> captured;
    RawFrame(const std::string& model,const ChainParameters&);
    void export_requests(const std::string& directory,const std::uint8_t* rgb);
    ncnn::Mat run(const std::uint8_t* rgb,bool dma,const char* device,bool capture=true,const std::string& verified_bit="");
};
} // namespace y26
