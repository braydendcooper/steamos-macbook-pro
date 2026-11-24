#!/bin/bash
# Clone the pinned kernel, m1n1, U-Boot and Omarchy recipe sources into $1
# (default /src/aurora). Run in the boot-chain container with the build volume
# at /src: the kernel tree has file names that differ only in case, so it must
# not live on a case-insensitive macOS filesystem.
#
# Pins: what Omarchy shipped together on 2026-11-10 (omarchy-pkgs 0d01c62), the
# last kernel/Mesa pair qualified on M1 before the 7.3 edge kernel, whose GPU
# driver rename needs a newer Mesa than steamos-build/mesa pins.
set -euo pipefail

DEST=${1:-/src/aurora}

declare -A URL=(
    [linux]=https://github.com/omacom/linux-aurora.git
    [m1n1]=https://github.com/omacom/m1n1.git
    [u-boot]=https://github.com/aurora-silicon/u-boot.git
    [omarchy-pkgs]=https://github.com/omacom/omarchy-pkgs.git
)
declare -A COMMIT=(
    [linux]=bed544bdf93a496ebf70ba180923bab12b6e01cf          # linux-aurora 7.2.11.aurora16
    [m1n1]=bc79acc434e612ffcb95bfc7cb2fd7543afac5f2           # m1n1-aurora 1.6.1.aurora22
    [u-boot]=d30213eadcaa886f4206d7661b61bc6cf7837828         # uboot-aurora 2026.07.aurora6
    [omarchy-pkgs]=0d01c62212a3d5950647cbd4a779461288639f73   # their recipes and kernel config
)

mkdir -p "$DEST"
for name in linux m1n1 u-boot omarchy-pkgs; do
    dir="$DEST/$name"
    if [[ -d "$dir/.git" ]]; then
        [[ $(git -C "$dir" rev-parse HEAD) == "${COMMIT[$name]}" ]] || {
            echo "$dir is not at ${COMMIT[$name]}; move it aside to refetch" >&2; exit 1;
        }
        echo "== $name: already at ${COMMIT[$name]}"
        continue
    fi
    echo "== $name: fetching ${COMMIT[$name]}"
    git init -q "$dir"
    git -C "$dir" fetch -q --depth 1 "${URL[$name]}" "${COMMIT[$name]}"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
    [[ $(git -C "$dir" rev-parse HEAD) == "${COMMIT[$name]}" ]]
done
# m1n1 builds its Rust and artwork from submodules.
git -C "$DEST/m1n1" submodule update -q --init --depth 1
echo "Sources ready in $DEST"
