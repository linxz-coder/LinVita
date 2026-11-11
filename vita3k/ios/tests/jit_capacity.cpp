// Host regression for the production JIT allocator: 128 executable slices,
// concurrent ownership, and full session reuse in the 512-MiB address budget.
#include <ios/jit_memory.h>
#include <util/jit_config.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <cassert>
#include <cstdio>
#include <vector>

int main() {
    auto &arena = vita::ios::JitMemory::instance();
    constexpr size_t bytes = 4 * 1024 * 1024;
    assert(arena.prepare(jit_config::default_arena_bytes));
    assert(arena.reservation_bytes() == 512ULL * 1024 * 1024);
    std::vector<vita::ios::JitCodeRegion> slices;
    // Match the observed Toukiden 2 field: forty workers, one frame loop,
    // then forty more workers. A second large request must leave space
    // for future workers, and a regular 4 MiB allocation must still succeed.
    constexpr size_t large = 64 * 1024 * 1024;
    constexpr size_t spare = 128 * 1024 * 1024;
    for (unsigned i = 0; i < 40; ++i) slices.push_back(arena.allocate_slice(bytes).value());
    auto frame_loop = arena.allocate_slice(large, spare).value();
    for (unsigned i = 0; i < 40; ++i) slices.push_back(arena.allocate_slice(bytes).value());
    assert(arena.free_bytes() == spare);
    assert(!arena.allocate_slice(large, spare));
    slices.push_back(arena.allocate_slice(bytes).value());
    for (auto &slice : slices) arena.release_slice(slice, bytes);
    arena.release_slice(frame_loop, large);
    slices.clear();
    assert(arena.free_bytes() == jit_config::default_arena_bytes);
    // Each round represents a fresh game after all previous CPUs stop.
    for (unsigned round = 0; round < 3; ++round) {
        for (unsigned i = 0; i < 128; ++i) {
            auto slice = arena.allocate_slice(bytes);
            assert(slice);
            slices.push_back(*slice);
            if (slice->mode == 1) pthread_jit_write_protect_np(0);
            for (size_t offset : {size_t{0}, bytes - 8}) {
                auto *code = reinterpret_cast<uint32_t *>(slice->rw + offset);
                code[0] = 0x91000000 | ((i + 1) << 10); // ADD X0, X0, #i+1
                code[1] = 0xd65f03c0; // RET
                sys_dcache_flush(code, 8);
                sys_icache_invalidate(reinterpret_cast<void *>(slice->rx + offset), 8);
            }
            if (slice->mode == 1) pthread_jit_write_protect_np(1);
        }
        assert(arena.free_bytes() == 0);
        assert(!arena.allocate_slice(bytes));
        // Check after all writes, so alias overlap cannot pass unnoticed.
        for (unsigned i = 0; i < slices.size(); ++i) {
            for (size_t offset : {size_t{0}, bytes - 8}) {
                auto fn = reinterpret_cast<uint64_t (*)(uint64_t)>(slices[i].rx + offset);
                assert(fn(1000) == 1001 + i);
            }
        }
        // Out-of-order frees must merge holes as well as the free tail.
        for (size_t parity : {size_t{0}, size_t{1}})
            for (size_t i = parity; i < slices.size(); i += 2)
                arena.release_slice(slices[i], bytes);
        slices.clear();
        assert(arena.allocated_bytes() == 0);
        assert(arena.free_bytes() == jit_config::default_arena_bytes);
    }
    arena.shutdown();
    assert(!arena.is_prepared());
    std::puts("PASS: 128 executable 4-MiB slices inside 512 MiB, capacity rejection, and three complete reuse cycles");
}
