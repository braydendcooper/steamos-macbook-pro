# MacBook Neo installer

Installs SteamOS for the MacBook Neo (`j700ap`, A18 Pro) next to macOS. It is a
fork of the Gravity Linux installer, which is itself derived from the
[Asahi Linux](https://asahilinux.org) installer; all credit for the installer's
design and most of its code goes to those projects (see `LICENSE`).

What it does, run from macOS on the Neo:

- creates a small macOS "stub" install (macOS 26.6.2 firmware) that the Mac's
  boot picker uses to start Linux, and installs the m1n1 boot loader into it
  (finished in recoveryOS, as the installer explains);
- creates the partitions described by `installer_data.json`, including SteamOS's
  A/B layout (`esp`, `efi-A/B`, `rootfs-A/B`, `var-A/B`, `home`), and writes the
  OS package's images into them;
- copies the device firmware Linux needs from the running macOS (Wi-Fi and
  Bluetooth, trackpad and other device firmware and calibration data), using
  firmware collectors ported from the Omarchy project.

It sends no usage data anywhere. It downloads only from the install server you
point it at (and Apple's servers for the macOS stub's restore image).

## Building

`build.sh` assembles the installer package (a Python runtime plus the code in
`src/`). It downloads the Python framework from python.org and libffi from
Homebrew's package registry. Supply your own m1n1 stage 1 build and an icon for
the boot picker:

```sh
M1N1_STAGE1=/path/to/m1n1.bin LOGO=/path/to/logo.icns ./build.sh
```

The package lands in `releases/`. To serve it and install, see `serve/README.md`
in this repository.

## License

MIT, see `LICENSE`, which lists the Asahi Linux contributors and the other
copyright holders whose code this includes.
