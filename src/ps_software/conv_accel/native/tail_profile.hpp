// Dispatcher-only NCNN timing. Optimized kernels and normal builds are unchanged.
#pragma once
#include "layer.h"
namespace y26_tail_profile {
struct Event {const ncnn::Layer* layer; double elapsed; int w,h,c,pack;};
static std::vector<Event> events;
static bool active=false;
static void start(){events.clear();events.reserve(512);active=true;}
static void stop(){active=false;}
static void write(std::ostream& f){
 f<<"[";
 for(unsigned i=0;i<events.size();++i){const auto& e=events[i];f<<(i?",":"")<<"{\"name\":\""<<e.layer->name<<"\",\"type\":\""<<e.layer->type<<"\",\"ms\":"<<e.elapsed<<",\"output\":["<<e.c*e.pack<<","<<e.h<<","<<e.w<<"]}";}
 f<<"]";
}
}
namespace ncnn {
void benchmark(const Layer* layer,double a,double b){if(y26_tail_profile::active)y26_tail_profile::events.push_back({layer,b-a,0,0,0,0});}
void benchmark(const Layer* layer,const Mat&,Mat& out,double a,double b){if(y26_tail_profile::active)y26_tail_profile::events.push_back({layer,b-a,out.w,out.h,out.c,out.elempack});}
}
