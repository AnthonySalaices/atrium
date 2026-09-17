-- Glasshouse — baseline design.
--
-- This file IS the documentation. Copy any block you want to change into your
-- own config and override just that key:
--
--     ~/.config/glasshouse/config.lua
--
--     local xr = require 'xr'
--     return {
--       backdrop = { mode = "passthrough" },
--       glass    = { tint = xr.hex("#0b1220"), opacity = 0.34 },
--     }
--
-- Your config is merged OVER these defaults, so you only write what differs.
-- It is evaluated on the host running glassd, not in the headset, and re-read the
-- moment you save — panels restyle live, no rebuild, no reinstall.
--
-- Units: text sizes are in **dmm** (1 dmm = 1 milliradian = 0.0573 deg). dmm is
-- angular, so text stays the same apparent size no matter how far away or how
-- large you make a panel. Distances and panel sizes are in metres.

local xr = require 'xr'

return {

  ----------------------------------------------------------------------------
  -- BACKDROP — what you see behind the windows.
  ----------------------------------------------------------------------------
  backdrop = {
    -- "passthrough" : your real room, via the headset cameras. Your keyboard
    --                 and coffee stay visible. Best default for desk work, and
    --                 glass reads as glass because there is real depth behind it.
    -- "default"     : the shipped room (an Astra-built GLB).
    -- "custom"      : your own .glb — see backdrop.custom below.
    mode = "default",

    default = {
      preset = "cafe",        -- "cafe"   = a cartoon coffee shop with other people
                              --            quietly working (baked, lightly animated).
                              --            The social pressure of a café, none of
                              --            the commute.
                              -- "nebula" = the procedural animated sky that shipped
                              --            first. Not a real place, on purpose.
                              -- "void"   = flat dark.
      lighting = "baked",     -- "baked" is much cheaper on a Quest; "realtime" if you must
      dim = 0.0,              -- 0..1, darken the backdrop to make the glass pop
    },

    custom = {
      glb = xr.unset,         -- absolute path to your .glb, served from the host
      scale = 1.0,
      yaw_deg = 0.0,          -- rotate the room so its "front" faces you
      origin = { 0.0, 0.0, 0.0 },
      -- ⚠️ Composition layers do not depth-sort against scene geometry, so a
      -- custom room MUST leave a clear cylinder in front of you or geometry
      -- will appear to punch through your panels. Enforced, not advisory:
      clear_radius_m = 2.0,
    },

    passthrough = {
      -- A real passthrough window cut into an otherwise opaque room, so you can
      -- see the desk and keyboard without leaving the room. Ignored when
      -- mode == "passthrough" (then everything is already passthrough).
      desk_window = true,
      desk_window_size_m = { 1.2, 0.6 },
      desk_window_pitch_deg = -35,
    },
  },

  ----------------------------------------------------------------------------
  -- GLASS — the window material. This is the Liquid Glass look, and it applies
  -- to the panels only, never to the backdrop.
  ----------------------------------------------------------------------------
  glass = {
    tint = xr.hex("#0d1117"),   -- the colour the glass is made of
    opacity = 0.38,             -- 0 = invisible, 1 = solid. Lower needs a busier backdrop.
    blur = 0.55,                -- how much the backdrop smears behind the glass
    saturation = 1.12,          -- backdrop saturation through the glass; >1 = livelier

    edge = {
      width_mm = 2.2,           -- the bright rim that gives glass its thickness
      opacity = 0.42,
      color = xr.hex("#ffffff"),
      specular = 0.6,           -- how much the rim catches the light as you move
    },

    corner_radius_mm = 18,
    inner_shadow = 0.25,        -- darkening just inside the rim; sells thickness
    drop_shadow = {
      enabled = true,
      opacity = 0.35,
      offset_m = 0.012,         -- how far the panel floats off the backdrop
      softness = 0.6,
    },

    -- ⚠️ Text is drawn on an OpenXR composition layer for sharpness, and those
    -- do not blend with the 3D scene. So the glass frame is in-scene geometry
    -- and the text is inset inside it. This is the gap between the frame's
    -- inner edge and the first text cell.
    text_inset_mm = 14,
  },

  ----------------------------------------------------------------------------
  -- PANELS — geometry. See the legibility note at the bottom before raising
  -- the column count.
  ----------------------------------------------------------------------------
  panels = {
    focus = {
      cols = 80, rows = 28,
      distance_m = 1.5,         -- clamped 1.2..2.5; Quest 3's focal plane is ~1.3-1.5 m
      pitch_deg = -10,          -- centre slightly below eye level; looking down is restful
      curve = true,             -- cylinder layer. Flat quads shrink glyphs at the edges.
      follow = "none",          -- "none" | "lazy" — lazy re-centres if you turn away
    },
    tile = {
      -- Tiles are for GLANCING, not reading. Name, state, and a couple of tail
      -- lines. Do not put a readable terminal in one; see the note below.
      cols = 20, rows = 5,
      distance_m = 1.8,
      arc_deg = 140,            -- spread tiles across this much of your view
      pitch_deg = -4,
      max = 7,                  -- hard cap; 1 focus + 7 tiles = 8 layers
    },
  },

  ----------------------------------------------------------------------------
  -- AMBIENCE — the room tone.
  ----------------------------------------------------------------------------
  ambience = {
    -- OFF by default, and it stays that way: silence is the right default for
    -- something you wear on your face. Turn it on and you get a coffee shop,
    -- entirely synthesised — no audio files ship with the app.
    enabled = false,
    volume = 0.10,       -- 0..1 master for every layer below. Room tone, not music.
                         -- Deliberately low: at 0.10 a keystroke sits near -37 dBFS
                         -- and the steam wand near -35. Try 0.3-0.5 if you want the
                         -- room clearly present; the layer volumes balance under it.

    -- A soft click for each keystroke you send to a pane. Pitch and length are
    -- randomised per key; identical clicks are what makes a fake keyboard sound
    -- fake. Keys the router refuses stay silent.
    typing = {
      enabled = true,
      volume = 0.35,     -- relative to ambience.volume
    },

    -- A barista steaming milk somewhere across the room: a few seconds of
    -- filtered noise, then a minute or three of nothing.
    steam = {
      enabled = true,
      volume = 0.50,
      every_min_s = 60,  -- clamped to 5..1800, and min <= max
      every_max_s = 180,
      length_min_s = 2,  -- clamped to 0.5..15
      length_max_s = 4,
    },

    -- "procedural" = a slow C major pad that never loops (the old drone, moved
    --   up an octave — the 55 Hz version read as "a scary hum")
    -- "folder"     = your own .ogg/.mp3, shuffled, one pass at a time
    -- "off"        = no music layer; typing and steam still work
    -- ⚠️ `dir` is a path on the DEVICE running the client — the headset, e.g.
    -- "/sdcard/Music" — not on the host that evaluates this file.
    music = {
      mode = "procedural",
      dir = "",
      volume = 0.50,
    },
  },

  ----------------------------------------------------------------------------
  -- FONT
  ----------------------------------------------------------------------------
  font = {
    family = "Iosevka Term Medium",   -- 0.5-em advance: ~20% more columns per degree
    size_dmm = 22.3,                  -- floor is 18 and it is enforced, not advisory
    line_height = 1.25,
    weight = "medium",
  },

  ----------------------------------------------------------------------------
  -- GLOW — the point of the whole thing. Expressed in the glass language:
  -- the window's own edge lights up, rather than a border being bolted on.
  ----------------------------------------------------------------------------
  glow = {
    states = {
      idle        = { edge = xr.hex("#ffffff"), intensity = 0.12 },
      working     = { edge = xr.hex("#4c8dff"), intensity = 0.22, pulse = "breathe" },
      -- "breathe": the amber edge slowly swells and settles (0.5 Hz, never dark).
      -- Set "none" if motion in your periphery bothers you.
      needs_input = { edge = xr.hex("#ffb74a"), intensity = 1.00, pulse = "breathe", spill = true },
      error       = { edge = xr.hex("#ff5c5c"), intensity = 0.95, pulse = "none", spill = true },
      done        = { edge = xr.hex("#5ad19b"), intensity = 0.55 },
    },

    -- Guessed states render dimmer than ones a hook told us about, so a
    -- heuristic never shouts as loudly as a fact.
    heuristic_scale = 0.55,

    -- "spill" lets the glow bleed onto the backdrop. A composition layer cannot
    -- bloom into the scene, so this is a separate emissive quad behind the panel.
    spill_scale = 1.06,

    -- Escalation for a panel you are ignoring, outside your field of view.
    escalate = {
      after_s = 30,
      only_if_off_gaze_deg = 40,
      chevron = true,           -- a head-locked arrow pointing at the panel
      ping = "once",            -- "once" | "never" | "repeat"
      ping_volume = 0.4,
    },

    ack_on_focus = true,        -- looking at a panel clears its unread flag
  },

  ----------------------------------------------------------------------------
  -- SESSIONS — which tmux sessions become panels.
  ----------------------------------------------------------------------------
  sessions = {
    -- Glasshouse finds agents by what is RUNNING in a tmux pane (see `agents`
    -- below), not by session name. These are optional extra filters on the
    -- session name (regular expressions). Empty = no filter.
    include = {},
    exclude = {},
    order = "activity",           -- "activity" | "name" | "fixed"
    fixed = {},                   -- session names, in the order you want them
    title = "pane",               -- "pane" uses the agent's own summary line
    max_panels = 8,
    -- A watched window is normally resized to the headset's cols x rows, and a
    -- tmux window has ONE size for every attached client — so it shrinks on
    -- your desktop too. Sessions matching these patterns are never resized;
    -- the headset shows the bottom-left crop of the desktop-sized pane
    -- instead. Same as `glasshouse pin off` inside a session, but permanent.
    pin_exclude = {},             -- Python regexes, e.g. { "^cc-1$", "desk" }
  },

  ----------------------------------------------------------------------------
  -- AGENTS — which terminal programs count as an agent.
  --
  -- "Provider" is the wrong axis. Claude, GPT, DeepSeek, Qwen are models; what
  -- runs in your terminal is a HARNESS (Claude Code, Codex CLI, Gemini CLI,
  -- aider, OpenCode, …) and one harness can front several models. Glasshouse
  -- recognises harnesses by the process in the pane and never needs an API key.
  --
  -- Built in: claude-code, codex, gemini-cli, qwen-code, opencode, aider, crush,
  -- goose, amp, copilot, kiro, cursor-agent. Add or override here; the phrases
  -- are matched against the last 12 lines of the pane to guess "needs you" /
  -- "working" when the harness has no hooks. A wrong phrase costs a dim glow,
  -- nothing more — the scraper can never type into a pane.
  ----------------------------------------------------------------------------
  agents = {
    extra = {
      -- mytool = {
      --   name = "My Tool",
      --   match = { "mytool" },              -- process / script names to look for
      --   needs_input = { "Proceed? (y/n)" },
      --   working = { "thinking" },
      -- },
    },
  },

  ----------------------------------------------------------------------------
  -- KEYS
  ----------------------------------------------------------------------------
  keys = {
    next_panel   = "ctrl+alt+Right",
    prev_panel   = "ctrl+alt+Left",
    jump_to_glow = "ctrl+alt+Space",   -- go straight to whoever needs you
    recenter     = "ctrl+alt+r",
    toggle_backdrop = "ctrl+alt+b",    -- flip passthrough <-> room without a restart
    toggle_tiles = "ctrl+alt+t",
  },

  ----------------------------------------------------------------------------
  -- COMFORT / PERFORMANCE
  ----------------------------------------------------------------------------
  comfort = {
    refresh_hz = 72,            -- 72 | 90 | 120. Higher costs battery and heat.
    hand_tracking = true,
    typing_lockout_ms = 1500,   -- ignore pinches while you are typing, so resting
                                -- hands on the keyboard never grab a panel
    foveation = 2,              -- 0..4, fixed foveated rendering
  },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- ⚠️ THE LEGIBILITY CEILING — read before raising panels.focus.cols
--
-- A Quest 3 resolves about 25 pixels per degree. A comfortably readable
-- monospace column costs ~0.64 deg, which works out to 1.56 columns per degree.
-- The headset's entire 104 deg horizontal field therefore holds about 162
-- readable columns, TOTAL, forever. One 80-column terminal already eats half
-- your view.
--
-- That is why there is exactly one focus panel and the rest are tiles. You can
-- raise cols, or lower font.size_dmm to fit more in, but below 18 dmm text stops
-- being comfortable to read for hours, and that is the whole point of this.
-- ─────────────────────────────────────────────────────────────────────────────
