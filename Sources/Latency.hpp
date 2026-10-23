#pragma once
#include <cmath>
#include <cstdint>

namespace patch {
constexpr uint32_t TimingProperty = 0x7370746d; // sptm: generation and capture delay
constexpr uint32_t LatencyProperty = 0x73706c74; // splt: generation-bound report
constexpr uint32_t TimingChannels = 2;
constexpr double TimingPeriod = 1048576.0;

// Complementary ramps survive linear sample-rate conversion. Silence is invalid.
// Avoid wrap neighbourhoods, where the resampler's filter sees a discontinuity.
inline void encodeTiming(double frame, float& a, float& b) {
    double phase=std::fmod(frame,TimingPeriod);
    if(phase<0)phase+=TimingPeriod;
    a=float(phase/TimingPeriod); b=1.0f-a;
}
inline bool decodeTiming(float a,float b,double nearFrame,double& frame) {
    if(!std::isfinite(a) || !std::isfinite(b) || std::abs(double(a)+b-1)>0.00001 ||
        a<0.001 || a>0.999) return false;
    const double phase=double(a)*TimingPeriod;
    frame=phase+std::round((nearFrame-phase)/TimingPeriod)*TimingPeriod;
    return true;
}
inline bool timingDelay(double destination,double source,double& delay) {
    delay=destination-source;
    return std::isfinite(delay) && delay>=0 && delay<65536;
}
}
