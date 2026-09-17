import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "glassd"))
import confedit  # noqa: E402
import config  # noqa: E402

STARTER = os.path.join(os.path.dirname(__file__), "..", "config", "starter.lua")

HAND_EDITED = '''local xr = require 'xr'

return {
  -- backdrop = { mode = "passthrough" },   -- an example I left commented out
  backdrop = {
    mode = "default",
    default = { preset = "cafe", dim = 0.2 },   -- I like it dim
  },
  font = { size_dmm = 24 },
}
'''


def evaluated(text):
    """Run the edited file through the real Lua evaluator."""
    d = tempfile.mkdtemp()
    p = os.path.join(d, "config.lua")
    with open(p, "w") as f:
        f.write(text)
    cfg, warnings = config.evaluate(p)
    return cfg, warnings


class TestSetBackdrop(unittest.TestCase):
    """The file belongs to the user: change the named keys, touch nothing else."""

    def test_starter_gains_a_working_backdrop_block(self):
        with open(STARTER) as f:
            starter = f.read()
        out = confedit.set_backdrop(starter, "default", preset="cafe")
        cfg, warnings = evaluated(out)
        self.assertEqual(warnings, [])
        self.assertEqual(cfg["backdrop"]["mode"], "default")
        self.assertEqual(cfg["backdrop"]["default"]["preset"], "cafe")

    def test_existing_keys_are_replaced_in_place(self):
        out = confedit.set_backdrop(HAND_EDITED, "default", preset="nebula")
        cfg, _ = evaluated(out)
        self.assertEqual(cfg["backdrop"]["default"]["preset"], "nebula")
        # The neighbours survive: same table, same sibling key, same comment.
        self.assertEqual(cfg["backdrop"]["default"]["dim"], 0.2)
        self.assertEqual(cfg["font"]["size_dmm"], 24)
        self.assertIn("I like it dim", out)
        self.assertIn("an example I left commented out", out)

    def test_a_commented_out_block_is_not_mistaken_for_the_real_one(self):
        out = confedit.set_backdrop(HAND_EDITED, "passthrough")
        cfg, _ = evaluated(out)
        self.assertEqual(cfg["backdrop"]["mode"], "passthrough")
        # The commented line is still a comment, still says passthrough, and the
        # real block is the one that changed.
        self.assertIn('-- backdrop = { mode = "passthrough" },', out)

    def test_custom_mode_writes_the_glb_path(self):
        out = confedit.set_backdrop(HAND_EDITED, "custom", glb="/rooms/my loft.glb")
        cfg, _ = evaluated(out)
        self.assertEqual(cfg["backdrop"]["mode"], "custom")
        self.assertEqual(cfg["backdrop"]["custom"]["glb"], "/rooms/my loft.glb")
        self.assertEqual(cfg["backdrop"]["default"]["dim"], 0.2)

    def test_quotes_and_backslashes_in_a_path_survive(self):
        weird = '/rooms/it\'s "mine"\\here.glb'
        out = confedit.set_backdrop(HAND_EDITED, "custom", glb=weird)
        cfg, _ = evaluated(out)
        self.assertEqual(cfg["backdrop"]["custom"]["glb"], weird)

    def test_running_twice_is_the_same_as_running_once(self):
        once = confedit.set_backdrop(HAND_EDITED, "default", preset="void")
        twice = confedit.set_backdrop(once, "default", preset="void")
        self.assertEqual(once, twice)

    def test_a_brace_inside_a_string_does_not_end_the_block(self):
        text = '''return {
  sessions = { exclude = { "weird}name" } },
  backdrop = { mode = "default" },
}
'''
        out = confedit.set_backdrop(text, "passthrough")
        cfg, _ = evaluated(out)
        self.assertEqual(cfg["backdrop"]["mode"], "passthrough")
        self.assertEqual(cfg["sessions"]["exclude"], ["weird}name"])


if __name__ == "__main__":
    unittest.main()
