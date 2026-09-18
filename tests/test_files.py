import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "atriumd"))
import files  # noqa: E402


def cfg(mode="custom", glb=None):
    return {"backdrop": {"mode": mode, "custom": {"glb": glb} if glb is not None else {}}}


class TestBackdropPath(unittest.TestCase):
    """The daemon serves exactly one file, and only when the config says so."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.glb = os.path.join(self.tmp, "room.glb")
        with open(self.glb, "wb") as f:
            f.write(b"glTF\x02\x00\x00\x00" + b"\x00" * 64)

    def test_serves_the_configured_file(self):
        path, why = files.backdrop_path(cfg(glb=self.glb))
        self.assertEqual(path, self.glb)
        self.assertIsNone(why)

    def test_nothing_is_served_unless_the_mode_is_custom(self):
        for mode in ("default", "passthrough", "", None):
            path, why = files.backdrop_path(cfg(mode=mode, glb=self.glb))
            self.assertIsNone(path, "mode %r must not serve a file" % mode)
            self.assertIn("mode", why)

    def test_unset_missing_and_wrong_suffix_all_refuse(self):
        self.assertIsNone(files.backdrop_path(cfg(glb=""))[0])
        self.assertIsNone(files.backdrop_path(cfg())[0])
        self.assertIsNone(files.backdrop_path(cfg(glb=self.glb + ".nope"))[0])
        other = os.path.join(self.tmp, "secrets.txt")
        open(other, "w").close()
        path, why = files.backdrop_path(cfg(glb=other))
        self.assertIsNone(path)
        self.assertIn(".glb", why)

    def test_a_directory_is_not_a_file(self):
        d = os.path.join(self.tmp, "room.glb.d")
        os.mkdir(d)
        self.assertIsNone(files.backdrop_path(cfg(glb=d))[0])

    def test_tilde_is_expanded(self):
        home = os.path.expanduser("~")
        if not self.glb.startswith(home):
            self.skipTest("temp dir is not under $HOME")
        rel = "~" + self.glb[len(home):]
        self.assertEqual(files.backdrop_path(cfg(glb=rel))[0], self.glb)

    def test_oversized_files_are_refused(self):
        real = files.MAX_BYTES
        try:
            files.MAX_BYTES = 8
            path, why = files.backdrop_path(cfg(glb=self.glb))
            self.assertIsNone(path)
            self.assertIn("limit", why)
        finally:
            files.MAX_BYTES = real

    def test_etag_changes_when_the_file_does(self):
        first = files.etag(self.glb)
        self.assertEqual(first, files.etag(self.glb))       # stable across calls
        time.sleep(1.1)                                     # mtime has 1 s resolution here
        with open(self.glb, "ab") as f:
            f.write(b"more")
        self.assertNotEqual(first, files.etag(self.glb))


if __name__ == "__main__":
    unittest.main()
