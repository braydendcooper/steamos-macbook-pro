# Aurora Mesa for SteamOS on an aarch64 MacBook Neo

This recipe replaces native Valve Mesa with Omarchy's Asahi Gallium, Zink,
softpipe and Honeykrisp Vulkan from `omacom/mesa` commit
`a19691114759e2c0507f3502cf6166ef2c6e2e33`. It targets SteamOS 0.3.0
(glibc 2.39) and 0.4.x. The container is Ubuntu 24.04 arm64; the installed
ELFs must require no GLIBC version newer than 2.39 and must not link LLVM.
It does not supply a kernel: working G17 support needs the matching Aurora
kernel/DRM UAPI and firmware. The input PKGBUILD does not claim that this
particular package build has passed Neo hardware qualification.

## Inputs and limits

The recipe follows Omarchy's Mesa PKGBUILD and the file list of the Mesa
package in SteamOS, and it built the Mesa used in the Neo image. Meson
**1.9.1** is pinned; it is not a verified minimum for other Mesa commits.
Before any compilation, the script reads the actual source's `meson_version`
and rejects an incompatible pin. If necessary, rebuild with
`--build-arg MESON_VERSION=<verified-version>` after inspecting that file.
Options follow the PKGBUILD, plus standard Mesa `llvm=disabled`,
`gallium-rusticl=false`, and the requested installation/build options.
Meson setup must confirm those against the supplied checkout; no guessed
replacement option or automatic source download is attempted on failure.

Driver changes from the PKGBUILD: omit llvmpipe; disable video codecs and
Vulkan layers; disable rusticl/OpenCL (the legacy Clover frontend is not
requested). Keep GLES1/GLES2 enabled. First build `mesa_clc`, `vtn_bindgen2`,
and `asahi_clc` with LLVM 19, then pass their paths to the driver build with
`mesa-clc=system`, `precomp-compiler=system`, `llvm=disabled`, and
`spirv-tools=disabled`. LLVM/libclc/SPIR-V and Rust are build tools, not
libraries to copy into SteamOS. No VA/VDPAU frontend is requested; Mesa's
normal auto-detection must leave unsupported video frontends disabled.

The image always builds private libdrm >=2.4.124 from a supplied tarball,
rather than using Noble's older libdrm. Its prefix is `/opt/libdrm` and it
is never staged in the output. Mesa checks its own actual libdrm requirement
at setup; supply a newer tarball if needed. SteamOS's libdrm 2.4.134 provides
`libdrm.so.2` at runtime. Do not use a build-time libdrm newer than the target
without checking the symbols it introduces. The manifest, `needed.txt`, and
`glibc.txt` are audit reports, not a complete target dependency resolver.

## Build

Obtain inputs separately. This document does not fetch them. Image creation
uses networked apt, pip, Rust distribution and Cargo operations; the Mesa
build itself uses `--wrap-mode=nodownload` and can run with `--network=none`.
For a completely offline image build, those packages/toolchains must already
be mirrored/cached or the completed image must be supplied externally.

Prepare a clean Git checkout of the pinned commit at a host path whose
container mount will be `/src/aurora/mesa`. Prepare an external Docker build
context containing **exactly one** `deps/libdrm-<version>.tar.xz` (2.4.124 or
newer). Supply its independently verified SHA256. For example, with
`/absolute/path/offline-inputs/deps/libdrm-2.4.124.tar.xz` already present:

```bash
recipe_dir="$PWD/mesa"
inputs=/absolute/path/offline-inputs
mesa_source=/absolute/path/aurora/mesa
output="$PWD/mesa-output"
# Replace with the trusted checksum for the chosen source tarball.
libdrm_sha256=REPLACE_WITH_VERIFIED_SHA256

# -f can refer outside the build context. Only deps/ is copied from that context.
docker build --platform linux/arm64 \
  -f "$recipe_dir/Dockerfile.noble" \
  --build-arg LIBDRM_SHA256="$libdrm_sha256" \
  -t mesa-aurora-noble:local "$inputs"

mkdir -p "$output"
docker run --rm --platform linux/arm64 \
  --network=none --user "$(id -u):$(id -g)" \
  -e BUILD_JOBS=8 \
  -v "$recipe_dir:/recipe:ro" \
  -v "$mesa_source:/src/aurora/mesa:ro" \
  -v "$output:/out" \
  mesa-aurora-noble:local \
  bash /recipe/build-mesa.sh /src/aurora/mesa /out
```

The Colima VM must share those host paths. Git must trust the checkout owner;
if its owner differs from the container user, correct the ownership or pass
`-e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory
-e GIT_CONFIG_VALUE_0=/src/aurora/mesa` to `docker run`.

The output directory must not overlap the source. Re-running cleans only
`build-tools`, `build`, `root` and generated reports/archive in that output
directory. A failed build produces no new successful archive. Preserve the
Meson setup logs if any dependency or option check fails; never bypass setup
by silently dropping an Asahi component.

