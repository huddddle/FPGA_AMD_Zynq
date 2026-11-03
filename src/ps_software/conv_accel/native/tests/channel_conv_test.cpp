#include "channel_conv.hpp"
#include <cassert>
#include <iostream>
int main(){
    y26::ConvGeometry s(16,1,1,1,1,1,0);
    std::vector<std::int16_t> x(16,1),w(16,0);w[0]=-10;w[15]=20;
    std::vector<y26::FusionChannel> p(1);p[0].bias=5;p[0].multiplier=1;p[0].shift=0;
    assert(y26::fused_conv_reference(x,w,s,p)==std::vector<std::int8_t>(1,15));
    y26::ConvGeometry t(4,2,3,3,3,1,1);
    x.assign(36,1);w.assign(72,1);p.assign(2,y26::FusionChannel());
    p[0].multiplier=p[1].multiplier=1;
    const auto q=y26::fused_conv_reference(x,w,t,p);
    const int expected[]={16,24,16,24,36,24,16,24,16};
    for(unsigned c=0;c<2;++c)for(unsigned i=0;i<9;++i)assert(q[c*9+i]==expected[i]);
    std::cout<<"CHANNEL CONV PASS: signed partial sums, IC tail, OC order, spatial padding\n";
}
