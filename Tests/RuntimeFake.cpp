#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <sstream>
#include <thread>
#include <chrono>
static bool running=false;
static std::string config="1 2 2 96000 256";
static double hardwareRate=96000;
static std::string root(){return std::getenv("STUDIOPATCH_TEST_DIRECTORY");}
static char* reply(std::string s){return strdup(s.c_str());}
static void event(const char* s){std::ofstream(root()+"/events",std::ios::app)<<s<<"\n";}
extern "C" {
char* SPInventory(){static bool first=true;if(first){event("image");first=false;}if(std::ifstream(root()+"/disconnected").good()) return reply(R"({"devices":[],"driverInstalled":false,"driverConfig":""})");if(std::ifstream(root()+"/inventory-bad-object").good())return reply(R"({"devices":[{"id":1,"uid":"mock","name":"Test master","inputs":2,"outputs":2,"sampleRate":96000,"aggregate":false,"inputNames":["Mic","Line"],"outputNames":["Left","Right"]}],"driverInstalled":false,"driverConfig":"","driverErrorStatus":560947818})");return reply(R"({"devices":[{"id":1,"uid":"mock","name":"Test master","inputs":2,"outputs":2,"sampleRate":)"+std::to_string(hardwareRate)+R"(,"aggregate":false,"inputNames":["Mic","Line"],"outputNames":["Left","Right"]}],"driverInstalled":true,"driverConfig":")"+config+R"("})");}
char* SPRuntimeRates(const char*){
 if(std::ifstream(root()+"/bad-object").good())return reply(R"({"error":"Stale HAL object","coreAudioStatus":560947818})");
 if(std::ifstream(root()+"/hang-control").good()){std::remove((root()+"/hang-control").c_str());std::this_thread::sleep_for(std::chrono::seconds(120));}
std::ifstream f(root()+"/request");double rate=0;f>>rate;return reply("{\"requested\":"+std::to_string(rate)+",\"masterRate\":"+std::to_string(hardwareRate)+"}");}
char* SPSetHardwareRate(const char* raw){event("rate");std::ifstream f(root()+"/fail");if(f.good())return reply("{\"error\":\"Simulated failure\"}");std::string json(raw);auto pos=json.find("\"sampleRate\":");if(pos!=std::string::npos)hardwareRate=std::stod(json.substr(pos+13));return reply("{\"ok\":true}");}
char* SPConfigure(const char* raw){event("configure");std::string json(raw);auto value=[&](std::string key){return std::stoi(json.substr(json.find("\""+key+"\":")+key.size()+3));};config="1 "+std::to_string(value("inputCount"))+" "+std::to_string(value("outputCount"))+" "+std::to_string(value("sampleRate"))+" 256";auto pos=json.find("\"virtualDeviceUID\":\"");if(pos!=std::string::npos){auto start=pos+20;auto uid=json.substr(start,json.find('"',start)-start);if(uid!="se.studiopatch.device.v1"){config[0]='2';config+=" "+uid;}}return reply("{\"ok\":true}");}
char* SPStart(const char*){std::remove((root()+"/invalid-clock").c_str());event("start");running=true;return reply("{\"ok\":true}");}
char* SPUpdateRouting(const char*){event("route");return reply(running?"{\"applied\":true}":"{\"applied\":false}");}
void SPStop(){if(running)event("stop");running=false;}
char* SPStatus(){if(std::ifstream(root()+"/invalid-clock").good())return reply(R"({"running":false,"invalidated":true,"cycles":1,"badBuffers":0,"bufferFrames":64})");return reply(std::string("{\"running\":")+(running?"true":"false")+",\"invalidated\":false,\"cycles\":1,\"badBuffers\":0,\"bufferFrames\":64,\"latencyDiagnostics\":\"{}\"}");}
char* SPSetChannelNames(const char* raw){std::ofstream(root()+"/names.json")<<raw;return reply("{\"ok\":true}");}
char* SPReadChannelLabels(const char*){return reply("{\"error\":\"Unavailable in fake service\"}");}
char* SPSetChannelLabel(const char*){event("label");return reply("{\"ok\":true}");}
char* SPFollowMaster(const char*){return reply("{\"sampleRate\":96000}");}
char* SPAcknowledgeRate(const char*){std::ofstream(root()+"/request")<<0;return reply("{\"ok\":true}");}
void SPFree(char* p){free(p);}
}
