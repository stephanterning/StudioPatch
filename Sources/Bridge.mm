#include "Bridge.h"
#include "Core.hpp"
#include "Latency.hpp"
#include "SharedTransport.hpp"
#include "ChannelNames.hpp"
#include "RateSync.hpp"
#include "RateWire.hpp"
#import <Foundation/Foundation.h>
#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <algorithm>
#include <map>
#include <mutex>
#include <set>
#include <thread>
#include <vector>

namespace {
AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal, UInt32 element = 0) {
    return {selector,scope,element};
}
void check(OSStatus status, const std::string& what) {
    if (status) throw std::runtime_error(what + " (Core Audio " + std::to_string(status) + ")");
}
template<typename T> T get(AudioObjectID id, AudioObjectPropertySelector key,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    T value{}; UInt32 size = sizeof(value); auto a = address(key,scope);
    check(AudioObjectGetPropertyData(id,&a,0,nullptr,&size,&value),"Read device property");
    return value;
}
template<typename T> std::vector<T> list(AudioObjectID id, AudioObjectPropertySelector key,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    auto a = address(key,scope); UInt32 size=0;
    check(AudioObjectGetPropertyDataSize(id,&a,0,nullptr,&size),"Read device list size");
    std::vector<T> result((size+sizeof(T)-1)/sizeof(T));
    if (size) check(AudioObjectGetPropertyData(id,&a,0,nullptr,&size,result.data()),"Read device list");
    return result;
}
NSString* stringProperty(AudioObjectID id, AudioObjectPropertySelector key,
    AudioObjectPropertyScope scope=kAudioObjectPropertyScopeGlobal, UInt32 element=0) {
    auto a=address(key,scope,element); CFStringRef text=nullptr; UInt32 size=sizeof(text);
    if (AudioObjectGetPropertyData(id,&a,0,nullptr,&size,&text) || !text) return @"";
    return CFBridgingRelease(text);
}
std::vector<UInt32> layout(AudioObjectID id, AudioObjectPropertyScope scope) {
    auto bytes=list<uint8_t>(id,kAudioDevicePropertyStreamConfiguration,scope);
    std::vector<UInt32> result;
    if (bytes.size()<offsetof(AudioBufferList,mBuffers)) return result;
    const auto* buffers=reinterpret_cast<const AudioBufferList*>(bytes.data());
    for (UInt32 b=0;b<buffers->mNumberBuffers;++b) result.push_back(buffers->mBuffers[b].mNumberChannels);
    return result;
}
UInt32 total(const std::vector<UInt32>& l) { UInt32 n=0; for(auto v:l)n+=v; return n; }
AudioDeviceID translate(NSString* uid) {
    auto a=address(kAudioHardwarePropertyTranslateUIDToDevice);
    CFStringRef cf=(__bridge CFStringRef)uid; AudioDeviceID id=0; UInt32 size=sizeof(id);
    check(AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(cf),&cf,&size,&id),"Find device");
    return id;
}
AudioObjectID pluginID() {
    // HAL device ownership is not the plug-in ID (it may be the system object).
    CFStringRef bundle=CFSTR("se.studiopatch.driver");
    AudioObjectID id=kAudioObjectUnknown; UInt32 size=sizeof(id);
    auto a=address(kAudioHardwarePropertyTranslateBundleIDToPlugIn);
    check(AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(bundle),&bundle,&size,&id),
        "Find the StudioPatch driver");
    if (!id) throw std::runtime_error("The StudioPatch driver is not installed and loaded.");
    return id;
}
NSDictionary* json(const char* raw) {
    if (!raw) throw std::runtime_error("Missing configuration");
    NSError* error=nil;
    id o=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:raw length:strlen(raw)] options:0 error:&error];
    if (![o isKindOfClass:[NSDictionary class]]) throw std::runtime_error("Invalid configuration JSON");
    return o;
}
char* response(id obj) {
    NSData* data=[NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted error:nil];
    NSString* s=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return strdup(s.UTF8String ?: "{}");
}
char* failure(const std::exception& e) { return response(@{@"error":@(e.what())}); }
patch::Config config(NSDictionary* d) {
    auto integer = [&](NSString* key)->std::string {
        id v=d[key];
        if (![v isKindOfClass:[NSNumber class]] || [v doubleValue] != [v longLongValue])
            throw std::runtime_error("Invalid numeric configuration");
        return std::to_string([v longLongValue]);
    };
    return patch::Config::parse("1 "+integer(@"inputCount")+" "+integer(@"outputCount")+" "+
        integer(@"sampleRate")+" "+integer(@"delayFrames"));
}
std::string currentConfig() {
    auto id=pluginID(); auto a=address(patch::ConfigProperty);
    CFStringRef value=nullptr; UInt32 size=sizeof(value);
    check(AudioObjectGetPropertyData(id,&a,0,nullptr,&size,&value),"Read StudioPatch configuration");
    if (!value) throw std::runtime_error("The StudioPatch driver returned an empty configuration.");
    NSString* text=CFBridgingRelease(value);
    return text.UTF8String;
}

