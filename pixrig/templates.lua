-- PixelBone v0.7 UI helper: add a small humanoid rest rig using the EXISTING
-- Rig:addBone API. No new animation or persistence format is introduced.
local T = {}

function T.humanoid(rig, width, height)
  if #rig.bones ~= 0 then
    return false, "Humanoid template requires an empty skeleton (existing bones are untouched)."
  end
  if width < 16 or height < 16 then
    return false, "Make the sprite at least 16 x 16 pixels for this template."
  end
  local scale = math.min(width, height) / 64
  local cx, cy = width / 2, height * 0.52
  local function pt(dx,dy)
    return math.floor(cx+dx*scale)+0.5, math.floor(cy+dy*scale)+0.5
  end
  local function bone(name, x1,y1,x2,y2,parent,connected)
    local ax,ay=pt(x1,y1)
    local bx,by=pt(x2,y2)
    return rig:addBone(ax,ay,bx,by,parent and parent.id or 0,connected,name)
  end

  -- Suppress automatic mirroring while adding explicit _L/_R names.
  local mirroring = rig.mirror.enabled
  rig.mirror.enabled = false
  local hips=bone("hips",0,1,0,-5)
  local chest=bone("chest",0,-5,0,-17,hips,true)
  local neck=bone("neck",0,-17,0,-20,chest,true)
  bone("head",0,-20,0,-26,neck,true)
  for _,side in ipairs({ {"L",-1},{"R",1} }) do
    local s=side[2]
    local upper=bone("upper_arm_"..side[1],2*s,-16,9*s,-12,chest,false)
    local lower=bone("forearm_"..side[1],9*s,-12,15*s,-8,upper,true)
    bone("hand_"..side[1],15*s,-8,17*s,-7,lower,true)
    local thigh=bone("thigh_"..side[1],3*s,1,5*s,13,hips,false)
    local shin=bone("shin_"..side[1],5*s,13,6*s,23,thigh,true)
    bone("foot_"..side[1],6*s,23,10*s,24,shin,true)
  end
  rig.mirror.axisX = width/2
  rig.mirror.enabled = mirroring
  rig:symmetrize()
  rig:touch()
  return true, #rig.bones
end

return T
