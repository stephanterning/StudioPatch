#include "../Sources/Bridge.mm"
#include <cassert>
#include <sys/wait.h>
#include <unistd.h>
#include <iostream>
static int lookupMode=0;
static OSStatus lookupSize(AudioObjectID,const AudioObjectPropertyAddress*,UInt32,const void*,UInt32* size) {
    *size=3*sizeof(AudioObjectID);return noErr;
}
static OSStatus lookupRead(AudioObjectID id,const AudioObjectPropertyAddress* a,UInt32,const void*,UInt32* size,void* out) {
    if(a->mSelector==kAudioHardwarePropertyTranslateBundleIDToPlugIn) {
        if(lookupMode==1){*static_cast<AudioObjectID*>(out)=77;return noErr;}
        return kAudioHardwareBadObjectError;
    }
    if(a->mSelector==kAudioHardwarePropertyPlugInList) {
        AudioObjectID ids[]{11,22,33};memcpy(out,ids,sizeof(ids));*size=sizeof(ids);return noErr;
    }
    if(id==11)return kAudioHardwareBadObjectError;
    auto name=(id==33 && lookupMode!=2)?CFSTR("se.studiopatch.driver"):CFSTR("another.driver");
    *static_cast<CFStringRef*>(out)=static_cast<CFStringRef>(CFRetain(name));return noErr;
}
int main() {
    assert(pluginID(lookupRead,lookupSize)==33); // stale unrelated object skipped
    lookupMode=1;assert(pluginID(lookupRead,lookupSize)==77);
    lookupMode=2;bool absent=false;
    try {pluginID(lookupRead,lookupSize);}catch(const HALError& e){absent=e.status==kAudioHardwareBadObjectError;}
    assert(absent); // never authorize an unrelated plug-in

    auto mapping=std::make_shared<patch::SharedMapping>();mapping->size=sizeof(patch::SharedTransport);
    mapping->data=new(mmap(nullptr,mapping->size,PROT_READ|PROT_WRITE,MAP_ANON|MAP_SHARED,-1,0)) patch::SharedTransport;
    auto& shared=*mapping->data;shared.padding=32;shared.rate=96000;shared.inputs=3;shared.outputs=2;shared.active=1;
    // Broker revocation must renew a cached claim even with unchanged format/generation.
    std::shared_ptr<patch::SharedMapping> claim;int connections=0;uint64_t wanted=41;
    auto connect=[&]{++connections;shared.generation=wanted;shared.controllerPID=getpid();return mapping;};
    refreshControllerClaim(claim,wanted,connect);assert(connections==1);
    refreshControllerClaim(claim,wanted,connect);assert(connections==1);
    shared.controllerPID=0;
    refreshControllerClaim(claim,wanted,connect);assert(connections==2 && shared.controllerPID==getpid());
    wanted=42;refreshControllerClaim(claim,wanted,connect);assert(connections==3 && shared.generation==42);
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
    patch::ClockReader reader;assert(reader.read(shared,clock));
    patch::HardwareTimeline timeline;double zs;uint64_t zh,ze;
    assert(timeline.get(shared,now.mHostTime,zs,zh,ze));auto stableHost=zh;
    shared.clockSequence.fetch_add(1); // Writer paused midway through publication.
    shared.sample=123456789; // A torn snapshot must never escape.
    assert(reader.read(shared,clock) && clock.sample==10200);
    assert(timeline.get(shared,now.mHostTime+1,zs,zh,ze) && zh==stableHost && ze==0);
    shared.sample=10200;shared.clockSequence.fetch_add(1);
    now.mFlags|=kAudioTimeStampRateScalarValid;now.mRateScalar=1.0001;
    DirectEngine::io(0,&now,&input,&it,&output,&ot,&d);
    assert(shared.clock(clock) && std::abs(clock.ticks-250.025)<1e-9);
    assert(timeline.get(shared,now.mHostTime,zs,zh,ze) && zh==stableHost);
    patch::HardwareTimeline scaled;double ss;uint64_t sh,se;
    auto expected=double(now.mHostTime)+(patch::RingFrames-now.mSampleTime)*250.025;
    assert(scaled.get(shared,uint64_t(expected+251),ss,sh,se));
    assert(ss==patch::RingFrames && std::abs(double(sh)-expected)<1);
    now.mRateScalar=1;DirectEngine::io(0,&now,&input,&it,&output,&ot,&d);
    patch::PhaseMeter phase;
    phase.record(false,32,90,1);phase.record(true,32,100,1);
    phase.record(true,64,200,1);phase.record(false,64,220,1);
    phase.record(false,64,220,1);phase.record(false,96.5,300,1);phase.record(true,96,300,1);
    assert(phase.pairs==2 && phase.minimumTicks==-10 && phase.maximumTicks==20);
    patch::PhaseMeter projected;
    projected.record(true,32,100,2,32);projected.record(false,40,130,2);
    projected.record(false,75,240,2);projected.record(true,64,200,2,32);
    assert(projected.pairs==2 && projected.exactPairs==0 && projected.maximumProjectionFrames==11);
    assert(projected.minimumTicks==14 && projected.maximumTicks==18);
    patch::PublicationLog log;patch::MarginStats stats;
    log.publish(0,32,100);log.publish(64,96,200);
    stats.observe(log,0,96,300,1);assert(stats.unmatched==1); // Interior hole.
    log.publish(32,64,250);stats.observe(log,0,96,300,1);assert(stats.minimumTicks==50);
    assert(shared.claimed.exchange(1)==0 && shared.claimed.exchange(1)==1);
    // Old slots never reappear when wrapping, and inactive transport is silent.
    shared.playback.write(1,10268+patch::SharedFrames,1);assert(shared.playback.read(1,10268)==0);
    shared.active=0;DirectEngine::io(0,&now,&input,&it,&output,&ot,&d);for(auto v:out)assert(v==0);
    // An unaddressable block is skipped alone; the next valid block carries audio.
    shared.active=1;input.mBuffers[0].mNumberChannels=1;
    DirectEngine::io(0,&now,&input,&it,&output,&ot,&d);assert(e.badBuffers==1);for(auto v:out)assert(v==0);
    input.mBuffers[0].mNumberChannels=2;shared.playback.write(1,10268,.25f);
    DirectEngine::io(0,&now,&input,&it,&output,&ot,&d);
    assert(e.badBuffers==1 && out[0]==.25f && out[2]==-.5f && shared.capture.read(2,10001)==4);
    // A second hardware clock (or Apple's corrected aggregate) uses a fixed
    // epoch translation. Its larger safety offset never delays master routes.
    d.master=false;d.aligned=false;d.extraInput=240;d.extraOutput=80;
    now.mSampleTime-=1000;it.mSampleTime-=1000;ot.mSampleTime-=1000;
    shared.playback.write(1,10188,.75f);shared.playback.write(1,10189,-.25f);
    DirectEngine::io(0,&now,&input,&it,&output,&ot,&d);
    assert(d.offset==1000 && shared.capture.read(2,10240)==2 && shared.capture.read(2,10241)==4);
    assert(out[0]==.75f && out[1]==.75f && out[2]==-.25f && out[3]==-.25f);
    // Cross-device host-time differences are not an audio gate either.
    now.mHostTime+=2400001;
    DirectEngine::io(0,&now,&input,&it,&output,&ot,&d);
    assert(out[0]==.75f && out[2]==-.25f);
    d.master=true;d.offset=0;now.mHostTime=100000000;now.mSampleTime=20200;
    it.mSampleTime=20000;ot.mSampleTime=20300;d.extraInput=0;d.extraOutput=0;
    shared.playback.write(1,20268,.5f);shared.playback.write(1,20269,-.5f);
    // A host/sample prediction mismatch does not invalidate a running master.
    DirectEngine::io(0,&now,&input,&it,&output,&ot,&d);
    assert(shared.active && shared.clock(clock) && clock.epoch==0);
    assert(shared.capture.read(2,20000)==2 && out[0]==.5f && out[2]==-.5f);
    // A real counter reset gets a fresh, monotonic mapping without stopping I/O.
    now.mHostTime+=500;now.mSampleTime=100;it.mSampleTime=-100;ot.mSampleTime=200;
    shared.playback.write(1,20270,.25f);shared.playback.write(1,20271,-.25f);
    DirectEngine::io(0,&now,&input,&it,&output,&ot,&d);
    assert(shared.active && shared.clock(clock) && clock.epoch==1 && clock.sample==20202);
    assert(d.offset==20102 && shared.capture.read(2,20002)==2 && out[0]==.25f && out[2]==-.25f);
    assert(timeline.get(shared,now.mHostTime,zs,zh,ze) && ze==1);
    DirectEngine::DeviceIO skewed;skewed.owner=&e;skewed.inLayout={2};skewed.outLayout={2};
    // A deliberately stopped transport is not used to establish a mapping.
    shared.publishClock({now.mSampleTime+100,250,now.mHostTime,0});shared.active=0;
    for(int i=0;i<4;++i)DirectEngine::io(0,&now,&input,&it,&output,&ot,&skewed);
    assert(!skewed.aligned);shared.active=1;skewed.aligned=true;
    skewed.offset=1000;skewed.extraInput=240;skewed.extraOutput=80;
    skewed.inputs=d.inputs;skewed.outputs=d.outputs;
    // Replay the measured trigger and larger deviations, sustained for 100 ms
    // each. Assert actual capture AND playback: a running flag alone missed the
    // old bug, which left a selectable endpoint with a silently latched member.
    for(double deviation:{12.0,-32.795953195134643,-188.34397473186255,100.0,-20000.0,20000.0,0.0}) {
        for(int i=0;i<10;++i) {
            now.mHostTime+=240000;now.mSampleTime+=960; // 10 ms at 96 kHz
            it.mSampleTime=now.mSampleTime-200;ot.mSampleTime=now.mSampleTime+100;
            shared.publishClock({now.mSampleTime+skewed.offset+deviation,250,now.mHostTime,0});
            auto captured=int64_t(it.mSampleTime+skewed.offset+skewed.extraInput);
            auto played=int64_t(ot.mSampleTime+skewed.offset-shared.padding-skewed.extraOutput);
            shared.playback.write(1,played,.75f);shared.playback.write(1,played+1,-.25f);
            auto cycles=e.cycles.load();
            DirectEngine::io(0,&now,&input,&it,&output,&ot,&skewed);
            assert(shared.capture.read(2,captured)==2 && shared.capture.read(2,captured+1)==4);
            assert(out[0]==.75f && out[1]==.75f && out[2]==-.25f && out[3]==-.25f);
            assert(e.cycles==cycles+1 && shared.active);
            assert(std::abs(skewed.clockSkew.load()-deviation)<1e-6 && skewed.offset==1000);
        }
    }
    assert(std::abs(skewed.peakClockSkew.load())==20000 && skewed.clockSkew==0);
    // The secondary's own counter restarts (e.g. sync lock set its rate back):
    // its routes realign to the shared timeline and keep carrying audio.
    {
        patch::ClockSample last;assert(shared.clock(last));
        now.mHostTime+=240000;const double timeline=last.sample+960;
        shared.publishClock({timeline,250,now.mHostTime,0});
        now.mSampleTime=5000;it.mSampleTime=4800;ot.mSampleTime=5100;
        DirectEngine::io(0,&now,&input,&it,&output,&ot,&skewed);
        assert(skewed.offset==timeline-5000 && std::abs(skewed.clockSkew.load())<1e-6);
        assert(shared.capture.read(2,int64_t(timeline-200+skewed.extraInput))==2);
    }
    // A route table remains alive until a reader holding the old pointer exits.
    struct Tracked {std::atomic<int>* destroyed;int value;~Tracked(){++*destroyed;}};
    std::atomic<int> destroyed{0};patch::RouteSlot<Tracked> slot;
    auto table=[&](int v){auto p=std::make_unique<Tracked>();p->destroyed=&destroyed;p->value=v;return p;};
    slot.publish(table(1));
    {
        patch::RouteSlot<Tracked>::Read held(slot);auto visit=slot.publish(table(2));
        assert(!slot.passed(visit) && destroyed==0 && held.value->value==1);
    }
    slot.collect();assert(destroyed==1);
    {
        patch::RouteSlot<Tracked>::Read held(slot);assert(held.value->value==2);
    }
    // Cross-device transfer waits for the old writer, keeps unrelated routes,
    // then changes ownership before the new writer can publish the destination.
    DirectEngine routes;routes.memory=mapping;
    for(int i=0;i<2;++i){auto dev=std::make_unique<DirectEngine::DeviceIO>();dev->timingIndex=i;routes.devices.push_back(std::move(dev));}
    routes.devices[0]->inputs={{{0,0,1},0},{{0,0,1},1}};
    shared.captureOwner[0]=0;shared.captureOwner[1]=0;
    std::vector<std::unique_ptr<DirectEngine::Routes>> tables;
    for(int i=0;i<2;++i)tables.push_back(std::make_unique<DirectEngine::Routes>());
    tables[0]->inputs={{{0,0,1},1}};tables[1]->inputs={{{0,0,1},0}};
    std::atomic<bool> holding{false},release{false};
    std::thread callback([&]{patch::RouteSlot<DirectEngine::Routes>::Read read(routes.devices[0]->routes);holding=true;while(!release.load())std::this_thread::yield();});
    while(!holding.load())std::this_thread::yield();
    std::thread releaseReader([&]{
        // The published interim table can be read only by this device's one
        // serialized callback, so inspect the ownership flag instead here.
        assert(shared.captureOwner[0]==0);release=true;
    });
    routes.handoverRouting(std::move(tables),{1,0});callback.join();releaseReader.join();
    assert(routes.routingUpdates==1 && shared.captureOwner[0]==1 && shared.captureOwner[1]==0);
    assert(routes.devices[0]->routes.controlValue()->inputs.size()==1);
    assert(routes.devices[1]->routes.controlValue()->inputs[0].dest==0);
    // Routes to a channel that no longer exists (e.g. fewer ADAT/MADI channels
    // at double speed), a missing interface or a taken output stay silent; the
    // remaining routes still apply.
    DirectEngine compiled;compiled.memory=mapping;
    struct Spec {const char* uid;UInt32 inputs,outputs;};
    for(auto spec:{Spec{"a",2,2},Spec{"b",0,1}}) {
        auto dev=std::make_unique<DirectEngine::DeviceIO>();dev->uid=spec.uid;dev->timingIndex=uint32_t(compiled.devices.size());
        if(spec.inputs)dev->inLayout={spec.inputs};
        dev->outLayout={spec.outputs};compiled.devices.push_back(std::move(dev));
    }
    NSDictionary* request=@{@"inputCount":@3,@"outputCount":@2,@"sampleRate":@96000,@"masterUID":@"a",
        @"inputs":@[@{@"deviceUID":@"a",@"channel":@2},@{@"deviceUID":@"a",@"channel":@9},[NSNull null]],
        @"outputs":@[@{@"deviceUID":@"b",@"channel":@1,@"virtualChannel":@1},@{@"deviceUID":@"gone",@"channel":@1,@"virtualChannel":@2},
                     @{@"deviceUID":@"b",@"channel":@1,@"virtualChannel":@2}]};
    auto compiledRoutes=compiled.compile(request,patch::Config::parse("1 3 2 96000 256"));
    assert(compiledRoutes.tables[0]->inputs.size()==1 && compiledRoutes.tables[0]->inputs[0].dest==0 && compiledRoutes.tables[0]->inputs[0].source.channel==1);
    assert(compiledRoutes.owner[0]==0 && compiledRoutes.owner[1]==2 && compiledRoutes.owner[2]==2);
    assert(compiledRoutes.tables[1]->outputs.size()==1 && compiledRoutes.tables[1]->outputs[0].source==0);
    assert((compiledRoutes.silent==std::vector<std::string>{"To Computer 2","From Computer 2","From Computer 2"}));
    compiled.graph=DirectEngine::graphOf(request);
    assert(compiled.updateRouting(request) && compiled.routingUpdates==1);
    assert(compiled.routeWarning.find("To Computer 2")!=std::string::npos);
    assert(compiled.devices[0]->routes.controlValue()->inputs.size()==1 && compiled.devices[1]->routes.controlValue()->outputs.size()==1);
    assert(shared.captureOwner[0]==0 && shared.captureOwner[1]==patch::MaxChannels);
    // Sync lock (and the legacy followMaster default) only steers rate
    // changes; toggling it is a routing-level update, not a graph change.
    NSDictionary* locked=@{@"devices":@[@{@"uid":@"a",@"drift":@NO,@"syncLocked":@YES}],@"followMaster":@YES,@"bufferFrames":@64,@"inputs":@[]};
    NSDictionary* unlocked=@{@"devices":@[@{@"uid":@"a",@"drift":@NO,@"syncLocked":@NO}],@"followMaster":@NO,@"bufferFrames":@64,@"inputs":@[[NSNull null]]};
    NSDictionary* drifting=@{@"devices":@[@{@"uid":@"a",@"drift":@YES,@"syncLocked":@YES}],@"followMaster":@YES,@"bufferFrames":@64,@"inputs":@[]};
    assert([DirectEngine::graphOf(locked) isEqual:DirectEngine::graphOf(unlocked)]);
    assert(![DirectEngine::graphOf(locked) isEqual:DirectEngine::graphOf(drifting)]);
    std::cout<<"PASS: cross-process samples, direct independent routing, fan-out, physical clock, isolated bad blocks, silent unavailable routes and wrap validation\n";
}
