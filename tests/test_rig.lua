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

-- two-bone IK: the foot reaches the goal on both knee sides, limb stays connected
do
  local r = Rig.new(32)
  local hip = r:addBone(16, 8, 16, 10, 0, false, "hip")
  local thigh = r:addBone(16, 10, 16, 16, hip.id, true, "thigh")
  local shin = r:addBone(16, 16, 16, 22, thigh.id, true, "shin")
  local anim = r:currentAnim()
  for _, bend in ipairs({ 1, -1 }) do
    local ok, info = r:solveIK(anim, 1, shin.id, 22, 18, bend)
    assert(ok and info.reached)
    local posed = r:pose(anim, 1)
    local foot, knee_t, knee_s
    for _, b in ipairs(posed) do
      if b.id == shin.id then foot = b; knee_s = b end
      if b.id == thigh.id then knee_t = b end
    end
    eq(foot.bx, 22, "foot x")
    eq(foot.by, 18, "foot y")
    assert(math.abs(knee_t.bx - knee_s.ax) < 1e-9 and math.abs(knee_t.by - knee_s.ay) < 1e-9, "knee joint stays connected")
    assert(r:ikBendSide(anim, 1, shin.id) == bend, "knee side")
  end
  -- out of reach: limb straightens toward the goal, no error
  local ok, info = r:solveIK(anim, 1, shin.id, 100, 10, 1)
  assert(ok and not info.reached)
end

-- per-bone offset: children follow, offset lives in the parent's frame
do
  local r = Rig.new(32)
  local a = r:addBone(10, 10, 10, 16, 0, false, "a")
  local b = r:addBone(10, 16, 10, 22, a.id, true, "b")
  local anim = r:currentAnim()
  r:setKey(anim, b.id, 1, nil, 5, 0)
  local posed = r:pose(anim, 1)
  eq(posed[2].ax, 15, "b head moved by dx")
  eq(posed[2].bx, 15, "b tail moved by dx")
  eq(posed[1].ax, 10, "parent unchanged")
  -- rotate parent 90 degrees: the same local offset now points another way
  r:setKey(anim, a.id, 1, 90)
  posed = r:pose(anim, 1)
  local ex, ey = posed[1].bx, posed[1].by
  assert(math.abs(posed[2].ax - ex) < 1e-9, "offset no longer along x after the parent turned")
  assert(math.abs(math.abs(posed[2].ay - ey) - 5) < 1e-9, "offset now runs along y by 5")
  -- offset on a middle bone moves its subtree
  local c = r:addBone(10, 22, 10, 28, b.id, true, "c")
  r:setKey(anim, a.id, 1, 0)
  r:setKey(anim, b.id, 1, nil, 0, 3)
  posed = r:pose(anim, 1)
  eq(posed[3].ay, 25, "grandchild follows the offset")
end

