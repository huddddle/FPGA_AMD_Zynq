#include "two_layer.hpp"
#include <cassert>
#include <iostream>
#include <stdexcept>
int main(){
    std::string graph="7767517\n4 4\nInput in0 0 1 in0\n"
        "Convolution convrelu_0 1 1 in0 1 0=16 1=3 2=1 3=2 4=1 5=1 6=432 9=1\n"
        "Convolution convrelu_1 1 1 1 2 0=32 1=3 2=1 3=2 4=1 5=1 6=4608 9=1\n"
        "Convolution convrelu_2 1 1 2 out0 0=1 1=1 6=32\n";
    auto actual=y26::adapt_two_layer_graph(graph);
    assert(actual.find("\n3 3\n")!=std::string::npos);
    assert(actual.find("Y26TwoConv convrelu_0_1 1 1 in0 2")!=std::string::npos);
    assert(actual.find("Convolution convrelu_1 ")==std::string::npos);
    auto branch=graph;branch.replace(branch.find("1 1 2 out0"),10,"1 1 1 out0");
    bool rejected=false;try{y26::adapt_two_layer_graph(branch);}catch(const std::exception&){rejected=true;}
    assert(rejected);
    auto wrong=graph;wrong.replace(wrong.find("6=4608"),6,"6=4609");
    rejected=false;try{y26::adapt_two_layer_graph(wrong);}catch(const std::exception&){rejected=true;}
    assert(rejected);
    std::cout<<"TWO LAYER GRAPH PASS: blob remapping, original graph retained, branches rejected\n";
}
