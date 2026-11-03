#include "resident_prefix.hpp"
#include "net.h"
#include <chrono>
#include <fstream>
#include <iostream>
#include <iomanip>
#include <map>
#include <iterator>
#include <stdexcept>
int main(int argc,char** argv){try{
 std::map<std::string,std::string>a;for(int i=1;i<argc;i+=2){if(i+1>=argc)throw std::runtime_error("Option value");a[argv[i]]=argv[i+1];}
 std::ifstream f(a.at("--rgb"),std::ios::binary);std::vector<unsigned char>rgb(std::istreambuf_iterator<char>(f),{});if(rgb.size()!=307200)throw std::runtime_error("RGB320");
 ncnn::Net net;net.opt.num_threads=1;net.opt.use_packing_layout=true;net.opt.use_vulkan_compute=false;net.opt.use_fp16_packed=net.opt.use_fp16_storage=net.opt.use_fp16_arithmetic=net.opt.use_bf16_storage=false;
 if(net.load_param(a.at("--param").c_str())||net.load_model(a.at("--bin").c_str()))throw std::runtime_error("NCNN model");
 const auto mode=a.at("--backend");if(mode!="cpu"&&mode!="pl21"&&mode!="pl30")throw std::runtime_error("Backend");
 std::unique_ptr<y26::ResidentPrefix>pl;if(mode!="cpu")pl.reset(new y26::ResidentPrefix(a.at("--package"),mode=="pl30"));
 ncnn::Mat out;int warm=std::stoi(a.at("--warmup")),runs=std::stoi(a.at("--runs"));double total=0;std::vector<double>ts;
 for(int i=0;i<warm+runs;++i){auto t=std::chrono::steady_clock::now();
  if(pl)out=pl->run(net,rgb,"/dev/y26_dma_loopback",a.count("--capture")==0||a.at("--capture")=="1");else{auto ex=net.create_extractor();ex.set_light_mode(true);auto image=ncnn::Mat::from_pixels(rgb.data(),ncnn::Mat::PIXEL_RGB,320,320);float norm[]={1/255.f,1/255.f,1/255.f};image.substract_mean_normalize(nullptr,norm);if(ex.input("in0",image)||ex.extract("out0",out))throw std::runtime_error("CPU inference");}
  double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-t).count();if(i>=warm){ts.push_back(ms);total+=ms;}
 }
 const auto d=a.at("--output-dir");ncnn::Mat plain;ncnn::convert_packing(out,plain,1);std::ofstream output(d+"/output.f32",std::ios::binary);output.write(static_cast<const char*>(plain.data),plain.w*plain.h*4);if(!output)throw std::runtime_error("Output file");if(pl&&(a.count("--capture")==0||a.at("--capture")=="1"))pl->save(d);
 std::ofstream report(d+"/report.json");report<<std::setprecision(12)<<"{\"backend\":\""<<mode<<"\",\"warmup\":"<<warm<<",\"runs\":"<<runs<<",\"forward_ms\":"<<total/runs<<",\"samples_ms\":[";for(unsigned i=0;i<ts.size();++i)report<<(i?",":"")<<ts[i];report<<"]";if(pl)report<<",\"prefix_ms\":"<<pl->prefix_ms<<",\"tail_ms\":"<<pl->remaining_ms<<",\"profile\":"<<pl->profile_json;report<<"}\n";std::cout<<"CONTINUOUS30 CHECK PASS "<<mode<<'\n';return 0;
}catch(const std::exception&e){std::cerr<<"ERROR: "<<e.what()<<'\n';return 1;}}
