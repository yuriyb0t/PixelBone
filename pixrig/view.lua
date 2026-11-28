-- Viewport: maps sprite coordinates <-> canvas pixels.

local View = {}
View.__index = View

function View.new()
  return setmetatable({ zoom = 4, ox = 0, oy = 0 }, View)
end

function View:toScreen(x, y)
  return x * self.zoom + self.ox, y * self.zoom + self.oy
end

function View:toRig(sx, sy)
  return (sx - self.ox) / self.zoom, (sy - self.oy) / self.zoom
end

-- Fit a sprite of sw x sh into a canvas of cw x ch (integer zoom when possible).
function View:fit(cw, ch, sw, sh)
  local z = math.min((cw - 40) / sw, (ch - 40) / sh)
  if z >= 1 then z = math.floor(z) else z = math.max(0.25, z) end
  self.zoom = z
  self.ox = (cw - sw * z) / 2
  self.oy = (ch - sh * z) / 2
end

-- Zoom by `factor` keeping the sprite point under (sx, sy) fixed.
function View:zoomAt(sx, sy, factor)
  local old = self.zoom
  local new = math.max(0.25, math.min(64, old * factor))
  self.ox = sx - (sx - self.ox) * new / old
  self.oy = sy - (sy - self.oy) * new / old
  self.zoom = new
end

return View
