// Manual Core Audio integration probe. Creates only process-private aggregates,
// starts no audio, and changes names only on the devices it creates.
#import <Foundation/Foundation.h>
#include <CoreAudio/CoreAudio.h>
#include <atomic>
#include <chrono>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <thread>
#include <vector>

static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope=kAudioObjectPropertyScopeGlobal, UInt32 element=0) {
    return {selector,scope,element};
}
static void check(OSStatus status,const char* action) {
    if(status)throw std::runtime_error(std::string(action)+": "+std::to_string(status));
}
static NSString* name(AudioObjectID device,AudioObjectPropertyScope scope,UInt32 channel) {
    auto a=address(kAudioObjectPropertyElementName,scope,channel);
    CFStringRef value=nullptr;UInt32 size=sizeof(value);
    check(AudioObjectGetPropertyData(device,&a,0,nullptr,&size,&value),"read channel name");
    return CFBridgingRelease(value) ?: @"";
}
static OSStatus setName(AudioObjectID device,AudioObjectPropertyScope scope,UInt32 channel,NSString* text) {
    auto a=address(kAudioObjectPropertyElementName,scope,channel);
    CFStringRef value=(__bridge CFStringRef)text;
    return AudioObjectSetPropertyData(device,&a,0,nullptr,sizeof(value),&value);
}
static void awaitName(AudioObjectID device,AudioObjectPropertyScope scope,UInt32 channel,NSString* expected) {
    for(int i=0;i<100;++i) {
        if([name(device,scope,channel) isEqualToString:expected])return;
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    throw std::runtime_error("Timed out waiting for channel name: "+std::string(expected.UTF8String));
}
static void report(NSString* stage,NSDictionary* fields) {
    NSMutableDictionary* value=[fields mutableCopy];value[@"stage"]=stage;
    NSData* data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    std::cout<<std::string((const char*)data.bytes,data.length)<<std::endl;
}
struct NameListener {
    AudioObjectID id;
    AudioObjectPropertyAddress property;
    dispatch_queue_t queue=dispatch_queue_create("se.studiopatch.label-probe.listener",DISPATCH_QUEUE_SERIAL);
    std::shared_ptr<std::atomic<unsigned>> count=std::make_shared<std::atomic<unsigned>>(0);
    AudioObjectPropertyListenerBlock block;
    NameListener(AudioObjectID device,AudioObjectPropertyScope scope):id(device),
        property(address(kAudioObjectPropertyElementName,scope,kAudioObjectPropertyElementWildcard)) {
        auto counter=count;
        block=^(UInt32 n,const AudioObjectPropertyAddress*) {counter->fetch_add(n);};
        check(AudioObjectAddPropertyListenerBlock(id,&property,queue,block),"subscribe to channel-name changes");
    }
    void after(unsigned previous) {
        for(int i=0;i<100;++i) {
            if(count->load()>previous)return;
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
        throw std::runtime_error("No channel-name change notification received");
    }
    ~NameListener() {
        AudioObjectRemovePropertyListenerBlock(id,&property,queue,block);
        dispatch_sync(queue,^{});
    }
};
struct PrivateDevice {
    AudioDeviceID id=0;
    NSString* uid;
    NSDictionary* spec;
    std::vector<std::pair<AudioObjectPropertyScope,UInt32>> touched;
    explicit PrivateDevice(NSString* suffix,NSString* member) {
        uid=[@"se.studiopatch.label-probe." stringByAppendingString:suffix];
        spec=@{@kAudioAggregateDeviceUIDKey:uid,
            @kAudioAggregateDeviceNameKey:[@"StudioPatch label probe " stringByAppendingString:suffix],
            @kAudioAggregateDeviceIsPrivateKey:@YES,
            @kAudioAggregateDeviceIsStackedKey:@NO,
            @kAudioAggregateDeviceMainSubDeviceKey:member,
            @kAudioAggregateDeviceSubDeviceListKey:@[@{@kAudioSubDeviceUIDKey:member,
                @kAudioSubDeviceDriftCompensationKey:@NO}]};
        check(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)spec,&id),"create private aggregate");
        report(@"created",@{@"uid":uid,@"id":@(id)});
    }
    void write(AudioObjectPropertyScope scope,UInt32 channel,NSString* text) {
        touched.emplace_back(scope,channel);
        auto status=setName(id,scope,channel,text);
        report(@"set",@{@"uid":uid,@"scope":@(scope),@"channel":@(channel),@"value":text ?: @"<null>",@"status":@(status)});
        check(status,"set channel name");
    }
    void members(NSArray<NSString*>* members) {
        auto a=address(kAudioAggregateDevicePropertyFullSubDeviceList);
        CFArrayRef value=(__bridge CFArrayRef)members;
        check(AudioObjectSetPropertyData(id,&a,0,nullptr,sizeof(value),&value),"change private aggregate members");
        report(@"members",@{@"uid":uid,@"members":members});
    }
    ~PrivateDevice() {
        if(!id)return;
        for(auto [scope,channel]:touched) {
            auto status=setName(id,scope,channel,@"");
            if(status)report(@"cleanup-name-failed",@{@"uid":uid,@"status":@(status)});
        }
        auto status=AudioHardwareDestroyAggregateDevice(id);
        report(@"destroyed",@{@"uid":uid,@"status":@(status)});
    }
};

