#pragma once
#include <cmath>
#include <cstdint>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

namespace patch {
struct RateDevice {
    uint32_t id;
    std::string name;
    double rate;
    bool writable, running;
    std::vector<std::pair<double,double>> supported;
    bool syncLocked = true;
};
inline bool sameRate(double a,double b) { return std::isfinite(a) && std::abs(a-b)<0.1; }
// Preflight the whole group before changing any device. Never write to the master.
inline std::vector<uint32_t> ratePlan(const std::vector<RateDevice>& devices,uint32_t master,double target) {
    bool found=false;
    std::vector<uint32_t> result;
    for(const auto& d:devices) {
        if(d.id==master) { found=true; if(!sameRate(d.rate,target)) throw std::runtime_error("The sync source changed sample rate. Try again."); continue; }
        if(!d.syncLocked || sameRate(d.rate,target)) continue;
        bool supported=false;
        for(auto r:d.supported) supported|=target>=r.first && target<=r.second;
        if(!supported) throw std::runtime_error(d.name+" does not support the sync source's sample rate.");
        if(!d.writable) throw std::runtime_error(d.name+" does not allow sample rate changes through Core Audio. Use the interface's control panel.");
        if(d.running) throw std::runtime_error(d.name+" is in use by an audio application. Stop audio there before changing the sample rate.");
        result.push_back(d.id);
    }
    if(!found) throw std::runtime_error("The sync source must be one of the selected interfaces.");
    return result;
}
inline void applyRates(const std::vector<RateDevice>& devices,uint32_t master,double target,
    const std::function<double(uint32_t)>& read,
    const std::function<void(uint32_t,double)>& write,
    const std::function<void()>& wait) {
    auto plan=ratePlan(devices,master,target);
    for(auto id:plan) {
        if(!sameRate(read(master),target)) throw std::runtime_error("The sync source changed sample rate during synchronization.");
        if(sameRate(read(id),target)) continue; // An externally clocked device may already have followed.
        write(id,target);
        bool matched=false;
        for(int attempt=0;attempt<80;++attempt) {
            if(sameRate(read(id),target)) { matched=true; break; }
            wait();
        }
        if(!matched) throw std::runtime_error("An interface did not confirm the sample rate change within two seconds.");
    }
    for(const auto& d:devices) if(!sameRate(read(d.id),target))
        throw std::runtime_error(d.name+" still reports the wrong sample rate. Routing was not started.");
}
}
