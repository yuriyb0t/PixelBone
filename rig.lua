-- Rig model. Pure Lua (no Aseprite API) so it can be tested with any interpreter.
--
-- Coordinates are in sprite pixels (floats). Pixel centers are at n + 0.5.
-- A bone is a segment head(ax,ay) -> tail(bx,by) with a radius at each end
-- (ra at the head, rb at the tail) used to build the skin.
--   parent    : id of the parent bone, 0 = root
--   connected : head follows the parent's tail (and shares its radius)
--   mirrorOf  : id of the mirrored twin, 0 = none
--   group     : id of the skin group the bone is drawn in, 0 = helper (not drawn)

local Rig = {}
Rig.__index = Rig

local function copy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = copy(v) end
  return r
end

-- Keys in JSON objects must be strings, so ids/frames are formatted as "%d".
local function fk(n) return string.format("%d", n) end

local function newAnim(id, name)
  return { id = id, name = name, frames = 8, fps = 12, interp = "linear", keys = {} }
end

local PALETTE = {
  { r = 205, g = 160, b = 130 }, { r = 120, g = 170, b = 220 }, { r = 150, g = 200, b = 120 },
  { r = 225, g = 190, b = 100 }, { r = 200, g = 130, b = 190 }, { r = 130, g = 200, b = 200 },
}

function Rig.new(axisX)
  return setmetatable({
    version = 2,
    rev = 0,
    nextId = 1,
    bones = {},
    mirror = { enabled = false, axisX = axisX or 0 },
    groups = { { id = 1, name = "Body", color = copy(PALETTE[1]) } },
    nextGroupId = 2,
    activeGroup = 1,
    defaultRadius = 2,
    outline = "pixel",                       -- "none" | "pixel"
    outlineColor = { r = 24, g = 18, b = 28 },
    anims = { newAnim(1, "Anim 1") },
    nextAnimId = 2,
    activeAnim = 1,
  }, Rig)
end

-- Bump the revision counter; the UI re-renders the skin when it changes.
function Rig:touch()
  self.rev = (self.rev or 0) + 1
end

function Rig:toTable()
  return copy({
    version = self.version, nextId = self.nextId, bones = self.bones, mirror = self.mirror,
    groups = self.groups, nextGroupId = self.nextGroupId, activeGroup = self.activeGroup,
    defaultRadius = self.defaultRadius, outline = self.outline, outlineColor = self.outlineColor,
    anims = self.anims, nextAnimId = self.nextAnimId, activeAnim = self.activeAnim,
  })
end

