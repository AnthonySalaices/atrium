import os, sys, unittest, subprocess
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "atriumd"))
import pin

SESSION = "atrium-pintest"


def tmux(*args):
    p = subprocess.run(["tmux"] + list(args), capture_output=True, text=True, timeout=5)
    return p.stdout.strip() if p.returncode == 0 else None


def geometry():
    return tmux("display-message", "-p", "-t", SESSION, "#{window_width}x#{window_height}")


class TestPinAgainstThrowawaySession(unittest.TestCase):
    """Creates and kills its own detached tmux session; never touches others."""

    def setUp(self):
        if subprocess.run(["tmux", "-V"], capture_output=True).returncode != 0:
            self.skipTest("tmux not installed")
        tmux("kill-session", "-t", SESSION)
        if tmux("new-session", "-d", "-s", SESSION, "-x", "200", "-y", "50") is None:
            self.skipTest("could not create a tmux session")
        # A detached session under the server's `window-size latest` is
        # re-sized to the newest client immediately, so hold it at 200x50.
        tmux("set-option", "-w", "-t", SESSION, "window-size", "manual")
        tmux("resize-window", "-t", SESSION, "-x", "200", "-y", "50")
        pin._pinned.clear()

    def tearDown(self):
        pin._pinned.clear()
        tmux("kill-session", "-t", SESSION)

    def test_pin_records_on_the_window_and_restores(self):
        self.assertEqual(geometry(), "200x50")
        self.assertTrue(pin.pin(SESSION, 80, 28))
        self.assertEqual(geometry(), "80x28")
        self.assertEqual(tmux("show-options", "-w", "-v", "-t", SESSION, pin.PREV_OPT), "manual|200|50")
        self.assertTrue(pin.unpin(SESSION))
        self.assertEqual(geometry(), "200x50")
        self.assertFalse(tmux("show-options", "-w", "-v", "-t", SESSION, pin.PREV_OPT))
        self.assertEqual(tmux("show-options", "-w", "-v", "-t", SESSION, "window-size"), "manual")

    def test_unset_window_size_is_unset_again_after_restore(self):
        tmux("set-option", "-w", "-u", "-t", SESSION, "window-size")
        pin.pin(SESSION, 80, 28)
        self.assertTrue(tmux("show-options", "-w", "-v", "-t", SESSION, pin.PREV_OPT).startswith("-|"))
        self.assertEqual(tmux("show-options", "-w", "-v", "-t", SESSION, "window-size"), "manual")
        pin.unpin(SESSION)
        # resize-window sets `manual`; the restore must end with the option UNSET
        self.assertFalse(tmux("show-options", "-w", "-v", "-t", SESSION, "window-size"))
        self.assertFalse(tmux("show-options", "-w", "-v", "-t", SESSION, pin.PREV_OPT))

    def test_restart_recovers_a_pin_left_by_a_dead_daemon(self):
        pin.pin(SESSION, 80, 28)
        pin._pinned.clear()                      # the daemon died here
        self.assertEqual(geometry(), "80x28")
        self.assertEqual(pin.recover(), 1)       # the next daemon starts
        self.assertEqual(geometry(), "200x50")
        self.assertFalse(pin.is_pinned(SESSION))

    def test_repin_after_restart_adopts_the_old_record_not_vr_geometry(self):
        pin.pin(SESSION, 80, 28)
        pin._pinned.clear()
        pin.pin(SESSION, 80, 28)                 # the 9/17 bug: "was 80x28, manual"
        self.assertEqual(pin.status()[SESSION]["cols"], 200)
        pin.unpin(SESSION)
        self.assertEqual(geometry(), "200x50")

    def test_opted_out_window_is_never_resized(self):
        tmux("set-option", "-w", "-t", SESSION, pin.PIN_OPT, "off")
        self.assertTrue(pin.opted_out(SESSION))
        self.assertFalse(pin.pin(SESSION, 80, 28))
        self.assertEqual(geometry(), "200x50")
        self.assertFalse(pin.is_pinned(SESSION))


if __name__ == "__main__":
    unittest.main()
