#pragma once
#include <cmath>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>
#include <utility>
namespace patch {
// Lossless numeric spelling understood by both existing and new drivers.
// Older drivers reserve three UTF-8 bytes per character in a 256-byte buffer.
inline std::string rateToken(double value) {
    std::ostringstream out; out << std::setprecision(17) << value;
    auto plain=out.str();
    if(std::isfinite(value) && value>=8000 && value<=384000 && std::floor(value)==value) {
        auto digits=std::to_string(static_cast<unsigned>(value));
        unsigned zeros=0;
        while(digits.back()=='0') { digits.pop_back(); ++zeros; }
        auto compact=digits+"e"+std::to_string(zeros);
        if(zeros && compact.size()<plain.size()) return compact;
    }
    return plain;
}
inline std::string encodeRateRanges(const std::vector<std::pair<double,double>>& ranges) {
    std::string result;
    for(const auto& r:ranges) {
        if(!result.empty()) result+=' ';
        result+=rateToken(r.first)+" "+rateToken(r.second);
    }
    return result;
}
}