Outputs: `root/`, `manifest.txt` (all files and symlinks, relative to root),
`needed.txt` (DT_NEEDED for every regular ELF), `glibc.txt` (per-ELF maximum
and overall GLIBC requirement), and `mesa-aurora-steamos-aarch64.tar.zst`.
The audit also rejects non-AArch64 ELFs, compiler runtime libraries,
GLIBC_PRIVATE and installed RPATH/RUNPATH entries. It checks the GLVND, GBM,
DRI, drirc and Asahi ICD entry points before producing the archive.

The source pin, Rust 1.90.0, binding-generator pins, Meson pin, tarball hash,
fixed archive timestamps/ownership/order and single-threaded compression make
runs repeatable with the same inputs. This is not a claim of bit-identical
rebuilds across future apt/pip repositories or different source/build paths:
`ubuntu:24.04` and apt dependencies are not digest/snapshot pinned. Preserve
the resulting builder image by digest and input artifacts for exact reuse.
The runtime GLIBC gate remains mandatory even when reusing that image.

## Replace Valve's native Mesa in an unpacked image

Work on an unpacked, offline root filesystem and keep a backup. This archive
is a manual overlay, not a pacman package: the image's package database is not
updated and later package upgrades can overwrite it. Valve's package provides
`mesa`, `mesa-libgl`, `opengl-driver`; its declared dependencies include
libdrm, Wayland, libxshmfence, libelf, libdisplay-info, libglvnd, zstd,
the Vulkan loader, Lua and libconfig. Retain the image's loaders and shared
dependencies. In particular, retain libglvnd's dispatcher libraries and the
Vulkan loader. Compare `needed.txt` with the actual target libraries and
symbol versions, including libstdc++/CXXABI, before booting: the GLIBC ceiling
does not guarantee every other ABI or all runtime/dlopen dependencies.

Delete the following exact native package-owned files **before extraction**.
This list includes every non-directory entry in the supplied
`deckard-mesa-linux-aarch64-26.3.0_devel+git8aa73b4b-1.files`, including tools,
headers, pkg-config files and license, so no stale native files remain.
It removes Freedreno's library, ICD and register data and Valve's VRAM layer
and JSON together. Preserve shared directories and files owned by other
packages; do not delete all of `/usr/lib/dri` or `/usr/share/vulkan`.

