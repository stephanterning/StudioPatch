// Bounded duplex capture for a user-confirmed, isolated physical loopback.
// Only the specified output receives a signal. STUDIOPATCH_TEST_BUFFER optionally
// sets this client's buffer size explicitly for comparable duplex measurements.
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

void check(OSStatus s) { if(s) throw std::runtime_error("Core Audio error " + std::to_string(s)); }
template<class T> T property(AudioObjectID id, UInt32 selector, UInt32 scope=kAudioObjectPropertyScopeGlobal) {
    T result{}; UInt32 bytes=sizeof(result); AudioObjectPropertyAddress a{selector,scope,0};
    check(AudioObjectGetPropertyData(id,&a,0,nullptr,&bytes,&result)); return result;
}
AudioDeviceID device(const char* uid) {
    auto text=CFStringCreateWithCString(nullptr,uid,kCFStringEncodingUTF8);
    AudioValueTranslation t{&text,sizeof(text),nullptr,0}; AudioDeviceID id=0;
    t.mOutputData=&id; t.mOutputDataSize=sizeof(id);
    AudioObjectPropertyAddress a{kAudioHardwarePropertyDeviceForUID,kAudioObjectPropertyScopeGlobal,0};
    UInt32 size=sizeof(t); auto status=AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,nullptr,&size,&t);
    CFRelease(text); check(status); if(!id) throw std::runtime_error("Device not found"); return id;
}
struct Block { uint64_t offset, count, host; double sample; uint32_t flags; };
struct Report { uint64_t host; UInt32 input,output,inputSafety,outputSafety,buffer; };
struct Capture {
    AudioDeviceID id; unsigned inChannel,outChannel; double rate;
    std::vector<float> input,output,signal;
    std::vector<Block> inBlocks,outBlocks;
    std::vector<Report> reports;
    size_t inCount=0,outCount=0,ni=0,no=0;
    std::atomic<bool> failed{false}; AudioDeviceIOProcID proc=nullptr;
    Capture(const char* uid,unsigned in,unsigned out,double seconds=6): id(device(uid)),inChannel(in),outChannel(out),
        rate(property<Float64>(id,kAudioDevicePropertyNominalSampleRate)),
        input(size_t(rate*(seconds+4))),output(input.size()),signal(input.size()),inBlocks(65536),outBlocks(65536) {
        for(auto scope:{kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput}) {
            AudioObjectPropertyAddress a{kAudioDevicePropertyStreams,scope,0}; UInt32 bytes=0;
            check(AudioObjectGetPropertyDataSize(id,&a,0,nullptr,&bytes));
            std::vector<AudioStreamID> streams(bytes/sizeof(AudioStreamID));
            check(AudioObjectGetPropertyData(id,&a,0,nullptr,&bytes,streams.data()));
            unsigned channels=0;
            for(auto stream:streams) {
                auto f=property<AudioStreamBasicDescription>(stream,kAudioStreamPropertyVirtualFormat);
                if(f.mFormatID!=kAudioFormatLinearPCM || !(f.mFormatFlags&kAudioFormatFlagIsFloat) || f.mBitsPerChannel!=32 || f.mSampleRate!=rate)
                    throw std::runtime_error("Expected Float32 PCM at device rate");
                channels+=f.mChannelsPerFrame;
            }
            if((scope==kAudioObjectPropertyScopeInput?inChannel:outChannel)>channels) throw std::runtime_error("Channel out of range");
        }
        uint32_t rng=0x19ab7321;
        for(size_t i=size_t(rate);i<size_t((seconds-2)*rate);++i) {
            rng^=rng<<13; rng^=rng>>17; rng^=rng<<5;
            signal[i]=(double(rng)/UINT32_MAX*2-1)*0.008; // peak below -41 dBFS
        }
        // Low-pass the reference so converter anti-alias filters do not dominate
        // the correlation. The saved output is the actual filtered waveform.
        auto raw=signal;
        for(size_t i=8;i<signal.size();++i) {
            double sum=0;for(size_t j=0;j<8;++j)sum+=raw[i-j];signal[i]=float(sum/8);
        }
    }
    static AudioBuffer* channel(AudioBufferList* buffers,unsigned index,unsigned& stride,unsigned& local) {
        if(!buffers || !index) return nullptr;
        --index;
        for(unsigned b=0;b<buffers->mNumberBuffers;++b) {
            auto& v=buffers->mBuffers[b];
            if(index<v.mNumberChannels) { stride=v.mNumberChannels;local=index;return &v; }
            index-=v.mNumberChannels;
        }
        return nullptr;
    }
    static OSStatus io(AudioDeviceID,const AudioTimeStamp*,const AudioBufferList* input,
        const AudioTimeStamp* it,AudioBufferList* output,const AudioTimeStamp* ot,void* ctx) {
        auto& c=*static_cast<Capture*>(ctx);
        if(output) for(unsigned b=0;b<output->mNumberBuffers;++b)
            if(output->mBuffers[b].mData) memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
        if(c.failed.load()) return noErr;
        for(bool in:{true,false}) {
            if(!in && !c.outChannel) continue;
            unsigned stride=0,local=0;
            auto b=channel(in?const_cast<AudioBufferList*>(input):output,in?c.inChannel:c.outChannel,stride,local);
            auto t=in?it:ot; auto& n=in?c.inCount:c.outCount; auto& nb=in?c.ni:c.no;
            auto& samples=in?c.input:c.output; auto& blocks=in?c.inBlocks:c.outBlocks;
            if(!b || !b->mData || !t || !stride || b->mDataByteSize%(stride*4)) {c.failed=true;return noErr;}
            size_t count=b->mDataByteSize/(stride*4);
            if(n+count>samples.size() || nb==blocks.size()) {c.failed=true;return noErr;}
            blocks[nb++]={n,count,t->mHostTime,t->mSampleTime,t->mFlags};
            auto data=static_cast<float*>(b->mData);
            for(size_t f=0;f<count;++f) {
                if(in) samples[n+f]=data[f*stride+local];
                else data[f*stride+local]=samples[n+f]=c.signal[n+f];
            }
            n+=count;
        }
        return noErr;
    }
    void start() {check(AudioDeviceCreateIOProcID(id,io,this,&proc));check(AudioDeviceStart(id,proc));}
    void setBuffer(UInt32 frames) {
        AudioObjectPropertyAddress a{kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal,0};
        check(AudioObjectSetPropertyData(id,&a,0,nullptr,sizeof(frames),&frames));
        if(property<UInt32>(id,kAudioDevicePropertyBufferFrameSize)!=frames)throw std::runtime_error("Requested client buffer was not applied");
    }
    void readReport() {reports.push_back({mach_absolute_time(),
        property<UInt32>(id,kAudioDevicePropertyLatency,kAudioObjectPropertyScopeInput),
        property<UInt32>(id,kAudioDevicePropertyLatency,kAudioObjectPropertyScopeOutput),
        property<UInt32>(id,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeInput),
        property<UInt32>(id,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeOutput),
        property<UInt32>(id,kAudioDevicePropertyBufferFrameSize)});}
    void stop() {if(proc){AudioDeviceStop(id,proc);AudioDeviceDestroyIOProcID(id,proc);proc=nullptr;}}
    ~Capture(){stop();}
    void save(const std::string& prefix) {
        mach_timebase_info_data_t tb;mach_timebase_info(&tb);
        auto log=fopen((prefix+"-reports.csv").c_str(),"w");if(!log)throw std::runtime_error("Cannot write reports");
        fprintf(log,"host,input,output,inputSafety,outputSafety,buffer\n");for(auto r:reports)fprintf(log,"%llu,%u,%u,%u,%u,%u\n",r.host,r.input,r.output,r.inputSafety,r.outputSafety,r.buffer);fclose(log);
        for(bool in:{true,false}) {
            if(!in && !outChannel) continue;
            std::string path=prefix+(in?"-input":"-output");
            auto f=fopen((path+".f32").c_str(),"wb");if(!f)throw std::runtime_error("Cannot write capture");
            auto n=in?inCount:outCount;auto& samples=in?input:output;
            bool ok=fwrite(samples.data(),sizeof(float),n,f)==n;fclose(f);if(!ok)throw std::runtime_error("Short write");
            f=fopen((path+".csv").c_str(),"w");if(!f)throw std::runtime_error("Cannot write timestamps");
            fprintf(f,"offset,count,host,sample,flags,rate,tick_ns\n");
            auto& blocks=in?inBlocks:outBlocks;
            for(size_t j=0;j<(in?ni:no);++j){auto b=blocks[j];fprintf(f,"%llu,%llu,%llu,%.9f,%u,%.0f,%.12f\n",b.offset,b.count,b.host,b.sample,b.flags,rate,double(tb.numer)/tb.denom);}
            fclose(f);
        }
        printf("device=%u rate=%.0f inputFrames=%zu outputFrames=%zu failed=%d\n",id,rate,inCount,outCount,int(failed.load()));
    }
};
int main(int argc,char** argv) {
    if(argc!=5 && argc!=7){fprintf(stderr,"Usage: latency-capture UID INPUT OUTPUT PREFIX [OBSERVER_UID OBSERVER_INPUT]\n");return 2;}
    try {
        double seconds=6;if(auto value=std::getenv("STUDIOPATCH_TEST_SECONDS"))seconds=std::stod(value);
        if(seconds<6 || seconds>120)throw std::runtime_error("Test duration must be 6..120 seconds");
        Capture primary(argv[1],std::stoul(argv[2]),std::stoul(argv[3]),seconds);
        if(auto frames=std::getenv("STUDIOPATCH_TEST_BUFFER"))primary.setBuffer(std::stoul(frames));
        std::unique_ptr<Capture> observer;
        if(argc==7){observer=std::make_unique<Capture>(argv[5],std::stoul(argv[6]),0,seconds);observer->start();}
        primary.start();
        auto deadline=std::chrono::steady_clock::now()+std::chrono::milliseconds(int(seconds*1000));
        do{primary.readReport();std::this_thread::sleep_for(std::chrono::milliseconds(50));}while(std::chrono::steady_clock::now()<deadline);
        primary.stop();if(observer)observer->stop();
        primary.save(argv[4]);if(observer)observer->save(std::string(argv[4])+"-observer");
        return primary.failed || (observer && observer->failed)?1:0;
    }catch(const std::exception& e){fprintf(stderr,"%s\n",e.what());return 1;}
}
