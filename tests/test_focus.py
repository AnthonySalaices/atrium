import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "glassd"))
import focus


def s(key, state="idle", since=0.0, unread=False):
    return {"key": key, "state": state, "state_since": since, "unread": unread}


class TestStableOrder(unittest.TestCase):
    def test_order_is_alphabetical_not_urgency(self):
        """⭐ The arrangement must not move when something becomes urgent.

        A panel that changes position when it starts asking for attention
        destroys the muscle memory that makes a spatial UI worth having.
        """
        a = [s("zeta", "needs-input"), s("alpha"), s("mid", "error")]
        self.assertEqual([x["key"] for x in focus.stable_order(a)],
                         ["alpha", "mid", "zeta"])

    def test_order_is_unchanged_by_state_churn(self):
        before = focus.stable_order([s("a"), s("b"), s("c")])
        after = focus.stable_order([s("a", "needs-input"), s("b", "error"), s("c", "working")])
        self.assertEqual([x["key"] for x in before], [x["key"] for x in after])


class TestFocusCandidate(unittest.TestCase):
    def test_nobody_waiting_is_none(self):
        self.assertIsNone(focus.focus_candidate([s("a", "working"), s("b", "idle")]))

    def test_needs_input_beats_error_beats_done(self):
        a = [s("d", "done", 1), s("e", "error", 1), s("n", "needs-input", 1)]
        self.assertEqual(focus.focus_candidate(a), "n")
        self.assertEqual(focus.focus_candidate([s("d", "done", 1), s("e", "error", 1)]), "e")

    def test_longest_waiting_wins_within_a_state(self):
        """Fairness, and it stops a chatty session from jumping the queue."""
        a = [s("recent", "needs-input", 500.0), s("patient", "needs-input", 100.0)]
        self.assertEqual(focus.focus_candidate(a), "patient")

    def test_working_never_steals_focus(self):
        self.assertIsNone(focus.focus_candidate([s("busy", "working", 1)]))

    def test_unread_counts_even_when_state_is_not_waiting(self):
        a = [s("quiet", "idle", 1), s("flagged", "idle", 1, unread=True)]
        self.assertEqual(focus.focus_candidate(a), "flagged")

    def test_gone_is_never_focused(self):
        self.assertIsNone(focus.focus_candidate([s("dead", "gone", 1, unread=True)]))


class TestCycle(unittest.TestCase):
    def setUp(self):
        self.a = [s("b"), s("a"), s("c")]     # stable order: a, b, c

    def test_next_and_prev_follow_stable_order(self):
        self.assertEqual(focus.cycle(self.a, "a", +1), "b")
        self.assertEqual(focus.cycle(self.a, "b", -1), "a")

    def test_wraps_both_ways(self):
        self.assertEqual(focus.cycle(self.a, "c", +1), "a")
        self.assertEqual(focus.cycle(self.a, "a", -1), "c")

    def test_unknown_current_lands_somewhere_sensible(self):
        self.assertEqual(focus.cycle(self.a, "ghost", +1), "a")

    def test_empty_is_none(self):
        self.assertIsNone(focus.cycle([], None, +1))

    def test_gone_sessions_are_skipped(self):
        a = [s("a"), s("b", "gone"), s("c")]
        self.assertEqual(focus.cycle(a, "a", +1), "c")


if __name__ == "__main__":
    unittest.main()
