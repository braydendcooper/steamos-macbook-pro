# Hardware notes

## MacBook Pro (16-inch, M1 Pro) — J316s, T6000

From the sources (linux-aurora 0428c9a, m1n1 ba130ff), not yet verified on the device:

- Stub firmware must be macOS 13.5: the M1-family (G13) GPU driver only accepts
  12.3 or 13.5 firmware (`drivers/gpu/drm/asahi/driver.rs`). m1n1 sets
  `apple,firmware-compat` for the GPU and display from the stub.
- Display: DCP internal panel `eDP-1`, 3456×2234 mini-LED. m1n1 adds
  `apple,notch-height`; the display driver hides the notch rows, so DRM offers
  about 3456×2160 with the image below the notch.
- Keyboard and trackpad: SPI HID (`apple,spi-hid-transport`), not dockchannel.
  Trackpad firmware comes from macOS (installer multitouch collector).
- Wi-Fi/Bluetooth: Broadcom BCM4387 (`pci14e4,4433`/`pci14e4,5f71`), board
  `apple,madagascar`; firmware comes from the 13.5 recovery via `neo-vendorfw`.
- Audio: six TAS2764 amplifiers plus a CS42L84 headphone jack, all under the
  `snd_soc_macaudio` machine driver (`apple,j316-macaudio`). Blacklisted in our
  image until speakersafetyd is ported, so there is no headphone audio either.
- CPUs: cpu0-1 are efficiency cores, cpu2-9 performance cores.
- No SME, so `arm64.nosme` does nothing here; `user4k=on` needs the CPU's 4K
  translation granule, which M1 cores have.

Verified on the M1 Pro (first install, 2026-11):

- The 13.5 stub boots m1n1 → U-Boot → steamcl → GRUB → kernel → SteamOS, and
  Game Mode, Desktop Mode, Steam and Wi-Fi work.
- Native Vulkan works: gamescope selects "Apple M1 Pro (G13S C0)" (Honeykrisp).
- The internal panel comes up on apple-drm at 3456x2160 (below the notch), 120 Hz.
- Boot race: m1n1's boot framebuffer (simpledrm) is replaced by apple-drm about
  a second into boot. Autologin straight into Game Mode started KWin on
  simpledrm; when apple-drm took over, gamescope failed
  (`vkGetPhysicalDeviceSurfaceCapabilitiesKHR`, `vulkan_make_output failed`),
  Valve's health check fell back to Desktop Mode, or SDDM gave up (2 starts in
  30 s) leaving a text console. `sddm.service` now waits for apple-drm's eDP
  panel (`wait-for-display`), which fixed it.
- x86_64 Linux games (Steam Linux Runtime under FEX) get graphics from
  `/usr/share/guestos/fex-mesa`, Valve's x86 Mesa for the Steam Frame: only
  Freedreno Vulkan and no Apple GL driver, so they find no Vulkan GPU (BeamNG's
  native Linux build). The same game's Windows build through Proton runs on the
  native Mesa and loads a level, with rendering artifacts.
- SDDM reads `/etc/sddm.conf.d` in name order: steamos-manager's default is
  `zz-steamos-autologin.conf` and "Return to Gaming Mode" writes a one-time
  `zzt-steamos-temp-login.conf`, so a local override must sort between them.

To verify on the first boots: the 13.5 stub boots m1n1; display mode and refresh
rates DRM offers (60 Hz is configured); whether `KWIN_DRM_NO_DIRECT_SCANOUT=1`
is still needed; Wi-Fi/Bluetooth; the `4K userspace translation granule` boot
line and `AT_PAGESZ` 4096 for Steam; DXVK and vkd3d-proton games.

## Findings carried over from the MacBook Neo (A18 Pro) port

These were verified on the Neo. The ones about SteamOS and Steam should hold
here too; hardware-specific ones are kept for reference.

- Valve's Steam client switches NetworkManager to iwd via
  `/etc/NetworkManager/conf.d/99-valve-wifi-backend.conf`, written by
  steamos-manager.
- Steam processes run with 4K pages (`AT_PAGESZ` = 4096) via aurora-userpages.
- Games must NOT be launched with `aurora-userpages native`: Proton's
  `lsteamclient` loads Valve's 4K-only `steamclient.so` inside the game process.
- Starting Steam without `-deckard` and `-vrgamepadui` removes the Steam Frame
  controller-pairing setup screen and keeps the user signed in.
- NetworkManager Wi-Fi passwords entered by an unprivileged `nmcli` are stored
  per-user (agent-owned).
- KWin direct scanout hands gamescope's buffers straight to the display. On
  the Neo's split GPU/display this showed tearing and stale frames flashing
  back. `KWIN_DRM_NO_DIRECT_SCANOUT=1` forces compositing every frame and made
  it much smoother.
- Gamescope's SDL window otherwise became a decorated window about 80% of the
  screen. The dedicated KWin instance's window rule forces it fullscreen and
  borderless.
- Neo only: the A18 Pro reports SME/SME2 but no SVE, which crashed Proton's
  Wine and FEX until `arm64.nosme`; the T8140 input and SSD coprocessors cannot
  be restarted; the A18 Pro (G17) Vulkan driver did not complete DXVK/vkd3d
  game work correctly, so the Neo defaulted to WineD3D.
