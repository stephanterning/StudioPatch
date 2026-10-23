#pragma once
#include "Core.hpp"
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
struct ClockSample { double sample=0, ticks=0;uint64_t host=0; };
struct SharedTransport {
    static constexpr uint64_t Magic=0x5350444952454355ULL;
    uint64_t magic=Magic,generation=0;
    uint32_t inputs=0,outputs=0,rate=0,padding=0,inputPadding=0;
    std::atomic<uint32_t> active{0},clockSequence{0},claimed{0};
    std::atomic<double> sample{0},ticks{0};std::atomic<uint64_t> host{0};
    std::atomic<uint64_t> captureMisses{0},playbackMisses{0};
    SharedPlane capture,playback;
    void publishClock(ClockSample c) {
        clockSequence.fetch_add(1);sample.store(c.sample);ticks.store(c.ticks);host.store(c.host);clockSequence.fetch_add(1);
    }
    bool clock(ClockSample& c) const {
        for(int i=0;i<3;++i) {
            auto seq=clockSequence.load();if(seq&1)continue;
            c={sample.load(),ticks.load(),host.load()};
            if(seq==clockSequence.load() && c.host && c.ticks>0)return true;
        }
        return false;
    }
    bool alive(uint64_t now) const {
        // HAL may predict the physical callback's current timestamp slightly
        // ahead of mach_absolute_time(). Fresh predictions are valid too.
        ClockSample c;return active.load() && clock(c) &&
            std::abs(double(now)-double(c.host))<c.ticks*rate*.1;
    }
};
static_assert(std::atomic<double>::is_always_lock_free && std::atomic<uint64_t>::is_always_lock_free);

// Control-thread IPC only. Audio callbacks access only the mapped atomics.
struct SharedMapping {
    SharedTransport* data=nullptr;size_t size=0;
    ~SharedMapping(){if(data)munmap(data,size);}
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
        xpc_connection_cancel(connection);
#if !__has_feature(objc_arc)
        xpc_release(message);xpc_release(connection);
#endif
        if(!result->data || result->size<sizeof(SharedTransport) || result->data->magic!=SharedTransport::Magic ||
            result->data->generation!=generation || result->data->inputs!=c.inputs || result->data->outputs!=c.outputs || result->data->rate!=c.rate)
            throw std::runtime_error("The StudioPatch shared-memory broker is unavailable or returned an incompatible session.");
        return result;
    }
};
}
