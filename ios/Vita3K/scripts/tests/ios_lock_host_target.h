#pragma once
// Test-only: compile the production iPhone lock branch against macOS's identical
// os_unfair_lock API. This is a host concurrency test, not an iPhone performance test.
#include <TargetConditionals.h>
#undef TARGET_OS_IOS
#define TARGET_OS_IOS 1
#undef TARGET_OS_SIMULATOR
#define TARGET_OS_SIMULATOR 0
