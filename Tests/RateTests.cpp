#include "../Sources/RateSync.hpp"
#include <cassert>
#include <map>
#include <iostream>
int main() {
    using namespace patch;
    std::vector<RateDevice> d={{1,"UFX",96000,false,true,{}},{2,"ZED",48000,true,false,{{44100,96000}}}};
    d[1].syncLocked=false;
    int unlockedWrites=0;
    bool muted=false;
    try { applyRates(d,1,96000,[](uint32_t id){return id==1?96000.0:48000.0;},
        [&](uint32_t,double){++unlockedWrites;},[]{}); } catch(...) { muted=true; }
    assert(unlockedWrites==0 && muted); // Mismatched unlocked hardware must never be forced.
    applyRates(d,1,96000,[](uint32_t){return 96000.0;},
        [&](uint32_t,double){++unlockedWrites;},[]{});
    assert(unlockedWrites==0); // External digital synchronization needs no software write.
    d[1].syncLocked=true;
    auto p=ratePlan(d,1,96000); assert(p.size()==1 && p[0]==2);
    std::map<uint32_t,double> rates{{1,96000},{2,48000}};
    int writes=0,waits=0;
    applyRates(d,1,96000,[&](uint32_t id){return rates.at(id);},
        [&](uint32_t id,double rate){assert(id==2 && rate==96000);++writes;},
        [&]{if(++waits==3) rates[2]=96000;});
    assert(writes==1 && waits==3);
    d[1].rate=96000;d[1].writable=false;d[1].running=true;d[1].supported.clear();
    assert(ratePlan(d,1,96000).empty()); // Already-synced devices need no write permission.
    d[1].rate=48000;
    for(int mode=0;mode<3;++mode) {
        d[1].supported=mode==0?std::vector<std::pair<double,double>>{{44100,48000}}:std::vector<std::pair<double,double>>{{44100,96000}};
        d[1].writable=mode!=1;d[1].running=mode==2;
        bool failed=false; writes=0;
        try {applyRates(d,1,96000,[&](uint32_t id){return rates.at(id);},[&](uint32_t,double){++writes;},[]{});}
        catch(...) {failed=true;}
        assert(failed && writes==0);
    }
    d[1].running=false;d[1].writable=true;rates[2]=48000;waits=0;
    bool failed=false;
    try {applyRates(d,1,96000,[&](uint32_t id){return rates.at(id);},[](uint32_t,double){},[&]{++waits;});}
    catch(...) {failed=true;}
    assert(failed && waits==80);
    rates[1]=48000;writes=0;failed=false;
    try {applyRates(d,1,96000,[&](uint32_t id){return rates.at(id);},[&](uint32_t,double){++writes;},[]{});}
    catch(...) {failed=true;}
    assert(failed && writes==0);
    std::cout<<"PASS: master never written, asynchronous acknowledgement, no-op, unsupported/read-only/busy preflight, timeout and changing master\n";
}
