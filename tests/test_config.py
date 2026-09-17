import os, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "glassd"))
import config


def write(tmp, text):
    p = os.path.join(tmp, "config.lua")
    with open(p, "w") as f:
        f.write(text)
    return p


class TestConfig(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_defaults_load_with_no_user_config(self):
        cfg, warnings = config.evaluate("")
        self.assertEqual(warnings, [])
        # The shipped baseline is the procedural nebula (M3), not passthrough.
        self.assertEqual(cfg["backdrop"]["mode"], "default")
        self.assertIn("glass", cfg)

    def test_user_override_is_deep_merged(self):
        p = write(self.tmp, 'return { glass = { opacity = 0.2 } }')
        cfg, _ = config.evaluate(p)
        self.assertEqual(cfg["glass"]["opacity"], 0.2)
        self.assertEqual(cfg["glass"]["blur"], 0.55)   # sibling default survives

    def test_nested_override_keeps_siblings(self):
        p = write(self.tmp, 'return { glass = { edge = { width_mm = 9 } } }')
        cfg, _ = config.evaluate(p)
        self.assertEqual(cfg["glass"]["edge"]["width_mm"], 9)
        self.assertEqual(cfg["glass"]["edge"]["opacity"], 0.42)

    def test_arrays_replace_wholesale(self):
        p = write(self.tmp, 'return { sessions = { include = { "^only" } } }')
        cfg, _ = config.evaluate(p)
        self.assertEqual(cfg["sessions"]["include"], ["^only"])

    def test_unknown_key_warns_but_does_not_fail(self):
        p = write(self.tmp, 'return { glass = { opacty = 0.5 } }')
        cfg, warnings = config.evaluate(p)
        self.assertTrue(any("opacty" in w for w in warnings))

    def test_documented_unset_key_does_not_warn(self):
        p = write(self.tmp, 'return { backdrop = { custom = { glb = "/tmp/x.glb" } } }')
        _, warnings = config.evaluate(p)
        self.assertEqual(warnings, [])

    def test_syntax_error_raises_with_useful_message(self):
        p = write(self.tmp, 'return { glass = ')
        with self.assertRaises(config.ConfigError) as cm:
            config.evaluate(p)
        self.assertIn("config.lua", str(cm.exception))

    def test_helper_error_is_reported_not_swallowed(self):
        p = write(self.tmp, 'local xr=require "xr" return { glass={tint=xr.hex("nope")} }')
        with self.assertRaises(config.ConfigError):
            config.evaluate(p)

    def test_font_floor_is_enforced(self):
        cfg, _ = config.evaluate("")
        cfg["font"]["size_dmm"] = 3
        notes = config.validate(cfg)
        self.assertEqual(cfg["font"]["size_dmm"], config.FONT_DMM_MIN)
        self.assertTrue(any("size_dmm" in n for n in notes))

    def test_bad_backdrop_mode_falls_back(self):
        cfg, _ = config.evaluate("")
        cfg["backdrop"]["mode"] = "hologram"
        config.validate(cfg)
        self.assertEqual(cfg["backdrop"]["mode"], "passthrough")

    def test_custom_mode_without_glb_falls_back_to_default(self):
        cfg, _ = config.evaluate("")
        cfg["backdrop"]["mode"] = "custom"
        cfg["backdrop"]["custom"]["glb"] = None
        config.validate(cfg)
        self.assertEqual(cfg["backdrop"]["mode"], "default")

    def test_clear_radius_cannot_go_below_two_metres(self):
        cfg, _ = config.evaluate("")
        cfg["backdrop"]["custom"]["clear_radius_m"] = 0.1
        config.validate(cfg)
        self.assertEqual(cfg["backdrop"]["custom"]["clear_radius_m"], 2.0)

    def test_layer_budget_is_capped(self):
        cfg, _ = config.evaluate("")
        cfg["panels"]["tile"]["max"] = 99
        cfg["sessions"]["max_panels"] = 99
        config.validate(cfg)
        self.assertEqual(cfg["panels"]["tile"]["max"], 7)
        self.assertEqual(cfg["sessions"]["max_panels"], 8)

    def test_ambience_defaults_are_silent_and_valid(self):
        cfg, _ = config.evaluate("")
        notes = config.validate(cfg)
        amb = cfg["ambience"]
        self.assertFalse(amb["enabled"])          # silence is the default, always
        self.assertEqual(amb["music"]["mode"], "procedural")
        self.assertEqual(notes, [])

    def test_ambience_volumes_and_steam_window_are_clamped(self):
        p = write(self.tmp, """return { ambience = {
            volume = 4,
            typing = { volume = -1 },
            steam = { every_min_s = 900, every_max_s = 30, length_min_s = 90 },
        } }""")
        cfg, _ = config.evaluate(p)
        config.validate(cfg)
        amb = cfg["ambience"]
        self.assertEqual(amb["volume"], 1.0)
        self.assertEqual(amb["typing"]["volume"], 0.0)
        # min > max is a swap, not a silent room or a hiss every 30 minutes.
        self.assertLessEqual(amb["steam"]["every_min_s"], amb["steam"]["every_max_s"])
        self.assertEqual(amb["steam"]["length_min_s"], 4.0)
        self.assertEqual(amb["steam"]["length_max_s"], 15.0)

    def test_ambience_music_mode_is_an_enum_and_folder_needs_a_dir(self):
        p = write(self.tmp, 'return { ambience = { music = { mode = "jazz" } } }')
        cfg, _ = config.evaluate(p)
        notes = config.validate(cfg)
        self.assertEqual(cfg["ambience"]["music"]["mode"], "procedural")
        self.assertTrue(any("music.mode" in n for n in notes))

        p = write(self.tmp, 'return { ambience = { music = { mode = "folder" } } }')
        cfg, _ = config.evaluate(p)
        notes = config.validate(cfg)
        self.assertEqual(cfg["ambience"]["music"]["mode"], "procedural")
        self.assertTrue(any("music.dir" in n for n in notes))

    def test_ambience_music_dir_is_not_checked_against_this_host(self):
        """The path belongs to the headset's filesystem, not the daemon's."""
        p = write(self.tmp,
                  'return { ambience = { music = { mode = "folder", dir = "/sdcard/Music" } } }')
        cfg, _ = config.evaluate(p)
        config.validate(cfg)
        self.assertEqual(cfg["ambience"]["music"]["mode"], "folder")
        self.assertEqual(cfg["ambience"]["music"]["dir"], "/sdcard/Music")

    def test_empty_config_keeps_all_defaults(self):
        """A config with everything commented out must not wipe the defaults."""
        p = write(self.tmp, "return {}")
        cfg, _ = config.evaluate(p)
        self.assertIsInstance(cfg, dict)
        self.assertEqual(cfg["glass"]["opacity"], 0.38)
        self.assertEqual(cfg["backdrop"]["mode"], "default")

    def test_empty_map_override_is_a_noop(self):
        p = write(self.tmp, "return { glass = {} }")
        cfg, _ = config.evaluate(p)
        self.assertEqual(cfg["glass"]["opacity"], 0.38)

    def test_empty_list_override_clears_the_list(self):
        p = write(self.tmp, "return { sessions = { include = {} } }")
        cfg, _ = config.evaluate(p)
        self.assertEqual(cfg["sessions"]["include"], [])

    def test_watcher_reloads_on_change(self):
        p = write(self.tmp, 'return { glass = { opacity = 0.5 } }')
        w = config.ConfigWatcher(user_path=p)
        self.assertEqual(w.config["glass"]["opacity"], 0.5)
        self.assertFalse(w.poll())
        os.utime(p, (0, 0))
        write(self.tmp, 'return { glass = { opacity = 0.9 } }')
        self.assertTrue(w.poll())
        self.assertEqual(w.config["glass"]["opacity"], 0.9)
        self.assertEqual(w.rev, 2)

    def test_watcher_keeps_last_good_config_on_broken_edit(self):
        p = write(self.tmp, 'return { glass = { opacity = 0.5 } }')
        w = config.ConfigWatcher(user_path=p)
        os.utime(p, (0, 0))
        write(self.tmp, 'return { glass = ')       # user saves mid-edit
        self.assertFalse(w.poll())
        self.assertEqual(w.config["glass"]["opacity"], 0.5)   # panels keep working
        self.assertIsNotNone(w.error)
        self.assertEqual(w.frame()["rev"], 1)


if __name__ == "__main__":
    unittest.main()


class LupaParity(unittest.TestCase):
    """The lupa evaluator must print exactly what the vendored binary prints."""

    def _both(self, user):
        import subprocess, sys
        binary = os.path.join(config.ROOT, "vendor", "lua", "bin", "lua")
        if not os.path.exists(binary):
            self.skipTest("lua binary not built")
        try:
            import lupa  # noqa: F401
        except ImportError:
            self.skipTest("lupa not installed")
        a = subprocess.run([binary, config.EVAL, config.CONFIG_DIR, user],
                           capture_output=True, text=True, timeout=10).stdout
        b = subprocess.run([sys.executable, config.LUAEVAL, config.CONFIG_DIR, user],
                           capture_output=True, text=True, timeout=10).stdout
        return a, b

    def test_defaults_identical(self):
        a, b = self._both("")
        self.assertEqual(a, b)

    def test_broken_config_identical(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
            f.write("return {")
        a, b = self._both(f.name)
        os.unlink(f.name)
        self.assertEqual(a, b)
        self.assertIn('"ok":false', a)
