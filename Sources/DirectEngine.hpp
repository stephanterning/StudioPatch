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
        std::string uid;
        bool master=false,aggregate=false,aligned=false,started=false;double offset=0;
        patch::ClockReader clockReader;
        patch::ClockSample previousClock{};
        uint32_t previousFrames=0;uint64_t alignedEpoch=0;double previousSample=-INFINITY;
        std::atomic<double> clockSkew{0},peakClockSkew{0};
        uint32_t physicalInputLatency=0,physicalOutputLatency=0,inputSafety=0,outputSafety=0;
        uint32_t timingIndex=0,buffer=0,extraInput=0,extraOutput=0,inputOffset=0,outputOffset=0;
        std::vector<UInt32> inLayout,outLayout;
        std::vector<InputRoute> inputs;std::vector<OutputRoute> outputs;
        patch::RouteSlot<Routes> routes;
        ~DeviceIO(){if(proc){AudioDeviceStop(id,proc);AudioDeviceDestroyIOProcID(id,proc);}if(aggregate)AudioHardwareDestroyAggregateDevice(id);}
    };
    struct CompiledRoutes {std::vector<std::unique_ptr<Routes>> tables;std::vector<size_t> owner;std::vector<std::string> silent;};
    std::shared_ptr<patch::SharedMapping> memory;
    std::vector<std::unique_ptr<DeviceIO>> devices;
    std::atomic<uint64_t> cycles{0},badBuffers{0};
    std::vector<std::string> deviceWarnings;std::string routeWarning;
    AudioDeviceID syncSource=0;
    std::atomic<uint32_t> actualBuffer{0};
    uint32_t masterInputSafety=0,masterOutputSafety=0;
    int outputPaddingOverride=-1;
    uint64_t generation=0;double nominalTicks=0;
    std::string lastReport;
    ~DirectEngine(){stop();}
    void stop() {
        if(memory)memory->data->active=0;
        devices.clear();
    }
    static uint32_t pathLatency(AudioDeviceID id,bool input) {
        auto scope=input?kAudioObjectPropertyScopeInput:kAudioObjectPropertyScopeOutput;
        uint32_t stream=0;for(auto s:list<AudioStreamID>(id,kAudioDevicePropertyStreams,scope))stream=std::max(stream,get<UInt32>(s,kAudioStreamPropertyLatency));
        return get<UInt32>(id,kAudioDevicePropertyLatency,scope)+stream;
    }
    static std::string deviceName(NSString* uid) {
        try {
            AudioDeviceID id=[uid isKindOfClass:NSString.class]?translate(uid):0;
            if(NSString* name=id?stringProperty(id,kAudioObjectPropertyName):nil;name.length)return name.UTF8String;
        } catch(const std::exception&) {}
        return [uid isKindOfClass:NSString.class]?uid.UTF8String:"An audio interface";
    }
    uint32_t latency(bool input) {
        // The driver accepts at most 131072 frames per direction.
        auto padding=input?memory->data->inputPadding.load():memory->data->padding.load();
        return uint32_t(std::min<uint64_t>(131072,uint64_t(pathLatency(syncSource,input))+padding));
    }
    void publishLatency() {
        if(!memory)return;
        auto si=get<UInt32>(syncSource,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeInput);
        auto so=get<UInt32>(syncSource,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeOutput);
        auto text=std::to_string(generation)+" "+std::to_string(latency(true))+" "+std::to_string(latency(false))+" "+std::to_string(si)+" "+std::to_string(so);
        if(text==lastReport)return;
        auto value=CFStringCreateWithCString(nullptr,text.c_str(),kCFStringEncodingUTF8);auto a=address(patch::LatencyProperty);
        auto status=AudioObjectSetPropertyData(pluginID(),&a,0,nullptr,sizeof(value),&value);CFRelease(value);check(status,"Publish direct latency");lastReport=text;
    }
    // Layout changes require new channel addresses. Block lengths are read
    // from the callback itself and update timing without rebuilding the graph.
    bool stale() const {
        for(auto& d:devices) try {
            if(layout(d->id,kAudioObjectPropertyScopeInput)!=d->inLayout || layout(d->id,kAudioObjectPropertyScopeOutput)!=d->outLayout)return true;
        } catch(const std::exception&) {}
        return false;
    }
    void observeBlock(uint32_t frames) {
        if(!frames)return;
        actualBuffer=frames;
        auto padding=outputPaddingOverride>=0?uint32_t(outputPaddingOverride):std::max(uint32_t(std::ceil(double(memory->data->rate)/3000.0)),frames);
        // Short or variable blocks must not move the read position forward
        // again. Keep the largest observed margin until the next engine start.
        memory->data->padding=std::max(memory->data->padding.load(),padding);
        memory->data->inputPadding=std::max(memory->data->inputPadding.load(),std::max(padding,frames));
    }
    static OSStatus io(AudioDeviceID,const AudioTimeStamp* now,const AudioBufferList* input,const AudioTimeStamp* it,
        AudioBufferList* output,const AudioTimeStamp* ot,void* context) {
        auto entryHost=mach_absolute_time();
        auto& d=*static_cast<DeviceIO*>(context);auto& e=*d.owner;auto& shared=*e.memory->data;
        if(output)for(UInt32 b=0;b<output->mNumberBuffers;++b)if(output->mBuffers[b].mData)memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
        patch::RouteSlot<Routes>::Read routeRead(d.routes);
        const auto& inputRoutes=routeRead.value?routeRead.value->inputs:d.inputs;
        const auto& outputRoutes=routeRead.value?routeRead.value->outputs:d.outputs;
        uint32_t frames=0;
        // An unaddressable block is skipped on its own; it never disables later
        // blocks or other interfaces.
        for(bool in:{true,false}) {
            auto buffers=in?input:output;auto& layout=in?d.inLayout:d.outLayout;
            if((!buffers && !layout.empty()) || (buffers && buffers->mNumberBuffers!=layout.size())){++e.badBuffers;return noErr;}
            for(size_t b=0;b<layout.size();++b){auto& v=buffers->mBuffers[b];
                if(!v.mData || !layout[b] || v.mNumberChannels!=layout[b] || v.mDataByteSize%(layout[b]*4)){++e.badBuffers;return noErr;}
                auto n=v.mDataByteSize/(layout[b]*4);if(frames && n!=frames){++e.badBuffers;return noErr;}frames=n;
            }
        }
        if(!now || !(now->mFlags&kAudioTimeStampHostTimeValid) || !(now->mFlags&kAudioTimeStampSampleTimeValid))return noErr;
        if(d.master) {
            e.observeBlock(frames);
            double scalar=(now->mFlags&kAudioTimeStampRateScalarValid)?now->mRateScalar:1;
            if(!std::isfinite(scalar) || scalar<=0)scalar=1;
            patch::ClockSample next{now->mSampleTime+d.offset,e.nominalTicks*scalar,now->mHostTime,d.previousClock.epoch};
            if(d.previousClock.host && next.sample<d.previousClock.sample) {
                // A hardware sample counter can restart. Translate it forward
                // instead of stopping I/O or reusing the previous timeline's slots.
                double shift=d.previousClock.sample+d.previousFrames-next.sample;
                d.offset+=shift;next.sample+=shift;++next.epoch;
            }
            d.previousClock=next;d.previousFrames=frames;shared.publishClock(next);
            if(shared.timingEnabled){shared.serviceCycle.record(entryHost,now->mHostTime,next.sample);
                shared.readPhase.record(true,next.sample,entryHost,e.nominalTicks,frames);
                shared.writePhase.record(true,next.sample,entryHost,e.nominalTicks,frames);}
        }
        patch::ClockSample clock;if(!d.clockReader.read(shared,clock))return noErr;
        if(!shared.active.load())return noErr;
        // A secondary's own sample counter can restart, for example when sync
        // lock sets its rate. Realign instead of writing to a stale timeline.
        if(!d.master && (!d.aligned || d.alignedEpoch!=clock.epoch || now->mSampleTime<d.previousSample)) {
            d.offset=std::llround(clock.sample+(double(now->mHostTime)-double(clock.host))/clock.ticks-now->mSampleTime);
            d.aligned=true;d.alignedEpoch=clock.epoch;
        }
        d.previousSample=now->mSampleTime;
        if(!d.master) {
            double skew=clock.sample+(double(now->mHostTime)-double(clock.host))/clock.ticks-now->mSampleTime-d.offset;
            d.clockSkew=skew;
            if(std::abs(skew)>std::abs(d.peakClockSkew.load()))d.peakClockSkew=skew;
            // Diagnostic only: driver timestamp skew does not establish loss of
            // hardware sync. Clock configuration belongs to the user; keep routing.
        }
        auto time=[&](const AudioTimeStamp* t) {
            return t->mSampleTime+d.offset;
        };
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
    // Sync lock only steers rate changes; toggling it must not rebuild the graph.
    static NSDictionary* graphOf(NSDictionary* request) {
        NSMutableDictionary* graph=[request mutableCopy];
        [graph removeObjectForKey:@"inputs"];[graph removeObjectForKey:@"outputs"];[graph removeObjectForKey:@"followMaster"];
        NSMutableArray* members=[NSMutableArray array];
        for(id member in request[@"devices"]) {
            if(![member isKindOfClass:NSDictionary.class]){[members addObject:member];continue;}
            NSMutableDictionary* copy=[member mutableCopy];[copy removeObjectForKey:@"syncLocked"];[members addObject:copy];
        }
        graph[@"devices"]=members;return graph;
    }
    // A route whose interface or channel is unavailable stays silent instead of
    // preventing the rest of the graph from running.
    CompiledRoutes compile(NSDictionary* request,const patch::Config& c) const {
        CompiledRoutes result;result.owner.assign(c.inputs,devices.size());
        for(size_t i=0;i<devices.size();++i)result.tables.push_back(std::make_unique<Routes>());
        auto resolve=[&](NSDictionary* route,bool input,size_t& index,Channel& channel) {
            NSString* uid=route[@"deviceUID"];auto n=[route[@"channel"] longLongValue];
            if(![uid isKindOfClass:NSString.class] || n<1)return false;
            for(index=0;index<devices.size() && devices[index]->uid!=uid.UTF8String;++index){}
            if(index==devices.size())return false;
            auto& d=*devices[index];auto list=channels(input?d.inLayout:d.outLayout);n+=input?d.inputOffset:d.outputOffset;
            if(uint64_t(n)>list.size())return false;
            channel=list[n-1];return true;
        };
        NSArray* inputs=request[@"inputs"];
        for(uint32_t n=0;n<c.inputs && n<inputs.count;++n) {
            if(inputs[n]==[NSNull null])continue;
            size_t index;Channel channel;
            if(!resolve(inputs[n],true,index,channel)){result.silent.push_back("To Computer "+std::to_string(n+1));continue;}
            result.tables[index]->inputs.push_back({channel,n});result.owner[n]=index;
        }
        std::set<std::pair<size_t,uint32_t>> occupied;
        for(NSDictionary* route in request[@"outputs"]) {
            auto source=[route[@"virtualChannel"] longLongValue];
            if(source<1 || uint64_t(source)>c.outputs)continue;
            size_t index;Channel channel;
            if(!resolve(route,false,index,channel) || !occupied.insert({index,[route[@"channel"] unsignedIntValue]}).second) {
                result.silent.push_back("From Computer "+std::to_string(source));continue;
            }
            result.tables[index]->outputs.push_back({uint32_t(source-1),channel});
        }
        return result;
    }
    static std::string describeSilent(const std::vector<std::string>& silent) {
        if(silent.empty())return "";
        std::string text="Unavailable hardware channels stay silent: ";
        for(size_t i=0;i<silent.size();++i)text+=(i?", ":"")+silent[i];
        return text;
    }
    bool updateRouting(NSDictionary* request) {
        if(![graph isEqual:graphOf(request)])return false;
        auto routes=compile(request,config(request));
        handoverRouting(std::move(routes.tables),routes.owner);
        routeWarning=describeSilent(routes.silent);
        return true;
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
        for(size_t i=0;i<devices.size();++i)
            while(!devices[i]->routes.passed(visits[i]) && std::chrono::steady_clock::now()<deadline)
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
        for(uint32_t n=0;n<owner.size();++n)memory->data->captureOwner[n]=owner[n]<devices.size()?devices[owner[n]]->timingIndex:patch::MaxChannels;
        for(size_t i=0;i<devices.size();++i)devices[i]->routes.publish(std::move(next[i]));
        ++routingUpdates;
    }
    // Publishes timing and lets HAL apply it while the transport is still
    // silent. Every failure of this optional step is a warning; it delays
    // correct timing values, never audio.
    void reportTiming() {
        try {
            publishLatency();
            auto timingApplied=[&] {
                std::istringstream timing([stringProperty(pluginID(),patch::LatencyProperty) UTF8String]);
                uint32_t in=0,out=0,si=0,so=0;
                return bool(timing>>in>>out>>si>>so) && si==masterInputSafety && so==masterOutputSafety;
            };
            for(int attempt=0;attempt<100 && !timingApplied();++attempt)std::this_thread::sleep_for(std::chrono::milliseconds(20));
        } catch(const std::exception& error) { deviceWarnings.push_back(std::string("Latency was not reported: ")+error.what()); }
    }
    std::unique_ptr<DeviceIO> openDevice(NSDictionary* member,NSString* master,uint32_t buffer) {
        NSString* uid=member[@"uid"];
        if(![uid isKindOfClass:NSString.class] || [uid hasPrefix:@"se.studiopatch."])throw std::runtime_error("Invalid physical interface");
        for(auto& other:devices)if(other->uid==uid.UTF8String)throw std::runtime_error("Interface is listed twice");
        auto d=std::make_unique<DeviceIO>();d->owner=this;d->uid=uid.UTF8String;
        d->id=translate(uid);d->physical=d->id;d->master=d->id==syncSource;
        if(!d->id)throw std::runtime_error("Interface is unavailable");
        // Metadata that cannot be read is not evidence that audio cannot flow.
        // Only reject what a successful read shows to be unusable.
        auto flag=[&](AudioObjectPropertySelector key,UInt32 fallback) {
            try { return get<UInt32>(d->physical,key); } catch(const std::exception&) { return fallback; }
        };
        if(!flag(kAudioDevicePropertyDeviceIsAlive,1) || flag(kAudioDevicePropertyTransportType,0)==kAudioDeviceTransportTypeAggregate)
            throw std::runtime_error("Select an available physical interface");
        if(!d->master && [member[@"drift"] boolValue]) {
            // Apple owns resampling for an independently clocked secondary.
            // This private aggregate never carries the Sync Source routes.
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
        // The engine follows the buffer the device actually runs with.
        auto a=address(kAudioDevicePropertyBufferFrameSize);AudioObjectSetPropertyData(d->id,&a,0,nullptr,sizeof(buffer),&buffer);
        try { d->buffer=get<UInt32>(d->id,kAudioDevicePropertyBufferFrameSize); }
        catch(const std::exception&) {
            d->buffer=buffer;
            deviceWarnings.push_back(deviceName(uid)+": buffer size could not be read; the first audio callback will establish timing; requested "+std::to_string(buffer)+" frames.");
        }
        d->inLayout=layout(d->id,kAudioObjectPropertyScopeInput);d->outLayout=layout(d->id,kAudioObjectPropertyScopeOutput);
        bool float32=true;
        try {
            for(auto scope:{kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput})for(auto stream:list<AudioStreamID>(d->id,kAudioDevicePropertyStreams,scope)) {
                auto f=get<AudioStreamBasicDescription>(stream,kAudioStreamPropertyVirtualFormat);
                float32&=f.mFormatID==kAudioFormatLinearPCM && (f.mFormatFlags&kAudioFormatFlagIsFloat) && f.mBitsPerChannel==32;
            }
        } catch(const std::exception&) {}
        if(!float32)throw std::runtime_error("Direct path requires Float32 audio");
        bool timingUnknown=false;
        auto timing=[&](auto read)->uint32_t { try { return read(); } catch(const std::exception&) { timingUnknown=true; return 0; } };
        d->inputSafety=timing([&]{return get<UInt32>(d->id,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeInput);});
        d->outputSafety=timing([&]{return get<UInt32>(d->id,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeOutput);});
        d->extraInput=d->inputSafety>masterInputSafety?d->inputSafety-masterInputSafety:0;
        d->extraOutput=d->outputSafety>masterOutputSafety?d->outputSafety-masterOutputSafety:0;
        d->physicalInputLatency=timing([&]{return pathLatency(d->physical,true);});
        d->physicalOutputLatency=timing([&]{return pathLatency(d->physical,false);});
        if(timingUnknown)deviceWarnings.push_back(deviceName(uid)+": latency or safety offset could not be read; timing may be incomplete.");
        return d;
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
        NSString* master=request[@"masterUID"];
        syncSource=[master isKindOfClass:NSString.class]?translate(master):0;if(!syncSource)throw std::runtime_error("Sync Source is missing");
        auto safety=[&](AudioObjectPropertyScope scope)->uint32_t {
            try { return get<UInt32>(syncSource,kAudioDevicePropertySafetyOffset,scope); } catch(const std::exception&) { return 0; }
        };
        masterInputSafety=safety(kAudioObjectPropertyScopeInput);masterOutputSafety=safety(kAudioObjectPropertyScopeOutput);
        auto buffer=[request[@"bufferFrames"] unsignedIntValue];if(buffer<32 || buffer>1024 || (buffer&(buffer-1)))throw std::runtime_error("Invalid I/O buffer");
        for(NSDictionary* member in request[@"devices"]) {
            try {
                auto d=openDevice(member,master,buffer);
                d->timingIndex=uint32_t(devices.size());if(d->master)actualBuffer=d->buffer;
                devices.push_back(std::move(d));
            } catch(const std::exception& error) {
                // A secondary that cannot start must not keep the other interfaces silent.
                if([member[@"uid"] isEqual:master])throw;
                deviceWarnings.push_back(deviceName(member[@"uid"])+" was not started: "+error.what());
            }
        }
        if(!actualBuffer)throw std::runtime_error("Sync Source must be selected");
        // One actual hardware block of transport delay; the callback corrects
        // an unavailable startup buffer query before copying its first samples.
        if(auto raw=std::getenv("STUDIOPATCH_TEST_OUTPUT_PADDING")) {
            char* end=nullptr;auto value=std::strtoul(raw,&end,10);
            if(!*raw || *end || value>4096)throw std::runtime_error("Invalid test output padding");
            outputPaddingOverride=int(value);
        }
        observeBlock(actualBuffer.load());
        auto routes=compile(request,c);
        for(size_t i=0;i<devices.size();++i){devices[i]->inputs=std::move(routes.tables[i]->inputs);devices[i]->outputs=std::move(routes.tables[i]->outputs);}
        for(uint32_t n=0;n<c.inputs;++n)memory->data->captureOwner[n]=routes.owner[n]<devices.size()?devices[routes.owner[n]]->timingIndex:patch::MaxChannels;
        routeWarning=describeSilent(routes.silent);
        std::stable_sort(devices.begin(),devices.end(),[](auto& a,auto& b){return a->master && !b->master;});
        reportTiming();
        memory->data->active=1;
        for(auto& d:devices) {
            auto status=AudioDeviceCreateIOProcID(d->id,io,d.get(),&d->proc);
            if(!status)status=AudioDeviceStart(d->id,d->proc);
            d->started=status==noErr; // Status only; never gates or changes audio.
            if(status && d->master)check(status,"Start direct hardware audio");
            if(status)deviceWarnings.push_back(deviceName(@(d->uid.c_str()))+" was not started (Core Audio "+std::to_string(status)+").");
        }
    }
};
