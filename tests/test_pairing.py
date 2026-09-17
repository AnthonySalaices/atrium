import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "glassd"))
import pairing  # noqa: E402


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


class PairingTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.p = pairing.Pairing(clock=self.clock)

    def test_code_shape_and_ttl(self):
        code, ttl = self.p.new_code()
        self.assertRegex(code, r"^\d{6}$")
        self.assertEqual(ttl, pairing.TTL_S)
        self.assertTrue(self.p.active())
        self.assertEqual(self.p.seconds_left(), pairing.TTL_S)

    def test_redeem_once(self):
        code, _ = self.p.new_code()
        self.assertEqual(self.p.redeem(code), (True, "ok"))
        self.assertEqual(self.p.redeem(code), (False, "none"))
        self.assertFalse(self.p.active())

    def test_wrong_then_right(self):
        code, _ = self.p.new_code()
        self.assertEqual(self.p.redeem("000000" if code != "000000" else "111111"), (False, "wrong"))
        self.assertEqual(self.p.redeem(code), (True, "ok"))

    def test_expiry(self):
        code, _ = self.p.new_code()
        self.clock.t += pairing.TTL_S + 1
        self.assertEqual(self.p.redeem(code), (False, "expired"))
        self.assertFalse(self.p.active())

    def test_lockout_after_guesses(self):
        code, _ = self.p.new_code()
        bad = "999999" if code != "999999" else "888888"
        for _ in range(pairing.MAX_TRIES - 1):
            self.assertEqual(self.p.redeem(bad), (False, "wrong"))
        self.assertEqual(self.p.redeem(bad), (False, "locked"))
        self.assertEqual(self.p.redeem(code), (False, "locked"))      # even the right one
        self.clock.t += pairing.LOCK_S + 1
        self.assertEqual(self.p.redeem(code), (False, "none"))        # code was retired

    def test_new_code_clears_lockout(self):
        self.p.new_code()
        for _ in range(pairing.MAX_TRIES):
            self.p.redeem("xxxxxx")
        code, _ = self.p.new_code()
        self.assertEqual(self.p.redeem(code), (True, "ok"))

    def test_whitespace_and_non_strings(self):
        code, _ = self.p.new_code()
        self.assertEqual(self.p.redeem(None), (False, "wrong"))
        self.assertEqual(self.p.redeem(" %s \n" % code), (True, "ok"))


if __name__ == "__main__":
    unittest.main()