int main(int argc,char** argv) { @autoreleasepool {
    try {
        NSString* suffix=NSUUID.UUID.UUIDString;
        NSString* member=argc>1 ? @(argv[1]) : @"se.studiopatch.device.v1";
        PrivateDevice source([suffix stringByAppendingString:@".source"],member);
        PrivateDevice target([suffix stringByAppendingString:@".target"],member);
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
        for(auto scope:{kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput}) {
            NameListener observer(source.id,scope);
            NSString* sourceDefault=name(source.id,scope,1);
            NSString* targetDefault=name(target.id,scope,1);
            report(@"defaults",@{@"scope":@(scope),@"source":sourceDefault,@"target":targetDefault});
            NSString* manual=[@"StudioPatch probe manual " stringByAppendingString:suffix];
            auto previous=observer.count->load();
            source.write(scope,1,manual);
            awaitName(source.id,scope,1,manual);
            observer.after(previous);
            awaitName(target.id,scope,1,targetDefault);
            target.write(scope,1,name(source.id,scope,1));
            awaitName(target.id,scope,1,manual);
            report(@"copy-known-manual-passed",@{@"scope":@(scope)});
            target.write(scope,1,@"");
            awaitName(target.id,scope,1,targetDefault);
            previous=observer.count->load();
            source.write(scope,1,@"");
            awaitName(source.id,scope,1,sourceDefault);
            observer.after(previous);
            report(@"clear-empty-string-passed",@{@"scope":@(scope)});
            report(@"set-and-clear-notifications-passed",@{@"scope":@(scope)});
            source.write(scope,1,sourceDefault);
            awaitName(source.id,scope,1,sourceDefault);
            report(@"equal-manual-and-default",@{@"scope":@(scope),
                @"sourceManual":name(source.id,scope,1),@"targetAutomatic":name(target.id,scope,1)});
            source.members(@[]);
            target.members(@[]);
            awaitName(target.id,scope,1,@"");
            awaitName(source.id,scope,1,sourceDefault);
            report(@"equal-manual-survives-default-change",@{@"scope":@(scope),
                @"sourceManual":name(source.id,scope,1),@"targetAutomatic":name(target.id,scope,1)});
            source.write(scope,1,@"");
            awaitName(source.id,scope,1,@"");
            source.members(@[member]);
            target.members(@[member]);
            awaitName(source.id,scope,1,sourceDefault);
            awaitName(target.id,scope,1,targetDefault);
            report(@"cleared-label-follows-default-changes",@{@"scope":@(scope)});
        }
        report(@"basic-probe-passed",@{@"note":@"Copy uses effective names differing from defaults. Native driver UID persistence requires a separate lifecycle test."});
        return 0;
    } catch(const std::exception& e) {
        report(@"failed",@{@"error":@(e.what())});return 1;
    }
} }
