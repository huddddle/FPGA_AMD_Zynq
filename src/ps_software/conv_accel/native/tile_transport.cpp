#include "tile_transport.hpp"
#include "../../loopback/y26_dma_uapi.h"
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <stdexcept>
#include <string>
#include <sys/ioctl.h>
#include <unistd.h>

namespace y26 {
namespace {
void put_at(std::uint8_t* b,std::uint32_t value) {
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    std::memcpy(b,&value,4);
#else
    for(unsigned i=0;i<4;++i)b[i]=std::uint8_t(value>>(i*8));
#endif
}
void put(std::vector<std::uint8_t>& b,std::uint32_t value) {
    for(unsigned i=0;i<4;++i)b.push_back(std::uint8_t(value>>(i*8)));
}
std::uint32_t get(const std::vector<std::uint8_t>& b,unsigned offset) {
    if(offset>b.size()||b.size()-offset<4)throw std::runtime_error("Truncated protocol word");
    std::uint32_t v=0;
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    std::memcpy(&v,b.data()+offset,4);
#else
    for(unsigned i=0;i<4;++i)v|=std::uint32_t(b[offset+i])<<(8*i);
#endif
    return v;
}
void triplet_at(std::uint8_t* b,const std::int16_t* values) {
    put_at(b,std::uint16_t(values[0])|(std::uint32_t(std::uint16_t(values[1]))<<16));
    put_at(b+4,std::uint16_t(values[2]));
}
void valid(const Tile& t) {
    if((t.kernel!=1&&t.kernel!=3)||(t.stride!=1&&t.stride!=2)||t.inputs<1||t.inputs>3||
       t.outputs<1||t.outputs>16||t.width<1||t.width>160||t.height<1||t.height>4)
        throw std::runtime_error("Unsupported convolution tile");
}
} // namespace

std::vector<std::uint8_t> encode_tile(const Tile& t,const std::vector<std::int16_t>& patch,
                                    const std::vector<std::int16_t>& weights) {
    std::vector<std::uint8_t> result;encode_tile_into(t,patch,weights,result);return result;
}

void encode_tile_into(const Tile& t,const std::vector<std::int16_t>& patch,
                      const std::vector<std::int16_t>& weights,std::vector<std::uint8_t>& b) {
    valid(t);
    const unsigned pixels=((t.height-1)*t.stride+t.kernel)*((t.width-1)*t.stride+t.kernel);
    if(patch.size()!=pixels*3||weights.size()!=16*9*3)throw std::runtime_error("Tile input/weight size mismatch");
    b.resize(32+(144+pixels)*8);
    const std::uint32_t header[]={0x59323643,0x10001,t.tag,
        t.kernel|(t.stride<<2)|(t.inputs<<4)|(t.outputs<<8),t.width|(t.height<<16),
        t.first?1U:0U,(144+pixels)*2,8+t.outputs*t.width*t.height*2};
    for(unsigned i=0;i<8;++i)put_at(b.data()+i*4,header[i]);
    for(unsigned i=0;i<144;++i)triplet_at(b.data()+32+i*8,&weights[i*3]);
    for(unsigned i=0;i<pixels;++i)triplet_at(b.data()+32+(144+i)*8,&patch[i*3]);
}

std::vector<std::int64_t> decode_tile(const Tile& t,const std::vector<std::uint8_t>& b,std::uint32_t* cycles) {
    std::vector<std::int64_t> result;decode_tile_into(t,b,result,cycles);return result;
}

void decode_tile_into(const Tile& t,const std::vector<std::uint8_t>& b,std::vector<std::int64_t>& result,std::uint32_t* cycles) {
    valid(t);
    const unsigned count=t.outputs*t.height*t.width;
    if(b.size()!=32+count*8||get(b,0)!=0x59323652||get(b,4)!=0x10001||get(b,8)!=t.tag||
       get(b,12)!=0||get(b,16)!=(t.width|(t.height<<16))||get(b,20)!=t.outputs||get(b,24)!=count*2)
        throw std::runtime_error("PL response magic/version/tag/status/shape/length mismatch");
    result.resize(count);
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    std::memcpy(result.data(),b.data()+32,count*8);
#else
    for(unsigned i=0;i<count;++i) {
        const std::uint64_t bits=get(b,32+i*8)|(std::uint64_t(get(b,36+i*8))<<32);
        std::memcpy(&result[i],&bits,8);
    }
#endif
    for(unsigned i=0;i<count;++i) {
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
        std::uint32_t high;std::memcpy(&high,b.data()+36+i*8,4);
        if(high+0x8000U>0xffffU)
#else
        if(result[i]<-(std::int64_t(1)<<47)||result[i]>=(std::int64_t(1)<<47))
#endif
            throw std::runtime_error("PL result is not sign-extended INT48");
    }
    if(cycles)*cycles=get(b,28);
}

DmaSession::DmaSession(const char* device,TransferProfile* profile):fd_(-1),profile_(profile) {
    {ScopeTimer timer(profile_?&profile_->open_ms:nullptr);fd_=::open(device,O_RDWR|O_CLOEXEC);}
    if(fd_<0)throw std::runtime_error(std::string("Cannot open DMA device: ")+std::strerror(errno));
}

DmaSession::~DmaSession() {
    ScopeTimer timer(profile_?&profile_->close_ms:nullptr);::close(fd_);
}

void DmaSession::transfer(const std::vector<std::uint8_t>& tx,std::vector<std::uint8_t>& rx,
                          unsigned rx_bytes,unsigned timeout_ms) {
    static_assert(sizeof(y26_dma_transfer_v2)==40,"V2 ABI layout");
    if(tx.size()>Y26_DMA_V2_MAX_BYTES||!y26_dma_v2_valid_lengths(unsigned(tx.size()),rx_bytes)||
       timeout_ms>5000)throw std::runtime_error("Invalid DMA lengths/timeout");
    {ScopeTimer timer(profile_?&profile_->rx_allocate_ms:nullptr);rx.resize(rx_bytes);}
    y26_dma_transfer_v2 request={};request.version=Y26_DMA_ABI_V2;
    request.tx_bytes=tx.size();request.rx_bytes=rx_bytes;request.timeout_ms=timeout_ms;
    request.tx_user=reinterpret_cast<std::uintptr_t>(tx.data());
    request.rx_user=reinterpret_cast<std::uintptr_t>(rx.data());
    int ret,saved;
    {ScopeTimer timer(profile_?&profile_->ioctl_ms:nullptr);ret=::ioctl(fd_,Y26_DMA_TRANSFER_V2,&request);saved=errno;}
    if(ret<0)throw std::runtime_error(std::string("DMA V2 ioctl failed: ")+std::strerror(saved));
    if(request.completed!=(Y26_DMA_DONE_TX|Y26_DMA_DONE_RX))throw std::runtime_error("DMA completion missing");
    if(profile_){++profile_->calls;profile_->tx_bytes+=tx.size();profile_->rx_bytes+=rx_bytes;}
}

std::vector<std::uint8_t> dma_transfer(const char* device,const std::vector<std::uint8_t>& tx,
                                     unsigned rx_bytes,unsigned timeout_ms,TransferProfile* profile) {
    DmaSession session(device,profile);std::vector<std::uint8_t> rx;
    session.transfer(tx,rx,rx_bytes,timeout_ms);return rx;
}

void framed_echo(const char* device) {
    std::vector<std::uint8_t> tx;
    for(auto v:std::vector<std::uint32_t>{0x59323643,0x10000,0x10203040,0,0,0,4,12,
                                        0,0xffffffff,0x12345678,0xabcdef12})put(tx,v);
    const auto rx=dma_transfer(device,tx,48);
    if(get(rx,0)!=0x59323652||get(rx,4)!=0x10000||get(rx,8)!=0x10203040||get(rx,12)||
       get(rx,16)||get(rx,20)||get(rx,24)!=4||get(rx,28)||
       !std::equal(rx.begin()+32,rx.end(),tx.begin()+32))throw std::runtime_error("Framed echo comparison failed");
}
} // namespace y26
