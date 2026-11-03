// FP32 YOLO26n application for Linux ARM32; configurable square size and labels.
// Read main() in order: arguments -> decode -> preprocess -> infer -> NMS -> save.
#include "detection.hpp"
#include "raw_frame.hpp"
#include "resident_prefix.hpp"
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_ONLY_PNM
#define STBI_MAX_DIMENSIONS 8192
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include <cerrno>
#include <chrono>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <numeric>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <sys/resource.h>
#include <unistd.h>
#include <fcntl.h>

using Clock=std::chrono::steady_clock;
static double elapsed(Clock::time_point begin) {
    return std::chrono::duration<double,std::milli>(Clock::now()-begin).count();
}
static void check(bool ok,const std::string& message) {
    if (!ok) throw std::runtime_error(message);
}
static std::string quote(const std::string& value) {
    std::ostringstream out; out << '"';
    for (unsigned char c : value) {
        if (c=='"' || c=='\\') out << '\\' << c;
        else if (c<32) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << int(c) << std::dec;
        else out << c;
    }
    out << '"'; return out.str();
}
static const char* names[] = {
    "person","bicycle","car","motorcycle","airplane","bus","train","truck","boat","traffic light",
    "fire hydrant","stop sign","parking meter","bench","bird","cat","dog","horse","sheep","cow",
    "elephant","bear","zebra","giraffe","backpack","umbrella","handbag","tie","suitcase","frisbee",
    "skis","snowboard","sports ball","kite","baseball bat","baseball glove","skateboard","surfboard","tennis racket","bottle",
    "wine glass","cup","fork","knife","spoon","bowl","banana","apple","sandwich","orange",
    "broccoli","carrot","hot dog","pizza","donut","cake","chair","couch","potted plant","bed",
    "dining table","toilet","tv","laptop","mouse","remote","keyboard","cell phone","microwave","oven",
    "toaster","sink","refrigerator","book","clock","vase","scissors","teddy bear","hair drier","toothbrush"
};
struct Args {
    std::string param="model.ncnn.param", bin="model.ncnn.bin", image;
    std::string root="InferenceResult", context="unspecified", input, labels;
    std::string backend="cpu", parameters, device="/dev/y26_dma_loopback";
    int runs=1, warmup=0, size=320;
    bool dump=false, check_runtime=false, hardware_only=false;
};
static int number(const std::string& text) {
    size_t count=0; const int value=std::stoi(text,&count);
    check(count==text.size(),"Invalid integer: "+text); return value;
}
static Args parse(int argc,char** argv) {
    Args a;
    for (int i=1;i<argc;++i) {
        const std::string key=argv[i];
        if (key=="--dump-tensors") { a.dump=true; continue; }
        if (key=="--check-runtime") { a.check_runtime=true; continue; }
        if (key=="--hardware-only") { a.hardware_only=true; continue; }
        check(i+1<argc,"Missing value for "+key);
        const std::string value=argv[++i];
        if (key=="--param") a.param=value;
        else if (key=="--bin") a.bin=value;
        else if (key=="--image") a.image=value;
        else if (key=="--output-root") a.root=value;
        else if (key=="--context") a.context=value;
        else if (key=="--input-f32") a.input=value;
        else if (key=="--labels") a.labels=value;
        else if (key=="--size") a.size=number(value);
        else if (key=="--runs") a.runs=number(value);
        else if (key=="--warmup") a.warmup=number(value);
        else if (key=="--backend") a.backend=value;
        else if (key=="--parameters") a.parameters=value;
        else if (key=="--device") a.device=value;
        else throw std::runtime_error("Unknown argument: "+key);
    }
    check(a.backend=="cpu" || a.backend=="pl3" || a.backend=="reference3" || a.backend=="pl21" || a.backend=="pl30","Invalid --backend");
    if(a.check_runtime) return a;
    check(!a.image.empty(),"--image is required");
    if(a.backend!="cpu") check(a.size==320 && !a.parameters.empty(),"PL backend requires --size 320 and calibrated --parameters");
    check(a.size>=32 && a.size%32==0,"--size must be a positive multiple of 32");
    check(a.runs>=1 && a.runs<=1000 && a.warmup>=0 && a.warmup<=100,"Invalid run counts");
    check(a.context=="unspecified" || a.context=="board" || a.context=="qemu" || a.context=="host", "Invalid --context");
    return a;
}
static void ensure_directory(const std::string& path) {
    struct stat st;
    if (stat(path.c_str(),&st)==0) { check(S_ISDIR(st.st_mode),"Not a directory: "+path); return; }
    check(errno==ENOENT,"Cannot stat output directory: "+path);
    check(mkdir(path.c_str(),0755)==0,"Cannot create output root (parent must exist): "+path);
}
static std::string create_run(const Args& args) {
    ensure_directory(args.root);
    const auto stamp=std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    const std::string stem=args.root+"/"+args.context+"_"+std::to_string(stamp)+"_"+std::to_string(getpid());
    for (int attempt=0;attempt<100;++attempt) {
        const std::string path=stem+"_"+std::to_string(attempt);
        if (mkdir(path.c_str(),0755)==0) return path;
        check(errno==EEXIST,"Cannot create run directory: "+path);
    }
    throw std::runtime_error("Output directory collision");
}
static void write_text(const std::string& path,const std::string& value) {
    std::ofstream file(path); check(bool(file),"Cannot open output: "+path);
    file << value; file.close(); check(bool(file),"Cannot finish writing: "+path);
}
static void write_tensor(const std::string& path,const ncnn::Mat& value) {
    std::ofstream file(path,std::ios::binary); check(bool(file),"Cannot open tensor: "+path);
    if (value.dims==3) {
        for(int c=0;c<value.c;++c) {
            const float* p=value.channel(c);
            file.write(reinterpret_cast<const char*>(p),value.w*value.h*sizeof(float));
        }
    } else {
        for(int y=0;y<value.h;++y)
            file.write(reinterpret_cast<const char*>(value.row(y)),value.w*sizeof(float));
    }
    file.close(); check(bool(file),"Cannot finish tensor: "+path);
}
static ncnn::Mat preprocess(const unsigned char* rgb,const yolo26::Geometry& g,std::vector<unsigned char>* prepared=nullptr) {
    ncnn::Mat resized=ncnn::Mat::from_pixels_resize(rgb,ncnn::Mat::PIXEL_RGB,
        g.width,g.height,g.resized_width,g.resized_height);
    check(!resized.empty(),"Resize allocation failed");
    ncnn::Mat input;
    ncnn::copy_make_border(resized,input,g.top,g.size-g.resized_height-g.top,
                          g.left,g.size-g.resized_width-g.left,ncnn::BORDER_CONSTANT,114.f);
    check(!input.empty(),"Input allocation failed");
    if(prepared){prepared->resize(size_t(g.size)*g.size*3);input.to_pixels(prepared->data(),ncnn::Mat::PIXEL_RGB);}
    const float norm[3]={1.f/255,1.f/255,1.f/255};
    input.substract_mean_normalize(nullptr,norm);
    return input;
}
static void read_input(const std::string& path,ncnn::Mat& input) {
    std::ifstream file(path,std::ios::binary|std::ios::ate);
    check(bool(file),"Cannot open --input-f32");
    const size_t plane=size_t(input.w)*input.h;
    check(file.tellg()==std::streamoff(3*plane*sizeof(float)),
          "Input tensor must be exactly "+std::to_string(3*plane*sizeof(float))+" bytes");
    file.seekg(0);
    for(int c=0;c<3;++c) {
        float* p=input.channel(c);
        file.read(reinterpret_cast<char*>(p),plane*sizeof(float));
        for(size_t j=0;j<plane;++j) check(std::isfinite(p[j]) && p[j]>=0 && p[j]<=1,"Input values must be finite in [0,1]");
    }
    check(bool(file),"Input tensor read failed");
}
static ncnn::Mat infer(ncnn::Net& net,const ncnn::Mat& input,y26::RawFrame* accelerator,
                       const std::vector<unsigned char>& rgb,const Args& args,double& prefix_ms,double& remaining_ms,y26::ResidentPrefix* deep=nullptr) {
    if(deep){auto result=deep->run(net,rgb,args.device.c_str(),args.dump);prefix_ms=deep->prefix_ms;remaining_ms=deep->remaining_ms;return result;}
    ncnn::Extractor ex=net.create_extractor();
    ex.set_light_mode(true);
    auto begin=Clock::now();
    if(accelerator){
        auto third=accelerator->run(rgb.data(),args.backend=="pl3",args.device.c_str(),false);
        check(ex.input("3",third)==0,"NCNN third feature injection failed");
        prefix_ms=elapsed(begin);begin=Clock::now();
    }else check(ex.input("in0",input)==0,"NCNN input failed");
    ncnn::Mat output;
    check(ex.extract("out0",output)==0 && !output.empty(),"NCNN output failed");
    remaining_ms=elapsed(begin);
    return output;
}
static void draw(std::vector<unsigned char>& image,int w,int h,const std::vector<yolo26::Detection>& boxes) {
    for (const auto& d : boxes) {
        const int x1=std::max(0,std::min(w-1,int(std::floor(d.x1))));
        const int x2=std::max(0,std::min(w-1,int(std::ceil(d.x2))));
        const int y1=std::max(0,std::min(h-1,int(std::floor(d.y1))));
        const int y2=std::max(0,std::min(h-1,int(std::ceil(d.y2))));
        const unsigned char color[3]={static_cast<unsigned char>(64+(d.class_id*67)%192),
                                     static_cast<unsigned char>(64+(d.class_id*113+83)%192),240};
        for(int y=y1;y<=y2;++y) for(int x=x1;x<=x2;++x) {
            if(x-x1<3 || x2-x<3 || y-y1<3 || y2-y<3)
                std::copy(color,color+3,&image[(size_t(y)*w+x)*3]);
        }
    }
}

