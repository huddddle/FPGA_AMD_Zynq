#pragma once
#include "net.h"
#include "channel_conv.hpp"
#include "profile.hpp"
#include <string>
namespace y26 {
struct ChainParameters {float first_scale=0,second_scale=0,third_scale=0;std::vector<FusionChannel> first,second,third;};
struct ChainProfile {
    FirstProfile cpu;
    std::uint64_t conv0_cycles=0,conv1_cycles=0,pl_job_cycles=0;
    std::uint64_t internal_tx_words=0,internal_rx_words=0;
};
struct ChainContext {
    bool dma=false,capture=true,profile_enabled=false;
    std::string device="/dev/y26_dma_loopback";
    ChainParameters parameters;
    ChainProfile profile;
    std::vector<std::int8_t> second_output;
};
ChainParameters load_chain_parameters(const std::string&);
std::vector<std::uint8_t> encode_chain_load(const std::vector<std::int16_t>&,
    const std::vector<std::int16_t>&,const ChainParameters&);
std::string adapt_two_layer_graph(const std::string&);
int register_two_layer(ncnn::Net&,ChainContext&);
}
