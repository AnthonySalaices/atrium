-- Atrium config. Edit and save — the headset restyles live, no rebuild.
-- Everything here is optional: whatever you leave out keeps the shipped default.
-- The full list of what you can set, with a comment on each key, is in
-- config/default.lua next to the daemon — copy any block from there and change it.

local xr = require 'xr'

return {
  -- What you see behind the windows: "passthrough" (your real room),
  -- "default" (a shipped scene: preset "cafe", "nebula" or "void"),
  -- or "custom" (your own .glb).
  -- backdrop = { mode = "passthrough" },
  -- backdrop = { mode = "default", default = { preset = "cafe", dim = 0.0 } },

  -- Text size is angular (dmm), so it holds at any panel distance. Floor is 18.
  -- font = { size_dmm = 22.3 },

  -- Colours use WezTerm's keys, so a `colors = {...}` block from your
  -- .wezterm.lua pastes straight in.
  -- color_scheme = "rose-pine-moon",

  -- Which tmux sessions to show. Atrium finds agents by what is running in
  -- a pane; these are optional name filters (regular expressions).
  -- sessions = { include = {}, exclude = { "scratch" } },

  -- A terminal program of yours that Atrium should treat as an agent.
  -- agents = { extra = { mytool = { match = { "mytool" }, needs_input = { "Proceed?" } } } },

  -- Room tone. Off by default until the café sound ships.
  -- ambience = { enabled = false },
}
