import json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "atriumd"))
import config
import settings


class SettingsTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.lua = os.path.join(self.dir, "config.lua")
        with open(self.lua, "w") as f:
            f.write('return { color_scheme = "Dracula", backdrop = { mode = "passthrough" } }\n')
        self.sp = settings.path_for(self.lua)

    def test_panel_overrides_lua_and_reset_restores_it(self):
        w = config.ConfigWatcher(self.lua)
        self.assertEqual(w.config["backdrop"]["mode"], "passthrough")
        settings.update(self.sp, {"backdrop.mode": "default",
                                  "backdrop.default.preset": "cafe-night",
                                  "color_scheme": "rose-pine-moon"})
        self.assertTrue(w.poll())
        self.assertEqual(w.config["backdrop"]["mode"], "default")
        self.assertEqual(w.config["backdrop"]["default"]["preset"], "cafe-night")
        self.assertEqual(w.frame()["settings"]["overrides"]["color_scheme"], "rose-pine-moon")
        settings.reset(self.sp, ["backdrop.mode"])
        self.assertTrue(w.poll())
        self.assertEqual(w.config["backdrop"]["mode"], "passthrough")
        settings.reset(self.sp)
        self.assertTrue(w.poll())
        self.assertEqual(w.frame()["settings"]["overrides"], {})

    def test_lua_file_is_never_written(self):
        before = open(self.lua).read()
        settings.update(self.sp, {"pointer.hand": "left"})
        self.assertEqual(open(self.lua).read(), before)

    def test_rejects_unknown_paths_and_values(self):
        with self.assertRaises(ValueError):
            settings.update(self.sp, {"sessions.new.command": "rm -rf ~"})
        with self.assertRaises(ValueError):
            settings.update(self.sp, {"pointer.hand": "tentacle"})
        with self.assertRaises(ValueError):
            settings.update(self.sp, {"font.size_dmm": "big"})
        self.assertEqual(settings.load(self.sp), {})

    def test_steps_are_clamped(self):
        d = settings.update(self.sp, {"font.size_dmm": 5, "backdrop.default.dim": 9})
        self.assertEqual(d["font.size_dmm"], 18.0)
        self.assertEqual(d["backdrop.default.dim"], 0.8)

    def test_stale_file_cannot_inject_keys(self):
        with open(self.sp, "w") as f:
            json.dump({"sessions.new.command": "evil", "pointer.hand": "left"}, f)
        w = config.ConfigWatcher(self.lua)
        self.assertEqual(w.config["pointer"]["hand"], "left")
        self.assertNotEqual(w.config["sessions"]["new"].get("command"), "evil")

    def test_broken_file_is_ignored(self):
        with open(self.sp, "w") as f:
            f.write("{nope")
        w = config.ConfigWatcher(self.lua)
        self.assertEqual(w.config["backdrop"]["mode"], "passthrough")

    def test_schema_lists_every_scheme_and_scene(self):
        rows = {r["id"]: r for g in settings.schema() for r in g["rows"]}
        import schemes
        self.assertEqual(len(rows["scheme"]["options"]), len(schemes.SCHEMES))
        presets = [o["preset"] for o in rows["scene"]["options"]]
        self.assertIn("cafe", presets)
        self.assertIn("", presets)       # passthrough needs no GLB


if __name__ == "__main__":
    unittest.main()
