#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <sstream>
static bool running=false,available=false;
static std::string deviceName="StudioPatch";
static std::string config="1 2 2 96000 256";
static double hardwareRate=96000,secondaryRate=96000;
static std::string root(){return std::getenv("STUDIOPATCH_TEST_DIRECTORY");}
static bool flag(const char* name){return std::ifstream(root()+"/"+name).good();}
static char* reply(std::string s){return strdup(s.c_str());}
static void event(const char* s){std::ofstream(root()+"/events",std::ios::app)<<s<<"\n";}
extern "C" {
char* SPInventory(){
 static bool first=true;if(first){event("image");first=false;}
 // metadata-gap: the device is still connected but its metadata could not be read.
 bool omitted=flag("disconnected") || flag("metadata-gap");
 // inventory-rate: inventory reports an outdated master rate.
 double listedRate=hardwareRate;std::ifstream(root()+"/inventory-rate")>>listedRate;
 std::string devices=omitted?"":R"({"id":1,"uid":"mock","name":"Test master","inputs":2,"outputs":2,"sampleRate":)"+std::to_string(listedRate)+R"(,"aggregate":false,"inputNames":["Mic","Line"],"outputNames":["Left","Right"]})";
 // secondary-rate: someone else changed the secondary's rate.
 std::ifstream changed(root()+"/secondary-rate");if(changed>>secondaryRate)std::remove((root()+"/secondary-rate").c_str());
 if(flag("secondary-present")) {
  if(!devices.empty())devices+=",";
  devices+=R"({"id":2,"uid":"secondary","name":"Test secondary","inputs":2,"outputs":2,"sampleRate":)"+std::to_string(secondaryRate)+R"(,"aggregate":false,"inputNames":["Mic","Line"],"outputNames":["Left","Right"]})";
 }
 bool failed=flag("inventory-bad-object");
 return reply("{\"devices\":["+devices+"],\"driverInstalled\":"+(failed?"false":"true")+",\"driverConfig\":\""+config+"\""+(failed?",\"driverErrorStatus\":560947818":"")+"}");
}
char* SPMissingDevices(const char* raw){
 std::string request(raw),missing;
 auto add=[&](const char* uid){if(request.find(std::string("\"")+uid+"\"")!=std::string::npos)missing+=std::string(missing.empty()?"":",")+"\""+uid+"\"";};
 if(flag("disconnected"))add("mock");
 if(!flag("secondary-present"))add("secondary");
 return reply("{\"missing\":["+missing+"]}");
}
char* SPSetDeviceAvailable(const char* raw){
 bool next=std::string(raw).find("true")!=std::string::npos;
 if(next && !running)return reply(R"({"error":"Cannot publish before routing starts"})");
 if(next && flag("publish-fail"))return reply(R"({"error":"Simulated publication failure"})");
 bool changed=next!=available;available=next;
 if(changed)event(next?"available":"unavailable");
 std::ofstream(root()+"/availability")<<(available?"1":"0");
 return reply(std::string("{\"changed\":")+(changed?"true":"false")+",\"deviceName\":\""+deviceName+"\"}");
}
char* SPRuntimeRates(const char*){
 if(flag("bad-object"))return reply(R"({"error":"Stale HAL object","coreAudioStatus":560947818})");
 std::ifstream f(root()+"/request");double rate=0;f>>rate;return reply("{\"requested\":"+std::to_string(rate)+",\"masterRate\":"+std::to_string(hardwareRate)+"}");
}
char* SPSetHardwareRate(const char* raw){
 event("rate");
 if(flag("fail"))return reply("{\"error\":\"Simulated failure\"}");
 if(flag("rate-error"))return reply(R"({"error":"Simulated rate control failure"})");
 std::string json(raw),warnings;auto pos=json.find("\"sampleRate\":");
 double target=pos!=std::string::npos?std::stod(json.substr(pos+13)):hardwareRate;
 if(flag("master-refuses"))warnings=R"("Test master rejected the rate.")";else hardwareRate=target;
 if(json.find(R"("syncLocked":true,"uid":"secondary")")!=std::string::npos) {
  if(flag("locked-refuses"))warnings+=std::string(warnings.empty()?"":",")+R"("Test secondary does not support the rate.")";
  else secondaryRate=hardwareRate;
 }
 return reply("{\"rate\":"+std::to_string(hardwareRate)+",\"warnings\":["+warnings+"]}");
}
char* SPConfigure(const char* raw){if(flag("configure-unavailable"))return reply(R"({"error":"Simulated broker unavailable"})");event("configure");std::string json(raw);
 // configure-fail: the driver rejects configurations with this output count.
 std::string rejected;std::ifstream(root()+"/configure-fail")>>rejected;
 if(!rejected.empty() && json.find("\"outputCount\":"+rejected+",")!=std::string::npos)return reply(R"({"error":"Simulated configuration rejection"})");
auto value=[&](std::string key){return std::stoi(json.substr(json.find("\""+key+"\":")+key.size()+3));};config="1 "+std::to_string(value("inputCount"))+" "+std::to_string(value("outputCount"))+" "+std::to_string(value("sampleRate"))+" 256";auto pos=json.find("\"virtualDeviceUID\":\"");if(pos!=std::string::npos){auto start=pos+20;auto uid=json.substr(start,json.find('"',start)-start);if(uid!="se.studiopatch.device.v1"){config[0]='2';config+=" "+uid;}}return reply("{\"ok\":true}");}
char* SPStart(const char*){if(flag("start-fail"))return reply(R"({"error":"Simulated start failure"})");std::remove((root()+"/stale-hardware").c_str());event("start");running=true;return reply("{\"ok\":true}");}
char* SPUpdateRouting(const char*){event("route");return reply(running?"{\"applied\":true}":"{\"applied\":false}");}
void SPStop(){if(running)event("stop");running=false;}
char* SPPublishLatency(){return reply("{\"ok\":true}");}
char* SPStatus(){
 std::string diagnostics="{}";double skew=0;std::ifstream skewFile(root()+"/clock-skew");
 if(skewFile>>skew)diagnostics=R"({\"devices\":[{\"deviceID\":2,\"master\":false,\"clockSkewFrames\":)"+std::to_string(skew)+R"(,\"peakClockSkewFrames\":)"+std::to_string(skew)+R"(}]})";
 return reply(std::string("{\"running\":")+(running?"true":"false")+",\"stale\":"+(flag("stale-hardware")?"true":"false")+",\"warnings\":[],\"cycles\":1,\"badBuffers\":0,\"bufferFrames\":64,\"latencyDiagnostics\":\""+diagnostics+"\"}");
}
char* SPSetChannelNames(const char* raw){
 if(flag("names-fail"))return reply(R"({"error":"Simulated channel-name write failure"})");
 std::string json(raw);auto pos=json.find("\"deviceName\":\"");if(pos!=std::string::npos){auto start=pos+14;deviceName=json.substr(start,json.find('"',start)-start);}std::ofstream(root()+"/names.json")<<raw;return reply("{\"ok\":true}");
}
char* SPReadChannelLabels(const char*){return reply("{\"error\":\"Unavailable in fake service\"}");}
char* SPSetChannelLabel(const char*){event("label");return reply("{\"ok\":true}");}
char* SPFollowMaster(const char*){return reply("{\"sampleRate\":96000}");}
char* SPAcknowledgeRate(const char*){
 if(flag("ack-fail"))return reply(R"({"error":"Simulated acknowledgement failure"})");
 std::ofstream(root()+"/request")<<0;return reply("{\"ok\":true}");
}
void SPFree(char* p){free(p);}
}
