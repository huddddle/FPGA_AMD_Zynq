#include "fusion.hpp"
#include "tile_transport.hpp"
#include <iostream>
#include <fstream>
#include <iomanip>
#include <stdexcept>
static void need(bool x){if(!x)throw std::runtime_error("fusion test assertion");}
static void word(std::vector<std::uint8_t>& b,std::uint32_t x){for(int i=0;i<4;++i)b.push_back(std::uint8_t(x>>(8*i)));}
int main(int argc,char** argv){try{
    need(y26::requantize_int8(11,1,5,2,false)==15);
    need(y26::requantize_int8(-10,3,3,1,false)==-10);
    need(y26::requantize_int8(-10,3,3,1,true)==0);
    need(y26::requantize_int8(1,0,1,1,false)==0);
    need(y26::requantize_int8(3,0,1,1,false)==2);
    need(y26::requantize_int8((1LL<<47)-1,(1LL<<47)-1,0xffffffff,0,false)==127);
    need(y26::requantize_int8(-(1LL<<47),-(1LL<<47),0xffffffff,31,false)==-128);
    y26::Tile t;t.kernel=1;t.stride=1;t.width=t.height=1;t.outputs=2;t.tag=42;
    std::vector<std::int16_t> patch={3,-2,5},weights(16*9*3,0);std::vector<std::uint8_t> tx;
    y26::encode_fused_tile_into(t,patch,weights,tx);need(tx[4]==2&&tx[28]==9);
    std::vector<std::uint8_t> rx;
    for(auto v:{0x59323652U,0x10002U,42U,0U,0x10001U,2U,1U,100U,0x00000febU})word(rx,v);
    std::vector<std::int8_t> values;std::uint32_t cycles=0;
    y26::decode_fused_tile_into(t,rx,values,&cycles);need(values.size()==2&&values[0]==-21&&values[1]==15&&cycles==100);
    rx.back()=1;bool rejected=false;try{y26::decode_fused_tile_into(t,rx,values);}catch(const std::runtime_error&){rejected=true;}
    need(rejected);
    if(argc==2){
        std::ifstream f(argv[1]);unsigned count;need(bool(f>>count));
        for(unsigned i=0;i<count;++i){
            unsigned long long a,b,m,n,r,gold;need(bool(f>>std::hex>>a>>b>>m>>n>>r>>gold));
            const std::int64_t sa=(a&(1ULL<<47)) ? std::int64_t(a)-(1LL<<48) : std::int64_t(a);
            const std::int64_t sb=(b&(1ULL<<47)) ? std::int64_t(b)-(1LL<<48) : std::int64_t(b);
            need(std::uint8_t(y26::requantize_int8(sa,sb,m,n,r))==gold);
        }
        std::cout<<"FUSION RANDOM REFERENCE PASS compared="<<count<<'\n';
    }
    std::cout<<"FUSION CPU AND WIRE PASS full_width_saturation=1 rne=1 signed_int8=1 padding_checked=1\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
