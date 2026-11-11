import subprocess
import unittest
from unittest.mock import patch

from diskutil import DiskUtil


class DiskUtilMountTests(unittest.TestCase):
    def setUp(self):
        self.diskutil = DiskUtil()
        self.target = "disk0s4"
        self.mp = "/private/var/tmp/gravity-disk0s4-test"
        self.error = subprocess.CalledProcessError(1, ["diskutil", "mount", self.target])
        self.action = self.enterContext(patch.object(self.diskutil, "action"))
        self.get = self.enterContext(patch.object(self.diskutil, "get"))
        self.run = self.enterContext(patch("diskutil.subprocess.run"))
        self.mkdtemp = self.enterContext(patch("diskutil.tempfile.mkdtemp", return_value=self.mp))
        self.ismount = self.enterContext(patch("diskutil.os.path.ismount", return_value=True))

    def assert_kernel_mount(self):
        self.mkdtemp.assert_called_once_with(
            prefix="gravity-disk0s4-", dir="/private/var/tmp")
        self.run.assert_called_once_with(
            ["/sbin/mount_msdos", "/dev/disk0s4", self.mp], check=True)
        self.ismount.assert_called_once_with(self.mp)

    def test_diskutil_success(self):
        self.get.return_value = {"MountPoint": "/Volumes/EFI", "FilesystemType": "msdos"}

        self.assertEqual(self.diskutil.mount(self.target), "/Volumes/EFI")

        self.action.assert_called_once_with("mount", self.target)
        self.get.assert_called_once_with("info", "-plist", self.target)
        self.run.assert_not_called()
        self.mkdtemp.assert_not_called()

    def test_diskutil_failure_on_msdos(self):
        self.action.side_effect = self.error
        self.get.return_value = {"FilesystemType": "msdos"}

        with self.assertLogs(level="WARNING") as logs:
            self.assertEqual(self.diskutil.mount(self.target), self.mp)

        self.assert_kernel_mount()
        self.get.assert_called_once_with("info", "-plist", self.target)
        self.assertIn("FSKit", logs.output[0])
        self.assertIn("4096-byte", logs.output[0])
        self.assertIn("kernel msdos driver", logs.output[0])

    def test_diskutil_failure_on_non_fat(self):
        self.action.side_effect = self.error
        for fs in ("apfs", "exfat"):
            with self.subTest(fs=fs):
                self.get.return_value = {"FilesystemType": fs}
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    self.diskutil.mount(self.target)
                self.assertIs(raised.exception, self.error)

        self.run.assert_not_called()
        self.mkdtemp.assert_not_called()

    def test_kernel_mount_does_not_create_mount_point(self):
        self.action.side_effect = self.error
        self.get.return_value = {"FilesystemType": "msdos"}
        self.ismount.return_value = False

        with self.assertRaisesRegex(Exception, "mount_msdos succeeded.*not a mount point"):
            self.diskutil.mount(self.target)

        self.assert_kernel_mount()

    def test_missing_mount_point_on_fat(self):
        for mount_info in ({}, {"MountPoint": ""}, {"MountPoint": None}):
            with self.subTest(mount_info=mount_info):
                self.get.return_value = {"FilesystemType": "msdos", **mount_info}
                with self.assertLogs(level="WARNING"):
                    self.assertEqual(self.diskutil.mount(self.target), self.mp)

        self.assertEqual(self.run.call_count, 3)

    def test_alternate_filesystem_keys(self):
        self.action.side_effect = self.error
        for key, value in (("FilesystemName", "MS-DOS FAT32"),
                           ("FilesystemUserVisibleName", "MS-DOS (FAT32)")):
            with self.subTest(key=key):
                self.get.return_value = {key: value}
                with self.assertLogs(level="WARNING"):
                    self.assertEqual(self.diskutil.mount(self.target), self.mp)

        self.assertEqual(self.run.call_count, 2)

    def test_missing_mount_point_on_non_fat(self):
        self.get.return_value = {"FilesystemType": "apfs"}

        with self.assertRaises(KeyError):
            self.diskutil.mount(self.target)

        self.run.assert_not_called()
        self.mkdtemp.assert_not_called()

    def test_kernel_mount_failure_propagates(self):
        self.action.side_effect = self.error
        self.get.return_value = {"FilesystemType": "msdos"}
        error = subprocess.CalledProcessError(1, ["/sbin/mount_msdos"])
        self.run.side_effect = error

        with self.assertRaises(subprocess.CalledProcessError) as raised:
            self.diskutil.mount(self.target)

        self.assertIs(raised.exception, error)
        self.ismount.assert_not_called()


if __name__ == "__main__":
    unittest.main()
