#include "../Sources/AsyncResource.hpp"
#include <cassert>
#include <chrono>
#include <thread>
#include <iostream>
using namespace std::chrono_literals;
int main(){
    std::atomic<unsigned> calls{0};
    patch::AsyncResource<int> resource([&]{if(++calls<3)throw 1;return std::make_shared<int>(42);});
    auto until=std::chrono::steady_clock::now()+4s;
    while(!resource && std::chrono::steady_clock::now()<until)std::this_thread::sleep_for(5ms);
    assert(resource && *resource.get()==42 && resource.attempts()==3);
    std::atomic<bool> entered{false},release{false},exited{false};
    {
        patch::AsyncResource<int> pending([&]{entered=true;while(!release)std::this_thread::sleep_for(1ms);exited=true;return std::make_shared<int>(9);});
        while(!entered)std::this_thread::sleep_for(1ms);
        assert(!pending); // Construction returned while acquisition is blocked.
    } // Cancellation does not wait on acquisition and never captures its owner.
    release=true;while(!exited)std::this_thread::sleep_for(1ms);
    std::cout<<"PASS: asynchronous failure/retry/recovery and cancellation during acquisition\n";
}
