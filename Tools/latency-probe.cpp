#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cstdio>
#include <vector>
#include <string>
AudioObjectPropertyAddress addr(UInt32 sel,UInt32 scope=kAudioObjectPropertyScopeGlobal){return {sel,scope,kAudioObjectPropertyElementMain};}
template<class T> bool get(AudioObjectID id,UInt32 key,T& v,UInt32 scope=kAudioObjectPropertyScopeGlobal){auto a=addr(key,scope);UInt32 n=sizeof(v);return AudioObjectGetPropertyData(id,&a,0,nullptr,&n,&v)==noErr;}
template<class T> std::vector<T> list(AudioObjectID id,UInt32 key,UInt32 scope=kAudioObjectPropertyScopeGlobal){auto a=addr(key,scope);UInt32 n=0;if(AudioObjectGetPropertyDataSize(id,&a,0,nullptr,&n))return {};std::vector<T> v(n/sizeof(T));if(n&&AudioObjectGetPropertyData(id,&a,0,nullptr,&n,v.data()))return {};return v;}
std::string str(AudioObjectID id,UInt32 key){CFStringRef s=nullptr;if(!get(id,key,s)||!s)return "unavailable";char b[4096]={};CFStringGetCString(s,b,sizeof(b),kCFStringEncodingUTF8);CFRelease(s);return b;}
int main(){for(auto id:list<AudioObjectID>(kAudioObjectSystemObject,kAudioHardwarePropertyDevices)){
 auto name=str(id,kAudioObjectPropertyName);if(name.find("StudioPatch")==std::string::npos&&name.find("UFX")==std::string::npos&&name.find("ZED")==std::string::npos)continue;
 Float64 rate=0;UInt32 frames=0;get(id,kAudioDevicePropertyNominalSampleRate,rate);get(id,kAudioDevicePropertyBufferFrameSize,frames);
 printf("%s: rate=%.0f buffer=%u\n",name.c_str(),rate,frames);
 for(auto scope:{kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput}){
  printf("  %s",scope==kAudioObjectPropertyScopeInput?"input":"output");
  UInt32 n=0;if(get(id,kAudioDevicePropertyLatency,n,scope))printf(" deviceLatency=%u",n);else printf(" deviceLatency=unavailable");
  if(get(id,kAudioDevicePropertySafetyOffset,n,scope))printf(" safetyOffset=%u",n);else printf(" safetyOffset=unavailable");
  printf(" streamLatencies=[");for(auto st:list<AudioStreamID>(id,kAudioDevicePropertyStreams,scope)){if(get(st,kAudioStreamPropertyLatency,n))printf("%u ",n);else printf("? ");}printf("]\n");
 }
}
CFStringRef bundle=CFSTR("se.studiopatch.driver");auto a=addr(kAudioHardwarePropertyTranslateBundleIDToPlugIn);AudioObjectID plugin=0;UInt32 n=sizeof(plugin);auto err=AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(bundle),&bundle,&n,&plugin);
if(!err&&plugin){printf("driverConfig: %s\n",str(plugin,0x73706366).c_str());printf("missingFrames capture/playback: %s\n",str(plugin,0x73707374).c_str());}else printf("Driver statistics unavailable: %d\n",int(err));
}
