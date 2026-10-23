#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <sstream>
static bool running=false;
static std::string config="1 2 2 96000 256";
static double hardwareRate=96000;
static std::string root(){return std::getenv("STUDIOPATCH_TEST_DIRECTORY");}
static char* reply(std::string s){return strdup(s.c_str());}
static void event(const char* s){std::ofstream(root()+"/events",std::ios::app)<<s<<"\n";}
extern "C" {
char* SPInventory(){if(std::ifstream(root()+"/disconnected").good()) return reply(R"({"devices":[],"driverInstalled":false,"driverConfig":""})");return reply(R"({"devices":[{"id":1,"uid":"mock","name":"Test master","inputs":2,"outputs":2,"sampleRate":)"+std::to_string(hardwareRate)+R"(,"aggregate":false,"inputNames":["Mic","Line"],"outputNames":["Left","Right"]}],"driverInstalled":true,"driverConfig":")"+config+R"("})");}
char* SPRuntimeRates(const char*){std::ifstream f(root()+"/request");double rate=0;f>>rate;return reply("{\"requested\":"+std::to_string(rate)+",\"masterRate\":"+std::to_string(hardwareRate)+"}");}
char* SPSetHardwareRate(const char* raw){event("rate");std::ifstream f(root()+"/fail");if(f.good())return reply("{\"error\":\"Simulated failure\"}");std::string json(raw);auto pos=json.find("\"sampleRate\":");if(pos!=std::string::npos)hardwareRate=std::stod(json.substr(pos+13));return reply("{\"ok\":true}");}
char* SPConfigure(const char* raw){event("configure");std::string json(raw);auto value=[&](std::string key){return std::stoi(json.substr(json.find("\""+key+"\":")+key.size()+3));};config="1 "+std::to_string(value("inputCount"))+" "+std::to_string(value("outputCount"))+" "+std::to_string(value("sampleRate"))+" 256";return reply("{\"ok\":true}");}
char* SPStart(const char*){event("start");running=true;return reply("{\"ok\":true}");}
void SPStop(){if(running)event("stop");running=false;}
char* SPStatus(){return reply(std::string("{\"running\":")+(running?"true":"false")+",\"invalidated\":false,\"cycles\":1,\"badBuffers\":0,\"bufferFrames\":64}");}
char* SPSetChannelNames(const char*){return reply("{\"ok\":true}");}
char* SPFollowMaster(const char*){return reply("{\"sampleRate\":96000}");}
char* SPAcknowledgeRate(const char*){std::ofstream(root()+"/request")<<0;return reply("{\"ok\":true}");}
void SPFree(char* p){free(p);}
}
