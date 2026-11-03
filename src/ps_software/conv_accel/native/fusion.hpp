#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <vector>
namespace y26 {
struct Tile;
struct FusionParameters {
    float output_scale=1.f;
    std::array<std::uint32_t,16> multiplier{},shift{};
    std::array<std::int64_t,16> bias{};
};
FusionParameters load_fusion_parameters(const std::string&);
std::int8_t requantize_int8(std::int64_t accumulator,std::int64_t bias,std::uint32_t multiplier,unsigned shift,bool relu);
void encode_fused_tile_into(const Tile&,const std::vector<std::int16_t>&,const std::vector<std::int16_t>&,std::vector<std::uint8_t>&);
void decode_fused_tile_into(const Tile&,const std::vector<std::uint8_t>&,std::vector<std::int8_t>&,std::uint32_t* cycles=nullptr);
class FusionRegisters {
    int fd_;
    volatile std::uint32_t* registers_;
public:
    FusionRegisters();
    ~FusionRegisters();
    FusionRegisters(const FusionRegisters&)=delete;
    FusionRegisters& operator=(const FusionRegisters&)=delete;
    void program(const FusionParameters&,bool relu);
};
}
