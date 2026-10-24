#include "Core.hpp"
#include "Latency.hpp"
#include "SharedTransport.hpp"
#include "AsyncResource.hpp"
#include "ChannelNames.hpp"
#include <aspl/Driver.hpp>
#include <aspl/HostCallbacks.hpp>
#include "HostStorage.hpp"
#include <mach/mach_time.h>
#include <cmath>
#include <os/log.h>
#include <mutex>

namespace patch {
inline std::atomic<uint64_t> initializeMicros{0};
struct Session {
    const Config config;
    std::atomic<bool> ready{true};
    Timeline capture, playback;
    const uint64_t anchor = mach_absolute_time();
    double ticksPerFrame;
    std::mutex control;
    uint32_t active = 0;
    std::atomic<double> captureDelay{-1};
    std::atomic<uint32_t> inputLatency{0}, outputLatency{0};
    std::atomic<uint32_t> inputSafety{0}, outputSafety{0};
    const bool useDirect;
    AsyncResource<SharedMapping> direct;
    bool retired = false;
    explicit Session(Config c,bool useDirect=false) : config(c), capture(useDirect?0:c.inputs), playback(useDirect?0:c.outputs), useDirect(useDirect),
        direct(useDirect?std::function<std::shared_ptr<SharedMapping>()>([generation=anchor,c]{return SharedMapping::connect(generation,c,true);}):nullptr) {
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        ticksPerFrame = 1e9 * double(tb.denom) / tb.numer / c.rate;
    }
};

class Handler final : public aspl::IORequestHandler, public aspl::ControlRequestHandler {
    std::shared_ptr<Session> session_;
    bool bridge_;
    ClockReader clockReader_;
public:
    Handler(std::shared_ptr<Session> s, bool bridge) : session_(std::move(s)), bridge_(bridge) {}
    void OnCycleTiming(UInt32 operation,const AudioServerPlugInIOCycleInfo& cycle) override {
        if(!session_->direct || bridge_)return;
        auto& shared=*session_->direct->data;if(!shared.timingEnabled)return;
        auto& t=cycle.mCurrentTime;
        if((t.mFlags&kAudioTimeStampSampleHostTimeValid)!=kAudioTimeStampSampleHostTimeValid)return;
        auto entry=mach_absolute_time();
        if(operation==kAudioServerPlugInIOOperationReadInput){shared.readCycle.record(entry,t.mHostTime,t.mSampleTime);shared.readPhase.record(false,t.mSampleTime,entry,session_->ticksPerFrame);}
        if(operation==kAudioServerPlugInIOOperationWriteMix){shared.writeCycle.record(entry,t.mHostTime,t.mSampleTime);shared.writePhase.record(false,t.mSampleTime,entry,session_->ticksPerFrame);}
    }
    OSStatus OnStartIO() override {
        std::lock_guard lock(session_->control);
        if (session_->retired) return kAudioHardwareIllegalOperationError;
        ++session_->active;
        return noErr;
    }
    void OnStopIO() override {
        std::lock_guard lock(session_->control);
        if (session_->active) --session_->active;
    }
    void OnReadClientInput(const std::shared_ptr<aspl::Client>&,
        const std::shared_ptr<aspl::Stream>& stream, Float64, Float64 time,
        void* data, UInt32 size) override {
        if (!session_->ready.load()) { memset(data,0,size); return; }
        if(session_->useDirect && !bridge_) {
            if(!session_->direct){memset(data,0,size);return;}
            auto& shared=*session_->direct->data;auto count=session_->config.inputs;
            if(!clockReader_.alive(shared,mach_absolute_time()) || !count || size%(count*4)){memset(data,0,size);return;}
            auto dest=static_cast<float*>(data);auto start=int64_t(std::llround(time))-shared.inputPadding;
            if(shared.timingEnabled) {
                bool seen[MaxChannels]{};
                for(uint32_t c=0;c<count;++c) {
                    auto owner=shared.captureOwner[c].load();if(owner>=MaxChannels || seen[owner])continue;seen[owner]=true;
                    shared.captureMargin.observe(shared.capturePublications[owner],start,start+size/4/count,mach_absolute_time(),clockReader_.last.ticks);
                }
            }
            for(uint32_t n=0;n<size/4/count;++n)for(uint32_t c=0;c<count;++c) {
                bool found;dest[n*count+c]=shared.capture.read(c,start+n,&found);
                if(!found)shared.captureMisses.fetch_add(1,std::memory_order_relaxed);
            }
            return;
        }
        auto& ring = bridge_ ? session_->playback : session_->capture;
        const auto channels = stream->GetChannelCount();
        const auto expected=bridge_?session_->config.outputs+TimingChannels:session_->config.inputs;
        if(!channels || channels!=expected || size%(channels*sizeof(float))) {memset(data,0,size);return;}
        if (channels) {
            auto samples=static_cast<float*>(data); const auto count=size/sizeof(float)/channels;
            ring.read(int64_t(std::llround(time))-session_->config.delay,samples,count,channels);
            if(bridge_) for(uint32_t n=0;n<count;++n)
                encodeTiming(time+n-session_->config.delay,samples[n*channels+channels-2],samples[n*channels+channels-1]);
        }
    }
    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64, Float64 time, const void* data, UInt32 size) override {
        if (!session_->ready.load()) return;
        if(session_->useDirect && !bridge_) {
            if(!session_->direct)return;
            auto& shared=*session_->direct->data;auto count=session_->config.outputs;
            if(!clockReader_.alive(shared,mach_absolute_time()) || !count || size%(count*4))return;
            auto source=static_cast<const float*>(data);auto start=int64_t(std::llround(time));
            for(uint32_t n=0;n<size/4/count;++n)for(uint32_t c=0;c<count;++c)shared.playback.write(c,start+n,source[n*count+c]);
            if(shared.timingEnabled)shared.playbackPublications.publish(start,start+size/4/count,mach_absolute_time());
            return;
        }
        auto& ring = bridge_ ? session_->capture : session_->playback;
        const auto channels = stream->GetChannelCount();
        const auto expected=bridge_?session_->config.inputs+TimingChannels:session_->config.outputs;
        if(!channels || channels!=expected || size%(channels*sizeof(float)))return;
        if (channels) {
            auto samples=static_cast<const float*>(data);const auto count=size/sizeof(float)/channels;
            ring.write(int64_t(std::llround(time)),samples,count,channels);
            if(bridge_ && count) {
                double source,delay;auto n=count/2;
                if(decodeTiming(samples[n*channels+channels-2],samples[n*channels+channels-1],time+n,source) &&
                    timingDelay(time+n+session_->config.delay,source,delay))
                    session_->captureDelay.store(delay,std::memory_order_relaxed);
            }
        }
    }
};

