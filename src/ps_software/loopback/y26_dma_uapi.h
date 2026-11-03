#ifndef Y26_DMA_UAPI_H
#define Y26_DMA_UAPI_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define Y26_DMA_MAX_BYTES 4096U
#define Y26_DMA_V2_MAX_BYTES 524288U
#define Y26_DMA_ABI_V2 2U
#define Y26_DMA_DONE_TX 1U
#define Y26_DMA_DONE_RX 2U

/* Byte lengths include protocol headers; this changes capacity, not the ABI. */
static inline int y26_dma_v2_valid_lengths(__u32 tx_bytes, __u32 rx_bytes)
{
    return tx_bytes && rx_bytes && tx_bytes <= Y26_DMA_V2_MAX_BYTES &&
           rx_bytes <= Y26_DMA_V2_MAX_BYTES && !((tx_bytes | rx_bytes) & 3U);
}

/* Fixed-width ABI, shared unchanged by the kernel and ARM32 application. */
struct y26_dma_transfer {
    __u32 bytes;
    __u32 timeout_ms;
    __aligned_u64 tx_user;
    __aligned_u64 rx_user;
    __u32 completed;
    __u32 reserved;
};

#define Y26_DMA_TRANSFER _IOWR('Y', 1, struct y26_dma_transfer)

/* Independent TX/RX lengths. V1 remains binary compatible for the old raw loopback.
 * V2 ioctl does not imply that the PL understands a particular packet protocol. */
struct y26_dma_transfer_v2 {
    __u32 version;
    __u32 tx_bytes;
    __u32 rx_bytes;
    __u32 timeout_ms;
    __aligned_u64 tx_user;
    __aligned_u64 rx_user;
    __u32 completed;
    __u32 reserved;
};

#define Y26_DMA_TRANSFER_V2 _IOWR('Y', 2, struct y26_dma_transfer_v2)

#endif
