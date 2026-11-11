# MacBook Neo vendor firmware for SteamOS

These are mkinitcpio install/runtime hooks for the BusyBox `base udev`
initramfs, following the early ESP extraction and late tmpfs approach used
by asahi-scripts and the Omarchy vendor firmware helpers. They do not use
systemd initrd services.

Install `install/neo-vendorfw` as `/etc/initcpio/install/neo-vendorfw` and
`hooks/neo-vendorfw` as `/etc/initcpio/hooks/neo-vendorfw` on the image build
host. Include an empty `/usr/lib/firmware/vendor` directory in the SteamOS
root image before sealing it read-only. This directory must be a real
directory suitable for mounting a tmpfs. SteamOS's `/lib` resolves to
`/usr/lib` on the real root.

Put **neo-vendorfw immediately after base and before udev** in
`/etc/mkinitcpio.conf`. For the baseline hooks:

```sh
HOOKS=(base neo-vendorfw udev modconf keymap block filesystems fsck)
```

Retain SteamOS's existing hooks, their arguments/configuration, and their
relative ordering, including `blockdev_ro`, `partsets`, `initrd_shell`,
`factory_reset`, and `etc_overlay`; insert only `neo-vendorfw` after `base`.
Its `run_hook` must precede udev's driver triggers. It explicitly probes
Apple storage first, as in asahi-scripts. Any additional storage controller
drivers required by a particular kernel must also be included and available
before this hook runs.

The early hook reads the NUL-terminated ESP PARTUUID from
`/proc/device-tree/chosen/asahi,efi-system-partition`, falling back to
`gravity,efi-system-partition` if the first property is absent or empty.
It polls util-linux `blkid` with its cache disabled (50 probes, 0.1 seconds
between attempts), so it needs neither udev symlinks nor a filesystem UUID.
The install hook includes util-linux `blkid` because BusyBox `blkid` lacks
the required PARTUUID filtering options, and util-linux `mount` because
SteamOS's BusyBox has no mount applet. Both the ESP and late tmpfs mounts
use plain `mount`, as SteamOS's `partsets` hook does. The install hook also
includes `rm` for staging cleanup. Other commands, including `cpio` and `cp`,
use the BusyBox applets supplied by `base`. FAT and NLS modules are added
with `add_module`, which accepts built-in modules; optional Apple mailbox
and NVMe modules are included too.

The ESP is mounted read-only as vfat at `/run/neo-vendorfw-esp`.
`vendorfw/firmware.cpio` must be a trusted newc archive containing relative
paths under the Asahi-style `vendorfw/` prefix, such as `vendorfw/apple/...`
and `vendorfw/mediatek/...`. BusyBox `cpio -i` extracts into the private
staging directory `/run/neo-vendorfw-stage`. The hook requires a `vendorfw`
directory there and copies `vendorfw/.` into `/lib/firmware/vendor` with
`cp -a`, including hidden entries and preserving metadata. It then removes
the staging directory and unmounts the ESP. The kernel searches the vendor
directory before `/lib/firmware`. `firmware.tar` and `manifest.txt` on the
ESP are not used by this hook.

In `run_latehook`, after SteamOS has mounted its selected root at
`/new_root`, the hook mounts a tmpfs at
`/new_root/usr/lib/firmware/vendor` and copies the extracted tree, including
hidden entries. The tmpfs has a 128 MiB limit and allocates memory only as
files are copied; increase the limit if the firmware grows beyond it. It
survives the switch to the real root. SteamOS's root is read-only btrfs,
and firmware is specific to each Mac and comes from that Mac's ESP, so
the hook cannot copy it onto the root image. The tmpfs provides a writable,
per-boot firmware tree without modifying the shared image.

`partsets` continues to select and mount the SteamOS root as usual; this
hook locates the ESP independently of the root partition. SteamOS's
`etc_overlay` mounts `/var` in its late hook. Firmware staging uses `/run`
and the initramfs firmware directory, and the final mount is under `/usr`,
so it does not depend on `/var` or the `/etc` overlay being ready.

Missing device-tree properties, an unavailable ESP, mount failures, a
missing archive, extraction errors, a missing `vendorfw` directory, and copy
failures produce `neo-vendorfw:` messages and return success so boot continues. A missing
real-root mountpoint is silently skipped. Failed extraction stays in staging
until cleanup and is not copied into the firmware directory. An early copy
failure can leave partial files in the initramfs, but they are not copied
to the real root. Staging cleanup failures also warn without aborting boot.
A failed late copy attempts to unmount the incomplete tmpfs. An unmount
failure is reported, and boot still continues. Devices requiring absent
firmware may remain unavailable even though boot proceeds.

To test, rebuild the initramfs with the image's normal mkinitcpio command
(for example, `mkinitcpio -P` when its presets are configured), then inspect
the actual generated image:

```sh
lsinitcpio /path/to/generated-initramfs.img
```

Check for `hooks/neo-vendorfw`, BusyBox, the util-linux `blkid` and `mount`
binaries, `rm`, and `lib/firmware/vendor` (possibly under `usr/lib` in a
merged-usr image).
Verify vfat, nls_cp437, and nls_iso8859-1 are present as modules unless
built into the kernel. The per-machine firmware files are loaded at boot,
so they are not expected inside the generated image.

On the Neo, boot the rebuilt image and look for both success messages.
In an initramfs shell after the early hook, check `/lib/firmware/vendor`.
After normal boot, verify:

```sh
ls /lib/firmware/vendor
findmnt -T /usr/lib/firmware/vendor
```

Expect the machine's firmware directories and a tmpfs at the vendor
directory. For failure testing on a test ESP, temporarily make the archive
unavailable and confirm the hook reports it and boot continues; restore
the archive afterward.