int main(int argc,char** argv) {
    try {
        if(argc==2 && std::string(argv[1])=="--self-test") {
            yolo26::self_test(); std::cout << "Postprocess self-test OK\n"; return 0;
        }
        if(argc==2 && std::string(argv[1])=="--help") {
            std::cout << "yolo26_detect --image IMAGE [--param PARAM --bin BIN --output-root InferenceResult]\n"
                         "  [--size 320 --labels labels.txt]  # labels omitted: COCO 80 classes\n"
                         "  [--runs 1 --warmup 0 --dump-tensors --context board|qemu|host|unspecified]\n"
                         "  [--backend cpu|pl3|reference3|pl21|pl30 --parameters FILE_OR_PL21_DIRECTORY --device /dev/y26_dma_loopback]\n"
                         "  --check-runtime --backend pl21 [--hardware-only]  # matched bit/DT/device check; no DMA\n"
                         "  [--input-f32 CHW_FLOAT32_FILE]  # diagnostic input override, not normal image inference\n"
                         "  --self-test  # synthetic postprocess tests; no model required\n";
            return 0;
        }
        const Args args=parse(argc,argv);
        if(args.check_runtime){
            check(args.backend=="pl3"||args.backend=="pl21"||args.backend=="pl30","--check-runtime requires PL backend");
            if(args.backend=="pl30")y26::ResidentPrefix::validate_continuous_system(args.parameters);else if(args.backend=="pl21")y26::ResidentPrefix::validate_system();else y26::validate_raw_system(true);
            if(args.hardware_only){std::cout<<"HARDWARE READY (read-only; no DMA)\n";return 0;}
            const int fd=open(args.device.c_str(),O_RDWR|O_CLOEXEC);
            check(fd>=0,"DMA device not available (load matched client first)");close(fd);
            std::cout<<args.backend<<" RUNTIME READY (read-only; no DMA)\n";return 0;
        }
        std::vector<std::string> class_names(std::begin(names),std::end(names));
        if(!args.labels.empty()) {
            std::ifstream labels(args.labels);
            check(bool(labels),"Cannot open --labels: "+args.labels);
            class_names.clear();
            std::string name;
            while(std::getline(labels,name)) {
                if(!name.empty() && name.back()=='\r') name.pop_back();
                check(!name.empty(),"Empty class name in --labels");
                class_names.push_back(name);
            }
            check(!class_names.empty(),"--labels contains no class names");
        }
        for(const auto& path : {args.param,args.bin,args.image}) {
            std::ifstream f(path,std::ios::binary); check(bool(f),"Missing or unreadable input: "+path);
        }
        const auto total_begin=Clock::now();
        auto begin=Clock::now();
        int width=0,height=0,channels=0;
        check(stbi_info(args.image.c_str(),&width,&height,&channels)!=0,"Unsupported or corrupt image");
        check(width>0 && height>0 && size_t(width)*height<=16000000,"Image exceeds 16 megapixel limit");
        std::unique_ptr<unsigned char,void(*)(void*)> pixels(stbi_load(args.image.c_str(),&width,&height,&channels,3),stbi_image_free);
        check(bool(pixels),"Image decode failed");
        const double decode_ms=elapsed(begin);
        begin=Clock::now();
        const auto geometry=yolo26::geometry(width,height,args.size);
        std::vector<unsigned char> prepared_rgb;
        ncnn::Mat input=preprocess(pixels.get(),geometry,args.backend!="cpu"?&prepared_rgb:nullptr);
        if(!args.input.empty()) read_input(args.input,input);
        if(args.backend!="cpu"&&!args.input.empty()){
            prepared_rgb.resize(320*320*3);
            for(int c=0;c<3;++c){const float* q=input.channel(c);for(int i=0;i<320*320;++i)
                prepared_rgb[i*3+c]=static_cast<unsigned char>(std::max(0,std::min(255,int(std::nearbyint(double(q[i])*255.)))));}
        }
        const double preprocess_ms=elapsed(begin);
        begin=Clock::now();
        ncnn::Net net;
        net.opt.num_threads=1;
        net.opt.use_packing_layout=true;
        net.opt.use_vulkan_compute=false;
        net.opt.use_fp16_packed=false; net.opt.use_fp16_storage=false;
        net.opt.use_fp16_arithmetic=false; net.opt.use_bf16_storage=false;
        check(net.load_param(args.param.c_str())==0 && net.load_model(args.bin.c_str())==0,"NCNN load failed");
        std::unique_ptr<y26::RawFrame> accelerator;
        std::unique_ptr<y26::ResidentPrefix> deep;
        if(args.backend=="pl21"||args.backend=="pl30")deep.reset(new y26::ResidentPrefix(args.parameters,args.backend=="pl30"));
        else if(args.backend!="cpu"){
            auto p=y26::load_chain_parameters(args.parameters);
            check(p.third.size()==32,"Expected three-layer parameters");
            accelerator.reset(new y26::RawFrame(args.bin,p));
        }
        const double load_ms=elapsed(begin);
        double prefix_ms=0,remaining_ms=0,prefix_sum=0,remaining_sum=0;
        for(int i=0;i<args.warmup;++i) infer(net,input,accelerator.get(),prepared_rgb,args,prefix_ms,remaining_ms,deep.get());
        std::vector<double> times;
        ncnn::Mat output;
        for(int i=0;i<args.runs;++i) {
            begin=Clock::now(); output=infer(net,input,accelerator.get(),prepared_rgb,args,prefix_ms,remaining_ms,deep.get()); times.push_back(elapsed(begin));
            prefix_sum+=prefix_ms;remaining_sum+=remaining_ms;
        }
        begin=Clock::now();
        const auto boxes=yolo26::postprocess(output,geometry,int(class_names.size()));
        const double post_ms=elapsed(begin);
        const double total_compute_ms=elapsed(total_begin);
        const double mean=std::accumulate(times.begin(),times.end(),0.0)/times.size();
        struct rusage usage={}; check(getrusage(RUSAGE_SELF,&usage)==0,"getrusage failed");
        // Output is created only after inference succeeds. report.json is the completion marker.
        const std::string directory=create_run(args);
        begin=Clock::now();
        if(args.dump) { write_tensor(directory+"/input.f32",input); write_tensor(directory+"/output.f32",output); }
        if(args.dump&&deep)deep->save(directory);
        std::ostringstream records; records << std::setprecision(9) << "[\n";
        for(size_t i=0;i<boxes.size();++i) {
            const auto& d=boxes[i];
            records << "  {\"class_id\":" << d.class_id << ",\"class_name\":" << quote(class_names[d.class_id])
                    << ",\"confidence\":" << d.confidence << ",\"xyxy\":[" << d.x1 << ',' << d.y1 << ',' << d.x2 << ',' << d.y2
                    << "],\"candidate_index\":" << d.candidate << '}' << (i+1<boxes.size()?",":"") << '\n';
            std::cout << class_names[d.class_id] << " score=" << d.confidence << " box=" << d.x1 << ',' << d.y1 << ',' << d.x2 << ',' << d.y2 << '\n';
        }
        records << "]\n"; write_text(directory+"/detections.json",records.str());
        std::vector<unsigned char> annotated(pixels.get(),pixels.get()+size_t(width)*height*3);
        draw(annotated,width,height,boxes);
        check(stbi_write_png((directory+"/annotated.png").c_str(),width,height,3,annotated.data(),width*3)!=0,"PNG write failed");
        const double save_ms=elapsed(begin);
        std::ostringstream report; report << std::setprecision(12);
        report << "{\n  \"completed\":true,\n  \"execution_context\":" << quote(args.context)
               << ",\n  \"image\":" << quote(args.image) << ",\n  \"param\":" << quote(args.param) << ",\n  \"bin\":" << quote(args.bin)
               << ",\n  \"original_wh\":[" << width << ',' << height << "],\n  \"input_chw\":[3," << args.size << ',' << args.size
               << "],\n  \"output_shape\":[" << output.h << ',' << output.w << "],\n  \"num_classes\":" << class_names.size()
               << ",\n  \"labels\":" << quote(args.labels) << ','
               << "\n  \"preprocess\":{\"decoder\":\"stb RGB (no EXIF auto-rotation)\",\"resize\":\"NCNN uint8 bilinear\",\"fill\":114,\"normalization\":\"RGB/255\",\"gain\":" << geometry.gain
               << ",\"resized_wh\":[" << geometry.resized_width << ',' << geometry.resized_height << "],\"pad_left_top\":[" << geometry.left << ',' << geometry.top << "]},"
               << "\n  \"input_override\":" << quote(args.input) << ",\n  \"dump_tensors\":" << (args.dump?"true":"false")
               << ",\n  \"postprocess\":{\"confidence\":0.25,\"nms_iou\":0.45,\"class_aware\":true,\"max_det\":300},"
               << "\n  \"detections\":" << boxes.size() << ",\n  \"num_threads\":1,\n  \"openmp_enabled\":false,\n  \"pl_acceleration\":" << ((args.backend=="pl3"||deep)?"true":"false") << ','
               << "\n  \"backend\":" << quote(args.backend) << ','
               << "\n  \"warmup_runs\":" << args.warmup << ",\n  \"measured_runs\":" << args.runs
               << ",\n  \"timing_ms\":{\"decode\":" << decode_ms << ",\"preprocess\":" << preprocess_ms << ",\"model_load\":" << load_ms
               << ",\"inference_mean\":" << mean << ",\"inference_min\":" << *std::min_element(times.begin(),times.end())
               << ",\"inference_max\":" << *std::max_element(times.begin(),times.end()) << ",\"postprocess\":" << post_ms
               << ",\"total_before_save\":" << total_compute_ms << ",\"save_excluding_report\":" << save_ms;
        if(accelerator||deep)report<<",\"prefix_mean\":"<<prefix_sum/args.runs<<",\"remaining_mean\":"<<remaining_sum/args.runs;
        report<<"},";
        if(deep){
            report<<"\n  \""<<(args.backend=="pl30"?"pl30_profile":"pl21_profile")<<"\":"<<deep->profile_json<<",\n  \"accelerated_layers\":[";
            for(int i=0;i<(args.backend=="pl30"?31:22);++i)report<<(i?",":"")<<quote("convrelu_"+std::to_string(i));
            if(args.backend=="pl30")report<<"],\n  \"resident_subgraphs\":[[0,30]],\n  \"ddr_boundaries_after\":[],";
            else report<<"],\n  \"resident_subgraphs\":[[0,6],[7,11],[12,21]],\n  \"ddr_boundaries_after\":[6,11],";
        }
        if(accelerator){
            const auto& r=accelerator->profile;const auto& p=r.cpu;
            report<<"\n  \"prefix_profile\":{\"config_and_load_ms\":"<<p.fusion_config_ms<<",\"encode_ms\":"<<p.encode_ms
                  <<",\"transfer_and_wait_ms\":"<<p.backend_ms<<",\"decode_ms\":"<<p.decode_ms<<",\"layout_and_compatibility_ms\":"<<p.restore_ms
                  <<",\"transactions\":"<<p.transfer.calls<<",\"tx_bytes\":"<<p.transfer.tx_bytes<<",\"rx_bytes\":"<<p.transfer.rx_bytes
                  <<",\"pl_job_cycles_nested\":"<<r.job_cycles<<",\"conv0_cycles\":"<<r.conv0_cycles<<",\"conv1_cycles\":"<<r.conv1_cycles
                  <<",\"conv2_cycles\":"<<r.conv2_cycles<<",\"sample\":\"last measured run\"},";
        }
        report << "\n  \"process_peak_rss_kib_before_save\":" << usage.ru_maxrss
               << ",\n  \"notes\":\"RSS is process high-water memory, not peak live activations. QEMU timing/RSS is not board performance. Total includes load and all warmup/measured runs. PNG has boxes only; class names/confidence are in JSON. Requires decoded one-to-many FP32 YOLO26n output.\"\n}\n";
        write_text(directory+"/report.json",report.str());
        std::cout << "Inference mean (ms): " << mean << "\nRESULT_DIR=" << directory << '\n';
        return 0;
    } catch(const std::exception& e) {
        std::cerr << "ERROR: " << e.what() << '\n'; return 1;
    }
}
