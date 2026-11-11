# SteamOS on the MacBook Neo (unofficial)

An experimental port of Valve's SteamOS for ARM to Apple's MacBook Neo (A18 Pro),
running natively (no virtual machine), on top of the Omarchy project's "Aurora"
Apple Silicon Linux platform.

> **Unofficial.** This project is not affiliated with, endorsed by or supported by
> Valve or Apple. SteamOS and Steam are trademarks of Valve Corporation. MacBook
> is a trademark of Apple Inc.

> **Experimental.** This changes how your Mac boots and partitions its internal
> disk. Back up everything first. Expect bugs; there is no support.

## No SteamOS images or proprietary Valve software

This repository contains our own scripts, configuration and patches, plus a few
small open-source files adapted from Valve: the Steam Frame session scripts
(MIT) and a power-button service unit (BSD-2-Clause), each with its license
notice in `steamos-build/packages/steamos-neo-session/`. It does **not** contain
or distribute SteamOS, the Steam client, Proton or any other proprietary Valve
software, and no prebuilt images are provided. To build an image you supply
SteamOS for ARM yourself, from Valve, and you are responsible for following
Valve's terms. `steamos-build/steamos-rootfs/` contains a helper that downloads
Valve's public SteamOS for ARM update bundle directly from Valve's update server
to your machine; it checks the download against Valve's manifest but does not
verify Valve's signature (see its README).

## Status (November 2026)

Works:

- Boots Valve's SteamOS for ARM (0.4.5) natively, straight into Game Mode, with
  SteamOS's A/B system partitions, boot counting and rollback.
- Steam Big Picture at the panel's full 2408×1506, keyboard, trackpad (clicks and
  acceleration), Steam controllers, Wi-Fi.
- 2D games and Direct3D 9–11 games through WineD3D (Direct3D over OpenGL), which is
  the default here.
- SteamOS's own update finalization steps, through a Neo boot hook.

Does not work yet:

- Games that need Vulkan (Proton's DXVK and vkd3d-proton paths, Direct3D 12 games):
  the A18 Pro's Vulkan driver is very new and doesn't complete game GPU work
  correctly yet.
- Some screen tearing in menus and games.
- Speakers are deliberately disabled until their protection software is verified.
- SteamOS updates are disabled: Valve's update channel for this image is the Steam
  Frame's, and its images cannot boot on the Neo.

## Things to know

- Like a Steam Deck, it logs in automatically and starts Game Mode, and Game Mode
  has no lock screen. Use Steam's own PIN or parental controls if you need one.
- Behaviour kept from Valve's session scripts: if the home partition has less than
  500 MB free when Game Mode starts, it deletes installed games, least recently
  changed first, until 500 MB is free, so that Steam can start. Save data in Proton
  prefixes is kept, but anything stored inside a game's own folder (some saves,
  mods) is deleted with it. Game Mode's X server also accepts connections from any
  local program.
- SteamOS's own updater is turned off. You update by building a new image and
  writing it into the other A/B slot.
- Boot and kernel messages go to the Mac's USB-C debug serial port. Release builds
  have no shell there; `NEO_DEBUG_SHELL=1` adds a root shell for development only.

## How it works

```
Apple iBoot (macOS 26.6.2 firmware, in a small "stub" macOS install)
  → m1n1 stage 1 and 2      Aurora's m1n1 + our patch, with the Neo device tree
  → U-Boot (UEFI)           Aurora's U-Boot + our patches
  → steamcl.efi             Valve's boot loader from SteamOS (A/B slot choice)
  → GRUB                    from SteamOS, with our grub.cfg
  → Linux                   Aurora's kernel + our patches and SteamOS options
  → SteamOS for ARM         Valve's root filesystem + our Neo packages
      Game Mode: KWin owns the screen → gamescope (SDL backend) → Steam
```

Key pieces, all in `steamos-build/`:

- `build-image.sh` builds the image from your SteamOS for ARM root filesystem: it
  replaces the Steam Frame kernel and boot pieces with Aurora's, masks the Frame's
  hardware services, adds the Neo packages and the early-boot firmware loader.
