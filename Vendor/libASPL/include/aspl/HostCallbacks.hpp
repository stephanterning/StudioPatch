#pragma once
#include <dispatch/dispatch.h>
#include <functional>
#include <memory>
namespace aspl {
// StudioPatch local patch: synchronous host RPC from a HAL request can wait on
// the very request being handled. Submit notifications/config requests off-stack.
inline dispatch_queue_t HostCallbackQueue() {
    static auto q=dispatch_queue_create("se.studiopatch.host-callbacks",DISPATCH_QUEUE_SERIAL);
    return q;
}
inline void DeferHostCallback(std::function<void()> callback) {
    auto* task=new std::function<void()>(std::move(callback));
    dispatch_async_f(HostCallbackQueue(),task,[](void* raw) {
        std::unique_ptr<std::function<void()>> fn(static_cast<std::function<void()>*>(raw));
        (*fn)();
    });
}
inline void DrainHostCallbacksForTesting() {
    dispatch_sync_f(HostCallbackQueue(),nullptr,[](void*){});
}
}
