import os
import tempfile
import unittest
from unittest.mock import Mock

from diskutil import Partition
from osinstall import OSInstaller


def partition(name, uuid):
    return Partition(name, 0, 1, False, "EFI", uuid)


class SteamOSPartsetTests(unittest.TestCase):
    def test_ab_partsets_and_grubenv(self):
        layout = [("esp", "AAAA0001"), ("efi-A", "AAAA0002"), ("rootfs-A", "AAAA0003"),
                  ("var-A", "AAAA0004"), ("efi-B", "AAAA0005"), ("rootfs-B", "AAAA0006"),
                  ("var-B", "AAAA0007"), ("home", "AAAA0008")]
        template = {"default_os_name": "SteamOS",
                    "partitions": [{"name": role, "size": "1B", "type": "Linux", "steamos": role}
                                   for role, _ in layout]}
        mounts = {}

        def mount(name):
            mounts.setdefault(name, tempfile.mkdtemp())
            return mounts[name]

        ins = OSInstaller(Mock(mount=Mock(side_effect=mount)), None, template)
        ins.part_info = [partition(f"disk0s{i}", uuid) for i, (_, uuid) in enumerate(layout)]
        ins.write_steamos_partsets()

        def read(slot_part, *path):
            with open(os.path.join(mounts[slot_part], "SteamOS", *path)) as fd:
                return fd.read()

        # efi-A is disk0s1, efi-B is disk0s4; nothing else is mounted.
        self.assertEqual(set(mounts), {"disk0s1", "disk0s4"})
        self.assertEqual(read("disk0s1", "partsets", "self"),
                         "efi aaaa0002\nrootfs aaaa0003\nvar aaaa0004\n")
        self.assertEqual(read("disk0s1", "partsets", "other"),
                         "efi aaaa0005\nrootfs aaaa0006\nvar aaaa0007\n")
        self.assertEqual(read("disk0s4", "partsets", "self"), read("disk0s1", "partsets", "B"))
        self.assertEqual(read("disk0s1", "partsets", "shared"), "esp aaaa0001\nhome aaaa0008\n")
        self.assertEqual(read("disk0s1", "partsets", "all").splitlines()[:3],
                         ["esp aaaa0001", "home aaaa0008", "efi-A aaaa0002"])

        env = read("disk0s4", "neo-grubenv")
        self.assertEqual(len(env), 1024)
        self.assertTrue(env.startswith("# GRUB Environment Block\n"
                                       "steamos_rootfs_partuuid=aaaa0006\n#"))


if __name__ == "__main__":
    unittest.main()
