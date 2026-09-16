-- Helpers available to user config via `local xr = require 'xr'`.
local xr = {}

local function clamp01(x) return x < 0 and 0 or (x > 1 and 1 or x) end

--- Colour from "#rgb", "#rrggbb" or "#rrggbbaa". Returns {r,g,b[,a]} in 0..1,
--- which is also what you get if you just write {0.1, 0.2, 0.3} yourself.
function xr.hex(s)
  local h = tostring(s):gsub("^#", "")
  if #h == 3 then h = h:sub(1,1):rep(2) .. h:sub(2,2):rep(2) .. h:sub(3,3):rep(2) end
  if #h ~= 6 and #h ~= 8 then
    error(("xr.hex: expected #rgb, #rrggbb or #rrggbbaa, got %q"):format(tostring(s)), 2)
  end
  local out = {}
  for i = 1, #h, 2 do
    out[#out+1] = clamp01(tonumber(h:sub(i, i+1), 16) / 255)
  end
  return out
end

--- Colour from 0..255 components.
function xr.rgb(r, g, b, a)
  local out = { clamp01(r/255), clamp01(g/255), clamp01(b/255) }
  if a then out[4] = clamp01(a/255) end
  return out
end

--- Degrees to dmm (milliradians), for anyone who thinks in degrees.
function xr.deg_to_dmm(d) return d * math.pi / 180 * 1000 end
function xr.dmm_to_deg(v) return v / 1000 * 180 / math.pi end

--- Merge tables left-to-right, for composing your own presets.
function xr.merge(...)
  local out = {}
  for _, t in ipairs({...}) do
    for k, v in pairs(t or {}) do out[k] = v end
  end
  return out
end

--- Marks a key that exists in the schema but has no value yet. Encodes to
--- JSON null, and keeps the key known so overriding it is not "unknown key".
xr.unset = { __unset = true }

xr.VERSION = "0.1"
return xr
