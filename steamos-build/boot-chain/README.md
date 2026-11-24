# Kernel and boot chain for the 16-inch M1 Pro

Builds, in an Ubuntu 24.04 arm64 container, everything `build-image.sh`,
`package.py` and the installer need that comes from Aurora's sources:

- the kernel `Image`, its modules, `t6000-j316s.dtb` and the static
  `aurora-userpages` launcher (`build-kernel.sh`);
- m1n1 stage 1 for the installer (`M1N1_STAGE1`) and the ESP's `boot.bin`
  (m1n1 stage 2 + `t6000-j316s.dtb` + gzipped U-Boot) for `package.py`
  (`build-boot.sh`).

## Pins

What Omarchy shipped together on 2026-11-10 (`omacom/omarchy-pkgs` 0d01c62):

| Source | Commit | Omarchy package |
|---|---|---|
| `omacom/linux-aurora` | bed544b | linux-aurora 7.2.11.aurora16 |
| `omacom/m1n1` | bc79acc | m1n1-aurora 1.6.1.aurora22 |
| `aurora-silicon/u-boot` | d30213e | uboot-aurora 2026.07.aurora6 |

This is the last kernel/Mesa pairing qualified on M1 before Omarchy's 7.3 edge
kernel. 7.3 renames the GPU driver to `aurora`, which needs a newer Mesa than
`../mesa` pins (`a1969111`, two commits behind the Mesa paired with 7.2.11).

The kernel is configured like Omarchy's package (their `config` +
`asahi.config`, LLVM 18, Rust 1.85, the kernel's private bindgen) plus
`../../kconfig/steamos-neo.config`, and gets `../../patches/linux`. m1n1 and
U-Boot get `../../patches/m1n1` and `../../patches/u-boot`. Unlike Omarchy's
builds, U-Boot keeps its console and stage 1 its display output, since a
failing boot can only be watched on screen without a serial cable.

## Build

The kernel tree has file names that differ only in case, so sources live in a
Docker volume, not on a macOS disk. From the repository root:

```sh
docker build --platform linux/arm64 -f steamos-build/boot-chain/Dockerfile.noble \
  -t steamos-boot-chain:local steamos-build/boot-chain
docker volume create steamos-build
run() {
  docker run --rm --platform linux/arm64 -e BUILD_JOBS=8 \
    --mount type=volume,source=steamos-build,target=/src -v "$PWD:/work:ro" \
    steamos-boot-chain:local bash "/work/steamos-build/boot-chain/$@"
}
run fetch-sources.sh   # pinned sources into /src/aurora
run build-kernel.sh    # /src/aurora/kernel-out (about an hour; give Docker 12 GB)
run build-boot.sh      # /src/aurora/boot-out
```

Then point `build-image.sh` at the kernel outputs:
`KERNEL_IMAGE=/src/aurora/kernel-out/Image`,
`USERPAGES_BIN=/src/aurora/kernel-out/userpages`,
`MODULES_ROOT=/src/aurora/kernel-out/modules-staging/lib/modules`.
`boot-out/boot.bin` is `package.py`'s ESP boot.bin and `boot-out/m1n1-stage1.bin`
is the installer's `M1N1_STAGE1`.
