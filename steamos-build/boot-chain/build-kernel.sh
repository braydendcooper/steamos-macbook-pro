#!/bin/bash
# Build the Aurora kernel for the 16-inch M1 Pro the way Omarchy's linux-aurora
# recipe does (its config + asahi.config, LLVM 18, Rust 1.85, private bindgen),
# plus our patches/linux and kconfig/steamos-neo.config. Run in the boot-chain
# container after fetch-sources.sh:
#   build-kernel.sh [SOURCES (/src/aurora)] [OUT (/src/aurora/kernel-out)]
# Outputs in OUT: Image, t6000-j316s.dtb, userpages (static), config, version,
# and modules-staging/lib/modules/<release> for build-image.sh's MODULES_ROOT.
set -euo pipefail

SOURCES=${1:-/src/aurora}
OUT=${2:-/src/aurora/kernel-out}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
LINUX=$SOURCES/linux
RECIPE=$SOURCES/omarchy-pkgs/pkgbuilds/linux-aurora
JOBS=${BUILD_JOBS:-$(nproc)}
# Same localversion as Omarchy's 7.2.11.aurora16 package (aurorarel 16, pkgrel 1).
LOCALVERSION_PKGREL=-16-1
DTB=apple/t6000-j316s.dtb

[[ $(git -C "$LINUX" rev-parse HEAD) == bed544bdf93a496ebf70ba180923bab12b6e01cf ]] || {
    echo "$LINUX is not the pinned linux-aurora commit (run fetch-sources.sh)" >&2; exit 1;
}
for f in config configure.sh validate-config.py bindgen-kernel.py; do
    [[ -r "$RECIPE/$f" ]] || { echo "Missing Omarchy recipe file: $RECIPE/$f" >&2; exit 1; }
done
case "$OUT" in "$LINUX"|"$LINUX"/*) echo "OUT must be outside the source" >&2; exit 1 ;; esac

export ARCH=arm64
export LLVM=/usr/lib/llvm-18/bin/
# Omarchy builds on Arch, where plain clang is LLVM 18; bindgen's self-test runs
# "clang", and Ubuntu only installs suffixed names outside this directory.
export PATH=/usr/lib/llvm-18/bin:$PATH
export LIBCLANG_PATH=/usr/lib/llvm-18/lib
export RUSTUP_TOOLCHAIN=1.85.0
export KBUILD_BUILD_HOST=steamos-build KBUILD_BUILD_USER=linux-neo
BUILD=$SOURCES/linux-build
BINDGEN_DIR=$SOURCES/linux-bindgen
export AURORA_BINDGEN_REAL=$BINDGEN_DIR/rust-bindgen-0.73.2/target/release/bindgen

"${LLVM}clang" --version | head -1 | grep -q 'clang version 18\.' || {
    echo "LLVM 18 is required" >&2; exit 1;
}

_make() {
    RUSTFMT="$(rustup which --toolchain 1.99.0 rustfmt)" \
        make -C "$LINUX" O="$BUILD" LLVM="$LLVM" BINDGEN="$RECIPE/bindgen-kernel.py" \
        LOCALVERSION= "$@"
}

cd "$LINUX"
if [[ ! -e "$LINUX/.neo-patched" ]]; then
    git diff --quiet || { echo "$LINUX has local changes; refetch it" >&2; exit 1; }
    for p in "$REPO"/patches/linux/*.patch; do
        echo "== Applying $(basename "$p")"
        patch -p1 --batch --fuzz=0 --no-backup-if-mismatch -i "$p"
    done
    echo "$LOCALVERSION_PKGREL" > localversion.10-pkgrel
    touch "$LINUX/.neo-patched"
fi

# build.py writes result.json only after bindgen's compile tests pass.
if [[ ! -s "$BINDGEN_DIR/result.json" ]]; then
    echo "== Building the kernel's private bindgen"
    rm -rf "$BINDGEN_DIR"
    RUSTUP_TOOLCHAIN=1.99.0 RUSTFMT="$(rustup which --toolchain 1.99.0 rustfmt)" \
        python3 tools/aurora-bindgen/build.py --output-dir "$BINDGEN_DIR"
fi

echo "== Configuring: Omarchy config + asahi.config + steamos-neo.config"
# configure.sh supplies resolve_kernel_config (merge, olddefconfig) and expects
# _make; it is Omarchy's own, so our fragment goes through the same path.
# shellcheck source=/dev/null
source "$RECIPE/configure.sh"
resolve_kernel_config "$RECIPE" "$BUILD" "" \
    arch/arm64/configs/asahi.config "$REPO/kconfig/steamos-neo.config"
python3 "$RECIPE/validate-config.py" arch/arm64/configs/asahi.config "$BUILD/.config"
python3 "$RECIPE/validate-config.py" "$REPO/kconfig/steamos-neo.config" "$BUILD/.config"
for opt in CONFIG_RUST=y CONFIG_ARM64_16K_PAGES=y CONFIG_ARM64_USER4K_EXPERIMENTAL=y \
           CONFIG_DRM_ASAHI=m CONFIG_DRM_APPLE=m CONFIG_BRCMFMAC=m CONFIG_SPI_HID_APPLE_OF=m; do
    grep -qx "$opt" "$BUILD/.config" || { echo "Kernel config lacks $opt" >&2; exit 1; }
done

echo "== Building Image, modules and device trees"
_make -j"$JOBS" Image modules dtbs
release=$(_make -s kernelrelease)
echo "Kernel release: $release"

echo "== Staging outputs in $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/modules-staging"
cp "$BUILD/arch/arm64/boot/Image" "$OUT/Image"
cp "$BUILD/arch/arm64/boot/dts/$DTB" "$OUT/"
cp "$BUILD/.config" "$OUT/config"
echo "$release" > "$OUT/version"
_make INSTALL_MOD_PATH="$OUT/modules-staging" INSTALL_MOD_STRIP=1 DEPMOD=/bin/true modules_install
rm -f "$OUT/modules-staging/lib/modules/$release"/{build,source}
# Same packaging check Omarchy relies on: every module symbol must resolve.
depmod -b "$OUT/modules-staging" -e -F "$BUILD/System.map" "$release" 2>&1 | tee "$OUT/depmod.log"
! grep -q 'unknown symbol' "$OUT/depmod.log" || { echo "Unresolved module symbols" >&2; exit 1; }

echo "== Building aurora-userpages (static, 16K-safe)"
make -C tools/aurora-userpages clean
make -C tools/aurora-userpages CC=gcc LDFLAGS="-static -Wl,-z,max-page-size=65536" userpages
cp tools/aurora-userpages/userpages "$OUT/userpages"
make -C tools/aurora-userpages clean

for f in Image t6000-j316s.dtb userpages; do
    [[ -s "$OUT/$f" ]] || { echo "Missing output $f" >&2; exit 1; }
done
if readelf -l "$OUT/userpages" | grep -q INTERP; then
    echo "userpages is not static" >&2; exit 1;
fi
echo "Kernel $release built: $OUT"
