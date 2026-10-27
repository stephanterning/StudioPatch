#import <Foundation/Foundation.h>
#include <CoreAudio/CoreAudio.h>
// Deterministic HAL reads and writes for the real bridge and engine code. No
// Core Audio object, IOProc, aggregate or broker connection is touched.
static OSStatus faultRead(AudioObjectID,const AudioObjectPropertyAddress*,UInt32,const void*,UInt32*,void*);
static OSStatus faultSize(AudioObjectID,const AudioObjectPropertyAddress*,UInt32,const void*,UInt32*);
static OSStatus faultSet(AudioObjectID,const AudioObjectPropertyAddress*,UInt32,const void*,UInt32,const void*);
#define AudioObjectGetPropertyData faultRead
#define AudioObjectGetPropertyDataSize faultSize
#define AudioObjectSetPropertyData faultSet
#include "../Sources/Bridge.mm"
#include <cassert>
#include <iostream>
#include <sys/mman.h>
static bool ioRunning=false,failLatency=false,failSecondary=false,failMasterRate=false,failBufferRead=false;
static UInt32 actualBuffer=32;
static int pluginLookups=0,rateWrites=0;
static bool failAfterRateWrite=false;
static double masterRate=96000;
static uint64_t driverGeneration=1;
static std::string driverConfig="1 2 2 96000 256",requestedConfig;
static bool configurationReady=true,failConfigurationRead=false,failConfigurationWrite=false;
static int configurationWrites=0,claimCalls=0,failClaimAt=0;
static void claim() { if(++claimCalls==failClaimAt)throw std::runtime_error("Broker unavailable"); }

