#include "SharedTransport.hpp"
#include <sys/stat.h>
#include <pwd.h>
#include <fstream>
#include <iterator>

int main(int argc,char** argv) {
    if(argc!=2)return 2;
    std::ifstream file(argv[1]);std::string requirement((std::istreambuf_iterator<char>(file)),{});
    if(requirement.empty())return 2;
    auto audioUser=getpwnam("_coreaudiod");if(!audioUser)return 2;const auto audioUID=audioUser->pw_uid;
    auto queue=dispatch_queue_create("se.studiopatch.broker",DISPATCH_QUEUE_SERIAL);
    auto listener=xpc_connection_create_mach_service(patch::BrokerName,queue,XPC_CONNECTION_MACH_SERVICE_LISTENER);
    static xpc_object_t memory=nullptr;static uint64_t generation=0;
    static uint64_t registrationSerial=0,currentRegistration=0;
    static void* backing=nullptr; // Own the mapping for the lifetime of this session.
    xpc_connection_set_event_handler(listener,^(xpc_object_t event){
        if(xpc_get_type(event)!=XPC_TYPE_CONNECTION)return;
        auto peer=(xpc_connection_t)event;const auto uid=xpc_connection_get_euid(peer);
        struct stat console{};if(stat("/dev/console",&console))return;
        bool driver=uid==audioUID;
        if(!driver && uid!=console.st_uid){xpc_connection_cancel(peer);return;}
        if(xpc_connection_set_peer_code_signing_requirement(peer,driver?"anchor apple":requirement.c_str())){xpc_connection_cancel(peer);return;}
        xpc_connection_set_target_queue(peer,queue);
        __block uint64_t registration=0;
        xpc_connection_set_event_handler(peer,^(xpc_object_t request){
            if(xpc_get_type(request)==XPC_TYPE_ERROR) {
                if(registration && registration==currentRegistration && backing)
                    static_cast<patch::SharedTransport*>(backing)->controllerPID=0;
                return;
            }
            if(xpc_get_type(request)!=XPC_TYPE_DICTIONARY)return;
            auto wanted=xpc_dictionary_get_uint64(request,"generation");
            auto restored=xpc_dictionary_get_value(request,"restore");
            if(driver && restored && xpc_get_type(restored)==XPC_TYPE_SHMEM && wanted>generation) {
                void* address=nullptr;auto size=xpc_shmem_map(restored,&address);
                auto state=static_cast<patch::SharedTransport*>(address);
                if(patch::validSharedRegion(state,size,wanted)) {
                    if(memory)xpc_release(memory);if(backing)munmap(backing,sizeof(patch::SharedTransport));
                    memory=xpc_retain(restored);backing=address;generation=wanted;currentRegistration=0;
                } else if(address)munmap(address,size);
            }
            auto reply=xpc_dictionary_create_reply(request);if(!reply)return;
            if(driver && xpc_dictionary_get_bool(request,"create")) {
                auto ni=xpc_dictionary_get_uint64(request,"inputs"),no=xpc_dictionary_get_uint64(request,"outputs"),rate=xpc_dictionary_get_uint64(request,"rate");
                if(wanted>generation && ni<=patch::MaxChannels && no<=patch::MaxChannels && ni+no && patch::supportedSampleRate(double(rate))) {
                    void* address=mmap(nullptr,sizeof(patch::SharedTransport),PROT_READ|PROT_WRITE,MAP_ANON|MAP_SHARED,-1,0);
                    if(address!=MAP_FAILED) {
                        auto next=xpc_shmem_create(address,sizeof(patch::SharedTransport));
                        if(next) {
                            auto state=new(address) patch::SharedTransport;
                            state->generation=wanted;state->inputs=ni;state->outputs=no;state->rate=rate;
                            if(memory)xpc_release(memory);
                            if(backing)munmap(backing,sizeof(patch::SharedTransport));
                            backing=address;memory=next;generation=wanted;currentRegistration=0;
                        }
                        if(address!=backing)munmap(address,sizeof(patch::SharedTransport));
                    }
                }
            }
            if(memory && generation==wanted) {
                if(!driver) {
                    registration=currentRegistration=++registrationSerial;
                    static_cast<patch::SharedTransport*>(backing)->controllerPID.store(xpc_connection_get_pid(peer));
                }
                xpc_dictionary_set_value(reply,"memory",memory);
            }
            xpc_connection_send_message(peer,reply);xpc_release(reply);
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);dispatch_main();
}