function Rig.fromTable(t)
  local r = Rig.new(0)
  r.mirror = {
    enabled = (t.mirror and t.mirror.enabled) and true or false,
    axisX = (t.mirror and t.mirror.axisX) or 0,
  }
  r.defaultRadius = t.defaultRadius or 2
  r.outline = t.outline or "pixel"
  if type(t.outlineColor) == "table" then
    r.outlineColor = {
      r = t.outlineColor.r or 24, g = t.outlineColor.g or 18, b = t.outlineColor.b or 28,
    }
  end

  -- groups (rigs saved by 0.1.x have none)
  local maxGid = 0
  local groups = {}
  for _, g in ipairs(t.groups or {}) do
    groups[#groups + 1] = {
      id = g.id,
      name = g.name or ("Group " .. tostring(g.id)),
      color = {
        r = (g.color and g.color.r) or 200, g = (g.color and g.color.g) or 200, b = (g.color and g.color.b) or 200,
      },
    }
    if g.id > maxGid then maxGid = g.id end
  end
  if #groups > 0 then r.groups = groups end
  if #groups == 0 then maxGid = 1 end
  r.nextGroupId = math.max(t.nextGroupId or 1, maxGid + 1)
  r.activeGroup = r:getGroup(t.activeGroup or -1) and t.activeGroup or r.groups[1].id

  -- animations (rigs saved by 0.1.x / 0.2.x have none)
  local anims, maxAid = {}, 0
  for _, a in ipairs(t.anims or {}) do
    anims[#anims + 1] = {
      id = a.id, name = a.name or ("Anim " .. tostring(a.id)),
      frames = a.frames or 8, fps = a.fps or 12, interp = a.interp or "linear",
      keys = copy(a.keys or {}),
    }
    if a.id > maxAid then maxAid = a.id end
  end
  if #anims > 0 then r.anims = anims else maxAid = 1 end
  r.nextAnimId = math.max(t.nextAnimId or 1, maxAid + 1)
  r.activeAnim = r:getAnim(t.activeAnim or -1) and t.activeAnim or r.anims[1].id

  local maxId = 0
  for _, b in ipairs(t.bones or {}) do
    local nb = {
      id = b.id,
      name = b.name or ("bone" .. tostring(b.id)),
      parent = b.parent or 0,
      connected = b.connected and true or false,
      ax = b.ax or 0, ay = b.ay or 0, bx = b.bx or 0, by = b.by or 0,
      ra = b.ra or r.defaultRadius, rb = b.rb or r.defaultRadius,
      group = b.group or r.groups[1].id,
      mirrorOf = b.mirrorOf or 0,
    }
    r.bones[#r.bones + 1] = nb
    if nb.id > maxId then maxId = nb.id end
  end
  r.nextId = math.max(t.nextId or 1, maxId + 1)
  return r
end

-- Undo support: snapshots hold bones, groups and counters
-- (mirror settings, outline and default radius are not undone).
function Rig:snapshot()
  return copy({
    nextId = self.nextId, bones = self.bones,
    groups = self.groups, nextGroupId = self.nextGroupId, activeGroup = self.activeGroup,
    anims = self.anims, nextAnimId = self.nextAnimId, activeAnim = self.activeAnim,
  })
end

function Rig:restore(s)
  self.nextId = s.nextId
  self.bones = copy(s.bones)
  self.groups = copy(s.groups)
  self.nextGroupId = s.nextGroupId
  self.activeGroup = s.activeGroup
  self.anims = copy(s.anims)
  self.nextAnimId = s.nextAnimId
  self.activeAnim = s.activeAnim
  self:touch()
end

-- Lookup -------------------------------------------------------------------

function Rig:get(id)
  for i, b in ipairs(self.bones) do
    if b.id == id then return b, i end
  end
  return nil
end

function Rig:twin(b)
  if b.mirrorOf and b.mirrorOf ~= 0 then return self:get(b.mirrorOf) end
  return nil
end

function Rig:mx(x)
  return 2 * self.mirror.axisX - x
end

function Rig:isDescendant(id, ancestorId)
  local guard = 0
  local cur = self:get(id)
  while cur and guard < 10000 do
    if cur.parent == ancestorId then return true end
    cur = self:get(cur.parent)
    guard = guard + 1
  end
  return false
end

-- Names --------------------------------------------------------------------

local SIDES = { { "Left", "Right" }, { "left", "right" }, { "_L", "_R" }, { ".L", ".R" }, { "_l", "_r" } }

function Rig.swapSide(name)
  for _, p in ipairs(SIDES) do
    local a, b = p[1], p[2]
    local s, e = name:find(a, 1, true)
    if s then return name:sub(1, s - 1) .. b .. name:sub(e + 1) end
    s, e = name:find(b, 1, true)
    if s then return name:sub(1, s - 1) .. a .. name:sub(e + 1) end
  end
  return name .. "_m"
end

function Rig:rename(b, name, skipMirror)
  b.name = name
  if self.mirror.enabled and not skipMirror then
    local t = self:twin(b)
    if t then self:rename(t, Rig.swapSide(name), true) end
  end
end

-- Creation -----------------------------------------------------------------

local function newBone(self, ax, ay, bx, by, parent, connected, name)
  local id = self.nextId
  self.nextId = id + 1
  local p = (parent and parent ~= 0) and self:get(parent) or nil
  local conn = (connected and p) and true or false
  local b = {
    id = id,
    name = name or ("bone" .. id),
    parent = parent or 0,
    connected = conn,
    ax = ax, ay = ay, bx = bx, by = by,
    ra = conn and p.rb or self.defaultRadius,
    rb = self.defaultRadius,
    group = self.activeGroup or 0,
    mirrorOf = 0,
  }
  self.bones[#self.bones + 1] = b
  return b
end

-- Returns bone, twin (twin is nil unless mirror is on and the bone is off-axis).
function Rig:addBone(ax, ay, bx, by, parentId, connected, name)
  local b = newBone(self, ax, ay, bx, by, parentId, connected, name)
  local twin
  if self.mirror.enabled then
    local axis = self.mirror.axisX
    local onAxis = math.abs(ax - axis) < 0.01 and math.abs(bx - axis) < 0.01
    if not onAxis then
      local tp = 0
      local parent = parentId and parentId ~= 0 and self:get(parentId) or nil
      if parent then
        local pt = self:twin(parent)
        tp = pt and pt.id or parent.id
      end
      twin = newBone(self, self:mx(ax), ay, self:mx(bx), by, tp, connected, Rig.swapSide(b.name))
      b.mirrorOf, twin.mirrorOf = twin.id, b.id
    end
  end
  self:touch()
  return b, twin
end

-- Editing ------------------------------------------------------------------

-- Move one endpoint. A connected head moves the parent's tail instead, and a
-- tail drags the heads of its connected children along.
function Rig:setPoint(b, which, x, y, skipMirror)
  if which == "head" then
    if b.connected and b.parent ~= 0 then
      local p = self:get(b.parent)
      if p then return self:setPoint(p, "tail", x, y, skipMirror) end
    end
    b.ax, b.ay = x, y
  else
    b.bx, b.by = x, y
    for _, c in ipairs(self.bones) do
      if c.parent == b.id and c.connected then c.ax, c.ay = x, y end
    end
  end
  if self.mirror.enabled and not skipMirror then
    local t = self:twin(b)
    if t then self:setPoint(t, which, self:mx(x), y, true) end
  end
  self:touch()
end

-- Joint radius. Same joint logic as setPoint: a connected head edits the
-- parent's tail, and a tail sets the head radius of its connected children.
function Rig:setRadius(b, which, r, skipMirror)
  r = math.max(0, r)
  if which == "head" then
    if b.connected and b.parent ~= 0 then
      local p = self:get(b.parent)
      if p then return self:setRadius(p, "tail", r, skipMirror) end
    end
    b.ra = r
  else
    b.rb = r
    for _, c in ipairs(self.bones) do
      if c.parent == b.id and c.connected then c.ra = r end
    end
  end
  if self.mirror.enabled and not skipMirror then
    local t = self:twin(b)
    if t then self:setRadius(t, which, r, true) end
  end
  self:touch()
end

local function translateSubtree(self, b, dx, dy)
  b.ax, b.ay, b.bx, b.by = b.ax + dx, b.ay + dy, b.bx + dx, b.by + dy
  for _, c in ipairs(self.bones) do
    if c.parent == b.id then translateSubtree(self, c, dx, dy) end
  end
end

-- Move a whole bone and everything below it. The bone is detached from its
-- parent's tail (connected = false) because it no longer sits there.
function Rig:translate(b, dx, dy, skipMirror)
  b.connected = false
  translateSubtree(self, b, dx, dy)
  if self.mirror.enabled and not skipMirror then
    local t = self:twin(b)
    if t then self:translate(t, -dx, dy, true) end
  end
  self:touch()
end

function Rig:setParent(b, pid, connected, skipMirror)
  if pid == b.id then return false end
  if pid ~= 0 and self:isDescendant(pid, b.id) then return false end
  local p = pid ~= 0 and self:get(pid) or nil
  if pid ~= 0 and not p then return false end
  b.parent = pid
  b.connected = (connected and p) and true or false
  if b.connected then
    b.ax, b.ay = p.bx, p.by
    b.ra = p.rb
  end
  if self.mirror.enabled and not skipMirror then
    local t = self:twin(b)
    if t then
      local pt = p and self:twin(p) or nil
      local tpid = pid == 0 and 0 or (pt and pt.id or pid)
      self:setParent(t, tpid, connected, true)
    end
  end
  self:touch()
  return true
end

function Rig:setConnected(b, flag, skipMirror)
  if b.parent == 0 then return end
  local p = self:get(b.parent)
  if not p then return end
  b.connected = flag and true or false
  if b.connected then
    b.ax, b.ay = p.bx, p.by
    b.ra = p.rb
  end
  if self.mirror.enabled and not skipMirror then
    local t = self:twin(b)
    if t then self:setConnected(t, flag, true) end
  end
  self:touch()
end

-- Deletes the bone; its children are re-parented to the bone's parent
-- (detached). With mirror on, the twin is deleted too.
function Rig:delete(b, skipMirror)
  local t = (self.mirror.enabled and not skipMirror) and self:twin(b) or nil
  for _, c in ipairs(self.bones) do
    if c.parent == b.id then
      c.parent = b.parent
      c.connected = false
    end
  end
  local _, idx = self:get(b.id)
  if idx then table.remove(self.bones, idx) end
  for _, o in ipairs(self.bones) do
    if o.mirrorOf == b.id then o.mirrorOf = 0 end
  end
  for _, a in ipairs(self.anims) do a.keys[fk(b.id)] = nil end
  if t then self:delete(t, true) end
  self:touch()
end

-- Pair up bones of a hand-built rig that mirror each other across the axis.
-- Returns the number of pairs linked.
function Rig:symmetrize(eps)
  eps = eps or 1.5
  local linked = 0
  for _, a in ipairs(self.bones) do
    if a.mirrorOf == 0 then
      for _, b in ipairs(self.bones) do
        if b.id ~= a.id and b.mirrorOf == 0
          and math.abs(self:mx(a.ax) - b.ax) <= eps and math.abs(a.ay - b.ay) <= eps
          and math.abs(self:mx(a.bx) - b.bx) <= eps and math.abs(a.by - b.by) <= eps then
          a.mirrorOf, b.mirrorOf = b.id, a.id
          linked = linked + 1
          break
        end
      end
    end
  end
  return linked
end

-- Groups -------------------------------------------------------------------

function Rig:getGroup(id)
  for i, g in ipairs(self.groups) do
    if g.id == id then return g, i end
  end
  return nil
end

function Rig:groupByName(name)
  for _, g in ipairs(self.groups) do
    if g.name == name then return g end
  end
  return nil
end

local function uniqueGroupName(self, name, ignoreId)
  local base, n, candidate = name, 1, name
  while true do
    local clash = self:groupByName(candidate)
    if not clash or clash.id == ignoreId then return candidate end
    n = n + 1
    candidate = base .. " " .. n
  end
end

-- Creates a group and makes it the active one (new bones are drawn into it).
function Rig:addGroup(name)
  local id = self.nextGroupId
  self.nextGroupId = id + 1
  local g = {
    id = id,
    name = uniqueGroupName(self, name or ("Group " .. id)),
    color = copy(PALETTE[((id - 1) % #PALETTE) + 1]),
  }
  self.groups[#self.groups + 1] = g
  self.activeGroup = id
  self:touch()
  return g
end

function Rig:renameGroup(id, name)
  local g = self:getGroup(id)
  if not g or name == "" then return nil end
  g.name = uniqueGroupName(self, name, id)
  self:touch()
  return g.name
end

-- Refuses to delete the last remaining group. Bones in it become helpers.
function Rig:deleteGroup(id)
  if #self.groups <= 1 then return false end
  local _, idx = self:getGroup(id)
  if not idx then return false end
  table.remove(self.groups, idx)
  for _, b in ipairs(self.bones) do
    if b.group == id then b.group = 0 end
  end
  if self.activeGroup == id then self.activeGroup = self.groups[1].id end
  self:touch()
  return true
end

function Rig:assignGroup(b, gid, withChildren, skipMirror)
  b.group = gid
  if withChildren then
    for _, c in ipairs(self.bones) do
      if c.parent == b.id then self:assignGroup(c, gid, true, true) end
    end
  end
  if self.mirror.enabled and not skipMirror then
    local t = self:twin(b)
    if t then self:assignGroup(t, gid, withChildren, true) end
  end
  self:touch()
end

-- Animation ----------------------------------------------------------------
-- Each animation stores keys per bone and frame: keys["<boneId>"]["<frame>"] =
-- { rot = degrees, dx = pixels, dy = pixels }. rot rotates the bone around its
-- head (relative to its parent); dx/dy only matter for root bones and move the
-- whole character. Between keys values are interpolated ("linear" or "step").

function Rig:getAnim(id)
  for i, a in ipairs(self.anims) do
    if a.id == id then return a, i end
  end
  return nil
end

function Rig:currentAnim()
  return self:getAnim(self.activeAnim) or self.anims[1]
end

local function uniqueAnimName(self, name, ignoreId)
  local n, candidate = 1, name
  while true do
    local clash
    for _, a in ipairs(self.anims) do
      if a.name == candidate and a.id ~= ignoreId then clash = a end
    end
    if not clash then return candidate end
    n = n + 1
    candidate = name .. " " .. n
  end
end

function Rig:addAnim(name)
  local id = self.nextAnimId
  self.nextAnimId = id + 1
  local a = newAnim(id, uniqueAnimName(self, name or ("Anim " .. id)))
  self.anims[#self.anims + 1] = a
  self.activeAnim = id
  self:touch()
  return a
end

function Rig:renameAnim(id, name)
  local a = self:getAnim(id)
  if not a or name == "" then return nil end
  a.name = uniqueAnimName(self, name, id)
  self:touch()
  return a.name
end

-- Refuses to delete the last animation.
function Rig:deleteAnim(id)
  if #self.anims <= 1 then return false end
  local _, idx = self:getAnim(id)
  if not idx then return false end
  table.remove(self.anims, idx)
  if self.activeAnim == id then self.activeAnim = self.anims[1].id end
  self:touch()
  return true
end

local function sortedFrames(bk)
  local fs = {}
  for k in pairs(bk) do fs[#fs + 1] = tonumber(k) end
  table.sort(fs)
  return fs
end

-- Interpolated channels (rot, dx, dy) of a bone at a frame.
function Rig:channels(anim, boneId, frame)
  local bk = anim.keys[fk(boneId)]
  if not bk then return 0, 0, 0 end
  local fs = sortedFrames(bk)
  if #fs == 0 then return 0, 0, 0 end
  local function val(f)
    local k = bk[fk(f)]
    return k.rot or 0, k.dx or 0, k.dy or 0
  end
  if frame <= fs[1] then return val(fs[1]) end
  if frame >= fs[#fs] then return val(fs[#fs]) end
  local prev, nxt
  for i = 1, #fs - 1 do
    if frame >= fs[i] and frame < fs[i + 1] then
      prev, nxt = fs[i], fs[i + 1]
      break
    end
  end
  local r1, x1, y1 = val(prev)
  if anim.interp == "step" then return r1, x1, y1 end
  local r2, x2, y2 = val(nxt)
  local t = (frame - prev) / (nxt - prev)
  return r1 + (r2 - r1) * t, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t
end

-- Set a key. Channels left nil keep their current (interpolated) value.
function Rig:setKey(anim, boneId, frame, rot, dx, dy)
  local r0, x0, y0 = self:channels(anim, boneId, frame)
  local bk = anim.keys[fk(boneId)]
  if not bk then
    bk = {}
    anim.keys[fk(boneId)] = bk
  end
  bk[fk(frame)] = { rot = rot or r0, dx = dx or x0, dy = dy or y0 }
  self:touch()
end

function Rig:hasKey(anim, boneId, frame)
  local bk = anim.keys[fk(boneId)]
  return bk ~= nil and bk[fk(frame)] ~= nil
end

function Rig:deleteKey(anim, boneId, frame)
  local bk = anim.keys[fk(boneId)]
  if bk and bk[fk(frame)] then
    bk[fk(frame)] = nil
    if next(bk) == nil then anim.keys[fk(boneId)] = nil end
    self:touch()
    return true
  end
  return false
end

function Rig:rootOf(b)
  local cur, guard = b, 0
  while cur.parent ~= 0 and guard < 10000 do
    local p = self:get(cur.parent)
    if not p then break end
    cur = p
    guard = guard + 1
  end
  return cur
end

-- 2D rigid transforms: point' = [c -s; s c] * point + (tx, ty)
local function compose(a, b)
  return {
    c = a.c * b.c - a.s * b.s,
    s = a.s * b.c + a.c * b.s,
    tx = a.c * b.tx - a.s * b.ty + a.tx,
    ty = a.s * b.tx + a.c * b.ty + a.ty,
  }
end

local function apply(t, x, y)
  return t.c * x - t.s * y + t.tx, t.s * x + t.c * y + t.ty
end

-- Posed copy of every bone (same order as self.bones) at a frame, plus the
-- transform of each bone by id. Forward kinematics: a bone rotates around its
-- own rest-pose head, then everything is carried by its parent's transform.
function Rig:pose(anim, frame)
  local T = {}
  local function xf(b, depth)
    if T[b.id] then return T[b.id] end
    local rot, dx, dy = 0, 0, 0
    if anim then rot, dx, dy = self:channels(anim, b.id, frame) end
    local th = math.rad(rot)
    local c, s = math.cos(th), math.sin(th)
    local rt = { c = c, s = s, tx = b.ax - (c * b.ax - s * b.ay), ty = b.ay - (s * b.ax + c * b.ay) }
    local parent = (b.parent ~= 0) and self:get(b.parent) or nil
    local t
    if parent and depth < 256 then
      t = compose(xf(parent, depth + 1), rt)
    else
      t = compose({ c = 1, s = 0, tx = dx, ty = dy }, rt)
    end
    T[b.id] = t
    return t
  end
  local out = {}
  for i, b in ipairs(self.bones) do
    local t = xf(b, 0)
    local nb = copy(b)
    nb.ax, nb.ay = apply(t, b.ax, b.ay)
    nb.bx, nb.by = apply(t, b.bx, b.by)
    out[i] = nb
  end
  return out, T
end

-- Hit testing --------------------------------------------------------------

local function segDist(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  local t = 0
  if l2 > 0 then
    t = ((px - ax) * dx + (py - ay) * dy) / l2
    t = math.max(0, math.min(1, t))
  end
  local cx, cy = ax + t * dx, ay + t * dy
  return math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
end

-- Returns bone, part ("head" | "tail" | "body") or nil. Endpoints win over bodies.
function Rig:hit(x, y, tol, bones)
  local list = bones or self.bones
  local best, part, bestD
  for i = #list, 1, -1 do
    local b = list[i]
    local dt = math.sqrt((x - b.bx) ^ 2 + (y - b.by) ^ 2)
    if dt <= tol and (not bestD or dt < bestD) then best, part, bestD = b, "tail", dt end
    local dh = math.sqrt((x - b.ax) ^ 2 + (y - b.ay) ^ 2)
    if dh <= tol and (not bestD or dh < bestD) then best, part, bestD = b, "head", dh end
  end
  if best then return best, part end
  for i = #list, 1, -1 do
    local b = list[i]
    local d = segDist(x, y, b.ax, b.ay, b.bx, b.by)
    if d <= tol * 0.7 and (not bestD or d < bestD) then best, part, bestD = b, "body", d end
  end
  return best, part
end

return Rig