struct Channel { uint32_t buffer, channel, stride; };
std::vector<Channel> channels(const std::vector<UInt32>& l) {
    std::vector<Channel> result;
    for(uint32_t b=0;b<l.size();++b) for(uint32_t c=0;c<l[b];++c) result.push_back({b,c,l[b]});
    return result;
}
struct Route { Channel source,dest; };
struct Watch { AudioObjectID id; AudioObjectPropertyAddress addr; };
class LegacyEngine {
public:
    AudioDeviceID aggregate=0;
    AudioDeviceIOProcID proc=nullptr;
    std::atomic<bool> invalidated{false};
    std::atomic<uint64_t> cycles{0}, badBuffers{0};
    // Timestamp diagnostics only; never call HAL or allocate in the audio callback.
    std::atomic<int64_t> ioTimestampGap{-1};
    std::atomic<uint32_t> callbackFrames{0};
    std::vector<UInt32> inLayout,outLayout;
    std::vector<Route> routes;
    std::vector<Watch> watches;
    uint32_t actualBuffer=0;
    uint64_t timingAnchor=0;
    double ticksPerFrame=0;
    Channel timingInput[2]{},timingOutput[2]{};
    std::atomic<double> playbackDelay{-1};
    AudioDeviceID syncSource=0;
    uint32_t lastInputLatency=UINT32_MAX,lastOutputLatency=UINT32_MAX;
    void publishLatency() {
        if(invalidated.load())return;
        auto timing=stringProperty(pluginID(),patch::TimingProperty);
        uint64_t generation; double ticks,capture;
        std::istringstream values(timing.UTF8String ?: "");
        if(!(values>>generation>>ticks>>capture) || generation!=timingAnchor || capture<0)return;
        const auto playback=playbackDelay.load();if(playback<0)return;
        auto hardwareLatency=[&](bool input) {
            auto scope=input?kAudioObjectPropertyScopeInput:kAudioObjectPropertyScopeOutput;
            UInt32 streamLatency=0;
            for(auto stream:list<AudioStreamID>(syncSource,kAudioDevicePropertyStreams,scope))
                streamLatency=std::max(streamLatency,get<UInt32>(stream,kAudioStreamPropertyLatency));
            return uint64_t(get<UInt32>(syncSource,kAudioDevicePropertyLatency,scope))+streamLatency;
        };
        auto in=uint32_t(std::llround(capture)+hardwareLatency(true));
        auto out=uint32_t(std::llround(playback)+hardwareLatency(false));
        if(in==lastInputLatency && out==lastOutputLatency)return;
        auto text=std::to_string(timingAnchor)+" "+std::to_string(in)+" "+std::to_string(out);
        CFStringRef value=CFStringCreateWithCString(nullptr,text.c_str(),kCFStringEncodingUTF8);
        auto a=address(patch::LatencyProperty);
        auto status=AudioObjectSetPropertyData(pluginID(),&a,0,nullptr,sizeof(value),&value);CFRelease(value);
        check(status,"Publish latency report");lastInputLatency=in;lastOutputLatency=out;
    }
    ~LegacyEngine() { stop(); }
    static OSStatus changed(AudioObjectID,UInt32,const AudioObjectPropertyAddress*,void* p) {
        static_cast<LegacyEngine*>(p)->invalidated.store(true); return noErr;
    }
    void watch(AudioObjectID id,AudioObjectPropertySelector key,AudioObjectPropertyScope scope=kAudioObjectPropertyScopeGlobal) {
        auto a=address(key,scope);
        check(AudioObjectAddPropertyListener(id,&a,changed,this),"Watch device changes");
        watches.push_back({id,a});
    }
    void stop() {
        invalidated.store(true);
        if (proc) { AudioDeviceStop(aggregate,proc); AudioDeviceDestroyIOProcID(aggregate,proc); proc=nullptr; }
        for (const auto& w:watches) AudioObjectRemovePropertyListener(w.id,&w.addr,changed,this);
        watches.clear();
        if (aggregate) { AudioHardwareDestroyAggregateDevice(aggregate); aggregate=0; }
    }
    static OSStatus io(AudioDeviceID,const AudioTimeStamp*,const AudioBufferList* input,
        const AudioTimeStamp* inputTime,AudioBufferList* output,const AudioTimeStamp* outputTime,void* p) {
        auto& e=*static_cast<LegacyEngine*>(p);
        if (output) for(UInt32 b=0;b<output->mNumberBuffers;++b)
            if(output->mBuffers[b].mData) memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
        if (e.invalidated.load(std::memory_order_relaxed)) return noErr;
        if (!input || !output || input->mNumberBuffers!=e.inLayout.size() || output->mNumberBuffers!=e.outLayout.size()) {
            e.badBuffers.fetch_add(1); e.invalidated.store(true); return noErr;
        }
        uint32_t frames=UINT32_MAX;
        for(bool in:{true,false}) {
            const auto* abl=in?input:output;
            const auto& l=in?e.inLayout:e.outLayout;
            for(uint32_t b=0;b<l.size();++b) {
                const auto& buf=abl->mBuffers[b];
                if(buf.mNumberChannels!=l[b] || !l[b] || !buf.mData || buf.mDataByteSize%(l[b]*4)) {
                    e.badBuffers.fetch_add(1); e.invalidated.store(true); return noErr;
                }
                const auto n=buf.mDataByteSize/(l[b]*4);
                if(frames==UINT32_MAX) frames=n;
                if(n!=frames) { e.badBuffers.fetch_add(1); e.invalidated.store(true); return noErr; }
            }
        }
        if(inputTime && outputTime &&
            (inputTime->mFlags & kAudioTimeStampSampleTimeValid) &&
            (outputTime->mFlags & kAudioTimeStampSampleTimeValid))
            e.ioTimestampGap.store(int64_t(std::llround(outputTime->mSampleTime-inputTime->mSampleTime)),std::memory_order_relaxed);
        e.callbackFrames.store(frames,std::memory_order_relaxed);
        for(const auto& route:e.routes) {
            const float* src=static_cast<const float*>(input->mBuffers[route.source.buffer].mData)+route.source.channel;
            float* dst=static_cast<float*>(output->mBuffers[route.dest.buffer].mData)+route.dest.channel;
            for(uint32_t f=0;f<frames;++f) dst[size_t(f)*route.dest.stride]=src[size_t(f)*route.source.stride];
        }
        if(inputTime && outputTime && (inputTime->mFlags&kAudioTimeStampHostTimeValid) &&
            (outputTime->mFlags&kAudioTimeStampHostTimeValid)) {
            const double inFrame=(double(inputTime->mHostTime)-double(e.timingAnchor))/e.ticksPerFrame;
            const double outFrame=(double(outputTime->mHostTime)-double(e.timingAnchor))/e.ticksPerFrame;
            auto& ia=e.timingInput[0];auto& ib=e.timingInput[1];
            auto& oa=e.timingOutput[0];auto& ob=e.timingOutput[1];
            auto a=static_cast<const float*>(input->mBuffers[ia.buffer].mData)+ia.channel;
            auto b=static_cast<const float*>(input->mBuffers[ib.buffer].mData)+ib.channel;
            auto x=static_cast<float*>(output->mBuffers[oa.buffer].mData)+oa.channel;
            auto y=static_cast<float*>(output->mBuffers[ob.buffer].mData)+ob.channel;
            for(uint32_t n=0;n<frames;++n)patch::encodeTiming(inFrame+n,x[n*oa.stride],y[n*ob.stride]);
            auto n=frames/2;double source,delay;
            if(patch::decodeTiming(a[n*ia.stride],b[n*ib.stride],outFrame+n,source) &&
                patch::timingDelay(outFrame+n,source,delay)) e.playbackDelay.store(delay,std::memory_order_relaxed);
        }
        e.cycles.fetch_add(1,std::memory_order_relaxed);
        return noErr;
    }
    void start(NSDictionary* d) {
        const auto c=config(d);
        if (currentConfig()!=c.encode()) throw std::runtime_error("Apply channel counts first, then reselect StudioPatch in the audio application.");
        auto timing=stringProperty(pluginID(),patch::TimingProperty);
        std::istringstream clock(timing.UTF8String ?: "");double previousDelay;
        if(!(clock>>timingAnchor>>ticksPerFrame>>previousDelay) || ticksPerFrame<=0)
            throw std::runtime_error("Install the latency-reporting driver before starting this service.");
        const auto buffer=[d[@"bufferFrames"] unsignedIntValue];
        if(buffer<32 || buffer>1024 || (buffer&(buffer-1))) throw std::runtime_error("Invalid buffer size");
        if(c.delay<buffer*2) throw std::runtime_error("The transport margin must be at least two I/O buffers.");
        NSArray* devices=d[@"devices"];
        if(![devices isKindOfClass:[NSArray class]] || devices.count==0) throw std::runtime_error("Select at least one physical audio interface.");
        NSMutableArray* subs=[NSMutableArray array];
        std::map<std::string,std::pair<uint32_t,uint32_t>> offsets;
        std::map<std::string,std::pair<uint32_t,uint32_t>> counts;
        std::vector<AudioDeviceID> hardware;
        uint32_t ins=0,outs=0;
        NSString* master=d[@"masterUID"];
        if(![master isKindOfClass:[NSString class]]) throw std::runtime_error("Select clock master");
        bool haveMaster=false;
        for(NSDictionary* member in devices) {
            NSString* uid=member[@"uid"];
            if(![uid isKindOfClass:[NSString class]] || [uid hasPrefix:@"se.studiopatch."])
                throw std::runtime_error("Invalid physical device");
            const std::string key=uid.UTF8String;
            if(offsets.count(key)) throw std::runtime_error("Duplicate device");
            const auto id=translate(uid);
            if(!id) throw std::runtime_error("A selected audio device is missing. Routing was not started.");
            if(get<UInt32>(id,kAudioDevicePropertyTransportType)==kAudioDeviceTransportTypeAggregate)
                throw std::runtime_error("Select the physical interfaces directly instead of an existing aggregate device.");
            const double rate=get<Float64>(id,kAudioDevicePropertyNominalSampleRate);
            if(std::abs(rate-c.rate)>0.1) throw std::runtime_error(std::string(uid.UTF8String)+
                " reports "+std::to_string(int(rate))+" Hz. Set both interfaces to the selected sample rate first.");
            if(!get<UInt32>(id,kAudioDevicePropertyDeviceIsAlive)) throw std::runtime_error("Device is offline");
            offsets[key]={ins,outs};
            auto ni=total(layout(id,kAudioObjectPropertyScopeInput));
            auto no=total(layout(id,kAudioObjectPropertyScopeOutput));
            counts[key]={ni,no}; ins+=ni; outs+=no; hardware.push_back(id);
            const bool primary=[uid isEqualToString:master]; haveMaster|=primary;
            [subs addObject:@{@kAudioSubDeviceUIDKey:uid,
                @kAudioSubDeviceDriftCompensationKey:@(!primary && [member[@"drift"] boolValue])}];
        }
        if(!haveMaster) throw std::runtime_error("The sync source must be one of the selected interfaces.");
        syncSource=translate(master);
        const auto bridgeInputOffset=ins,bridgeOutputOffset=outs;
        if(!translate(@(patch::BridgeUID))) throw std::runtime_error("Internal bridge is unavailable");
        [subs addObject:@{@kAudioSubDeviceUIDKey:@(patch::BridgeUID),@kAudioSubDeviceDriftCompensationKey:@YES}];
        NSDictionary* desc=@{@kAudioAggregateDeviceNameKey:@"StudioPatch LegacyEngine",
            @kAudioAggregateDeviceUIDKey:[@"se.studiopatch.engine." stringByAppendingString:NSUUID.UUID.UUIDString],
            @kAudioAggregateDeviceIsPrivateKey:@YES,@kAudioAggregateDeviceIsStackedKey:@NO,
            @kAudioAggregateDeviceMainSubDeviceKey:master,@kAudioAggregateDeviceSubDeviceListKey:subs};
        check(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)desc,&aggregate),"Create private audio aggregate");
        auto ba=address(kAudioDevicePropertyBufferFrameSize);
        check(AudioObjectSetPropertyData(aggregate,&ba,0,nullptr,sizeof(buffer),&buffer),"Set engine buffer");
        // Configuration publication is asynchronous. Bound the wait and validate the actual result.
        for(int attempt=0;attempt<40;++attempt) {
            inLayout=layout(aggregate,kAudioObjectPropertyScopeInput);
            outLayout=layout(aggregate,kAudioObjectPropertyScopeOutput);
            if(total(inLayout)==ins+c.outputs+patch::TimingChannels && total(outLayout)==outs+c.inputs+patch::TimingChannels) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(25));
        }
        if(total(inLayout)!=ins+c.outputs+patch::TimingChannels || total(outLayout)!=outs+c.inputs+patch::TimingChannels)
            throw std::runtime_error("Aggregate channel layout did not match; no routing was started");
        CFArrayRef full=get<CFArrayRef>(aggregate,kAudioAggregateDevicePropertyFullSubDeviceList);
        NSArray* actual=CFBridgingRelease(full);
        if(actual.count!=subs.count) throw std::runtime_error("Unexpected aggregate device order");
        for(NSUInteger i=0;i<actual.count;++i)
            if(![actual[i] isEqual:subs[i][@kAudioSubDeviceUIDKey]]) throw std::runtime_error("Unexpected aggregate device order");
        for(bool input:{true,false}) {
            auto scope=input?kAudioObjectPropertyScopeInput:kAudioObjectPropertyScopeOutput;
            for(auto stream:list<AudioStreamID>(aggregate,kAudioDevicePropertyStreams,scope)) {
                auto f=get<AudioStreamBasicDescription>(stream,kAudioStreamPropertyVirtualFormat);
                if(f.mFormatID!=kAudioFormatLinearPCM || !(f.mFormatFlags&kAudioFormatFlagIsFloat) ||
                    f.mBitsPerChannel!=32 || std::abs(f.mSampleRate-c.rate)>0.1)
                    throw std::runtime_error("LegacyEngine requires native Float32 PCM at the selected sample rate");
            }
        }
        const auto inputChannels=channels(inLayout),outputChannels=channels(outLayout);
        for(unsigned n=0;n<patch::TimingChannels;++n) {
            timingInput[n]=inputChannels.at(bridgeInputOffset+c.outputs+n);
            timingOutput[n]=outputChannels.at(bridgeOutputOffset+c.inputs+n);
        }
        std::set<uint32_t> usedOutputs;
        NSArray* captures=d[@"inputs"], *playbacks=d[@"outputs"];
        if(![captures isKindOfClass:[NSArray class]] || captures.count!=c.inputs ||
            ![playbacks isKindOfClass:[NSArray class]]) throw std::runtime_error("Invalid routing table");
        auto resolve=[&](NSDictionary* r,bool input)->uint32_t {
            NSString* uid=r[@"deviceUID"];
            if(![uid isKindOfClass:[NSString class]]) throw std::runtime_error("Invalid route UID");
            std::string key=uid.UTF8String;
            auto number=[r[@"channel"] longLongValue];
            if(!counts.count(key) || number<1 || uint64_t(number)>(input?counts[key].first:counts[key].second))
                throw std::runtime_error("A mapped hardware channel is missing or out of range.");
            return (input?offsets[key].first:offsets[key].second)+uint32_t(number-1);
        };
        for(uint32_t i=0;i<c.inputs;++i) {
            if(captures[i]==[NSNull null]) continue;
            auto source=resolve(captures[i],true);
            routes.push_back({inputChannels.at(source),outputChannels.at(bridgeOutputOffset+i)});
        }
        for(NSDictionary* r in playbacks) {
            const auto source=[r[@"virtualChannel"] longLongValue];
            if(source<1 || uint64_t(source)>c.outputs) throw std::runtime_error("Invalid From Computer channel");
            auto dest=resolve(r,false);
            if(!usedOutputs.insert(dest).second) throw std::runtime_error("Two routes target the same hardware output");
            routes.push_back({inputChannels.at(bridgeInputOffset+uint32_t(source-1)),outputChannels.at(dest)});
        }
        actualBuffer=get<UInt32>(aggregate,kAudioDevicePropertyBufferFrameSize);
        if(actualBuffer*2>c.delay) throw std::runtime_error("Hardware buffer is larger than the configured transport margin");
        for(auto id:hardware) {
            watch(id,kAudioDevicePropertyDeviceIsAlive);
            watch(id,kAudioDevicePropertyNominalSampleRate);
            watch(id,kAudioDevicePropertyStreamConfiguration,kAudioObjectPropertyScopeInput);
            watch(id,kAudioDevicePropertyStreamConfiguration,kAudioObjectPropertyScopeOutput);
        }
        watch(aggregate,kAudioDevicePropertyStreamConfiguration,kAudioObjectPropertyScopeInput);
        watch(aggregate,kAudioDevicePropertyStreamConfiguration,kAudioObjectPropertyScopeOutput);
        watch(aggregate,kAudioDevicePropertyBufferFrameSize);
        invalidated.store(false);
        check(AudioDeviceCreateIOProcID(aggregate,io,this,&proc),"Create audio callback");
        check(AudioDeviceStart(aggregate,proc),"Start audio; allow microphone access if macOS requests it");
    }
};
#include "DirectEngine.hpp"
using Engine=DirectEngine;
std::mutex control;
std::unique_ptr<Engine> engine;
void startLatencyUpdates() {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        // Independent of the two-second UI inventory timer. Property publication
        // stays off the audio thread and follows slow bridge clock drift.
        auto queue=dispatch_queue_create("se.studiopatch.latency",DISPATCH_QUEUE_SERIAL);
        static dispatch_source_t timer;
        timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
        dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),100*NSEC_PER_MSEC,10*NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer,^{
            std::lock_guard lock(control);
            if(engine)try {engine->publishLatency();}catch(const std::exception&) {}
        });
        dispatch_resume(timer);
    });
}
}

