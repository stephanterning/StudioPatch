#pragma once
#include <cmath>

namespace patch {
inline bool sameRate(double a,double b) { return std::isfinite(a) && std::abs(a-b)<0.1; }
}
