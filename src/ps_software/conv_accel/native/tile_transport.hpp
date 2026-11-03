#pragma once
#include <cstdint>
#include <vector>
#include "profile.hpp"

namespace y26 {
struct Tile {
    unsigned kernel=3,stride=2,inputs=3,outputs=16,width=160,height=4;
    bool first=true;
    std::uint32_t tag=0;
};
std::vector<std::uint8_t> encode_tile(const Tile&,const std::vector<std::int16_t>& patch_hwc3,
                                    const std::vector<std::int16_t>& weights_otap3);
void encode_tile_into(const Tile&,const std::vector<std::int16_t>& patch_hwc3,
                      const std::vector<std::int16_t>& weights_otap3,std::vector<std::uint8_t>& request);
std::vector<std::int64_t> decode_tile(const Tile&,const std::vector<std::uint8_t>&,std::uint32_t* cycles=nullptr);
void decode_tile_into(const Tile&,const std::vector<std::uint8_t>&,std::vector<std::int64_t>& result,std::uint32_t* cycles=nullptr);
// One serialized forward owns its descriptor; never shared between extractors.
class DmaSession {
    int fd_;
    TransferProfile* profile_;
public:
    explicit DmaSession(const char* device,TransferProfile* profile=nullptr);
    ~DmaSession();
    DmaSession(const DmaSession&)=delete;
    DmaSession& operator=(const DmaSession&)=delete;
    void transfer(const std::vector<std::uint8_t>& tx,std::vector<std::uint8_t>& rx,
                  unsigned rx_bytes,unsigned timeout_ms=1000);
};
std::vector<std::uint8_t> dma_transfer(const char* device,const std::vector<std::uint8_t>& tx,
                                     unsigned rx_bytes,unsigned timeout_ms=1000,TransferProfile* profile=nullptr);
void framed_echo(const char* device);
} // namespace y26
