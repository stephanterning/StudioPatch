#include "../Sources/RuntimePolicy.hpp"
#include <cassert>
#include <limits>
int main() {
    patch::RuntimePolicy p;
    assert(!p.mayRoute());
    auto a=p.request(96000);
    assert(!p.mayRoute());
    assert(!p.complete(a,{96000,48000}));
    assert(!p.complete(a,{}));
    assert(!p.complete(a,{std::numeric_limits<double>::quiet_NaN()}));
    assert(p.complete(a,{96000,96000})); assert(p.mayRoute());
    auto b=p.request(48000); assert(!p.mayRoute());
    assert(!p.complete(a,{96000,96000}));
    for(int i=0;i<3;++i) assert(p.fail(b,"Failed") == 0);
    assert(p.fail(b,"Failed") == 5000); assert(!p.mayRoute());
    assert(p.fail(b,"Failed") == 5000);
    assert(p.complete(b,{48000,48000})); assert(p.mayRoute());
    p.unavailable("Master disconnected"); assert(!p.mayRoute());
    assert(!p.complete(b,{48000,48000}));
    auto c=p.request(192000);
    p.fail(b,"Stale failure"); assert(p.failure.empty());
    assert(p.complete(c,{192000}));
    bool rejected=false; try { p.request(0); } catch (...) { rejected=true; }
    assert(rejected);
}
