import os, subprocess, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "atriumd"))
import spawn
import config


class TestSpawn(unittest.TestCase):
    def test_next_name_matches_cc_new(self):
        taken = {"cc", "cc-2"}
        self.assertEqual(spawn.next_name("cc", lambda n: n in taken), "cc-3")
        self.assertEqual(spawn.next_name("cx", lambda n: False), "cx")

    def test_bad_names_refused(self):
        with self.assertRaises(ValueError):
            spawn.next_name("a b", lambda n: False)
        with self.assertRaises(ValueError):
            spawn.close_session("-t evil")

    def test_config_defaults_and_bad_prefix(self):
        cfg, _ = config.evaluate("")
        self.assertEqual(config.validate(cfg), [])
        self.assertEqual(cfg["sessions"]["new"]["command"], "claude")
        cfg["sessions"]["new"]["prefix"] = "no spaces"
        self.assertTrue(any("prefix" in n for n in config.validate(cfg)))
        self.assertEqual(cfg["sessions"]["new"]["prefix"], "cc")

    @unittest.skipUnless(os.path.exists(spawn.TMUX), "no tmux")
    def test_new_then_close_real_tmux(self):
        name = spawn.new_session({"command": "sleep 60", "prefix": "atrium-spawntest"})
        try:
            self.assertTrue(spawn._exists(name))
        finally:
            spawn.close_session(name)
        self.assertFalse(spawn._exists(name))


if __name__ == "__main__":
    unittest.main()
