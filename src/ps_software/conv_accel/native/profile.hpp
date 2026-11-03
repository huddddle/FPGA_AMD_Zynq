#pragma once
#include <chrono>
#include <cstdint>
#include <vector>
namespace y26 {
using ProfileClock=std::chrono::steady_clock;
// Optional timers never sample the clock when disabled. No per-pixel timing or I/O.
class ScopeTimer {
    double* target;
    ProfileClock::time_point start;
public:
    explicit ScopeTimer(double* value):target(value){if(target)start=ProfileClock::now();}
    ~ScopeTimer(){if(target)*target+=std::chrono::duration<double,std::milli>(ProfileClock::now()-start).count();}
    ScopeTimer(const ScopeTimer&)=delete;
    ScopeTimer& operator=(const ScopeTimer&)=delete;
};
struct TransferProfile {
    double open_ms=0,rx_allocate_ms=0,ioctl_ms=0,close_ms=0;
    std::uint64_t tx_bytes=0,rx_bytes=0;
    unsigned calls=0;
};
struct FirstProfile {
    double total_ms=0,allocation_ms=0,input_quantize_ms=0,patch_ms=0,result_allocation_ms=0;
    double encode_ms=0,backend_ms=0,decode_ms=0,restore_ms=0,fusion_config_ms=0;
    TransferProfile transfer;
    std::uint64_t core_cycles=0;
    std::vector<std::uint32_t> tile_cycles;
};
} // namespace y26
