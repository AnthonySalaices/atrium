import copy, os, sys, threading, time, unittest
from unittest import mock
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "atriumd"))
import screen, sgr


def _row(text, cols):
    return [[sgr.DEFAULT, sgr.DEFAULT, 0, text.ljust(cols)]]


class TestCropFrame(unittest.TestCase):
    """An opted-out session streams the desktop-sized pane cropped to what
    the headset asked for: bottom rows, leftmost columns."""

    def _frame(self, cols=10, rows=5):
        return {"type": "screen", "key": "s", "rev": 3, "base": 0,
                "cols": cols, "rows": rows, "alt": False,
                "cursor": {"x": 2, "y": 4, "visible": True},
                "lines": [{"y": y, "runs": _row("r%d" % y, cols)} for y in range(rows)]}

    def test_fits_already_is_untouched(self):
        f = self._frame()
        self.assertIs(screen.crop_frame(f, 10, 5), f)
        self.assertIs(screen.crop_frame(f, 0, 0), f)

    def test_keeps_bottom_rows_and_left_cols(self):
        out = screen.crop_frame(self._frame(), 4, 2)
        self.assertEqual((out["cols"], out["rows"]), (4, 2))
        self.assertEqual([l["y"] for l in out["lines"]], [0, 1])
        self.assertEqual([sgr.runs_to_text(l["runs"]) for l in out["lines"]], ["r3  ", "r4  "])
        self.assertEqual(out["cursor"], {"x": 2, "y": 1, "visible": True})
        self.assertEqual(out["cropped"], [10, 5])

    def test_cursor_outside_the_crop_is_hidden(self):
        f = self._frame(); f["cursor"] = {"x": 8, "y": 0, "visible": True}
        out = screen.crop_frame(f, 4, 2)
        self.assertFalse(out["cursor"]["visible"])

    def test_diff_rows_outside_the_crop_are_dropped(self):
        f = self._frame(); f["base"] = 2
        f["lines"] = [{"y": 0, "runs": _row("top", 10)}, {"y": 4, "runs": _row("bot", 10)}]
        out = screen.crop_frame(f, 10, 2)
        self.assertEqual([l["y"] for l in out["lines"]], [1])
        self.assertEqual(out["base"], 2)

    def test_wide_glyph_on_the_cut_is_padded(self):
        runs = [[1, 2, 0, "a"], [3, 4, 1, "漢字"]]
        out = screen.crop_runs(runs, 2)
        self.assertEqual(sgr.runs_width(out), 2)
        self.assertEqual(sgr.runs_to_text(out), "a ")
        out = screen.crop_runs(runs, 3)
        self.assertEqual(sgr.runs_to_text(out), "a漢")
        self.assertEqual(sgr.runs_width(out), 3)


class TestMirrorFullIsAtomic(unittest.TestCase):
    """`full()` must not come back None because the screen loop polled between
    it clearing `last` and re-reading it: the client asked for everything and
    got nothing, which on a quiet pane is a panel that stays blank for minutes."""

    def test_full_survives_a_concurrent_poller(self):
        m = screen.PaneMirror("dummy")
        frame = {"cols": 4, "rows": 2, "alt": False,
                 "cursor": {"x": 0, "y": 0, "visible": True},
                 "grid": [[[sgr.DEFAULT, sgr.DEFAULT, 0, "ab  "]],
                          [[sgr.DEFAULT, sgr.DEFAULT, 0, "cd  "]]]}
        stop = threading.Event()

        def slow_capture(t, info=None):
            # A real capture shells out to tmux. The race needs that cost: the
            # loop refills `last` while full() is still inside its own capture.
            time.sleep(0.002)
            return copy.deepcopy(frame)

        with mock.patch.object(screen, "pane_info", lambda t: frame), \
             mock.patch.object(screen, "capture", slow_capture):
            def poller():
                # Paced like the real screen loop; a tight loop just starves
                # full() on an unfair lock and makes the suite crawl.
                while not stop.is_set():
                    m.poll()
                    time.sleep(0.002)
            t = threading.Thread(target=poller, daemon=True)
            t.start()
            try:
                for _ in range(80):
                    self.assertIsNotNone(m.full(), "full() returned no frame")
            finally:
                stop.set()
                t.join(timeout=2)


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
