#include <dynarmic/interface/exclusive_monitor.h>

#include <atomic>
#include <cassert>
#include <chrono>
#include <iostream>
#include <thread>
#include <vector>

int main() {
    Dynarmic::ExclusiveMonitor monitor(150);
    constexpr Dynarmic::VAddr address = 0x1000;
    uint32_t value = 7;
    auto read = [&] { return value; };
    auto increment = [&](uint32_t saved) {
        if (saved != value) return false;
        ++value;
        return true;
    };

    // Only one competing reservation may commit; CLREX must cancel its owner.
    assert(monitor.ReadAndMark<uint32_t>(0, address, read) == 7);
    assert(monitor.ReadAndMark<uint32_t>(1, address, read) == 7);
    assert(monitor.DoExclusiveOperation<uint32_t>(0, address, increment));
    assert(!monitor.DoExclusiveOperation<uint32_t>(1, address, increment));
    monitor.ReadAndMark<uint32_t>(0, address, read);
    monitor.ClearProcessor(0);
    assert(!monitor.DoExclusiveOperation<uint32_t>(0, address, increment));
    monitor.ReadAndMark<uint32_t>(0, address, read);
    monitor.Clear();
    assert(!monitor.DoExclusiveOperation<uint32_t>(0, address, increment));
    monitor.ReadAndMark<uint32_t>(0, address, read);
    assert(!monitor.DoExclusiveOperation<uint32_t>(0, address + 4, increment));

    // Exercise actual monitor code with contended LDREX/STREX retries, plus
    // preemption of an owner inside a read callback. Wrong lock ordering or
    // missing mutual exclusion loses updates or corrupts saved values.
    value = 0;
    std::atomic<bool> start{false};
    std::atomic<bool> finished{false};
    std::thread watchdog([&] {
        for (int i = 0; i < 300 && !finished.load(); ++i)
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        if (!finished.load()) std::abort();
    });
    std::vector<std::thread> workers;
    for (size_t thread = 0; thread < 8; ++thread) {
        workers.emplace_back([&, thread] {
            while (!start.load()) std::this_thread::yield();
            for (int i = 0; i < 10000; ++i) {
                bool success;
                do {
                    monitor.ReadAndMark<uint32_t>(thread, address, [&] {
                        if (thread == 0 && i % 1000 == 0)
                            std::this_thread::sleep_for(std::chrono::microseconds(100));
                        return value;
                    });
                    success = monitor.DoExclusiveOperation<uint32_t>(thread, address, increment);
                } while (!success);
                monitor.ClearProcessor(thread);
            }
        });
    }
    start = true;
    for (auto& thread : workers) thread.join();
    assert(value == 80000);
    finished = true;
    watchdog.join();

    // The monitor also preserves complete 64/128-bit saved values.
    const Dynarmic::Vector vector{0x1122334455667788ULL, 0x8877665544332211ULL};
    monitor.ReadAndMark<Dynarmic::Vector>(149, address, [&] { return vector; });
    assert(monitor.DoExclusiveOperation<Dynarmic::Vector>(149, address, [&](auto saved) { return saved == vector; }));
    constexpr uint64_t wide = 0xfedcba9876543210ULL;
    monitor.ReadAndMark<uint64_t>(149, address, [] { return wide; });
    assert(monitor.DoExclusiveOperation<uint64_t>(149, address, [](auto saved) { return saved == wide; }));
    std::cout << "PASS: reservation invalidation, CLREX, 80000 contended updates, preempted owner, 64/128-bit values\n";
}
