#define main capture_tool_main
#include "../Tools/latency-capture.cpp"
#undef main
#include <cassert>
#include <unistd.h>
int main(){
    char folder[]="/private/tmp/studiopatch-stream-XXXXXX";assert(mkdtemp(folder));
    std::string prefix=std::string(folder)+"/test";
    CaptureStream stream;stream.start(prefix,96000);
    float values[]{.25f,9,-.5f,9};
    assert(stream.push({0,2,100,10,3},true,values,2));
    assert(stream.push({0,2,100,10,3},false,values,2));
    stream.finish();assert(!stream.failed);
    auto f=fopen((prefix+"-input.f32").c_str(),"rb");float read[2];assert(fread(read,4,2,f)==2);fclose(f);
    assert(read[0]==.25f && read[1]==-.5f);
    CaptureStream full;
    for(int i=0;i<256;++i)assert(full.push({uint64_t(i),1,100,10,3},true,values,1));
    assert(!full.push({256,1,100,10,3},true,values,1) && full.failed);
    for(auto suffix:{"-input.f32","-output.f32","-input.csv","-output.csv"})unlink((prefix+suffix).c_str());rmdir(folder);
}
