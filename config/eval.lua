-- Evaluate default config, merge the user's config over it, print JSON.
-- Run as: lua eval.lua <config_dir> <user_config_path|"">
-- Always prints one JSON object; never throws at the caller.

local config_dir, user_path = ...
package.path = config_dir .. "/?.lua;" .. package.path

local warnings = {}

-- ── deep merge ──────────────────────────────────────────────────────────────
local function is_array(t)
  if type(t) ~= "table" then return false end
  if next(t) == nil then return true end          -- empty table encodes as []
  return t[1] ~= nil
end

local function deep_merge(base, over, path)
  if type(base) == "table" and base.__unset then return over end
  if type(over) ~= "table" or type(base) ~= "table" then return over end
  -- An empty table is ambiguous in Lua: {} is both an empty list and an empty
  -- map. Over a map it means "change nothing" (a config with everything
  -- commented out must not wipe the defaults); over a list it means "clear it".
  if next(over) == nil then
    if is_array(base) then return over end
    return base
  end
  if is_array(over) or is_array(base) then return over end   -- arrays replace wholesale
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  for k, v in pairs(over) do
    local p = path == "" and tostring(k) or (path .. "." .. tostring(k))
    if base[k] == nil then
      warnings[#warnings+1] = "unknown config key: " .. p
      out[k] = v
    else
      out[k] = deep_merge(base[k], v, p)
    end
  end
  return out
end

-- ── JSON encode ─────────────────────────────────────────────────────────────
local esc = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}
local function q(s)
  return '"' .. tostring(s):gsub('[%c"\\]', function(c)
    return esc[c] or string.format('\\u%04x', c:byte())
  end) .. '"'
end

local encode
function encode(v)
  local t = type(v)
  if v == nil then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.type(v) == "integer" then return tostring(v) end
    return string.format("%.6g", v)
  elseif t == "string" then return q(v)
  elseif t == "table" then
    if v.__unset then return "null" end
    if is_array(v) then
      local parts = {}
      for _, x in ipairs(v) do parts[#parts+1] = encode(x) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys+1] = tostring(k) end
    table.sort(keys)                       -- stable output, so diffs are readable
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts+1] = q(k) .. ":" .. encode(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"                            -- functions/userdata are not config
end

-- ── run ─────────────────────────────────────────────────────────────────────
local function fail(msg)
  io.write('{"ok":false,"error":' .. q(msg) .. '}')
  os.exit(0)                               -- a broken config is data, not a crash
end

local okd, defaults = pcall(dofile, config_dir .. "/default.lua")
if not okd then fail("default.lua failed: " .. tostring(defaults)) end
if type(defaults) ~= "table" then fail("default.lua did not return a table") end

local merged = defaults
if user_path and user_path ~= "" then
  local f = io.open(user_path, "r")
  if f then
    f:close()
    local chunk, lerr = loadfile(user_path)
    if not chunk then fail("config.lua: " .. tostring(lerr)) end
    local oku, user = pcall(chunk)
    if not oku then fail("config.lua: " .. tostring(user)) end
    if user ~= nil and type(user) ~= "table" then
      fail("config.lua must return a table (or nothing), got " .. type(user))
    end
    if user then merged = deep_merge(defaults, user, "") end
  end
end

io.write('{"ok":true,"warnings":' .. encode(warnings) .. ',"config":' .. encode(merged) .. '}')
