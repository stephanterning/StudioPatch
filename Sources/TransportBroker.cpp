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
    xpc_connection_set_event_handler(listener,^(xpc_object_t event){
        if(xpc_get_type(event)!=XPC_TYPE_CONNECTION)return;
        auto peer=(xpc_connection_t)event;const auto uid=xpc_connection_get_euid(peer);
        struct stat console{};if(stat("/dev/console",&console))return;
        bool driver=uid==audioUID;
        if(!driver && uid!=console.st_uid){xpc_connection_cancel(peer);return;}
        if(xpc_connection_set_peer_code_signing_requirement(peer,driver?"anchor apple":requirement.c_str())){xpc_connection_cancel(peer);return;}
        xpc_connection_set_target_queue(peer,queue);
        xpc_connection_set_event_handler(peer,^(xpc_object_t request){
            if(xpc_get_type(request)!=XPC_TYPE_DICTIONARY)return;
            auto reply=xpc_dictionary_create_reply(request);if(!reply)return;
            auto wanted=xpc_dictionary_get_uint64(request,"generation");
            if(driver && xpc_dictionary_get_bool(request,"create")) {
                auto ni=xpc_dictionary_get_uint64(request,"inputs"),no=xpc_dictionary_get_uint64(request,"outputs"),rate=xpc_dictionary_get_uint64(request,"rate");
                if(wanted && ni<=patch::MaxChannels && no<=patch::MaxChannels && ni+no && rate>=8000 && rate<=384000) {
                    void* address=mmap(nullptr,sizeof(patch::SharedTransport),PROT_READ|PROT_WRITE,MAP_ANON|MAP_SHARED,-1,0);
                    if(address!=MAP_FAILED) {
                        auto next=xpc_shmem_create(address,sizeof(patch::SharedTransport));
                        if(next) {
                            auto state=new(address) patch::SharedTransport;
                            state->generation=wanted;state->inputs=ni;state->outputs=no;state->rate=rate;
                            state->padding=uint32_t(std::ceil(double(rate)/3000.0));
                            state->inputPadding=state->padding;
                            if(memory)xpc_release(memory);memory=next;generation=wanted;
                        }
                        munmap(address,sizeof(patch::SharedTransport));
                    }
                }
            }
            if(memory && generation==wanted)xpc_dictionary_set_value(reply,"memory",memory);
            xpc_connection_send_message(peer,reply);xpc_release(reply);
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);dispatch_main();
}
