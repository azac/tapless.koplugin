#!/bin/sh
# Reproducible build with Zig 0.13.0. Output requires ARMv7 + NEON/VFPv3 hard-float.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${ZIG:?Provide the path to Zig 0.13.0}"
object_dir=${TAPLESS_C_OBJECT_DIR:-${TMPDIR:-/tmp}/tapless-native-build}
mkdir -p "$object_dir"
"$ZIG" cc -target arm-linux-gnueabihf.2.17 -mcpu=cortex_a9 \
    -O3 -fPIC -fno-fast-math -ffp-contract=off \
    -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -c "$root/core.c" -o "$object_dir/core.o"
"$ZIG" cc -target arm-linux-gnueabihf.2.17 -mcpu=cortex_a9 \
    -O3 -fPIC -fno-fast-math -ffp-contract=off \
    -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -c "$root/scan.c" -o "$object_dir/scan.o"
"$ZIG" cc -target arm-linux-gnueabihf.2.17 -mcpu=cortex_a9 \
    -O3 -fPIC -fno-fast-math -ffp-contract=off \
    -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -c "$root/shape.c" -o "$object_dir/shape.o"
"$ZIG" cc -target arm-linux-gnueabihf.2.17 -mcpu=cortex_a9 \
    -O3 -fPIC -fno-fast-math -ffp-contract=off \
    -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -c "$root/engine.c" -o "$object_dir/engine.o"
"$ZIG" cc -target arm-linux-gnueabihf.2.17 -mcpu=cortex_a9 \
    -O3 -fPIC -fno-fast-math -ffp-contract=off \
    -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -c "$root/store.c" -o "$object_dir/store.o"
# Use LuaJIT's already loaded libc/libm; omit CRT startup/version metadata
# that is incompatible with older Kindle dynamic loaders.
"$ZIG" build-lib "$object_dir/core.o" -target arm-linux-gnueabihf \
    -mcpu=cortex_a9 -dynamic -fPIC -fno-compiler-rt \
    "$object_dir/scan.o" "$object_dir/shape.o" "$object_dir/engine.o" "$object_dir/store.o" -femit-bin="$root/libtapless-core.so"
