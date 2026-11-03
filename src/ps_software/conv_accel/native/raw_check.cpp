// Fixed, prepared RGB888 is the common timing boundary for ALL backends.
// The original NCNN graph/bin stay unchanged: input blob "2" skips the prefix.
#include "raw_frame.hpp"
#include <chrono>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
static std::string read(const std::string& p){std::ifstream f(p,std::ios::binary);if(!f)throw std::runtime_error("Cannot read "+p);return std::string(std::istreambuf_iterator<char>(f),{});}
static void dump(const std::string& p,const ncnn::Mat& m){
    if(m.elempack!=1||m.elemsize!=4u)throw std::runtime_error("Expected unpacked FP32 output");
    std::ofstream f(p,std::ios::binary);for(int c=0;c<m.c;++c){const float* v=m.channel(c);f.write(reinterpret_cast<const char*>(v),m.w*m.h*4);}
    if(!f)throw std::runtime_error("Output write failed");
}
int main(int argc,char** argv){
    try{
        std::map<std::string,std::string> a;
        const std::set<std::string> options={"--param","--bin","--rgb","--output-dir","--backend","--parameters","--device","--warmup","--runs","--layers","--export-requests"};
        for(int i=1;i<argc;++i){std::string k=argv[i];
            if(k=="--help"){std::cout<<"y26-raw-check --param model.param --bin model.bin --rgb input.rgb --output-dir existing_dir --backend baseline|reference|dma [--layers 2|3] [--parameters parameters.txt] [--device path] [--warmup 2] [--runs 7] [--no-capture]\n";return 0;}
            if(k=="--no-capture"){a[k]="1";continue;}
            if(!options.count(k)||i+1==argc)throw std::runtime_error("Unknown option/missing value: "+k);
            a[k]=argv[++i];
        }
        for(const char* n:{"--param","--bin","--rgb","--output-dir","--backend"})if(!a.count(n))throw std::runtime_error(std::string("Missing ")+n);
        const auto backend=a["--backend"];
        const int layers=a.count("--layers")?std::stoi(a["--layers"]):2;
        if(layers!=2&&layers!=3)throw std::runtime_error("Expected --layers 2 or 3");
        const std::string prefix_blob=layers==3?"3":"2",feature_name=layers==3?"third":"second";
        if(backend!="baseline"&&backend!="reference"&&backend!="dma")throw std::runtime_error("Invalid backend");
        int warmup=a.count("--warmup")?std::stoi(a["--warmup"]):0,runs=a.count("--runs")?std::stoi(a["--runs"]):1;
        if(warmup<0||warmup>5||runs<1||runs>20)throw std::runtime_error("Invalid warmup/runs");
        const auto rgb=read(a["--rgb"]);if(rgb.size()!=307200)throw std::runtime_error("Expected exactly 320x320 RGB888");
        const auto graph=read(a["--param"]);y26::adapt_two_layer_graph(graph); // Validate the exact prefix, without rewriting the graph.
        if(layers==3){
            std::istringstream rows(graph);std::string line;bool found=false;
            while(std::getline(rows,line)){
                std::istringstream row(line);std::string type,name;int ni,no;
                if(!(row>>type>>name)||name!="convrelu_2")continue;
                std::string in,out,item;row>>ni>>no>>in>>out;std::map<int,int> p;
                while(row>>item){auto eq=item.find('=');if(eq!=std::string::npos)p[std::stoi(item.substr(0,eq))]=std::stoi(item.substr(eq+1));}
                if(type!="Convolution"||ni!=1||no!=1||in!="2"||out!="3"||p[0]!=32||p[1]!=1||p[3]!=1||p[4]!=0||p[5]!=1||p[6]!=1024||p[9]!=1)throw std::runtime_error("Third-layer geometry/connectivity changed");
                found=true;
            }
            if(!found)throw std::runtime_error("Missing convrelu_2");
        }
        std::unique_ptr<y26::RawFrame> accelerator;
        if(backend!="baseline"){
            if(!a.count("--parameters"))throw std::runtime_error("Missing --parameters");
            auto parameters=y26::load_chain_parameters(a["--parameters"]);
            if((layers==3)!=(!parameters.third.empty()))throw std::runtime_error("Parameter file layer count mismatch");
            accelerator.reset(new y26::RawFrame(a["--bin"],parameters));
            if(a.count("--export-requests"))accelerator->export_requests(a["--export-requests"],reinterpret_cast<const std::uint8_t*>(rgb.data()));
        }
        ncnn::Net net;net.opt.num_threads=1;net.opt.use_packing_layout=true;net.opt.use_vulkan_compute=false;
        net.opt.use_fp16_packed=net.opt.use_fp16_storage=net.opt.use_fp16_arithmetic=net.opt.use_bf16_storage=false;
        if(net.load_param_mem(graph.c_str())||net.load_model(a["--bin"].c_str()))throw std::runtime_error("Model load failed");
        ncnn::Mat second,output;double sum=0;std::vector<std::string> samples;
        for(int run=0;run<warmup+runs;++run){
            auto ex=net.create_extractor();ex.set_light_mode(true);
            auto t0=std::chrono::steady_clock::now();
            if(backend=="baseline"){
                auto tensor=ncnn::Mat::from_pixels(reinterpret_cast<const unsigned char*>(rgb.data()),ncnn::Mat::PIXEL_RGB,320,320);
                const float norm[]={1/255.f,1/255.f,1/255.f};tensor.substract_mean_normalize(nullptr,norm);
                if(ex.input("in0",tensor)||ex.extract(prefix_blob.c_str(),second))throw std::runtime_error("Baseline prefix failed");
            }else{
                second=accelerator->run(reinterpret_cast<const std::uint8_t*>(rgb.data()),backend=="dma",a.count("--device")?a["--device"].c_str():"/dev/y26_dma_loopback",!a.count("--no-capture"));
                if(ex.input(prefix_blob.c_str(),second))throw std::runtime_error("Prefix feature injection failed");
            }
            auto t1=std::chrono::steady_clock::now();
            if(ex.extract("out0",output))throw std::runtime_error("Remaining network failed");
            auto t2=std::chrono::steady_clock::now();if(run<warmup)continue;
            double ms=std::chrono::duration<double,std::milli>(t2-t0).count();sum+=ms;
            y26::RawProfile blank;const auto& r=accelerator?accelerator->profile:blank;const auto& p=r.cpu;const auto& t=p.transfer;
            std::ostringstream s;s<<std::setprecision(12);
            s<<"{\"forward_ms\":"<<ms<<",\"subgraph_ms\":"<<std::chrono::duration<double,std::milli>(t1-t0).count()<<",\"remaining_ms\":"<<std::chrono::duration<double,std::milli>(t2-t1).count()
             <<",\"input_reorder_ms\":"<<p.input_quantize_ms<<",\"config_and_load_ms\":"<<p.fusion_config_ms<<",\"encode_ms\":"<<p.encode_ms<<",\"transfer_and_wait_ms\":"<<p.backend_ms<<",\"decode_ms\":"<<p.decode_ms<<",\"layout_and_compatibility_ms\":"<<p.restore_ms
             <<",\"ioctl_ms_nested\":"<<t.ioctl_ms<<",\"transactions\":"<<t.calls<<",\"tx_bytes\":"<<t.tx_bytes<<",\"rx_bytes\":"<<t.rx_bytes
             <<",\"pl_job_cycles_nested\":"<<r.job_cycles<<",\"conv0_cycles\":"<<r.conv0_cycles<<",\"conv1_cycles\":"<<r.conv1_cycles<<",\"conv2_cycles\":"<<r.conv2_cycles<<",\"feed_cycles\":"<<r.feed_cycles<<",\"fusion_cycles\":"<<r.fusion_cycles<<",\"input_fill_cycles\":"<<r.input_fill_cycles<<",\"output_stall_cycles_nested\":"<<r.output_stall_cycles<<'}';samples.push_back(s.str());
        }
        if(second.w!=80||second.h!=80||second.c!=32||output.w!=2100||output.h!=9)throw std::runtime_error("Output shape mismatch");
        dump(a["--output-dir"]+"/"+feature_name+".f32",second);dump(a["--output-dir"]+"/output.f32",output);
        if(accelerator&&!accelerator->captured.empty()){
            std::ofstream f(a["--output-dir"]+"/"+feature_name+".i8",std::ios::binary);f.write(reinterpret_cast<const char*>(accelerator->captured.data()),accelerator->captured.size());if(!f)throw std::runtime_error("INT8 write failed");
        }
        std::ofstream f(a["--output-dir"]+"/report.json");f<<std::setprecision(12)<<"{\"backend\":\""<<backend<<"\",\"layers\":"<<layers<<",\"timing_start\":\"prepared_320x320_RGB888\",\"packing\":true,\"lightmode\":true,\"threads\":1,\"warmup_runs\":"<<warmup<<",\"measured_runs\":"<<runs<<",\"forward_ms\":"<<sum/runs<<",\"samples\":[";
        for(unsigned i=0;i<samples.size();++i)f<<(i?",":"")<<samples[i];
        f<<"]}\n";if(!f)throw std::runtime_error("Report write failed");
        std::cout<<"RAW FRAME MODEL PASS backend="<<backend<<" shape=32x80x80 forward_ms="<<sum/runs<<'\n';
    }catch(const std::exception& e){std::cerr<<"ERROR: "<<e.what()<<'\n';return 1;}
}
