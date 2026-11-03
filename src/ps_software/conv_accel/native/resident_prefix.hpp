#pragma once
#include "net.h"
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
namespace y26 {
// Image-facing adapter for the accepted 0..6, 7..11 and 12..21 task sequence.
class ResidentPrefix {
 struct Impl;std::unique_ptr<Impl> impl;
public:
 double prefix_ms=0,remaining_ms=0;
 std::string profile_json;
 explicit ResidentPrefix(const std::string& directory,bool continuous30=false);
 ~ResidentPrefix();
 ncnn::Mat run(ncnn::Net& net,const std::vector<unsigned char>& rgb,const char* device,bool capture=false);
 void save(const std::string& directory)const;
 static void validate_system(const std::string& directory="");
 static void validate_continuous_system(const std::string& directory);
};
}
