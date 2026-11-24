# Install server

The installer (in `installer/` of this repository) downloads itself
and the OS package from a server you run yourself. Nothing is downloaded from
any project server. The simplest and safest setup is to copy your build onto the
Mac and run the server there, in macOS, on `127.0.0.1`.

## Served directory layout

```
<root>/
  installer/latest                         one line: the installer version, e.g. j316s-1
  installer/installer-<version>.tar.gz     built with the installer's build.sh
  installer/installer_data.json            from installer_data.example.json
  os/<package>.zip                         your image, packaged with steamos-build/package.py
```

1. Build the SteamOS image with `steamos-build/build-image.sh`, then package it:
   `python3 steamos-build/package.py <build output dir> <ESP boot.bin> <root>/os/steamos-j316s.zip`.
   `<ESP boot.bin>` is your m1n1 stage 2 + device tree + U-Boot payload.
2. Build the installer with its `build.sh`, supplying `M1N1_STAGE1` (your m1n1
   stage 1 build) and `LOGO` (any `.icns` icon). Copy
   `releases/installer-<version>.tar.gz` and `releases/latest` from the
   installer into `<root>/installer/`.
3. Copy `installer_data.example.json` to `<root>/installer/installer_data.json`
   and set `"package"` to your zip's file name.
4. Serve `<root>` with HTTP range support (the installer fetches the multi-GB
   package in ranges): `python3 rangeserve.py <root> 127.0.0.1 8000`. Serve a
   directory that contains only these install files: everything in it is
   readable by anyone who can reach the server.

## Installing

On the M1 Pro MacBook Pro, in macOS, with everything backed up:

```sh
sh install.sh
```

This uses the server on the Mac itself (`http://127.0.0.1:8000`). To use a
server elsewhere, pass its address: `https://` is required, because the
installer runs with administrator rights and a plain-HTTP download could be
tampered with by any device on the network. If you trust every device on your
network, `NEO_ALLOW_HTTP=1 sh install.sh http://<server address>:8000` allows
plain HTTP anyway.
The installer asks for your password to run as root, creates a small macOS stub
volume and the SteamOS partitions, and copies Wi-Fi, Bluetooth and trackpad
firmware from macOS. Finishing the install requires a reboot into recoveryOS, as
the installer explains.

## Removing

`remove-steamos.sh` removes one SteamOS install and its macOS stub volume. Run it
in macOS on the Mac as your normal user (it asks for your password through sudo),
first with `DRY_RUN=1` to see what it would delete:

```sh
DRY_RUN=1 sh remove-steamos.sh
sh remove-steamos.sh
```

It only deletes after you type `DELETE`. If you named the stub volume something
other than `SteamOS` during installation, set `STUB_VOLUME=<name>`. Read the script
before running it; it deletes partitions.

## Your data

The installer keeps information about your Mac on the EFI system partition so
that the install can be finished and repaired later: `installer.log`, your
macOS administrator accounts' names, full names and user IDs (`stub_info.json`), disk and
volume identifiers, and the device-specific firmware and calibration copied from
macOS. None of it is sent anywhere. Do not publish these files or the raw
installer output; if you share a log to get help, remove names and identifiers
first.
