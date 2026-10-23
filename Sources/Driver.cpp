#include "Core.hpp"
#include "ChannelNames.hpp"
#include <aspl/Driver.hpp>
#include <aspl/HostCallbacks.hpp>
#include "HostStorage.hpp"
#include <mach/mach_time.h>
#include <cmath>
#include <mutex>

namespace patch {
struct Session {
    const Config config;
    std::atomic<bool> ready{true};
    Timeline capture, playback;
    const uint64_t anchor = mach_absolute_time();
    double ticksPerFrame;
    std::mutex control;
    uint32_t active = 0;
    bool retired = false;
    explicit Session(Config c) : config(c), capture(c.inputs), playback(c.outputs) {
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        ticksPerFrame = 1e9 * double(tb.denom) / tb.numer / c.rate;
    }
};

class Handler final : public aspl::IORequestHandler, public aspl::ControlRequestHandler {
    std::shared_ptr<Session> session_;
    bool bridge_;
public:
    Handler(std::shared_ptr<Session> s, bool bridge) : session_(std::move(s)), bridge_(bridge) {}
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
        auto& ring = bridge_ ? session_->playback : session_->capture;
        const auto channels = stream->GetChannelCount();
        if (channels) ring.read(int64_t(std::llround(time)) - session_->config.delay,
            static_cast<float*>(data), size / sizeof(float) / channels);
    }
    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64, Float64 time, const void* data, UInt32 size) override {
        if (!session_->ready.load()) return;
        auto& ring = bridge_ ? session_->capture : session_->playback;
        const auto channels = stream->GetChannelCount();
        if (channels) ring.write(int64_t(std::llround(time)),
            static_cast<const float*>(data), size / sizeof(float) / channels);
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
    std::function<void(double)> rateRequest_;
    bool applying_ = false;
    std::function<void()> abort_;
    mutable std::mutex namesMutex_;
    ChannelNames names_;
    bool isChannelName(const AudioObjectPropertyAddress* a) const {
        if (!exposed_ || !a || a->mSelector != kAudioObjectPropertyElementName || a->mElement == 0) return false;
        return (a->mScope == kAudioObjectPropertyScopeInput && a->mElement <= std::atomic_load(&session_)->config.inputs) ||
            (a->mScope == kAudioObjectPropertyScopeOutput && a->mElement <= std::atomic_load(&session_)->config.outputs);
    }
public:
    Endpoint(std::shared_ptr<const aspl::Context> context, const aspl::DeviceParameters& p,
        std::shared_ptr<Session> s, bool exposed) : aspl::Device(context, p), session_(std::move(s)), exposed_(exposed) {}
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
    void replaceSession(std::shared_ptr<Session> next, std::function<void()> completed, std::function<void()> aborted) {
        abort_=std::move(aborted);
        auto self=std::static_pointer_cast<Endpoint>(shared_from_this());
        RequestConfigurationChange([self,next,completed] {
            self->applying_=true;
            for (auto scope : {kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput})
                for(auto id:self->GetStreamIDs(scope)) self->RemoveStreamAsync(self->GetStreamByID(id));
            std::atomic_store(&self->session_,next);
            self->SetPreferredChannelCountAsync(std::max(next->config.inputs,next->config.outputs));
            self->SetNominalSampleRateImpl(next->config.rate);
            self->NotifyPropertyChanged(kAudioDevicePropertyNominalSampleRate);
            for(bool input:{true,false}) {
                auto channels=(input==self->exposed_) ? next->config.inputs : next->config.outputs;
                if(!channels) continue;
                aspl::StreamParameters sp;
                sp.Direction=input ? aspl::Direction::Input : aspl::Direction::Output;
                sp.Latency=input ? next->config.delay : 0;
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
    OSStatus GetZeroTimeStampImpl(UInt32, Float64* sample, UInt64* host, UInt64* seed) override {
        // Both endpoints share a clock and epoch, including when clients start separately.
        const auto session = std::atomic_load(&session_);
        const uint64_t now = mach_absolute_time();
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
    p.Name = bridge ? "StudioPatch Bridge (internal)" : "StudioPatch";
    p.Manufacturer = "StudioPatch";
    p.DeviceUID = bridge ? BridgeUID : DeviceUID;
    p.ModelUID = "se.studiopatch.model.v1";
    p.ConfigurationApplicationBundleID = "se.studiopatch.app";
    p.SampleRate = s->config.rate;
    p.ChannelCount = std::max(s->config.inputs, s->config.outputs);
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
        const auto channels = (input != bridge) ? s->config.inputs : s->config.outputs;
        if (!channels) continue;
        aspl::StreamParameters sp;
        sp.Direction = input ? aspl::Direction::Input : aspl::Direction::Output;
        sp.Latency = input ? s->config.delay : 0;
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
public:
    explicit PatchPlugin(std::shared_ptr<aspl::Context> context)
        : aspl::Plugin(context), context_(context) {
        RegisterCustomProperty(ConfigProperty, [this]() -> CFStringRef {
            std::lock_guard lock(mutex_);
            return CFStringCreateWithCString(nullptr, session_->config.encode().c_str(), kCFStringEncodingUTF8);
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
            return CFStringCreateCopy(nullptr,(!configuring_.load() && session_->ready.load()) ? CFSTR("1") : CFSTR("0"));
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
        RemoveDevice(device_); RemoveDevice(bridge_);
        OSStatus result;
        try { result=configure(c,false); }
        catch(...) { AddDevice(device_); AddDevice(bridge_); throw; }
        AddDevice(device_); AddDevice(bridge_);
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
        if (persist && context_->Host) persistSnapshot(context_,"channel-names-v1",names_.encode());
        NotifyPropertyChanged(NamesProperty);
        return noErr;
    }
    OSStatus configure(Config c, bool persist) {
        std::lock_guard lock(mutex_);
        if (session_ && session_->config.encode() == c.encode() && session_->ready.load()) return noErr;
        auto next = std::make_shared<Session>(c);
        if (configuring_.exchange(true)) return kAudioHardwareIllegalOperationError;
        if (device_) {
            session_->ready.store(false); next->ready.store(false);
            auto count=std::make_shared<std::atomic<int>>(0);
            auto aborted=std::make_shared<std::atomic<bool>>(false);
            auto done=[this,next,count,persist,c,aborted] {
                if(count->fetch_add(1)!=1 || aborted->load()) return;
                std::lock_guard lock(mutex_);
                session_=next;
                names_.inputs.resize(c.inputs); names_.outputs.resize(c.outputs);
                device_->setNames(names_);
                next->ready.store(requestedRate_.load()==0 || requestedRate_.load()==c.rate); configuring_.store(false);
                if(persist && context_->Host) persistSnapshot(context_,"configuration-v1",c.encode());
                NotifyPropertyChanged(ConfigProperty);
            };
            auto abort=[this,aborted] { aborted->store(true); configuring_.store(false); };
            device_->replaceSession(next,done,abort); bridge_->replaceSession(next,done,abort);
            return noErr;
        }
        auto dev = endpoint(context_, next, false);
        auto bridge = endpoint(context_, next, true);
        dev->onRateRequest([this](double rate) { requestedRate_.store(rate); NotifyPropertyChanged(RateRequestProperty); });
        if (device_) { RemoveDevice(device_); RemoveDevice(bridge_); }
        session_ = next; device_ = dev; bridge_ = bridge;
        names_.inputs.resize(c.inputs); names_.outputs.resize(c.outputs);
        device_->setNames(names_);
        AddDevice(device_); AddDevice(bridge_); configuring_.store(false);
        if (persist && context_->Host) persistSnapshot(context_,"configuration-v1", c.encode());
        NotifyPropertyChanged(ConfigProperty);
        return noErr;
    }
    Boolean HasProperty(AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress* a) const override {
        return (a && a->mSelector==RatesProperty) || aspl::Plugin::HasProperty(id,pid,a);
    }
    OSStatus IsPropertySettable(AudioObjectID id, pid_t pid,
        const AudioObjectPropertyAddress* addr, Boolean* writable) const override {
        if (addr && (addr->mSelector == ConfigProperty || addr->mSelector == NamesProperty || addr->mSelector == RatesProperty || addr->mSelector == RateRequestProperty)) {
            if (!writable) return kAudioHardwareIllegalOperationError;
            *writable = true; return noErr;
        }
        return aspl::Plugin::IsPropertySettable(id, pid, addr, writable);
    }
    OSStatus SetPropertyData(AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* addr,
        UInt32 qualifierSize, const void* qualifier, UInt32 dataSize, const void* data) override {
        if (!addr || (addr->mSelector != ConfigProperty && addr->mSelector != NamesProperty && addr->mSelector != RatesProperty && addr->mSelector != RateRequestProperty))
            return aspl::Plugin::SetPropertyData(id, pid, addr, qualifierSize, qualifier, dataSize, data);
        if (!data || dataSize != sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
        CFStringRef str = *static_cast<const CFStringRef*>(data);
        if (!str || CFGetTypeID(str) != CFStringGetTypeID()) return kAudioHardwareIllegalOperationError;
        const auto capacity=CFStringGetMaximumSizeForEncoding(CFStringGetLength(str),kCFStringEncodingUTF8)+1;
        const size_t limit=addr->mSelector == NamesProperty ? ChannelNames::MaxPayloadBytes*3+1 : 256;
        if (capacity<=0 || size_t(capacity)>limit) return kAudioHardwareIllegalOperationError;
        try {
            std::vector<char> text(capacity);
            if (!CFStringGetCString(str,text.data(),capacity,kCFStringEncodingUTF8)) return kAudioHardwareIllegalOperationError;
            if (addr->mSelector == RateRequestProperty) { double expected=CFStringGetDoubleValue(str); requestedRate_.compare_exchange_strong(expected,0); return noErr; }
            if (addr->mSelector == RatesProperty) {
                std::istringstream values(text.data()); double lo,hi; std::vector<AudioValueRange> ranges;
                while(values>>lo>>hi) { if(lo<8000 || hi>384000 || hi<lo) return kAudioHardwareIllegalOperationError; ranges.push_back({lo,hi}); }
                if(ranges.empty()) return kAudioHardwareIllegalOperationError;
                device_->SetAvailableSampleRatesAsync(ranges); bridge_->SetAvailableSampleRatesAsync(ranges);
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
public:
    Initialization(std::shared_ptr<aspl::Context> c, std::shared_ptr<PatchPlugin> p)
        : context_(c), plugin_(p) {}
    OSStatus OnInitialize() override {
        const auto [text, found] = aspl::Storage(context_).ReadString("configuration-v1");
        if (found) { try { plugin_->restoreConfiguration(Config::parse(text)); } catch (...) {} }
        const auto [names, hasNames] = aspl::Storage(context_).ReadString("channel-names-v1");
        if (hasNames) { try { plugin_->setNames(ChannelNames::parse(names),false); } catch (...) {} }
        return noErr;
    }
};
std::shared_ptr<aspl::Driver> makeDriver() {
    auto context = std::make_shared<aspl::Context>(
        std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    auto plugin = std::make_shared<PatchPlugin>(context);
    auto driver = std::make_shared<aspl::Driver>(context, plugin);
    driver->SetDriverHandler(std::make_shared<Initialization>(context, plugin));
    return driver;
}
}

extern "C" void* StudioPatchEntryPoint(CFAllocatorRef, CFUUIDRef type) {
    if (!type || !CFEqual(type, kAudioServerPlugInTypeUUID)) return nullptr;
    try { static auto driver = patch::makeDriver(); return driver->GetReference(); }
    catch (...) { return nullptr; }
}