extern "C" char* SPInventory() { @autoreleasepool {
    try {
        NSMutableArray* devices=[NSMutableArray array];
        for(auto id:list<AudioDeviceID>(kAudioObjectSystemObject,kAudioHardwarePropertyDevices)) {
            try { @try {
                // Some drivers retain disconnected devices in the HAL device list.
                if(!get<UInt32>(id,kAudioDevicePropertyDeviceIsAlive)) continue;
                NSString* uid=stringProperty(id,kAudioDevicePropertyDeviceUID);
                NSString* name=stringProperty(id,kAudioObjectPropertyName);
                auto ni=total(layout(id,kAudioObjectPropertyScopeInput)),no=total(layout(id,kAudioObjectPropertyScopeOutput));
                NSMutableArray* inNames=[NSMutableArray array],*outNames=[NSMutableArray array];
                for(bool input:{true,false}) for(UInt32 c=1;c<=(input?ni:no);++c) {
                    NSString* label=stringProperty(id,kAudioObjectPropertyElementName,
                        input?kAudioObjectPropertyScopeInput:kAudioObjectPropertyScopeOutput,c);
                    [(input?inNames:outNames) addObject:label.length?label:[NSString stringWithFormat:@"Channel %u",c]];
                }
                NSMutableArray* rates=[NSMutableArray array];
                try {
                    std::set<double> values;
                    for(auto range:list<AudioValueRange>(id,kAudioDevicePropertyAvailableNominalSampleRates)) {
                        values.insert(range.mMinimum); values.insert(range.mMaximum);
                        for(auto common:{8000,11025,16000,22050,32000,44100,48000,64000,88200,96000,176400,192000,352800,384000})
                            if(common>=range.mMinimum && common<=range.mMaximum) values.insert(common);
                    }
                    for(auto rate:values) if(rate>=8000 && rate<=384000) [rates addObject:@(rate)];
                } catch(...) { }
                [devices addObject:@{@"id":@(id),@"uid":uid,@"name":name,@"inputs":@(ni),@"outputs":@(no),
                    @"sampleRate":@(get<Float64>(id,kAudioDevicePropertyNominalSampleRate)),
                    @"aggregate":@(get<UInt32>(id,kAudioDevicePropertyTransportType)==kAudioDeviceTransportTypeAggregate),
                    @"inputNames":inNames,@"outputNames":outNames,@"sampleRates":rates}];
            } @catch(NSException* exception) { (void)exception; }
            } catch(const std::exception&) {
                // A device can disappear between enumeration and its property reads.
                // Preserve the rest of the inventory instead of publishing stale devices.
            }
        }
        bool installed=false;
        std::string config;
        // Driver health must not gate hardware discovery, especially during hot unplug.
        try { installed=translate(@(patch::DeviceUID))!=0; } catch(const std::exception&) { }
        if(installed) { try { config=currentConfig(); } catch(const std::exception&) { } }
        return response(@{@"devices":devices,@"driverInstalled":@(installed),
            @"driverConfig":@(config.c_str())});
    } catch(const std::exception& e) { return failure(e); }
} }
extern "C" char* SPFollowMaster(const char* raw) { @autoreleasepool {
    std::lock_guard lock(control);
    bool attempted=false;
    try {
        if(engine) throw std::runtime_error("Stop routing before changing the sample rate.");
        NSDictionary* d=json(raw);
        NSString* uid=d[@"masterUID"];
        NSArray* members=d[@"devices"];
        if(![uid isKindOfClass:[NSString class]] || ![members isKindOfClass:[NSArray class]])
            throw std::runtime_error("Select a sync source and audio interfaces first.");
        auto master=translate(uid);
        if(!master) throw std::runtime_error("Sync source is missing.");
        const double target=get<Float64>(master,kAudioDevicePropertyNominalSampleRate);
        if(target!=44100 && target!=48000 && target!=88200 && target!=96000)
            throw std::runtime_error("The virtual device does not support the sync source's sample rate.");
        std::vector<patch::RateDevice> devices;
        std::set<AudioDeviceID> seen;
        for(NSDictionary* member in members) {
            NSString* memberUID=member[@"uid"];
            if(![memberUID isKindOfClass:[NSString class]] || [memberUID hasPrefix:@"se.studiopatch."])
                throw std::runtime_error("Select physical audio interfaces for synchronization.");
            auto id=translate(memberUID);
            if(!id || !seen.insert(id).second) throw std::runtime_error("A selected interface is missing or listed twice.");
            auto transport=get<UInt32>(id,kAudioDevicePropertyTransportType);
            if(transport==kAudioDeviceTransportTypeAggregate || transport==kAudioDeviceTransportTypeVirtual)
                throw std::runtime_error("Follow sync source applies to physical interfaces, not virtual or aggregate devices.");
            if(!get<UInt32>(id,kAudioDevicePropertyDeviceIsAlive)) throw std::runtime_error("A selected interface is disconnected.");
            patch::RateDevice dev{id,stringProperty(id,kAudioObjectPropertyName).UTF8String,
                get<Float64>(id,kAudioDevicePropertyNominalSampleRate),false,false,{}};
            dev.syncLocked=[member[@"syncLocked"] boolValue];
            if(id!=master && dev.syncLocked && !patch::sameRate(dev.rate,target)) {
                auto a=address(kAudioDevicePropertyNominalSampleRate); Boolean writable=false;
                check(AudioObjectIsPropertySettable(id,&a,&writable),"Check sample rate control");
                dev.writable=writable;
                dev.running=get<UInt32>(id,kAudioDevicePropertyDeviceIsRunningSomewhere)!=0;
                for(auto range:list<AudioValueRange>(id,kAudioDevicePropertyAvailableNominalSampleRates))
                    dev.supported.emplace_back(range.mMinimum,range.mMaximum);
            }
            devices.push_back(std::move(dev));
        }
        patch::applyRates(devices,master,target,
            [](uint32_t id){return get<Float64>(id,kAudioDevicePropertyNominalSampleRate);},
            [&](uint32_t id,double rate){
                if(get<UInt32>(id,kAudioDevicePropertyDeviceIsRunningSomewhere))
                    throw std::runtime_error("Another application started using an interface. The sample rate change was cancelled.");
                attempted=true;
                auto a=address(kAudioDevicePropertyNominalSampleRate);
                check(AudioObjectSetPropertyData(id,&a,0,nullptr,sizeof(rate),&rate),"The driver rejected the sample rate change");
            },[]{std::this_thread::sleep_for(std::chrono::milliseconds(25));});
        return response(@{@"ok":@YES,@"sampleRate":@(target)});
    } catch(const std::exception& e) {
        std::string message=e.what();
        if(attempted) message+=" An interface may already have changed sample rate. Check the interface status; changes are not rolled back automatically.";
        return response(@{@"error":@(message.c_str())});
    }
} }
extern "C" char* SPSetChannelNames(const char* raw) { @autoreleasepool {
    std::lock_guard lock(control);
    try {
        auto d=json(raw);
        patch::ChannelNames names;
        for (bool input : {true,false}) {
            id values=d[input ? @"inputs" : @"outputs"];
            if (![values isKindOfClass:[NSArray class]] || [values count]>patch::MaxChannels)
                throw std::runtime_error("Invalid channel name list");
            auto& list=input ? names.inputs : names.outputs;
            for (id value in values) {
                if (![value isKindOfClass:[NSString class]]) throw std::runtime_error("Invalid channel name");
                NSData* bytes=[value dataUsingEncoding:NSUTF8StringEncoding];
                list.emplace_back(static_cast<const char*>(bytes.bytes),bytes.length);
            }
        }
        auto encoded=names.encode();
        const auto c=patch::Config::parse(currentConfig());
        // Width edits are pending until Apply; never assign them to the old layout.
        if (names.inputs.size()!=c.inputs || names.outputs.size()!=c.outputs)
            return response(@{@"pending":@YES});
        auto id=pluginID(); auto a=address(patch::NamesProperty);
        if (!AudioObjectHasProperty(id,&a)) throw std::runtime_error("The installed StudioPatch driver needs an update to support channel names.");
        CFStringRef value=CFStringCreateWithCString(nullptr,encoded.c_str(),kCFStringEncodingUTF8);
        auto result=AudioObjectSetPropertyData(id,&a,0,nullptr,sizeof(value),&value);
        CFRelease(value);
        check(result,"Could not update the StudioPatch device's channel names");
        return response(@{@"ok":@YES});
    } catch(const std::exception& e) { return failure(e); }
} }
extern "C" char* SPConfigure(const char* raw) { @autoreleasepool {
    std::lock_guard lock(control);
    try {
        if(engine) throw std::runtime_error("Stop routing before changing channel counts.");
        auto c=config(json(raw));
        auto id=pluginID(); auto a=address(patch::ConfigProperty);
        CFStringRef value=CFStringCreateWithCString(nullptr,c.encode().c_str(),kCFStringEncodingUTF8);
        auto result=AudioObjectSetPropertyData(id,&a,0,nullptr,sizeof(value),&value);
        CFRelease(value);
        check(result,"Request virtual device configuration");
        auto ready=[&] {
            auto property=address(patch::ReadyProperty); CFStringRef text=nullptr; UInt32 size=sizeof(text);
            auto err=AudioObjectGetPropertyData(id,&property,0,nullptr,&size,&text);
            bool value=!err && text && CFStringGetIntValue(text)==1;
            if(text) CFRelease(text); return value;
        };
        for(int i=0;i<200 && (currentConfig()!=c.encode() || !ready());++i) std::this_thread::sleep_for(std::chrono::milliseconds(25));
        if(currentConfig()!=c.encode() || !ready()) throw std::runtime_error("Core Audio did not confirm the new configuration within five seconds. Audio is muted.");
        return response(@{@"ok":@YES});
    } catch(const std::exception& e) { return failure(e); }
} }
extern "C" char* SPStart(const char* raw) { @autoreleasepool {
    std::lock_guard lock(control);
    try {
        if(engine) throw std::runtime_error("Routing is already active");
        auto next=std::make_unique<Engine>(); next->start(json(raw)); engine=std::move(next);
        startLatencyUpdates();
        return response(@{@"ok":@YES});
    } catch(const std::exception& e) { return failure(e); }
} }
extern "C" char* SPStatus() { @autoreleasepool {
    std::lock_guard lock(control);
    NSString* diagnostics=@"unavailable";
    if(engine)try {
        engine->publishLatency();auto& state=*engine->memory->data;
        auto values=@{@"transport":@"direct shared memory",@"bufferFrames":@(engine->actualBuffer),
            @"inputPadding":@(state.inputPadding),@"outputPadding":@(state.padding),@"captureMisses":@(state.captureMisses.load()),
            @"playbackMisses":@(state.playbackMisses.load()),@"reportedLatency":stringProperty(pluginID(),patch::LatencyProperty),
            @"inputSafety":@(engine->masterInputSafety),@"outputSafety":@(engine->masterOutputSafety)};
        diagnostics=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:values options:0 error:nil] encoding:NSUTF8StringEncoding];
    }catch(const std::exception& e){diagnostics=[@"unavailable: " stringByAppendingString:@(e.what())];}
    return response(@{@"running":@(engine!=nullptr),@"invalidated":@(engine && engine->invalidated.load()),
        @"cycles":@(engine?engine->cycles.load():0),@"badBuffers":@(engine?engine->badBuffers.load():0),
        @"latencyDiagnostics":diagnostics ?: @"unavailable",@"bufferFrames":@(engine?engine->actualBuffer:0)});
} }
extern "C" void SPStop() { std::lock_guard lock(control); engine.reset(); }
extern "C" void SPFree(char* s) { free(s); }

