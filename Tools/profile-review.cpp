#include "../Sources/Driver.cpp"
#include <chrono>
#include <thread>
#include <algorithm>
#include <iostream>
using Clock=std::chrono::steady_clock;
int main(){
    auto memory=std::make_unique<patch::SharedTransport>();std::vector<double> times;
    volatile float sink=0;
    for(int run=0;run<10000;++run){auto start=Clock::now();auto frame=int64_t(run)*32;
        for(unsigned n=0;n<32;++n){
            for(unsigned c=0;c<46;++c)memory->capture.write(c,frame+n,.1f);
            for(unsigned c=0;c<40;++c)memory->playback.write(c,frame+n,.1f);
            for(unsigned c=0;c<46;++c)sink=memory->capture.read(c,frame+n);
            for(unsigned c=0;c<40;++c)sink=memory->playback.read(c,frame+n);
        }
        times.push_back(std::chrono::duration<double,std::micro>(Clock::now()-start).count());
    }
    auto report=[](const char* label,std::vector<double>& v){std::sort(v.begin(),v.end());std::cout<<label<<" p50_us="<<v[v.size()/2]<<" p99_us="<<v[v.size()*99/100]<<" max_us="<<v.back()<<"\n";};
    report("tagged_storage_46in_40out_32frames",times);
    auto ctx=std::make_shared<aspl::Context>(std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    auto session=std::make_shared<patch::Session>(patch::Config{});auto device=patch::endpoint(ctx,session,false);
    device->StartIO(device->GetID(),1);
    std::atomic<bool> done{false};std::thread churn([&]{while(!done){device->StartIO(device->GetID(),2);device->StopIO(device->GetID(),2);}});
    times.clear();for(int i=0;i<10000;++i){double sample;uint64_t host,seed;auto start=Clock::now();device->GetZeroTimeStamp(device->GetID(),1,&sample,&host,&seed);times.push_back(std::chrono::duration<double,std::micro>(Clock::now()-start).count());}
    done=true;churn.join();device->StopIO(device->GetID(),1);report("zero_timestamp_with_start_stop_contention",times);
}
