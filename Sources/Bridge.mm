#include "Bridge.h"
#include "Core.hpp"
#include "Latency.hpp"
#include "SharedTransport.hpp"
#include "RouteSlot.hpp"
#include "ChannelNames.hpp"
#include "RateSync.hpp"
#include "RateWire.hpp"
#import <Foundation/Foundation.h>
#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <algorithm>
#include <mutex>
#include <set>
#include <thread>
#include <vector>

namespace {
AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal, UInt32 element = 0) {
    return {selector,scope,element};
}
struct HALError : std::runtime_error {
    OSStatus status;
    HALError(OSStatus value,const std::string& what):std::runtime_error(what+" (Core Audio "+std::to_string(value)+")"),status(value){}
};
void check(OSStatus status, const std::string& what) {
    if (status) throw HALError(status,what);
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
AudioObjectID pluginID(decltype(&AudioObjectGetPropertyData) read=AudioObjectGetPropertyData,
    decltype(&AudioObjectGetPropertyDataSize) readSize=AudioObjectGetPropertyDataSize) {
    CFStringRef bundle=CFSTR("se.studiopatch.driver");
    AudioObjectID id=0; UInt32 size=sizeof(id);
    auto a=address(kAudioHardwarePropertyTranslateBundleIDToPlugIn);
    auto status=read(kAudioObjectSystemObject,&a,sizeof(bundle),&bundle,&size,&id);
    if(!status && id)return id;
    // A stale unrelated plug-in can make HAL's bundle translation fail.
    // Query each current plug-in independently; never cache IDs across hotplug.
    a=address(kAudioHardwarePropertyPlugInList);size=0;
    auto listStatus=readSize(kAudioObjectSystemObject,&a,0,nullptr,&size);
    if(!listStatus && size && size<=4096*sizeof(AudioObjectID) && size%sizeof(AudioObjectID)==0) {
        std::vector<AudioObjectID> ids(size/sizeof(AudioObjectID));auto capacity=size;
        listStatus=read(kAudioObjectSystemObject,&a,0,nullptr,&size,ids.data());
        if(!listStatus && size<=capacity && size%sizeof(AudioObjectID)==0) {
            for(size_t i=0;i<size/sizeof(AudioObjectID);++i) {
                auto key=address(kAudioPlugInPropertyBundleID);CFStringRef name=nullptr;UInt32 bytes=sizeof(name);
                auto err=read(ids[i],&key,0,nullptr,&bytes,&name);
                bool match=!err && name && CFGetTypeID(name)==CFStringGetTypeID() && CFEqual(name,bundle);
                if(name)CFRelease(name);
                if(match)return ids[i];
            }
        }
    }
    check(status,"Find the StudioPatch driver");
    check(listStatus,"List audio plug-ins");
    throw std::runtime_error("The StudioPatch driver is not installed and loaded.");
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
char* failure(const std::exception& e) {
    if(auto hal=dynamic_cast<const HALError*>(&e))return response(@{@"error":@(e.what()),@"coreAudioStatus":@(hal->status)});
    return response(@{@"error":@(e.what())});
}
patch::Config config(NSDictionary* d) {
    auto integer = [&](NSString* key)->std::string {
        id v=d[key];
        if (![v isKindOfClass:[NSNumber class]] || [v doubleValue] != [v longLongValue])
            throw std::runtime_error("Invalid numeric configuration");
        return std::to_string([v longLongValue]);
    };
    auto c=patch::Config::parse("1 "+integer(@"inputCount")+" "+integer(@"outputCount")+" "+
        integer(@"sampleRate")+" 256");
    if([d[@"virtualDeviceUID"] isKindOfClass:NSString.class]) c.uid=[d[@"virtualDeviceUID"] UTF8String];
    return patch::Config::parse(c.encode());
}
std::string currentConfig() {
    auto id=pluginID(); auto a=address(patch::ConfigProperty);
    CFStringRef value=nullptr; UInt32 size=sizeof(value);
    check(AudioObjectGetPropertyData(id,&a,0,nullptr,&size,&value),"Read StudioPatch configuration");
    if (!value) throw std::runtime_error("The StudioPatch driver returned an empty configuration.");
    NSString* text=CFBridgingRelease(value);
    return text.UTF8String;
}

// The broker authenticates this console-user process and registers its PID for
// this generation. All callers run on the serialized service control queue.
template<class Connect> void refreshControllerClaim(std::shared_ptr<patch::SharedMapping>& claim,
    uint64_t generation,Connect connect) {
    if(!claim || claim->data->generation!=generation || claim->data->controllerPID.load()!=getpid())
        claim=connect();
}
void authorizeWrites() {
    auto text=stringProperty(pluginID(),patch::DirectProperty);
    auto generation=std::strtoull(text.UTF8String,nullptr,10);
    if(!generation)throw std::runtime_error("StudioPatch transport is connecting; waiting for broker recovery.");
    static std::shared_ptr<patch::SharedMapping> claim;
    refreshControllerClaim(claim,generation,[&]{
        return patch::SharedMapping::connect(generation,patch::Config::parse(currentConfig()),false);
    });
}

struct Channel { uint32_t buffer, channel, stride; };
std::vector<Channel> channels(const std::vector<UInt32>& l) {
    std::vector<Channel> result;
    for(uint32_t b=0;b<l.size();++b) for(uint32_t c=0;c<l[b];++c) result.push_back({b,c,l[b]});
    return result;
}
#include "DirectEngine.hpp"
using Engine=DirectEngine;
std::mutex control;
std::unique_ptr<Engine> engine;

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
        NSNumber* driverError=nil;
        try { config=currentConfig(); installed=true; }
        catch(const HALError& e) { driverError=@(e.status); }
        catch(const std::exception&) { }
        if(installed) {
            try { config=currentConfig(); }
            catch(const HALError& e) { driverError=@(e.status); }
            catch(const std::exception&) { }
        }
        // Preserve hardware discovery, but do not turn a stale HAL object into
        // a generic "not installed" state that bypasses bounded recovery.
        return response(@{@"devices":devices,@"driverInstalled":@(installed),
            @"driverErrorStatus":driverError ?: (id)[NSNull null],@"driverConfig":@(config.c_str())});
    } catch(const std::exception& e) { return failure(e); }
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
        authorizeWrites();
        const auto c=patch::Config::parse(currentConfig());
        if(d[@"uid"] && ![d[@"uid"] isEqual:@(c.uid.c_str())]) return response(@{@"pending":@YES});
        // Width edits are pending until Apply; never assign them to the old layout.
        if (names.inputs.size()!=c.inputs || names.outputs.size()!=c.outputs)
            return response(@{@"pending":@YES});
        auto id=pluginID(); auto a=address(patch::NamesProperty);
        if (!AudioObjectHasProperty(id,&a)) throw std::runtime_error("The installed StudioPatch driver needs an update to support channel names.");
        CFStringRef value=CFStringCreateWithCString(nullptr,encoded.c_str(),kCFStringEncodingUTF8);
        auto result=AudioObjectSetPropertyData(id,&a,0,nullptr,sizeof(value),&value);
        CFRelease(value);
        check(result,"Could not update the StudioPatch device's channel names");
        NSString* displayName=d[@"deviceName"];
        if([displayName isKindOfClass:NSString.class] && ![stringProperty(id,patch::DeviceNameProperty) isEqual:displayName]) {
            auto property=address(patch::DeviceNameProperty); CFStringRef name=(__bridge CFStringRef)displayName;
            check(AudioObjectSetPropertyData(id,&property,0,nullptr,sizeof(name),&name),"Update StudioPatch device name");
        }
        return response(@{@"ok":@YES});
    } catch(const std::exception& e) { return failure(e); }
} }
// HAL owns and persists element-name aliases. Never route these writes through
// the driver's default-name property or write names on a physical interface.
extern "C" char* SPReadChannelLabels(const char* uid) { @autoreleasepool {
    std::lock_guard lock(control);
    try {
        auto c=patch::Config::parse(currentConfig());
        if(!uid || c.uid!=uid)throw std::runtime_error("The preset device is still changing. Try again when it is available.");
        auto device=translate(@(uid));
        if(!device)throw std::runtime_error("The preset device is unavailable.");
        NSString* rawDefaults=stringProperty(pluginID(),patch::NamesProperty);
        auto defaults=patch::ChannelNames::parse(rawDefaults.UTF8String);
        if(defaults.inputs.size()!=c.inputs || defaults.outputs.size()!=c.outputs)
            throw std::runtime_error("The preset channel names are still changing.");
        NSMutableArray* inputs=[NSMutableArray array]; NSMutableArray* outputs=[NSMutableArray array];
        NSMutableArray* baseInputs=[NSMutableArray array]; NSMutableArray* baseOutputs=[NSMutableArray array];
        for(bool input:{true,false}) {
            auto& names=input?defaults.inputs:defaults.outputs;
            for(size_t i=0;i<names.size();++i) {
                NSString* base=names[i].empty() ? [NSString stringWithFormat:@"%s %zu",input?"To Computer":"From Computer",i+1] : @(names[i].c_str());
                [(input?baseInputs:baseOutputs) addObject:base];
                [(input?inputs:outputs) addObject:stringProperty(device,kAudioObjectPropertyElementName,
                    input?kAudioObjectPropertyScopeInput:kAudioObjectPropertyScopeOutput,UInt32(i+1))];
            }
        }
        // A concurrent routing/default-name update must not be mistaken for
        // manual overrides and copied back as sticky aliases.
        if(currentConfig()!=c.encode() || translate(@(uid))!=device ||
           ![rawDefaults isEqual:stringProperty(pluginID(),patch::NamesProperty)])
            throw std::runtime_error("The preset or its routing names changed while reading labels. Try again.");
        return response(@{@"uid":@(uid),@"inputs":inputs,@"outputs":outputs,@"defaultInputs":baseInputs,@"defaultOutputs":baseOutputs});
    } catch(const std::exception& e) { return failure(e); }
} }
extern "C" char* SPSetChannelLabel(const char* raw) { @autoreleasepool {
    std::lock_guard lock(control);
    try {
        auto d=json(raw);auto c=patch::Config::parse(currentConfig());
        if(![d[@"uid"] isEqual:@(c.uid.c_str())])throw std::runtime_error("The preset changed. The label was not written.");
        NSString* direction=d[@"direction"];NSString* text=d[@"text"];
        if(![direction isEqual:@"input"] && ![direction isEqual:@"output"])throw std::runtime_error("Invalid channel direction.");
        bool input=[direction isEqual:@"input"];auto channel=[d[@"channel"] unsignedIntValue];
        if(![text isKindOfClass:NSString.class] || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>4096 ||
            channel<1 || channel>(input?c.inputs:c.outputs))throw std::runtime_error("Invalid channel label.");
        auto device=translate(@(c.uid.c_str()));
        if(!device)throw std::runtime_error("The preset device is unavailable.");
        auto a=address(kAudioObjectPropertyElementName,input?kAudioObjectPropertyScopeInput:kAudioObjectPropertyScopeOutput,channel);
        CFStringRef value=(__bridge CFStringRef)text;
        check(AudioObjectSetPropertyData(device,&a,0,nullptr,sizeof(value),&value),"Update channel label in Core Audio");
        if(currentConfig()!=c.encode() || translate(@(c.uid.c_str()))!=device)throw std::runtime_error("The preset changed while writing. Check its labels before continuing.");
        return response(@{@"ok":@YES});
    } catch(const std::exception& e) { return failure(e); }
} }
// Check control access before an intentional hardware rate write. The actual
// configuration still executes while the current engine runs; this check is
// never a reason to stop it and does not guarantee the next call will succeed.
extern "C" char* SPPrepareChange(const char* raw) { @autoreleasepool {
    std::lock_guard lock(control);
    try { config(json(raw)); authorizeWrites(); return response(@{@"ok":@YES}); }
    catch(const std::exception& e) { return failure(e); }
} }
// One outstanding HAL request. Keep its identity across slow confirmations and
// failed control reads: retrying a query must not submit another configuration.
namespace {
struct ConfigurationChange {
    enum Result { Pending, Applied, Rejected };
    std::string pending;
    uint64_t previousGeneration=0;
    static uint64_t generation(AudioObjectID id) {
        auto text=stringProperty(id,patch::DirectProperty);
        auto value=std::strtoull(text.UTF8String,nullptr,10);
        if(!value)throw std::runtime_error("The direct transport generation is unavailable.");
        return value;
    }
    Result step(const patch::Config& wanted,void (*authorize)()=authorizeWrites) {
        auto id=pluginID();
        if(pending.empty()) {
            authorize();
            previousGeneration=generation(id);
            auto a=address(patch::ConfigProperty);
            CFStringRef value=CFStringCreateWithCString(nullptr,wanted.encode().c_str(),kCFStringEncodingUTF8);
            auto result=AudioObjectSetPropertyData(id,&a,0,nullptr,sizeof(value),&value);
            CFRelease(value);
            check(result,"Request virtual device configuration");
            pending=wanted.encode();
        }
        auto ready=stringProperty(id,patch::ReadyProperty);
        if(![ready isEqual:@"0"] && ![ready isEqual:@"1"])throw std::runtime_error("The configuration status is unavailable.");
        if([ready isEqual:@"0"])return Pending;
        auto current=generation(id);
        if(current==previousGeneration) {
            bool same=pending==wanted.encode();pending.clear();
            return same?Rejected:Pending;
        }
        if(currentConfig()!=pending)throw std::runtime_error("The driver configuration changed while applying the request.");
        // Establish the new mapping/claim before releasing the old engine.
        authorize();
        bool same=pending==wanted.encode();pending.clear();
        return same?Applied:Pending;
    }
};
ConfigurationChange configurationChange;
}
extern "C" char* SPConfigure(const char* raw) { @autoreleasepool {
    std::lock_guard lock(control);
    try {
        auto result=configurationChange.step(config(json(raw)));
        return response(@{@"ok":@(result==ConfigurationChange::Applied),
            @"pending":@(result==ConfigurationChange::Pending),@"rejected":@(result==ConfigurationChange::Rejected)});
    } catch(const std::exception& e) {
        return response(@{@"ok":@NO,@"pending":@(!configurationChange.pending.empty()),@"failure":@(e.what())});
    }
} }
extern "C" char* SPUpdateRouting(const char* raw) { @autoreleasepool {
    std::lock_guard lock(control);
    try{return response(@{@"applied":@(engine && engine->updateRouting(json(raw)))});}
    catch(const std::exception& e){return failure(e);}
} }
// Inventory omits a device whose metadata could not be read. Only the UID
// lookup and the alive flag decide that hardware is physically gone; a failed
// read is not evidence of disconnection.
extern "C" char* SPMissingDevices(const char* raw) { @autoreleasepool {
    std::lock_guard lock(control);
    try {
        NSMutableArray* missing=[NSMutableArray array];
        for(NSString* uid in json(raw)[@"uids"]) {
            if(![uid isKindOfClass:NSString.class])continue;
            CFStringRef cf=(__bridge CFStringRef)uid;AudioDeviceID id=0;UInt32 size=sizeof(id);
            auto a=address(kAudioHardwarePropertyTranslateUIDToDevice);
            if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(cf),&cf,&size,&id))continue;
            UInt32 alive=1;size=sizeof(alive);a=address(kAudioDevicePropertyDeviceIsAlive);
            if(!id || (!AudioObjectGetPropertyData(id,&a,0,nullptr,&size,&alive) && !alive))[missing addObject:uid];
        }
        return response(@{@"missing":missing});
    } catch(const std::exception& e) { return failure(e); }
} }
extern "C" char* SPSetDeviceAvailable(const char* raw) { @autoreleasepool {
    std::lock_guard lock(control);
    // Retain an accepted change across a HAL enumeration timeout, so a later
    // confirmed retry still emits exactly one notification.
    static std::string pendingUID;
    static bool pendingAvailable=false;
    try {
        auto request=json(raw);
        const bool available=[request[@"available"] boolValue];
        auto id=pluginID();auto a=address(patch::AvailableProperty);
        if(!AudioObjectHasProperty(id,&a))throw std::runtime_error("The StudioPatch driver needs an update to support device availability.");
        const auto c=patch::Config::parse(currentConfig());
        if(available && ![request[@"uid"] isEqual:@(c.uid.c_str())])throw std::runtime_error("The preset changed before publishing its device.");
        NSString* state=CFBridgingRelease(get<CFStringRef>(id,patch::AvailableProperty));
        if(![state isEqual:@"0"] && ![state isEqual:@"1"])throw std::runtime_error("The driver returned an invalid availability state.");
        const bool before=[state isEqual:@"1"];
        NSString* name=CFBridgingRelease(get<CFStringRef>(id,patch::DeviceNameProperty));
        if(!name.length)name=@(c.uid.c_str());
        if(available && !before) {
            patch::ClockReader clock;patch::ClockSample sample;
            if(!engine || !engine->memory->data->active.load() || !clock.read(*engine->memory->data,sample))
                throw std::runtime_error("Waiting for the hardware clock before publishing the StudioPatch device.");
        }
        if(before!=available) {
            authorizeWrites();
            CFStringRef value=available?CFSTR("1"):CFSTR("0");
            check(AudioObjectSetPropertyData(id,&a,0,nullptr,sizeof(value),&value),"Change StudioPatch device availability");
            pendingUID=c.uid;pendingAvailable=available;
        }
        if(!available)configurationChange.pending.clear();
        // Host property notifications are asynchronous. Confirm the public HAL
        // list before telling the user that the device has gone/returned.
        bool confirmed=false;
        for(int attempt=0;attempt<100;++attempt) {
            auto devices=list<AudioDeviceID>(kAudioObjectSystemObject,kAudioHardwarePropertyDevices);
            auto device=translate(@(c.uid.c_str()));
            bool listed=device && std::find(devices.begin(),devices.end(),device)!=devices.end();
            confirmed=available ? listed && get<UInt32>(device,kAudioDevicePropertyDeviceIsAlive) : !listed;
            if(confirmed)break;
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
        if(!confirmed)throw std::runtime_error("Core Audio has not confirmed the StudioPatch device's availability.");
        const bool changed=pendingUID==c.uid && pendingAvailable==available;
        pendingUID.clear();
        return response(@{@"changed":@(changed),@"uid":@(c.uid.c_str()),@"deviceName":name});
    } catch(const std::exception& e) { return failure(e); }
} }
extern "C" char* SPStart(const char* raw) { @autoreleasepool {
    std::lock_guard lock(control);
    try {
        if(engine) throw std::runtime_error("Routing is already active");
        auto next=std::make_unique<Engine>(); next->start(json(raw)); engine=std::move(next);
        return response(@{@"ok":@YES});
    } catch(const std::exception& e) { return failure(e); }
} }
extern "C" char* SPStatus() { @autoreleasepool {
    std::lock_guard lock(control);
    NSString* diagnostics=@"unavailable";
    if(engine)try {
        auto& state=*engine->memory->data;
        auto phase=[](const patch::PhaseMeter& p)->NSDictionary* {
            NSMutableArray* bins=[NSMutableArray array];for(auto& b:p.histogram)[bins addObject:@(b.load())];
            return @{@"mode":@"projected containing hardware cycle",@"exactPairs":@(p.exactPairs.load()),@"maximumProjectionFrames":@(p.maximumProjectionFrames.load()),@"pairs":@(p.pairs.load()),@"serviceRecords":@(p.service.count.load()),@"clientRecords":@(p.client.count.load()),
                @"minimumTicks":@(p.minimumTicks.load()),@"maximumTicks":@(p.maximumTicks.load()),@"histogram":bins};
        };
        auto histogram=[](const patch::MarginStats& stats)->NSArray* {
            NSMutableArray* result=[NSMutableArray array];for(auto& bucket:stats.histogram)[result addObject:@(bucket.load())];return result;
        };
        auto observation=[](const patch::CycleObservation& c)->NSDictionary* {
            uint64_t entry=0,host=0;double sample=0;bool valid=c.snapshot(entry,host,sample);
            return @{@"valid":@(valid),@"entryHost":@(entry),@"cycleHost":@(host),@"sample":@(sample)};
        };
        NSMutableArray* deviceTiming=[NSMutableArray array];uint32_t masterIn=0,masterOut=0;
        for(auto& d:engine->devices)if(d->master){masterIn=d->physicalInputLatency;masterOut=d->physicalOutputLatency;}
        for(auto& d:engine->devices)[deviceTiming addObject:@{@"deviceID":@(d->physical),@"master":@(d->master),
            @"clockSkewFrames":@(d->clockSkew.load()),@"peakClockSkewFrames":@(d->peakClockSkew.load()),
            @"inputSkewFrames":@(int64_t(d->physicalInputLatency)+d->extraInput-masterIn),
            @"outputSkewFrames":@(int64_t(d->physicalOutputLatency)+d->extraOutput-masterOut)}];
        auto values=@{@"devices":deviceTiming,@"transport":@"direct shared memory",@"timingEnabled":@(state.timingEnabled),@"routingUpdates":@(engine->routingUpdates.load()),@"generation":@(engine->generation),@"rate":@(state.rate),@"readPhase":phase(state.readPhase),@"writePhase":phase(state.writePhase),
            @"captureMarginHistogram":histogram(state.captureMargin),@"playbackMarginHistogram":histogram(state.playbackMargin),
            @"captureMarginReads":@(state.captureMargin.reads.load()),@"playbackMarginReads":@(state.playbackMargin.reads.load()),
            @"captureMarginMinTicks":@(state.captureMargin.minimumTicks.load()),@"playbackMarginMinTicks":@(state.playbackMargin.minimumTicks.load()),
            @"capturePublicationUnmatched":@(state.captureMargin.unmatched.load()),@"playbackPublicationUnmatched":@(state.playbackMargin.unmatched.load()),
            @"serviceCycle":observation(state.serviceCycle),@"readCycle":observation(state.readCycle),@"writeCycle":observation(state.writeCycle),@"bufferFrames":@(engine->actualBuffer.load()),
            @"inputPadding":@(state.inputPadding.load()),@"outputPadding":@(state.padding.load()),@"captureMisses":@(state.captureMisses.load()),
            @"playbackMisses":@(state.playbackMisses.load()),@"reportedLatency":stringProperty(pluginID(),patch::LatencyProperty),
            @"inputSafety":@(engine->masterInputSafety),@"outputSafety":@(engine->masterOutputSafety)};
        diagnostics=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:values options:0 error:nil] encoding:NSUTF8StringEncoding];
    }catch(const std::exception& e){diagnostics=[@"unavailable: " stringByAppendingString:@(e.what())];}
    NSMutableArray* warnings=[NSMutableArray array];
    if(engine) {
        for(auto& warning:engine->deviceWarnings)[warnings addObject:@(warning.c_str())];
        if(!engine->routeWarning.empty())[warnings addObject:@(engine->routeWarning.c_str())];
    }
    return response(@{@"running":@(engine!=nullptr),@"stale":@(engine && engine->stale()),@"warnings":warnings,
        @"cycles":@(engine?engine->cycles.load():0),@"badBuffers":@(engine?engine->badBuffers.load():0),
        @"latencyDiagnostics":diagnostics ?: @"unavailable",@"bufferFrames":@(engine?engine->actualBuffer.load():0)});
} }
extern "C" void SPStop() { std::lock_guard lock(control); engine.reset(); }
// Reported latency follows the hardware while audio runs; a change is not a
// reason to rebuild the graph.
extern "C" char* SPPublishLatency() { @autoreleasepool {
    std::lock_guard lock(control);
    try { if(engine)engine->publishLatency(); return response(@{@"ok":@YES}); }
    catch(const std::exception& e) { return failure(e); }
} }
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
        // The heartbeat must renew a revoked broker claim even when the rate
        // ranges have not changed. A valid live claim performs no IPC here.
        authorizeWrites();
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
// Locked members follow the rate the Sync Source actually reaches. A member
// that cannot follow is reported and left at its own rate; whether that sound
// is usable is the user's decision. Unlocked members are never changed.
extern "C" char* SPSetHardwareRate(const char* raw) { @autoreleasepool {
    std::lock_guard lock(control);
    try {
        auto d=json(raw);
        NSString* masterUID=d[@"masterUID"];
        auto master=[masterUID isKindOfClass:NSString.class]?translate(masterUID):0;
        if(!master) throw std::runtime_error("The Sync Source is unavailable.");
        NSMutableArray* warnings=[NSMutableArray array];
        bool wroteSyncSource=false;
        auto follow=[&](AudioDeviceID id,double target) {
            std::string name=stringProperty(id,kAudioObjectPropertyName).UTF8String ?: "";
            const auto rate=std::to_string(std::llround(target))+" Hz";
            try {
                auto before=get<Float64>(id,kAudioDevicePropertyNominalSampleRate);
                if(patch::sameRate(before,target))return;
                auto ranges=list<AudioValueRange>(id,kAudioDevicePropertyAvailableNominalSampleRates);
                if(std::none_of(ranges.begin(),ranges.end(),[&](auto r){return target>=r.mMinimum && target<=r.mMaximum;}))
                    throw std::runtime_error("does not support "+rate);
                auto a=address(kAudioDevicePropertyNominalSampleRate);
                check(AudioObjectSetPropertyData(id,&a,0,nullptr,sizeof(target),&target),"rejected "+rate);
                if(id==master)wroteSyncSource=true;
                for(int i=0;i<80 && !patch::sameRate(get<Float64>(id,kAudioDevicePropertyNominalSampleRate),target);++i)
                    std::this_thread::sleep_for(std::chrono::milliseconds(25));
                if(!patch::sameRate(get<Float64>(id,kAudioDevicePropertyNominalSampleRate),target))throw std::runtime_error("did not confirm "+rate);
            } catch(const std::exception& error) {
                [warnings addObject:[NSString stringWithFormat:@"%s %s.",name.empty()?"An interface":name.c_str(),error.what()]];
            }
        };
        follow(master,[d[@"sampleRate"] doubleValue]);
        // The caller may undo only a Sync Source write made by this call.
        NSMutableDictionary* result=[@{@"warnings":warnings,@"wroteSyncSource":@(wroteSyncSource)} mutableCopy];
        // Only a confirmed rate is reported. An unreadable Sync Source leaves the
        // rate unknown, and locked members are not steered by a guess.
        double rate=0;
        try { rate=get<Float64>(master,kAudioDevicePropertyNominalSampleRate); }
        catch(const std::exception& error) {
            [warnings addObject:[NSString stringWithFormat:@"The Sync Source rate could not be read: %s.",error.what()]];
            return response(result);
        }
        for(NSDictionary* m in d[@"devices"]) {
            NSString* uid=m[@"uid"];
            if(![m[@"syncLocked"] boolValue] || ![uid isKindOfClass:NSString.class] || [uid isEqual:masterUID])continue;
            try { if(auto id=translate(uid))follow(id,rate); }
            catch(const std::exception& error) { [warnings addObject:[NSString stringWithFormat:@"%@ could not be checked: %s.",uid,error.what()]]; }
        }
        result[@"rate"]=@(rate);return response(result);
    } catch(const std::exception& e) { return failure(e); }
} }
extern "C" char* SPAcknowledgeRate(const char* raw) { @autoreleasepool {
    try {
        std::lock_guard lock(control);
        authorizeWrites();
        auto a=address(patch::RateRequestProperty);
        auto text=std::to_string([json(raw)[@"ack"] doubleValue]);
        CFStringRef v=CFStringCreateWithCString(nullptr,text.c_str(),kCFStringEncodingUTF8);
        auto err=AudioObjectSetPropertyData(pluginID(),&a,0,nullptr,sizeof(v),&v); CFRelease(v);
        check(err,"Acknowledge sample rate request"); return response(@{@"ok":@YES});
    } catch(const std::exception& e) { return failure(e); }
} }