class RoutedStream final : public aspl::Stream {
    std::weak_ptr<aspl::Device> device_;
public:
    RoutedStream(std::shared_ptr<const aspl::Context> c,std::shared_ptr<aspl::Device> d,const aspl::StreamParameters& p)
        : aspl::Stream(c,d,p),device_(d) {}
protected:
    OSStatus SetPhysicalFormatImpl(const AudioStreamBasicDescription& f) override {
        if(auto d=device_.lock(); d && f.mSampleRate!=d->GetNominalSampleRate()) d->SetNominalSampleRateAsync(f.mSampleRate);
        return aspl::Stream::SetPhysicalFormatImpl(f);
    }
    OSStatus SetVirtualFormatImpl(const AudioStreamBasicDescription& f) override {
        if(auto d=device_.lock(); d && f.mSampleRate!=d->GetNominalSampleRate()) d->SetNominalSampleRateAsync(f.mSampleRate);
        return aspl::Stream::SetVirtualFormatImpl(f);
    }
};

class Endpoint final : public aspl::Device {
    std::shared_ptr<Session> session_;
    bool exposed_;
    HardwareTimeline timeline_;
    std::function<void(double)> rateRequest_;
    bool applying_ = false;
    std::function<void()> abort_;
    mutable std::mutex namesMutex_;
    ChannelNames names_;
    std::string displayName_;
    bool isChannelName(const AudioObjectPropertyAddress* a) const {
        if (!exposed_ || !a || a->mSelector != kAudioObjectPropertyElementName || a->mElement == 0) return false;
        return (a->mScope == kAudioObjectPropertyScopeInput && a->mElement <= std::atomic_load(&session_)->config.inputs) ||
            (a->mScope == kAudioObjectPropertyScopeOutput && a->mElement <= std::atomic_load(&session_)->config.outputs);
    }
    bool isLatency(const AudioObjectPropertyAddress* a) const {
        return exposed_ && a && (a->mSelector==kAudioDevicePropertyLatency || a->mSelector==kAudioDevicePropertySafetyOffset) &&
            (a->mScope==kAudioObjectPropertyScopeInput || a->mScope==kAudioObjectPropertyScopeOutput);
    }
public:
    Endpoint(std::shared_ptr<const aspl::Context> context, const aspl::DeviceParameters& p,
        std::shared_ptr<Session> s, bool exposed) : aspl::Device(context, p), session_(std::move(s)), exposed_(exposed), displayName_(p.Name) {}
    std::string GetName() const override { std::lock_guard lock(namesMutex_); return displayName_; }
    void setDisplayName(const std::string& name) {
        { std::lock_guard lock(namesMutex_); if(name==displayName_)return; displayName_=name; }
        NotifyPropertyChanged(kAudioObjectPropertyName);
    }
    OSStatus AbortConfigurationChange(AudioObjectID id,UInt64 action,void* info) override {
        auto result=aspl::Device::AbortConfigurationChange(id,action,info);
        if(abort_) { auto callback=std::move(abort_); aspl::DeferHostCallback(callback); }
        return result;
    }
    void publishFormats(const std::vector<AudioValueRange>& ranges) {
        for(auto scope:{kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput}) for(auto id:GetStreamIDs(scope)) {
            auto stream=GetStreamByID(id); std::vector<AudioStreamRangedDescription> formats;
            for(auto range:ranges) { auto f=stream->GetPhysicalFormat(); f.mSampleRate=range.mMinimum; formats.push_back({f,range}); }
            stream->SetAvailablePhysicalFormatsAsync(formats); stream->SetAvailableVirtualFormatsAsync(formats);
        }
    }
    void onRateRequest(std::function<void(double)> callback) { rateRequest_=std::move(callback); }
    void publishTiming(std::shared_ptr<Session> session,uint32_t in,uint32_t out,uint32_t si,uint32_t so) {
        auto self=std::static_pointer_cast<Endpoint>(shared_from_this());
        RequestConfigurationChange([self,session,in,out,si,so] {
            if(std::atomic_load(&self->session_)!=session)return;
            session->inputLatency=in;session->outputLatency=out;
            session->inputSafety=si;session->outputSafety=so;
            self->SetSafetyOffsetImpl(std::max(si,so));
            for(auto scope:{kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput}) {
                self->NotifyPropertyChanged(kAudioDevicePropertyLatency,scope);
                self->NotifyPropertyChanged(kAudioDevicePropertySafetyOffset,scope);
            }
        });
    }
    void replaceSession(std::shared_ptr<Session> next, std::function<void()> completed, std::function<void()> aborted) {
        abort_=std::move(aborted);
        auto self=std::static_pointer_cast<Endpoint>(shared_from_this());
        RequestConfigurationChange([self,next,completed] {
            self->applying_=true;
            for (auto scope : {kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput})
                for(auto id:self->GetStreamIDs(scope)) self->RemoveStreamAsync(self->GetStreamByID(id));
            std::atomic_store(&self->session_,next);
            self->timeline_=HardwareTimeline{};
            self->SetPreferredChannelCountAsync(std::max(next->config.inputs,next->config.outputs)+(self->exposed_?0:TimingChannels));
            self->SetNominalSampleRateImpl(next->config.rate);
            self->NotifyPropertyChanged(kAudioDevicePropertyNominalSampleRate);
            for(bool input:{true,false}) {
                auto channels=(input==self->exposed_) ? next->config.inputs : next->config.outputs;
                if(!self->exposed_)channels+=TimingChannels;
                if(!channels) continue;
                aspl::StreamParameters sp;
                sp.Direction=input ? aspl::Direction::Input : aspl::Direction::Output;
                sp.Latency=(!self->exposed_ && input) ? next->config.delay : 0;
                sp.Format={double(next->config.rate),kAudioFormatLinearPCM,kAudioFormatFlagsNativeFloatPacked,
                    channels*4,1,channels*4,channels,32,0};
                self->AddStreamAsync(std::make_shared<RoutedStream>(self->GetContext(),self,sp));
            }
            auto handler=std::make_shared<Handler>(next,!self->exposed_);
            self->SetControlHandler(handler); self->SetIOHandler(handler);
            self->publishFormats(self->GetAvailableSampleRates());
            self->applying_=false;
            self->abort_={};
            if(self->GetContext()->Host && self->HasOwner()) aspl::DeferHostCallback(completed); else completed();
        });
    }
    std::string channelName(bool input, UInt32 channel) const {
        std::lock_guard lock(namesMutex_);
        const auto& names = input ? names_.inputs : names_.outputs;
        if (channel > 0 && channel <= names.size() && !names[channel-1].empty()) return names[channel-1];
        return std::string(input ? "To Computer " : "From Computer ") + std::to_string(channel);
    }
    void setNames(const ChannelNames& names) {
        std::vector<AudioObjectPropertyAddress> changed;
        {
            std::lock_guard lock(namesMutex_);
            for (bool input : {true,false}) {
                const auto& before = input ? names_.inputs : names_.outputs;
                const auto& after = input ? names.inputs : names.outputs;
                for (size_t i=0; i<after.size(); ++i)
                    if (i>=before.size() || before[i]!=after[i])
                        changed.push_back({kAudioObjectPropertyElementName,input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,UInt32(i+1)});
            }
            names_=names;
        }
        for (const auto& a : changed) NotifyPropertyChanged(a.mSelector,a.mScope,a.mElement);
    }
    Boolean HasProperty(AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a) const override {
        return isChannelName(a) || aspl::Device::HasProperty(id,pid,a);
    }
    OSStatus IsPropertySettable(AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* writable) const override {
        if (!isChannelName(a)) return aspl::Device::IsPropertySettable(id,pid,a,writable);
        if (!writable) return kAudioHardwareIllegalOperationError;
        *writable=false; return noErr;
    }
    OSStatus GetPropertyDataSize(AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
        UInt32 qs, const void* q, UInt32* size) const override {
        if (!isChannelName(a)) return aspl::Device::GetPropertyDataSize(id,pid,a,qs,q,size);
        if (!size) return kAudioHardwareIllegalOperationError;
        *size=sizeof(CFStringRef); return noErr;
    }
    OSStatus GetPropertyData(AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
        UInt32 qs, const void* q, UInt32 size, UInt32* written, void* data) const override {
        if(isLatency(a)) {
            if(!data || !written || size<sizeof(UInt32))return kAudioHardwareBadPropertySizeError;
            auto s=std::atomic_load(&session_);
            const bool input=a->mScope==kAudioObjectPropertyScopeInput;
            *static_cast<UInt32*>(data)=a->mSelector==kAudioDevicePropertyLatency?
                (input?s->inputLatency.load():s->outputLatency.load()):(input?s->inputSafety.load():s->outputSafety.load());
            *written=sizeof(UInt32);return noErr;
        }
        if (!isChannelName(a)) return aspl::Device::GetPropertyData(id,pid,a,qs,q,size,written,data);
        if (!data || !written || size < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
        auto name=channelName(a->mScope == kAudioObjectPropertyScopeInput,a->mElement);
        auto value=CFStringCreateWithCString(nullptr,name.c_str(),kCFStringEncodingUTF8);
        if (!value) return kAudioHardwareIllegalOperationError;
        *static_cast<CFStringRef*>(data)=value; *written=sizeof(value); return noErr;
    }
protected:
    OSStatus SetAvailableSampleRatesImpl(std::vector<AudioValueRange> ranges) override {
        auto result=aspl::Device::SetAvailableSampleRatesImpl(ranges);
        publishFormats(ranges); return result;
    }
    OSStatus SetNominalSampleRateImpl(Float64 rate) override {
        if (!applying_ && rateRequest_ && rate != GetNominalSampleRate()) {
            std::atomic_load(&session_)->ready.store(false);
            rateRequest_(rate);
        }
        return aspl::Device::SetNominalSampleRateImpl(rate);
    }
    OSStatus StartIOImpl(UInt32,UInt32 count) override {
        return count==0?GetControlHandler()->OnStartIO():noErr;
    }
    OSStatus StopIOImpl(UInt32,UInt32 count) override {
        if(count==0)GetControlHandler()->OnStopIO();return noErr;
    }
    OSStatus GetZeroTimeStampImpl(UInt32, Float64* sample, UInt64* host, UInt64* seed) override {
        // Both endpoints share a clock and epoch, including when clients start separately.
        const auto session = std::atomic_load(&session_);
        const uint64_t now = mach_absolute_time();
        uint64_t epoch=0;
        if(session->direct && timeline_.get(*session->direct->data,now,*sample,*host,epoch)) {
            *seed=session->anchor+1+epoch;return noErr;
        }
        const double periods = std::floor(double(now - session->anchor) /
            session->ticksPerFrame / double(RingFrames));
        *sample = periods * double(RingFrames);
        *host = session->anchor + uint64_t(*sample * session->ticksPerFrame);
        *seed = session->anchor;
        return noErr;
    }
};

std::shared_ptr<Endpoint> endpoint(std::shared_ptr<const aspl::Context> context,
    std::shared_ptr<Session> s, bool bridge) {
    aspl::DeviceParameters p;
    p.IndependentIOLifecycle=true;
    p.Name = bridge ? "StudioPatch Bridge (internal)" : "StudioPatch";
    p.Manufacturer = "StudioPatch";
    p.DeviceUID = bridge ? BridgeUID : s->config.uid;
    p.ModelUID = "se.studiopatch.model.v1";
    p.ConfigurationApplicationBundleID = "se.studiopatch.app";
    p.SampleRate = s->config.rate;
    p.ChannelCount = std::max(s->config.inputs, s->config.outputs)+(bridge?TimingChannels:0);
    p.CanBeDefault = !bridge;
    p.CanBeDefaultForSystemSounds = false;
    // HAL derives its allowed client buffer range from this period.
    // AudioServerPlugIn requires at least 10923 frames; this is the timeline
    // ring wrap period, not the I/O buffer size or transport delay.
    static_assert(RingFrames >= 10923);
    p.ZeroTimeStampPeriod = RingFrames;
    p.SafetyOffset = 0;
    auto d = std::make_shared<Endpoint>(context, p, s, !bridge);
    d->SetIsHidden(bridge);
    for (bool input : {true, false}) {
        const auto channels = ((input != bridge) ? s->config.inputs : s->config.outputs)+(bridge?TimingChannels:0);
        if (!channels) continue;
        aspl::StreamParameters sp;
        sp.Direction = input ? aspl::Direction::Input : aspl::Direction::Output;
        sp.Latency = bridge && input ? s->config.delay : 0;
        sp.Format = {double(s->config.rate), kAudioFormatLinearPCM,
            kAudioFormatFlagsNativeFloatPacked, channels * 4, 1, channels * 4, channels, 32, 0};
        d->AddStreamAsync(std::make_shared<RoutedStream>(context,d,sp));
    }
    auto h = std::make_shared<Handler>(s, bridge);
    d->SetControlHandler(h);
    d->SetIOHandler(h);
    return d;
}

class PatchPlugin final : public aspl::Plugin {
    std::shared_ptr<aspl::Context> context_;
    std::shared_ptr<Session> session_;
    std::shared_ptr<Endpoint> device_, bridge_;
    mutable std::recursive_mutex mutex_;
    ChannelNames names_;
    std::atomic<double> requestedRate_{0};
    std::atomic<bool> configuring_{false};
    bool direct_=false;
    std::atomic<int32_t> lastControlPID_{0};
public:
    void enableDirect(){direct_=true;}
    std::string deviceUID() const { std::lock_guard lock(mutex_);return session_->config.uid; }
    void restoreName(const std::string& name) { std::lock_guard lock(mutex_); if(!name.empty())device_->setDisplayName(name); }
    explicit PatchPlugin(std::shared_ptr<aspl::Context> context,bool direct=false)
        : aspl::Plugin(context), context_(context),direct_(direct) {
        RegisterCustomProperty(DeviceNameProperty, [this]() -> CFStringRef {
            std::lock_guard lock(mutex_);
            return CFStringCreateWithCString(nullptr,device_->GetName().c_str(),kCFStringEncodingUTF8);
        });
        RegisterCustomProperty(ConfigProperty, [this]() -> CFStringRef {
            std::lock_guard lock(mutex_);
            return CFStringCreateWithCString(nullptr, session_->config.encode().c_str(), kCFStringEncodingUTF8);
        });
        RegisterCustomProperty(TimingProperty,[this]() -> CFStringRef {
            std::lock_guard lock(mutex_);
            auto text=std::to_string(session_->anchor)+" "+std::to_string(session_->ticksPerFrame)+" "+
                std::to_string(session_->captureDelay.load());
            return CFStringCreateWithCString(nullptr,text.c_str(),kCFStringEncodingUTF8);
        });
        RegisterCustomProperty(TransportStatusProperty,[this]() -> CFStringRef {
            std::lock_guard lock(mutex_);
            auto text=std::string(!direct_?"legacy":session_->direct?"ready":"connecting")+" "+std::to_string(session_->direct.attempts())+" controller="+std::to_string(session_->direct?session_->direct->data->controllerPID.load():0)+" writer="+std::to_string(lastControlPID_.load())+" init_us="+std::to_string(initializeMicros.load());
            return CFStringCreateWithCString(nullptr,text.c_str(),kCFStringEncodingUTF8);
        });
        RegisterCustomProperty(DirectProperty,[this]() -> CFStringRef {
            std::lock_guard lock(mutex_);auto text=session_->direct?std::to_string(session_->anchor):"0";
            return CFStringCreateWithCString(nullptr,text.c_str(),kCFStringEncodingUTF8);
        });
        RegisterCustomProperty(LatencyProperty,[this]() -> CFStringRef {
            std::lock_guard lock(mutex_);
            auto text=std::to_string(session_->inputLatency.load())+" "+std::to_string(session_->outputLatency.load());
            return CFStringCreateWithCString(nullptr,text.c_str(),kCFStringEncodingUTF8);
        });
        RegisterCustomProperty(NamesProperty, [this]() -> CFStringRef {
            std::lock_guard lock(mutex_);
            return CFStringCreateWithCString(nullptr,names_.encode().c_str(),kCFStringEncodingUTF8);
        });
        RegisterCustomProperty(StatsProperty, [this]() -> CFStringRef {
            std::lock_guard lock(mutex_);
            auto text = std::to_string(session_->capture.missingFrames.load()) + " " +
                std::to_string(session_->playback.missingFrames.load());
            return CFStringCreateWithCString(nullptr, text.c_str(), kCFStringEncodingUTF8);
        });
        // HAL marshals custom selectors using this registry, not HasProperty alone.
        RegisterCustomProperty(RatesProperty,[this]() -> CFStringRef {
            std::lock_guard lock(mutex_);
            std::ostringstream text;
            for(auto range:device_->GetAvailableSampleRates()) text<<range.mMinimum<<" "<<range.mMaximum<<" ";
            return CFStringCreateWithCString(nullptr,text.str().c_str(),kCFStringEncodingUTF8);
        });
        RegisterCustomProperty(ReadyProperty,[this]() -> CFStringRef {
            std::lock_guard lock(mutex_);
            return CFStringCreateCopy(nullptr,(!configuring_.load() && session_->ready.load() && (!direct_ || bool(session_->direct))) ? CFSTR("1") : CFSTR("0"));
        });
        RegisterCustomProperty(RateRequestProperty,[this]() -> CFStringRef {
            auto text=std::to_string(requestedRate_.load());
            return CFStringCreateWithCString(nullptr,text.c_str(),kCFStringEncodingUTF8);
        });
        configure(Config{}, false);
    }
    // Only called from Initialize, before HAL has enumerated this plugin's devices.
    // Unpublished devices apply configuration synchronously; asking HAL to stop
    // them here can enqueue a request for an ID HAL does not know yet.
    OSStatus restoreConfiguration(Config c) {
        std::lock_guard lock(mutex_);
        RemoveDevice(device_); if(bridge_)RemoveDevice(bridge_);
        OSStatus result;
        try { result=configure(c,false); }
        catch(...) { AddDevice(device_); if(bridge_)AddDevice(bridge_); throw; }
        AddDevice(device_); if(bridge_)AddDevice(bridge_);
        return result;
    }
    OSStatus setNames(const ChannelNames& names, bool persist) {
        names.validate();
        std::lock_guard lock(mutex_);
        if (names.inputs.size()!=session_->config.inputs || names.outputs.size()!=session_->config.outputs)
            return kAudioHardwareIllegalOperationError;
        if (names == names_) return noErr;
        names_=names;
        device_->setNames(names_);
        if (persist && context_->Host) persistSnapshot(context_,"channel-names-v2",session_->config.uid+"\n"+names_.encode());
        NotifyPropertyChanged(NamesProperty);
        return noErr;
    }
    OSStatus configure(Config c, bool persist) {
        std::lock_guard lock(mutex_);
        // Direct transport gets fresh storage and clock epoch on every start,
        // even when the user format is unchanged. Old samples cannot survive a
        // service restart whose hardware sample counter starts over.
        if (!direct_ && session_ && session_->config.encode() == c.encode() && session_->ready.load()) return noErr;
        auto next = std::make_shared<Session>(c,direct_);
        if (configuring_.exchange(true)) return kAudioHardwareIllegalOperationError;
        if (device_ && session_->config.uid == c.uid) {
            session_->ready.store(false); next->ready.store(false);
            auto count=std::make_shared<std::atomic<int>>(0);
            auto aborted=std::make_shared<std::atomic<bool>>(false);
            auto done=[this,next,count,persist,c,aborted] {
                if(count->fetch_add(1)!=(direct_?0:1) || aborted->load()) return;
                std::lock_guard lock(mutex_);
                session_=next;
                names_.inputs.resize(c.inputs); names_.outputs.resize(c.outputs);
                device_->setNames(names_);
                next->ready.store(requestedRate_.load()==0 || requestedRate_.load()==c.rate); configuring_.store(false);
                if(persist && context_->Host) persistSnapshot(context_,"configuration-v1",c.encode());
                NotifyPropertyChanged(ConfigProperty);
            };
            auto abort=[this,aborted] { aborted->store(true); configuring_.store(false); };
            device_->replaceSession(next,done,abort); if(bridge_)bridge_->replaceSession(next,done,abort);
            return noErr;
        }
        struct FinishConfiguration { std::atomic<bool>& value; ~FinishConfiguration(){value=false;} } finish{configuring_};
        auto dev = endpoint(context_, next, false);
        auto bridge = direct_?nullptr:endpoint(context_, next, true);
        dev->onRateRequest([this](double rate) { requestedRate_.store(rate); NotifyPropertyChanged(RateRequestProperty); });
        if (device_) {
            { std::lock_guard control(session_->control); session_->retired=true; session_->ready=false; }
            device_->SetIsAlive(false); RemoveDevice(device_);
            if(bridge_) { bridge_->SetIsAlive(false); RemoveDevice(bridge_); }
        }
        session_ = next; device_ = dev; bridge_ = bridge;
        names_ = {}; // Defaults never leak between preset identities.
        names_.inputs.resize(c.inputs); names_.outputs.resize(c.outputs);
        device_->setNames(names_);
        AddDevice(device_); if(bridge_)AddDevice(bridge_); configuring_.store(false);
        if (persist && context_->Host) persistSnapshot(context_,"configuration-v1", c.encode());
        NotifyPropertyChanged(ConfigProperty);
        return noErr;
    }
    Boolean HasProperty(AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress* a) const override {
        return (a && a->mSelector==RatesProperty) || aspl::Plugin::HasProperty(id,pid,a);
    }
    OSStatus IsPropertySettable(AudioObjectID id, pid_t pid,
        const AudioObjectPropertyAddress* addr, Boolean* writable) const override {
        if (addr && (addr->mSelector == DeviceNameProperty || addr->mSelector == ConfigProperty || addr->mSelector == NamesProperty || addr->mSelector == RatesProperty || addr->mSelector == RateRequestProperty || addr->mSelector == LatencyProperty)) {
            if (!writable) return kAudioHardwareIllegalOperationError;
            *writable = true; return noErr;
        }
        return aspl::Plugin::IsPropertySettable(id, pid, addr, writable);
    }
    OSStatus SetPropertyData(AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* addr,
        UInt32 qualifierSize, const void* qualifier, UInt32 dataSize, const void* data) override {
        if (!addr || (addr->mSelector != DeviceNameProperty && addr->mSelector != ConfigProperty && addr->mSelector != NamesProperty && addr->mSelector != RatesProperty && addr->mSelector != RateRequestProperty && addr->mSelector != LatencyProperty))
            return aspl::Plugin::SetPropertyData(id, pid, addr, qualifierSize, qualifier, dataSize, data);
        if(direct_) {
            lastControlPID_=pid;
            std::lock_guard lock(mutex_);
            if(pid<=0 || !session_->direct || session_->direct->data->controllerPID.load()!=pid)
                return kAudioHardwareIllegalOperationError;
        }
        if (!data || dataSize != sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
        CFStringRef str = *static_cast<const CFStringRef*>(data);
        if (!str || CFGetTypeID(str) != CFStringGetTypeID()) return kAudioHardwareIllegalOperationError;
        const auto capacity=CFStringGetMaximumSizeForEncoding(CFStringGetLength(str),kCFStringEncodingUTF8)+1;
        const size_t limit=addr->mSelector == NamesProperty ? ChannelNames::MaxPayloadBytes*3+1 : (addr->mSelector == DeviceNameProperty ? 16384 : 512);
        if (capacity<=0 || size_t(capacity)>limit) return kAudioHardwareIllegalOperationError;
        try {
            std::vector<char> text(capacity);
            if (!CFStringGetCString(str,text.data(),capacity,kCFStringEncodingUTF8)) return kAudioHardwareIllegalOperationError;
            if(addr->mSelector==DeviceNameProperty) {
                std::lock_guard lock(mutex_);
                std::string name(text.data());
                if(name.empty() || name.size()>4096)return kAudioHardwareIllegalOperationError;
                device_->setDisplayName(name);
                if(context_->Host)persistSnapshot(context_,"device-name-v2",session_->config.uid+"\n"+name);
                NotifyPropertyChanged(DeviceNameProperty);return noErr;
            }
            if(addr->mSelector==LatencyProperty) {
                std::lock_guard lock(mutex_);
                uint64_t generation; uint32_t in,out,si=0,so=0;std::string tail;
                std::istringstream values(text.data());
                if(!(values>>generation>>in>>out))return kAudioHardwareIllegalOperationError;
                if(values>>si){if(!(values>>so))return kAudioHardwareIllegalOperationError;}else if(!values.eof())return kAudioHardwareIllegalOperationError;
                if((values>>tail) || generation!=session_->anchor || in>131072 || out>131072 || si>131072 || so>131072)
                    return kAudioHardwareIllegalOperationError;
                device_->publishTiming(session_,in,out,si,so);
                NotifyPropertyChanged(LatencyProperty);return noErr;
            }
            if (addr->mSelector == RateRequestProperty) { double expected=CFStringGetDoubleValue(str); requestedRate_.compare_exchange_strong(expected,0); return noErr; }
            if (addr->mSelector == RatesProperty) {
                std::istringstream values(text.data()); double lo,hi; std::vector<AudioValueRange> ranges;
                while(values>>lo>>hi) { if(lo<8000 || hi>384000 || hi<lo) return kAudioHardwareIllegalOperationError; ranges.push_back({lo,hi}); }
                if(ranges.empty()) return kAudioHardwareIllegalOperationError;
                device_->SetAvailableSampleRatesAsync(ranges); if(bridge_)bridge_->SetAvailableSampleRatesAsync(ranges);
                return noErr;
            }
            if (addr->mSelector == NamesProperty) return setNames(ChannelNames::parse(text.data()),true);
            return configure(Config::parse(text.data()), true);
        }
        catch (...) { return kAudioHardwareIllegalOperationError; }
    }
};

class Initialization final : public aspl::DriverRequestHandler {
    std::shared_ptr<aspl::Context> context_;
    std::shared_ptr<PatchPlugin> plugin_;
    bool direct_;
public:
    Initialization(std::shared_ptr<aspl::Context> c, std::shared_ptr<PatchPlugin> p,bool direct=false)
        : context_(c), plugin_(p),direct_(direct) {}
    OSStatus OnInitialize() override {
        auto began=mach_absolute_time();
        os_log(OS_LOG_DEFAULT,"StudioPatch Initialize begin");
        if(direct_)plugin_->enableDirect();
        const auto [text, found] = aspl::Storage(context_).ReadString("configuration-v1");
        const auto [displayName, hasDisplayName] = aspl::Storage(context_).ReadString("device-name-v2");
        const auto [scopedNames, hasScopedNames] = aspl::Storage(context_).ReadString("channel-names-v2");
        const auto [names, hasNames] = aspl::Storage(context_).ReadString("channel-names-v1");
        // HAL has not enumerated this graph yet. Restore it without sending
        // transient remove/add/stream notifications for unpublished objects.
        struct RestoreHost {
            std::shared_ptr<aspl::Context> context;AudioServerPlugInHostRef host;
            ~RestoreHost(){context->Host=host;}
        } restore{context_,context_->Host.exchange(nullptr)};
        if (found) { try { plugin_->restoreConfiguration(Config::parse(text)); } catch (...) {if(direct_)return kAudioHardwareUnspecifiedError;} }
        else if(direct_) {try{plugin_->restoreConfiguration(Config{});}catch(...){return kAudioHardwareUnspecifiedError;}}
        const auto prefix=plugin_->deviceUID()+"\n";
        if (hasDisplayName && displayName.rfind(prefix,0)==0) plugin_->restoreName(displayName.substr(prefix.size()));
        try {
            if(hasScopedNames && scopedNames.rfind(prefix,0)==0) plugin_->setNames(ChannelNames::parse(scopedNames.substr(prefix.size())),false);
            else if(!hasScopedNames && hasNames && plugin_->deviceUID()==DeviceUID) plugin_->setNames(ChannelNames::parse(names),false);
        } catch (...) {}
        mach_timebase_info_data_t tb;mach_timebase_info(&tb);
        initializeMicros=uint64_t(double(mach_absolute_time()-began)*tb.numer/tb.denom/1000);
        os_log(OS_LOG_DEFAULT,"StudioPatch Initialize complete in %{public}llu us",(unsigned long long)initializeMicros.load());
        return noErr;
    }
};
std::shared_ptr<aspl::Driver> makeDriver(bool direct=true) {
    auto context = std::make_shared<aspl::Context>(
        std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    auto plugin = std::make_shared<PatchPlugin>(context,direct);
    auto driver = std::make_shared<aspl::Driver>(context, plugin);
    driver->SetDriverHandler(std::make_shared<Initialization>(context, plugin,direct));
    return driver;
}
}

extern "C" void* StudioPatchEntryPoint(CFAllocatorRef, CFUUIDRef type) {
    if (!type || !CFEqual(type, kAudioServerPlugInTypeUUID)) return nullptr;
    try { static auto driver = patch::makeDriver(); return driver->GetReference(); }
    catch (...) { return nullptr; }
}
