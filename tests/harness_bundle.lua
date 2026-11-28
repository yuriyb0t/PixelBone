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

local assertf=assert
local Rig=require("pixrig.rig")
local Store=require("pixrig.store")
local rig=Rig.new(16)
local hip=rig:addBone(16,6,16,9,0,false,"hip")
local thigh=rig:addBone(16,9,16,15,hip.id,true,"thigh")
rig:addBone(16,15,16,22,thigh.id,true,"shin")
assert(Store.save(sprite,rig))
dofile("dist/main.lua")
local commands={}
local plugin={newCommand=function(self, command) commands[command.id]=command end}
init(plugin)
assert(commands.PixelBoneOpen,"PixelBone command is missing")
assert(not commands.PixelBoneClassic,"Classic UI must not be registered")
assert(commands.PixelBoneOpen.onenabled(),"extension disabled on an open sprite")
commands.PixelBoneOpen.onclick()
local dlg=dialogs[1]
local cv=widgets["workspace"] and widgets["workspace"].opts
assert(cv,"workspace widget not registered")
assert(not widgets["tl"],"a separate timeline canvas was built")
local texts={}
local function ctx()
  local c={width=960,height=570}
  return setmetatable(c,{__index=function(self,key)
    if key=="fillText" then return function(_,t,x,y)
      texts[#texts+1]={t=t,x=x,y=y}
    end end
    return noop
  end})
end
local function repaint()
  texts={}
  cv.onpaint({context=ctx()})
end
local function textLocation(s,xmin,xmax)
  repaint()
  for _,e in ipairs(texts) do
    if e.t==s and (not xmin or e.x>=xmin) and (not xmax or e.x<xmax) then
      return e.x+1,e.y+1
    end
  end
  error("Button/label not displayed: "..s)
end
local function ev(x,y)
  return {x=x,y=y,button=MouseButton.LEFT,deltaY=1,shiftKey=false}
end
local function click(x,y)
  cv.onmousedown(ev(x,y)); cv.onmouseup(ev(x,y)); repaint()
end
local function clickText(s,xmin,xmax)
  local x,y=textLocation(s,xmin,xmax)
  click(x,y)
end
local function clickTextScrolled(s,xmin,xmax)
  for trial=1,32 do
    repaint()
    for _,entry in ipairs(texts) do
      if entry.t==s and (not xmin or entry.x>=xmin) and (not xmax or entry.x<xmax) then
        click(entry.x+1,entry.y+1)
        return
      end
    end
    cv.onwheel({x=100,y=300,deltaY=1})
  end
  error("Scrollable control not found: "..s)
end
local function drag(x1,y1,x2,y2)
  cv.onmousedown(ev(x1,y1))
  cv.onmousemove(ev(x2,y2))
  cv.onmouseup(ev(x2,y2))
  repaint()
end
local steps=0
local function step(name,f)
  steps=steps+1
  local ok,err=xpcall(f,debug.traceback)
  if not ok then print("FAILED ["..name.."]\n"..err); os.exit(1) end
end
step("initial UI draw",function()
  repaint()
  assertf(#texts>40, "expected owner-drawn controls")
  textLocation("PIXELBONE")
  textLocation("Play")
  textLocation("Rest")
  textLocation("Rig",0,330)
end)
step("tabs stay inside same canvas",function()
  for _,t in ipairs({"Bone","Groups","Paint","Animation","Poses","More","Rig"}) do
    clickText(t,0,330)
  end
  assert(#dialogs==1,"tab switching created a dialog")
end)
step("draw bone with right canvas",function()
  clickText("Bone",0,330)
  clickText("Draw bone")
  local before=#Store.load(sprite).bones
  drag(354,112,397,141)
  assert(#Store.load(sprite).bones>before,"bone not created")
end)
step("show pose and rest",function()
  clickText("Animate",330)
  clickText("Rest",330)
end)
step("timeline has rows and writes keys",function()
  -- click a bone row in the first visible row, then +Key
  click(332,444)
  local x,y=textLocation("+Key",330)
  click(x,y)
  local saved=Store.load(sprite)
  local a=saved:currentAnim()
  local count=0
  for _,ks in pairs(a.keys) do for _ in pairs(ks) do count=count+1 end end
  assert(count>0,"timeline did not save a key")
end)
step("paint sheet creation + refreshed preview",function()
  clickText("Paint",0,330)
  clickText("Generate new Paint Sheet")
  local found=false
  for _,layer in ipairs(sprite.layers) do
    if layer.isGroup and layer.name:match("PixRig Paint Sheet") then found=true end
  end
  assert(found,"paint sheet not added")
  clickText("Refresh artwork")
  clickText("Open Paint Sheet in Aseprite")
  assert(app.layer ~= nil,"opened paint sheet but didn't select its layer")
end)
step("end",function() dlg:close() end)
print("workspace harness ok: "..steps.." steps; dialogs="..#dialogs.."; warnings="..#warnings)
for _,w in ipairs(warnings) do print("warning: "..w) end
