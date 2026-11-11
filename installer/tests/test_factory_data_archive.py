# SPDX-License-Identifier: MIT
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

from stub import factory_data_filter


class FactoryDataArchiveTests(unittest.TestCase):
    def test_filter_uses_case_sensitive_basename_prefixes(self):
        for name in ("seal-record", "factory/seal-record", "factory/nested/MSRk-key"):
            for kind in (tarfile.REGTYPE, tarfile.DIRTYPE, tarfile.SYMTYPE):
                with self.subTest(name=name, kind=kind):
                    info = tarfile.TarInfo(name)
                    info.type = kind
                    self.assertIsNone(factory_data_filter(info))
        for name in ("factory", "factory/BWC2-calibration", "factory/Seal-record",
                     "factory/msrk-key", "factory/not-seal-record", "seal-dir/keep"):
            with self.subTest(name=name):
                info = tarfile.TarInfo(name)
                self.assertIs(factory_data_filter(info), info)

    def test_archive_omits_records_and_preserves_other_data(self):
        with tempfile.TemporaryDirectory() as directory:
            factory = Path(directory) / "com.apple.factorydata"
            factory.mkdir()
            files = ("seal-record", "MSRk-key", "nested/seal-record", "nested/MSRk-key",
                     "seal-private/child", "MSRk-private/child", "BWC2-calibration",
                     "nested/calibration", "Seal-other", "msrk-other")
            for name in files:
                path = factory / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(name.encode())
            (factory / "safe-link").symlink_to("BWC2-calibration")
            data = io.BytesIO()
            with tarfile.open(fileobj=data, mode="w:gz") as archive:
                archive.add(factory, arcname=factory.name, filter=factory_data_filter)
            data.seek(0)
            with tarfile.open(fileobj=data, mode="r:gz") as archive:
                prefix = factory.name + "/"
                self.assertEqual(set(archive.getnames()), {
                    factory.name, prefix + "nested", prefix + "BWC2-calibration",
                    prefix + "nested/calibration", prefix + "Seal-other",
                    prefix + "msrk-other", prefix + "safe-link",
                })
                for name in ("BWC2-calibration", "nested/calibration", "Seal-other", "msrk-other"):
                    self.assertEqual(archive.extractfile(prefix + name).read(), name.encode())
                self.assertEqual(archive.getmember(prefix + "safe-link").linkname, "BWC2-calibration")


if __name__ == "__main__":
    unittest.main()
