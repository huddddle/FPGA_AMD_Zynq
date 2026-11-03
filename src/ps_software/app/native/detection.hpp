#ifndef YOLO26_DETECTION_HPP
#define YOLO26_DETECTION_HPP

#include <net.h>
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <vector>

namespace yolo26 {
constexpr int kSize = 320;
constexpr int kClasses = 80;
constexpr int kCandidates = 2100;

struct Geometry {
    int width, height, resized_width, resized_height, left, top, size;
    double gain;
};

// Python round() uses ties-to-even for positive halfway values.
inline int round_even(double value) {
    const int base = static_cast<int>(std::floor(value));
    const double fraction = value - base;
    return base + (fraction > 0.5 || (fraction == 0.5 && (base & 1)));
}

inline Geometry geometry(int width, int height, int size=kSize) {
    if (width <= 0 || height <= 0 || size < 32 || size % 32)
        throw std::runtime_error("Invalid image dimensions or input size");
    Geometry g;
    g.width = width; g.height = height; g.size = size;
    g.gain = std::min(double(size) / width, double(size) / height);
    g.resized_width = round_even(width * g.gain);
    g.resized_height = round_even(height * g.gain);
    if (g.resized_width < 1 || g.resized_height < 1)
        throw std::runtime_error("Image aspect ratio too extreme for input size");
    g.left = (size - g.resized_width) / 2;
    g.top = (size - g.resized_height) / 2;
    return g;
}

struct Detection {
    float x1, y1, x2, y2, confidence;
    int class_id, candidate;
};

inline float iou(const Detection& a, const Detection& b) {
    const float intersection = std::max(0.f, std::min(a.x2,b.x2)-std::max(a.x1,b.x1)) *
                               std::max(0.f, std::min(a.y2,b.y2)-std::max(a.y1,b.y1));
    const float total = std::max(0.f,a.x2-a.x1)*std::max(0.f,a.y2-a.y1) +
                        std::max(0.f,b.x2-b.x1)*std::max(0.f,b.y2-b.y1) - intersection;
    return total > 0 ? intersection / total : 0.f;
}

inline std::vector<Detection> nms(std::vector<Detection> proposals, float threshold) {
    std::stable_sort(proposals.begin(), proposals.end(), [](const Detection& a, const Detection& b) {
        return a.confidence > b.confidence;
    });
    std::vector<Detection> kept;
    for (const auto& proposal : proposals) {
        bool suppress = false;
        for (const auto& previous : kept) {
            if (proposal.class_id == previous.class_id && iou(proposal, previous) > threshold) {
                suppress = true; break;
            }
        }
        if (!suppress) kept.push_back(proposal);
        if (kept.size() == 300) break;
    }
    return kept;
}

inline std::vector<Detection> postprocess(const ncnn::Mat& output, const Geometry& g, int classes=kClasses) {
    const int candidates = (g.size/8)*(g.size/8) + (g.size/16)*(g.size/16) + (g.size/32)*(g.size/32);
    if (classes < 1 || output.dims != 2 || output.w != candidates || output.h != 4+classes ||
        output.elempack != 1 || output.elemsize != sizeof(float))
        throw std::runtime_error("Expected FP32 decoded [4+classes,candidates]; check --size, --labels and model");
    for (int row = 0; row < output.h; ++row) {
        const float* values = output.row(row);
        for (int col = 0; col < output.w; ++col)
            if (!std::isfinite(values[col])) throw std::runtime_error("Non-finite model output");
    }
    std::vector<Detection> proposals;
    for (int i = 0; i < candidates; ++i) {
        int label = 0;
        float score = output.row(4)[i];
        for (int c = 1; c < classes; ++c) {
            if (output.row(4+c)[i] > score) { score = output.row(4+c)[i]; label = c; }
        }
        if (score <= 0.25f) continue;
        const float cx=output.row(0)[i], cy=output.row(1)[i];
        const float w=output.row(2)[i], h=output.row(3)[i];
        if (w < 0 || h < 0) throw std::runtime_error("Negative decoded box size");
        proposals.push_back({cx-w/2, cy-h/2, cx+w/2, cy+h/2, score, label, i});
    }
    auto detections = nms(proposals, 0.45f);
    // NMS occurs before clipping, matching the Python reference.
    for (auto& d : detections) {
        d.x1 = std::max(0.f,std::min(float(g.width),float((d.x1-g.left)/g.gain)));
        d.x2 = std::max(0.f,std::min(float(g.width),float((d.x2-g.left)/g.gain)));
        d.y1 = std::max(0.f,std::min(float(g.height),float((d.y1-g.top)/g.gain)));
        d.y2 = std::max(0.f,std::min(float(g.height),float((d.y2-g.top)/g.gain)));
    }
    return detections;
}

inline void self_test() {
    auto require=[](bool pass) { if (!pass) throw std::runtime_error("Postprocess self-test failed"); };
    require(round_even(2.5)==2 && round_even(3.5)==4);
    const auto portrait=geometry(810,1080), landscape=geometry(1080,810);
    require(portrait.left==40 && portrait.top==0 && landscape.left==0 && landscape.top==40);
    require(geometry(319,320).left==0);
    std::vector<Detection> boxes={{0,0,10,10,.9f,0,0},{0,0,10,10,.8f,0,1},
                                 {0,0,10,10,.7f,1,2},{20,20,30,30,.6f,0,3}};
    require(nms(boxes,.45f).size()==3 && nms({},.45f).empty());
    ncnn::Mat raw(kCandidates,84);
    raw.fill(0.f);
    require(postprocess(raw,portrait).empty());
    raw.row(0)[0]=160; raw.row(1)[0]=160; raw.row(2)[0]=1000; raw.row(3)[0]=1000;
    raw.row(4)[0]=.25f;
    require(postprocess(raw,portrait).empty());
    raw.row(4)[0]=.9f;
    const auto result=postprocess(raw,portrait);
    require(result.size()==1 && result[0].x1==0 && result[0].x2==810 && result[0].y2==1080);
    bool rejected=false;
    try { postprocess(ncnn::Mat(3,4),portrait); } catch (const std::runtime_error&) { rejected=true; }
    require(rejected);
}
} // namespace yolo26
#endif
