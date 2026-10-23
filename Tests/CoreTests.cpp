#include "../Sources/Driver.cpp"
#include "../Sources/RateWire.hpp"
#include <cassert>
#include <aspl/HostCallbacks.hpp>
#include <iostream>
#include <thread>
#include <vector>
#include <future>

static std::vector<AudioObjectPropertyAddress> nameChanges;
static OSStatus recordChanges(AudioServerPlugInHostRef, AudioObjectID, UInt32 count, const AudioObjectPropertyAddress* a) {
    for (UInt32 i=0;i<count;++i) if (a[i].mSelector==kAudioObjectPropertyElementName) nameChanges.push_back(a[i]);
    return noErr;
}
static CFPropertyListRef savedNames=nullptr;
static OSStatus saveNames(AudioServerPlugInHostRef, CFStringRef key, CFPropertyListRef value) {
    assert(CFEqual(key,CFSTR("channel-names-v1")));
    if (savedNames) CFRelease(savedNames);
    savedNames=CFRetain(value); return noErr;
}
static OSStatus loadNames(AudioServerPlugInHostRef, CFStringRef key, CFPropertyListRef* value) {
    *value=nullptr;
    if (CFEqual(key,CFSTR("channel-names-v1")) && savedNames) *value=CFRetain(savedNames);
    return noErr;
}
static std::string readName(const std::shared_ptr<aspl::Device>& d, bool input, UInt32 channel) {
    AudioObjectPropertyAddress a{kAudioObjectPropertyElementName,input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,channel};
    assert(d->HasProperty(d->GetID(),0,&a));
    Boolean writable=true; UInt32 size=0, written=0;
    assert(d->IsPropertySettable(d->GetID(),0,&a,&writable)==noErr && !writable);
    assert(d->GetPropertyDataSize(d->GetID(),0,&a,0,nullptr,&size)==noErr && size==sizeof(CFStringRef));
    CFStringRef value=nullptr;
    assert(d->GetPropertyData(d->GetID(),0,&a,0,nullptr,0,&written,&value)==kAudioHardwareBadPropertySizeError);
    assert(d->GetPropertyData(d->GetID(),0,&a,0,nullptr,size,&written,&value)==noErr && written==size);
    char buffer[8192]; assert(CFStringGetCString(value,buffer,sizeof(buffer),kCFStringEncodingUTF8));
    CFRelease(value); return buffer;
}
static void testChannelNames() {
    using namespace patch;
    auto ctx=std::make_shared<aspl::Context>(std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    auto p=std::make_shared<PatchPlugin>(ctx);
    assert(p->configure(Config::parse("1 2 3 96000 256"),false)==noErr);
    auto d=p->GetDeviceByIndex(0);
    assert(readName(d,true,1)=="To Computer 1" && readName(d,false,3)=="From Computer 3");
    // Keep a non-ASCII character to exercise Unicode name round-tripping.
    ChannelNames names{{"Vocal \u00e5 \"A\"", "RE-201"},{"Monitor L · Monitor R","", "FX\\Return"}};
    assert(ChannelNames::parse(names.encode())==names);
    for (const auto& invalid : {std::string("1 129 0"),std::string("1 1 0 unquoted"),names.encode()+" trailing"}) {
        bool rejected=false; try { ChannelNames::parse(invalid); } catch (...) { rejected=true; } assert(rejected);
    }
    ChannelNames oversized{{std::string(ChannelNames::MaxNameBytes+1,'x')},{}};
    bool rejected=false; try { oversized.encode(); } catch (...) { rejected=true; } assert(rejected);
    AudioServerPlugInHostInterface host{}; host.PropertiesChanged=recordChanges;
    ctx->Host=&host;
    assert(d->GetControlHandler()->OnStartIO()==noErr);
    assert(p->setNames(names,false)==noErr); // Names may change while audio is running.
    assert(p->GetDeviceByIndex(0)->GetID()==d->GetID());
    aspl::DrainHostCallbacksForTesting();
    assert(nameChanges.size()==4);
    assert(nameChanges[0].mScope==kAudioObjectPropertyScopeInput && nameChanges[0].mElement==1);
    assert(nameChanges[3].mScope==kAudioObjectPropertyScopeOutput && nameChanges[3].mElement==3);
    assert(readName(d,true,1)==names.inputs[0]);
    assert(readName(d,false,1)==names.outputs[0]);
    assert(readName(d,false,2)=="From Computer 2");
    assert(p->setNames(names,false)==noErr);
    aspl::DrainHostCallbacksForTesting();
    assert(nameChanges.size()==4);
    auto wrong=names; wrong.inputs.pop_back();
    assert(p->setNames(wrong,false)!=noErr && readName(d,true,2)=="RE-201");
    AudioObjectPropertyAddress bad{kAudioObjectPropertyElementName,kAudioObjectPropertyScopeInput,3};
    assert(!d->HasProperty(d->GetID(),0,&bad));
    bad.mScope=kAudioObjectPropertyScopeGlobal; bad.mElement=1;
    assert(!d->HasProperty(d->GetID(),0,&bad));
    host.WriteToStorage=saveNames; host.CopyFromStorage=loadNames;
    // Exercise the actual custom-property transport, including Unicode and clearing a name.
    names.inputs[0]="";
    auto raw=names.encode(); auto value=CFStringCreateWithCString(nullptr,raw.c_str(),kCFStringEncodingUTF8);
    AudioObjectPropertyAddress property{NamesProperty,kAudioObjectPropertyScopeGlobal,0};
    assert(p->SetPropertyData(p->GetID(),0,&property,0,nullptr,sizeof(value),&value)==noErr);
    CFRelease(value);
    assert(readName(d,true,1)=="To Computer 1");
    d->GetControlHandler()->OnStopIO();
    dispatch_sync_f(patch::storageQueue(),nullptr,[](void*){});
    assert(savedNames);
    auto restoredContext=std::make_shared<aspl::Context>(std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    auto restored=std::make_shared<PatchPlugin>(restoredContext);
    assert(restored->configure(Config::parse("1 2 3 96000 256"),false)==noErr);
    restoredContext->Host=&host;
    Initialization init(restoredContext,restored);
    assert(init.OnInitialize()==noErr);
    assert(readName(restored->GetDeviceByIndex(0),true,2)=="RE-201");
    assert(readName(restored->GetDeviceByIndex(0),false,1)=="Monitor L · Monitor R");
    aspl::DrainHostCallbacksForTesting();
    restoredContext->Host=nullptr;
    CFRelease(savedNames); savedNames=nullptr;
    aspl::DrainHostCallbacksForTesting();
    ctx->Host=nullptr;
    assert(p->configure(Config::parse("1 1 0 96000 256"),false)==noErr);
    d=p->GetDeviceByIndex(0);
    bad={kAudioObjectPropertyElementName,kAudioObjectPropertyScopeOutput,1};
    assert(!d->HasProperty(d->GetID(),0,&bad));
}

static void testStreamNotificationsDoNotBlockSetter() {
    auto ctx=std::make_shared<aspl::Context>(std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    auto session=std::make_shared<patch::Session>(patch::Config{});
    auto device=patch::endpoint(ctx,session,false);
    auto stream=device->GetStreamByID(device->GetStreamIDs(kAudioObjectPropertyScopeInput)[0]);
    static dispatch_semaphore_t setterReturned;
    static std::atomic<unsigned> notices{0};
    setterReturned=dispatch_semaphore_create(0); notices=0;
    AudioServerPlugInHostInterface host{};
    host.PropertiesChanged=[](AudioServerPlugInHostRef,AudioObjectID,UInt32,const AudioObjectPropertyAddress*)->OSStatus {
        // Emulate HAL waiting for its SetPropertyData request to return before
        // completing the notification. Synchronous delivery would deadlock.
        assert(dispatch_semaphore_wait(setterReturned,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
        ++notices; return noErr;
    };
    ctx->Host=&host;
    AudioObjectPropertyAddress a{kAudioStreamPropertyIsActive,kAudioObjectPropertyScopeGlobal,0};
    UInt32 inactive=0;
    assert(stream->SetPropertyData(stream->GetID(),0,&a,0,nullptr,sizeof(inactive),&inactive)==noErr);
    dispatch_semaphore_signal(setterReturned);
    aspl::DrainHostCallbacksForTesting();
    assert(notices==1);
    ctx->Host=nullptr;
    dispatch_release(setterReturned);
}

static void testStorageReentry() {
    using namespace patch;
    auto ctx=std::make_shared<aspl::Context>(std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    auto plugin=std::make_shared<PatchPlugin>(ctx);
    static PatchPlugin* target=nullptr;
    static std::vector<std::string> snapshots;
    target=plugin.get(); snapshots.clear();
    AudioServerPlugInHostInterface host{};
    host.PropertiesChanged=[](AudioServerPlugInHostRef,AudioObjectID,UInt32,const AudioObjectPropertyAddress*)->OSStatus { return noErr; };
    host.RequestDeviceConfigurationChange=[](AudioServerPlugInHostRef,AudioObjectID id,UInt64 action,void* info)->OSStatus {
        return target->GetDeviceByID(id)->PerformConfigurationChange(id,action,info);
    };
    host.WriteToStorage=[](AudioServerPlugInHostRef,CFStringRef,CFPropertyListRef value)->OSStatus {
        // Re-enter a getter taking the configuration mutex, as HAL's change
        // processing can do while WriteToStorage waits for the audio server.
        AudioObjectPropertyAddress a{ConfigProperty,kAudioObjectPropertyScopeGlobal,0};
        CFStringRef result=nullptr; UInt32 bytes=0;
        assert(target->GetPropertyData(target->GetID(),0,&a,0,nullptr,sizeof(result),&bytes,&result)==noErr);
        CFRelease(result);
        char text[256]; assert(CFStringGetCString((CFStringRef)value,text,sizeof(text),kCFStringEncodingUTF8));
        snapshots.emplace_back(text); return noErr;
    };
    ctx->Host=&host;
    assert(plugin->configure(Config::parse("1 2 3 96000 128"),true)==noErr);
    aspl::DrainHostCallbacksForTesting(); aspl::DrainHostCallbacksForTesting();
    assert(plugin->configure(Config::parse("1 3 4 96000 256"),true)==noErr);
    aspl::DrainHostCallbacksForTesting(); aspl::DrainHostCallbacksForTesting();
    dispatch_sync_f(storageQueue(),nullptr,[](void*){});
    assert((snapshots==std::vector<std::string>{"1 2 3 96000 128","1 3 4 96000 256"}));
    aspl::DrainHostCallbacksForTesting();
    ctx->Host=nullptr; target=nullptr;
}

static void testLiveConfiguration() {
    using namespace patch;
    auto context=std::make_shared<aspl::Context>(std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    auto plugin=std::make_shared<PatchPlugin>(context);
    const auto properties=plugin->GetCustomProperties();
    for(auto selector:{ConfigProperty,NamesProperty,StatsProperty,RatesProperty,RateRequestProperty,ReadyProperty}) {
        assert(std::any_of(properties.begin(),properties.end(),[&](const auto& p) {
            return p.mSelector==selector && p.mPropertyDataType==kAudioServerPlugInCustomPropertyDataTypeCFString;
        }));
    }
    AudioObjectPropertyAddress ratesAddress{RatesProperty,kAudioObjectPropertyScopeGlobal,0};
    CFStringRef publishedRates=nullptr; UInt32 publishedBytes=0;
    assert(plugin->GetPropertyData(plugin->GetID(),0,&ratesAddress,0,nullptr,sizeof(publishedRates),&publishedBytes,&publishedRates)==noErr);
    assert(publishedRates && CFStringGetLength(publishedRates)>0); CFRelease(publishedRates);
    std::vector<std::pair<double,double>> masterRates;
    for(double rate:{32000,44100,48000,88200,96000,176400,192000}) masterRates.emplace_back(rate,rate);
    auto wire=encodeRateRanges(masterRates);
    std::istringstream parsed(wire);
    for(auto expected:masterRates) { double lo=0,hi=0; assert(parsed>>lo>>hi); assert(lo==expected.first && hi==expected.second); }
    CFStringRef payload=CFStringCreateWithCString(nullptr,wire.c_str(),kCFStringEncodingUTF8);
    assert(CFStringGetMaximumSizeForEncoding(CFStringGetLength(payload),kCFStringEncodingUTF8)+1<=256);
    assert(plugin->SetPropertyData(plugin->GetID(),0,&ratesAddress,0,nullptr,sizeof(payload),&payload)==noErr);
    CFRelease(payload);
    assert(plugin->GetDeviceByIndex(0)->GetAvailableSampleRates().size()==7);
    auto device=plugin->GetDeviceByIndex(0);
    const auto id=device->GetID();
    assert(device->GetControlHandler()->OnStartIO()==noErr);
    assert(plugin->configure(Config::parse("1 4 2 96000 64"),false)==noErr);
    assert(plugin->GetDeviceByIndex(0)->GetID()==id);
    auto input=device->GetStreamByID(device->GetStreamIDs(kAudioObjectPropertyScopeInput)[0]);
    assert(input->GetChannelCount()==4);
    assert(device->GetPreferredChannelCount()==4);
    device->SetAvailableSampleRatesAsync({{48000,48000},{96000,96000},{192000,192000}});
    assert(input->GetAvailablePhysicalFormats().size()==3);
    assert(device->SetNominalSampleRateAsync(192000)==noErr);
    AudioObjectPropertyAddress a{RateRequestProperty,kAudioObjectPropertyScopeGlobal,0};
    CFStringRef value=nullptr; UInt32 bytes=0;
    assert(plugin->GetPropertyData(plugin->GetID(),0,&a,0,nullptr,sizeof(value),&bytes,&value)==noErr);
    assert(CFStringGetDoubleValue(value)==192000); CFRelease(value);
    assert(plugin->configure(Config::parse("1 1 0 192000 64"),false)==noErr);
    assert(plugin->GetDeviceByIndex(0)->GetID()==id);
    assert(device->GetNominalSampleRate()==192000);
    assert(device->GetStreamIDs(kAudioObjectPropertyScopeOutput).empty());
    assert(device->GetStreamByID(device->GetStreamIDs(kAudioObjectPropertyScopeInput)[0])->GetPhysicalFormat().mSampleRate==192000);
    auto session=std::make_shared<Session>(Config::parse("1 1 1 96000 64"));
    Handler front(session,false),back(session,true);
    aspl::StreamParameters p; p.Format.mChannelsPerFrame=1;
    auto stream=std::make_shared<aspl::Stream>(context,device,p);
    float sample=1,output=1;
    front.OnWriteMixedOutput(stream,0,100,&sample,4);
    session->ready.store(false);
    front.OnReadClientInput({},stream,0,164,&output,4);
    assert(output==0); // No old ring audio during format changes or failures.
}

static void testInitializeAndRejectedChanges() {
    using namespace patch;
    auto context=std::make_shared<aspl::Context>(std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    auto plugin=std::make_shared<PatchPlugin>(context);
    static std::atomic<int> requests{0}; requests.store(0);
    AudioServerPlugInHostInterface host{};
    host.PropertiesChanged=[](AudioServerPlugInHostRef,AudioObjectID,UInt32,const AudioObjectPropertyAddress*)->OSStatus {return noErr;};
    host.RequestDeviceConfigurationChange=[](AudioServerPlugInHostRef,AudioObjectID,UInt64,void*)->OSStatus {
        ++requests; return kAudioHardwareBadObjectError;
    };
    context->Host=&host;
    assert(plugin->restoreConfiguration(Config::parse("1 4 2 96000 64"))==noErr);
    aspl::DrainHostCallbacksForTesting();
    assert(requests.load()==0); // Initialize must not request changes to unpublished IDs.
    AudioObjectPropertyAddress a{ReadyProperty,kAudioObjectPropertyScopeGlobal,0};
    CFStringRef v=nullptr; UInt32 size=0;
    assert(plugin->GetPropertyData(plugin->GetID(),0,&a,0,nullptr,sizeof(v),&size,&v)==noErr);
    assert(CFStringGetIntValue(v)==1); CFRelease(v);
    assert(plugin->configure(Config::parse("1 3 2 96000 64"),false)==noErr);
    aspl::DrainHostCallbacksForTesting(); aspl::DrainHostCallbacksForTesting();
    assert(requests.load()==2);
    // Rejection must release the pending flag, allowing a future retry.
    assert(plugin->configure(Config::parse("1 2 2 96000 64"),false)==noErr);
    aspl::DrainHostCallbacksForTesting(); aspl::DrainHostCallbacksForTesting();
    assert(requests.load()==4);
    context->Host=nullptr;
}

static void testLatencyReporting() {
    using namespace patch;
    for(double frame:{2000.25,50000.75,TimingPeriod+2000.5}) {
        float a,b;encodeTiming(frame,a,b);double decoded;
        assert(decodeTiming(a,b,frame+1000,decoded));assert(std::abs(decoded-frame)<0.07);
    }
    double decoded;assert(!decodeTiming(0,0,1000,decoded));
    float a,b;encodeTiming(TimingPeriod-1,a,b);assert(!decodeTiming(a,b,TimingPeriod,decoded));
    auto context=std::make_shared<aspl::Context>(std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    auto session=std::make_shared<Session>(Config::parse("1 1 1 96000 64"));
    auto back=endpoint(context,session,true);
    auto stream=back->GetStreamByID(back->GetStreamIDs(kAudioObjectPropertyScopeOutput)[0]);
    float block[]{0.25f,0,0};encodeTiming(5000,block[1],block[2]);
    back->GetIOHandler()->OnWriteMixedOutput(stream,0,5400,block,sizeof(block));
    assert(std::abs(session->captureDelay.load()-464)<0.1);
    auto plugin=std::make_shared<PatchPlugin>(context);
    AudioObjectPropertyAddress timing{TimingProperty,kAudioObjectPropertyScopeGlobal,0};
    CFStringRef wire=nullptr;UInt32 size=0;
    assert(plugin->GetPropertyData(plugin->GetID(),0,&timing,0,nullptr,sizeof(wire),&size,&wire)==noErr);
    char text[256];assert(CFStringGetCString(wire,text,sizeof(text),kCFStringEncodingUTF8));CFRelease(wire);
    uint64_t anchor;std::istringstream(text)>>anchor;
    AudioObjectPropertyAddress report{LatencyProperty,kAudioObjectPropertyScopeGlobal,0};
    auto set=[&](std::string payload) {
        CFStringRef value=CFStringCreateWithCString(nullptr,payload.c_str(),kCFStringEncodingUTF8);
        auto result=plugin->SetPropertyData(plugin->GetID(),0,&report,0,nullptr,sizeof(value),&value);CFRelease(value);return result;
    };
    assert(set(std::to_string(anchor)+" 700 624")==noErr);
    auto device=plugin->GetDeviceByIndex(0);
    for(bool input:{true,false}) {
        AudioObjectPropertyAddress a{kAudioDevicePropertyLatency,input?kAudioObjectPropertyScopeInput:kAudioObjectPropertyScopeOutput,0};
        UInt32 result=0;
        assert(device->GetPropertyData(device->GetID(),0,&a,0,nullptr,sizeof(result),&size,&result)==noErr);
        assert(result==(input?700:624));
        auto stream=device->GetStreamByID(device->GetStreamIDs(a.mScope)[0]);assert(stream->GetLatency()==0);
    }
    assert(set(std::to_string(anchor+1)+" 700 624")!=noErr);
    assert(set(std::to_string(anchor)+" 56 60 48 24")==noErr);
    for(bool input:{true,false}) {
        AudioObjectPropertyAddress a{kAudioDevicePropertySafetyOffset,input?kAudioObjectPropertyScopeInput:kAudioObjectPropertyScopeOutput,0};
        UInt32 result=0;
        assert(device->GetPropertyData(device->GetID(),0,&a,0,nullptr,sizeof(result),&size,&result)==noErr);
        assert(result==(input?48:24));
    }
    assert(set(std::to_string(anchor)+" 999999 624")!=noErr);
    assert(set(std::to_string(anchor)+" 700 624 trailing")!=noErr);
}

static void testInitializeDoesNotNotifyUnpublishedGraph() {
    auto ctx=std::make_shared<aspl::Context>(std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    auto plugin=std::make_shared<patch::PatchPlugin>(ctx);
    static std::atomic<int> notices{0};notices=0;
    AudioServerPlugInHostInterface host{};
    host.CopyFromStorage=[](AudioServerPlugInHostRef,CFStringRef key,CFPropertyListRef* out)->OSStatus {
        *out=CFEqual(key,CFSTR("configuration-v1"))?CFRetain(CFSTR("1 4 2 96000 256")):nullptr;return noErr;
    };
    host.PropertiesChanged=[](AudioServerPlugInHostRef,AudioObjectID,UInt32,const AudioObjectPropertyAddress*)->OSStatus {++notices;return noErr;};
    host.RequestDeviceConfigurationChange=[](AudioServerPlugInHostRef,AudioObjectID,UInt64,void*)->OSStatus {++notices;return noErr;};
    ctx->Host=&host;patch::Initialization init(ctx,plugin);
    assert(init.OnInitialize()==noErr && ctx->Host.load()==&host);
    aspl::DrainHostCallbacksForTesting();assert(notices==0);
    auto device=plugin->GetDeviceByIndex(0);assert(device->GetNominalSampleRate()==96000);
    assert(device->GetStreamByID(device->GetStreamIDs(kAudioObjectPropertyScopeInput)[0])->GetChannelCount()==4);
    ctx->Host=nullptr;
}

static void testIndependentLifecycle() {
    struct SlowControl final:aspl::ControlRequestHandler {
        std::promise<void> entered,release;
        OSStatus OnStartIO() override {entered.set_value();release.get_future().wait();return noErr;}
    };
    auto ctx=std::make_shared<aspl::Context>(std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    auto session=std::make_shared<patch::Session>(patch::Config{});
    auto device=patch::endpoint(ctx,session,false);auto slow=std::make_shared<SlowControl>();
    device->SetControlHandler(slow);
    auto started=std::async(std::launch::async,[&]{return device->StartIO(device->GetID(),1);});
    slow->entered.get_future().wait();
    auto stamp=std::async(std::launch::async,[&]{double sample;uint64_t host,seed;return device->GetZeroTimeStamp(device->GetID(),1,&sample,&host,&seed);});
    bool independent=stamp.wait_for(std::chrono::seconds(1))==std::future_status::ready;
    slow->release.set_value(); // Always release before asserting, including on regression.
    assert(started.get()==noErr && stamp.get()==noErr && independent);
    assert(device->StopIO(device->GetID(),1)==noErr);
    assert(device->StopIO(device->GetID(),1)!=noErr);
}

int main() {
    assert(patch::supportedSampleRate(8000) && patch::supportedSampleRate(192000) && patch::supportedSampleRate(384000));
    assert(!patch::supportedSampleRate(7999) && !patch::supportedSampleRate(384001) && !patch::supportedSampleRate(48000.5));
    assert(!patch::supportedSampleRate(NAN) && !patch::supportedSampleRate(INFINITY));
    {
        auto direct=patch::makeDriver();auto plugin=direct->GetPlugin();assert(plugin->GetDeviceCount()==1);
        CFStringRef value=CFSTR("0");
        for(auto key:{patch::ConfigProperty,patch::NamesProperty,patch::RatesProperty,patch::RateRequestProperty,patch::LatencyProperty}) {
            AudioObjectPropertyAddress a{key,kAudioObjectPropertyScopeGlobal,0};
            for(auto pid:{0,getpid()})assert(plugin->SetPropertyData(plugin->GetID(),pid,&a,0,nullptr,sizeof(value),&value)==kAudioHardwareIllegalOperationError);
        }
    }
    testLatencyReporting();
    testInitializeAndRejectedChanges();
    testLiveConfiguration();
    testStreamNotificationsDoNotBlockSetter();
    testStorageReentry();
    using namespace patch;
    testChannelNames();
    testIndependentLifecycle();
    testInitializeDoesNotNotifyUnpublishedGraph();
    {
        auto region=mmap(nullptr,sizeof(SharedTransport),PROT_READ|PROT_WRITE,MAP_ANON|MAP_SHARED,-1,0);
        assert(region!=MAP_FAILED);auto state=new(region) SharedTransport;state->generation=42;
        auto object=xpc_shmem_create(region,sizeof(SharedTransport));assert(object);
        void* mapped=nullptr;auto bytes=xpc_shmem_map(object,&mapped);
        assert(validSharedRegion(static_cast<SharedTransport*>(mapped),bytes,42));
        assert(!validSharedRegion(static_cast<SharedTransport*>(mapped),sizeof(SharedTransport)-1,42));
        assert(!validSharedRegion(static_cast<SharedTransport*>(mapped),bytes,43));
        munmap(mapped,bytes);xpc_release(object);munmap(region,sizeof(SharedTransport));
    }
    assert(Config::parse("1 37 21 48000 64").outputs == 21);
    for (auto invalid : {"", "1 -1 2 48000 64", "1 129 2 48000 64",
        "1 0 0 48000 64", "1 3 5 7999 64", "1 3 5 48000 0", "1 2 2 48000 64 extra"}) {
        bool failed = false;
        try { Config::parse(invalid); } catch (...) { failed = true; }
        assert(failed);
    }
    Timeline ring(3);
    float input[]{0.25f, -0.5f, 0.75f, -0.25f, 0.5f, -0.75f};
    float output[6]{};
    ring.write(RingFrames-1, input, 2);
    ring.read(RingFrames-1, output, 2);
    assert(std::memcmp(input, output, sizeof(input)) == 0);
    ring.read(-1, output, 2);
    for (float v : output) assert(v == 0);
    ring.write(2*RingFrames-1, input, 2);
    ring.read(RingFrames-1, output, 2);
    for (float v : output) assert(v == 0);

    auto driver = makeDriver(false);
    auto plugin = std::dynamic_pointer_cast<PatchPlugin>(driver->GetPlugin());
    assert(plugin->configure(Config::parse("1 3 5 48000 64"), false) == noErr);
    auto visible = plugin->GetDeviceByIndex(0);
    auto bridge = plugin->GetDeviceByIndex(1);
    assert(!visible->GetIsHidden() && bridge->GetIsHidden());
    auto inStream = visible->GetStreamIDs(kAudioObjectPropertyScopeInput);
    auto outStream = visible->GetStreamIDs(kAudioObjectPropertyScopeOutput);
    assert(inStream.size() == 1 && outStream.size() == 1);
    assert(visible->GetStreamByID(inStream[0])->GetChannelCount() == 3);
    assert(visible->GetStreamByID(outStream[0])->GetChannelCount() == 5);
    assert(bridge->GetStreamByID(bridge->GetStreamIDs(kAudioObjectPropertyScopeInput)[0])->GetChannelCount() == 7);
    assert(bridge->GetStreamByID(bridge->GetStreamIDs(kAudioObjectPropertyScopeOutput)[0])->GetChannelCount() == 5);
    assert(visible->GetControlHandler()->OnStartIO() == noErr);
    assert(plugin->configure(Config::parse("1 37 21 48000 64"), false) == noErr);
    assert(plugin->GetDeviceByIndex(0)->GetID() == visible->GetID());
    visible->GetControlHandler()->OnStopIO();
    assert(plugin->configure(Config::parse("1 37 21 48000 64"), false) == noErr);
    auto ctx = driver->GetContext();
    // Test the same I/O handlers used by the HAL, with unequal input/output widths.
    auto s = std::make_shared<Session>(Config::parse("1 3 5 48000 64"));
    auto a = endpoint(ctx, s, false), b = endpoint(ctx, s, true);
    aspl::StreamParameters params;
    params.Format.mChannelsPerFrame = 3;
    auto stream3 = std::make_shared<aspl::Stream>(ctx, a, params);
    params.Format.mChannelsPerFrame = 5;
    auto stream5 = std::make_shared<aspl::Stream>(ctx, b, params);
    Handler front(s, false), back(s, true);
    front.OnReadClientInput({}, stream3, 0, 164, output, sizeof(output));
    for (float v : output) assert(v == 0);
    auto bridgeCapture=b->GetStreamByID(b->GetStreamIDs(kAudioObjectPropertyScopeOutput)[0]);
    float markedInput[]{input[0],input[1],input[2],0,0,input[3],input[4],input[5],0,0};
    back.OnWriteMixedOutput(bridgeCapture, 0, 100, markedInput, sizeof(markedInput));
    front.OnReadClientInput({}, stream3, 0, 164, output, sizeof(output));
    assert(std::memcmp(input, output, sizeof(input)) == 0);
    float playback[]{1, 2, 3, 4, 5}, got[7]{};
    front.OnWriteMixedOutput(stream5, 0, 300, playback, sizeof(playback));
    auto bridgePlayback=b->GetStreamByID(b->GetStreamIDs(kAudioObjectPropertyScopeInput)[0]);
    back.OnReadClientInput({}, bridgePlayback, 0, 364, got, sizeof(got));
    assert(std::memcmp(playback, got, sizeof(playback)) == 0);
    // Playback must never leak into capture.
    front.OnReadClientInput({}, stream3, 0, 364, output, 3*sizeof(float));
    assert(output[0] == 0 && output[1] == 0 && output[2] == 0);
    // The HAL requires a sufficiently long clock period to expose normal
    // client buffer sizes. Both endpoints must advertise and use that period.
    assert(a->GetZeroTimeStampPeriod() == RingFrames);
    assert(b->GetZeroTimeStampPeriod() == RingFrames);
    assert(a->GetZeroTimeStampPeriod() >= 10923);
    Float64 ta,tb; UInt64 ha,hb,sa,sb;
    assert(a->GetZeroTimeStamp(a->GetID(),0,&ta,&ha,&sa) == noErr);
    assert(b->GetZeroTimeStamp(b->GetID(),0,&tb,&hb,&sb) == noErr);
    assert(std::fmod(ta, double(RingFrames)) == 0);
    assert(std::fmod(tb, double(RingFrames)) == 0);
    assert(sa == sb);
    assert(ha <= mach_absolute_time() && hb <= mach_absolute_time());
    assert(std::abs((double(hb)-double(ha)) - (tb-ta)*s->ticksPerFrame) < 2.0);
    assert(front.OnStartIO() == noErr);
    front.OnStopIO();
    s->retired = true;
    assert(front.OnStartIO() != noErr);
    // Concurrent wraparound: accept only a complete matching frame or silence.
    Timeline concurrent(3);
    std::atomic<bool> done{false};
    std::thread writer([&] {
        for (int64_t i=0; i<100000; ++i) {
            float v[]{float(i+1),float(i+1),float(i+1)};
            concurrent.write(i,v,1);
        }
        done.store(true);
    });
    for (int64_t i=0; !done.load(); i=(i+1)%100000) {
        float v[3]; concurrent.read(i,v,1);
        assert(v[0] == v[1] && v[1] == v[2]);
        assert(v[0] == 0 || v[0] == float(i+1));
    }
    writer.join();
    std::cout << "PASS: arbitrary asymmetric counts, validation, duplex isolation, "
        "transport delay, stale-frame silence, shared clock, lifecycle and concurrent wraparound\n";
}
