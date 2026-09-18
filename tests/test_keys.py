import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "atriumd"))
import keys


class FakeProc:
    def __init__(self, rc=0):
        self.returncode = rc
        self.stdout = self.stderr = ""


class Runner:
    """Records argv lists instead of spawning tmux."""

    def __init__(self, rc=0):
        self.calls = []
        self.rc = rc

    def __call__(self, argv, **kw):
        self.calls.append(argv)
        return FakeProc(self.rc)


class TestNames(unittest.TestCase):
    def test_verified_names_pass(self):
        for n in ("Enter", "Escape", "Tab", "BTab", "BSpace", "Up", "DC",
                  "PageUp", "F12", "Space", "C-c", "M-x", "C-M-x", "S-Up",
                  "C-Space"):
            self.assertEqual(keys.validate_name(n), n)

    def test_the_names_that_tmux_would_TYPE_are_refused(self):
        """⛔ The whole reason this module exists.

        tmux answers an unknown name by typing it as text, so `S-Tab` and
        `Backspace` put those literal words into the pane. Verified against a
        real pane — these must never reach send-keys.
        """
        for n in ("S-Tab", "Backspace", "Ctrl-C", "Return", "Esc", "ArrowUp",
                  "S-a", "S-Enter"):
            with self.assertRaises(keys.Rejected, msg=n):
                keys.validate_name(n)

    def test_bare_character_is_not_a_key(self):
        with self.assertRaises(keys.Rejected):
            keys.validate_name("a")

    def test_injection_shaped_names_refused(self):
        for n in ("Enter; rm -rf /", "$(id)", "`id`", "a b", "Up\nDown", ""):
            with self.assertRaises(keys.Rejected, msg=n):
                keys.validate_name(n)

    def test_overlong_name_refused(self):
        with self.assertRaises(keys.Rejected):
            keys.validate_name("C-" * 20 + "x")


class TestLiterals(unittest.TestCase):
    def test_printable_text_passes(self):
        self.assertEqual(keys.validate_literal("ls -la | grep x"), "ls -la | grep x")

    def test_unicode_passes(self):
        self.assertEqual(keys.validate_literal("héllo ✅"), "héllo ✅")

    def test_control_characters_must_be_named_keys(self):
        for t in ("a\nb", "a\tb", "a\rb", "\x1b[A", "a\x7f"):
            with self.assertRaises(keys.Rejected, msg=repr(t)):
                keys.validate_literal(t)

    def test_length_capped(self):
        with self.assertRaises(keys.Rejected):
            keys.validate_literal("x" * (keys.MAX_LITERAL + 1))


class TestArgv(unittest.TestCase):
    def test_named_argv(self):
        self.assertEqual(keys.argv_for("my-session", {"k": "Enter"}),
                         [keys.TMUX, "send-keys", "-t", "my-session", "--", "Enter"])

    def test_literal_argv_uses_dash_l_and_terminator(self):
        argv = keys.argv_for("my-session", {"l": "-rf --x"})
        self.assertEqual(argv, [keys.TMUX, "send-keys", "-t", "my-session", "-l", "--", "-rf --x"])
        # A literal that looks like a flag must sit after `--`, never before it.
        self.assertGreater(argv.index("-rf --x"), argv.index("--"))

    def test_bad_session_refused(self):
        for s in ("", "a b", "x;y", "$(id)", "x" * 65):
            with self.assertRaises(keys.Rejected, msg=s):
                keys.plan(s, [{"k": "Enter"}])


