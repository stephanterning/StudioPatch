// Included inside Bridge.mm's private namespace, after the HAL helpers.
class DirectEngine {
public:
    struct InputRoute {Channel source;uint32_t dest;};
    struct OutputRoute {uint32_t source;Channel dest;};
    struct Routes {std::vector<InputRoute> inputs;std::vector<OutputRoute> outputs;};
    NSDictionary* graph=nil;
    std::atomic<uint64_t> routingUpdates{0};
    struct DeviceIO {
        DirectEngine* owner=nullptr;AudioDeviceID id=0,physical=0;AudioDeviceIOProcID proc=nullptr;
        bool master=false,aggregate=false,aligned=false;double offset=0;
        patch::ClockReader clockReader;
        patch::ClockSample previousClock{};
        std::atomic<double> clockSkew{0},peakClockSkew{0},faultClockSkew{0};
        std::atomic<bool> clockFault{false};unsigned skewCycles=0;uint64_t skewSince=0;
        uint32_t physicalInputLatency=0,physicalOutputLatency=0;
        uint32_t timingIndex=0,buffer=0,extraInput=0,extraOutput=0,inputOffset=0,outputOffset=0;
        std::vector<UInt32> inLayout,outLayout;
        std::vector<InputRoute> inputs;std::vector<OutputRoute> outputs;
        patch::RouteSlot<Routes> routes;
        ~DeviceIO(){if(proc){AudioDeviceStop(id,proc);AudioDeviceDestroyIOProcID(id,proc);}if(aggregate)AudioHardwareDestroyAggregateDevice(id);}
    };
    std::shared_ptr<patch::SharedMapping> memory;
    std::vector<std::unique_ptr<DeviceIO>> devices;
    std::vector<Watch> watches;
    std::shared_ptr<std::atomic<bool>> invalidation=std::make_shared<std::atomic<bool>>(false);
    std::atomic<bool>& invalidated=*invalidation;
    std::atomic<uint64_t> cycles{0},badBuffers{0};
    AudioDeviceID syncSource=0;
    uint32_t actualBuffer=0,masterInputSafety=0,masterOutputSafety=0;
    uint64_t generation=0;double nominalTicks=0;
    std::string lastReport;
    ~DirectEngine(){stop();}
    void watch(AudioDeviceID id,UInt32 selector,UInt32 scope=kAudioObjectPropertyScopeGlobal) {
        addWatch(watches,id,address(selector,scope),invalidation);
    }
    void stop() {
        invalidated=true;if(memory)memory->data->active=0;
        removeWatches(watches);devices.clear();
    }
    uint32_t latency(bool input) {
        auto scope=input?kAudioObjectPropertyScopeInput:kAudioObjectPropertyScopeOutput;
        uint32_t stream=0;for(auto id:list<AudioStreamID>(syncSource,kAudioDevicePropertyStreams,scope))stream=std::max(stream,get<UInt32>(id,kAudioStreamPropertyLatency));
        uint64_t result=uint64_t(get<UInt32>(syncSource,kAudioDevicePropertyLatency,scope))+stream+
            (input?memory->data->inputPadding:memory->data->padding);
        if(result>131072)throw std::runtime_error("Interface latency is out of range");return uint32_t(result);
    }
    void publishLatency() {
        if(invalidated || !memory)return;
        auto si=get<UInt32>(syncSource,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeInput);
        auto so=get<UInt32>(syncSource,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeOutput);
        auto text=std::to_string(generation)+" "+std::to_string(latency(true))+" "+std::to_string(latency(false))+" "+std::to_string(si)+" "+std::to_string(so);
        if(text==lastReport)return;
        auto value=CFStringCreateWithCString(nullptr,text.c_str(),kCFStringEncodingUTF8);auto a=address(patch::LatencyProperty);
        auto status=AudioObjectSetPropertyData(pluginID(),&a,0,nullptr,sizeof(value),&value);CFRelease(value);check(status,"Publish direct latency");lastReport=text;
    }
    static OSStatus io(AudioDeviceID,const AudioTimeStamp* now,const AudioBufferList* input,const AudioTimeStamp* it,
        AudioBufferList* output,const AudioTimeStamp* ot,void* context) {
        auto entryHost=mach_absolute_time();
        auto& d=*static_cast<DeviceIO*>(context);auto& e=*d.owner;auto& shared=*e.memory->data;
        if(output)for(UInt32 b=0;b<output->mNumberBuffers;++b)if(output->mBuffers[b].mData)memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
        if(e.invalidated)return noErr;
        patch::RouteSlot<Routes>::Read routeRead(d.routes);
        const auto& inputRoutes=routeRead.value?routeRead.value->inputs:d.inputs;
        const auto& outputRoutes=routeRead.value?routeRead.value->outputs:d.outputs;
        uint32_t frames=0;
        for(bool in:{true,false}) {
            auto buffers=in?input:output;auto& layout=in?d.inLayout:d.outLayout;
            if((!buffers && !layout.empty()) || (buffers && buffers->mNumberBuffers!=layout.size())){e.invalidated=true;++e.badBuffers;return noErr;}
            for(size_t b=0;b<layout.size();++b){auto& v=buffers->mBuffers[b];
                if(!v.mData || !layout[b] || v.mNumberChannels!=layout[b] || v.mDataByteSize%(layout[b]*4)){e.invalidated=true;++e.badBuffers;return noErr;}
                auto n=v.mDataByteSize/(layout[b]*4);if(frames && n!=frames){e.invalidated=true;++e.badBuffers;return noErr;}frames=n;
            }
        }
        if(!now || !(now->mFlags&kAudioTimeStampHostTimeValid) || !(now->mFlags&kAudioTimeStampSampleTimeValid))return noErr;
        if(d.master) {
            if(shared.timingEnabled){shared.serviceCycle.record(entryHost,now->mHostTime,now->mSampleTime);
                shared.readPhase.record(true,now->mSampleTime,entryHost,e.nominalTicks,frames);
                shared.writePhase.record(true,now->mSampleTime,entryHost,e.nominalTicks,frames);}
            double scalar=(now->mFlags&kAudioTimeStampRateScalarValid)?now->mRateScalar:1;
            if(!std::isfinite(scalar) || scalar<.9 || scalar>1.1)return noErr;
            patch::ClockSample next{now->mSampleTime,e.nominalTicks*scalar,now->mHostTime,d.previousClock.epoch};
            if(d.previousClock.host) {
                double predicted=d.previousClock.sample+(double(next.host)-double(d.previousClock.host))/d.previousClock.ticks;
                if(std::abs(next.sample-predicted)>std::max(2.0,double(frames)/4)) {
                    ++next.epoch;
                    // Repeated frame indices must never revive samples from before a jump.
                    shared.active=0;e.invalidated=true;
                }
            }
            d.previousClock=next;shared.publishClock(next);
        }
        patch::ClockSample clock;if(!d.clockReader.read(shared,clock))return noErr;
        // An inactive/stale master is not evidence of secondary clock drift.
        // Do not calibrate or latch a secondary fault from that observation.
        if(!shared.active.load() || std::abs(double(now->mHostTime)-double(clock.host))>=clock.ticks*shared.rate*.1) {
            d.skewCycles=0;d.skewSince=0;return noErr;
        }
        if(!d.aligned){d.offset=std::llround(clock.sample+(double(now->mHostTime)-double(clock.host))/clock.ticks-now->mSampleTime);d.aligned=true;}
        if(!d.master) {
            double skew=clock.sample+(double(now->mHostTime)-double(clock.host))/clock.ticks-now->mSampleTime-d.offset;
            d.clockSkew=skew;
            if(std::abs(skew)>std::abs(d.peakClockSkew.load()))d.peakClockSkew=skew;
            // Unlike continuity within the master clock, cross-device host
            // timestamps wander by >10 frames on the observed UFX/ZED setup.
            if(std::abs(skew)>std::max(32.0,double(frames)/4)) {
                if(!d.skewCycles || now->mHostTime<d.skewSince)d.skewSince=now->mHostTime;
                d.skewCycles=std::min(d.skewCycles+1,3u);
            } else {d.skewCycles=0;d.skewSince=0;}
            // Cross-device host timestamps have measurable short-term jitter.
            // Require sustained drift, not merely three sub-millisecond callbacks.
            if(d.skewCycles>=3 && double(now->mHostTime-d.skewSince)>=clock.ticks*shared.rate*.020 && !d.clockFault) {
                d.faultClockSkew=skew;d.clockFault=true;
            }
            if(d.clockFault)return noErr; // Latch until a deliberate graph restart.
        }
        auto time=[&](const AudioTimeStamp* t) {
            if(d.master)return t->mSampleTime;
            return t->mSampleTime+d.offset;
        };
        if(!d.clockReader.alive(shared,now->mHostTime))return noErr;
        if(it && (it->mFlags&kAudioTimeStampSampleTimeValid) && (it->mFlags&kAudioTimeStampHostTimeValid)) {
            auto base=time(it)+d.extraInput;
            for(auto& route:inputRoutes) {
                auto source=static_cast<const float*>(input->mBuffers[route.source.buffer].mData)+route.source.channel;
                for(uint32_t n=0;n<frames;++n) {
                    auto value=source[n*route.source.stride];double frame=base+n;
                    shared.capture.write(route.dest,std::llround(frame),value);
                }
            }
        }
        if(shared.timingEnabled && it && (it->mFlags&kAudioTimeStampSampleTimeValid))
            shared.capturePublications[d.timingIndex].publish(std::llround(time(it)+d.extraInput),std::llround(time(it)+d.extraInput)+frames,mach_absolute_time());
        if(ot && (ot->mFlags&kAudioTimeStampSampleTimeValid) && (ot->mFlags&kAudioTimeStampHostTimeValid)) {
            auto base=time(ot)-shared.padding-d.extraOutput;
            if(shared.timingEnabled && !outputRoutes.empty())shared.playbackMargin.observe(shared.playbackPublications,std::llround(base),std::llround(base)+frames,mach_absolute_time(),clock.ticks);
            for(auto route:outputRoutes) {
                auto dest=static_cast<float*>(output->mBuffers[route.dest.buffer].mData)+route.dest.channel;
                for(uint32_t n=0;n<frames;++n) {
                    bool found;auto frame=base+n;auto f=int64_t(std::llround(frame));
                    float value=shared.playback.read(route.source,f,&found);
                    dest[n*route.dest.stride]=value;if(!found)shared.playbackMisses.fetch_add(1,std::memory_order_relaxed);
                }
            }
        }
        ++e.cycles;return noErr;
    }
    static NSDictionary* graphOf(NSDictionary* request) {
        auto graph=[request mutableCopy];[graph removeObjectForKey:@"inputs"];[graph removeObjectForKey:@"outputs"];return graph;
    }
    bool updateRouting(NSDictionary* request) {
        if(![graph isEqual:graphOf(request)])return false;
        const auto c=config(request);NSArray* inputs=request[@"inputs"];
        if(inputs.count!=c.inputs)throw std::runtime_error("Invalid input routing");
        std::vector<std::unique_ptr<Routes>> next;for(size_t i=0;i<devices.size();++i)next.push_back(std::make_unique<Routes>());
        auto resolve=[&](NSDictionary* r,bool input) {
            auto id=translate(r[@"deviceUID"]);size_t index=0;
            while(index<devices.size() && devices[index]->physical!=id)++index;
            auto n=[r[@"channel"] longLongValue];
            if(index==devices.size() || n<1)throw std::runtime_error("Mapped interface is missing");
            auto& d=*devices[index];auto list=channels(input?d.inLayout:d.outLayout);n+=input?d.inputOffset:d.outputOffset;
            if(uint64_t(n)>list.size())throw std::runtime_error("Mapped channel is unavailable");
            return std::make_pair(index,list[n-1]);
        };
        std::vector<size_t> owner(c.inputs,devices.size());
        for(uint32_t n=0;n<c.inputs;++n)if(inputs[n]!=[NSNull null]){auto [i,ch]=resolve(inputs[n],true);next[i]->inputs.push_back({ch,n});owner[n]=i;}
        std::set<std::pair<size_t,uint32_t>> occupied;
        for(NSDictionary* r in request[@"outputs"]) {
            auto source=[r[@"virtualChannel"] longLongValue];if(source<1 || source>c.outputs)throw std::runtime_error("Invalid virtual output");
            auto [i,ch]=resolve(r,false);
            if(!occupied.insert({i,[r[@"channel"] unsignedIntValue]}).second)throw std::runtime_error("Duplicate output route");
            next[i]->outputs.push_back({uint32_t(source-1),ch});
        }
        handoverRouting(std::move(next),owner);return true;
    }
    void handoverRouting(std::vector<std::unique_ptr<Routes>> next,const std::vector<size_t>& owner) {
        // First release moving capture destinations. Other routes remain live.
        std::vector<uint64_t> visits(devices.size());
        for(size_t i=0;i<devices.size();++i) {
            auto& d=*devices[i];auto old=d.routes.controlValue();
            auto interim=old?std::make_unique<Routes>(*old):std::make_unique<Routes>(Routes{d.inputs,d.outputs});
            interim->inputs.erase(std::remove_if(interim->inputs.begin(),interim->inputs.end(),[&](auto r){return owner[r.dest]!=i;}),interim->inputs.end());
            visits[i]=d.routes.publish(std::move(interim));
        }
        auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(1);
        for(size_t i=0;i<devices.size();++i)while(!devices[i]->routes.passed(visits[i])) {
            if(std::chrono::steady_clock::now()>deadline)throw std::runtime_error("Routing handover timed out");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        for(uint32_t n=0;n<owner.size();++n)memory->data->captureOwner[n]=owner[n]<devices.size()?devices[owner[n]]->timingIndex:patch::MaxChannels;
        for(size_t i=0;i<devices.size();++i)devices[i]->routes.publish(std::move(next[i]));
        ++routingUpdates;
    }
    void start(NSDictionary* request) {
        graph=graphOf(request);
        auto c=config(request);if(currentConfig()!=c.encode())throw std::runtime_error("Apply the device format first");
        auto text=stringProperty(pluginID(),patch::DirectProperty);generation=std::strtoull(text.UTF8String,nullptr,10);
        if(!generation)throw std::runtime_error("Install the direct-transport driver and broker first");
        memory=patch::SharedMapping::connect(generation,c,false);memory->data->active=0;
        for(auto& owner:memory->data->captureOwner)owner=patch::MaxChannels;
        memory->data->timingEnabled=std::getenv("STUDIOPATCH_TIMING")!=nullptr;
        if(memory->data->claimed.exchange(1))throw std::runtime_error("Direct transport must be configured with a fresh session before restarting");
        mach_timebase_info_data_t tb;mach_timebase_info(&tb);nominalTicks=1e9*tb.denom/tb.numer/c.rate;
        syncSource=translate(request[@"masterUID"]);if(!syncSource)throw std::runtime_error("Sync Source is missing");
        masterInputSafety=get<UInt32>(syncSource,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeInput);
        masterOutputSafety=get<UInt32>(syncSource,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeOutput);
        auto buffer=[request[@"bufferFrames"] unsignedIntValue];if(buffer<32 || buffer>1024 || (buffer&(buffer-1)))throw std::runtime_error("Invalid I/O buffer");
        std::map<std::string,DeviceIO*> byUID;
        for(NSDictionary* member in request[@"devices"]) {
            NSString* uid=member[@"uid"];auto d=std::make_unique<DeviceIO>();d->owner=this;d->id=translate(uid);d->physical=d->id;d->master=d->id==syncSource;
            if(!d->id || [uid hasPrefix:@"se.studiopatch."] || byUID.count(uid.UTF8String))throw std::runtime_error("Invalid or duplicate physical interface");
            if(std::abs(get<Float64>(d->id,kAudioDevicePropertyNominalSampleRate)-c.rate)>.1)throw std::runtime_error("Interface sample rates differ");
            if(!get<UInt32>(d->physical,kAudioDevicePropertyDeviceIsAlive) ||
                get<UInt32>(d->physical,kAudioDevicePropertyTransportType)==kAudioDeviceTransportTypeAggregate)
                throw std::runtime_error("Select an available physical interface");
            if(!d->master && [member[@"drift"] boolValue]) {
                // Apple owns resampling for an independently clocked secondary.
                // This private aggregate never carries the Sync Source routes.
                NSString* master=request[@"masterUID"];
                NSArray* subs=@[@{@kAudioSubDeviceUIDKey:master,@kAudioSubDeviceDriftCompensationKey:@NO},
                    @{@kAudioSubDeviceUIDKey:uid,@kAudioSubDeviceDriftCompensationKey:@YES}];
                NSDictionary* desc=@{@kAudioAggregateDeviceNameKey:@"StudioPatch secondary clock",
                    @kAudioAggregateDeviceUIDKey:[@"se.studiopatch.secondary." stringByAppendingString:NSUUID.UUID.UUIDString],
                    @kAudioAggregateDeviceIsPrivateKey:@YES,@kAudioAggregateDeviceIsStackedKey:@NO,
                    @kAudioAggregateDeviceMainSubDeviceKey:master,@kAudioAggregateDeviceSubDeviceListKey:subs};
                AudioDeviceID aggregate=0;
                check(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)desc,&aggregate),"Create secondary clock aggregate");
                d->id=aggregate;d->aggregate=true;
                d->inputOffset=total(layout(syncSource,kAudioObjectPropertyScopeInput));
                d->outputOffset=total(layout(syncSource,kAudioObjectPropertyScopeOutput));
                auto ni=d->inputOffset+total(layout(d->physical,kAudioObjectPropertyScopeInput));
                auto no=d->outputOffset+total(layout(d->physical,kAudioObjectPropertyScopeOutput));
                for(int attempt=0;attempt<50;++attempt) {
                    if(total(layout(d->id,kAudioObjectPropertyScopeInput))==ni && total(layout(d->id,kAudioObjectPropertyScopeOutput))==no)break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(20));
                }
                NSArray* order=CFBridgingRelease(get<CFArrayRef>(d->id,kAudioAggregateDevicePropertyFullSubDeviceList));
                if(order.count!=2 || ![order[0] isEqual:master] || ![order[1] isEqual:uid] ||
                    total(layout(d->id,kAudioObjectPropertyScopeInput))!=ni || total(layout(d->id,kAudioObjectPropertyScopeOutput))!=no)
                    throw std::runtime_error("Secondary clock channel layout did not match");
            }
            auto a=address(kAudioDevicePropertyBufferFrameSize);check(AudioObjectSetPropertyData(d->id,&a,0,nullptr,sizeof(buffer),&buffer),"Set direct interface buffer");
            d->buffer=get<UInt32>(d->id,kAudioDevicePropertyBufferFrameSize);if(d->master)actualBuffer=d->buffer;
            d->inLayout=layout(d->id,kAudioObjectPropertyScopeInput);d->outLayout=layout(d->id,kAudioObjectPropertyScopeOutput);
            for(auto scope:{kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput})for(auto stream:list<AudioStreamID>(d->id,kAudioDevicePropertyStreams,scope)) {
                auto f=get<AudioStreamBasicDescription>(stream,kAudioStreamPropertyVirtualFormat);
                if(f.mFormatID!=kAudioFormatLinearPCM || !(f.mFormatFlags&kAudioFormatFlagIsFloat) || f.mBitsPerChannel!=32 || std::abs(f.mSampleRate-c.rate)>.1)throw std::runtime_error("Direct path requires Float32 at the selected sample rate");
            }
            auto si=get<UInt32>(d->id,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeInput),so=get<UInt32>(d->id,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeOutput);
            d->extraInput=si>masterInputSafety?si-masterInputSafety:0;d->extraOutput=so>masterOutputSafety?so-masterOutputSafety:0;
            auto pathLatency=[&](bool input){auto scope=input?kAudioObjectPropertyScopeInput:kAudioObjectPropertyScopeOutput;
                uint32_t stream=0;for(auto id:list<AudioStreamID>(d->physical,kAudioDevicePropertyStreams,scope))stream=std::max(stream,get<UInt32>(id,kAudioStreamPropertyLatency));
                return get<UInt32>(d->physical,kAudioDevicePropertyLatency,scope)+stream;};
            d->physicalInputLatency=pathLatency(true);d->physicalOutputLatency=pathLatency(false);
            d->timingIndex=uint32_t(devices.size());byUID[uid.UTF8String]=d.get();devices.push_back(std::move(d));
        }
        if(!actualBuffer)throw std::runtime_error("Sync Source must be selected");
        // Hardware load tests found local playback corruption at 48 kHz /
        // 90% client load with padding 16; padding 32 removed it. Keep a full
        // engine block until a separately qualified lower-latency mode exists.
        memory->data->padding=std::max(uint32_t(std::ceil(double(c.rate)/3000.0)),actualBuffer);
        // Explicit measurement-only override, applied before activating transport.
        if(auto raw=std::getenv("STUDIOPATCH_TEST_OUTPUT_PADDING")) {
            char* end=nullptr;auto value=std::strtoul(raw,&end,10);
            if(!*raw || *end || value>4096)throw std::runtime_error("Invalid test output padding");
            memory->data->padding=uint32_t(value);
        }
        memory->data->inputPadding=std::max(memory->data->padding,actualBuffer);
        NSArray* inputs=request[@"inputs"];if(inputs.count!=c.inputs)throw std::runtime_error("Invalid input routing");
        auto resolve=[&](NSDictionary* route,bool input) {
            NSString* uid=route[@"deviceUID"];auto found=byUID.find(uid.UTF8String ?: "");auto n=[route[@"channel"] longLongValue];
            if(found==byUID.end() || n<1)throw std::runtime_error("Mapped interface is missing");
            auto d=found->second;auto list=channels(input?d->inLayout:d->outLayout);n+=input?d->inputOffset:d->outputOffset;if(uint64_t(n)>list.size())throw std::runtime_error("Mapped channel is unavailable");
            return std::make_pair(d,list[n-1]);
        };
        for(uint32_t n=0;n<c.inputs;++n)if(inputs[n]!=[NSNull null]){auto [d,ch]=resolve(inputs[n],true);d->inputs.push_back({ch,n});memory->data->captureOwner[n]=d->timingIndex;}
        std::set<std::pair<AudioDeviceID,uint32_t>> occupied;
        for(NSDictionary* route in request[@"outputs"]) {
            auto source=[route[@"virtualChannel"] longLongValue];if(source<1 || uint64_t(source)>c.outputs)throw std::runtime_error("Invalid virtual output");
            auto [d,ch]=resolve(route,false);if(!occupied.insert({d->id,[route[@"channel"] unsignedIntValue]}).second)throw std::runtime_error("Duplicate output route");
            d->outputs.push_back({uint32_t(source-1),ch});
        }
        std::stable_sort(devices.begin(),devices.end(),[](auto& a,auto& b){return a->master && !b->master;});
        for(auto& d:devices) {
            if(d->aggregate){watch(d->physical,kAudioDevicePropertyDeviceIsAlive);watch(d->physical,kAudioDevicePropertyNominalSampleRate);}
            watch(d->id,kAudioDevicePropertyDeviceIsAlive);watch(d->id,kAudioDevicePropertyNominalSampleRate);watch(d->id,kAudioDevicePropertyBufferFrameSize);
            watch(d->id,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeInput);watch(d->id,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeOutput);
            for(auto scope:{kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput}) {
                watch(d->physical,kAudioDevicePropertyLatency,scope);
                for(auto stream:list<AudioStreamID>(d->physical,kAudioDevicePropertyStreams,scope))watch(stream,kAudioStreamPropertyLatency);
            }
            watch(d->id,kAudioDevicePropertyStreamConfiguration,kAudioObjectPropertyScopeInput);watch(d->id,kAudioDevicePropertyStreamConfiguration,kAudioObjectPropertyScopeOutput);
        }
        invalidated=false;publishLatency();
        auto virtualID=translate(@(patch::DeviceUID));
        bool ready=false;
        for(int attempt=0;attempt<100;++attempt) {
            ready=get<UInt32>(virtualID,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeInput)==masterInputSafety &&
                get<UInt32>(virtualID,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeOutput)==masterOutputSafety;
            if(ready)break;std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
        if(!ready)throw std::runtime_error("Core Audio did not confirm the Sync Source safety offsets");
        memory->data->active=1;
        for(auto& d:devices){check(AudioDeviceCreateIOProcID(d->id,io,d.get(),&d->proc),"Create direct callback");check(AudioDeviceStart(d->id,d->proc),"Start direct hardware audio");}
    }
};
