#pragma once
#include <aspl/Storage.hpp>
#include <dispatch/dispatch.h>
#include <memory>
#include <string>

namespace patch {
// Host storage can synchronously call back through HAL's change queues. Never
// invoke it from SetPropertyData, or while holding the configuration mutex.
inline dispatch_queue_t storageQueue() {
    static auto queue=dispatch_queue_create("se.studiopatch.host-storage", DISPATCH_QUEUE_SERIAL);
    return queue;
}
inline void persistSnapshot(std::shared_ptr<aspl::Context> context,
                            std::string key, std::string value) {
    if (!context->Host) return;
    struct Write { std::shared_ptr<aspl::Context> context; std::string key,value; };
    auto* write=new Write{std::move(context),std::move(key),std::move(value)};
    dispatch_async_f(storageQueue(),write,[](void* raw) {
        std::unique_ptr<Write> w(static_cast<Write*>(raw));
        try { aspl::Storage(w->context).WriteString(w->key,w->value); }
        catch (...) { /* The app's atomic session file remains authoritative. */ }
    });
}
}
