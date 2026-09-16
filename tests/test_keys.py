import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "glassd"))
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
