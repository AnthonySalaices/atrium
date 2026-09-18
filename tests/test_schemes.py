import os, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "atriumd"))
import config
import schemes


def load(text):
    tmp = tempfile.mkdtemp()
    p = os.path.join(tmp, "config.lua")
    with open(p, "w") as f:
        f.write(text)
    cfg, warnings = config.evaluate(p)
    return cfg, warnings + config.validate(cfg)


class TestSchemes(unittest.TestCase):
    def test_default_is_the_shipped_look(self):
        cfg, notes = load("return {}")
        self.assertEqual(notes, [])
        self.assertEqual(cfg["color_scheme"], "atrium")
        self.assertEqual(cfg["colors"]["background"], "#101922")
        self.assertEqual(len(cfg["colors"]["ansi"]), 8)
        self.assertEqual(len(cfg["colors"]["brights"]), 8)

    def test_scheme_by_name_any_case(self):
        cfg, notes = load('return { color_scheme = "ROSE-PINE-MOON" }')
        self.assertEqual(notes, [])
        self.assertEqual(cfg["colors"]["background"], "#232136")
        self.assertEqual(cfg["colors"]["ansi"][1], "#eb6f92")

    def test_unknown_scheme_falls_back_with_a_note(self):
        cfg, notes = load('return { color_scheme = "nope" }')
        self.assertEqual(cfg["colors"]["background"], "#101922")
        self.assertTrue(any("color_scheme" in n for n in notes))

    def test_wezterm_colors_block_pastes_in(self):
        # Straight out of a .wezterm.lua, tab_bar and all.
        cfg, notes = load('''return { colors = {
            foreground = "#E0DEF4", background = "#232136",
            cursor_bg = "#fff",
            ansi = { "#000000", "#111111" },
            indexed = { [16] = "#ffb86c", [255] = "#010203" },
            selection_bg = "#44415a",
            tab_bar = { background = "#232136" },
        } }''')
        self.assertEqual(notes, [])
        c = cfg["colors"]
        self.assertEqual(c["foreground"], "#e0def4")
        self.assertEqual(c["cursor_bg"], "#ffffff")
        self.assertEqual(c["ansi"][:2], ["#000000", "#111111"])
        self.assertEqual(c["ansi"][2], "#0dbc79")          # rest of the scheme survives
        self.assertEqual(c["indexed"], {"16": "#ffb86c", "255": "#010203"})

    def test_xr_hex_and_bad_values(self):
        cfg, notes = load('''local xr = require 'xr'
            return { colors = { background = xr.hex("#232136"), foreground = "teal",
                                bogus = "#000" },
                     default_cursor_style = "Wiggly" }''')
        self.assertEqual(cfg["colors"]["background"], "#232136")
        self.assertEqual(cfg["colors"]["foreground"], "#e0e5ec")
        self.assertEqual(cfg["default_cursor_style"], "SteadyBlock")
        self.assertEqual(len(notes), 3)

    def test_color_forms(self):
        self.assertEqual(schemes.color("#abc"), "#aabbcc")
        self.assertEqual(schemes.color("#AABBCCDD"), "#aabbcc")
        self.assertEqual(schemes.color([1, 0, 0.5]), "#ff0080")
        self.assertIsNone(schemes.color("rgb(1,2,3)"))


if __name__ == "__main__":
    unittest.main()
