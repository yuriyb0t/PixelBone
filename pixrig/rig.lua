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
    iks = {},
    nextIkId = 1,
    assembly = {}, -- per-bone rest -> assembled offsets; not animation keys
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
    iks = self.iks, nextIkId = self.nextIkId, assembly = self.assembly,
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

  -- IK constraints (rigs saved before 0.6 have none)
  local iks, maxIk = {}, 0
  for _, k in ipairs(t.iks or {}) do
    if type(k.id) == "number" and type(k.tip) == "number" and type(k.target) == "number" then
      iks[#iks + 1] = {
        id = k.id, name = k.name or ("IK " .. tostring(k.id)),
        tip = k.tip, target = k.target,
        chain = k.chain or 2, influence = k.influence or 1,
        bend = (k.bend and k.bend < 0) and -1 or 1,
        enabled = k.enabled ~= false,
      }
      if k.id > maxIk then maxIk = k.id end
    end
  end
  r.iks = iks
  r.nextIkId = math.max(t.nextIkId or 1, maxIk + 1)

  -- Optional since 0.8: old projects load with an identity assembly.
  -- A missing bone or malformed entry never changes existing animation data.
  r.assembly = {}
  for id, v in pairs(t.assembly or {}) do
    if type(v) == "table" and tonumber(id) then
      r.assembly[fk(tonumber(id))] = {
        rot = tonumber(v.rot) or 0, dx = tonumber(v.dx) or 0, dy = tonumber(v.dy) or 0,
      }
    end
  end

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
    iks = self.iks, nextIkId = self.nextIkId, assembly = self.assembly,
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
  self.iks = copy(s.iks or {})
  self.nextIkId = s.nextIkId or 1
  self.assembly = copy(s.assembly or {})
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
  self.assembly[fk(b.id)] = nil
  for i = #(self.iks or {}), 1, -1 do
    local k = self.iks[i]
    if k.tip == b.id or k.target == b.id then table.remove(self.iks, i) end
  end
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

-- Assembly pose ------------------------------------------------------------
-- Independent offsets used to assemble a character from separated Paint Sheet
-- parts. Values are local to the same rest-pose coordinate system as the FK
-- animation channels, and are composed ADDITIVELY with frame-specific keys.
-- An empty assembly is the identity, exactly matching all pre-0.8 projects.
function Rig:assemblyChannels(boneId)
  local a = self.assembly[fk(boneId)]
  if not a then return 0, 0, 0 end
  return a.rot or 0, a.dx or 0, a.dy or 0
end

function Rig:setAssembly(boneId, rot, dx, dy, skipMirror)
  local bone = self:get(boneId)
  if not bone then return false end
  local r, x, y = self:assemblyChannels(boneId)
  if rot ~= nil then r = rot end
  if dx ~= nil then x = dx end
  if dy ~= nil then y = dy end
  local key = fk(boneId)
  if math.abs(r) < 1e-9 and math.abs(x) < 1e-9 and math.abs(y) < 1e-9 then
    self.assembly[key] = nil
  else
    self.assembly[key] = { rot = r, dx = x, dy = y }
  end
  if self.mirror.enabled and not skipMirror then
    local twin = self:twin(bone)
    if twin then self:setAssembly(twin.id, -r, -x, y, true) end
  end
  self:touch()
  return true
end

function Rig:resetAssembly(boneId)
  if boneId then
    return self:setAssembly(boneId, 0, 0, 0)
  end
  self.assembly = {}
  self:touch()
  return true
end

function Rig:assembledPose()
  -- Disable IK in this non-animated assembly editing mode.
  return self:pose(nil, 1, true)
end

-- Animation ----------------------------------------------------------------
-- Each animation stores keys per bone and frame: keys["<boneId>"]["<frame>"] =
-- { rot = degrees, dx = pixels, dy = pixels }. rot rotates the bone around its
-- head (relative to its parent); dx/dy offset the bone (and its children) in its
-- parent's frame; on a root bone they move the whole character. Between keys values are interpolated ("linear" or "step").

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

local function wrap180(a)
  return (a + 180) % 360 - 180
end

