/* This file is part of the dynarmic project.
 * Copyright (c) 2022 MerryMage
 * SPDX-License-Identifier: 0BSD
 */

#pragma once

#if defined(__APPLE__)
#    include <TargetConditionals.h>
#    if defined(__aarch64__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR
#        include <os/lock.h>
#    endif
#endif

namespace Dynarmic {

struct SpinLock {
    void Lock();
    void Unlock();

#if defined(__APPLE__) && defined(__aarch64__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR
    // ARM64's exclusive monitor calls Lock/Unlock in compiled host code.
    // Keep waiters visible to the iOS scheduler instead of repeatedly yielding.
    os_unfair_lock storage = OS_UNFAIR_LOCK_INIT;
#else
    // The other backends also access this word from generated lock helpers.
    volatile int storage = 0;
#endif
};

}  // namespace Dynarmic
