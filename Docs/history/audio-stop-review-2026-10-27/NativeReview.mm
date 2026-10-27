#import <Foundation/Foundation.h>
#include <CoreAudio/CoreAudio.h>
static OSStatus reviewRead(AudioObjectID,const AudioObjectPropertyAddress*,UInt32,const void*,UInt32*,void*);
static OSStatus reviewSize(AudioObjectID,const AudioObjectPropertyAddress*,UInt32,const void*,UInt32*);
static OSStatus reviewSet(AudioObjectID,const AudioObjectPropertyAddress*,UInt32,const void*,UInt32,const void*);
#define AudioObjectGetPropertyData reviewRead
#define AudioObjectGetPropertyDataSize reviewSize
#define AudioObjectSetPropertyData reviewSet
#include "Bridge.mm"
#include <cassert>
#include <iostream>
static bool started=false,failLatency=false,failSecondary=false,failMasterRate=false,failBufferRead=false;
static UInt32 actualBuffer=32;
static OSStatus reviewSize(AudioObjectID,const AudioObjectPropertyAddress* a,UInt32,const void*,UInt32* size) {
 switch(a->mSelector) {
 case kAudioDevicePropertyStreamConfiguration:*size=sizeof(AudioBufferList);return noErr;
 case kAudioDevicePropertyStreams:*size=sizeof(AudioStreamID);return noErr;
 case kAudioDevicePropertyAvailableNominalSampleRates:*size=sizeof(AudioValueRange);return noErr;
 default:return kAudioHardwareBadObjectError;
 }
}
static OSStatus reviewRead(AudioObjectID id,const AudioObjectPropertyAddress* a,UInt32,const void* q,UInt32* size,void* out) {
 switch(a->mSelector) {
 case kAudioHardwarePropertyTranslateUIDToDevice: {
  bool secondary=CFEqual(*static_cast<const CFStringRef*>(q),CFSTR("secondary"));
  if(secondary && failSecondary)return kAudioHardwareBadObjectError;
  *static_cast<AudioDeviceID*>(out)=secondary?20:10;return noErr;
 }
 case kAudioObjectPropertyName:*static_cast<CFStringRef*>(out)=CFStringCreateCopy(nullptr,CFSTR("Review interface"));return noErr;
 case kAudioDevicePropertyDeviceIsAlive:*static_cast<UInt32*>(out)=1;return noErr;
 case kAudioDevicePropertyTransportType:*static_cast<UInt32*>(out)=kAudioDeviceTransportTypeUSB;return noErr;
 case kAudioDevicePropertyBufferFrameSize:if(failBufferRead)return kAudioHardwareBadObjectError;*static_cast<UInt32*>(out)=actualBuffer;return noErr;
 case kAudioDevicePropertySafetyOffset:*static_cast<UInt32*>(out)=0;return noErr;
 case kAudioDevicePropertyNominalSampleRate:if(failMasterRate && id==10)return kAudioHardwareBadObjectError;*static_cast<Float64*>(out)=96000;return noErr;
 case kAudioDevicePropertyAvailableNominalSampleRates:*static_cast<AudioValueRange*>(out)={96000,96000};return noErr;
 case kAudioDevicePropertyStreamConfiguration:*static_cast<AudioBufferList*>(out)={1,{{2,0,nullptr}}};return noErr;
 case kAudioDevicePropertyStreams:*static_cast<AudioStreamID*>(out)=id+100;return noErr;
 case kAudioStreamPropertyVirtualFormat:*static_cast<AudioStreamBasicDescription*>(out)={96000,kAudioFormatLinearPCM,kAudioFormatFlagsNativeFloatPacked,8,1,8,2,32,0};return noErr;
 case kAudioDevicePropertyLatency:if(failLatency)return kAudioHardwareUnknownPropertyError;*static_cast<UInt32*>(out)=started && id<100?16:0;return noErr;
 default:return kAudioHardwareBadObjectError;
 }
}
static OSStatus reviewSet(AudioObjectID,const AudioObjectPropertyAddress*,UInt32,const void*,UInt32,const void*) {return noErr;}
int main() { @autoreleasepool {
 NSDictionary* request=@{@"inputCount":@2,@"outputCount":@2,@"sampleRate":@96000,@"bufferFrames":@32,@"masterUID":@"master",
   @"devices":@[@{@"uid":@"master",@"drift":@NO},@{@"uid":@"secondary",@"drift":@NO,@"syncLocked":@YES}],@"inputs":@[],@"outputs":@[]};
 auto callRate=[](NSDictionary* request) {
   auto data=[NSJSONSerialization dataWithJSONObject:request options:0 error:nil];auto text=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
   char* raw=SPSetHardwareRate(text.UTF8String);NSDictionary* result=json(raw);free(raw);return result;
 };
 failSecondary=true;auto result=callRate(request);assert(!result[@"error"] && [result[@"warnings"] count]>0);failSecondary=false;
 std::cout<<"PASS: secondary lookup failure becomes a warning\n";
 DirectEngine e;e.syncSource=10;
 failLatency=true;auto d=e.openDevice(request[@"devices"][0],@"master",32);assert(d && !e.deviceWarnings.empty());failLatency=false;
 std::cout<<"PASS: unreadable latency metadata no longer prevents master open\n";
 for(int i=0;i<3;++i) {
  started=false;e.devices.push_back(e.openDevice(request[@"devices"][0],@"master",32));assert(!e.stale());
  started=true;assert(!e.stale());e.devices.clear();
 }
 std::cout<<"PASS: changing only latency at I/O start does not make the graph stale (3/3)\n";
 actualBuffer=64;
 for(int i=0;i<3;++i) {
  failBufferRead=true;e.devices.push_back(e.openDevice(request[@"devices"][0],@"master",32));
  failBufferRead=false;assert(e.stale());e.devices.clear();
 }
 actualBuffer=32;
 std::cout<<"REPRODUCED in simulated HAL: unreadable buffer size at open is assumed 32; real 64 is treated as a change after every open (3/3)\n";

 NSMutableDictionary* changed=[request mutableCopy];changed[@"devices"]=@[@{@"uid":@"master",@"drift":@NO},@{@"uid":@"secondary",@"drift":@NO,@"syncLocked":@NO}];
 assert([DirectEngine::graphOf(request) isEqual:DirectEngine::graphOf(changed)]);
 std::cout<<"PASS: toggling sync lock leaves the graph equivalent\n";
 changed[@"sampleRate"]=@48000;failMasterRate=true;
 result=callRate(changed);assert([result[@"rate"] intValue]==48000 && !result[@"error"]);
 std::cout<<"REPRODUCED: master remains 96000, both rate reads fail, SPSetHardwareRate reports 48000 as rate\n";
} }
