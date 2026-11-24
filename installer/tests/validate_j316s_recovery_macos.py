#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Opt-in real IPSW test for the 16-inch M1 Pro (j316sap) with the 13.5 stub.

Scratch files and read-only mounts only; no partition writes. Run on the M1 Pro
itself (the ALS, camera and factory-data collectors read this Mac's macOS),
with the installer Python and PYTHONPATH=src:tests from installer/:
  python3 tests/validate_j316s_recovery_macos.py [IPSW_OR_HTTPS_URL] OUTPUT_DIRECTORY
The IPSW defaults to the installer's 13.5 entry, which is read in byte ranges
(about 2 GB of the 13 GB file). The output directory must not already exist.
"""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import tarfile
from types import SimpleNamespace

import main as installer_main
from gravity_firmware.core import FWPackage
from gravity_firmware.update import update_firmware
from stub import StubInstaller
from test_m4_firmware import read_newc

WIFI_PREFIX = "brcm/brcmfmac4387c2-pcie.apple,madagascar"
BT_PREFIX = "brcm/brcmbt4387c2-apple,madagascar"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipsw", nargs="?", default=installer_main.IPSW_VERSIONS[0].url)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    source = args.ipsw if args.ipsw.startswith("https://") else str(Path(args.ipsw).resolve())
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    before = plistlib.loads(subprocess.check_output(["diskutil", "list", "-plist", "disk0"]))
    os.chdir(output)
    os.environ.pop("IPSW_BASE", None)
    sysinfo = SimpleNamespace(board_id=0x0A, chip_id=0x6000, device_class="j316sap")
    installer = StubInstaller(sysinfo, None, None)
    try:
        installer.load_ipsw(SimpleNamespace(version="13.5", url=source))
        assert installer.recovery_image is not None, "13.5 recovery was not validated"
        identity = installer.identity
        installer.pb_vgid = str(output / "preboot/test-volume-group")
        restore = Path(installer.pb_vgid) / installer.restore_bundle_path()
        restore.mkdir(parents=True)
        for value in identity["Manifest"].values():
            member = value["Info"]["Path"]
            if member.startswith("kernelcache."):
                installer.extract(member, str(restore))
        recovery_root = output / "recovery-volume"
        installer.osi = SimpleNamespace(recovery=str(recovery_root), vgid="test-volume-group")
        target = recovery_root / "test-volume-group/usr/standalone/firmware/arm64eBaseSystem.dmg"
        target.parent.mkdir(parents=True)
        prepared = installer.recovery_image
        with prepared.path.open("rb") as stream:
            installer.stream_compress(stream, prepared.path.stat().st_size, str(target), crc=prepared.crc)
        subprocess.run(["hdiutil", "verify", str(target)], check=True)
        (output / "vendorfw").mkdir()
        with FWPackage(str(output / "vendorfw")) as package:
            installer.collect_firmware(package)
        files = read_newc(output / "vendorfw/firmware.cpio")
        names = sorted(files)
        print("\n".join(names))
        # Identical firmware for several boards is stored as hard links, which
        # carry no data in newc; read contents through the tar, which resolves them.
        with tarfile.open(output / "vendorfw/firmware.tar") as archive:
            def data(name):
                return archive.extractfile(name.removeprefix("vendorfw/")).read()
            for prefix, suffixes in ((WIFI_PREFIX, (".bin", ".txt", ".clm_blob")),
                                     (BT_PREFIX, (".bin", ".ptb"))):
                for suffix in suffixes:
                    assert any(n.startswith("vendorfw/" + prefix) and n.endswith(suffix) and data(n)
                               for n in names), f"missing {prefix}*{suffix}"
        # The M1 Pro's SPI HID trackpad loads no firmware (unlike dockchannel models).
        assert not any(n.startswith("vendorfw/apple/tpmtfw-") for n in names)
        with tarfile.open(output / "all_firmware.tar.gz") as archive:
            assert any(n.startswith("firmware/wifi/") for n in archive.getnames())
            assert any(n.startswith("firmware/bluetooth/") for n in archive.getnames())
        idata = output / "installer-data"
        idata.mkdir()
        (idata / "all_firmware.tar.gz").symlink_to(output / "all_firmware.tar.gz")
        for kernel in restore.glob("kernelcache.*"):
            (idata / kernel.name).symlink_to(kernel)
        update_firmware(idata, output / "rebuilt-vendorfw", machine=None)
        rebuilt = read_newc(output / "rebuilt-vendorfw/firmware.cpio")
        missing = {n for n in files if n.startswith(("vendorfw/" + WIFI_PREFIX, "vendorfw/" + BT_PREFIX))} - rebuilt.keys()
        assert not missing, f"fwextract round-trip lost {missing}"
        after = plistlib.loads(subprocess.check_output(["diskutil", "list", "-plist", "disk0"]))
        assert before == after, "Unexpected physical disk layout change"
        print("PASS: 13.5 recovery staged and verified, APFS compression, read-only mount,")
        print("      j316s Wi-Fi/Bluetooth firmware, fwextract round-trip, unchanged disk0 layout")
        print("firmware.cpio SHA256:", hashlib.sha256((output / "vendorfw/firmware.cpio").read_bytes()).hexdigest())
    finally:
        if installer.recovery_image:
            installer.recovery_image.close()


if __name__ == "__main__":
    main()
