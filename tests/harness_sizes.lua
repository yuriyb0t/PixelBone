-- Runs the PixRig dialog against a fake Aseprite API and drives it with
-- synthetic clicks / drags. Catches runtime errors (nil calls, typos) that a
-- syntax check can't. Usage:  texlua tests/harness_ui.lua   (from repo root)
package.path = "./?.lua;" .. package.path

local widgets, dialogs = {}, {}
local warnings = {}
local function warn(s) warnings[#warnings + 1] = s end

local function noop() end
local function loose() return setmetatable({}, { __index = function() return noop end }) end

Color = function(t) t = t or {}; return { red = t.r or t.red or 0, green = t.g or t.green or 0, blue = t.b or t.blue or 0, alpha = t.a or 255 } end
Point = function(x, y) if type(x) == "table" then return { x = x.x or x[1], y = x.y or x[2] } end return { x = x, y = y } end
Rectangle = function(x, y, w, h)
  if type(x) == "table" then return { x = x.x, y = x.y, width = x.width or x.w, height = x.height or x.h } end
  return { x = x, y = y, width = w, height = h }
end
ColorMode = { RGB = 1 }
MouseButton = { LEFT = 1, RIGHT = 2, MIDDLE = 3 }
Image = function(a, b)
  local w, h = a, b
  if type(a) == "table" then w, h = a.width, a.height end
  local px = {}
  local im = { width = w, height = h }
  function im:putPixel(x, y, c) px[y * 100000 + x] = c end
  function im:getPixel(x, y) return px[y * 100000 + x] or 0 end
  function im:drawSprite() end
  function im:drawImage(src, pos)
    pos=pos or {x=0,y=0}
    for y=0,src.height-1 do
      for x=0,src.width-1 do
        local px=src:getPixel(x,y)
        if px~=0 then self:putPixel(x+(pos.x or 0),y+(pos.y or 0),px) end
      end
    end
  end
  function im:clear() px = {} end
  return im
end
Timer = function(o) return { start = noop, stop = noop, isRunning = false, ontick = o.ontick } end

local pc = { rgba = function(r, g, b, a) return r | (g << 8) | (b << 16) | ((a or 255) << 24) end,
  rgbaA = function(c) return (c >> 24) & 255 end }
local sprite = { width = 32, height = 32, data = "", colorMode = ColorMode.RGB, layers = {}, frames = { {}, },
  spec = { width = 32, height = 32 }, events = { on = function() return 1 end, off = noop } }
app = { sprite = sprite, frame = { frameNumber = 1 }, pixelColor = pc, refresh = noop,
  events = { on = function() return 1 end, off = noop },
  alert = function(m) warn("app.alert: " .. tostring(type(m) == "table" and m.text or m)) end,
  transaction = function(name, f) if type(name)=="function" then return name() elseif f then return f() end end,
  window = {bounds={width=1200,height=780}}, uiScale=1 }

local autoN = 0
local function addWidget(d, kind, o)
  o = o or {}
  if not o.id and (o.onclick or o.onchange) then
    autoN = autoN + 1
    widgets["_auto" .. autoN] = { kind = kind, opts = o, dlg = d }
  end
  if o.id then
    if widgets[o.id] then warn("duplicate id " .. o.id) end
    widgets[o.id] = { kind = kind, opts = o, dlg = d }
    if kind == "check" then d.data[o.id] = o.selected and true or false
    elseif kind == "combobox" then d.data[o.id] = o.option
    elseif kind == "number" or kind == "entry" then d.data[o.id] = (kind == "number") and tonumber(o.text) or o.text
    elseif kind == "color" then d.data[o.id] = o.color
    elseif kind == "slider" then d.data[o.id] = o.value end
  end
end
Dialog = function(o)
  local d = { data = {}, opts = o, bounds = Rectangle(0, 0, 100, 100) }
  dialogs[#dialogs + 1] = d
  local kinds = { "button", "check", "number", "entry", "label", "color", "combobox", "canvas", "slider", "separator" }
  if os.getenv("NATIVE_TABS") then kinds[#kinds + 1] = "tab" end
  for _, k in ipairs(kinds) do
    d[k] = function(self, opts) addWidget(self, k, opts); return self end
  end
  d.newrow = function(self) return self end
  if os.getenv("NATIVE_TABS") then d.endtabs = function(self) return self end end
  d.repaint = noop
  d.show = function(self) self.shown = true end
  d.close = function(self) self.shown = false; if self.opts.onclose then self.opts.onclose() end end
  d.modify = function(self, t)
    local id = t.id
    local w = widgets[id]
    if not w then warn("modify: unknown id " .. tostring(id)); return end
    for k, v in pairs(t) do
      if k ~= "id" then w.opts[k] = v end
    end
    if t.selected ~= nil then self.data[id] = t.selected end
    if t.text ~= nil and (w.kind == "entry") then self.data[id] = t.text end
    if t.option ~= nil then self.data[id] = t.option end
  end
  return d
end


local spriteHandlers={}
sprite.events.on=function(self,name,fn) spriteHandlers[name]=fn; return 1 end
function sprite:newGroup()
  local g={name="Group",isGroup=true,layers={}}
  table.insert(self.layers,g)
  return g
end
function sprite:newLayer()
  local l={name="Layer",isGroup=false,cels={}}
  function l:cel(n) return self.cels[n] end
  table.insert(self.layers,l)
  return setmetatable(l, {__newindex=function(obj,k,v)
    rawset(obj,k,v)
    if k=="parent" and v and v.layers then table.insert(v.layers,obj) end
  end})
end
function sprite:newCel(layer,frame,im,pos)
  local cel={image=im,position=pos}
  layer.cels[frame]=cel
  return cel
end


local sw=tonumber(os.getenv("SCREEN_W")) or 1366
local sh=tonumber(os.getenv("SCREEN_H")) or 768
local ui=tonumber(os.getenv("UI_SCALE")) or 1
app.window.bounds={width=sw,height=sh}
app.uiScale=ui
local Rig=require("pixrig.rig")
local Store=require("pixrig.store")
local rig=Rig.new(32)
local hip=rig:addBone(32,5,32,25,0,false,"hips")
rig:addBone(32,25,32,42,hip.id,true,"leg")
Store.save(sprite,rig)
require("pixrig.ui").open()
local workspace=widgets.workspace.opts
assert(workspace.width*ui<=sw-70,"workspace is wider than the screen")
assert(workspace.height*ui<=sh-65,"workspace is taller than the screen")
local labels={}
local ctx={width=workspace.width,height=workspace.height}
setmetatable(ctx,{__index=function(_,method)
  if method=="fillText" then
    return function(_,value,x,y) labels[#labels+1]={text=value,x=x,y=y} end
  end
  return noop
end})
local function draw()
  labels={}
  workspace.onpaint({context=ctx})
end
local function locate(text)
  for _,t in ipairs(labels) do if t.text==text then return t end end
  return nil
end
draw()
assert(workspace.onwheel and workspace.onmousedown,"mouse events missing")
local bone=locate("Bone")
assert(bone,"Bone tab missing")
local event={x=bone.x+1,y=bone.y+1,button=MouseButton.LEFT}
workspace.onmousedown(event)
workspace.onmouseup(event)
draw()
local chain=locate("Chain +")
assert(chain and chain.y<workspace.height-22,
  "IK chain shortcut not visible in compact Bone tab")
print(string.format("layout ok: %dx%d at %dx%d UI scale %d; IK chain visible y=%d",workspace.width,workspace.height,sw,sh,ui,chain.y))
dialogs[1]:close()
