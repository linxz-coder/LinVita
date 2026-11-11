// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

#include <mem/functions.h>
#include <mem/state.h>
#include <gtest/gtest.h>

#ifndef _WIN32
#include <sys/mman.h>
#endif
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_vm.h>
#endif

#ifndef _WIN32
static bool is_mapped(uint8_t *base) {
#ifdef __APPLE__
    mach_vm_address_t address = reinterpret_cast<mach_vm_address_t>(base);
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    const auto result = mach_vm_region(mach_task_self(), &address, &size,
        VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&info), &count, &object);
    if (object != MACH_PORT_NULL)
        mach_port_deallocate(mach_task_self(), object);
    return result == KERN_SUCCESS && address == reinterpret_cast<mach_vm_address_t>(base);
#else
    unsigned char resident = 0;
    return mincore(base, 4096, &resident) == 0;
#endif
}
#endif

TEST(memory_lifecycle, repeated_game_switches_reuse_clean_reservation) {
    MemState state;
    uint8_t *base = nullptr;
    constexpr Address address = 0x81000000;
    for (int game = 0; game < 40; ++game) {
        ASSERT_TRUE(init(state, game % 2 == 0));
        if (!base)
            base = state.memory.get();
        ASSERT_EQ(state.memory.get(), base);
        ASSERT_FALSE(state.reserved_memory);
        EXPECT_FALSE(is_valid_addr(state, address));
#ifndef _WIN32
        // Read before alloc_at's memset: the old game's bytes must really
        // have been discarded by teardown, not just hidden by the allocator.
        ASSERT_EQ(mprotect(base + address, state.host_page_size, PROT_READ | PROT_WRITE), 0);
        EXPECT_EQ(base[address], 0);
        EXPECT_EQ(base[address + state.host_page_size - 1], 0);
#endif
        ASSERT_EQ(alloc_at(state, address, state.host_page_size, "lifecycle-test"), address);
        base[address] = 0xAB;
        base[address + state.host_page_size - 1] = 0xCD;
        state.protect_tree.emplace(address, ProtectSegmentInfo(state.host_page_size, MemPerm::ReadOnly));
        deinit_mem(state, true);
        EXPECT_FALSE(state.memory);
        EXPECT_EQ(state.reserved_memory.get(), base);
        EXPECT_FALSE(state.alloc_table);
        EXPECT_FALSE(state.page_table);
        EXPECT_TRUE(state.protect_tree.empty());
        EXPECT_TRUE(state.allocator.words.empty());
        // A second stop while already idle must preserve the reservation.
        deinit_mem(state, true);
        ASSERT_EQ(state.reserved_memory.get(), base);
    }
    deinit_mem(state);
    EXPECT_FALSE(state.memory);
    EXPECT_FALSE(state.reserved_memory);
#ifndef _WIN32
    EXPECT_FALSE(is_mapped(base));
#endif
}

TEST(memory_lifecycle, active_initialization_does_not_replace_guest_data) {
    MemState state;
    ASSERT_TRUE(init(state, false));
    constexpr Address address = 0x81000000;
    ASSERT_EQ(alloc_at(state, address, state.host_page_size, "lifecycle-test"), address);
    auto *base = state.memory.get();
    base[address] = 0xAB;
    EXPECT_FALSE(init(state, false));
    EXPECT_EQ(state.memory.get(), base);
    EXPECT_EQ(base[address], 0xAB);
    deinit_mem(state);
}

TEST(memory_lifecycle, destruction_releases_retained_reservation) {
    uint8_t *base;
    {
        MemState state;
        ASSERT_TRUE(init(state, false));
        base = state.memory.get();
        deinit_mem(state, true);
        ASSERT_EQ(state.reserved_memory.get(), base);
    }
#ifndef _WIN32
    EXPECT_FALSE(is_mapped(base));
#endif
}
