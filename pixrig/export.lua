-- Writes the skin into the sprite as a locked layer group named "PixRig".
-- Only that group is touched: it is deleted and rebuilt on every export, so
-- your own layers are never modified.

local Skin = require("pixrig.skin")
local Binding = require("pixrig.binding")

local E = {}
local GROUP_NAME = "PixRig"

-- Paint a sparse mask into a fresh RGBA image of the sprite's size.
function E.maskImage(mask, w, h, c)
  local img = Image(w, h)
  local px = app.pixelColor.rgba(c.r, c.g, c.b, 255)
  for idx in pairs(mask) do
    local i = idx - 1
    img:putPixel(i % w, i // w, px)
  end
  return img
end

-- Returns true, layerCount  or  false, message
function E.export(sprite, rig, frameNumber)
  if sprite.colorMode ~= ColorMode.RGB then
    return false, "Switch the sprite to RGB color mode first (Sprite > Color Mode)."
  end
  local w, h = sprite.width, sprite.height
  local res = Skin.render(rig, w, h)
  local count = 0

  local ok, err = pcall(function()
    app.transaction("PixRig export", function()
      for _, l in ipairs(sprite.layers) do
        if l.isGroup and l.name == GROUP_NAME then
          sprite:deleteLayer(l)
          break
        end
      end

      local group = sprite:newGroup()
      group.name = GROUP_NAME
      group.stackIndex = 1                      -- bottom of the stack

      local function addLayer(name, mask, color)
        if next(mask) == nil then return end
        local layer = sprite:newLayer()
        layer.name = name
        layer.parent = group
        sprite:newCel(layer, frameNumber, E.maskImage(mask, w, h, color), Point(0, 0))
        layer.isEditable = false
        count = count + 1
      end

      -- Created bottom to top: outline first, then groups in list order.
      if res.outline then addLayer("outline", res.outline, rig.outlineColor) end
      for _, g in ipairs(rig.groups) do
        addLayer(g.name, res.masks[g.id], g.color)
      end
      group.isEditable = false
    end)
  end)

  if not ok then return false, "Export failed: " .. tostring(err) end
  app.refresh()
  return true, count
end

-- Renders every frame of an animation into the "PixRig" layer group (one cel
-- per frame and layer), adds the missing frames to the sprite, sets the frame
-- duration from the animation's fps and tags the frame range with its name.
-- Returns true, layerCount  or  false, message
function E.exportAnimation(sprite, rig, anim)
  if sprite.colorMode ~= ColorMode.RGB then
    return false, "Switch the sprite to RGB color mode first (Sprite > Color Mode)."
  end
  local w, h = sprite.width, sprite.height
  local n = math.max(1, anim.frames)

  -- Render all frames first so only layers that have pixels are created.
  local artwork = Binding.prepare(sprite, rig)
  local results, used = {}, {}
  local artFrames = {}
  for f = 1, n do
    local posed, transforms = rig:pose(anim, f)
    artFrames[f] = Binding.render(artwork, transforms, w, h)
    local res = Skin.render(rig, w, h, posed)
    results[f] = res
    if res.outline and next(res.outline) ~= nil and next(artwork) == nil then used.outline = true end
    for gid, m in pairs(res.masks) do
      if next(m) ~= nil and not artwork[gid] then used[gid] = true end
    end
  end

  local count = 0
  local ok, err = pcall(function()
    app.transaction("PixRig export animation", function()
      for _, l in ipairs(sprite.layers) do
        if l.isGroup and l.name == GROUP_NAME then
          sprite:deleteLayer(l)
          break
        end
      end
      for _, t in ipairs(sprite.tags) do
        if t.name == anim.name then
          sprite:deleteTag(t)
          break
        end
      end

      while #sprite.frames < n do sprite:newEmptyFrame() end

      local group = sprite:newGroup()
      group.name = GROUP_NAME
      group.stackIndex = 1

      local function build(name, pick, color)
        local layer = sprite:newLayer()
        layer.name = name
        layer.parent = group
        for f = 1, n do
          local mask = pick(results[f])
          if mask and next(mask) ~= nil then
            sprite:newCel(layer, f, E.maskImage(mask, w, h, color), Point(0, 0))
          end
        end
        layer.isEditable = false
        count = count + 1
      end

      if used.outline then
        build("outline", function(r) return r.outline end, rig.outlineColor)
      end
      for _, g in ipairs(rig.groups) do
        if artwork[g.id] then
          local layer = sprite:newLayer()
          layer.name = g.name .. " [artwork]"
          layer.parent = group
          for f = 1, n do
            sprite:newCel(layer, f, artFrames[f][g.id], Point(0, 0))
          end
          layer.isEditable = false
          count = count + 1
        elseif used[g.id] then
          build(g.name, function(r) return r.masks[g.id] end, g.color)
        end
      end
      group.isEditable = false

      local dur = 1 / math.max(1, anim.fps)
      for f = 1, n do sprite.frames[f].duration = dur end
      local tag = sprite:newTag(1, n)
      tag.name = anim.name
    end)
  end)

  if not ok then return false, "Export failed: " .. tostring(err) end
  app.refresh()
  return true, count
end

return E