-- IK constraints: controller bone, chain length, influence ---------------------
local function dist(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end
local function posedBy(posed, id) for _, b in ipairs(posed) do if b.id == id then return b end end end

do -- two-bone chain follows a controller, in both bend directions
  local r = Rig.new(32)
  local hip = r:addBone(16, 8, 16, 10, 0, false, "hip")
  local thigh = r:addBone(16, 10, 16, 16, hip.id, true, "thigh")
  local shin = r:addBone(16, 16, 16, 22, thigh.id, true, "shin")
  local anim = r:currentAnim()
  local ik, ctl = r:addController(shin.id, 2, 1)
  assert(ik and ctl, "controller created")
  assert(ctl.group == 0, "controller has no skin")
  eq(ctl.ax, 16, "controller sits at the tip")
  eq(ctl.ay, 22, "controller sits at the tip")
  -- at rest the pose is unchanged (the foot already is at the controller)
  local posed = r:pose(anim, 1)
  assert(math.abs(posedBy(posed, shin.id).by - 22) < 1e-3, "rest pose kept")
  -- offset the controller: the foot follows
  r:setKey(anim, ctl.id, 1, nil, 4, -3)
  for _, bend in ipairs({ 1, -1 }) do
    r:updateIK(ik, { bend = bend })
    posed = r:pose(anim, 1)
    local foot, knee = posedBy(posed, shin.id), posedBy(posed, thigh.id)
    eq(foot.bx, 20, "foot reaches controller x")
    eq(foot.by, 19, "foot reaches controller y")
    assert(dist(knee.bx, knee.by, foot.ax, foot.ay) < 1e-9, "knee stays connected")
    assert(dist(knee.bx, knee.by, 16, 10) - 6 < 1e-9, "thigh keeps its length")
  end
  -- the two bends put the knee on opposite sides
  r:updateIK(ik, { bend = 1 })
  local k1 = posedBy(r:pose(anim, 1), thigh.id).bx
  r:updateIK(ik, { bend = -1 })
  local k2 = posedBy(r:pose(anim, 1), thigh.id).bx
  assert(math.abs(k1 - k2) > 1, "bend flips the knee")
  -- influence 0 = pure FK, 0.5 = halfway between FK and IK
  r:updateIK(ik, { influence = 0 })
  eq(posedBy(r:pose(anim, 1), shin.id).by, 22, "influence 0 is FK")
  r:updateIK(ik, { influence = 1 })
  local full = posedBy(r:pose(anim, 1), shin.id)
  r:updateIK(ik, { influence = 0.5 })
  local half = posedBy(r:pose(anim, 1), shin.id)
  assert(dist(half.bx, half.by, 20, 19) > 0.1 and dist(half.bx, half.by, 20, 19) < dist(16, 22, 20, 19), "half influence lands between FK and IK")
  -- an unreachable controller straightens the limb towards it
  r:updateIK(ik, { influence = 1 })
  r:setKey(anim, ctl.id, 1, nil, 40, 0)
  local f = posedBy(r:pose(anim, 1), shin.id)
  assert(dist(f.bx, f.by, 16, 10) <= 12 + 1e-6, "limb never stretches")
  -- disabled constraint = FK
  r:updateIK(ik, { enabled = false })
  eq(posedBy(r:pose(anim, 1), shin.id).bx, 16, "disabled constraint is ignored")
end

do -- a controller that is not parented stays planted while the hip moves
  local r = Rig.new(32)
  local hip = r:addBone(16, 8, 16, 10, 0, false, "hip")
  local thigh = r:addBone(16, 10, 16, 16, hip.id, true, "thigh")
  local shin = r:addBone(16, 16, 16, 22, thigh.id, true, "shin")
  local anim = r:currentAnim()
  local ik, ctl = r:addController(shin.id, 2, 1)
  r:setKey(anim, hip.id, 1, nil, 1, 2)   -- hip drops 2 px and shifts 1 px
  local foot = posedBy(r:pose(anim, 1), shin.id)
  eq(foot.bx, 16, "foot stays on the ground")
  eq(foot.by, 22, "foot stays on the ground")
end

do -- chain of 1 aims, chain of 3 reaches (FABRIK)
  local r = Rig.new(32)
  local a = r:addBone(10, 10, 10, 16, 0, false, "a")
  local b = r:addBone(10, 16, 10, 22, a.id, true, "b")
  local c = r:addBone(10, 22, 10, 28, b.id, true, "c")
  local anim = r:currentAnim()
  local ik, ctl = r:addController(c.id, 3, 1)
  assert(ik, "chain of 3 is allowed")
  r:setKey(anim, ctl.id, 1, nil, 9, -8)       -- goal (19, 20), reachable (18 long)
  local tip = posedBy(r:pose(anim, 1), c.id)
  assert(dist(tip.bx, tip.by, 19, 20) < 0.02, "FABRIK chain reaches the goal")
  assert(dist(posedBy(r:pose(anim, 1), a.id).ax, posedBy(r:pose(anim, 1), a.id).ay, 10, 10) < 1e-9, "chain root stays put")
  r:updateIK(ik, { chain = 1 })
  local p = r:pose(anim, 1)
  local pc = posedBy(p, c.id)
  local ang = math.atan(pc.by - pc.ay, pc.bx - pc.ax)
  local want = math.atan(20 - pc.ay, 19 - pc.ax)
  assert(math.abs(ang - want) < 1e-9, "chain of 1 aims the bone at the target")
end

do -- validation, mirror pair, save / undo round trip, deleting the controller
  local r = Rig.new(16)
  r.mirror.enabled = true
  local hipL = r:addBone(18, 8, 20, 12, 0, false, "hip")             -- twin is created
  local up, upT = r:addBone(20, 12, 20, 18, hipL.id, true, "legL")
  local lo, loT = r:addBone(20, 18, 20, 24, up.id, true, "shinL")
  local ik, ctl, tik, tctl = r:addController(lo.id, 2, 1)
  assert(ik and tik and tctl, "mirrored controller pair")
  assert(tik.bend == -ik.bend, "mirrored bend")
  eq(ctl.mirrorOf, tctl.id, "controllers are twins")
  assert(r:twinIK(ik) == tik, "twin constraint found")
  assert(select(1, r:addController(lo.id, 2, 1)) == nil, "no second controller on the same tip")
  -- a target below the chain is refused
  local bad, why = r:addIK(lo.id, up.id, 2, 1, 1)
  assert(bad == nil and why, "target inside the chain is refused")
  -- round trip through the saved table and through undo
  local back = Rig.fromTable(r:toTable())
  eq(#back.iks, 2, "constraints saved")
  eq(back.iks[1].tip, lo.id, "tip saved")
  local snap = r:snapshot()
  r:deleteIK(ik.id)
  eq(#r.iks, 1, "constraint deleted")
  r:restore(snap)
  eq(#r.iks, 2, "undo brings the constraint back")
  -- deleting a controller bone removes its constraint
  r:delete(ctl, true)
  eq(#r.iks, 1, "constraint goes with its controller")
end

do -- creating a controller after posing keeps the limb where it is
  local r = Rig.new(32)
  local hip = r:addBone(16, 8, 16, 10, 0, false, "hip")
  local thigh = r:addBone(16, 10, 16, 16, hip.id, true, "thigh")
  local shin = r:addBone(16, 16, 16, 22, thigh.id, true, "shin")
  local anim = r:currentAnim()
  r:setKey(anim, hip.id, 1, nil, 0, 5)          -- body down 5 px first
  local before = posedBy(r:pose(anim, 1), shin.id)
  local ik = r:addController(shin.id, 2, 1, anim, 1)
  assert(ik, "controller created from the animated pose")
  local after = posedBy(r:pose(anim, 1), shin.id)
  assert(dist(before.bx, before.by, after.bx, after.by) < 1e-3,
         "creating a controller must not snap the foot to the rest pose")
end

do -- a chain never pulls in a branch point (a hip with two legs)
  local r = Rig.new(32)
  local hip = r:addBone(16, 8, 16, 10, 0, false, "hip")
  local thighL = r:addBone(16, 10, 12, 16, hip.id, true, "thighL")
  local shinL = r:addBone(12, 16, 8, 22, thighL.id, true, "shinL")
  local thighR = r:addBone(16, 10, 20, 16, hip.id, true, "thighR")
  r:addBone(20, 16, 24, 22, thighR.id, true, "shinR")
  local ik = r:addController(shinL.id, 4, 1)
  assert(ik, "controller created")
  local chain, _, stop = r:ikResolve(ik)
  eq(#chain, 2, "the chain stops before the branching hip")
  eq(chain[1].id, thighL.id, "chain root is the left thigh")
  eq(chain[2].id, shinL.id, "chain tip is the left shin")
  assert(stop == "branch", "the branch reason is reported")
end

print("all tests passed")
