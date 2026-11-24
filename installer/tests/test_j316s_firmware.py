# SPDX-License-Identifier: MIT
"""16-inch M1 Pro MacBook Pro (j316s): 13.5 recovery and Broadcom firmware."""
from contextlib import nullcontext
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import zipfile

import recovery
import stub
from gravity_firmware.open_firmware import OpenFirmwareCollection


# Layout of the 13.5 recovery's usr/share/firmware for the M1 Pro's BCM4387.
J316S_WIFI_SOURCES = {
    "C-4387__s-C2/madagascar.trx": b"wifi-firmware",
    "C-4387__s-C2/P-madagascar-X3_M-HRPN_V-u__m-7.5.txt": b"boardrev=0x1\n",
    "C-4387__s-C2/madagascar-X3.clmb": b"wifi-regulatory",
    "C-4387__s-C2/madagascar-X3.txcb": b"wifi-tx-power",
}
J316S_BT_SOURCES = {
    "BCM4387C2_19.3.395.4044_PCIE_macOS_Madagascar_CLPC_OS_USI_20211103.bin": b"bt-firmware",
    "BCM4387C2_EVTv1_PCIE_macOS_Madagascar_CLPC_OS_USI_20210624.ptb": b"bt-ptb",
}
J316S_WIFI_OUTPUTS = {
    "brcm/brcmfmac4387c2-pcie.apple,madagascar.bin",
    "brcm/brcmfmac4387c2-pcie.apple,madagascar.txt",
    "brcm/brcmfmac4387c2-pcie.apple,madagascar.clm_blob",
    "brcm/brcmfmac4387c2-pcie.apple,madagascar.txcap_blob",
}
J316S_BT_OUTPUTS = {
    "brcm/brcmbt4387c2-apple,madagascar-u.bin",
    "brcm/brcmbt4387c2-apple,madagascar-u.ptb",
}
# Another board's radio (M1 MacBook Air), which must not satisfy j316s.
OTHER_WIFI_SOURCES = {"C-4378__s-B1/shikoku.trx": b"x", "C-4378__s-B1/P-shikoku-X0_M-RASP_V-m__m-5.1.txt": b"boardrev=0x1\n"}
OTHER_BT_SOURCES = {"BCM4378B1_18.3.6.1134_PCIE_macOS_Shikoku_CLPC_OS_MUR_20210211.bin": b"x"}


def write_tree(root, files):
    for name, data in files.items():
        path = Path(root) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


def recovery_mount(root, version="13.5", wifi=J316S_WIFI_SOURCES, bt=J316S_BT_SOURCES):
    plist = root / "System/Library/CoreServices/SystemVersion.plist"
    plist.parent.mkdir(parents=True)
    plist.write_bytes(plistlib.dumps({"ProductVersion": version}))
    write_tree(root / "usr/share/firmware/wifi", wifi)
    write_tree(root / "usr/share/firmware/bluetooth", bt)


class J316sRadioTests(unittest.TestCase):
    def collect(self, wifi, bt, machine="j316s"):
        with tempfile.TemporaryDirectory() as directory:
            write_tree(Path(directory) / "wifi", wifi)
            write_tree(Path(directory) / "bt", bt)
            w, b = stub.radio_files(f"{directory}/wifi", f"{directory}/bt", machine)
            return {name for name, _ in w}, {name for name, _ in b}

    def test_generic_collection_produces_madagascar_firmware(self):
        wifi, bt = self.collect(J316S_WIFI_SOURCES, J316S_BT_SOURCES)
        self.assertEqual(wifi, J316S_WIFI_OUTPUTS)
        self.assertEqual(bt, J316S_BT_OUTPUTS)

    def test_other_boards_are_kept_alongside(self):
        wifi, bt = self.collect({**J316S_WIFI_SOURCES, **OTHER_WIFI_SOURCES},
                                {**J316S_BT_SOURCES, **OTHER_BT_SOURCES})
        self.assertTrue(J316S_WIFI_OUTPUTS <= wifi)
        self.assertTrue(J316S_BT_OUTPUTS <= bt)

    def test_missing_wifi_board_is_refused(self):
        with self.assertRaisesRegex(ValueError, "Wi-Fi"):
            self.collect(OTHER_WIFI_SOURCES, J316S_BT_SOURCES)

    def test_missing_bluetooth_board_is_refused(self):
        with self.assertRaisesRegex(ValueError, "Bluetooth"):
            self.collect(J316S_WIFI_SOURCES, OTHER_BT_SOURCES)

    def test_unknown_machine_is_refused(self):
        with self.assertRaisesRegex(ValueError, "No Wi-Fi/Bluetooth firmware profile"):
            self.collect(J316S_WIFI_SOURCES, J316S_BT_SOURCES, machine="j314s")

    def test_open_firmware_profile_is_empty(self):
        self.assertEqual(list(OpenFirmwareCollection(machine="j316s").files()), [])


