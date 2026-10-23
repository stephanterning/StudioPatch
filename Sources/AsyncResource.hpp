#pragma once
#include <atomic>
#include <functional>
#include <memory>
#include <dispatch/dispatch.h>

namespace patch {
// Published once. HAL/audio readers only load a pointer; acquisition and retry
// run on a worker queue. In-flight work owns State, never the enclosing Session.
template<class T> class AsyncResource {
    struct State {
        std::atomic<bool> cancelled{false};
        std::atomic<T*> published{nullptr};
        std::atomic<unsigned> attempts{0};
        std::shared_ptr<T> owner;
        std::function<std::shared_ptr<T>()> acquire;
    };
    std::shared_ptr<State> state=std::make_shared<State>();
    static void schedule(std::shared_ptr<State> s,unsigned delay) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,int64_t(delay)*NSEC_PER_MSEC),
            dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
                if(s->cancelled.load())return;
                auto n=++s->attempts;
                try {
                    auto value=s->acquire();
                    if(!value)throw 0;
                    if(!s->cancelled.load()) {s->owner=std::move(value);s->published.store(s->owner.get(),std::memory_order_release);}
                } catch(...) {if(!s->cancelled.load())schedule(s,n<4?100u*(1u<<n):2000u);}
            });
    }
public:
    AsyncResource()=default;
    explicit AsyncResource(std::function<std::shared_ptr<T>()> acquire) {if(acquire){state->acquire=std::move(acquire);schedule(state,0);}}
    ~AsyncResource(){state->cancelled=true;}
    AsyncResource(const AsyncResource&)=delete;
    T* get() const{return state->published.load(std::memory_order_acquire);}
    T* operator->() const{return get();}
    explicit operator bool() const{return get()!=nullptr;}
    unsigned attempts() const{return state->attempts.load();}
};
}
