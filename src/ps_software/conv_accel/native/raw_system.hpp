#pragma once
#include <string>
namespace y26 {
// The verified third-layer system implements both protocol pairs. Never accept
// a model-name-only match, a factory DT, or three-layer commands on two-layer PL.
inline bool unified_system_supports(const std::string& model,const std::string& bit,const std::string& expected){
    if(model!="Embedfire Zynq7020 unified prefix3 hotspot56 INT8 fusion" || expected.size()!=64 || bit!=expected)return false;
    for(char c:expected)if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return false;
    return true;
}
inline bool raw_system_supports(const std::string& model,const std::string& bit,bool three,const std::string& expected=""){
    if(unified_system_supports(model,bit,expected))return true;
    if(model=="Embedfire Zynq7020 RGB three-layer INT8 fusion")
        return bit=="5992eabc6da68537a9a89851f98547f7fd33e5e86d56f8ad7106ebabb05a73eb";
    return !three && model=="Embedfire Zynq7020 RGB frame INT8 fusion" &&
        bit=="1a4a2004dae11b53eddd1c9ff14a7b8abc70d588376abf53bd3ba617041c91a4";
}
}
