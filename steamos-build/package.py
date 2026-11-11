#!/usr/bin/env python3
# Package the SteamOS-for-MacBook-Neo images (from build-image.sh) as an
# installer OS package: the ESP file tree (m1n1 stage 2 + U-Boot, steamcl,
# slot A bootconf) and the slot partition images.
#
# usage: package.py <build output dir> <ESP boot.bin> <zip to write>
import os
import sys
import zipfile

out, boot_bin, dest = sys.argv[1:4]
images = ["rootfs.img", "var.img", "home.img"]
trees = ["esp", "efi"]  # copied by the installer into partitions it formats

with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED, allowZip64=True, compresslevel=6) as z:
    z.write(boot_bin, "esp/m1n1/boot.bin")
    for tree in trees:
        top = os.path.join(out, tree)
        for root, _, files in os.walk(top):
            for name in sorted(files):
                path = os.path.join(root, name)
                z.write(path, os.path.join(tree, os.path.relpath(path, top)))
    for image in images:
        path = os.path.join(out, image)
        if os.path.getsize(path) % 4096:
            sys.exit(f"{image}: size is not a multiple of 4 KiB")
        print(f"adding {image} ({os.path.getsize(path) >> 20} MiB)", flush=True)
        z.write(path, image)

with zipfile.ZipFile(dest) as z:
    for info in z.infolist():
        print(f"{info.file_size:>12} {info.compress_size:>12} {info.filename}")
