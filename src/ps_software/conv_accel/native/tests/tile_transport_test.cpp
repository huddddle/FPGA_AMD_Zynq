#include "tile_transport.hpp"
#include <iostream>
#include <stdexcept>
#include <vector>
static void need(bool ok) {if(!ok) throw std::runtime_error("test assertion");}
static void word(std::vector<std::uint8_t>& b,std::uint32_t v) {
    for(int i=0;i<4;++i)b.push_back(std::uint8_t(v>>(i*8)));
}
int main() {
    try {
        y26::Tile t;t.kernel=1;t.stride=1;t.outputs=2;t.width=1;t.height=1;t.tag=42;
        std::vector<std::int16_t> patch={3,-2,5},weights(16*9*3,0);
        weights[0]=-7;weights[27]=5;
        auto tx=y26::encode_tile(t,patch,weights);
        need(tx.size()==1192);need(tx[0]==0x43&&tx[3]==0x59&&tx[8]==42);
        need(tx[32]==0xf9&&tx[33]==0xff&&tx[34]==0);
        need(tx[1184]==3&&tx[1186]==0xfe&&tx[1187]==0xff&&tx[1188]==5);
        std::vector<std::uint8_t> reusable_request(2048,0xa5);
        y26::encode_tile_into(t,patch,weights,reusable_request);
        need(reusable_request==tx);
        std::vector<std::uint8_t> rx;
        for(auto v:std::vector<std::uint32_t>{0x59323652,0x10001,42,0,0x10001,2,4,100,
                                            0xffffffeb,0xffffffff,15,0})word(rx,v);
        std::uint32_t cycles=0;
        auto result=y26::decode_tile(t,rx,&cycles);need(result.size()==2&&result[0]==-21&&result[1]==15);
        need(cycles==100); // Hardware counter in the independently authored response header.
        std::vector<std::int64_t> reusable_result(8,123);
        y26::decode_tile_into(t,rx,reusable_result,&cycles);
        need(reusable_result.size()==2&&reusable_result[0]==-21&&reusable_result[1]==15&&cycles==100);
        // Independent literal INT48 boundaries; caller-owned storage must be resized and overwritten.
        const auto original_rx=rx;
        rx.resize(32);
        for(auto v:std::vector<std::uint32_t>{0,0xffff8000,0xffffffff,0x00007fff})word(rx,v);
        y26::decode_tile_into(t,rx,reusable_result);
        need(reusable_result[0]==-140737488355328LL&&reusable_result[1]==140737488355327LL);
        rx=original_rx;
        rx[8]=43;
        bool rejected=false;try{y26::decode_tile(t,rx);}catch(const std::runtime_error&){rejected=true;}
        need(rejected);rx[8]=42;rx[39]=0;
        rejected=false;try{y26::decode_tile(t,rx);}catch(const std::runtime_error&){rejected=true;}
        need(rejected);
        bool unavailable=false;
        try{y26::dma_transfer("/dev/y26-does-not-exist",tx,48);}catch(const std::runtime_error&){unavailable=true;}
        need(unavailable); // Hardware absence must never silently fall back to a CPU.
        unavailable=false;
        try{y26::DmaSession session("/dev/y26-does-not-exist");}catch(const std::runtime_error&){unavailable=true;}
        need(unavailable);
        std::cout<<"TILE TRANSPORT PASS signed_int48=1 tag_rejected=1 missing_hardware_rejected=1\n";
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
