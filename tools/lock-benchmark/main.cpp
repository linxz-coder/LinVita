#include <os/lock.h>
#include <sys/resource.h>
#include <sched.h>
#include <atomic>
#include <cassert>
#include <chrono>
#include <iostream>
#include <thread>
#include <vector>

struct CurrentSpin {
    int word = 0;
    void lock() {
        int spins = 0;
        for (;;) {
            if (__atomic_load_n(&word, __ATOMIC_ACQUIRE) == 0) {
                int expected = 0;
                if (__atomic_compare_exchange_n(&word, &expected, 1, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) return;
            }
            if (++spins % 32 == 0) sched_yield();
        }
    }
    void unlock() { __atomic_store_n(&word, 0, __ATOMIC_RELEASE); }
};
struct NativeLock {
    os_unfair_lock word = OS_UNFAIR_LOCK_INIT;
    void lock() { os_unfair_lock_lock(&word); }
    void unlock() { os_unfair_lock_unlock(&word); }
};
double cpu_ms() {
    rusage r{}; getrusage(RUSAGE_SELF, &r);
    return (r.ru_utime.tv_sec+r.ru_stime.tv_sec)*1000.0+(r.ru_utime.tv_usec+r.ru_stime.tv_usec)/1000.0;
}
template<class Lock> void run(const char* name, int hold_ms) {
    Lock lock;
    std::atomic<bool> go=false;
    unsigned long counter=0, mirror=~0UL;
    const auto start=std::chrono::steady_clock::now(); const double cpu=cpu_ms();
    std::vector<std::thread> workers;
    lock.lock();
    for(int t=0;t<4;++t) workers.emplace_back([&]{
        while(!go.load(std::memory_order_acquire)) std::this_thread::yield();
        for(int i=0;i<20000;++i){lock.lock(); assert(mirror==~counter);++counter;mirror=~counter;lock.unlock();}
    });
    go.store(true,std::memory_order_release);
    std::this_thread::sleep_for(std::chrono::milliseconds(hold_ms));
    lock.unlock();
    for(auto& worker:workers) worker.join();
    assert(counter==80000 && mirror==~counter);
    std::cout << name << " hold_ms=" << hold_ms << " wall_ms=" << std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count() << " cpu_ms=" << cpu_ms()-cpu << " critical_sections=" << counter << "\n";
}
int main(){for(int hold:{0,200}){run<CurrentSpin>("current",hold);run<NativeLock>("native",hold);}}
