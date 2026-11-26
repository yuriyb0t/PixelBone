-- Saves/loads the rig in sprite.data under the key "pixrig".
-- Existing JSON in sprite.data from other tools is preserved; non-JSON data
-- is never overwritten.

local json = require("pixrig.json")
local Rig = require("pixrig.rig")

local S = {}
local KEY = "pixrig"

-- Returns a table, or nil if sprite.data holds something we must not touch.
local function readBase(sprite)
  local s = sprite.data
  if s == nil or s == "" then return {} end
  local ok, t = pcall(json.decode, s)
  if ok and type(t) == "table" and #t == 0 then return t end
  return nil
end

function S.load(sprite)
  local base = readBase(sprite)
  if base and type(base[KEY]) == "table" then
    return Rig.fromTable(base[KEY])
  end
  return nil
end

function S.save(sprite, rig)
  local base = readBase(sprite)
  if base == nil then
    return false, "sprite.data holds data from another tool; not overwriting"
  end
  base[KEY] = rig:toTable()
  sprite.data = json.encode(base)
  return true
end

return S
