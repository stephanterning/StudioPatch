#include "../Sources/Bridge.mm"
#include "../Sources/Driver.cpp"
#include <cassert>
#include <iostream>
#include <thread>

// Run the real HAL handler and hardware callback on independent schedules.
// Producers publish only when their callback executes, never future fixtures.
static void transfer(uint32_t rate,uint32_t hardwareFrames,uint32_t clientFrames,uint32_t phase,uint32_t secondaryFrames=0,bool clientFirst=false,uint32_t secondaryDelay=0) {
    auto mapping=std::make_shared<patch::SharedMapping>();mapping->size=sizeof(patch::SharedTransport);
    mapping->data=new(mmap(nullptr,mapping->size,PROT_READ|PROT_WRITE,MAP_ANON|MAP_SHARED,-1,0)) patch::SharedTransport;
    auto& shared=*mapping->data;shared.rate=rate;shared.inputs=2;shared.outputs=2;shared.active=1;
    auto session=std::make_shared<patch::Session>(patch::Config::parse("1 2 2 "+std::to_string(rate)+" 256"),true,[mapping]{return mapping;});
    for(int n=0;n<1000 && !session->direct;++n)std::this_thread::sleep_for(std::chrono::milliseconds(1));
    assert(session->direct);
    patch::Handler driver(session,false);
    DirectEngine engine;engine.memory=mapping;engine.nominalTicks=24000000.0/rate;
    DirectEngine::DeviceIO device;device.owner=&engine;device.master=true;device.inLayout={1};device.outLayout={1};
    device.inputs={{{0,0,1},0}};device.outputs={{0,{0,0,1}}};
    if(!secondaryFrames)secondaryFrames=hardwareFrames;
    DirectEngine::DeviceIO secondary;secondary.owner=&engine;secondary.inLayout={1};secondary.outLayout={1};
    secondary.inputs={{{0,0,1},1}};secondary.outputs={{1,{0,0,1}}};
    secondary.offset=12345;secondary.aligned=true;secondary.extraInput=240;secondary.extraOutput=80;
    engine.observeBlock(hardwareFrames);
    auto largest=std::max(hardwareFrames,secondaryFrames);
    std::vector<float> input(largest),output(largest),fromClient(2*clientFrames),toClient(2*clientFrames);
    constexpr int64_t origin=32768,safety=48,warmup=8192,duration=24576;
    auto value=[](int64_t frame,uint32_t channel){return float(1+(frame%4093))/4096.0f*(channel?-1:1);};
    uint64_t playbackErrors=0,captureErrors=0,checked=0;
    int64_t hardware=0,other=13,client=phase;
    while(std::min({hardware,other,client})<duration) {
        // Exercise both thread orders when callback deadlines coincide.
        auto nextHardware=std::min(hardware,other+secondaryDelay);
        if(nextHardware<client || (nextHardware==client && !clientFirst)) {
            bool master=hardware<=other+secondaryDelay;auto& d=master?device:secondary;
            auto& scheduled=master?hardware:other;auto frames=master?hardwareFrames:secondaryFrames;
            uint32_t channel=master?0:1;
            int64_t time=origin+scheduled;
            AudioTimeStamp now{},it{},ot{};
            now.mFlags=it.mFlags=ot.mFlags=kAudioTimeStampSampleHostTimeValid;
            now.mSampleTime=time+(master?0:secondaryDelay)-d.offset;
            it.mSampleTime=time-d.offset-frames-safety-d.extraInput;ot.mSampleTime=time-d.offset+frames+safety+d.extraOutput;
            now.mHostTime=(now.mSampleTime+d.offset)*engine.nominalTicks;it.mHostTime=(it.mSampleTime+d.offset)*engine.nominalTicks;ot.mHostTime=(ot.mSampleTime+d.offset)*engine.nominalTicks;
            for(uint32_t n=0;n<frames;++n)input[n]=value(int64_t(it.mSampleTime+d.offset)+n,channel);
            AudioBufferList in{1,{{1,frames*4,input.data()}}},out{1,{{1,frames*4,output.data()}}};
            DirectEngine::io(0,&now,&in,&it,&out,&ot,&d);
            if(scheduled>=warmup)for(uint32_t n=0;n<frames;++n) {
                auto read=int64_t(ot.mSampleTime+d.offset)-shared.padding-d.extraOutput-engine.additionalPadding(d,false);
                ++checked;if(output[n]!=value(read+n,channel))++playbackErrors;
            }
            scheduled+=frames;
        } else {
            int64_t time=origin+client,read=time-clientFrames-safety,write=time+clientFrames+safety;
            for(uint32_t n=0;n<clientFrames;++n)for(uint32_t c=0;c<2;++c)fromClient[2*n+c]=value(write+n,c);
            driver.OnWriteMixedOutput(nullptr,0,write,fromClient.data(),clientFrames*8);
            driver.OnReadClientInput(nullptr,nullptr,0,read,toClient.data(),clientFrames*8);
            if(client>=warmup)for(uint32_t n=0;n<clientFrames;++n)for(uint32_t c=0;c<2;++c) {
                auto& d=c?secondary:device;
                if(toClient[2*n+c]!=value(read-shared.inputPadding-d.extraInput-engine.additionalPadding(d,true)+n,c))++captureErrors;
            }
            client+=clientFrames;
        }
    }
    if(playbackErrors || captureErrors)std::cerr<<"rate="<<rate<<" hardware="<<hardwareFrames<<" secondary="<<secondaryFrames<<" client="<<clientFrames<<" phase="<<phase
        <<" missing/corrupt playback="<<playbackErrors<<"/"<<checked<<" capture="<<captureErrors<<"\n";
    assert(playbackErrors==0 && captureErrors==0);
}
int main() { @autoreleasepool {
    for(uint32_t rate:{48000,96000,192000}) {
        // inNow includes wake-up latency, while input timestamps still name
        // the same contiguous hardware blocks. A client can run in that gap.
        transfer(rate,1024,32,7,1024,true,1023);
        for(uint32_t hardware:{32,64,128,256,512,1024})
            for(uint32_t client:{32,64,128,256,512,1024})
                for(uint32_t phase:{0u,7u,client-1})transfer(rate,hardware,client,phase,hardware,false,
                    phase==7?hardware-1:0);
        for(uint32_t secondary:{32,64,128,256,512,1024})
            for(uint32_t client:{1,47,256,1024}) {
                transfer(rate,32,client,0,secondary);
                transfer(rate,1024,client,client-1,secondary,true);
            }
    }
    std::cout<<"PASS: independent capture/playback schedules, 32–1024 frame interfaces, differing secondary buffers/safety offsets, 1–1024 frame clients, ring wrap, 48/96/192 kHz\n";
} }
