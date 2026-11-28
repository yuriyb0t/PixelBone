-- Paint Sheet v1: editable reference artwork generated from rest-pose capsules.
-- Separate from the locked PixRig export group. Never overwrites existing art.
local Skin = require("pixrig.skin")
local Export = require("pixrig.export")
local P = {}

function P.create(sprite, rig)
  if sprite.colorMode ~= ColorMode.RGB then
    return false, "Switch the sprite to RGB color mode first."
  end
  local w, h = sprite.width, sprite.height
  local result = Skin.render(rig, w, h)
  local hasPixels = false
  for _, g in ipairs(rig.groups) do
    if result.masks[g.id] and next(result.masks[g.id]) then hasPixels = true; break end
  end
  if not hasPixels then return false, "Assign bones to a Skin group first." end
  local existing = {}
  for _, layer in ipairs(sprite.layers) do existing[layer.name] = true end
  local name, n = "PixRig Paint Sheet", 2
  while existing[name] do name = "PixRig Paint Sheet " .. n; n = n + 1 end
  local count = 0
  local ok, err = pcall(function()
    app.transaction("PixRig create Paint Sheet", function()
      local sheet = sprite:newGroup()
      sheet.name = name
      -- Artwork layers are ordinary editable Aseprite layers.
      for _, g in ipairs(rig.groups) do
        local mask = result.masks[g.id]
        if mask and next(mask) then
          local layer = sprite:newLayer()
          layer.name = g.name .. " [bone group " .. tostring(g.id) .. "]"
          layer.parent = sheet
          sprite:newCel(layer, 1, Export.maskImage(mask, w, h, g.color), Point(0, 0))
          count = count + 1
        end
      end
    end)
  end)
  if not ok then return false, "Paint Sheet failed: " .. tostring(err) end
  app.refresh()
  return true, name .. " (" .. count .. " editable layers)"
end
-- Add a separate editable cel and bind all its pixels to the selected bone.
-- The layer name is the binding reference, no destructive pixel migration.
function P.addBoneLayer(sprite, rig, boneId, name)
  local Binding = require("pixrig.binding")
  local b = rig:get(boneId)
  if not b or b.group == 0 then return false, "Select a visible bone in a skin group." end
  if sprite.colorMode ~= ColorMode.RGB then return false, "RGB sprite required." end
  local sheet = Binding.activeSheet(sprite)
  if not sheet then return false, "Create a Paint Sheet first." end
  name = tostring(name or "Accessory"):gsub("%[bone[^%]]*%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then name = "Accessory" end
  local targetName = name .. " [bone " .. tostring(boneId) .. "]"
  local ok, err = pcall(function()
    app.transaction("PixelBone add artwork layer",function()
      local l = sprite:newLayer()
      l.name = targetName
      l.parent = sheet
      sprite:newCel(l,1,Image(sprite.width,sprite.height),Point(0,0))
      app.layer = l
      app.frame = 1
    end)
  end)
  if not ok then return false, tostring(err) end
  app.refresh()
  return true, targetName
end

return P
