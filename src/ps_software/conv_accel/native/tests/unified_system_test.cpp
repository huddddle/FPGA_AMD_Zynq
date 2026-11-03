#include "raw_system.hpp"
#include <iostream>
#include <stdexcept>
int main(){
    const std::string model="Embedfire Zynq7020 unified prefix3 hotspot56 INT8 fusion";
    const std::string bit(64,'a'),other(64,'b');
    if(!y26::raw_system_supports(model,bit,true,bit))throw std::runtime_error("matched unified system rejected");
    if(y26::raw_system_supports(model,bit,true,other))throw std::runtime_error("wrong bit accepted");
    if(y26::raw_system_supports(model,bit,true))throw std::runtime_error("unlocked unified system accepted");
    if(y26::raw_system_supports("Embedfire ZYNQ Board",bit,true,bit))throw std::runtime_error("factory accepted");
    if(y26::raw_system_supports(model,"bad",true,"bad"))throw std::runtime_error("invalid digest accepted");
    if(!y26::raw_system_supports("Embedfire Zynq7020 RGB three-layer INT8 fusion","5992eabc6da68537a9a89851f98547f7fd33e5e86d56f8ad7106ebabb05a73eb",true))throw std::runtime_error("legacy rejected");
    std::cout<<"UNIFIED SYSTEM GUARD PASS\n";
}
