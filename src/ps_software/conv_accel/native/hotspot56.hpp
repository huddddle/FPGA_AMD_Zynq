#pragma once
#include "channel_conv.hpp"
#include "profile.hpp"
#include "mat.h"
#include <string>
namespace y26 {
struct HotspotProfile {
    FirstProfile cpu;
    std::uint32_t job_cycles=0,conv5_cycles=0,conv6_cycles=0,feed_cycles=0,fusion_cycles=0,fill_cycles=0,stall_cycles=0;
};
// Fixed graph boundary, reusable existing 3IC x16OC tile arithmetic; no CPU fallback.
class Hotspot56 {
    float input_scale,output_scale;
    std::vector<FusionChannel> p5,p6;
    std::vector<std::int16_t> w5,w6;
    std::vector<std::uint8_t> load,tx,rx;
public:
    HotspotProfile profile;
    std::vector<std::int8_t> captured;
    explicit Hotspot56(const std::string& parameters);
    ncnn::Mat run(const ncnn::Mat&,bool dma,const char* device,const std::string& verified_bit,bool capture=true);
    void export_requests(const std::string& directory);
};
void validate_hotspot_graph(const std::string& graph);
}
