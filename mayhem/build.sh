#!/usr/bin/env bash
# Builds, under /mayhem: the OSS-Fuzz harnesses (yyjson_fuzzer, yyjson_patch_fuzzer,
# yyjson_merge_patch_fuzzer), the ported legacy harness (fuzz_yyjson_read) and the jsoninfo CLI,
# each fuzz harness also as a `-standalone` reproducer; plus the project's unit tests (normal flags).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
B="$SRC/build"
mkdir -p "$B/fuzz" "$B/tests"

# 1) The library, sanitized + DWARF 3 + SanCov (fuzzer-no-link) so the fuzzed code is instrumented.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link -I"$SRC/src" \
    -c "$SRC/src/yyjson.c" -o "$B/fuzz/yyjson.o"
# LeakSanitizer off, at build time.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/fuzz/lsan_off.o"

# 2) Harnesses: libFuzzer binary + run-once standalone reproducer.
build_harness() {
  local src="$1" name="$2"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -I"$SRC/src" $LIB_FUZZING_ENGINE \
      "$src" "$B/fuzz/yyjson.o" "$B/fuzz/lsan_off.o" -o "$SRC/$name"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -I"$SRC/src" "$STANDALONE_FUZZ_MAIN" \
      "$src" "$B/fuzz/yyjson.o" "$B/fuzz/lsan_off.o" -o "$SRC/$name-standalone"
}
build_harness "$SRC/fuzz/fuzzer.c"             yyjson_fuzzer
build_harness "$SRC/fuzz/patch_fuzzer.c"       yyjson_patch_fuzzer
build_harness "$SRC/fuzz/merge_patch_fuzzer.c" yyjson_merge_patch_fuzzer
# C++ harness (FuzzedDataProvider): the standalone driver is compiled as C first so its
# LLVMFuzzerTestOneInput reference keeps C linkage.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -I"$SRC/src" $LIB_FUZZING_ENGINE \
    "$SRC/mayhem/fuzz_yyjson_read.cpp" "$B/fuzz/yyjson.o" "$B/fuzz/lsan_off.o" -o "$SRC/fuzz_yyjson_read"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/fuzz/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -I"$SRC/src" "$SRC/mayhem/fuzz_yyjson_read.cpp" \
    "$B/fuzz/standalone_main.o" "$B/fuzz/yyjson.o" "$B/fuzz/lsan_off.o" -o "$SRC/fuzz_yyjson_read-standalone"

# 3) jsoninfo (file-input CLI, legacy target), sanitized + SanCov so Mayhem sees edges.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link -I"$SRC/src" \
    "$SRC/misc/jsoninfo.c" "$B/fuzz/yyjson.o" "$B/fuzz/lsan_off.o" -o "$SRC/jsoninfo"

# 4) Test suite with the project's NORMAL flags (no sanitizers, no DWARF pin).
$CC -O2 $COVERAGE_FLAGS -I"$SRC/src" -c "$SRC/src/yyjson.c" -o "$B/tests/yyjson.o"
for f in "$SRC/test/util/yy_test_utils.c" "$SRC/test/util/goo_double_conv.c"; do
  $CC -O2 -std=c99 $COVERAGE_FLAGS -DYYJSON_TEST_DATA_PATH="\"$SRC/test\"" -I"$SRC/src" -I"$SRC/test/util" \
      -c "$f" -o "$B/tests/$(basename "$f" .c).o"
done
for t in "$SRC"/test/test_*.c; do
  n="$(basename "$t" .c)"
  $CC -O2 -std=c99 $COVERAGE_FLAGS -DYYJSON_TEST_DATA_PATH="\"$SRC/test\"" -I"$SRC/src" -I"$SRC/test/util" \
      "$t" "$B/tests/yyjson.o" "$B/tests/yy_test_utils.o" "$B/tests/goo_double_conv.o" -lm $COVERAGE_FLAGS \
      -o "$B/tests/$n"
done
# jsoninfo built with normal flags: the behavioral oracle drives it.
$CC -O2 $COVERAGE_FLAGS -I"$SRC/src" "$SRC/misc/jsoninfo.c" "$B/tests/yyjson.o" $COVERAGE_FLAGS -o "$B/tests/jsoninfo"
