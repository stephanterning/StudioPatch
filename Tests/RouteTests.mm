#define STUDIOPATCH_ENABLE_LEGACY 1
#include "../Sources/Bridge.mm"
#include <cassert>
#include <iostream>

struct Buffers { UInt32 count; AudioBuffer buffers[3]; };
int main() {
    // Simulate separate UFX, ZED and virtual-bridge buffers, with unequal widths.
    float ufx[]{1,2,3,4,5,6}, zed[]{7,8}, daw[]{9,10,11,12};
    float ufxOut[4]{},zedOut[2]{},capture[6]{};
    Buffers in{3,{{3,sizeof(ufx),ufx},{1,sizeof(zed),zed},{2,sizeof(daw),daw}}};
    Buffers out{3,{{2,sizeof(ufxOut),ufxOut},{1,sizeof(zedOut),zedOut},{3,sizeof(capture),capture}}};
    LegacyEngine e; e.inLayout={3,1,2}; e.outLayout={2,1,3};
    auto a=channels(e.inLayout),b=channels(e.outLayout);
    e.routes={{a[2],b[3]},{a[3],b[4]},{a[0],b[5]}, // UFX3, ZED1, UFX1 -> DAW1..3
        {a[5],b[0]},{a[4],b[2]}}; // DAW2 -> UFX1; DAW1 -> ZED1
    LegacyEngine::io(0,nullptr,reinterpret_cast<AudioBufferList*>(&in),nullptr,
        reinterpret_cast<AudioBufferList*>(&out),nullptr,&e);
    assert(capture[0]==3 && capture[1]==7 && capture[2]==1);
    assert(capture[3]==6 && capture[4]==8 && capture[5]==4);
    assert(ufxOut[0]==10 && ufxOut[1]==0 && ufxOut[2]==12 && ufxOut[3]==0);
    assert(zedOut[0]==9 && zedOut[1]==11);
    // Dormant routes are omitted from the compiled active list. Old samples
    // must be cleared, and reinstating the routes must restore both directions.
    const auto savedRoutes=e.routes;
    e.routes={savedRoutes[0],savedRoutes[4]};
    LegacyEngine::io(0,nullptr,reinterpret_cast<AudioBufferList*>(&in),nullptr,
        reinterpret_cast<AudioBufferList*>(&out),nullptr,&e);
    assert(capture[0]==3 && capture[3]==6);
    assert(capture[1]==0 && capture[2]==0 && capture[4]==0 && capture[5]==0);
    for(float v:ufxOut) assert(v==0);
    assert(zedOut[0]==9 && zedOut[1]==11);
    e.routes=savedRoutes;
    LegacyEngine::io(0,nullptr,reinterpret_cast<AudioBufferList*>(&in),nullptr,
        reinterpret_cast<AudioBufferList*>(&out),nullptr,&e);
    assert(capture[1]==7 && capture[2]==1 && capture[4]==8 && capture[5]==4);
    assert(ufxOut[0]==10 && ufxOut[2]==12);
    // Fan-out copies the same source unchanged to multiple destinations.
    e.routes={{a[2],b[3]},{a[2],b[4]},{a[5],b[0]},{a[5],b[2]}};
    LegacyEngine::io(0,nullptr,reinterpret_cast<AudioBufferList*>(&in),nullptr,
        reinterpret_cast<AudioBufferList*>(&out),nullptr,&e);
    assert(capture[0]==3 && capture[1]==3 && capture[2]==0);
    assert(capture[3]==6 && capture[4]==6 && capture[5]==0);
    assert(ufxOut[0]==10 && ufxOut[2]==12 && zedOut[0]==10 && zedOut[1]==12);
    e.invalidated.store(true);
    LegacyEngine::io(0,nullptr,reinterpret_cast<AudioBufferList*>(&in),nullptr,
        reinterpret_cast<AudioBufferList*>(&out),nullptr,&e);
    for(float v:capture) assert(v==0);
    for(float v:ufxOut) assert(v==0);
    for(float v:zedOut) assert(v==0);
    e.invalidated.store(false); in.buffers[0].mNumberChannels=2;
    LegacyEngine::io(0,nullptr,reinterpret_cast<AudioBufferList*>(&in),nullptr,
        reinterpret_cast<AudioBufferList*>(&out),nullptr,&e);
    assert(e.invalidated && e.badBuffers==1);
    std::cout<<"PASS: device/channel reorder, independent duplex, fan-out-compatible routing, unconnected silence and layout-change fail-closed\n";
}
