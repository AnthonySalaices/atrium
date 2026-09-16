import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "glassd"))
import screen, sgr


class TestScreenAgainstLiveTmux(unittest.TestCase):
    """These run against whatever tmux session exists; skipped if none."""

    @classmethod
    def setUpClass(cls):
        try:
            out = screen._tmux(["list-sessions", "-F", "#{session_name}"])
            cls.target = out.split("\n")[0].strip()
        except Exception:
            cls.target = None

    def setUp(self):
        if not self.target:
            self.skipTest("no tmux session available")

    def test_every_row_is_exactly_cols_wide(self):
        f = screen.capture(self.target)
        widths = {sgr.runs_width(r) for r in f["grid"]}
        self.assertEqual(widths, {f["cols"]})

    def test_grid_height_matches_pane_height(self):
        f = screen.capture(self.target)
        self.assertEqual(len(f["grid"]), f["rows"])

    def test_first_poll_is_a_full_frame(self):
        m = screen.PaneMirror(self.target)
        msg = m.full()
        self.assertEqual(msg["base"], 0)
        self.assertEqual(len(msg["lines"]), msg["rows"])

    def test_second_poll_is_a_diff_or_none(self):
        m = screen.PaneMirror(self.target)
        m.full()
        msg = m.poll()
        if msg is not None:
            self.assertNotEqual(msg["base"], 0)
            self.assertLessEqual(len(msg["lines"]), msg["rows"])

    def test_bad_target_raises_capture_error(self):
        with self.assertRaises(screen.CaptureError):
            screen.pane_info("no-such-session-xyzzy")


if __name__ == "__main__":
    unittest.main()
