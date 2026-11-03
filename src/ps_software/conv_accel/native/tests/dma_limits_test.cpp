// Public transfer-length validation shared by the client and userspace.
#include "../../../loopback/y26_dma_uapi.h"
#include <cassert>
#include <iostream>
int main() {
    static_assert(sizeof(y26_dma_transfer_v2)==40,"Existing V2 ABI must stay stable");
    static_assert(sizeof(y26_dma_transfer)==32,"Existing V1 ABI must stay stable");
    assert(y26_dma_v2_valid_lengths(4,524288));
    assert(y26_dma_v2_valid_lengths(524288,4));
    assert(y26_dma_v2_valid_lengths(524288,524288));
    assert(y26_dma_v2_valid_lengths(131072,131072));
    assert(!y26_dma_v2_valid_lengths(524292,4));
    assert(!y26_dma_v2_valid_lengths(4,524292));
    assert(!y26_dma_v2_valid_lengths(0,4));
    assert(!y26_dma_v2_valid_lengths(4,0));
    assert(!y26_dma_v2_valid_lengths(5,4));
    assert(!y26_dma_v2_valid_lengths(4,7));
    assert(Y26_DMA_MAX_BYTES==4096);
    std::cout<<"DMA LIMITS PASS: 512 KiB each way; V1/V2 ABI unchanged\n";
}
