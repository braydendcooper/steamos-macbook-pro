# SPDX-License-Identifier: MIT
"""Exercise the native installer paths with synthetic macOS inputs."""
from contextlib import ExitStack, contextmanager, nullcontext
import os
from pathlib import Path
import plistlib
import shutil
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import stub
from gravity_firmware import isp, multitouch, neo_als, neo_isp, neo_mesacal, neo_mt7932
from gravity_firmware.core import FWFile, FWPackage
import test_neo_mt7932 as radio_tests
from test_neo_als import lsci
from test_neo_isp import blob
from test_m4_firmware import read_newc


@contextmanager
def working_directory(path):
    previous = os.getcwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(previous)


class NeoInstallerTests(unittest.TestCase):
    def test_collect_firmware_packages_driver_names_and_preserves_raw_fallback(self):
        fixture = radio_tests.CollectTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        root = fixture.root
        recovery = root / "recovery"
        recovery.mkdir()
        # Recovery lacks the Bluetooth PTB; the host has all radio inputs.
        for relative in (neo_mt7932.IZUBA, neo_mt7932.BLUETOOTH):
            target = recovery / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(root / relative, target)
        (recovery / neo_mt7932.BLUETOOTH / neo_mt7932.BT_PTX).unlink()
        camera = recovery / "usr/sbin"
        camera.mkdir(parents=True)
        camera_data = bytearray()
        for entry in [entry for entry in isp.ISP_SETFILES if entry.sensor == 0x558] + [neo_isp.IMX558_1925]:
            camera_data += bytes((-len(camera_data)) % 4096) + blob(entry)
        (camera / "appleh16camerad").write_bytes(camera_data)
        installer = stub.StubInstaller.__new__(stub.StubInstaller)
        installer.identity = {"Info": {"DeviceClass": "j700ap", "RestoreBehavior": "Erase", "Variant": "test"},
                              "Manifest": {"Multitouch": {"Info": {"Path": "Multitouch.im4p", "IsFUDFirmware": True}}}}
        installer.behavior, installer.variant = "Erase", "test"
        installer.pb_vgid = str(root)
        installer.restore_bundle_path = lambda: "restore"
        installer.osi = SimpleNamespace(recovery=str(root), vgid="recovery-volume")
        installer.copy_idata = []
        installer.extract = lambda _source, dest: (Path(dest) / "Multitouch.im4p").write_bytes(b"synthetic im4p")
        trackpad = {"C1FE0,0": [{"Type": "Config", "Config": {
            "Interface Config": [{"bInterfaceNumber": 1}]}}]}
        out = root / "output"
        out.mkdir()
        collect_radio = neo_mt7932.collect
        with ExitStack() as stack:
            stack.enter_context(working_directory(root))
            stack.enter_context(patch.object(stub, "mounted_recovery", return_value=nullcontext(recovery)))
            stack.enter_context(patch.object(stub, "FACTORY_DIR", str(root / neo_mt7932.FACTORY_DATA)))
            radio = stack.enter_context(patch.object(neo_mt7932, "collect",
                side_effect=lambda _root, **kwargs: collect_radio(str(root), **kwargs)))
            stack.enter_context(patch.object(neo_mt7932, "device_tree_chosen", return_value=fixture.chosen))
            stack.enter_context(patch.object(neo_als, "read_lsci", return_value=lsci()))
            stack.enter_context(patch.object(multitouch, "img4p_extract", return_value=("mtfw", plistlib.dumps(trackpad))))
            stack.enter_context(patch.object(neo_mesacal, "has_builtin_sensor", return_value=False))
            stack.enter_context(patch.object(stub, "KernelFWCollection", return_value=SimpleNamespace(files=lambda: [])))
            broadcom_wifi = stack.enter_context(patch.object(stub, "WiFiFWCollection", side_effect=AssertionError("Broadcom Wi-Fi on Neo")))
            broadcom_bt = stack.enter_context(patch.object(stub, "BluetoothFWCollection", side_effect=AssertionError("Broadcom Bluetooth on Neo")))
            with FWPackage(out) as package:
                installer.collect_firmware(package)
            radio.assert_called_once_with('/', factory=str(root / neo_mt7932.FACTORY_DATA))
            broadcom_wifi.assert_not_called()
            broadcom_bt.assert_not_called()
            with tarfile.open("all_firmware.tar.gz") as archive:
                names = archive.getnames()
                self.assertIn("apple_mediatek_firmware/IZUBA_wifi.cfg", names)
                self.assertIn("j700-exbright-LSCI.bin", names)
                self.assertIn("appleh16camerad", names)
                self.assertIn("com.apple.factorydata/BWC2-00008140-0000", names)
        files = read_newc(out / "firmware.cpio")
        expected = {
            "vendorfw/apple/tpmtfw-j700.bin", "vendorfw/apple/j700-aop-als-cal.bin",
            "vendorfw/apple/isp_1921_01XX.dat", "vendorfw/apple/isp_1922_02XX.dat",
            "vendorfw/apple/isp_1925_03XX.dat", "vendorfw/mediatek/mt7932/policy/world-XZ.bin",
            "vendorfw/mediatek/mt7932/policy/US.bin", "vendorfw/mediatek/mt7932/ppr.bin",
            "vendorfw/mediatek/mt7932/oca2.bin", "vendorfw/mediatek/mt7932/wcal.bin",
            "vendorfw/mediatek/mt7932/config-original.bin", "vendorfw/mediatek/j700-mt7932-btcal.bin",
            "vendorfw/mediatek/j700-mt7932-bdaddr.bin", "vendorfw/.vendorfw.manifest",
        } | {"vendorfw/mediatek/mt7932/" + name for name in (neo_mt7932.WIFI_PATCH, neo_mt7932.WIFI_RAM)} \
          | {"vendorfw/mediatek/" + name for name in (*neo_mt7932.BT_FIRMWARE, neo_mt7932.BT_PTX)}
        # FWPackage can encode duplicate data as a hard link; use tar to resolve it.
        with tarfile.open(out / "firmware.tar") as archive:
            self.assertEqual(set(archive.getnames()), {name.removeprefix("vendorfw/") for name in expected if not name.endswith(".manifest")})
            for name in archive.getnames():
                self.assertTrue(archive.extractfile(name).read())
        self.assertTrue(set(files) <= expected)
        self.assertEqual(files["vendorfw/apple/j700-aop-als-cal.bin"], neo_als.calibration(lsci()))
        self.assertEqual(files["vendorfw/apple/tpmtfw-j700.bin"][:4], b"HIDF")

    def test_j700_preflight_validates_host_radio_and_avoids_broadcom(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            version = root / "System/Library/CoreServices/SystemVersion.plist"
            version.parent.mkdir(parents=True)
            version.write_bytes(plistlib.dumps({"ProductVersion": "26.6.2"}))
            installer = stub.StubInstaller.__new__(stub.StubInstaller)
            installer.is_ota = False
            installer.pkg = Mock()
            installer.install_version = "26.6.2"
            installer.load_identity = Mock(return_value={"Info": {"DeviceClass": "j700ap"},
                "Manifest": {"BaseSystem": {"Info": {"Path": "Recovery.aea"}}}})
            image = SimpleNamespace(path=root, close=Mock())
            with patch.object(stub, "RecoveryImage", return_value=image), \
                 patch.object(stub, "mounted_recovery", return_value=nullcontext(root)), \
                 patch.object(stub, "WiFiFWCollection", side_effect=AssertionError("Broadcom")), \
                 patch.object(stub, "BluetoothFWCollection", side_effect=AssertionError("Broadcom")), \
                 patch.object(neo_mt7932, "collect", return_value=[]) as collect:
                installer.preflight_recovery()
            collect.assert_called_once_with('/', factory=stub.FACTORY_DIR)
            installer.load_identity.assert_called_once_with(prepare_paths=False)
            self.assertIs(installer.recovery_image, image)
            image.close.assert_not_called()

    def test_j700_preflight_propagates_radio_input_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            version = root / "System/Library/CoreServices/SystemVersion.plist"
            version.parent.mkdir(parents=True)
            version.write_bytes(plistlib.dumps({"ProductVersion": "26.6.2"}))
            for error in (FileNotFoundError("missing Bluetooth PTB"),
                          ValueError("invalid radio calibration")):
                with self.subTest(error=error):
                    installer = stub.StubInstaller.__new__(stub.StubInstaller)
                    installer.is_ota = False
                    installer.pkg = Mock()
                    installer.install_version = "26.6.2"
                    installer.recovery_image = None
                    installer.load_identity = Mock(return_value={"Info": {"DeviceClass": "j700ap"},
                        "Manifest": {"BaseSystem": {"Info": {"Path": "Recovery.aea"}}}})
                    image = SimpleNamespace(path=root, close=Mock())
                    with patch.object(stub, "RecoveryImage", return_value=image), \
                         patch.object(stub, "mounted_recovery", return_value=nullcontext(root)), \
                         patch.object(neo_mt7932, "collect", side_effect=error) as collect:
                        with self.assertRaises(type(error)) as raised:
                            installer.preflight_recovery()
                    self.assertIs(raised.exception, error)
                    collect.assert_called_once_with('/', factory=stub.FACTORY_DIR)
                    image.close.assert_called_once_with()
                    self.assertIsNone(installer.recovery_image)

    def test_mesacal_reads_only_calibration_and_never_collects_root_key(self):
        installer = stub.StubInstaller.__new__(stub.StubInstaller)
        installer.dutil = SimpleNamespace(find_system_disk=lambda: "disk0", disk_parts={"disk0": {
            "Partitions": [{"Content": "Apple_APFS_ISC", "DeviceIdentifier": "disk0s1"}]}})
        package = Mock()
        files = [(neo_mesacal.FIRMWARE_NAME, FWFile(neo_mesacal.FIRMWARE_NAME, b"calibration"))]
        with patch.object(neo_mesacal, "has_builtin_sensor", return_value=True), \
             patch.object(neo_mesacal, "collect", return_value=files) as collect, \
             patch.object(neo_mesacal, "factory_root_key", side_effect=AssertionError("root key")):
            installer.collect_neo_mesacal(package)
        collect.assert_called_once_with("/dev/rdisk0s1")
        package.add_files.assert_called_once_with(files)

    def test_optional_mesacal_failure_does_not_emit_invalid_data(self):
        installer = stub.StubInstaller.__new__(stub.StubInstaller)
        package = Mock()
        with patch.object(neo_mesacal, "has_builtin_sensor", side_effect=neo_mesacal.MesaError("bad IORegistry")):
            installer.collect_neo_mesacal(package)
        package.add_files.assert_not_called()
