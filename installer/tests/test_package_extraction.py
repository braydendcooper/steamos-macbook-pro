# SPDX-License-Identifier: MIT
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

from util import PackageInstaller


class PackageExtractionTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.dest = self.root / "dest"
        self.dest.mkdir()

    def extract(self, entries):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            for name, contents, mode in entries:
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = mode << 16
                archive.writestr(info, contents)
        self.extract_zip(data)

    def extract_zip(self, data):
        installer = PackageInstaller()
        installer.verbose = False
        installer.ucache = None
        with zipfile.ZipFile(data) as archive, redirect_stdout(io.StringIO()):
            installer.pkg = archive
            installer.extract_tree("src", self.dest)

    def test_rejects_parent_components_and_absolute_paths(self):
        for name in ("src/../escape", "src/../../escape", "src/nested/../file",
                     "src//escape"):
            with self.subTest(name=name):
                with self.assertRaisesRegex(ValueError, "Unsafe ZIP entry path"):
                    self.extract([(name, b"unsafe", stat.S_IFREG)])
                self.assertEqual(list(self.dest.iterdir()), [])
                self.assertEqual(list(self.root.iterdir()), [self.dest])

    def test_rejects_nul_in_original_zip_name(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            archive.writestr("src/nested/file!suffix", b"unsafe")
        data = io.BytesIO(data.getvalue().replace(b"file!suffix", b"file\0suffix"))
        with self.assertRaisesRegex(ValueError, "Unsafe ZIP entry path"):
            self.extract_zip(data)
        self.assertEqual(list(self.dest.iterdir()), [])

    def test_rejects_unsafe_symlink_targets_before_creating_parents(self):
        for target in (str(self.root / "escape"), "../../escape", "../..//dest-other/file",
                       "bad\0target"):
            with self.subTest(target=target):
                with self.assertRaisesRegex(ValueError, "ZIP symlink target"):
                    self.extract([("src/nested/link", target, stat.S_IFLNK)])
                self.assertEqual(list(self.dest.iterdir()), [])
                self.assertFalse((self.root / "escape").exists())

    def test_rejects_existing_parent_symlink_escape(self):
        outside = self.root / "dest-other"
        outside.mkdir()
        (self.dest / "parent").symlink_to(outside, target_is_directory=True)
        for name, mode in (("src/parent/nested/file", stat.S_IFREG),
                           ("src/parent/nested/", stat.S_IFDIR),
                           ("src/parent/nested/link", stat.S_IFLNK)):
            with self.subTest(name=name):
                with self.assertRaisesRegex(ValueError, "ZIP entry escapes destination"):
                    self.extract([(name, b"file", mode)])
                self.assertEqual(list(outside.iterdir()), [])

    def test_rejects_existing_file_symlink_escape(self):
        outside = self.root / "escape"
        outside.write_bytes(b"original")
        (self.dest / "file").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "ZIP entry escapes destination"):
            self.extract([("src/file", b"replacement", stat.S_IFREG)])
        self.assertEqual(outside.read_bytes(), b"original")

    def test_rejects_target_through_existing_symlink(self):
        outside = self.root / "dest-other"
        outside.mkdir()
        (self.dest / "outside").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "ZIP symlink target escapes destination"):
            self.extract([("src/nested/link", b"../outside/file", stat.S_IFLNK)])
        self.assertFalse((self.dest / "nested").exists())
        self.assertEqual(list(outside.iterdir()), [])

    def test_extracts_directories_nested_files_and_safe_relative_symlinks(self):
        self.extract([
            ("src/", b"", stat.S_IFDIR),
            ("src/empty/", b"", stat.S_IFDIR),
            ("src/nested/file", b"contents", stat.S_IFREG),
            ("src/links/file", b"../nested/file", stat.S_IFLNK),
        ])
        self.assertTrue((self.dest / "empty").is_dir())
        self.assertEqual((self.dest / "nested/file").read_bytes(), b"contents")
        self.assertEqual(os.readlink(self.dest / "links/file"), "../nested/file")
        self.assertEqual((self.dest / "links/file").read_bytes(), b"contents")

    def test_allows_existing_symlink_within_destination(self):
        (self.dest / "nested").mkdir()
        (self.dest / "parent").symlink_to("nested", target_is_directory=True)
        self.extract([("src/parent/file", b"contents", stat.S_IFREG)])
        self.assertEqual((self.dest / "nested/file").read_bytes(), b"contents")


if __name__ == "__main__":
    unittest.main()
