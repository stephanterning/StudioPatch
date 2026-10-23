#pragma once
#include <algorithm>
#include <cmath>
#include <atomic>
#include <array>
#include <cstdint>
#include <limits>
namespace patch {
// Single writer, bounded readers. Atomic payload avoids C++ data races even
// when a slot is reused during a snapshot. Sequence checks detect reuse.
struct PublicationLog {
    struct Slot {
        std::atomic<uint64_t> sequence{0},host{0};
        std::atomic<int64_t> first{-1},end{-1};
    };
    std::array<Slot,256> slots;
    std::atomic<uint64_t> count{0};
    void publish(int64_t first,int64_t end,uint64_t host) {
        auto n=count.load();auto& s=slots[n%slots.size()];
        s.sequence.store(2*n+1);s.first=first;s.end=end;s.host=host;
        s.sequence.store(2*n+2);count.store(n+1);
    }
    bool covering(int64_t frame,int64_t& first,uint64_t& host) const {
        auto n=count.load();auto limit=n>slots.size()?n-slots.size():0;
        while(n>limit) {
            --n;const auto& s=slots[n%slots.size()];auto seq=s.sequence.load();
            auto f=s.first.load(),e=s.end.load();auto h=s.host.load();
            if(seq!=2*n+2 || s.sequence.load()!=seq)continue;
            if(f<=frame && frame<e){first=f;host=h;return true;}
        }
        return false;
    }
};
struct MarginStats {
    std::atomic<uint64_t> reads{0},unmatched{0};
    std::atomic<int64_t> minimumTicks{INT64_MAX};
    std::array<std::atomic<uint64_t>,16> histogram{};
    void observe(const PublicationLog& log,int64_t first,int64_t end,uint64_t now,double ticks) {
        ++reads;int64_t margin=INT64_MAX;
        // Validate every contributing block, not only the last requested frame.
        while(end>first) {
            int64_t start;uint64_t published;
            if(!log.covering(end-1,start,published)){++unmatched;return;}
            margin=std::min(margin,int64_t(now)-int64_t(published));end=start;
        }
        if(margin==INT64_MAX)return;
        auto old=minimumTicks.load(std::memory_order_relaxed);
        while(margin<old && !minimumTicks.compare_exchange_weak(old,margin,std::memory_order_relaxed)){}
        unsigned bucket=0;double frames=margin/ticks;
        while(bucket<15 && frames>double(uint64_t(1)<<bucket))++bucket;
        histogram[bucket].fetch_add(1,std::memory_order_relaxed);
    }
};
struct CycleObservation {
    std::atomic<uint64_t> sequence{0},entryHost{0},cycleHost{0};
    std::atomic<double> sample{0};
    void record(uint64_t entry,uint64_t host,double frame){++sequence;entryHost=entry;cycleHost=host;sample=frame;++sequence;}
    bool snapshot(uint64_t& entry,uint64_t& host,double& frame) const {
        for(int i=0;i<3;++i){auto s=sequence.load();if(s&1)continue;entry=entryHost;host=cycleHost;frame=sample;if(sequence.load()==s)return entry!=0;}
        return false;
    }
};
// Pair a client boundary with the containing hardware cycle. Report entry
// difference projected to the client boundary using ticks/frame. This is an
// estimate between distinct grids, not evidence of simultaneous HAL callbacks.
// Each history has one serialized writer. Concurrent pairing is deduplicated.
struct PhaseMeter {
    struct Entry {
        std::atomic<uint64_t> sequence{0},host{0};
        std::atomic<double> frame{0},span{0};
    };
    struct History {
        std::array<Entry,256> slots;
        std::atomic<uint64_t> count{0};
        void add(double frame,uint64_t host,double span) {
            auto n=count.load();auto& e=slots[n%256];e.sequence=2*n+1;e.frame=frame;e.host=host;e.span=span;e.sequence=2*n+2;count=n+1;
        }
        bool find(double frame,double span,bool hardware,uint64_t& host,double& matched) const {
            auto n=count.load(),limit=n>256?n-256:0;
            while(n>limit){--n;auto& e=slots[n%256];auto seq=e.sequence.load();auto f=e.frame.load();auto h=e.host.load();auto width=e.span.load();
                bool match=hardware?(f==frame || (f>=frame && f<frame+span)):
                    (f==frame || (frame>=f && frame<f+width));
                if(seq==2*n+2 && e.sequence.load()==seq && match){host=h;matched=f;return true;}}
            return false;
        }
    } service,client;
    std::atomic<double> lastMatched{-std::numeric_limits<double>::infinity()};
    std::atomic<uint64_t> pairs{0},exactPairs{0};
    std::atomic<double> maximumProjectionFrames{0};
    std::atomic<int64_t> minimumTicks{INT64_MAX},maximumTicks{INT64_MIN};
    std::array<std::atomic<uint64_t>,33> histogram{};
    void record(bool hardware,double frame,uint64_t host,double ticks,double span=0) {
        (hardware?service:client).add(frame,host,span);
        uint64_t other;double matched;
        if(!(hardware?client:service).find(frame,span,hardware,other,matched))return;
        double clientFrame=hardware?matched:frame;
        double offset=hardware?matched-frame:frame-matched;
        auto previous=lastMatched.load();
        do {if(clientFrame<=previous)return;}while(!lastMatched.compare_exchange_weak(previous,clientFrame));
        int64_t difference=hardware?int64_t(other)-int64_t(host):int64_t(host)-int64_t(other);
        difference-=int64_t(std::llround(offset*ticks));
        if(offset==0)++exactPairs;
        auto projection=maximumProjectionFrames.load();while(offset>projection && !maximumProjectionFrames.compare_exchange_weak(projection,offset)){}
        auto lo=minimumTicks.load();while(difference<lo && !minimumTicks.compare_exchange_weak(lo,difference)){}
        auto hi=maximumTicks.load();while(difference>hi && !maximumTicks.compare_exchange_weak(hi,difference)){}
        unsigned magnitude=0;double frames=std::abs(double(difference))/ticks;
        while(magnitude<15 && frames>double(uint64_t(1)<<magnitude))++magnitude;
        unsigned bucket=difference==0?16:(difference<0?15-magnitude:17+magnitude);
        histogram[bucket].fetch_add(1,std::memory_order_relaxed);++pairs;
    }
};

}
