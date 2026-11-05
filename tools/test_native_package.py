"""Verify the installable archive contains sources and assets, never build output."""
import hashlib
import unittest
import zipfile

from build_native import build


class NativePackageTests(unittest.TestCase):
    def test_reproducible_complete_archive(self):
        path = build()
        first = hashlib.sha256(path.read_bytes()).digest()
        self.assertEqual(first, hashlib.sha256(build().read_bytes()).digest())
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            self.assertIsNone(archive.testzip())
            for required in (
                "horizon-native.json", "horizon-mod.toml", "LICENSE", "NOTICE",
                "mixins/orbital/horizon-mixin.toml",
                "mixins/orbital/engine/src/lib.rs", "mixins/orbital/post.rs",
                "assets/orbital/sounds.json",
            ):
                self.assertIn(required, names)
            self.assertTrue(any(n.startswith("data/orbital/") for n in names))
            self.assertTrue(any(n.endswith(".ogg") for n in names))
            self.assertFalse(any("target" in n.split("/") for n in names))
            self.assertFalse(any(n.endswith((".exe", ".pdb", ".jar")) for n in names))


if __name__ == "__main__":
    unittest.main()