-- FK transforms of every bone by id. `chan[id] = { rot, dx, dy }`; `ov[id]`
-- replaces a bone's rotation (IK result); `noOff[id]` ignores its offset.
-- A bone rotates around its own rest-pose head, is offset by (dx, dy), and then
-- everything is carried by its parent's transform.
local function evalT(self, chan, ov, noOff)
  local T = {}
  local function xf(b, depth)
    if T[b.id] then return T[b.id] end
    local ch = chan[b.id]
    local rot, dx, dy = ch[1], ch[2], ch[3]
    if ov[b.id] ~= nil then rot = ov[b.id] end
    if noOff[b.id] then dx, dy = 0, 0 end
    local th = math.rad(rot)
    local c, s = math.cos(th), math.sin(th)
    local rt = { c = c, s = s, tx = b.ax - (c * b.ax - s * b.ay), ty = b.ay - (s * b.ax + c * b.ay) }
    local parent = (b.parent ~= 0) and self:get(b.parent) or nil
    -- Local transform: rotate about the rest head, then offset (dx, dy) in the
    -- parent's frame. Every bone can be offset; its children follow.
    local lt = compose({ c = 1, s = 0, tx = dx, ty = dy }, rt)
    local t
    if parent and depth < 256 then
      t = compose(xf(parent, depth + 1), lt)
    else
      t = lt
    end
    T[b.id] = t
    return t
  end
  for _, b in ipairs(self.bones) do xf(b, 0) end
  return T
end