class J316sPreflightTests(unittest.TestCase):
    def installer(self):
        installer = stub.StubInstaller.__new__(stub.StubInstaller)
        installer.is_ota = False
        installer.pkg = Mock()
        installer.install_version = "13.5"
        installer.recovery_image = None
        installer.load_identity = Mock(return_value={"Info": {"DeviceClass": "j316sap"},
            "Manifest": {"BaseSystem": {"Info": {"Path": "090-12345-678.dmg"}}}})
        return installer

    def preflight(self, root, installer):
        image = SimpleNamespace(path=root, close=Mock())
        with patch.object(stub, "PlainRecoveryImage", return_value=image) as plain, \
             patch.object(stub, "RecoveryImage", side_effect=AssertionError("AEA")), \
             patch.object(stub, "mounted_recovery", return_value=nullcontext(root)):
            try:
                installer.preflight_recovery()
            finally:
                plain.assert_called_once_with(installer.pkg, "090-12345-678.dmg")
        return image

    def test_plain_recovery_is_validated_before_partitioning(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            recovery_mount(root)
            installer = self.installer()
            image = self.preflight(root, installer)
            self.assertIs(installer.recovery_image, image)
            image.close.assert_not_called()

    def test_missing_radio_firmware_fails_preflight(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            recovery_mount(root, wifi=OTHER_WIFI_SOURCES)
            installer = self.installer()
            image = SimpleNamespace(path=root, close=Mock())
            with patch.object(stub, "PlainRecoveryImage", return_value=image), \
                 patch.object(stub, "mounted_recovery", return_value=nullcontext(root)):
                with self.assertRaisesRegex(ValueError, "Wi-Fi"):
                    installer.preflight_recovery()
            image.close.assert_called_once_with()
            self.assertIsNone(installer.recovery_image)

    def test_wrong_recovery_version_fails_preflight(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            recovery_mount(root, version="12.3")
            installer = self.installer()
            with self.assertRaisesRegex(ValueError, "Unexpected recovery version"):
                self.preflight(root, installer)
            self.assertIsNone(installer.recovery_image)


class PlainRecoveryImageTests(unittest.TestCase):
    def test_stages_member_and_records_crc(self):
        with tempfile.TemporaryDirectory() as directory:
            ipsw = Path(directory) / "test.ipsw"
            data = b"basesystem" * 1000
            with zipfile.ZipFile(ipsw, "w") as z:
                z.writestr("090-12345-678.dmg", data)
            with zipfile.ZipFile(ipsw) as z, \
                 patch.object(recovery.subprocess, "run") as run:
                image = recovery.PlainRecoveryImage(z, "090-12345-678.dmg")
                try:
                    self.assertEqual(image.path.read_bytes(), data)
                    self.assertEqual(image.crc, recovery.file_checksums(image.path)[1])
                    run.assert_called_once_with(
                        ["/usr/bin/hdiutil", "verify", str(image.path)], check=True)
                finally:
                    image.close()
                self.assertFalse(image.path.exists())


if __name__ == "__main__":
    unittest.main()
