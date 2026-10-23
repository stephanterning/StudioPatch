#include "../Sources/Bridge.mm"
#include <cassert>
#include <sys/wait.h>
#include <unistd.h>
#include <iostream>
int main() {
    auto mapping=std::make_shared<patch::SharedMapping>();mapping->size=sizeof(patch::SharedTransport);
    mapping->data=new(mmap(nullptr,mapping->size,PROT_READ|PROT_WRITE,MAP_ANON|MAP_SHARED,-1,0)) patch::SharedTransport;
    auto& shared=*mapping->data;shared.padding=32;shared.rate=96000;shared.inputs=3;shared.outputs=2;shared.active=1;
    // Same lock-free atomic storage is visible in a second process.
    auto child=fork();assert(child>=0);
    if(!child){shared.playback.write(1,10268,.25f);shared.playback.write(1,10269,-.5f);_exit(0);}
    int result;waitpid(child,&result,0);assert(WIFEXITED(result) && WEXITSTATUS(result)==0);
    assert(shared.playback.read(1,10268)==.25f);
    DirectEngine e;e.memory=mapping;e.nominalTicks=250;
    DirectEngine::DeviceIO d;d.owner=&e;d.master=true;d.inLayout={2};d.outLayout={2};
    d.inputs.push_back({{0,1,2},2});d.outputs={ {1,{0,0,2}}, {1,{0,1,2}} };
    float in[]{1,2,3,4},out[]{9,9,9,9};AudioBufferList input{1,{{2,sizeof(in),in}}},output{1,{{2,sizeof(out),out}}};
    AudioTimeStamp now{},it{},ot{};now.mFlags=it.mFlags=ot.mFlags=kAudioTimeStampHostTimeValid|kAudioTimeStampSampleTimeValid;
    now.mSampleTime=10200;now.mHostTime=100000000;it.mSampleTime=10000;it.mHostTime=99950000;ot.mSampleTime=10300;ot.mHostTime=100025000;
    DirectEngine::io(0,&now,&input,&it,&output,&ot,&d);
    assert(shared.capture.read(2,10000)==2 && shared.capture.read(2,10001)==4);
    assert(shared.capture.read(0,10000)==0);assert(out[0]==.25f && out[1]==.25f && out[2]==-.5f && out[3]==-.5f);
    patch::ClockSample clock;assert(shared.clock(clock) && clock.sample==10200 && clock.host==100000000 && clock.ticks==250);
    assert(shared.alive(now.mHostTime) && shared.alive(now.mHostTime+2399999));
    assert(!shared.alive(now.mHostTime+2400000) && shared.alive(now.mHostTime-1));
    assert(!shared.alive(now.mHostTime-2400000));
    assert(shared.claimed.exchange(1)==0 && shared.claimed.exchange(1)==1);
    // Old slots never reappear when wrapping, and inactive transport is silent.
    shared.playback.write(1,10268+patch::SharedFrames,1);assert(shared.playback.read(1,10268)==0);
    shared.active=0;DirectEngine::io(0,&now,&input,&it,&output,&ot,&d);for(auto v:out)assert(v==0);
    shared.active=1;input.mBuffers[0].mNumberChannels=1;
    DirectEngine::io(0,&now,&input,&it,&output,&ot,&d);assert(e.invalidated && e.badBuffers==1);
    // A second hardware clock (or Apple's corrected aggregate) uses a fixed
    // epoch translation. Its larger safety offset never delays master routes.
    input.mBuffers[0].mNumberChannels=2;e.invalidated=false;
    d.master=false;d.aligned=false;d.extraInput=240;d.extraOutput=80;
    now.mSampleTime-=1000;it.mSampleTime-=1000;ot.mSampleTime-=1000;
    shared.playback.write(1,10188,.75f);shared.playback.write(1,10189,-.25f);
    DirectEngine::io(0,&now,&input,&it,&output,&ot,&d);
    assert(d.offset==1000 && shared.capture.read(2,10240)==2 && shared.capture.read(2,10241)==4);
    assert(out[0]==.75f && out[1]==.75f && out[2]==-.25f && out[3]==-.25f);
    now.mHostTime+=2400001;
    DirectEngine::io(0,&now,&input,&it,&output,&ot,&d);for(auto v:out)assert(v==0);
    std::cout<<"PASS: cross-process samples, direct independent routing, fan-out, physical clock, mute and wrap validation\n";
}
