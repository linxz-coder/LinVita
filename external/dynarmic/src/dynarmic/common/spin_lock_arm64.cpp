/* This file is part of the dynarmic project.
 * Copyright (c) 2022 MerryMage
 * SPDX-License-Identifier: 0BSD
 */

#include "dynarmic/common/spin_lock.h"

#if defined(__APPLE__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR

namespace Dynarmic {

// A busy loop with sched_yield can consume several cores while the owner is
// descheduled. The monitor lives in ordinary host memory at a stable address;
// every acquisition is released on the same thread. No generated ARM64 code
// accesses its lock word, so iOS can park contenders and track the owner.
void SpinLock::Lock() {
    os_unfair_lock_lock(&storage);
}

void SpinLock::Unlock() {
    os_unfair_lock_unlock(&storage);
}

}  // namespace Dynarmic

#else

#include <memory>
#include <mutex>

#if defined(__APPLE__)
#    include <TargetConditionals.h>
#endif

#include <oaknut/code_block.hpp>
#include <oaknut/oaknut.hpp>

#include "dynarmic/backend/arm64/abi.h"
#include "dynarmic/common/spin_lock.h"

namespace Dynarmic {

using Backend::Arm64::Wscratch0;
using Backend::Arm64::Wscratch1;
using namespace oaknut::util;

void EmitSpinLockLock(oaknut::CodeGenerator& code, oaknut::XReg ptr) {
    oaknut::Label start, loop;

    code.MOV(Wscratch1, 1);
    code.SEVL();
    code.l(start);
    code.WFE();
    code.l(loop);
    code.LDAXR(Wscratch0, ptr);
    code.CBNZ(Wscratch0, start);
    code.STXR(Wscratch0, Wscratch1, ptr);
    code.CBNZ(Wscratch0, loop);
}

void EmitSpinLockUnlock(oaknut::CodeGenerator& code, oaknut::XReg ptr) {
    code.STLR(WZR, ptr);
}

namespace {

constexpr std::size_t kSpinLockCodeBytes = 4096;

/// Owns the emitted lock/unlock code. `mem` is heap-owned because
/// oaknut::CodeBlock is non-movable.
struct SpinLockImpl {
    SpinLockImpl(std::unique_ptr<oaknut::CodeBlock> block, bool dual_map)
            : mem(std::move(block))
            , dual_map(dual_map)
            , code{mem->wptr(), mem->ptr()} {}

    void Initialize() {
        if (!dual_map) {
            mem->unprotect();
        }

        lock = code.xptr<void (*)(volatile int*)>();
        EmitSpinLockLock(code, X0);
        code.RET();

        unlock = code.xptr<void (*)(volatile int*)>();
        EmitSpinLockUnlock(code, X0);
        code.RET();

        if (!dual_map) {
            mem->protect();
        }
        mem->invalidate_all();
    }

    std::unique_ptr<oaknut::CodeBlock> mem;
    const bool dual_map;
    oaknut::CodeGenerator code;

    void (*lock)(volatile int*) = nullptr;
    void (*unlock)(volatile int*) = nullptr;
};

std::once_flag flag;

// Shared emitted helpers on targets which allow self-mapped executable memory.
SpinLockImpl* spin_lock_impl() {
    static std::unique_ptr<SpinLockImpl> impl;

    std::call_once(flag, [&] {
        // Simulator: self-mapped block; the simulator honors mmap/mprotect.
        impl = std::make_unique<SpinLockImpl>(
            std::make_unique<oaknut::CodeBlock>(kSpinLockCodeBytes), false);
        impl->Initialize();
    });

    return impl.get();
}

}  // namespace

void SpinLock::Lock() {
    spin_lock_impl()->lock(&storage);
}

void SpinLock::Unlock() {
    spin_lock_impl()->unlock(&storage);
}

}  // namespace Dynarmic

#endif
