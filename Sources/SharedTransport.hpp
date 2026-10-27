#pragma once
#include "Core.hpp"
#include "Timing.hpp"
#include <cmath>
#include <sys/mman.h>
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>

namespace patch {
constexpr const char* BrokerName="se.studiopatch.transport";
constexpr uint32_t DirectProperty=0x73706472; // spdr
constexpr size_t SharedFrames=8192;
struct SharedPlane {
    std::atomic<int64_t> tags[MaxChannels][SharedFrames];
    std::atomic<uint32_t> samples[MaxChannels][SharedFrames];
    SharedPlane() {
        for(auto& channel:tags)for(auto& tag:channel)tag.store(-1);
        for(auto& channel:samples)for(auto& sample:channel)sample.store(0);
    }
    void write(uint32_t channel,int64_t frame,float value) {
        if(channel>=MaxChannels || frame<0)return;
        auto slot=uint64_t(frame)%SharedFrames;uint32_t bits;memcpy(&bits,&value,4);
        tags[channel][slot].store(-1);samples[channel][slot].store(bits);tags[channel][slot].store(frame);
    }
    float read(uint32_t channel,int64_t frame,bool* present=nullptr) const {
        if(channel>=MaxChannels || frame<0){if(present)*present=false;return 0;}
        auto slot=uint64_t(frame)%SharedFrames;
        bool ok=tags[channel][slot].load()==frame;
        auto bits=samples[channel][slot].load();ok=ok && tags[channel][slot].load()==frame;
        if(present)*present=ok;float value=0;if(ok)memcpy(&value,&bits,4);return value;
    }
};
struct ClockSample { double sample=0, ticks=0;uint64_t host=0, epoch=0; };
struct SharedTransport {
    static constexpr uint64_t Magic=0x5350444952454359ULL;
    uint64_t magic=Magic,generation=0;
    uint32_t inputs=0,outputs=0,rate=0;
    std::atomic<uint32_t> padding{0},inputPadding{0};
    std::atomic<uint32_t> active{0},clockSequence{0},claimed{0};
    std::atomic<int32_t> controllerPID{0};
    std::atomic<uint64_t> clockEpoch{0};
    std::atomic<double> sample{0},ticks{0};std::atomic<uint64_t> host{0};
    std::atomic<uint64_t> captureMisses{0},playbackMisses{0};
    bool timingEnabled=false;
    std::atomic<uint32_t> captureOwner[MaxChannels]{};
    PublicationLog capturePublications[MaxChannels],playbackPublications;
    MarginStats captureMargin,playbackMargin;
    CycleObservation serviceCycle,readCycle,writeCycle;
    PhaseMeter readPhase,writePhase;
    SharedPlane capture,playback;
    void publishClock(ClockSample c) {
        clockSequence.fetch_add(1);sample.store(c.sample);ticks.store(c.ticks);host.store(c.host);clockEpoch.store(c.epoch);clockSequence.fetch_add(1);
    }
    bool clock(ClockSample& c) const {
        for(int i=0;i<3;++i) {
            auto seq=clockSequence.load();if(seq&1)continue;
            c={sample.load(),ticks.load(),host.load(),clockEpoch.load()};
            if(seq==clockSequence.load() && c.host && std::isfinite(c.sample) && std::isfinite(c.ticks) && c.ticks>0)return true;
        }
        return false;
    }
};
// XPC maps whole pages; size is permitted to exceed the C++ payload size.
inline bool validSharedRegion(const SharedTransport* data,size_t size,uint64_t generation) {
    return data && size>=sizeof(SharedTransport) && data->magic==SharedTransport::Magic && data->generation==generation;
}
// One instance per serialized reader (HAL endpoint/handler or DeviceIO).
// A failed snapshot never overwrites the last coherent clock. Timestamp age
// is not an audio gate; readers use frame tags to find the requested samples.
struct ClockReader {
    ClockSample last{};
    bool read(const SharedTransport& transport, ClockSample& result) {
        ClockSample candidate;
        if(transport.clock(candidate))last=candidate;
        result=last;return last.host && last.ticks>0;
    }
};
struct HardwareTimeline {
    ClockReader reader;
    bool valid=false;
    double sample=0;
    uint64_t host=0,epoch=0;
    bool get(const SharedTransport& transport,uint64_t now,double& outSample,uint64_t& outHost,uint64_t& outEpoch) {
        ClockSample c;if(!reader.read(transport,c))return false;
        auto next=std::floor((c.sample+(double(now)-double(c.host))/c.ticks)/RingFrames)*RingFrames;
        if(!valid || next!=sample || epoch!=c.epoch) {
            sample=next;host=uint64_t(std::max(0.0,double(c.host)+(sample-c.sample)*c.ticks));
            epoch=c.epoch;valid=true;
        }
        outSample=sample;outHost=host;outEpoch=epoch;return true;
    }
};
static_assert(std::atomic<double>::is_always_lock_free && std::atomic<uint64_t>::is_always_lock_free);

// Control-thread IPC only. Audio callbacks access only the mapped atomics.
struct SharedMapping {
    SharedTransport* data=nullptr;size_t size=0;
    xpc_connection_t keeper=nullptr;
    ~SharedMapping(){
        if(keeper){xpc_connection_cancel(keeper);
#if !__has_feature(objc_arc)
            xpc_release(keeper);
#endif
        }
        if(data)munmap(data,size);
    }
    // Keep the driver's existing mapping discoverable after a broker restart.
    // Reconnection never replaces published storage and runs only on workers.
    static void keepRegistered(std::weak_ptr<SharedMapping> weak) {
        auto self=weak.lock();if(!self)return;
        auto queue=dispatch_get_global_queue(QOS_CLASS_UTILITY,0);
        auto connection=xpc_connection_create_mach_service(BrokerName,queue,XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
        if(self->keeper){xpc_connection_cancel(self->keeper);
#if !__has_feature(objc_arc)
            xpc_release(self->keeper);
#endif
        }
        self->keeper=connection;
        auto retry=std::make_shared<std::atomic<bool>>(false);
        xpc_connection_set_event_handler(connection,^(xpc_object_t event){
            if(xpc_get_type(event)!=XPC_TYPE_ERROR || retry->exchange(true))return;
            if(auto active=weak.lock())active->data->controllerPID=0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),queue,^{keepRegistered(weak);});
        });
        xpc_connection_resume(connection);
        auto message=xpc_dictionary_create(nullptr,nullptr,0);
        xpc_dictionary_set_uint64(message,"generation",self->data->generation);
        auto memory=xpc_shmem_create(self->data,self->size);
        xpc_dictionary_set_value(message,"restore",memory);
        xpc_connection_send_message(connection,message);
#if !__has_feature(objc_arc)
        xpc_release(memory);xpc_release(message);
#endif
    }
    static std::shared_ptr<SharedMapping> connect(uint64_t generation,const Config& c,bool create) {
        auto connection=xpc_connection_create_mach_service(BrokerName,nullptr,XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
        xpc_connection_set_event_handler(connection,^(xpc_object_t){});xpc_connection_resume(connection);
        auto message=xpc_dictionary_create(nullptr,nullptr,0);
        xpc_dictionary_set_bool(message,"create",create);xpc_dictionary_set_uint64(message,"generation",generation);
        xpc_dictionary_set_uint64(message,"inputs",c.inputs);xpc_dictionary_set_uint64(message,"outputs",c.outputs);
        xpc_dictionary_set_uint64(message,"rate",c.rate);
        struct Reply {
            xpc_object_t value=nullptr;
            dispatch_semaphore_t done=dispatch_semaphore_create(0);
            ~Reply(){
#if !__has_feature(objc_arc)
                if(value)xpc_release(value);dispatch_release(done);
#endif
            }
        };
        auto response=std::make_shared<Reply>();
        xpc_connection_send_message_with_reply(connection,message,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(xpc_object_t value){
#if !__has_feature(objc_arc)
            xpc_retain(value);
#endif
            response->value=value;dispatch_semaphore_signal(response->done);
        });
        auto completed=dispatch_semaphore_wait(response->done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0;
        auto reply=completed?response->value:nullptr;
        auto result=std::make_shared<SharedMapping>();
        if(reply && xpc_get_type(reply)==XPC_TYPE_DICTIONARY) {
            auto memory=xpc_dictionary_get_value(reply,"memory");void* address=nullptr;
            if(memory && xpc_get_type(memory)==XPC_TYPE_SHMEM)result->size=xpc_shmem_map(memory,&address);
            result->data=static_cast<SharedTransport*>(address);
        }
        if(create)xpc_connection_cancel(connection);else result->keeper=connection;
#if !__has_feature(objc_arc)
        xpc_release(message);if(create)xpc_release(connection);
#endif
        if(!validSharedRegion(result->data,result->size,generation) || result->data->inputs!=c.inputs || result->data->outputs!=c.outputs || result->data->rate!=c.rate)
            throw std::runtime_error("The StudioPatch shared-memory broker is unavailable or returned an incompatible session.");
        if(create)keepRegistered(result);
        return result;
    }
};
}
