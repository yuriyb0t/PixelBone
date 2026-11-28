-- Paint Sheet artwork binder for 0.8.
-- Each source layer stays editable in Aseprite; tags determine its binding:
--   'Body [bone group 1]' => nearest bone in group 1
--   'Hat [bone 12]'      => bone 12, irrespective of nearest bone
-- Nested groups may carry '[bone group N]' to let children keep simple names.
-- Never edits existing cels. Rebuilds binding from current frame-1 artwork.
local B = {}

local function groupId(name)
  return tonumber((name or ''):match('%[bone group (%d+)%]$'))
end
local function boneId(name)
  return tonumber((name or ''):match('%[bone (%d+)%]$'))
end

-- One active Paint Sheet: prefer the last found sheet, normally the newest.
-- We deliberately do not combine generations: this would double the sprite.
function B.activeSheet(sprite)
  local selected
  for _, layer in ipairs(sprite.layers) do
    if layer.isGroup and layer.name:match('^PixRig Paint Sheet') then selected = layer end
  end
  return selected
end

function B.sources(sprite, rig)
  local sheet = B.activeSheet(sprite)
  local groups = {}
  if not sheet then return groups end
  local function walk(layers, inherited)
    for _, layer in ipairs(layers) do
      if layer.isVisible ~= false then
        local gid = groupId(layer.name) or inherited
        if layer.isGroup then
          walk(layer.layers or {}, gid)
        else
          local forced = boneId(layer.name)
          local bone = forced and rig:get(forced) or nil
          if bone then gid = bone.group end
          -- Unknown explicit bone tags are ignored rather than silently
          -- attaching art to the wrong limb.
          if forced and not bone then gid = nil end
          if gid and gid > 0 and rig:getGroup(gid) then
            local cel = layer:cel(1)
            if cel and cel.image then
              local g = groups[gid]
              if not g then g = { layers = {}, sheet = sheet }; groups[gid] = g end
              local entry = {
                image = cel.image, position = cel.position,
                bone = bone and bone.id or nil, layer = layer,
                opacity = math.min(255, math.max(0, math.floor((cel.opacity or 255)*(layer.opacity or 255)/255))),
              }
              g.layers[#g.layers+1] = entry
              -- Compatibility with the 0.7 single-image preview shape.
              if not g.image then g.image, g.position = entry.image, entry.position end
            end
          end
        end
      end
    end
  end
  walk(sheet.layers or {}, nil)
  return groups
end

local function nearest(x, y, bones)
  local winner, best = nil, math.huge
  for _, b in ipairs(bones) do
    local dx, dy = b.bx-b.ax, b.by-b.ay
    local len = dx*dx + dy*dy
    local t = 0
    if len > 1e-9 then t = math.max(0,math.min(1,((x-b.ax)*dx+(y-b.ay)*dy)/len)) end
    local d = (x-b.ax-t*dx)^2 + (y-b.ay-t*dy)^2
    if d < best then best,winner = d,b end
  end
  return winner
end

local function srcAlpha(color, opacity)
  return math.floor(app.pixelColor.rgbaA(color) * (opacity or 255) / 255 + 0.5)
end

local function blend(image, x, y, color, opacity)
  if x < 0 or y < 0 or x >= image.width or y >= image.height then return end
  local pc = app.pixelColor
  local a = srcAlpha(color, opacity)
  if a == 0 then return end
  if a == 255 then image:putPixel(x, y, color); return end
  local dst = image:getPixel(x, y)
  local da = pc.rgbaA(dst)
  if da == 0 then
    image:putPixel(x, y, pc.rgba(pc.rgbaR(color),pc.rgbaG(color),pc.rgbaB(color),a))
    return
  end
  local out = a + da*(255-a)/255
  local function channel(fn)
    return math.floor((fn(color)*a + fn(dst)*da*(255-a)/255)/out+0.5)
  end
  image:putPixel(x,y,pc.rgba(channel(pc.rgbaR),channel(pc.rgbaG),channel(pc.rgbaB),math.floor(out+0.5)))
end

-- Combined original Paint Sheet preview (not transformed); uses every layer,
-- not just the first cel of each group. Sources stay intact and editable.
function B.restImage(sprite, rig, sources)
  local src = sources or B.sources(sprite,rig)
  if not next(src) then return nil end
  local target = Image(sprite.width,sprite.height)
  for _, group in ipairs(rig.groups) do
    local g = src[group.id]
    if g then
      for _, layer in ipairs(g.layers) do
        local im, pos = layer.image, layer.position
        for y=0,im.height-1 do
          for x=0,im.width-1 do
            local col=im:getPixel(x,y)
            if app.pixelColor.rgbaA(col)>0 then
              blend(target,x+pos.x,y+pos.y,col,layer.opacity)
            end
          end
        end
      end
    end
  end
  return target
end

function B.prepare(sprite, rig)
  local sources=B.sources(sprite,rig)
  local result={}
  for gid, group in pairs(sources) do
    local bones={}
    local byId={}
    for _,b in ipairs(rig.bones) do
      if b.group==gid then bones[#bones+1]=b; byId[b.id]=b end
    end
    if #bones>0 then
      local bound={layers={}}
      for _,src in ipairs(group.layers) do
        local one={order={},byBone={},opacity=src.opacity}
        local im,pos=src.image,src.position
        for y=0,im.height-1 do
          for x=0,im.width-1 do
            local color=im:getPixel(x,y)
            if app.pixelColor.rgbaA(color)>0 then
              local wx,wy=x+pos.x,y+pos.y
              local b=(src.bone and byId[src.bone]) or nearest(wx+0.5,wy+0.5,bones)
              if b then
                local e=one.byBone[b.id]
                if not e then
                  e={map={},minx=wx,maxx=wx,miny=wy,maxy=wy}
                  one.byBone[b.id]=e
                  one.order[#one.order+1]=b.id
                end
                e.map[(wy+4096)*8192+(wx+4096)]=color
                if wx<e.minx then e.minx=wx end
                if wx>e.maxx then e.maxx=wx end
                if wy<e.miny then e.miny=wy end
                if wy>e.maxy then e.maxy=wy end
              end
            end
          end
        end
        if #one.order>0 then
          table.sort(one.order)
          bound.layers[#bound.layers+1]=one
        end
      end
      if #bound.layers>0 then
        -- The single-layer fields are retained for 0.7 code/tests.
        bound.byBone=bound.layers[1].byBone
        bound.order=bound.layers[1].order
        result[gid]=bound
      end
    end
  end
  return result
end

function B.render(prepared,transforms,w,h)
  local result={}
  for gid,bound in pairs(prepared) do
    local im=Image(w,h)
    local entries=bound.layers or {bound}
    -- Respect Aseprite source-layer order: the later layer paints on top.
    for _,layer in ipairs(entries) do
      for _,id in ipairs(layer.order or {}) do
        local t,e=transforms[id],layer.byBone[id]
        if t and e then
          local x0,y0,x1,y1=math.huge,math.huge,-math.huge,-math.huge
          for _,cx in ipairs({e.minx,e.maxx+1}) do
            for _,cy in ipairs({e.miny,e.maxy+1}) do
              local X=t.c*cx-t.s*cy+t.tx
              local Y=t.s*cx+t.c*cy+t.ty
              x0,y0=math.min(x0,X),math.min(y0,Y)
              x1,y1=math.max(x1,X),math.max(y1,Y)
            end
          end
          x0,y0=math.max(0,math.floor(x0)),math.max(0,math.floor(y0))
          x1,y1=math.min(w-1,math.ceil(x1)),math.min(h-1,math.ceil(y1))
          for y=y0,y1 do
            for x=x0,x1 do
              local dx,dy=x+0.5-t.tx,y+0.5-t.ty
              local sx=math.floor(t.c*dx+t.s*dy)
              local sy=math.floor(-t.s*dx+t.c*dy)
              local color=e.map[(sy+4096)*8192+(sx+4096)]
              if color then blend(im,x,y,color,layer.opacity) end
            end
          end
        end
      end
    end
    result[gid]=im
  end
  return result
end
return B