extern "C" char* SPRuntimeRates(const char* raw) { @autoreleasepool {
    std::lock_guard lock(control);
    try {
        auto master=translate(json(raw)[@"masterUID"]);
        if(!master) throw std::runtime_error("Sync source is missing");
        auto ranges=list<AudioValueRange>(master,kAudioDevicePropertyAvailableNominalSampleRates);
        std::vector<std::pair<double,double>> publishedRanges;
        for(auto r:ranges) {
            auto lo=std::max(8000.0,r.mMinimum),hi=std::min(384000.0,r.mMaximum);
            if(lo<=hi) publishedRanges.emplace_back(lo,hi);
        }
        const auto text=patch::encodeRateRanges(publishedRanges);
        auto id=pluginID(); auto a=address(patch::RatesProperty);
        if(!AudioObjectHasProperty(id,&a)) throw std::runtime_error("Core Audio does not expose the driver's sample rate control (sprt). Check the driver version and that it was loaded after restarting.");
        static std::string last;
        if(last!=text) {
            CFStringRef v=CFStringCreateWithCString(nullptr,text.c_str(),kCFStringEncodingUTF8);
            auto err=AudioObjectSetPropertyData(id,&a,0,nullptr,sizeof(v),&v); CFRelease(v);
            check(err,"Publish sync source sample rates"); last=text;
        }
        a=address(patch::RateRequestProperty); CFStringRef v=nullptr; UInt32 size=sizeof(v);
        check(AudioObjectGetPropertyData(id,&a,0,nullptr,&size,&v),"Read sample rate request");
        double requested=v?CFStringGetDoubleValue(v):0; if(v) CFRelease(v);
        return response(@{@"requested":@(requested),@"masterRate":@(get<Float64>(master,kAudioDevicePropertyNominalSampleRate))});
    } catch(const std::exception& e) { return failure(e); }
} }
extern "C" char* SPSetHardwareRate(const char* raw) { @autoreleasepool {
    std::lock_guard lock(control);
    try {
        engine.reset();
        auto d=json(raw); auto target=[d[@"sampleRate"] doubleValue];
        auto master=translate(d[@"masterUID"]);
        std::vector<AudioDeviceID> members;
        for(NSDictionary* m in d[@"devices"]) {
            auto id=translate(m[@"uid"]); if(!id) throw std::runtime_error("A selected audio interface is missing.");
            if(id!=master && ![m[@"syncLocked"] boolValue]) continue;
            auto ranges=list<AudioValueRange>(id,kAudioDevicePropertyAvailableNominalSampleRates);
            if(std::none_of(ranges.begin(),ranges.end(),[&](auto r){return target>=r.mMinimum && target<=r.mMaximum;}))
                throw std::runtime_error(std::string(stringProperty(id,kAudioObjectPropertyName).UTF8String)+" does not support the selected sample rate.");
            members.push_back(id);
        }
        if(std::find(members.begin(),members.end(),master)==members.end()) throw std::runtime_error("Choose a sync source from the selected interfaces.");
        std::stable_sort(members.begin(),members.end(),[&](auto a,auto b){return a==master && b!=master;});
        for(auto id:members) {
            if(patch::sameRate(get<Float64>(id,kAudioDevicePropertyNominalSampleRate),target)) continue;
            auto a=address(kAudioDevicePropertyNominalSampleRate);
            check(AudioObjectSetPropertyData(id,&a,0,nullptr,sizeof(target),&target),"The interface rejected the sample rate change");
            for(int i=0;i<80 && !patch::sameRate(get<Float64>(id,kAudioDevicePropertyNominalSampleRate),target);++i)
                std::this_thread::sleep_for(std::chrono::milliseconds(25));
            if(!patch::sameRate(get<Float64>(id,kAudioDevicePropertyNominalSampleRate),target)) throw std::runtime_error("The interface did not confirm the sample rate change.");
        }
        // A non-following slave may still track the master through its digital clock.
        // Verify before starting the aggregate; never write to an unlocked device.
        for(NSDictionary* m in d[@"devices"]) {
            auto id=translate(m[@"uid"]);
            if(!patch::sameRate(get<Float64>(id,kAudioDevicePropertyNominalSampleRate),target))
                throw std::runtime_error(std::string(stringProperty(id,kAudioObjectPropertyName).UTF8String)+" has a different sample rate. Lock its sample rate sync or change the interface's sample rate manually.");
        }
        return response(@{@"ok":@YES});
    } catch(const std::exception& e) { return failure(e); }
} }
extern "C" char* SPAcknowledgeRate(const char* raw) { @autoreleasepool {
    try {
        std::lock_guard lock(control);
        auto a=address(patch::RateRequestProperty);
        auto text=std::to_string([json(raw)[@"ack"] doubleValue]);
        CFStringRef v=CFStringCreateWithCString(nullptr,text.c_str(),kCFStringEncodingUTF8);
        auto err=AudioObjectSetPropertyData(pluginID(),&a,0,nullptr,sizeof(v),&v); CFRelease(v);
        check(err,"Acknowledge sample rate request"); return response(@{@"ok":@YES});
    } catch(const std::exception& e) { return failure(e); }
} }
