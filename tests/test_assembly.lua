-- Regression: editable separated Rest, persistent non-key Assembly and animation.
package.path="./?.lua;"..package.path
local Rig=require("pixrig.rig")
local json=require("pixrig.json")
local function near(a,b,msg)
  assert(type(a)=="number" and math.abs(a-b)<1e-6,(msg or "number")..": got "..tostring(a)..", expected "..tostring(b))
end
local function bone(list,id)
  for _,b in ipairs(list) do if b.id==id then return b end end
  error("missing bone "..id)
end

local rig=Rig.new(32)
local body=rig:addBone(8,8,8,16,0,false,"body")
local arm=rig:addBone(36,12,44,12,body.id,false,"arm")
local hand=rig:addBone(45,12,49,12,arm.id,false,"hand")
local anim=rig:currentAnim()
local rest=rig:pose(anim,1)
near(bone(rest,arm.id).ax,36,"old projects identity")
near(rig:assemblyChannels(arm.id),0,"identity")

rig:setAssembly(arm.id,0,-27,0)
local assembled=rig:assembledPose()
near(bone(assembled,arm.id).ax,9,"disconnected arm assembled")
near(bone(assembled,hand.id).ax,18,"child inherits parent assembly")
near(rig:get(arm.id).ax,36,"rest art stays separated")
assert(next(anim.keys)==nil,"assembly must not create animation keys")
local first=rig:pose(anim,1)
near(bone(first,arm.id).ax,9,"first exported frame is assembled")
local last=rig:pose(anim,8)
near(bone(last,arm.id).ax,9,"all frames start assembled")

rig:setKey(anim,arm.id,1,90,0,0)
rig:setKey(anim,arm.id,5,0,0,0)
local frame1=rig:pose(anim,1)
near(bone(frame1,arm.id).ax,9,"rotated assembled head")
near(bone(frame1,arm.id).bx,9,"rotated assembled arm X")
near(bone(frame1,arm.id).by,20,"rotated assembled arm Y")
local channelBefore=json.encode(anim.keys)
rig:setAssembly(arm.id,0,-20,2)
local frame1Again=rig:pose(anim,1)
near(bone(frame1Again,arm.id).ax,16,"editing assembly moves all frames")
near(bone(frame1Again,arm.id).ay,14,"edited assembly Y")
assert(channelBefore==json.encode(anim.keys),"editing assembly must not re-key frames")

local saved=json.decode(json.encode(rig:toTable()))
local reload=Rig.fromTable(saved)
local recovered=reload:pose(reload:currentAnim(),1)
near(bone(recovered,arm.id).ax,16,"assembly preserved by save/load")
near(bone(recovered,arm.id).by,22,"animation preserved by save/load")

local old=rig:toTable();old.assembly=nil
local legacy=Rig.fromTable(old)
near(bone(legacy:pose(legacy:currentAnim(),1),arm.id).ax,36,"old projects get identity assembly")
local snap=rig:snapshot()
rig:resetAssembly(arm.id)
near(bone(rig:assembledPose(),arm.id).ax,36,"reset only selected")
rig:restore(snap)
near(bone(rig:assembledPose(),arm.id).ax,16,"undo restores assembly")
rig:delete(arm)
assert(not rig.assembly[tostring(arm.id)],"deleted bone cleans assembly")

local mirrored=Rig.new(32)
mirrored.mirror.enabled=true
local lhs,rhs=mirrored:addBone(40,10,45,10,0,false,"hand_L")
assert(rhs)
mirrored:setAssembly(lhs.id,45,3,2)
local rr,rx,ry=mirrored:assemblyChannels(rhs.id)
near(rr,-45);near(rx,-3);near(ry,2)

-- No assembly change creates a key in a different animation either.
local other=mirrored:addAnim("Walk")
assert(next(other.keys)==nil)
print("assembly rig tests passed")
