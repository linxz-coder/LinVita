#!/usr/bin/env bash
# Run the production memory allocator/lifecycle tests without games or firmware.
set -euo pipefail
LINVITA_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
LINVITA_TEST_BUILD="$LINVITA_ROOT/build/mem-lifecycle-public"
mkdir -p "$LINVITA_TEST_BUILD"
cd "$LINVITA_ROOT"
"${CXX:-c++}" -std=c++23 -O2 -pthread -Wno-deprecated-declarations \
  -DSPDLOG_FMT_EXTERNAL -DFMT_HEADER_ONLY \
  -I vita3k/mem/include -I vita3k/util/include -I external/boost \
  -I external/fmt/include -I external/spdlog/include \
  -I external/googletest/googletest/include -I external/googletest/googletest \
  vita3k/mem/src/mem.cpp vita3k/mem/src/allocator.cpp \
  vita3k/mem/tests/lifecycle_tests.cpp vita3k/mem/tests/allocator_tests.cpp \
  external/googletest/googletest/src/gtest-all.cc \
  external/googletest/googletest/src/gtest_main.cc \
  -o "$LINVITA_TEST_BUILD/mem-tests"
"$LINVITA_TEST_BUILD/mem-tests"