class TestSend(unittest.TestCase):
    def setUp(self):
        keys._buckets.clear()

    def test_sends_in_order(self):
        r = Runner()
        n = keys.send("my-session", [{"l": "ls"}, {"k": "Enter"}], runner=r)
        self.assertEqual(n, 2)
        self.assertEqual(r.calls[0][-1], "ls")
        self.assertEqual(r.calls[1][-1], "Enter")

    def test_nothing_is_sent_when_any_item_is_bad(self):
        """All-or-nothing: a bad item late in the batch must not let the earlier
        ones through, or a rejected chord still half-types."""
        r = Runner()
        with self.assertRaises(keys.Rejected):
            keys.send("my-session", [{"l": "ls"}, {"k": "S-Tab"}], runner=r)
        self.assertEqual(r.calls, [])

    def test_tmux_failure_is_not_an_exception(self):
        r = Runner(rc=1)
        self.assertEqual(keys.send("my-session", [{"k": "Enter"}], runner=r), 0)

    def test_rate_limited_eventually(self):
        """A buggy client must not be able to spawn unbounded tmux processes."""
        r = Runner()
        with self.assertRaises(keys.Rejected):
            for _ in range(50):
                keys.send("my-session", [{"k": "C-a"}] * 8, runner=r)
        self.assertLess(len(r.calls), 50 * 8)

    def test_too_many_items(self):
        r = Runner()
        with self.assertRaises(keys.Rejected):
            keys.send("my-session", [{"k": "Enter"}] * (keys.MAX_ITEMS + 1), runner=r)


if __name__ == "__main__":
    unittest.main()


class StateRunner(Runner):
    """Answers display-message with a fixed pane state, records the rest."""

    def __init__(self, in_mode=0, alternate=0, mouse=0):
        super().__init__()
        self.state = "%d %d %d" % (in_mode, alternate, mouse)

    def __call__(self, argv, **kw):
        self.calls.append(argv)
        p = FakeProc(0)
        if argv[1] == "display-message":
            p.stdout = self.state + "\n"
        return p


class TestScroll(unittest.TestCase):
    """The pointer's scroll gesture, delivered three different ways."""

    def test_mouse_reporting_app_gets_sgr_wheel_at_the_pointer_cell(self):
        r = StateRunner(mouse=1)
        out = keys.scroll("s", 3, col=12, row=7, runner=r)
        self.assertEqual(out, {"sent": 3, "via": "wheel"})
        argv = r.calls[-1]
        self.assertEqual(argv[:5], [keys.TMUX, "send-keys", "-t", "s", "-l"])
        self.assertEqual(argv[-1], "\x1b[<64;12;7M" * 3)

    def test_wheel_down_is_button_65(self):
        r = StateRunner(mouse=1)
        keys.scroll("s", -1, runner=r)
        self.assertEqual(r.calls[-1][-1], "\x1b[<65;1;1M")

    def test_plain_shell_enters_copy_mode_with_exit_on_bottom(self):
        r = StateRunner()
        out = keys.scroll("s", 5, runner=r)
        self.assertEqual(out, {"sent": 5, "via": "copy-mode"})
        self.assertEqual(r.calls[1], [keys.TMUX, "copy-mode", "-e", "-t", "s"])
        self.assertEqual(r.calls[2], [keys.TMUX, "send-keys", "-t", "s", "-X", "-N", "5", "scroll-up"])

    def test_scroll_down_at_the_bottom_sends_nothing(self):
        r = StateRunner()
        out = keys.scroll("s", -5, runner=r)
        self.assertEqual(out["sent"], 0)
        self.assertEqual(len(r.calls), 1)          # only the state query

    def test_scroll_down_inside_copy_mode_does_not_re_enter(self):
        r = StateRunner(in_mode=1)
        out = keys.scroll("s", -2, runner=r)
        self.assertEqual(out, {"sent": 2, "via": "copy-mode"})
        self.assertNotIn("copy-mode", [c[1] for c in r.calls])

    def test_alternate_screen_without_mouse_is_skipped(self):
        """⛔ Up/Down into an editor would be keystrokes, not scrolling."""
        r = StateRunner(alternate=1)
        out = keys.scroll("s", 3, runner=r)
        self.assertEqual(out["sent"], 0)
        self.assertIn("alternate", out["skipped"])
        self.assertEqual(len(r.calls), 1)

    def test_bad_input_is_rejected_before_tmux_is_asked(self):
        r = StateRunner()
        for bad in (0, "3", 3.0, True, 999):
            with self.assertRaises(keys.Rejected, msg=repr(bad)):
                keys.scroll("s", bad, runner=r)
        with self.assertRaises(keys.Rejected):
            keys.scroll("s", 1, col=0, runner=r)
        with self.assertRaises(keys.Rejected):
            keys.scroll("bad session!", 1, runner=r)
        self.assertEqual(r.calls, [])
