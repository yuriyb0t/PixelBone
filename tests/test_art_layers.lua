-- Mocked Aseprite pixel API: verifies multi-layer source binding and non-destructive editing.
package.path="./?.lua;"..package.path
ColorMode={RGB=1}
Point=function(x,y) return {x=x,y=y} end
local function rgba(r,g,b,a) return r | (g<<8) | (b<<16) | ((a or 255)<<24) end
local pc={rgba=rgba,rgbaR=function(c) return c&255 end,
  rgbaG=function(c) return (c>>8)&255 end,
  rgbaB=function(c) return (c>>16)&255 end,
  rgbaA=function(c) return (c>>24)&255 end}
app={pixelColor=pc,refresh=function() end,transaction=function(_,fn) return fn() end}
Image=function(w,h)
  local pixels={}
  local im={width=w,height=h}
  function im:putPixel(x,y,c) pixels[y*w+x]=c end
  function im:getPixel(x,y) return pixels[y*w+x] or 0 end
  return im
end
local function layer(name)
  local obj={name=name,isGroup=false,isVisible=true,opacity=255,cels={}}
  function obj:cel(n) return self.cels[n] end
  return obj
end
local sprite={width=48,height=48,colorMode=ColorMode.RGB,layers={}}
function sprite:newLayer()
  return setmetatable(layer("Layer"),{__newindex=function(obj,k,v)
    rawset(obj,k,v)
    if k=="parent" and v and v.layers then v.layers[#v.layers+1]=obj end
  end})
end
function sprite:newCel(l,frame,im,pos)
  l.cels[frame]={image=im,position=pos,opacity=255};return l.cels[frame]
end
local Rig=require("pixrig.rig")
local Binding=require("pixrig.binding")
local Paint=require("pixrig.paint")
local r=Rig.new(24)
local arm=r:addBone(5,5,5,10,0,false,"arm")
local head=r:addBone(27,5,27,10,0,false,"head")
local sheet={name="PixRig Paint Sheet",isGroup=true,isVisible=true,layers={}}
sprite.layers[1]=sheet
local base=layer("Body [bone group 1]")
local img=Image(48,48)
local blue=rgba(0,0,255,255)
local yellow=rgba(255,255,0,255)
img:putPixel(5,6,blue)
img:putPixel(27,6,yellow)
sprite:newCel(base,1,img,Point(0,0))
sheet.layers[1]=base
local hat=layer("Hat [bone "..arm.id.."]")
local imh=Image(48,48)
local red=rgba(255,0,0,255)
imh:putPixel(27,6,red) -- nearer to head, but explicitly linked to arm
sprite:newCel(hat,1,imh,Point(0,0))
sheet.layers[2]=hat
local sources=Binding.sources(sprite,r)
assert(#sources[1].layers==2,"all layers should be in sources")
local prepared=Binding.prepare(sprite,r)
assert(#prepared[1].layers==2,"two bindable layers")
assert(prepared[1].layers[2].byBone[arm.id],"hat forced to arm")
local result=Binding.render(prepared,select(2,r:assembledPose()),48,48)
assert(result[1]:getPixel(27,6)==red,"top hat draws above body")
local ar,ax,ay=r:assemblyChannels(arm.id)
assert(ar==0 and ax==0 and ay==0)
r:setAssembly(arm.id,nil,10,0)
local after=Binding.render(prepared,select(2,r:assembledPose()),48,48)
assert(after[1]:getPixel(37,6)==red,"hat follows selected arm even when far away")
assert(after[1]:getPixel(27,6)==yellow,"head pixel stays on other bone")
assert(imh:getPixel(27,6)==red,"original source remains unchanged")

-- A new accessory layer has its own editable cel; no source pixel altered.
local ok,name=Paint.addBoneLayer(sprite,r,arm.id,"Crown")
assert(ok and name=="Crown [bone "..arm.id.."]")
assert(#sheet.layers==3)
local crown=sheet.layers[3]
assert(crown:cel(1) and app.layer==crown,"new cel is selected for native editing")
local green=rgba(0,255,0,255)
crown:cel(1).image:putPixel(27,7,green)
local newPrepared=Binding.prepare(sprite,r)
assert(#newPrepared[1].layers==3)
local newResult=Binding.render(newPrepared,select(2,r:assembledPose()),48,48)
assert(newResult[1]:getPixel(37,7)==green,"fresh art binds without re-keying")

-- Newest generated sheet takes priority, not both generations mixed.
local nextSheet={name="PixRig Paint Sheet 2",isGroup=true,layers={}}
local replacement=layer("Body [bone group 1]")
local repl=Image(48,48);repl:putPixel(5,6,blue)
sprite:newCel(replacement,1,repl,Point(0,0))
nextSheet.layers[1]=replacement
sprite.layers[#sprite.layers+1]=nextSheet
assert(Binding.activeSheet(sprite)==nextSheet)
assert(#Binding.sources(sprite,r)[1].layers==1,"generations must not blend")

-- Layer-group tags allow untagged children; hidden layers are skipped.
local artGroup={name="Extras [bone group 1]",isGroup=true,layers={}}
local untagged=layer("Scarf")
local scarfIm=Image(48,48);scarfIm:putPixel(5,7,green)
sprite:newCel(untagged,1,scarfIm,Point(0,0))
artGroup.layers[1]=untagged
nextSheet.layers[2]=artGroup
assert(#Binding.sources(sprite,r)[1].layers==2)
untagged.isVisible=false
assert(#Binding.sources(sprite,r)[1].layers==1)

-- Source-over alpha and layer/cel opacity: a translucent accessory is blended
-- on the same assembled bone without changing either editable source image.
local mist=layer("Mist [bone "..arm.id.."]")
local mistImage=Image(48,48)
local halfRed=rgba(255,0,0,128)
mistImage:putPixel(5,6,halfRed)
sprite:newCel(mist,1,mistImage,Point(0,0))
nextSheet.layers[3]=mist
local blendResult=Binding.render(Binding.prepare(sprite,r),select(2,r:assembledPose()),48,48)
local blended=blendResult[1]:getPixel(15,6)
assert(math.abs(pc.rgbaR(blended)-128)<2 and math.abs(pc.rgbaB(blended)-127)<2,
  "semi-transparent hat must source-over blue body")
mist.opacity=128
local faded=Binding.render(Binding.prepare(sprite,r),select(2,r:assembledPose()),48,48)[1]:getPixel(15,6)
assert(math.abs(pc.rgbaR(faded)-64)<2 and math.abs(pc.rgbaB(faded)-191)<2,
  "layer opacity must combine with pixel alpha")
assert(mistImage:getPixel(5,6)==halfRed, "layer source must stay untouched")
print("layered binding tests passed")
