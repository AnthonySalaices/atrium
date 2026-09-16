import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "glassd"))
import sgr


class TestSGR(unittest.TestCase):
    def w(self, runs):
        return sgr.runs_width(runs)

    def test_plain_line_is_padded_to_cols(self):
        runs, _ = sgr.parse_line("hello", 20)
        self.assertEqual(self.w(runs), 20)
        self.assertEqual(sgr.runs_to_text(runs), "hello" + " " * 15)

    def test_256_colour_run_splits(self):
        runs, _ = sgr.parse_line("ab\x1b[38;5;153mcd\x1b[39mef", 10)
        self.assertEqual([r[0] for r in runs][:3], [-1, 153, -1])
        self.assertEqual(self.w(runs), 10)

    def test_truecolor(self):
        runs, _ = sgr.parse_line("\x1b[38;2;255;128;0mX", 4)
        self.assertEqual(runs[0][0], sgr.RGB_FLAG | (255 << 16) | (128 << 8))

    def test_attributes_set_and_clear(self):
        runs, _ = sgr.parse_line("\x1b[1mA\x1b[22mB", 4)
        self.assertEqual(runs[0][2] & sgr.BOLD, sgr.BOLD)
        self.assertEqual(runs[1][2] & sgr.BOLD, 0)

    def test_reset_clears_everything(self):
        runs, st = sgr.parse_line("\x1b[1;38;5;9;48;5;4mA\x1b[0mB", 4)
        self.assertEqual((st.fg, st.bg, st.attrs), (-1, -1, 0))

    def test_style_carries_to_next_line(self):
        _, st = sgr.parse_line("\x1b[38;5;99mopen", 10)
        runs2, _ = sgr.parse_line("continues", 10, st)
        self.assertEqual(runs2[0][0], 99)

    def test_wide_glyphs_count_two_cells(self):
        runs, _ = sgr.parse_line("你好", 10)  # two wide CJK chars
        self.assertEqual(self.w(runs), 10)
        self.assertEqual(sgr.runs_to_text(runs), "你好" + " " * 6)

    def test_combining_marks_are_zero_width(self):
        self.assertEqual(sgr.char_width("́"), 0)

    def test_overlong_line_is_trimmed_to_cols(self):
        runs, _ = sgr.parse_line("x" * 50, 10)
        self.assertEqual(self.w(runs), 10)

    def test_unterminated_escape_does_not_crash(self):
        runs, _ = sgr.parse_line("ab\x1b[38;5;", 6)
        self.assertEqual(self.w(runs), 6)

    def test_non_sgr_csi_is_skipped_not_printed(self):
        runs, _ = sgr.parse_line("a\x1b[2Kb", 5)
        self.assertEqual(sgr.runs_to_text(runs).rstrip(), "ab")

    def test_empty_line_is_full_width_blank(self):
        runs, _ = sgr.parse_line("", 8)
        self.assertEqual(self.w(runs), 8)


if __name__ == "__main__":
    unittest.main()
