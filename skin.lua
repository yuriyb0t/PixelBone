-- Skin rasterizer. Pure Lua (no Aseprite API).
--
-- Every bone is a tapered capsule: radius ra at the head, rb at the tail,
-- linearly interpolated along the bone. A pixel belongs to a bone when its
-- center lies inside that capsule. Bones are drawn into their group's mask;
-- bones in group 0 are helpers and are skipped.
--
-- Masks are sparse tables keyed by (y * w + x + 1) = true.

local Skin = {}

-- `bones` (optional) overrides rig.bones, e.g. the posed bones of a frame.
-- Returns { masks = { [groupId] = mask }, all = mask, outline = mask|nil }
function Skin.render(rig, w, h, bones)
  local masks = {}
  for _, g in ipairs(rig.groups) do masks[g.id] = {} end
  local all = {}

  for _, b in ipairs(bones or rig.bones) do
    local m = masks[b.group]
    if m then
      local ax, ay, bx, by = b.ax, b.ay, b.bx, b.by
      local ra, rb = b.ra or 2, b.rb or 2
      local rmax = math.max(ra, rb)
      local x0 = math.max(0, math.floor(math.min(ax, bx) - rmax))
      local x1 = math.min(w - 1, math.ceil(math.max(ax, bx) + rmax))
      local y0 = math.max(0, math.floor(math.min(ay, by) - rmax))
      local y1 = math.min(h - 1, math.ceil(math.max(ay, by) + rmax))
      local dx, dy = bx - ax, by - ay
      local l2 = dx * dx + dy * dy
      for py = y0, y1 do
        local cy = py + 0.5
        for px = x0, x1 do
          local cx = px + 0.5
          local t = 0
          if l2 > 1e-9 then
            t = ((cx - ax) * dx + (cy - ay) * dy) / l2
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
          end
          local qx, qy = ax + t * dx, ay + t * dy
          local r = ra + (rb - ra) * t
          local ex, ey = cx - qx, cy - qy
          if ex * ex + ey * ey <= r * r then
            local idx = py * w + px + 1
            m[idx] = true
            all[idx] = true
          end
        end
      end
    end
  end

  local outline
  if rig.outline == "pixel" then
    outline = {}
    for idx in pairs(all) do
      local i = idx - 1
      local x, y = i % w, i // w
      local function mark(nx, ny)
        if nx >= 0 and nx < w and ny >= 0 and ny < h then
          local n = ny * w + nx + 1
          if not all[n] then outline[n] = true end
        end
      end
      mark(x - 1, y); mark(x + 1, y); mark(x, y - 1); mark(x, y + 1)
    end
  end

  return { masks = masks, all = all, outline = outline }
end

return Skin
