# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An unofficial port of Valve's SteamOS for ARM (0.4.5, built for the Steam Frame) running natively on Omarchy's "Aurora" Apple Silicon Linux stack. It started as a MacBook Neo (`j700ap`, A18 Pro / T8140) project; the `m1-pro` branch retargets it **only** to the 16-inch MacBook Pro M1 Pro (`j316sap`, T6000), the machine this checkout lives on. Many names still say `neo` (`steamos-neo-session`, `neo-vendorfw`, `linux-neo`, `NEO_*` variables); they are just names. M1 Pro hardware facts and open questions are in `steamos-build/NOTES-hardware.md`. The repo holds only our scripts, configs and patches: no SteamOS images or proprietary Valve software may be added. Valve-derived files (session scripts, power-button unit) keep their license notices in `steamos-build/packages/steamos-neo-session/`.

Boot chain: iBoot (macOS **13.5** stub; the M1 GPU driver accepts only 12.3/13.5 firmware) → m1n1 → U-Boot (UEFI) → Valve's `steamcl.efi` (A/B slot choice) → GRUB (`steamos-build/grub.cfg`) → Aurora kernel → SteamOS rootfs. Game Mode runs gamescope (SDL backend) nested inside a dedicated KWin, because Apple's display and GPU are separate devices.

## Repository layout (the three independent pipelines)

- **`steamos-build/`** — Linux-side image build. Audio is opt-in (`NEO_AUDIO=1` installs the *Neo* stack); by default `snd_soc_macaudio` is blacklisted, so the M1 Pro has no sound until speakersafetyd is ported. Runs on ARM64 Linux (privileged aarch64 Debian container, build volume at `/src`, this checkout at `/work`).
  - `steamos-rootfs/` fetches Valve's 0.4.5 rootfs from Valve's public RAUC bundle (Docker; see its README).
  - `mesa/` and `audio/` build Aurora Mesa and the Neo audio stack in Ubuntu 24.04 containers against SteamOS's glibc (≤ 2.39, no LLVM link).
  - `build-image.sh` is the core: takes Valve's rootfs + the Frame 0.3.0 image (for `/var`, `/home`), swaps the Frame kernel/Qualcomm boot chain for Aurora's, masks Frame hardware units (`FRAME_UNITS`/`FRAME_UNIT_FILES`), replaces `deckard-steamvr-session` with `packages/steamos-neo-session`, installs `packages/*` PKGBUILDs via the image's own pacman inside a chroot, adds the `neo-vendorfw` initcpio hook, and writes `rootfs.img`, `var.img`, `home.img`, `efi/`, `esp/` to `$OUT`. All inputs are env vars documented at the top of the script. It deliberately fails hard on any unexpected state (verification checks after each step) — keep that style when editing.
  - `package.py <build out dir> <ESP boot.bin> <zip>` zips that output into the installer's OS package (images must be 4 KiB multiples).
  - `kernelsetup.sh` is what SteamOS's `steamos-finalize-install` calls to install our boot files (GRUB, grub.cfg, bootconf) on updates; it never touches m1n1/boot.bin.
  - `NOTES-hardware.md` records M1 Pro facts and what still needs on-device verification, plus findings carried over from the Neo (e.g. games must not run under `aurora-userpages native`). Read it before changing session, kernel cmdline or firmware behaviour.
- **`installer/`** — macOS-side Python installer (fork of Gravity Linux's fork of the Asahi installer). `src/` is the installer (`main.py` entry, `DEVICES`/`IPSW_VERSIONS` tables; `stub.py` macOS stub + IPSW; `osinstall.py` partitions/images including SteamOS A/B partsets; `recovery.py`; `diskutil.py`), `gravity_firmware/` extracts device firmware from macOS (`src/gravity_firmware` is a symlink to it). Only `j316sap` is in `DEVICES`. Its Broadcom BCM4387 (`apple,madagascar`) firmware goes through `stub.radio_files()` (the collectors' generic mode plus a check for this board); the `neo_*`/M4 code paths remain but are unreachable. `preflight_recovery` validates the recovery image and radio firmware before any partitioning, for both AEA (26.x) and plain (13.x) images.
- **`serve/`** — hosting a build for the installer: `rangeserve.py` (HTTP range server), `install.sh` launcher (requires `https://` unless `NEO_ALLOW_HTTP=1`), `installer_data.example.json` (partition layout: `esp`, `efi-A/B`, `rootfs-A/B`, `var-A/B`, `home`), `remove-steamos.sh` uninstaller.
- **`patches/`** (`linux/`, `m1n1/`, `u-boot/`) apply to Aurora's `omacom/linux-aurora`, `omacom/m1n1`, `aurora-silicon/u-boot`; **`kconfig/steamos-neo.config`** is layered on Omarchy's kernel config. These upstream trees are not in this repo.

## Commands

Installer unit tests (run from `installer/`; no hardware or root needed):

```sh
cd installer
PYTHONPATH=src:tests python3 -m unittest discover -s tests          # all
PYTHONPATH=src:tests python3 -m unittest test_j316s_firmware        # one module
PYTHONPATH=src:tests python3 -m unittest test_j316s_firmware.J316sRadioTests.test_unknown_machine_is_refused
```

Tests construct objects without running `InstallerMain.__init__` (which probes disks/macOS) — follow that pattern. `tests/validate_j316s_recovery_macos.py` is an opt-in real-IPSW check (downloads ~2 GB of Apple's 13.5 restore image in ranges, writes only to the output dir; run on the M1 Pro itself):

```sh
PYTHONPATH=src:tests python3 tests/validate_j316s_recovery_macos.py <new output dir>
```

Build the installer package (macOS; downloads Python and libffi; output in `installer/releases/`):

```sh
M1N1_STAGE1=/path/to/m1n1.bin LOGO=/path/to/logo.icns ./installer/build.sh
```

Image build (inside the ARM64 container, as root): `steamos-build/build-image.sh` (set `NEO_DEBUG_SHELL=1` only for development builds — adds a root shell on tty9, Ctrl+Alt+F9; release GRUB configs are checked to not contain it). The boot needs `boot.bin` = m1n1 stage 2 + `t6000-j316s.dtb` + U-Boot. Full serve/install flow is in `serve/README.md`.

There is no linter configuration or CI in the repo.

## Constraints to keep in mind

- Audio is intentionally disabled (`snd_soc_macaudio` blacklisted) until speaker protection (speakersafetyd for J316) is installed and validated on hardware; don't re-enable casually — unprotected speakers can be damaged.
- SteamOS's updater (atomupd/RAUC) is intentionally disabled: Valve's channel is the Steam Frame's and its images can't boot on this Mac. Updates are done by writing a new image into the other A/B slot.
- Installing repartitions this Mac's internal disk: never run the installer, `serve/install.sh` or `remove-steamos.sh` without the user's explicit go-ahead.
- The installer must not send any data anywhere and only downloads from the user's own server (plus Apple's IPSW). It stores user/device info on the ESP; never commit installer logs, `stub_info.json`, or firmware/calibration dumps.
