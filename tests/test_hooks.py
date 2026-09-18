"""Hook installers: merge, back up, re-parse, idempotent, uninstall only ours."""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "atriumd"))
import hooks  # noqa: E402


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "settings.json")

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, obj):
        with open(self.path, "w") as f:
            f.write(obj if isinstance(obj, str) else json.dumps(obj))

    def read(self):
        with open(self.path) as f:
            return json.load(f)


class ClaudeCode(Base):
    def test_install_merges_and_backs_up(self):
        self.write({"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "mine.sh"}]}]}})
        inst = hooks.ClaudeCode(self.path)
        r = inst.apply()
        self.assertEqual(r.status, "installed")
        self.assertEqual(len(r.changes), len(inst.events))
        s = self.read()
        self.assertEqual(s["model"], "opus")                      # untouched
        self.assertEqual(s["hooks"]["Stop"][0]["hooks"][0]["command"], "mine.sh")   # theirs kept
        self.assertTrue(any("glow-emit.sh" in h["command"] for g in s["hooks"]["Stop"] for h in g["hooks"]))
        self.assertTrue(any(f.startswith("settings.json.bak-") for f in os.listdir(self.tmp.name)))
        self.assertEqual(inst.status().status, "installed")

    def test_idempotent(self):
        self.write({})
        inst = hooks.ClaudeCode(self.path)
        inst.apply()
        r = inst.apply()
        self.assertEqual(r.changes, [])
        s = self.read()
        self.assertEqual(len(s["hooks"]["Stop"]), 1)

    def test_uninstall_removes_only_ours(self):
        self.write({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "mine.sh"}]}]}})
        inst = hooks.ClaudeCode(self.path)
        inst.apply()
        r = inst.apply(uninstall=True)
        self.assertTrue(r.changes)
        s = self.read()
        self.assertEqual(s["hooks"]["Stop"], [{"hooks": [{"type": "command", "command": "mine.sh"}]}])
        self.assertNotIn("SessionStart", s["hooks"])
        self.assertEqual(inst.status().status, "absent")

    def test_uninstall_drops_empty_hooks_key(self):
        self.write({"a": 1})
        inst = hooks.ClaudeCode(self.path)
        inst.apply()
        inst.apply(uninstall=True)
        self.assertEqual(self.read(), {"a": 1})

    def test_invalid_json_is_left_alone(self):
        self.write("{not json")
        inst = hooks.ClaudeCode(self.path)
        r = inst.apply()
        self.assertEqual(r.status, "invalid")
        with open(self.path) as f:
            self.assertEqual(f.read(), "{not json")
        self.assertEqual(inst.status().status, "invalid")

    def test_dry_run_writes_nothing(self):
        self.write({})
        r = hooks.ClaudeCode(self.path).apply(dry_run=True)
        self.assertTrue(r.changes)
        self.assertEqual(self.read(), {})

    def test_missing_file_is_created(self):
        p = os.path.join(self.tmp.name, "sub", "settings.json")
        r = hooks.ClaudeCode(p).apply()
        self.assertEqual(r.status, "installed")
        self.assertTrue(os.path.exists(p))

    def test_partial(self):
        self.write({"hooks": {"Stop": [hooks.ClaudeCode(self.path).group()]}})
        self.assertEqual(hooks.ClaudeCode(self.path).status().status, "partial")

    def test_never_hooks_tool_use(self):
        self.assertNotIn("PreToolUse", hooks.ClaudeCode.events)
        self.assertNotIn("PostToolUse", hooks.ClaudeCode.events)


class GeminiCli(Base):
    def test_shape(self):
        self.write({})
        hooks.GeminiCli(self.path).apply()
        s = self.read()
        g = s["hooks"]["Notification"][0]
        self.assertEqual(g["matcher"], "*")
        h = g["hooks"][0]
        self.assertEqual(h["name"], "atrium")
        self.assertEqual(h["timeout"], 5000)                   # milliseconds
        self.assertTrue(h["command"].endswith("glow-emit.sh gemini-cli"))
        self.assertIn("BeforeAgent", s["hooks"])
        self.assertIn("AfterAgent", s["hooks"])


class Codex(Base):
    def test_shape_and_feature_note(self):
        self.write({})
        inst = hooks.Codex(self.path)
        inst.config_toml = os.path.join(self.tmp.name, "config.toml")
        with open(inst.config_toml, "w") as f:
            f.write('[features]\nhooks = false\n')
        inst.apply()
        s = self.read()
        self.assertIn("PermissionRequest", s["hooks"])
        self.assertTrue(s["hooks"]["Stop"][0]["hooks"][0]["command"].endswith("glow-emit.sh codex"))
        r = inst.status()
        self.assertEqual(r.status, "installed")
        self.assertIn("features", r.note or "")

    def test_feature_enabled_reads_toml(self):
        inst = hooks.Codex(self.path)
        inst.config_toml = os.path.join(self.tmp.name, "config.toml")
        with open(inst.config_toml, "w") as f:
            f.write('model = "x"\n[features]\nhooks = true\n')
        self.assertTrue(inst.feature_enabled())


class Registry(unittest.TestCase):
    def test_every_installer_has_the_pieces(self):
        for h, cls in hooks.INSTALLERS.items():
            self.assertEqual(cls.harness, h)
            self.assertTrue(cls.default_path)
            self.assertTrue(cls.events)

    def test_unsupported_reports_not_crashes(self):
        r = hooks.statuses(["aider"])[0]
        self.assertEqual(r.status, "unsupported")


if __name__ == "__main__":
    unittest.main()
