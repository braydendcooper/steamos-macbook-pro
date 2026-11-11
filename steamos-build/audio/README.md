# Aurora audio for SteamOS on an aarch64 MacBook Neo

Builds speaker protection and the DSP stack for SteamOS 0.4.5 on j700, using
Ubuntu 24.04 / glibc 2.39. Target runtime: gcc-libs 15, PipeWire 1.6.8,
WirePlumber 0.5.14, LV2 1.18.10 and alsa-lib 1.2.11. The six payloads become
real pacman packages inside `build-image.sh`; no rolling Arch libraries are
copied into SteamOS.

## Build

First supply the existing native arm64 Mesa builder as `neo-mesa-noble:1`
(Rust 1.90, Git, build-essential, Meson and Python). From `steamos-build`:

```bash
docker build -t neo-audio-noble:1 -f audio/Dockerfile.noble audio
docker run --rm -v neo-linux:/src -v <neo>:/work neo-audio-noble:1 \
  bash /work/steamos-build/audio/build-audio.sh
```

Replace `<neo>` with the absolute host path of the directory that contains
`steamos-build/`. Use the native arm64 Docker engine. The Dockerfile works
with the legacy builder. Both Docker image creation and the source build
require network access: apt, Git clones,
locked Cargo dependencies and LSP's `make fetch`. These scripts built the audio
stack used in the Neo image.

`OUT` defaults to `/src/aurora/audio-out`; pass `-e OUT=/src/...` to override.
Each run clones sources into a fresh temporary work directory under `OUT`,
removes the previous stage and archive, and deletes its checkout work directory
on exit. Preserve build logs. The script uses Noble's GCC/G++ defaults rather
than the inherited Mesa Clang/private libdrm environment.

## Packages and source pins

| Package | Version | Source / pin | Purpose |
| --- | --- | --- | --- |
| speakerguardd | 0.1.0.aurora3 | aurora-silicon/speakerguardd `d1bc5a02752ac01daa52d5ecb84008d7b50caef3` | J700 speaker protection daemon, profiles, unit and udev rule |
| aurora-audio | 4.1.aurora3 | aurora-silicon/asahi-audio `06aec67a8ac866eb5b40f44634652beff454e297` | PipeWire/WirePlumber configuration, DSP graphs and FIR data |
| alsa-ucm-conf-aurora | 10.aurora3 | aurora-silicon/alsa-ucm-conf-asahi `b9b2d0c82cbb46025e586b2dc9f2cae644d29999` | Complete Aurora UCM overlay alongside SteamOS's base ALSA data |
| bankstown-lv2 | 1.1.0 | chadmed/bankstown tag `1.1.0`, commit `e9829c9bccf5ed73768135c0ddd506f5a6690f9e` | Bass enhancement LV2 plugin |
| triforce-lv2 | 0.3.2 | chadmed/triforce tag `0.3.2` or `v0.3.2` | Multiband compressor LV2 plugin |
| lsp-plugins-lv2 | 1.2.37 | lsp-plugins/lsp-plugins tag `1.2.37`, commit `5dc3474fa7ff74fa43ae3bb3df5e25f093787c87` | All headless LSP LV2 processors |

The full source URLs are in the script and generated `.info` files. Every
supplied commit is checked against `git rev-parse HEAD`; a mismatch fails.
Triforce must resolve an explicit release tag and its commit is recorded,
but no independently verified commit was supplied. All Cargo builds use
`--locked` before upstream Make invocations; speakerguardd also runs its tests.
Omarchy's exact ExecStart edit selects `AppleJ700` and asserts one match.

## Output and image integration

`OUT/stage/<pkgname>/` is each package's DESTDIR tree. Adjacent
`OUT/stage/<pkgname>.info` records the version, URL, resolved commit and source
and installed license filenames. Triforce also records its selected tag.
The archive `OUT/aurora-audio-steamos-aarch64.tar.zst` contains `stage/`,
compressed with `zstd -19`; the script prints per-package and archive sizes.

Every regular staged ELF is audited as AArch64, with required GLIBC versions
at most 2.39, no GLIBC_PRIVATE and no RPATH/RUNPATH. NEEDED entries are printed
and restricted to the explicit allowlist in `build-audio.sh`. An unknown
library fails the build; inspect its target ABI before extending the list.
The script prints every installed j700 path in the data packages and the
unique HTTP URIs found in installed PipeWire/WirePlumber/graph files. It
checks for exact URI references in staged LV2 bundle TTL files and warns
on missing coverage. This textual check may include documentation URLs or
miss prefixed Turtle names; actual plugin discovery and graph loading still
need target validation.

`build-image.sh` accepts `AUDIO_TAR` (defaulting to the archive path above),
extracts it in the image's tmpfs, and copies the six trees into local package
build directories before makepkg with `--nodeps`. It installs all resulting
packages in one `pacman -U` transaction, resolving the audio dependencies
from that transaction and SteamOS's installed PipeWire/WirePlumber. It prints
the six installed versions and runs chroot `ldd` on every ELF in the three
LV2 bundles and on speakerguardd, failing on missing libraries. It enables
the daemon only if the shipped unit has an `[Install]` section; otherwise
its udev rule triggers startup.

## Speaker safety and open items

The kernel holds speakers 20 dB down until speakerguardd holds the protection
lease. This kernel/daemon contract still requires validation on the exact
j700 kernel and hardware. The speaker driver stays blacklisted in the image
until hardware validation; this work leaves `neo-no-speakers.conf` generation
untouched. Installing the packages is not clearance to remove the blacklist.

We do not ship speakersafetyd: j700 uses speakerguardd only. Neither Omarchy's
`use-feedback-guard` helper nor its speakersafetyd drop-in is installed.

Remaining checks:

- Review the recorded Triforce commit. Triforce 0.3.2's `LICENCE.txt`,
  `Cargo.toml` and SPDX headers declare `GPL-2.0-or-later`, as does the static
  PKGBUILD. Asahi's PKGBUILD lists MIT, which does not match the source.
  The checkout's license files are installed under `/usr/share/licenses/triforce-lv2/`.
- Run the LSP 1.2.37 build. `FEATURES='lv2'` requests no UI, and no additional
  UI/X11/GL development packages are installed here. `libcairo2-dev` is installed
  because the LV2 wrapper's inline-display canvas needs Cairo even without the
  UI feature. SteamOS 0.4.5 ships cairo 1.18.0, the same version as Ubuntu 24.04
  (noble); `libcairo.so.2` is allowed and the LV2 package depends on `cairo`.
  The Mesa base already
  contains graphics headers, so a successful build alone cannot establish
  their absence as build dependencies. Headless dependency requirements are
  unverified; inspect configuration/build output and NEEDED before changing
  dependencies. LSP's fetched component revisions also need review for exact
  rebuild provenance; the top-level source pin alone is not a complete lock.
- Check actual j700 manifests, UCM parsing against alsa-lib 1.2.11 and base UCM,
  PipeWire 1.6.8 / WirePlumber 0.5.14 graph loading, and installed LV2 URI coverage.
  Data copying alone does not establish runtime compatibility.
- Check other library symbol requirements (including GLIBCXX/CXXABI) and dlopen
  dependencies. The GLIBC audit and target `ldd` are useful gates, not a full
  plugin/graph integration test. Noble libsndfile and SteamOS's version need
  an actual target load check.
- Validate card identity, udev/service startup, lease loss and recovery, gain
  limits, sample-rate changes and suspend/resume before enabling speakers.
  Preserve the base image and build logs for repeatability: apt repositories,
  Cargo availability and Docker base tags are not immutable snapshots.