-- IK chain of a constraint: the tip bone plus up to chain-1 parents, as long as
-- each bone is connected to its parent. Returns the bones root-first and the
-- target bone, or nil and a reason.
function Rig:ikResolve(ik)
  local tip, tb = self:get(ik.tip), self:get(ik.target)
  if not tip then return nil, "IK tip bone is missing." end
  if not tb then return nil, "IK target bone is missing." end
  if tip.id == tb.id then return nil, "The target can't be the tip itself." end
  local n = math.max(1, math.min(math.floor(ik.chain or 2), 8))
  local list, cur = { tip }, tip
  local stop = nil
  while #list < n do
    if not cur.connected then stop = "disconnected"; break end
    if cur.parent == 0 then stop = "root"; break end
    local p = self:get(cur.parent)
    if not p then stop = "missing"; break end
    -- A branch point (a hip or chest with a second limb) must not join the
    -- chain: rotating it would drag the sibling limb along.  This also keeps a
    -- too-long "chain" from silently bending the body when the limb is short.
    local branch = false
    for _, s in ipairs(self.bones) do
      if s.parent == p.id and s.id ~= cur.id then branch = true; break end
    end
    if branch then stop = "branch"; break end
    list[#list + 1] = p
    cur = p
  end
  local chain = {}
  for i = #list, 1, -1 do chain[#chain + 1] = list[i] end
  for _, b in ipairs(chain) do
    if b.id == tb.id then return nil, "The target can't be part of the chain it controls." end
  end
  if self:isDescendant(tb.id, chain[1].id) then
    return nil, "The target hangs under the chain it controls; unparent it or shorten the chain."
  end
  return chain, tb, stop
end

-- Joint positions P[1..n+1] of a chain (P[1] = head of the first bone, P[n+1] =
-- tail of the tip) that reach for the goal. n = 1 aims, n = 2 is analytic with
-- a bend side, n >= 3 is FABRIK starting from the FK pose.
local function ikJoints(chain, T, gx, gy, bend)
  local n = #chain
  local b1 = chain[1]
  local hx, hy = apply(T[b1.id], b1.ax, b1.ay)
  local len, total = {}, 0
  for i, b in ipairs(chain) do
    len[i] = math.sqrt((b.bx - b.ax) ^ 2 + (b.by - b.ay) ^ 2)
    total = total + len[i]
  end
  if total < 1e-6 then return nil end
  local dx, dy = gx - hx, gy - hy
  local d = math.sqrt(dx * dx + dy * dy)
  local ux, uy = 1, 0
  if d > 1e-6 then ux, uy = dx / d, dy / d end
  local P = { { hx, hy } }
  if n == 1 then
    P[2] = { hx + ux * len[1], hy + uy * len[1] }
  elseif n == 2 then
    local l1, l2 = len[1], len[2]
    if l1 < 1e-6 or l2 < 1e-6 then return nil end
    local maxd, mind = l1 + l2 - 1e-4, math.abs(l1 - l2) + 1e-4
    local dc = math.max(mind, math.min(maxd, d))
    local cosA = math.max(-1, math.min(1, (l1 * l1 + dc * dc - l2 * l2) / (2 * l1 * dc)))
    local sgn = (bend and bend < 0) and -1 or 1
    local th1 = math.atan(uy, ux) + sgn * math.acos(cosA)
    P[2] = { hx + l1 * math.cos(th1), hy + l1 * math.sin(th1) }
    P[3] = { hx + dc * ux, hy + dc * uy }
  else
    for i, b in ipairs(chain) do
      local px, py = apply(T[b.id], b.bx, b.by)
      P[i + 1] = { px, py }
    end
    if d >= total - 1e-6 then
      local cum = 0
      for i = 1, n do
        cum = cum + len[i]
        P[i + 1] = { hx + ux * cum, hy + uy * cum }
      end
    else
      for _ = 1, 24 do
        if math.abs(P[n + 1][1] - gx) + math.abs(P[n + 1][2] - gy) < 1e-3 then break end
        P[n + 1] = { gx, gy }
        for i = n, 1, -1 do
          local vx, vy = P[i][1] - P[i + 1][1], P[i][2] - P[i + 1][2]
          local vl = math.sqrt(vx * vx + vy * vy)
          if vl < 1e-9 then vx, vy, vl = 1, 0, 1 end
          P[i] = { P[i + 1][1] + vx / vl * len[i], P[i + 1][2] + vy / vl * len[i] }
        end
        P[1] = { hx, hy }
        for i = 1, n do
          local vx, vy = P[i + 1][1] - P[i][1], P[i + 1][2] - P[i][2]
          local vl = math.sqrt(vx * vx + vy * vy)
          if vl < 1e-9 then vx, vy, vl = 1, 0, 1 end
          P[i + 1] = { P[i][1] + vx / vl * len[i], P[i][2] + vy / vl * len[i] }
        end
      end
    end
  end
  return P
end

-- Local rotations (degrees) that make each chain bone point from P[i] to
-- P[i+1]. `pa` is the angle of the first bone's parent transform.
local function jointRotations(chain, P, pa)
  local rots, acc = {}, pa
  for i, b in ipairs(chain) do
    local th = math.atan(P[i + 1][2] - P[i][2], P[i + 1][1] - P[i][1])
    local rest = math.atan(b.by - b.ay, b.bx - b.ax)
    local rot = wrap180(math.deg(th - rest - acc))
    rots[i] = rot
    acc = acc + math.rad(rot)
  end
  return rots
end

-- Posed copy of every bone (same order as self.bones) at a frame, plus the
-- transform of each bone by id. Forward kinematics, then the IK constraints in
-- order: each one bends its chain towards its target bone, blended with the FK
-- pose by its influence. `noIK` gives the pure FK pose.
function Rig:pose(anim, frame, noIK)
  local chan = {}
  for _, b in ipairs(self.bones) do
    local r, dx, dy = 0, 0, 0
    if anim then r, dx, dy = self:channels(anim, b.id, frame) end
    local ar, ax, ay = self:assemblyChannels(b.id)
    chan[b.id] = { r + ar, dx + ax, dy + ay }
  end
  local ov, noOff, active = {}, {}, {}
  if not noIK then
    for _, ik in ipairs(self.iks or {}) do
      if ik.enabled ~= false and (ik.influence or 1) > 0 then
        local chain, tb = self:ikResolve(ik)
        if chain then
          active[#active + 1] = { ik = ik, chain = chain, target = tb }
          -- lower chain bones stay attached to their parents
          for i = 2, #chain do noOff[chain[i].id] = true end
        end
      end
    end
  end
  local T = evalT(self, chan, ov, noOff)
  for _, a in ipairs(active) do
    local chain, tb = a.chain, a.target
    local gx, gy = apply(T[tb.id], tb.ax, tb.ay)
    local P = ikJoints(chain, T, gx, gy, a.ik.bend)
    if P then
      local pt = (chain[1].parent ~= 0) and T[chain[1].parent] or nil
      local pa = pt and math.atan(pt.s, pt.c) or 0
      local rots = jointRotations(chain, P, pa)
      local w = math.max(0, math.min(1, a.ik.influence or 1))
      for i, b in ipairs(chain) do
        local fkr = chan[b.id][1]
        ov[b.id] = fkr + w * wrap180(rots[i] - fkr)
      end
      T = evalT(self, chan, ov, noOff)
    end
  end
  local out = {}
  for i, b in ipairs(self.bones) do
    local t = T[b.id]
    local nb = copy(b)
    nb.ax, nb.ay = apply(t, b.ax, b.ay)
    nb.bx, nb.by = apply(t, b.bx, b.by)
    out[i] = nb
  end
  return out, T
end

-- IK constraints -----------------------------------------------------------
-- { id, name, tip, target, chain, influence (0..1), bend (+-1), enabled }
-- The tip bone's chain reaches for the head of the target bone, a plain helper
-- bone (group 0, no skin) that is animated with ordinary offset keys.

function Rig:getIK(id)
  for _, k in ipairs(self.iks or {}) do
    if k.id == id then return k end
  end
  return nil
end

function Rig:ikForTip(boneId)
  for _, k in ipairs(self.iks or {}) do
    if k.tip == boneId then return k end
  end
  return nil
end

function Rig:ikForTarget(boneId)
  for _, k in ipairs(self.iks or {}) do
    if k.target == boneId then return k end
  end
  return nil
end

-- The constraint on the mirrored side, if there is one.
function Rig:twinIK(ik)
  local tip = self:get(ik.tip)
  local tw = tip and self:twin(tip)
  return tw and self:ikForTip(tw.id) or nil
end

function Rig:addIK(tipId, targetId, chain, influence, bend)
  local tip = self:get(tipId)
  local ik = {
    id = self.nextIkId or 1,
    name = (tip and tip.name or "bone") .. " IK",
    tip = tipId, target = targetId,
    chain = chain or 2, influence = influence or 1,
    bend = (bend and bend < 0) and -1 or 1,
    enabled = true,
  }
  local ok, why = self:ikResolve(ik)
  if not ok then return nil, why end
  self.nextIkId = ik.id + 1
  self.iks = self.iks or {}
  self.iks[#self.iks + 1] = ik
  self:touch()
  return ik
end

function Rig:deleteIK(id)
  for i, k in ipairs(self.iks or {}) do
    if k.id == id then
      table.remove(self.iks, i)
      self:touch()
      return true
    end
  end
  return false
end

-- Change fields of a constraint; refuses (and restores) an invalid result.
function Rig:updateIK(ik, fields)
  local old = {}
  for k, v in pairs(fields) do old[k] = ik[k]; ik[k] = v end
  local ok, why = self:ikResolve(ik)
  if not ok then
    for k in pairs(fields) do ik[k] = old[k] end
    return false, why
  end
  self:touch()
  return true
end

-- Create a helper bone at the tail of `tipId` (no skin, not parented, so it
-- stays put while the body moves) and an IK constraint that makes the tip
-- follow it. With mirror on, the mirrored limb gets its own pair.
-- Returns ik, controller, twinIk, twinController  -- or nil and a message.
function Rig:addController(tipId, chain, bend, anim, frame)
  local tip = self:get(tipId)
  if not tip then return nil, "Select a bone first." end
  if tip.parent == 0 or not tip.connected then
    return nil, "IK needs a bone that is connected to its parent (a forearm, a shin)."
  end
  if self:ikForTip(tipId) then return nil, "This bone already has an IK controller." end
  local sgn = (bend and bend < 0) and -1 or 1

  -- Start the controller where the tip is right now: the animated pose in
  -- Animate mode, the assembly pose otherwise.  Placing it at the rest tip
  -- while the body is posed would snap the limb back when the IK is created.
  local posed = anim and self:pose(anim, frame or 1) or self:assembledPose()
  local function make(t, dir, sg)
    local tx, ty = t.bx, t.by
    for _, pb in ipairs(posed) do
      if pb.id == t.id then tx, ty = pb.bx, pb.by; break end
    end
    local c = newBone(self, tx, ty, tx + 2 * dir, ty, 0, false, t.name .. "_ctl")
    c.group, c.ra, c.rb = 0, 1, 1
    local ik, why = self:addIK(t.id, c.id, chain or 2, 1, sg)
    if not ik then
      self:delete(c, true)
      return nil, why
    end
    return ik, c
  end

  local ik, c = make(tip, 1, sgn)
  if not ik then return nil, c end
  local tik, tc
  local tw = self.mirror.enabled and self:twin(tip) or nil
  if tw and tw.connected and not self:ikForTip(tw.id) then
    tik, tc = make(tw, -1, -sgn)
    if tik then
      c.mirrorOf, tc.mirrorOf = tc.id, c.id
      tc.name = Rig.swapSide(c.name)
      tik.name = Rig.swapSide(ik.name)
    end
  end
  self:touch()
  return ik, c, tik, tc
end

-- Two-bone IK (quick posing) ------------------------------------------------
-- The chain is upper = parent of `lowerId`, lower = `lowerId` (it must hang
-- connected to its parent). The goal (gx, gy) is where the lower bone's tail
-- (hand / foot) should be. The solver writes ordinary FK rotation keys for
-- both bones at `frame`, so interpolation, export and artwork binding keep
-- working unchanged. `bend` is +1 or -1: which side the elbow / knee points.
-- Returns ok, info  (info = { reached = bool, bend = +-1 }) or false, message.
function Rig:solveIK(anim, frame, lowerId, gx, gy, bend)
  local L = self:get(lowerId)
  if not L or L.parent == 0 then return false, "IK needs a bone that has a parent." end
  if not L.connected then return false, "IK needs the bone to be connected to its parent." end
  local U = self:get(L.parent)
  if not U then return false, "IK: parent bone not found." end

  local posed, T = self:pose(anim, frame, true)
  local pu
  for _, pb in ipairs(posed) do
    if pb.id == U.id then pu = pb break end
  end
  if not pu then return false, "IK: bone not found." end

  local l1 = math.sqrt((U.bx - U.ax) ^ 2 + (U.by - U.ay) ^ 2)
  local l2 = math.sqrt((L.bx - L.ax) ^ 2 + (L.by - L.ay) ^ 2)
  if l1 < 1e-6 or l2 < 1e-6 then return false, "IK: a bone in the chain has zero length." end

  local hx, hy = pu.ax, pu.ay
  local dx, dy = gx - hx, gy - hy
  local d = math.sqrt(dx * dx + dy * dy)
  if d < 1e-6 then dx, dy, d = 1, 0, 1 end
  local maxd, mind = l1 + l2 - 1e-4, math.abs(l1 - l2) + 1e-4
  local dc = math.max(mind, math.min(maxd, d))
  local reached = (d <= maxd and d >= mind)

  local cosA = (l1 * l1 + dc * dc - l2 * l2) / (2 * l1 * dc)
  cosA = math.max(-1, math.min(1, cosA))
  local A = math.acos(cosA)
  local phi = math.atan(dy, dx)
  local sgn = (bend and bend < 0) and -1 or 1
  local th1 = phi + sgn * A
  local ex, ey = hx + l1 * math.cos(th1), hy + l1 * math.sin(th1)
  local gcx, gcy = hx + dc * dx / d, hy + dc * dy / d
  local th2 = math.atan(gcy - ey, gcx - ex)

  local pa = 0
  local pt = (U.parent ~= 0) and T[U.parent] or nil
  if pt then pa = math.atan(pt.s, pt.c) end
  local restU = math.atan(U.by - U.ay, U.bx - U.ax)
  local restL = math.atan(L.by - L.ay, L.bx - L.ax)

  local effectiveU = math.deg(th1 - pa - restU)
  local effectiveL = math.deg(th2 - (pa + math.rad(effectiveU)) - restL)
  local arU = self:assemblyChannels(U.id)
  local arL = self:assemblyChannels(L.id)
  local rotU, rotL = effectiveU - arU, effectiveL - arL

  -- Stay on the branch closest to the current value, so interpolation between
  -- keys never spins the long way round.
  local cu = self:channels(anim, U.id, frame)
  local cl = self:channels(anim, L.id, frame)
  rotU = cu + wrap180(rotU - cu)
  rotL = cl + wrap180(rotL - cl)

  self:setKey(anim, U.id, frame, rotU)
  self:setKey(anim, L.id, frame, rotL, 0, 0) -- the lower bone must stay attached
  return true, { reached = reached, bend = sgn, upper = U.id, rotU = rotU, rotL = rotL }
end

-- Which side the elbow / knee is on right now (+1 / -1, or nil when the limb
-- is straight and the side cannot be told).
function Rig:ikBendSide(anim, frame, lowerId)
  local L = self:get(lowerId)
  if not L or L.parent == 0 then return nil end
  local posed = self:pose(anim, frame, true)
  local pu, pl
  for _, pb in ipairs(posed) do
    if pb.id == L.parent then pu = pb end
    if pb.id == L.id then pl = pb end
  end
  if not pu or not pl then return nil end
  local ex, ey = pu.bx - pu.ax, pu.by - pu.ay
  local gx, gy = pl.bx - pu.ax, pl.by - pu.ay
  local cross = gx * ey - gy * ex
  if math.abs(cross) < 1e-3 then return nil end
  return (cross > 0) and 1 or -1
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
