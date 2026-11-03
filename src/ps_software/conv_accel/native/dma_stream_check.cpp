// Diagnostic stream echo, explicitly select the matched PL system; no CNN computation.
#include "tile_transport.hpp"
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
static void word(std::vector<std::uint8_t>& b,std::uint32_t v){for(unsigned i=0;i<4;++i)b.push_back(std::uint8_t(v>>(8*i)));}
static std::uint32_t get(const std::vector<std::uint8_t>& b,unsigned i){if(i*4+4>b.size())throw std::runtime_error("Short response");std::uint32_t v;std::memcpy(&v,b.data()+i*4,4);return v;}
int main(int argc,char** argv){
    try{
        unsigned bytes=4096,iterations=4;std::string device="/dev/y26_dma_loopback",system="chain",bit;
        for(int i=1;i<argc;++i){std::string a=argv[i];
            if(a=="--help"){std::cout<<"y26-dma-stream --payload-bytes 4..524252 --iterations 1..20 [--device path] [--system chain|frame|three|hotspot56|unified] [--bit-sha256 HASH required for hotspot56/unified]\n";return 0;}
            if(i+1==argc)throw std::runtime_error("Missing option value");
            if(a=="--payload-bytes")bytes=std::stoul(argv[++i]);
            else if(a=="--iterations")iterations=std::stoul(argv[++i]);
            else if(a=="--device")device=argv[++i];
            else if(a=="--system")system=argv[++i];
            else if(a=="--bit-sha256")bit=argv[++i];
            else throw std::runtime_error("Unknown option");
        }
        if(bytes<4||bytes>524252||bytes%4||iterations<1||iterations>20)throw std::runtime_error("Invalid stream lengths/iterations");
        if(system!="chain"&&system!="frame"&&system!="three"&&system!="hotspot56"&&system!="unified")throw std::runtime_error("Invalid --system; expected chain, frame, three, hotspot56 or unified");
        if((system=="hotspot56"||system=="unified")&&(bit.size()!=64||bit.find_first_not_of("0123456789abcdef")!=std::string::npos))throw std::runtime_error(system+" requires --bit-sha256 with 64 lowercase hex digits; DMA not started");
        std::ifstream dt("/proc/device-tree/model",std::ios::binary);std::string model((std::istreambuf_iterator<char>(dt)),{});
        if(!model.empty()&&model.back()=='\0')model.pop_back();
        const std::string expected=system=="unified"?"Embedfire Zynq7020 unified prefix3 hotspot56 INT8 fusion":system=="hotspot56"?"Embedfire Zynq7020 hotspot56 INT8 fusion":system=="three"?"Embedfire Zynq7020 RGB three-layer INT8 fusion":system=="frame"?"Embedfire Zynq7020 RGB frame INT8 fusion":"Embedfire Zynq7020 two-layer INT8 fusion";
        if(model!=expected)throw std::runtime_error("Matched "+system+" bit/DT required; DMA not started");
        if(!bit.empty()){
            std::ifstream identity("/proc/device-tree/chosen/y26,bitstream-sha256",std::ios::binary);std::string actual((std::istreambuf_iterator<char>(identity)),{});
            if(!actual.empty()&&actual.back()=='\0')actual.pop_back();
            if(actual!=bit)throw std::runtime_error("Bit SHA mismatch; DMA not started");
        }
        y26::TransferProfile profile;y26::DmaSession dma(device.c_str(),&profile);
        std::vector<std::uint8_t> tx,rx;
        for(unsigned n=0;n<iterations;++n){
            tx.clear();tx.reserve(bytes+32);const unsigned tag=0xe2000000+n;
            for(auto v:std::vector<std::uint32_t>{0x59323643,0x10012,tag,0,0,0,bytes/4,bytes/4+9})word(tx,v);
            std::uint32_t seed=0x12345678+n;
            for(unsigned i=0;i<bytes/4;++i){seed=seed*1664525U+1013904223U;word(tx,n%4==0?i:n%4==1?0:n%4==2?0xffffffffU:seed);}
            dma.transfer(tx,rx,bytes+36);
            if(rx.size()!=bytes+36||get(rx,0)!=0x59323652||get(rx,1)!=0x10012||get(rx,2)!=tag||get(rx,3)!=0||get(rx,4)!=0||get(rx,5)!=0||get(rx,6)!=bytes/4+1||get(rx,7)!=0||get(rx,8+bytes/4)!=0||!std::equal(tx.begin()+32,tx.end(),rx.begin()+32))
                throw std::runtime_error("Stream data/header/footer mismatch");
        }
        double rate=profile.ioctl_ms>0?(2.*bytes*iterations/1000.)/profile.ioctl_ms:0;
        std::cout<<"STREAM ECHO PASS payload_bytes="<<bytes<<" iterations="<<iterations<<" mismatches=0 tx_bytes="<<profile.tx_bytes<<" rx_bytes="<<profile.rx_bytes<<" ioctl_total_ms="<<profile.ioctl_ms<<" bidirectional_ioctl_payload_MBps="<<rate<<" (includes copies, setup and waits; not raw bus bandwidth)\n";
    }catch(const std::exception& e){std::cerr<<"ERROR: "<<e.what()<<'\n';return 1;}
}
