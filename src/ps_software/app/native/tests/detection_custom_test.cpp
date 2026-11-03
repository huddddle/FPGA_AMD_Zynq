// Public postprocess contract: custom classes, 640 input, last output candidate.
#include "../detection.hpp"
#include <iostream>

int main() {
    try {
        yolo26::self_test();
        const auto g = yolo26::geometry(1280, 640, 640);
        if (g.left != 0 || g.top != 160 || g.gain != .5)
            throw std::runtime_error("640 letterbox geometry mismatch");
        ncnn::Mat raw(8400, 9); // decoded xywh + five class scores
        raw.fill(0.f);
        raw.row(0)[8399] = 320;
        raw.row(1)[8399] = 320;
        raw.row(2)[8399] = 100;
        raw.row(3)[8399] = 80;
        raw.row(8)[8399] = .9f; // fifth class, not COCO class names
        const auto boxes = yolo26::postprocess(raw, g, 5);
        if (boxes.size() != 1 || boxes[0].class_id != 4 ||
            boxes[0].candidate != 8399 || boxes[0].x1 != 540 ||
            boxes[0].y1 != 240 || boxes[0].x2 != 740 || boxes[0].y2 != 400)
            throw std::runtime_error("Custom model postprocess mismatch");
        std::cout << "PASS: legacy 320/80 and custom 640/5 postprocess\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
