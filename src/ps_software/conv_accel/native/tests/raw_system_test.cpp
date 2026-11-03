#include "raw_system.hpp"
#include <cassert>
#include <iostream>
int main(){
    const std::string two="Embedfire Zynq7020 RGB frame INT8 fusion",three="Embedfire Zynq7020 RGB three-layer INT8 fusion";
    const std::string b2="1a4a2004dae11b53eddd1c9ff14a7b8abc70d588376abf53bd3ba617041c91a4",b3="5992eabc6da68537a9a89851f98547f7fd33e5e86d56f8ad7106ebabb05a73eb";
    assert(y26::raw_system_supports(two,b2,false));
    assert(!y26::raw_system_supports(two,b2,true));
    assert(y26::raw_system_supports(three,b3,false));
    assert(y26::raw_system_supports(three,b3,true));
    assert(!y26::raw_system_supports(three,b2,false));
    assert(!y26::raw_system_supports(two,b3,false));
    assert(!y26::raw_system_supports("factory",b3,true));
    assert(!y26::raw_system_supports(three,"",false));
    std::cout<<"RAW SYSTEM CONTRACT PASS 8 cases\n";
}
