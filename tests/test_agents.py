"""Harness recognition and the tier-3 prompt scrape."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "glassd"))
import agents  # noqa: E402


def procs(*rows):
    """rows of (pid, ppid, comm, args)"""
    return {pid: (ppid, comm, args) for pid, ppid, comm, args in rows}


class FindHarness(unittest.TestCase):
    def test_pane_command_is_enough(self):
        self.assertEqual(agents.find_harness(10, "claude", {}), "claude-code")
        self.assertEqual(agents.find_harness(10, "codex", {}), "codex")

    def test_walks_tree_while_a_tool_runs(self):
        # tmux reports `bash` while Claude Code runs a shell tool.
        p = procs((10, 1, "bash", "bash"), (11, 10, "claude", "claude"),
                  (12, 11, "bash", "bash -c ls"))
        self.assertEqual(agents.find_harness(10, "bash", p), "claude-code")

    def test_node_wrapped_harness(self):
        p = procs((10, 1, "zsh", "zsh"), (11, 10, "node", "node /usr/lib/node_modules/@google/gemini-cli/dist/gemini.js"))
        self.assertEqual(agents.find_harness(10, "node", p), "gemini-cli")

    def test_python_module_harness(self):
        p = procs((10, 1, "bash", "bash"), (11, 10, "python3", "python3 -m aider --model deepseek"))
        self.assertEqual(agents.find_harness(10, "python3", p), "aider")

    def test_plain_shell_is_not_an_agent(self):
        p = procs((10, 1, "bash", "bash"), (11, 10, "vim", "vim notes.md"))
        self.assertIsNone(agents.find_harness(10, "bash", p))

    def test_user_extra_harness(self):
        cfg = {"agents": {"extra": {"mytool": {"match": ["mytool"], "needs_input": ["Proceed?"]}}}}
        t = agents.table(cfg)
        p = procs((10, 1, "bash", "bash"), (11, 10, "mytool", "mytool --serve"))
        self.assertEqual(agents.find_harness(10, "bash", p, t), "mytool")
        self.assertEqual(agents.classify("…\nProceed? ", "mytool", t)[0], "needs-input")

    def test_extra_overrides_builtin_phrases(self):
        cfg = {"agents": {"extra": {"aider": {"needs_input": ["CUSTOM?"]}}}}
        t = agents.table(cfg)
        self.assertEqual(t["aider"]["needs_input"], ["CUSTOM?"])
        self.assertEqual(t["aider"]["name"], "aider")       # untouched fields survive

    def test_bad_extra_is_ignored(self):
        t = agents.table({"agents": {"extra": {"x": "not a table"}}})
        self.assertNotIn("x", t)


class Classify(unittest.TestCase):
    def test_claude_code_permission_prompt(self):
        tail = "\n" * 20 + "Bash(rm -rf build)\nDo you want to proceed?\n> 1. Yes"
        self.assertEqual(agents.classify(tail, "claude-code")[0], "needs-input")

    def test_claude_code_working(self):
        self.assertEqual(agents.classify("…\n✻ Thinking… (esc to interrupt)", "claude-code")[0], "working")

    def test_aider_yes_no(self):
        self.assertEqual(agents.classify("Add src/x.py to the chat? (Y)es/(N)o [Yes]:", "aider")[0], "needs-input")

    def test_idle_by_default(self):
        self.assertEqual(agents.classify("$ ", "codex")[0], "idle")

    def test_only_the_tail_counts(self):
        old_prompt = "Do you want to proceed?\n" + "\n".join("line %d" % i for i in range(30))
        self.assertEqual(agents.classify(old_prompt, "claude-code")[0], "idle")

    def test_unknown_harness_is_idle(self):
        self.assertEqual(agents.classify("Do you want to proceed?", "nope")[0], "idle")


class SessionFilter(unittest.TestCase):
    def test_empty_means_everything(self):
        self.assertTrue(agents.session_allowed("anything", {"sessions": {"include": [], "exclude": []}}))
        self.assertTrue(agents.session_allowed("anything", {}))

    def test_include_and_exclude(self):
        cfg = {"sessions": {"include": ["^cc", "^cx"], "exclude": ["scratch"]}}
        self.assertTrue(agents.session_allowed("cc-vr", cfg))
        self.assertFalse(agents.session_allowed("main", cfg))
        self.assertFalse(agents.session_allowed("cc-scratch", cfg))

    def test_bad_pattern_does_not_hide_everything(self):
        cfg = {"sessions": {"include": ["("]}}
        # an unmatchable include still means "nothing matched" -> hidden, but a
        # broken pattern must not raise
        self.assertFalse(agents.session_allowed("cc-vr", cfg))
        cfg = {"sessions": {"exclude": ["("]}}
        self.assertTrue(agents.session_allowed("cc-vr", cfg))


if __name__ == "__main__":
    unittest.main()