static OSStatus faultSize(AudioObjectID,const AudioObjectPropertyAddress* a,UInt32,const void*,UInt32* size) {
    switch(a->mSelector) {
    case kAudioDevicePropertyStreamConfiguration:*size=sizeof(AudioBufferList);return noErr;
    case kAudioDevicePropertyStreams:*size=sizeof(AudioStreamID);return noErr;
    case kAudioDevicePropertyAvailableNominalSampleRates:*size=sizeof(AudioValueRange);return noErr;
    default:return kAudioHardwareBadObjectError;
    }
}
static OSStatus faultRead(AudioObjectID id,const AudioObjectPropertyAddress* a,UInt32,const void* q,UInt32*,void* out) {
    switch(a->mSelector) {
    case patch::ConfigProperty:
        if(failConfigurationRead)return kAudioHardwareBadObjectError;
        *static_cast<CFStringRef*>(out)=CFStringCreateWithCString(nullptr,driverConfig.c_str(),kCFStringEncodingUTF8);return noErr;
    case patch::ReadyProperty:*static_cast<CFStringRef*>(out)=CFStringCreateCopy(nullptr,configurationReady?CFSTR("1"):CFSTR("0"));return noErr;
    case patch::DirectProperty:*static_cast<CFStringRef*>(out)=CFStringCreateWithCString(nullptr,std::to_string(driverGeneration).c_str(),kCFStringEncodingUTF8);return noErr;
    case kAudioHardwarePropertyTranslateBundleIDToPlugIn:
        if(pluginLookups<=0)return kAudioHardwareBadObjectError;
        --pluginLookups;*static_cast<AudioObjectID*>(out)=77;return noErr;
    case kAudioHardwarePropertyTranslateUIDToDevice: {
        bool secondary=CFEqual(*static_cast<const CFStringRef*>(q),CFSTR("secondary"));
        if(secondary && failSecondary)return kAudioHardwareBadObjectError;
        *static_cast<AudioDeviceID*>(out)=secondary?20:10;return noErr;
    }
    case kAudioObjectPropertyName:*static_cast<CFStringRef*>(out)=CFStringCreateCopy(nullptr,CFSTR("Fault interface"));return noErr;
    case kAudioDevicePropertyDeviceIsAlive:*static_cast<UInt32*>(out)=1;return noErr;
    case kAudioDevicePropertyTransportType:*static_cast<UInt32*>(out)=kAudioDeviceTransportTypeUSB;return noErr;
    case kAudioDevicePropertyBufferFrameSize:if(failBufferRead)return kAudioHardwareBadObjectError;*static_cast<UInt32*>(out)=actualBuffer;return noErr;
    case kAudioDevicePropertySafetyOffset:*static_cast<UInt32*>(out)=0;return noErr;
    case kAudioDevicePropertyNominalSampleRate:if(failMasterRate && id==10)return kAudioHardwareBadObjectError;*static_cast<Float64*>(out)=id==10?masterRate:96000;return noErr;
    case kAudioDevicePropertyAvailableNominalSampleRates:*static_cast<AudioValueRange*>(out)={48000,96000};return noErr;
    case kAudioDevicePropertyStreamConfiguration:*static_cast<AudioBufferList*>(out)={1,{{2,0,nullptr}}};return noErr;
    case kAudioDevicePropertyStreams:*static_cast<AudioStreamID*>(out)=id+100;return noErr;
    case kAudioStreamPropertyVirtualFormat:*static_cast<AudioStreamBasicDescription*>(out)={96000,kAudioFormatLinearPCM,kAudioFormatFlagsNativeFloatPacked,8,1,8,2,32,0};return noErr;
    // Device and stream latency share a selector; streams use IDs >= 100.
    case kAudioDevicePropertyLatency:if(failLatency)return kAudioHardwareUnknownPropertyError;*static_cast<UInt32*>(out)=ioRunning && id<100?16:0;return noErr;
    default:return kAudioHardwareBadObjectError;
    }
}
static OSStatus faultSet(AudioObjectID id,const AudioObjectPropertyAddress* a,UInt32,const void*,UInt32,const void* value) {
    if(a->mSelector==kAudioDevicePropertyNominalSampleRate){++rateWrites;if(id==10 && failAfterRateWrite){masterRate=*static_cast<const double*>(value);failMasterRate=true;}}
    if(a->mSelector==patch::ConfigProperty){if(failConfigurationWrite)return kAudioHardwareBadObjectError;++configurationWrites;configurationReady=false;NSString* text=(__bridge NSString*)*static_cast<const CFStringRef*>(value);requestedConfig=text.UTF8String;}
    return noErr;
}
static NSDictionary* setHardwareRate(NSDictionary* request) {
    auto data=[NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    auto text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    char* raw=SPSetHardwareRate(text.UTF8String);NSDictionary* result=json(raw);free(raw);return result;
}
int main() { @autoreleasepool {
    NSDictionary* request=@{@"inputCount":@2,@"outputCount":@2,@"sampleRate":@96000,@"bufferFrames":@32,@"masterUID":@"master",
        @"devices":@[@{@"uid":@"master",@"drift":@NO},@{@"uid":@"secondary",@"drift":@NO,@"syncLocked":@YES}],@"inputs":@[],@"outputs":@[]};
    NSDictionary* master=request[@"devices"][0];

    failSecondary=true;auto result=setHardwareRate(request);failSecondary=false;
    assert(!result[@"error"] && [result[@"warnings"] count]==1 && [result[@"rate"] intValue]==96000);

    // A requested rate is never reported as reached when the Sync Source
    // cannot be read; nothing is written and locked members are not steered.
    NSMutableDictionary* lower=[request mutableCopy];lower[@"sampleRate"]=@48000;
    failMasterRate=true;rateWrites=0;result=setHardwareRate(lower);failMasterRate=false;
    assert(!result[@"error"] && !result[@"rate"] && [result[@"warnings"] count]>0 && rateWrites==0);

    DirectEngine e;e.syncSource=10;
    failLatency=true;auto d=e.openDevice(master,@"master",32);failLatency=false;
    assert(d && !e.deviceWarnings.empty());

    // Latency differing once I/O runs is republished, not a reason to rebuild.
    for(int cycle=0;cycle<3;++cycle) {
        ioRunning=false;e.devices.push_back(e.openDevice(master,@"master",32));assert(!e.stale());
        ioRunning=true;assert(!e.stale());e.devices.clear();
    }
    ioRunning=false;

    // A block-size change alone does not require a new channel layout.
    actualBuffer=64;failBufferRead=true;e.devices.push_back(e.openDevice(master,@"master",32));failBufferRead=false;
    assert(!e.stale());actualBuffer=128;assert(!e.stale());actualBuffer=32;e.devices.clear();

    // Timing publication and its confirmation are optional: a plug-in lookup
    // failure at either step is a warning, never a failed start.
    auto mapping=std::make_shared<patch::SharedMapping>();mapping->size=sizeof(patch::SharedTransport);
    mapping->data=new(mmap(nullptr,mapping->size,PROT_READ|PROT_WRITE,MAP_ANON|MAP_SHARED,-1,0)) patch::SharedTransport;
    e.memory=mapping;e.generation=1;
    for(int allowed:{0,1}) {
        pluginLookups=allowed;e.deviceWarnings.clear();e.lastReport.clear();
        e.reportTiming();
        assert(e.deviceWarnings.size()==1 && e.deviceWarnings[0].find("Latency was not reported")==0);
        assert(allowed==0 || !e.lastReport.empty()); // the publication itself succeeded
    }

    // A successful write followed by failed readback remains unknown, with no
    // steering of the secondary based on the requested value.
    failAfterRateWrite=true;rateWrites=0;result=setHardwareRate(lower);
    assert(!result[@"rate"] && rateWrites==1 && masterRate==48000 && [result[@"wroteSyncSource"] boolValue]);
    failAfterRateWrite=false;failMasterRate=false;
    // A Sync Source already at the requested rate is not written, so there is
    // nothing of ours to undo.
    NSMutableDictionary* onlyMaster=[lower mutableCopy];onlyMaster[@"devices"]=@[master];
    rateWrites=0;result=setHardwareRate(onlyMaster);
    assert([result[@"rate"] intValue]==48000 && rateWrites==0 && ![result[@"wroteSyncSource"] boolValue]);
    masterRate=96000;

    // Old generation remains current through delayed/failed control reads.
    // A retry must query the same request, never create another generation.
    pluginLookups=1000;
    ConfigurationChange change;
    auto wanted=patch::Config::parse("1 2 3 96000 256");
    failClaimAt=1;bool failed=false;
    try{change.step(wanted,claim);}catch(const std::exception&){failed=true;}
    assert(failed && configurationWrites==0);
    failClaimAt=0;failConfigurationWrite=true;failed=false;
    try{change.step(wanted,claim);}catch(const std::exception&){failed=true;}
    assert(failed && change.pending.empty() && driverGeneration==1 && configurationWrites==0);
    failConfigurationWrite=false;
    assert(change.step(wanted,claim)==ConfigurationChange::Pending && configurationWrites==1);
    assert(change.step(wanted,claim)==ConfigurationChange::Pending && configurationWrites==1);
    configurationReady=true; // HAL rejects without replacing the old generation.
    assert(change.step(wanted,claim)==ConfigurationChange::Rejected && driverGeneration==1);
    assert(change.step(wanted,claim)==ConfigurationChange::Pending && configurationWrites==2);
    driverConfig=requestedConfig;++driverGeneration;configurationReady=true;
    failConfigurationRead=true;failed=false;
    try{change.step(wanted,claim);}catch(const std::exception&){failed=true;}
    assert(failed && configurationWrites==2);failConfigurationRead=false;
    failClaimAt=claimCalls+1;failed=false;
    try{change.step(wanted,claim);}catch(const std::exception&){failed=true;}
    assert(failed && configurationWrites==2);failClaimAt=0;
    assert(change.step(wanted,claim)==ConfigurationChange::Applied && configurationWrites==2);
    // An unchanged wire format still needs confirmation of a fresh generation.
    assert(change.step(wanted,claim)==ConfigurationChange::Pending);
    configurationReady=true;
    assert(change.step(wanted,claim)==ConfigurationChange::Rejected);

    // Actual samples, not the internal "observed" field: an unreadable buffer
    // property must not leave half of each real block outside the timing margin.
    DirectEngine samples;samples.memory=mapping;samples.nominalTicks=250;samples.syncSource=10;
    actualBuffer=64;failBufferRead=true;
    samples.devices.push_back(samples.openDevice(master,@"master",32));failBufferRead=false;
    auto& device=*samples.devices[0];device.outputs={{0,{0,0,2}}};device.inputs={{{0,0,2},0}};
    auto& shared=*mapping->data;shared.active=1;shared.inputs=1;shared.outputs=1;shared.rate=96000;shared.padding=32;shared.inputPadding=32;
    assert(!samples.stale());
    float input[256]{},output[256]{};
    AudioTimeStamp now{},it{},ot{};now.mFlags=it.mFlags=ot.mFlags=kAudioTimeStampHostTimeValid|kAudioTimeStampSampleTimeValid;
    for(int cycle=0;cycle<6;++cycle) {
        uint32_t frames=cycle<3?64:128;int64_t base=10000+256*cycle;
        for(uint32_t i=0;i<frames;++i){shared.playback.write(0,base+i,0.25f);input[2*i]=0.125f;}
        now.mSampleTime=it.mSampleTime=base;ot.mSampleTime=base+frames;
        now.mHostTime=it.mHostTime=100000000+256*cycle*250;ot.mHostTime=now.mHostTime+frames*250;
        AudioBufferList in{1,{{2,frames*8,input}}},out{1,{{2,frames*8,output}}};
        DirectEngine::io(0,&now,&in,&it,&out,&ot,&device);
        for(uint32_t i=0;i<frames;++i)assert(output[2*i]==0.25f && output[2*i+1]==0 && shared.capture.read(0,base+i)==0.125f);
        assert(shared.padding==frames && shared.inputPadding==frames);
    }
    // Variable/short blocks keep a stable read position after the maximum
    // block has been seen. A ramp exposes skipped or repeated samples.
    int64_t base=20000;
    for(int64_t frame=base;frame<base+2048;++frame)shared.playback.write(0,frame,float(frame-base+1));
    for(uint32_t frames:{128,32,64,16,128}) {
        now.mSampleTime=it.mSampleTime=base;ot.mSampleTime=base+128;
        now.mHostTime=it.mHostTime=200000000+base*250;ot.mHostTime=now.mHostTime+128*250;
        AudioBufferList in{1,{{2,frames*8,input}}},out{1,{{2,frames*8,output}}};
        DirectEngine::io(0,&now,&in,&it,&out,&ot,&device);
        for(uint32_t i=0;i<frames;++i)assert(output[2*i]==float(base+i-20000+1));
        assert(shared.padding==128 && shared.inputPadding==128);
        base+=frames;
    }
    std::cout<<"PASS: secondary lookup warning, unconfirmed Sync Source rate, unreadable latency, latency-only changes, live buffer sample delivery, configuration acknowledgement and contained timing confirmation\n";
} }
