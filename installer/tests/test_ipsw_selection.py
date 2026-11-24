# SPDX-License-Identifier: MIT
import contextlib
import io
import unittest
from dataclasses import replace
from types import SimpleNamespace
from unittest.mock import patch

import main


class IPSWSelectionTests(unittest.TestCase):
    def setUp(self):
        # Do not initialize the installer: that probes disks and macOS state.
        # Host values from a 16-inch M1 Pro MacBook Pro on macOS 27.3.
        self.installer = main.InstallerMain.__new__(main.InstallerMain)
        self.installer.sysinfo = SimpleNamespace(
            sys_firmware="mBoot-20457.60.77.501.2", macos_ver="27.3",
            sfr_full_ver="27.3", chip_id=0x6000, device_class="j316sap")
        self.installer.device = main.DEVICES["j316sap"]
        self.installer.expert = False

    def choose(self, supported_fw=("13.5",), **minimums):
        ipsw = replace(main.IPSW_VERSIONS[0], **minimums)
        with patch.object(main, "IPSW_VERSIONS", [ipsw]), contextlib.redirect_stdout(io.StringIO()):
            return self.installer.choose_ipsw(list(supported_fw))

    def test_m1_pro_uses_13_5_stub(self):
        # Linux's M1-family GPU driver only supports 12.3 and 13.5 firmware.
        self.assertEqual([i.version for i in main.IPSW_VERSIONS], ["13.5"])
        with contextlib.redirect_stdout(io.StringIO()):
            ipsw = self.installer.choose_ipsw(["13.5"])
        self.assertEqual(ipsw.version, "13.5")
        self.assertIn("UniversalMac_13.5_22G74_Restore.ipsw", ipsw.url)

    def test_only_the_m1_pro_is_supported(self):
        self.assertEqual(set(main.DEVICES), {"j316sap"})
        self.assertEqual(set(main.CHIP_MIN_VER), {0x6000})

    def test_newer_host_firmware_prefixes_pass_the_minimum(self):
        for firmware in ("iBoot-8422.141.2", "iBoot-13822.81.10", "mBoot-20457.60.77.501.2"):
            with self.subTest(firmware=firmware):
                self.installer.sysinfo.sys_firmware = firmware
                self.assertEqual(self.choose().version, "13.5")

    def test_real_firmware_minimum_is_enforced(self):
        self.installer.sysinfo.sys_firmware = "iBoot-8422.141.1"
        with self.assertRaises(SystemExit):
            self.choose()

    def test_macos_minimum_is_enforced(self):
        with self.assertRaises(SystemExit):
            self.choose(min_macos="27.4")

    def test_real_sfr_minimum_is_enforced(self):
        self.installer.sysinfo.sfr_full_ver = "22.7.73"
        with self.assertRaises(SystemExit):
            self.choose()

    def test_other_device_never_gets_the_entry(self):
        self.installer.sysinfo.device_class = "j314sap"
        with self.assertRaises(SystemExit):
            self.choose()

    def test_stub_version_not_supported_by_os_is_refused(self):
        with self.assertRaises(SystemExit):
            self.choose(supported_fw=("26.6.2",))


if __name__ == "__main__":
    unittest.main()
