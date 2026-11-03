// Public AXIS acceptance driver for Verilator. Same vectors as the four-state TB.
// Manual clocking avoids simulator-specific fork/timing coroutine behavior.
#include "Vaxi_dut.h"
#include "verilated.h"
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>
int main(int argc,char** argv){try{
    if(argc!=3)throw std::runtime_error("axis_driver vectors responses");
    std::ifstream file(argv[1]);std::ofstream response(argv[2]);if(!file||!response)throw std::runtime_error("Vector I/O failed");
    VerilatedContext context;Vaxi_dut dut(&context);std::uint64_t ticks=0,total=0;bool held=false;std::uint32_t held_data=0;unsigned held_keep=0;bool held_last=false;
    auto reset=[&](){dut.aresetn=0;dut.s_axis_tvalid=0;dut.m_axis_tready=0;for(int i=0;i<5;++i){dut.aclk=0;dut.eval();dut.aclk=1;dut.eval();}dut.aresetn=1;held=false;};
    reset();unsigned count;file>>count;
    for(unsigned frame=0;frame<count;++frame){
        unsigned nt,nr;int bad;file>>std::dec>>nt>>nr>>bad;
        if(!file||nt>131072||nr>131072)throw std::runtime_error("Vector format");
        std::vector<std::uint32_t> tx(nt),gold(nr);for(auto& x:tx)file>>std::hex>>x;for(auto& x:gold)file>>std::hex>>x;
        unsigned si=0,ri=0,after_tx=0;bool reset_done=bad!=-2&&bad!=-3,send_hold=false;
        for(unsigned watchdog=0;;++watchdog){
            if(watchdog>30000000)throw std::runtime_error("AXIS watchdog frame="+std::to_string(frame));
            if(si==nt&&ri==nr&&reset_done)break;
            if(si==nt&&!reset_done&&++after_tx>(bad==-3?8000u:100u)){reset();reset_done=true;}
            dut.aclk=0;dut.eval();
            dut.s_axis_tvalid=si<nt&&(send_hold||ticks%7!=3);dut.s_axis_tdata=si<nt?tx[si]:0;
            dut.s_axis_tkeep=int(si)==bad?7:15;dut.s_axis_tlast=si+1==nt&&bad!=-3;
            dut.m_axis_tready=ri<nr&&ticks%11!=2&&ticks%11!=3&&ticks%11!=4;dut.eval();
            if(held&&(!dut.m_axis_tvalid||dut.m_axis_tdata!=held_data||dut.m_axis_tkeep!=held_keep||bool(dut.m_axis_tlast)!=held_last))throw std::runtime_error("Output changed under backpressure");
            held=dut.m_axis_tvalid&&!dut.m_axis_tready;held_data=dut.m_axis_tdata;held_keep=dut.m_axis_tkeep;held_last=dut.m_axis_tlast;
            const bool in=dut.s_axis_tvalid&&dut.s_axis_tready,out=dut.m_axis_tvalid&&dut.m_axis_tready;
            send_hold=dut.s_axis_tvalid&&!dut.s_axis_tready;
            if(out){
                if(dut.m_axis_tkeep!=15||bool(dut.m_axis_tlast)!=(ri+1==nr&&bad!=-3))throw std::runtime_error("Response framing frame="+std::to_string(frame));
                if(gold[ri]!=0xffffffffu&&dut.m_axis_tdata!=gold[ri])throw std::runtime_error("Response mismatch frame="+std::to_string(frame)+" word="+std::to_string(ri)+" actual="+std::to_string(dut.m_axis_tdata)+" expected="+std::to_string(gold[ri]));
                response<<std::dec<<frame<<' '<<std::hex<<dut.m_axis_tdata<<'\n';++ri;++total;
            }
            dut.aclk=1;dut.eval();if(in)++si;++ticks;
        }
        std::cout<<"FRAME case "<<frame+1<<'/'<<count<<" PASS ticks="<<ticks<<std::endl;
    }
    dut.final();std::cout<<"Y26 RAW FRAME PASS compared_words="<<total<<std::endl;return 0;
}catch(const std::exception& e){std::cerr<<"ERROR: "<<e.what()<<std::endl;return 1;}}