- `packages/steamos-neo-session`: a flat-screen Game Mode session (SteamOS for ARM
  ships a VR session for the Steam Frame). gamescope runs nested inside KWin because
  Apple's display and GPU are separate devices.
- `packages/aurora-userpages`: runs the Steam client with 4 KB memory pages (Valve's
  ARM Steam client needs them; Apple hardware uses 16 KB), using Aurora's
  per-process page-size support.
- `initcpio/`: loads the Wi-Fi, Bluetooth and trackpad firmware that the installer
  copies from macOS.
- `kernelsetup.sh`: lets SteamOS's update finalizer install the Neo boot files.
- `grub.cfg`: kernel options, including `arm64.nosme` (the A18 Pro's SME without SVE
  crashes Proton's Wine/FEX) and `user4k=on`.

`patches/` holds our changes to Aurora's Linux kernel, m1n1 and U-Boot; `kconfig/`
holds the kernel options SteamOS needs on top of Omarchy's kernel configuration;
`installer/` and `serve/` are covered under Installing below.

## Building

Building is for developers. You need an ARM64 Linux build environment (for example
a container on an Apple Silicon Mac) and:

1. Aurora's kernel (`omacom/linux-aurora`), m1n1 (`omacom/m1n1`) and U-Boot
   (`aurora-silicon/u-boot`) with the patches in `patches/` applied, and the kernel
   configured with Omarchy's configuration plus `kconfig/steamos-neo.config`.
2. Aurora's Mesa and the Neo audio stack, built against SteamOS's glibc with
   `steamos-build/mesa/` and `steamos-build/audio/`.
3. SteamOS for ARM 0.4.5 (Steam Frame) obtained from Valve, and the Steam Frame
   0.3.0 recovery image for the initial `/var` and `/home`.
4. `steamos-build/build-image.sh` (inputs are documented at the top of the script).

## Installing

`installer/` is the Mac-side installer (a fork of the Asahi Linux installer via
Gravity Linux's): run from macOS on the Neo, it creates the macOS stub and the
SteamOS partitions, writes your image and copies device firmware from macOS. It
sends no usage data anywhere. `serve/` has what you need to host your build for
it: a small download server, the install launcher, an example installer
configuration and an uninstaller. Start with `serve/README.md`.

Everything is served from a computer you control; this project hosts no
downloads.

## Credits

This builds directly on other people's work:

- **Valve**: SteamOS for ARM, Steam, Proton, gamescope, steamcl and the A/B update
  tooling. `steamos-neo-session` is derived from Valve's MIT-licensed
  deckard-steamvr-session.
- **Omarchy / Aurora** (`omacom`, `aurora-silicon`): the Linux kernel with A18 Pro
  GPU, display, keyboard, trackpad, Wi-Fi and audio support, m1n1, U-Boot, Mesa,
  per-process 4 KB pages, the Neo firmware collectors, speakerguardd and the Neo
  audio configuration.
- **Asahi Linux**: m1n1, the installer design, the U-Boot port, the Apple GPU Mesa
  drivers, asahi-audio and macvdmtool. Almost all Apple Silicon Linux work starts
  here.
- **Gravity Linux**: the installer our Neo installer is forked from.
- **Omarchy** (DHH) and **Chris Kearney**: the Neo firmware collectors and the
  MT7932 policy extractor used by the installer.
- **Yureka Lilian**: the first T8140 device tree, the basis of our debug-UART node.
- **chadmed** (Bankstown, Triforce), **LSP Plugins**, **FEX-Emu**, **KDE**
  (Plasma, KWin), **desync**.
- **DroidDeck** and **SteamOS-ARM-Port**: found the Steam setting that lets Steam
  use the panel's native resolution under a nested gamescope.

## License

Our own code and configuration are under the MIT license (see `LICENSE`). The
patches in `patches/` are contributions to their upstream projects and carry those
projects' licenses (Linux and U-Boot: GPL-2.0; m1n1: MIT). `installer/` keeps its
own MIT license and copyright notices (`installer/LICENSE`). Each package recipe in
`steamos-build/packages/` states its own license.
