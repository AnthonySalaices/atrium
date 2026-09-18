import os, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "atriumd"))
import browser
import config


def load(text):
    tmp = tempfile.mkdtemp()
    p = os.path.join(tmp, "config.lua")
    with open(p, "w") as f:
        f.write(text)
    cfg, warnings = config.evaluate(p)
    return cfg, warnings + config.validate(cfg)


class TestBrowserConfig(unittest.TestCase):
    def test_default_has_no_apps(self):
        cfg, notes = load("return {}")
        self.assertEqual(notes, [])
        self.assertEqual(cfg["browser"]["apps"], [])
        self.assertEqual(cfg["browser"]["mobile"]["scale"], 2.0)

    def test_apps_validated(self):
        cfg, notes = load('''return { browser = { apps = {
            { name = "docs", url = "http://localhost:4040/", layout = "mobile" },
            { name = "bad name", url = "https://x" },
            { name = "js", url = "javascript:alert(1)" },
            { name = "docs", url = "https://dup" },
            { name = "odd", url = "https://y", layout = "tablet" },
        } } }''')
        apps = cfg["browser"]["apps"]
        self.assertEqual([a["name"] for a in apps], ["docs", "odd"])
        self.assertEqual(apps[0]["layout"], "mobile")
        self.assertEqual(apps[1]["layout"], "desktop")
        self.assertEqual(len(notes), 4)


class TestKeys(unittest.TestCase):
    def test_tmux_names_map_to_playwright(self):
        self.assertEqual(browser.pw_key("Enter"), "Enter")
        self.assertEqual(browser.pw_key("BSpace"), "Backspace")
        self.assertEqual(browser.pw_key("BTab"), "Shift+Tab")
        self.assertEqual(browser.pw_key("C-a"), "Control+a")
        self.assertEqual(browser.pw_key("C-M-x"), "Control+Alt+x")
        self.assertEqual(browser.pw_key("S-Up"), "Shift+ArrowUp")
        self.assertEqual(browser.pw_key("M-Left"), "Alt+ArrowLeft")
        self.assertEqual(browser.pw_key("F5"), "F5")
        self.assertEqual(browser.pw_key("C-Space"), "Control+Space")
        self.assertIsNone(browser.pw_key("Bogus"))
        self.assertIsNone(browser.pw_key("F13"))

    def test_is_web(self):
        self.assertTrue(browser.is_web("web:docs"))
        self.assertFalse(browser.is_web("cc-vr"))
        self.assertFalse(browser.is_web(None))


if __name__ == "__main__":
    unittest.main()