```bash
# Run on the Linux image-building host with the filesystem mounted offline.
# Requires permission to modify that filesystem.
ROOTFS=/absolute/path/to/unpacked-steamos-root
ARCHIVE=/absolute/path/mesa-output/mesa-aurora-steamos-aarch64.tar.zst
[[ "$ROOTFS" = /* && "$ROOTFS" != / && -d "$ROOTFS/usr/lib" ]] || exit 1
while IFS= read -r path; do
  rm -f -- "$ROOTFS/$path" || exit 1
done <<'VALVE_MESA_FILES'
usr/bin/cffdump
usr/bin/computerator
usr/bin/crashdec
usr/bin/fdperf
usr/bin/generate_rd
usr/bin/pps-producer
usr/bin/qrisc-asm
usr/bin/qrisc-disasm
usr/bin/rddecompiler
usr/bin/replay
usr/include/EGL/eglext_angle.h
usr/include/EGL/eglmesaext.h
usr/include/GL/internal/dri_interface.h
usr/include/gbm.h
usr/include/gbm_backend_abi.h
usr/lib/dri/apple_dri.so
usr/lib/dri/armada-drm_dri.so
usr/lib/dri/exynos_dri.so
usr/lib/dri/gm12u320_dri.so
usr/lib/dri/hdlcd_dri.so
usr/lib/dri/hx8357d_dri.so
usr/lib/dri/ili9163_dri.so
usr/lib/dri/ili9225_dri.so
usr/lib/dri/ili9341_dri.so
usr/lib/dri/ili9486_dri.so
usr/lib/dri/imx-dcss_dri.so
usr/lib/dri/imx-drm_dri.so
usr/lib/dri/imx-lcdif_dri.so
usr/lib/dri/ingenic-drm_dri.so
usr/lib/dri/kirin_dri.so
usr/lib/dri/komeda_dri.so
usr/lib/dri/libdril_dri.so
usr/lib/dri/mali-dp_dri.so
usr/lib/dri/mcde_dri.so
usr/lib/dri/mediatek_dri.so
usr/lib/dri/meson_dri.so
usr/lib/dri/mi0283qt_dri.so
usr/lib/dri/mxsfb-drm_dri.so
usr/lib/dri/panel-mipi-dbi_dri.so
usr/lib/dri/pl111_dri.so
usr/lib/dri/rcar-du_dri.so
usr/lib/dri/repaper_dri.so
usr/lib/dri/rockchip_dri.so
usr/lib/dri/rzg2l-du_dri.so
usr/lib/dri/ssd130x_dri.so
usr/lib/dri/st7586_dri.so
usr/lib/dri/st7735r_dri.so
usr/lib/dri/sti_dri.so
usr/lib/dri/stm_dri.so
usr/lib/dri/sun4i-drm_dri.so
usr/lib/dri/udl_dri.so
usr/lib/dri/vkms_dri.so
usr/lib/dri/zink_dri.so
usr/lib/dri/zynqmp-dpsub_dri.so
usr/lib/gbm/dri_gbm.so
usr/lib/libEGL_mesa.so
usr/lib/libEGL_mesa.so.0
usr/lib/libEGL_mesa.so.0.0.0
usr/lib/libGLX_mesa.so
usr/lib/libGLX_mesa.so.0
usr/lib/libGLX_mesa.so.0.0.0
usr/lib/libVkLayer_MESA_vram_report_limit.so
usr/lib/libfreedreno_noop_drm_shim.so
usr/lib/libgallium-26.3.0-devel.so
usr/lib/libgbm.so
usr/lib/libgbm.so.1
usr/lib/libgbm.so.1.0.0
usr/lib/libvulkan_freedreno.so
usr/lib/pkgconfig/dri.pc
usr/lib/pkgconfig/gbm.pc
usr/share/drirc.d/00-mesa-defaults.conf
usr/share/drirc.d/00-turnip-defaults.conf
usr/share/drirc.d/00-zink-defaults.conf
usr/share/freedreno/registers/adreno.xml.gz
usr/share/freedreno/registers/adreno/a2xx.xml.gz
usr/share/freedreno/registers/adreno/a3xx.xml.gz
usr/share/freedreno/registers/adreno/a4xx.xml.gz
usr/share/freedreno/registers/adreno/a5xx.xml.gz
usr/share/freedreno/registers/adreno/a6xx.xml.gz
usr/share/freedreno/registers/adreno/a6xx_descriptors.xml.gz
usr/share/freedreno/registers/adreno/a6xx_enums.xml.gz
usr/share/freedreno/registers/adreno/a6xx_gmu.xml.gz
usr/share/freedreno/registers/adreno/a6xx_perfcntrs.xml.gz
usr/share/freedreno/registers/adreno/a7xx_enums.xml.gz
usr/share/freedreno/registers/adreno/a7xx_perfcntrs.xml.gz
usr/share/freedreno/registers/adreno/a8xx_descriptors.xml.gz
usr/share/freedreno/registers/adreno/a8xx_enums.xml.gz
usr/share/freedreno/registers/adreno/a8xx_perfcntrs.xml.gz
usr/share/freedreno/registers/adreno/adreno_common.xml.gz
usr/share/freedreno/registers/adreno/adreno_control_regs.xml.gz
usr/share/freedreno/registers/adreno/adreno_pipe_regs.xml.gz
usr/share/freedreno/registers/adreno/adreno_pm4.xml.gz
usr/share/freedreno/registers/adreno/ocmem.xml.gz
usr/share/freedreno/registers/freedreno_copyright.xml.gz
usr/share/freedreno/registers/rules-fd.xsd.gz
usr/share/glvnd/egl_vendor.d/50_mesa.json
usr/share/licenses/deckard-mesa-linux-aarch64/LICENSE
usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
usr/share/vulkan/implicit_layer.d/VkLayer_MESA_vram_report_limit.json
VALVE_MESA_FILES
# This directory and all of its data belong to Valve's native Freedreno build.
rm -rf -- "$ROOTFS/usr/share/freedreno"
tar --zstd --numeric-owner -xpf "$ARCHIVE" -C "$ROOTFS"
```

The overlay provides `/usr/lib/libEGL_mesa.so.0`, `libGLX_mesa.so.0`,
`libgbm.so.1`, Asahi/Zink/software DRI modules under `/usr/lib/dri`,
`/usr/share/glvnd/egl_vendor.d/50_mesa.json`, Asahi's Vulkan library and ICD
under `/usr/share/vulkan/icd.d/`, and Mesa/Zink defaults in
`/usr/share/drirc.d`. Internal megadriver names and DRI aliases are determined
by the pinned Mesa source; they need not duplicate Valve's unrelated display
aliases. Asahi replaces Freedreno; do not rename Asahi's ICD to Freedreno or
preserve environment overrides pointing to the deleted Freedreno ICD.
Check any image-specific Mesa/Vulkan path overrides against the manifest.

The x86_64/i686 FEX copies under `/usr/share/guestos/fex-mesa` are explicitly
out of scope. This tarball neither replaces nor validates them. The native
replacement alone does not establish accelerated FEX guest compatibility.
Native `eglinfo`, `glxinfo` and `vulkaninfo` plus a real G17 workload should be
validated on the matching kernel before adopting the modified image.
