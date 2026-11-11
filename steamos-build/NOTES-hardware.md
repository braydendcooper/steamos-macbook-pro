# MacBook Neo hardware notes

Verified on hardware:

- Valve's Steam client switches NetworkManager to iwd via
  `/etc/NetworkManager/conf.d/99-valve-wifi-backend.conf`, written by
  steamos-manager. MT7932 Wi-Fi works with iwd.
- Steam processes run with 4K pages (`AT_PAGESZ` = 4096) via aurora-userpages.
- The trackpad driver, dockchannel-hid, retries its firmware load about every
  6 seconds.
- The T8140 input and SSD coprocessors cannot be restarted: never
  `rmmod dockchannel_hid` and never reset ANS.
- NetworkManager Wi-Fi passwords entered by an unprivileged `nmcli` are stored
  per-user (agent-owned).

Verified on the MacBook Neo:

- Starting Steam without `-deckard` and `-vrgamepadui` removes the Steam Frame
  controller-pairing setup screen and keeps the user signed in. Proton ARM64
  still works (a 2D game runs).
- Boot with `arm64.nosme`: A18 Pro reports SME/SME2 but no SVE. With SME
  visible, Proton ARM64's Wine and FEX crash at startup (ntdll stack access
  violation, illegal instruction in `libarm64ecfex.dll`). Hiding SME fixes it;
  nothing on SteamOS needs SME.
- KWin direct scanout hands gamescope's buffers straight to the display. On
  the Neo's split GPU/display this showed tearing and stale frames flashing
  back. `KWIN_DRM_NO_DIRECT_SCANOUT=1` forces compositing every frame and made
  it much smoother.
- Gamescope's SDL window otherwise became a decorated window about 80% of the
  screen. The dedicated KWin instance's window rule forces it fullscreen and
  borderless.
- Games must NOT be launched with `aurora-userpages native`: Proton's
  `lsteamclient` loads Valve's 4K-only `steamclient.so` inside the game process.
- Open GPU issue: kernel logs report `asahi: G17: N compute commands retired on
  their completion record after 50 ms without a completion stamp` on the game's
  queue only. A Direct3D 11 game's 3D scene renders as flat colours with blocky
  tiles.
- Open GPU issue: G17 GPU recovery reported `firmware blamed queue 3` when
  a Direct3D 12 game (DX12/vkd3d-proton) started rendering, causing a lost device.
