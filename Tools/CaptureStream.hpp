#pragma once
#include <array>
// Bounded SPSC transport. Overflow or disk failure invalidates the run; audio
// never waits for the disk writer. One instance per IOProc.
struct CaptureStream {
    struct Packet { Block block{}; bool input=false; float samples[4096]{}; };
    std::unique_ptr<Packet[]> queue{new Packet[256]};
    std::atomic<uint64_t> written{0},read{0};
    std::atomic<bool> done{false},failed{false};
    std::thread worker;
    FILE* pcm[2]{};FILE* csv[2]{};
    double rate=0,tick=0;
    ~CaptureStream(){finish();}
    void start(const std::string& prefix,double sampleRate) {
        rate=sampleRate;mach_timebase_info_data_t tb;mach_timebase_info(&tb);tick=double(tb.numer)/tb.denom;
        for(int i=0;i<2;++i) {
            auto path=prefix+(i?"-output":"-input");
            pcm[i]=fopen((path+".f32").c_str(),"wb");csv[i]=fopen((path+".csv").c_str(),"w");
            if(!pcm[i] || !csv[i])throw std::runtime_error("Cannot open streaming capture");
            fprintf(csv[i],"offset,count,host,sample,flags,rate,tick_ns\n");
        }
        worker=std::thread([this]{
            for(;;) {
                auto r=read.load(std::memory_order_relaxed);
                if(r==written.load(std::memory_order_acquire)) {
                    if(done.load())break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;
                }
                auto& p=queue[r%256];auto& b=p.block;int i=p.input?0:1;
                if(fwrite(p.samples,4,b.count,pcm[i])!=b.count || fprintf(csv[i],"%llu,%llu,%llu,%.9f,%u,%.0f,%.12f\n",b.offset,b.count,b.host,b.sample,b.flags,rate,tick)<0)failed=true;
                read.store(r+1,std::memory_order_release);
            }
        });
    }
    bool push(Block block,bool input,const float* source,unsigned stride) {
        auto w=written.load(std::memory_order_relaxed);
        if(block.count>4096 || w-read.load(std::memory_order_acquire)>=256 || failed){failed=true;return false;}
        auto& p=queue[w%256];p.block=block;p.input=input;
        for(size_t n=0;n<block.count;++n)p.samples[n]=source[n*stride];
        written.store(w+1,std::memory_order_release);return true;
    }
    void finish() {
        done=true;if(worker.joinable())worker.join();
        for(auto& f:pcm)if(f){if(fclose(f))failed=true;f=nullptr;}
        for(auto& f:csv)if(f){if(fclose(f))failed=true;f=nullptr;}
    }
};
