#pragma once
#include <atomic>
#include <memory>
#include <vector>
namespace patch {
// One serialized audio reader per device, one control writer. SC ordering joins
// reader entry, pointer exchange and reclamation without locks on the callback.
template<class T> class RouteSlot {
    std::atomic<T*> pointer{nullptr};
    std::atomic<uint64_t> visits{0};
    std::unique_ptr<T> current;
    struct Retired {std::unique_ptr<T> value;uint64_t visit;};
    std::vector<Retired> retired;
public:
    struct Read {
        RouteSlot& owner;const T* value;
        explicit Read(RouteSlot& p):owner(p){++owner.visits;value=owner.pointer.load();}
        ~Read(){++owner.visits;}
        Read(const Read&)=delete;
    };
    const T* controlValue() const{return current.get();}
    uint64_t publish(std::unique_ptr<T> next) {
        if(current)retired.reserve(retired.size()+1); // Allocate before publication.
        pointer.exchange(next.get());auto visit=visits.load();
        if(current)retired.push_back({std::move(current),visit});current=std::move(next);
        collect();return visit;
    }
    bool passed(uint64_t visit) const{return !(visit&1) || visits.load()!=visit;}
    void collect(){for(auto it=retired.begin();it!=retired.end();)if(passed(it->visit))it=retired.erase(it);else ++it;}
};
}
