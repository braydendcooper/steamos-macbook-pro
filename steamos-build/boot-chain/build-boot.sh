#!/bin/bash
# Build m1n1 (stage 1 for the installer, stage 2 for the ESP) and U-Boot with
# our patches, then assemble the ESP's boot.bin for the 16-inch M1 Pro:
# m1n1 stage 2 + t6000-j316s.dtb + gzipped U-Boot. Run in the boot-chain
# container after fetch-sources.sh and build-kernel.sh:
#   build-boot.sh [SOURCES (/src/aurora)] [KERNEL_OUT (/src/aurora/kernel-out)] [OUT (/src/aurora/boot-out)]
# Outputs in OUT: m1n1-stage1.bin (installer.sh M1N1_STAGE1), boot.bin
# (package.py's ESP boot.bin), and the parts it was made from.
#
# Unlike Omarchy's builds, stage 1 and U-Boot keep their console output on the
# screen: without a serial cable that is the only view of a failing boot.
set -euo pipefail

SOURCES=${1:-/src/aurora}
KERNEL_OUT=${2:-/src/aurora/kernel-out}
OUT=${3:-/src/aurora/boot-out}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
JOBS=${BUILD_JOBS:-$(nproc)}
M1N1=$SOURCES/m1n1
UBOOT=$SOURCES/u-boot

[[ $(git -C "$M1N1" rev-parse HEAD) == bc79acc434e612ffcb95bfc7cb2fd7543afac5f2 ]] || {
    echo "$M1N1 is not the pinned m1n1 commit (run fetch-sources.sh)" >&2; exit 1;
}
[[ $(git -C "$UBOOT" rev-parse HEAD) == d30213eadcaa886f4206d7661b61bc6cf7837828 ]] || {
    echo "$UBOOT is not the pinned U-Boot commit (run fetch-sources.sh)" >&2; exit 1;
}
[[ -s "$KERNEL_OUT/t6000-j316s.dtb" ]] || {
    echo "Missing $KERNEL_OUT/t6000-j316s.dtb (run build-kernel.sh)" >&2; exit 1;
}

apply_once() {
    local tree=$1 dir=$2
    [[ -e "$tree/.neo-patched" ]] && return
    git -C "$tree" diff --quiet || { echo "$tree has local changes; refetch it" >&2; exit 1; }
    for p in "$dir"/*.patch; do
        echo "== Applying $(basename "$p") to $(basename "$tree")"
        patch -d "$tree" -p1 --batch --fuzz=0 --no-backup-if-mismatch -i "$p"
    done
    touch "$tree/.neo-patched"
}
apply_once "$M1N1" "$REPO/patches/m1n1"
apply_once "$UBOOT" "$REPO/patches/u-boot"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "== m1n1 (Rust 1.89, clang)"
export RUSTUP_TOOLCHAIN=1.89.0
# Ubuntu's LLVM 18 tools are suffixed; m1n1's USE_CLANG build calls them unsuffixed.
export PATH=/usr/lib/llvm-18/bin:$PATH
make -C "$M1N1" clean
make -C "$M1N1" -j"$JOBS" EXTRA_CFLAGS=-Os RELEASE=1 CHAINLOADING=1 USE_CLANG=1
cp "$M1N1/build/m1n1.bin" "$OUT/m1n1-stage1.bin"
make -C "$M1N1" clean
make -C "$M1N1" -j"$JOBS" EXTRA_CFLAGS=-Os RELEASE=1 CHAINLOADING=1 ESP_STAGE2=1 USE_CLANG=1
cp "$M1N1/build/m1n1.bin" "$OUT/m1n1-stage2.bin"
unset RUSTUP_TOOLCHAIN

echo "== U-Boot (apple_m1_defconfig)"
make -C "$UBOOT" O=build-neo apple_m1_defconfig
"$UBOOT/scripts/config" --file "$UBOOT/build-neo/.config" -e EFI_RT_VOLATILE_STORE \
    -d TOOLS_KWBIMAGE -d TOOLS_LIBCRYPTO
make -C "$UBOOT" O=build-neo olddefconfig
grep -qx 'CONFIG_EFI_RT_VOLATILE_STORE=y' "$UBOOT/build-neo/.config"
make -C "$UBOOT" O=build-neo -j"$JOBS"
cp "$UBOOT/build-neo/u-boot-nodtb.bin" "$OUT/u-boot-nodtb.bin"

echo "== boot.bin"
cp "$KERNEL_OUT/t6000-j316s.dtb" "$OUT/"
gzip -9n -c "$OUT/u-boot-nodtb.bin" > "$OUT/u-boot-nodtb.bin.gz"
cat "$OUT/m1n1-stage2.bin" "$OUT/t6000-j316s.dtb" "$OUT/u-boot-nodtb.bin.gz" > "$OUT/boot.bin"

for f in m1n1-stage1.bin boot.bin; do
    [[ -s "$OUT/$f" ]] || { echo "Missing output $f" >&2; exit 1; }
done
(cd "$OUT" && sha256sum m1n1-stage1.bin m1n1-stage2.bin t6000-j316s.dtb u-boot-nodtb.bin boot.bin | tee SHA256SUMS)
echo "Boot chain built: $OUT"
