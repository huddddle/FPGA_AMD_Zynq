#include "fusion.hpp"
#include "tile_transport.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
namespace y26 {
namespace {
std::uint32_t word(const std::vector<std::uint8_t>& b,unsigned p){
    std::uint32_t v=0;for(unsigned i=0;i<4;++i)v|=std::uint32_t(b[p+i])<<(i*8);return v;
}
void put(std::vector<std::uint8_t>& b,unsigned p,std::uint32_t v){for(unsigned i=0;i<4;++i)b[p+i]=std::uint8_t(v>>(i*8));}
}
FusionParameters load_fusion_parameters(const std::string& path){
    std::ifstream f(path);std::string magic;FusionParameters p;
    if(!(f>>magic>>p.output_scale)||magic!="Y26F1"||!std::isfinite(p.output_scale)||p.output_scale<=0)throw std::runtime_error("Invalid fusion parameter header");
    for(unsigned c=0;c<16;++c){
        unsigned long long m,n;long long b;
        if(!(f>>m>>n>>b)||m>0xffffffffULL||n>31||b<-(1LL<<47)||b>=(1LL<<47))throw std::runtime_error("Invalid fusion channel parameters");
        p.multiplier[c]=m;p.shift[c]=n;p.bias[c]=b;
    }
    std::string extra;if(f>>extra)throw std::runtime_error("Unexpected fusion parameter data");return p;
}
std::int8_t requantize_int8(std::int64_t a,std::int64_t b,std::uint32_t m,unsigned n,bool relu){
    if(a<-(1LL<<47)||a>=(1LL<<47)||b<-(1LL<<47)||b>=(1LL<<47)||n>31)throw std::runtime_error("Invalid requantization input");
    const auto sum=a+b;if(!m||(relu&&sum<0))return 0;
    const bool negative=sum<0;const std::uint64_t magnitude=negative ? -sum : sum;
    // Above this exact bound the final INT8 is saturated; avoid an overflowing 81-bit product on ARM32.
    const std::uint64_t threshold=std::uint64_t(128)<<n;
    if(magnitude>threshold/m)return negative ? -128 : 127;
    const std::uint64_t product=magnitude*m;std::uint64_t q=product>>n;
    if(n){const auto remainder=product&((std::uint64_t(1)<<n)-1),half=std::uint64_t(1)<<(n-1);q+=remainder>half||(remainder==half&&(q&1));}
    const auto signed_result=negative ? -std::int64_t(q) : std::int64_t(q);
    return std::int8_t(std::max<std::int64_t>(-128,std::min<std::int64_t>(127,signed_result)));
}
void encode_fused_tile_into(const Tile& t,const std::vector<std::int16_t>& patch,const std::vector<std::int16_t>& weights,std::vector<std::uint8_t>& out){
    encode_tile_into(t,patch,weights,out);put(out,4,0x10002);put(out,28,8+(t.outputs*t.width*t.height+3)/4);
}
void decode_fused_tile_into(const Tile& t,const std::vector<std::uint8_t>& b,std::vector<std::int8_t>& out,std::uint32_t* cycles){
    const unsigned count=t.outputs*t.width*t.height,padded=(count+3)/4*4;
    if(t.outputs<1||t.outputs>16||t.width<1||t.width>160||t.height<1||t.height>4||b.size()!=32+padded||
       word(b,0)!=0x59323652||word(b,4)!=0x10002||word(b,8)!=t.tag||word(b,12)!=0||word(b,16)!=(t.width|(t.height<<16))||
       word(b,20)!=t.outputs||word(b,24)!=padded/4)throw std::runtime_error("Fused INT8 response contract mismatch");
    for(unsigned i=count;i<padded;++i)if(b[32+i])throw std::runtime_error("Nonzero fused tail padding");
    out.resize(count);std::memcpy(out.data(),b.data()+32,count);if(cycles)*cycles=word(b,28);
}
FusionRegisters::FusionRegisters():fd_(-1),registers_(nullptr){
    std::ifstream dt("/proc/device-tree/model",std::ios::binary);const std::string model((std::istreambuf_iterator<char>(dt)),{});
    if(model.find("INT8 fusion")==std::string::npos)throw std::runtime_error("Matched fusion bit/DT must be booted before accessing AXI-Lite");
    fd_=::open("/dev/mem",O_RDWR|O_SYNC|O_CLOEXEC);if(fd_<0)throw std::runtime_error("Cannot open fusion control /dev/mem");
    void* address=::mmap(nullptr,4096,PROT_READ|PROT_WRITE,MAP_SHARED,fd_,0x43c10000);
    if(address==MAP_FAILED){::close(fd_);throw std::runtime_error("Cannot map fusion AXI-Lite registers");}
    registers_=static_cast<volatile std::uint32_t*>(address);
    if(registers_[2]!=0x59324631){::munmap(address,4096);::close(fd_);throw std::runtime_error("Fusion register signature mismatch");}
}
FusionRegisters::~FusionRegisters(){::munmap(const_cast<std::uint32_t*>(registers_),4096);::close(fd_);}
void FusionRegisters::program(const FusionParameters& p,bool relu){
    if(registers_[1])throw std::runtime_error("Fusion engine busy during configuration");
    registers_[0]=0;__sync_synchronize();
    for(unsigned c=0;c<16;++c){
        const unsigned i=(0x100+c*16)/4;const std::uint64_t bias=p.bias[c];
        registers_[i]=p.multiplier[c];registers_[i+1]=p.shift[c];registers_[i+2]=std::uint32_t(bias);registers_[i+3]=(bias>>32)&0xffff;
    }
    __sync_synchronize();
    for(unsigned c=0;c<16;++c){
        const unsigned i=(0x100+c*16)/4;const std::uint64_t bias=p.bias[c];
        if(registers_[i]!=p.multiplier[c]||registers_[i+1]!=p.shift[c]||registers_[i+2]!=std::uint32_t(bias)||registers_[i+3]!=((bias>>32)&0xffff))throw std::runtime_error("Fusion register readback mismatch");
    }
    registers_[0]=relu ? 3 : 1;__sync_synchronize();
    if(registers_[0]!=(relu?3U:1U))throw std::runtime_error("Fusion control did not enable");
}
}
