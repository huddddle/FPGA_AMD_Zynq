#pragma once
#include "net.h"
#include <cstdint>
#include <string>
#include <vector>
#include "profile.hpp"
#include "fusion.hpp"
namespace y26 {
enum class Backend {IntegerReference,Dma};
struct Context {
    Backend backend=Backend::IntegerReference;
    std::string device="/dev/y26_dma_loopback";
    unsigned transactions=0;
    std::vector<std::int64_t> accumulator;
    bool capture_accumulator=true; // Validation default; disable for the measured inference-only path.
    bool profile_enabled=false;
    FirstProfile profile;
    bool fused=false;
    FusionParameters fusion;
    std::vector<std::int8_t> quantized_output;
};
// Context must outlive net. Changes only the first layer's type in an in-memory graph.
int register_first_layer(ncnn::Net&,Context&);
std::string adapt_first_layer_graph(const std::string&);
} // namespace y26
