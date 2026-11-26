-- Run from the extension root:  lua tests/test_rig.lua
package.path = "./?.lua;" .. package.path

local json = require("pixrig.json")
local Rig = require("pixrig.rig")
local Skin = require("pixrig.skin")

local function eq(a, b, msg)
  if math.abs(a - b) > 1e-9 then
    error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
  end
end

-- json round trip
do
  local src = { a = 1.5, b = { 1, 2, 3 }, c = "x\"y\n", d = true, e = {} }
  local back = json.decode(json.encode(src))
  eq(back.a, 1.5)
  eq(#back.b, 3)
  assert(back.c == "x\"y\n")
  assert(back.d == true)
  assert(#back.e == 0)
end

-- create + chain
do
  local r = Rig.new(32)
  local a = r:addBone(10.5, 10.5, 10.5, 20.5, 0, false, "arm")
  local b = r:addBone(10.5, 20.5, 10.5, 30.5, a.id, true, "forearm")
  assert(b.connected and b.parent == a.id)
  -- moving parent's tail drags connected child's head
  r:setPoint(a, "tail", 12.5, 21.5)
  eq(b.ax, 12.5); eq(b.ay, 21.5)
  -- moving connected child's head moves the parent's tail
  r:setPoint(b, "head", 13.5, 22.5)
  eq(a.bx, 13.5); eq(a.by, 22.5)
end

-- mirror create / edit / delete
do
  local r = Rig.new(32)
  r.mirror.enabled = true
  local a, at = r:addBone(36.5, 10.5, 40.5, 20.5, 0, false, "arm_L")
  assert(at, "twin expected")
  eq(at.ax, 27.5); eq(at.bx, 23.5)
  assert(at.name == "arm_R", at.name)
  r:setPoint(a, "tail", 42.5, 22.5)
  eq(at.bx, 21.5); eq(at.by, 22.5)
  r:translate(a, 2, 1)
  eq(at.ax, 25.5, "twin translate mirrored")
  r:delete(a)
  assert(#r.bones == 0, "twin deleted with bone")
end

-- on-axis bone gets no twin
do
  local r = Rig.new(32)
  r.mirror.enabled = true
  local spine, twin = r:addBone(32, 10, 32, 30, 0, false, "spine")
  assert(twin == nil)
end

-- parenting guards against loops
do
  local r = Rig.new(0)
  local a = r:addBone(0, 0, 0, 10, 0, false)
  local b = r:addBone(0, 10, 0, 20, a.id, true)
  assert(r:setParent(a, b.id, false) == false, "loop must be rejected")
end

-- symmetrize
do
  local r = Rig.new(32)
  local a = r:addBone(36, 10, 40, 20, 0, false, "x")
  local b = r:addBone(28, 10, 24, 20, 0, false, "y")
  eq(r:symmetrize(), 1)
  eq(a.mirrorOf, b.id)
end

-- serialization keeps ids
do
  local r = Rig.new(16)
  r:addBone(1, 2, 3, 4, 0, false, "q")
  local r2 = Rig.fromTable(json.decode(json.encode(r:toTable())))
  eq(#r2.bones, 1)
  eq(r2.nextId, r.nextId)
end

-- radius: connected joint is shared, mirror follows
do
  local r = Rig.new(32)
  r.mirror.enabled = true
  local a = r:addBone(36.5, 10.5, 36.5, 20.5, 0, false, "arm_L")
  local b, bt = r:addBone(36.5, 20.5, 36.5, 30.5, a.id, true, "forearm_L")
  eq(b.ra, a.rb, "connected head radius starts equal to parent tail")
  r:setRadius(b, "head", 4)
  eq(a.rb, 4); eq(b.ra, 4)
  local at = r:twin(a)
  eq(at.rb, 4, "mirror radius")
  local rev = r.rev
  r:setRadius(a, "tail", 3)
  assert(r.rev > rev, "rev bumps on edit")
  eq(b.ra, 3)
end

-- groups
do
  local r = Rig.new(32)
  local b = r:addBone(5, 5, 5, 15, 0, false)
  eq(b.group, 1)
  local g = r:addGroup("Arms")
  eq(r.activeGroup, g.id)
  local b2 = r:addBone(8, 5, 8, 15, 0, false)
  eq(b2.group, g.id)
  assert(r:renameGroup(g.id, "Body") == "Body 2", "unique group names")
  assert(r:deleteGroup(g.id) == true)
  eq(b2.group, 0, "bones of a deleted group become helpers")
  assert(r:deleteGroup(1) == false, "last group cannot be deleted")
  -- survives serialization, including defaults for old data
  local r2 = Rig.fromTable(json.decode(json.encode(r:toTable())))
  eq(#r2.groups, 1); eq(r2.bones[1].group, 1)
  local old = Rig.fromTable({ bones = { { id = 1, ax = 0, ay = 0, bx = 0, by = 5 } } })
  eq(old.bones[1].group, old.groups[1].id); eq(old.bones[1].ra, 2)
end

-- skin
do
  local r = Rig.new(16)
  r:addBone(8.5, 8.5, 8.5, 20.5, 0, false)           -- default radius 2
  local res = Skin.render(r, 32, 32)
  local function idx(x, y) return y * 32 + x + 1 end
  assert(res.masks[1][idx(8, 14)], "inside the capsule")
  assert(not res.masks[1][idx(20, 14)], "outside the capsule")
  assert(res.outline[idx(5, 14)], "outline just outside the skin")
  assert(not res.outline[idx(8, 14)], "no outline inside")
  r.outline = "none"
  assert(Skin.render(r, 32, 32).outline == nil)
  r:assignGroup(r.bones[1], 0, false)
  assert(next(Skin.render(r, 32, 32).all) == nil, "helper bones draw nothing")
end

-- animation: keys, interpolation, forward kinematics
do
  local r = Rig.new(32)
  local a = r:addBone(0, 0, 0, 10, 0, false, "upper")          -- vertical, head at origin
  local b = r:addBone(0, 10, 0, 20, a.id, true, "lower")        -- connected below it
  local anim = r:currentAnim()

  -- no keys: posed == rest
  local posed = r:pose(anim, 1)
  eq(posed[2].bx, 0); eq(posed[2].by, 20)

  -- rotate the parent 90 degrees around its head: tail (0,10) -> (-10,0)
  r:setKey(anim, a.id, 1, 90)
  posed = r:pose(anim, 1)
  eq(posed[1].bx, -10); eq(posed[1].by, 0)
  eq(posed[2].ax, -10); eq(posed[2].ay, 0, "connected child head follows the parent's tail")
  eq(posed[2].bx, -20); eq(posed[2].by, 0, "child is carried rigidly")

  -- linear interpolation between keys, step holds the previous key
  r:setKey(anim, a.id, 1, 0)
  r:setKey(anim, a.id, 5, 80)
  local rot = r:channels(anim, a.id, 3)
  eq(rot, 40)
  anim.interp = "step"
  eq((r:channels(anim, a.id, 3)), 0)
  anim.interp = "linear"
  eq((r:channels(anim, a.id, 9)), 80, "holds the last key")

  -- setKey keeps unspecified channels at their current value
  r:setKey(anim, a.id, 5, nil, 3, 4)
  local r2, dx, dy = r:channels(anim, a.id, 5)
  eq(r2, 80); eq(dx, 3); eq(dy, 4)

  -- root translation moves every bone
  posed = r:pose(anim, 5)
  assert(math.abs(posed[2].by) > 0)

  -- delete key / bone cleanup / serialization
  assert(r:deleteKey(anim, a.id, 5) == true)
  assert(r:hasKey(anim, a.id, 1) == true)
  local r3 = Rig.fromTable(json.decode(json.encode(r:toTable())))
  eq((r3:channels(r3:currentAnim(), a.id, 1)), 0)
  r:delete(b)
  assert(anim.keys[string.format("%d", b.id)] == nil)

  -- animations management
  local an2 = r:addAnim()
  eq(r.activeAnim, an2.id)
  assert(r:deleteAnim(an2.id) == true)
  assert(r:deleteAnim(r.activeAnim) == false, "last animation cannot be deleted")

  -- old data without animations loads with a default one
  local old = Rig.fromTable({ bones = {} })
  eq(#old.anims, 1)
end

-- skin follows the posed bones
do
  local r = Rig.new(16)
  local a = r:addBone(8.5, 8.5, 8.5, 20.5, 0, false, "bar")
  local anim = r:currentAnim()
  r:setKey(anim, a.id, 1, 90)                                   -- swing the bar sideways
  local res = Skin.render(r, 32, 32, r:pose(anim, 1))
  local function idx(x, y) return y * 32 + x + 1 end
  assert(res.masks[1][idx(2, 8)], "bar swung to the left of its head")
  assert(not res.masks[1][idx(8, 18)], "old position is empty")
end

print("all tests passed")
