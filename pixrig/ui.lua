-- PixRig dialog: canvas with bone editing tools, skin groups and export.

local Rig = require("pixrig.rig")
local Store = require("pixrig.store")
local View = require("pixrig.view")
local Skin = require("pixrig.skin")
local Export = require("pixrig.export")
local Paint = require("pixrig.paint")
local Binding = require("pixrig.binding")
local Templates = require("pixrig.templates")

local M = {}

-- Single owner-drawn workspace.  Dialog:canvas and GraphicsContext are already
-- available on the user's Aseprite 1.3-rc4-dev; no native tabs or resize API.
local DEFAULT_W, DEFAULT_H = 960, 570
local LEFT_FRAC = 0.335

local HINTS = {
  create = "Create: drag to draw a bone. Start on a bone's tip to chain, on its body for a loose child. Shift = new root.",
  edit   = "Edit: drag a tip to move it, drag a bone's body to move it with its children.",
  link   = "Link: drag from a bone onto another bone to make it the parent (release on the tip to connect).",
  delete = "Delete: click a bone to delete it (children are kept).",
  radius = "Radius: drag a joint outward or inward to change the skin thickness there.",
  pose   = "Rotate: drag a bone. Assemble = permanent setup; Animate = a key on this frame.",
  ik     = "IK: drag the ring on a hand or foot. With a controller (IK tab) this moves the controller; without one the limb is bent directly.",
  move   = "Move: drag a bone. Assemble changes the setup; Animate writes a frame key. Shift = whole character.",
  select = "Select: click a bone to inspect it without changing the pose.",
  pan    = "Pan: drag to move the viewport. Mouse wheel zooms.",
}

local TOOLS = { "select", "create", "edit", "link", "delete", "radius", "pose", "ik", "move", "pan" }

local COL = {
  bg       = Color{ r = 34,  g = 34,  b = 38 },
  canvas   = Color{ r = 58,  g = 58,  b = 64 },
  border   = Color{ r = 120, g = 120, b = 130 },
  axis     = Color{ r = 255, g = 90,  b = 120, a = 160 },
  boneFill = Color{ r = 80,  g = 160, b = 255, a = 150 },
  boneLine = Color{ r = 190, g = 225, b = 255 },
  twinFill = Color{ r = 120, g = 220, b = 200, a = 170 },
  twinLine = Color{ r = 200, g = 255, b = 240 },
  selFill  = Color{ r = 255, g = 200, b = 60,  a = 190 },
  selLine  = Color{ r = 255, g = 240, b = 150 },
  ghost    = Color{ r = 255, g = 255, b = 255, a = 200 },
  text     = Color{ r = 235, g = 235, b = 240 },
  radius   = Color{ r = 255, g = 255, b = 255, a = 120 },
  tlCell   = Color{ r = 58,  g = 58,  b = 64 },
  tlCur    = Color{ r = 90,  g = 140, b = 220 },
  tlKey    = Color{ r = 200, g = 200, b = 210 },
  ikLine   = Color{ r = 255, g = 150, b = 60,  a = 220 },
}

local function ifloor(v) return math.floor(v + 0.5) end

local function line(ctx, x1, y1, x2, y2, color)
  ctx.color = color
  ctx.strokeWidth = 1
  ctx:beginPath()
  ctx:moveTo(x1, y1)
  ctx:lineTo(x2, y2)
  ctx:stroke()
end
local function circle(ctx, cx, cy, r, color)
  if r < 1 then return end
  ctx.color = color
  ctx.strokeWidth = 1
  ctx:beginPath()
  local n = 24
  for i = 0, n do
    local a = (i / n) * 2 * math.pi
    local x, y = cx + r * math.cos(a), cy + r * math.sin(a)
    if i == 0 then ctx:moveTo(x, y) else ctx:lineTo(x, y) end
  end
  ctx:stroke()
end

local function drawBone(ctx, v, b, fill, lineColor, showName)
  local ax, ay = v:toScreen(b.ax, b.ay)
  local bx, by = v:toScreen(b.bx, b.by)
  local dx, dy = bx - ax, by - ay
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 0.5 then return end
  local w = math.min(10, len * 0.18)
  local nx, ny = -dy / len, dx / len
  local mx, my = ax + dx * 0.15, ay + dy * 0.15

  ctx:beginPath()
  ctx:moveTo(ax, ay)
  ctx:lineTo(mx + nx * w, my + ny * w)
  ctx:lineTo(bx, by)
  ctx:lineTo(mx - nx * w, my - ny * w)
  ctx:closePath()
  ctx.color = fill
  ctx:fill()
  ctx.color = lineColor
  ctx.strokeWidth = 1
  ctx:stroke()

  ctx.color = lineColor
  ctx:fillRect(Rectangle(ifloor(bx) - 2, ifloor(by) - 2, 5, 5))
  if not b.connected then
    ctx:fillRect(Rectangle(ifloor(ax) - 2, ifloor(ay) - 2, 5, 5))
  end
  if showName then
    ctx.color = COL.text
    ctx:fillText(b.name, ifloor(bx) + 7, ifloor(by) - 5)
  end
end

local function drawRadii(ctx, v, b)
  local ax, ay = v:toScreen(b.ax, b.ay)
  local bx, by = v:toScreen(b.bx, b.by)
  circle(ctx, ax, ay, (b.ra or 0) * v.zoom, COL.radius)
  circle(ctx, bx, by, (b.rb or 0) * v.zoom, COL.radius)
end

function M.open()
  local sprite = app.sprite
  if not sprite then
    app.alert("Open a sprite first.")
    return
  end

  local rig = Store.load(sprite) or Rig.new(sprite.width / 2)

  local st = {
    tool = "create",
    sel = 0,
    drag = nil,
    view = View.new(),
    undo = {}, redo = {},
    snap = true, showSprite = true, showBones = true, showNames = false, autosave = true,
    showSkin = true, showRadii = false, curIk = nil, showArt = true, art = nil, artKey = nil, artImgs = nil, artRev = 0, ikBend = {},
    artRest = nil, artDirty = true, mode = "rest", panel = "Rig", scroll = {}, hits = {}, statusText = HINTS.create,
    img = nil, skinImg = nil, skinKey = nil,
    frame = 1, angleSnap = 0, playing = false, clip = nil, newIkChain = 2,
    onion = {on = false, back = 2, fwd = 1, art = false}, onionCache = {}, onionStamp = nil,
    cw = DEFAULT_W * (1 - LEFT_FRAC), ch = 320,
  }
  st.view:fit(st.cw, st.ch, sprite.width, sprite.height)

  local dlg, syncAnimUi, syncFrame, stopPlay, showTab, startPlay

  ------------------------------------------------------------------ helpers
  local function status(text)
    st.statusText = tostring(text or "")
    if dlg then dlg:repaint() end
  end

  local function repaint()
    if dlg then dlg:repaint() end
  end

  local function save(force)
    if not (force or st.autosave) then return end
    local ok, err = pcall(function()
      local good, msg = Store.save(sprite, rig)
      if not good then status(msg) end
    end)
    if not ok then status("Save failed: " .. tostring(err)) end
  end

  local function refreshImage()
    local ok, im = pcall(function()
      local img = Image(sprite.spec)
      local f = (app.frame and app.frame.frameNumber) or 1
      img:drawSprite(sprite, f)
      return img
    end)
    st.img = ok and im or nil
  end

  local function refreshSkin(bones, key)
    local w, h = sprite.width, sprite.height
    local res = Skin.render(rig, w, h, bones)
    local img = Image(w, h)
    local function paint(mask, c)
      local px = app.pixelColor.rgba(c.r, c.g, c.b, 255)
      for idx in pairs(mask) do
        local i = idx - 1
        img:putPixel(i % w, i // w, px)
      end
    end
    if res.outline then paint(res.outline, rig.outlineColor) end
    for _, g in ipairs(rig.groups) do paint(res.masks[g.id], g.color) end
    st.skinImg, st.skinKey = img, key
  end

  -- Re-read the Paint Sheet artwork and bind each pixel to its nearest bone.
  -- Returns true when there is artwork to preview.
  local function refreshArt()
    -- Aseprite remains the sole editor of original Paint Sheet pixels.
    local ok, art = pcall(Binding.prepare, sprite, rig)
    st.art = ok and art or nil
    st.artDirty = false
    st.artRev = (st.artRev or 0) + 1
    st.artKey, st.artImgs = nil, nil
    local okSrc, sources = pcall(Binding.sources, sprite, rig)
    st.artRest = nil
    if okSrc and sources and next(sources) then
      local success, im = pcall(Binding.restImage, sprite, rig, sources)
      if success then st.artRest = im end
    end
    -- First appearance of artwork makes it the default preview.  Respect a
    -- deliberate Show Capsules toggle later in the editing session.
    if st.artRest and not st.lastArtwork and not st.manualCapsules then
      st.showSkin = false
    end
    st.lastArtwork = st.artRest ~= nil
    return ok and art ~= nil and next(art) ~= nil
  end

  local function pushUndo(snapshot)
    st.undo[#st.undo + 1] = snapshot or rig:snapshot()
    if #st.undo > 100 then table.remove(st.undo, 1) end
    st.redo = {}
  end

  -- Aseprite 1.3-rc4-dev can crash when a combobox is modified from
  -- its own onchange handler. Use a stable label and navigation buttons.
  local function syncGroupUi()
    -- The active group's data is painted directly; no stale native widgets.
  end

  local function cycleGroup(step)
    local index = 1
    for i, g in ipairs(rig.groups) do
      if g.id == rig.activeGroup then index = i; break end
    end
    local n = #rig.groups
    if n == 0 then return end
    rig.activeGroup = rig.groups[((index - 1 + step) % n) + 1].id
    syncGroupUi()
    save()
    repaint()
  end

  ------------------------------------------------------------- IK helpers
  local function curIK()
    local ik = st.curIk and rig:getIK(st.curIk) or nil
    if not ik and rig.iks and rig.iks[1] then
      ik = rig.iks[1]
      st.curIk = ik.id
    end
    return ik
  end

  local function syncIkUi()
    -- Selection and IK data are read live by the custom left panel.
  end

  -- The enabled IK that drives a bone (and the bone's index in its chain).
  local function ikDriving(boneId)
    for _, ik in ipairs(rig.iks or {}) do
      if ik.enabled ~= false and (ik.influence or 1) > 0 then
        local chain = rig:ikResolve(ik)
        if chain then
          for i, b in ipairs(chain) do
            if b.id == boneId then return ik, i end
          end
        end
      end
    end
    return nil
  end

  local function syncSelection()
    if not rig:get(st.sel) then st.sel = 0 end
    local b = rig:get(st.sel)
    st.selectedInfo = "No bone selected"
    if b then
      local p = rig:get(b.parent)
      local g = rig:getGroup(b.group)
      st.selectedInfo = string.format("#%d  %s  /  parent: %s  /  group: %s", b.id,
        b.name, p and p.name or "none", g and g.name or "helper")
    end
    local ik = b and (rig:ikForTip(b.id) or rig:ikForTarget(b.id)) or nil
    if ik then st.curIk = ik.id end
    syncIkUi()
  end

  local function snapPt(x, y)
    if st.snap then return math.floor(x) + 0.5, math.floor(y) + 0.5 end
    return x, y
  end

  local function snapDelta(d)
    if st.snap then return ifloor(d) end
    return d
  end

  ------------------------------------------------------------ pose helpers
  local function curAnim() return rig:currentAnim() end

  local function clampFrame()
    local n = curAnim().frames
    if st.frame < 1 then st.frame = 1 end
    if st.frame > n then st.frame = n end
  end

  -- Display mode is independent of the left-panel tabs and selection tool.
  local function isPose()
    return st.mode ~= "rest" or st.playing
  end

  local function isAssemble()
    return st.mode == "assembly" and not st.playing
  end

  local function byId(list, id)
    for _, b in ipairs(list) do
      if b.id == id then return b end
    end
    return nil
  end

  -- Bones to draw / hit-test: rest bones, or the posed bones of the frame.
  local function currentBones()
    if not isPose() then return rig.bones end
    local a = curAnim()
    local key = rig.rev .. ":" .. (isAssemble() and "assembly" or (a.id .. ":" .. st.frame))
    if st.poseKey ~= key then
      if isAssemble() then
        st.posed, st.T = rig:assembledPose()
      else
        st.posed, st.T = rig:pose(a, st.frame)
      end
      st.poseKey = key
    end
    return st.posed
  end

  -- IK: solve the limb that ends at the tail of `lowerId` towards (x, y) and
  -- mirror the result onto the twin limb when mirror mode is on.
  local function ikApply(lowerId, x, y, bend)
    local a = curAnim()
    local ok, info = rig:solveIK(a, st.frame, lowerId, x, y, bend)
    if not ok then return false, info end
    if rig.mirror.enabled then
      local L, U = rig:get(lowerId), rig:get(info.upper)
      local tl = L and rig:twin(L)
      local tu = U and rig:twin(U)
      if tl and tu then
        rig:setKey(a, tu.id, st.frame, -info.rotU)
        rig:setKey(a, tl.id, st.frame, -info.rotL, 0, 0)
      end
    end
    return true, info
  end

  -- Start dragging a bone's offset (its children follow). The offset lives in the
  -- parent's frame, so remember the parent's rotation for the drag.
  local function boneMoveDrag(rb, x, y)
    local a = curAnim()
    local _, dx, dy
    if isAssemble() then
      _, dx, dy = rig:assemblyChannels(rb.id)
    else
      _, dx, dy = rig:channels(a, rb.id, st.frame)
    end
    local pc, ps = 1, 0
    if rb.parent ~= 0 then
      -- Lua's and/or expression collapses multiple return values.  Get the
      -- transform table as a second return value explicitly (PB-079).
      local _, T
      if isAssemble() then
        _, T = rig:assembledPose()
      else
        _, T = rig:pose(a, st.frame)
      end
      local pt = T and T[rb.parent] or nil
      if pt then pc, ps = pt.c, pt.s end
    end
    return {
      mode = "movebone", assemble = isAssemble(), boneId = rb.id, x0 = x, y0 = y, dx0 = dx, dy0 = dy,
      pc = pc, ps = ps, snapshot = rig:snapshot(), moved = false,
    }
  end

  ------------------------------------------------------------------- paint
  -- Onion skin: poses of neighbouring frames, cached until the rig or artwork changes.
  local ONION_MAX = 8
  local function onionStep(field, delta)
    local o = st.onion
    o[field] = math.max(0, math.min(ONION_MAX, (o[field] or 0) + delta))
    repaint()
  end
  local function onionActive()
    return st.onion.on and st.mode == "pose" and not st.playing
  end
  local function ghostFrame(a, f)
    local stamp = rig.rev .. ":" .. st.artRev .. ":" .. a.id
    if st.onionStamp ~= stamp then st.onionCache = {}; st.onionStamp = stamp end
    local g = st.onionCache[f]
    if not g then
      local okp, posed, T = pcall(rig.pose, rig, a, f)
      if not okp or not posed then return nil end
      g = {bones = posed, T = T}
      st.onionCache[f] = g
    end
    return g
  end
  -- Calls fn(ghost, isPast, distance) for every visible ghost frame, farthest first.
  local function eachGhost(fn)
    local a = curAnim()
    local o = st.onion
    for k = o.back, 1, -1 do
      local f = st.frame - k
      if f >= 1 and f <= a.frames then
        local g = ghostFrame(a, f)
        if g then fn(g, true, k) end
      end
    end
    for k = o.fwd, 1, -1 do
      local f = st.frame + k
      if f >= 1 and f <= a.frames then
        local g = ghostFrame(a, f)
        if g then fn(g, false, k) end
      end
    end
  end

  local function onpaint(ev)
    local ctx = ev.context
    local W, H = st.cw, st.ch
    local v = st.view
    local pose = isPose()
    local bones = currentBones()

    ctx.color = COL.bg
    ctx:fillRect(Rectangle(st.area.x, st.area.y, W, H))

    local x0, y0 = v:toScreen(0, 0)
    local sw, sh = sprite.width * v.zoom, sprite.height * v.zoom
    local dst = Rectangle(ifloor(x0), ifloor(y0), math.max(1, ifloor(sw)), math.max(1, ifloor(sh)))
    local src = Rectangle(0, 0, sprite.width, sprite.height)

    local artActive = st.showArt and ((pose and st.art ~= nil and next(st.art) ~= nil) or (not pose and st.artRest ~= nil))

    ctx.color = COL.canvas
    ctx:fillRect(dst)
    if st.showSprite and not artActive then
      if not st.img then refreshImage() end
      if st.img then ctx:drawImage(st.img, src, dst) end
    end
    if onionActive() and st.onion.art and st.showArt and st.art ~= nil and next(st.art) ~= nil then
      eachGhost(function(g, past, dist)
        if not g.imgs then
          local okr, imgs = pcall(Binding.render, st.art, g.T or {}, sprite.width, sprite.height)
          g.imgs = okr and imgs or false
        end
        if g.imgs then
          pcall(function() ctx.opacity = math.max(25, 110 - (dist - 1) * 30) end)
          for _, grp in ipairs(rig.groups) do
            local im = g.imgs[grp.id]
            if im then ctx:drawImage(im, src, dst) end
          end
          pcall(function() ctx.opacity = 255 end)
        end
      end)
    end
    if st.showSkin then
      local key = rig.rev .. ":" .. (pose and (isAssemble() and "assembly" or (curAnim().id .. ":" .. st.frame)) or "rest")
      if not st.skinImg or st.skinKey ~= key then refreshSkin(bones, key) end
      pcall(function() ctx.opacity = artActive and 65 or 190 end)
      ctx:drawImage(st.skinImg, src, dst)
      pcall(function() ctx.opacity = 255 end)
    end
    if artActive and not pose and st.artRest then
      ctx:drawImage(st.artRest, src, dst)
    elseif artActive and pose then
      local a = curAnim()
      local key = rig.rev .. ":" .. (isAssemble() and "assembly" or (a.id .. ":" .. st.frame)) .. ":" .. st.artRev
      if st.artKey ~= key then
        local okr, imgs = pcall(Binding.render, st.art, st.T or {}, sprite.width, sprite.height)
        st.artImgs = okr and imgs or nil
        st.artKey = key
      end
      if st.artImgs then
        for _, g in ipairs(rig.groups) do
          local im = st.artImgs[g.id]
          if im then ctx:drawImage(im, src, dst) end
        end
      end
    end
    ctx.color = COL.border
    ctx.strokeWidth = 1
    ctx:strokeRect(dst)

    if rig.mirror.enabled and not pose then
      local ax = v:toScreen(rig.mirror.axisX, 0)
      line(ctx, ax, st.area.y, ax, st.area.y + H, COL.axis)
    end

    local selBone = byId(bones, st.sel)
    local restSel = rig:get(st.sel)
    local restTwin = restSel and rig:twin(restSel) or nil
    local selTwin = restTwin and byId(bones, restTwin.id) or nil

    if onionActive() then
      eachGhost(function(g, past, dist)
        local al = math.max(50, 190 - (dist - 1) * 45)
        local rgb = past and {255, 110, 110} or {110, 230, 130}
        local fill = Color{ r = rgb[1], g = rgb[2], b = rgb[3], a = math.floor(al / 3) }
        local edge = Color{ r = rgb[1], g = rgb[2], b = rgb[3], a = al }
        for _, b in ipairs(g.bones) do drawBone(ctx, v, b, fill, edge, false) end
      end)
    end

    if st.showBones then
    for _, b in ipairs(bones) do
      if selBone and b.id == selBone.id then
        -- drawn last
      elseif selTwin and b.id == selTwin.id then
        drawBone(ctx, v, b, COL.twinFill, COL.twinLine, true)
      else
        drawBone(ctx, v, b, COL.boneFill, COL.boneLine, st.showNames)
      end
    end
    if selBone then drawBone(ctx, v, selBone, COL.selFill, COL.selLine, true) end
    end

    -- IK: a line from each limb tip to its controller, and a ring on controllers
    for _, ik in ipairs(rig.iks or {}) do
      local pt, pg = byId(bones, ik.tip), byId(bones, ik.target)
      if pt and pg then
        local sx, sy = v:toScreen(pt.bx, pt.by)
        local gx, gy = v:toScreen(pg.ax, pg.ay)
        line(ctx, sx, sy, gx, gy, COL.ikLine)
        circle(ctx, gx, gy, 5, COL.ikLine)
      end
    end

    if st.showBones and st.tool == "ik" then
      local hasChild = {}
      for _, rb in ipairs(rig.bones) do
        if rb.parent ~= 0 then hasChild[rb.parent] = true end
      end
      for _, b in ipairs(bones) do
        local rb = rig:get(b.id)
        if rb and rb.parent ~= 0 and rb.connected and not hasChild[rb.id] then
          local sx, sy = v:toScreen(b.bx, b.by)
          circle(ctx, sx, sy, 7, COL.selLine)
        end
      end
    end

    if not pose and st.showBones then
      if st.showRadii or st.tool == "radius" then
        for _, b in ipairs(bones) do drawRadii(ctx, v, b) end
      elseif selBone then
        drawRadii(ctx, v, selBone)
      end
    end

    local d = st.drag
    if d and d.mode == "create" then
      local sx, sy = v:toScreen(d.ax, d.ay)
      local ex, ey = v:toScreen(d.cx, d.cy)
      line(ctx, sx, sy, ex, ey, COL.ghost)
    elseif d and d.mode == "link" then
      local b = rig:get(d.boneId)
      if b then
        local sx, sy = v:toScreen((b.ax + b.bx) / 2, (b.ay + b.by) / 2)
        local ex, ey = v:toScreen(d.cx, d.cy)
        line(ctx, sx, sy, ex, ey, COL.ghost)
      end
    end
  end

  ------------------------------------------------------------------- mouse
  local function onmousedown(ev)
    local v = st.view
    if ev.button == MouseButton.MIDDLE or ev.button == MouseButton.RIGHT or ev.spaceKey or st.tool == "pan" then
      st.drag = { mode = "pan", sx = ev.x, sy = ev.y, ox = v.ox, oy = v.oy }
      return
    end
    if ev.button ~= MouseButton.LEFT then return end
    if st.playing then return end

    local x, y = v:toRig(ev.x, ev.y)
    local tol = 8 / v.zoom
    local tool = st.tool

    if tool == "select" then
      local b = rig:hit(x, y, tol, currentBones())
      st.sel = b and b.id or 0
      syncSelection()
      repaint()
      return
    elseif tool == "pose" then
      local pb = rig:hit(x, y, tol, currentBones())
      if pb then
        st.sel = pb.id
        syncSelection()
        st.drag = { mode = "rotate", assemble = isAssemble(), boneId = pb.id,
                    snapshot = rig:snapshot(), moved = false }
        local ik = not isAssemble() and ikDriving(pb.id) or nil
        if ik then
          status("This bone is driven by IK (" .. ik.name .. "): move its controller, or disable the IK to pose it by hand.")
        end
      else
        st.sel = 0
        syncSelection()
      end
      repaint()
      return

    elseif tool == "ik" then
      local pb = rig:hit(x, y, tol, currentBones())
      local rb = pb and rig:get(pb.id) or nil
      if rb then
        st.sel = rb.id
        syncSelection()
        local ctl = rig:ikForTip(rb.id) or rig:ikForTarget(rb.id)
        local ctlBone = ctl and rig:get(ctl.target) or nil
        if ctlBone then
          -- A controller exists: dragging moves it, and the limb follows.
          st.drag = boneMoveDrag(ctlBone, x, y)
        elseif rb.parent ~= 0 and rb.connected then
          local side = rig:ikBendSide(curAnim(), st.frame, rb.id)
          if side then st.ikBend[rb.id] = side end
          st.drag = {
            mode = "ik", boneId = rb.id, bend = st.ikBend[rb.id] or 1,
            snapshot = rig:snapshot(), moved = false,
          }
        else
          status("IK bends a connected limb (a shin / forearm). To move the body, switch to the Move tool.")
        end
      else
        st.sel = 0
        syncSelection()
      end
      repaint()
      return

    elseif tool == "move" then
      local pb = rig:hit(x, y, tol, currentBones())
      local rb = pb and rig:get(pb.id) or nil
      if rb then
        st.sel = pb.id
        syncSelection()
        if ev.shiftKey then
          -- Shift: move the whole character (the root bone's offset).
          local root = rig:rootOf(rb)
          local _, dx, dy
          if isAssemble() then
            _, dx, dy = rig:assemblyChannels(root.id)
          else
            _, dx, dy = rig:channels(curAnim(), root.id, st.frame)
          end
          st.drag = {
            mode = "movechar", assemble = isAssemble(), rootId = root.id, x0 = x, y0 = y, dx0 = dx, dy0 = dy,
            snapshot = rig:snapshot(), moved = false,
          }
        else
          -- Move just this bone (its children follow).
          st.drag = boneMoveDrag(rb, x, y)
          local ik, idx = ikDriving(rb.id)
          if ik and idx >= 2 then
            status("This bone is driven by IK (" .. ik.name .. "): move its controller instead.")
          end
        end
      end
      repaint()
      return
    end

    local b, part = rig:hit(x, y, tol)

    if tool == "create" then
      local px, py = snapPt(x, y)
      local parent, connected = 0, false
      if b and not ev.shiftKey then
        parent = b.id
        if part == "tail" then
          px, py, connected = b.bx, b.by, true
        elseif part == "head" then
          px, py = b.ax, b.ay
        end
      end
      st.drag = {
        mode = "create", ax = px, ay = py, cx = px, cy = py,
        parent = parent, connected = connected, snapshot = rig:snapshot(),
      }

    elseif tool == "edit" then
      if b then
        st.sel = b.id
        syncSelection()
        st.drag = {
          mode = "move", boneId = b.id, part = part,
          x0 = x, y0 = y, appliedX = 0, appliedY = 0,
          snapshot = rig:snapshot(), moved = false,
        }
      else
        st.sel = 0
        syncSelection()
      end

    elseif tool == "link" then
      if b then
        st.sel = b.id
        syncSelection()
        st.drag = { mode = "link", boneId = b.id, cx = x, cy = y }
      end

    elseif tool == "delete" then
      if b then
        pushUndo()
        rig:delete(b)
        syncSelection()
        save()
      end

    elseif tool == "radius" then
      if b and (part == "head" or part == "tail") then
        st.sel = b.id
        syncSelection()
        local jx, jy = b.ax, b.ay
        local r0 = b.ra or 0
        if part == "tail" then jx, jy, r0 = b.bx, b.by, (b.rb or 0) end
        st.drag = {
          mode = "radius", boneId = b.id, part = part, r0 = r0,
          dist0 = math.sqrt((x - jx) ^ 2 + (y - jy) ^ 2),
          snapshot = rig:snapshot(), moved = false,
        }
      end
    end
    repaint()
  end

  local function onmousemove(ev)
    local d = st.drag
    if not d then return end
    local v = st.view

    if d.mode == "pan" then
      v.ox = d.ox + (ev.x - d.sx)
      v.oy = d.oy + (ev.y - d.sy)

    elseif d.mode == "create" then
      local x, y = v:toRig(ev.x, ev.y)
      d.cx, d.cy = snapPt(x, y)

    elseif d.mode == "move" then
      local b = rig:get(d.boneId)
      if b then
        local x, y = v:toRig(ev.x, ev.y)
        if d.part == "body" then
          local tx, ty = snapDelta(x - d.x0), snapDelta(y - d.y0)
          local ddx, ddy = tx - d.appliedX, ty - d.appliedY
          if ddx ~= 0 or ddy ~= 0 then
            rig:translate(b, ddx, ddy)
            d.appliedX, d.appliedY = tx, ty
            d.moved = true
          end
        else
          local px, py = snapPt(x, y)
          local cx, cy = b.ax, b.ay
          if d.part == "tail" then cx, cy = b.bx, b.by end
          if px ~= cx or py ~= cy then
            rig:setPoint(b, d.part, px, py)
            d.moved = true
          end
        end
      end

    elseif d.mode == "radius" then
      local b = rig:get(d.boneId)
      if b then
        local x, y = v:toRig(ev.x, ev.y)
        local jx, jy = b.ax, b.ay
        if d.part == "tail" then jx, jy = b.bx, b.by end
        local dist = math.sqrt((x - jx) ^ 2 + (y - jy) ^ 2)
        local r = math.max(0, d.r0 + dist - d.dist0)
        if st.snap then r = math.floor(r * 2 + 0.5) / 2 end
        rig:setRadius(b, d.part, r)
        d.moved = true
      end

    elseif d.mode == "rotate" then
      local rb = rig:get(d.boneId)
      if rb then
        local a = curAnim()
        -- Preserve both results of Rig:pose / Rig:assembledPose.
        -- `condition and fn() or fn()` would discard T and crash on drag.
        local posed, T
        if d.assemble then
          posed, T = rig:assembledPose()
        else
          posed, T = rig:pose(a, st.frame)
        end
        local pbone = byId(posed, rb.id)
        if pbone then
          local x, y = v:toRig(ev.x, ev.y)
          local ang = math.deg(math.atan(y - pbone.ay, x - pbone.ax))
          local restAng = math.deg(math.atan(rb.by - rb.ay, rb.bx - rb.ax))
          local pt = rb.parent ~= 0 and T and T[rb.parent] or nil
          local parentAng = (rb.parent ~= 0 and pt) and math.deg(math.atan(pt.s, pt.c)) or 0
          local totalRot = (ang - restAng - parentAng + 180) % 360 - 180
          local assemblyRot = rig:assemblyChannels(rb.id)
          local rot = d.assemble and totalRot or ((totalRot - assemblyRot + 180) % 360 - 180)
          if st.angleSnap > 0 then rot = math.floor(rot / st.angleSnap + 0.5) * st.angleSnap end
          if d.assemble then
            rig:setAssembly(rb.id,rot)
          else
            rig:setKey(a,rb.id,st.frame,rot)
            if rig.mirror.enabled then
              local tw=rig:twin(rb)
              if tw then rig:setKey(a,tw.id,st.frame,-rot) end
            end
          end
          d.moved=true
        end
      end

    elseif d.mode == "ik" then
      local x, y = v:toRig(ev.x, ev.y)
      local ok, err = ikApply(d.boneId, x, y, d.bend)
      if ok then d.moved = true else status(err) end

    elseif d.mode == "movechar" then
      local x, y = v:toRig(ev.x, ev.y)
      local ddx, ddy = x - d.x0, y - d.y0
      if st.snap then ddx, ddy = ifloor(ddx), ifloor(ddy) end
      if d.assemble then
        rig:setAssembly(d.rootId,nil,d.dx0+ddx,d.dy0+ddy)
      else
        rig:setKey(curAnim(),d.rootId,st.frame,nil,d.dx0+ddx,d.dy0+ddy)
      end
      d.moved = true

    elseif d.mode == "movebone" then
      local x, y = v:toRig(ev.x, ev.y)
      local ddx, ddy = x - d.x0, y - d.y0
      if st.snap then ddx, ddy = ifloor(ddx), ifloor(ddy) end
      -- screen delta -> the parent's local frame (inverse rotation)
      local lx = d.pc * ddx + d.ps * ddy
      local ly = -d.ps * ddx + d.pc * ddy
      if d.assemble then
        rig:setAssembly(d.boneId,nil,d.dx0+lx,d.dy0+ly)
      else
        local a=curAnim()
        rig:setKey(a,d.boneId,st.frame,nil,d.dx0+lx,d.dy0+ly)
        if rig.mirror.enabled then
          local b=rig:get(d.boneId)
          local tw=b and rig:twin(b)
          if tw then rig:setKey(a,tw.id,st.frame,nil,-(d.dx0+lx),d.dy0+ly) end
        end
      end
      d.moved = true

    elseif d.mode == "link" then
      d.cx, d.cy = v:toRig(ev.x, ev.y)
    end
    repaint()
  end

  local function onmouseup(ev)
    local d = st.drag
    st.drag = nil
    if not d then return end
    local v = st.view

    if d.mode == "create" then
      local len = math.sqrt((d.cx - d.ax) ^ 2 + (d.cy - d.ay) ^ 2)
      if len >= 0.9 then
        pushUndo(d.snapshot)
        local nb = rig:addBone(d.ax, d.ay, d.cx, d.cy, d.parent, d.connected)
        st.sel = nb.id
        syncSelection()
        save()
      end

    elseif d.mode == "move" or d.mode == "radius" or d.mode == "rotate" or d.mode == "movechar" or d.mode == "movebone" or d.mode == "ik" then
      if d.moved then
        pushUndo(d.snapshot)
        syncSelection()
        save()
      end

    elseif d.mode == "link" then
      local x, y = v:toRig(ev.x, ev.y)
      local target, part = rig:hit(x, y, 8 / v.zoom)
      local child = rig:get(d.boneId)
      if child and target and target.id ~= child.id then
        local snap = rig:snapshot()
        if rig:setParent(child, target.id, part == "tail") then
          pushUndo(snap)
          syncSelection()
          save()
        else
          status("Can't link: that would create a loop.")
        end
      end
    end
    repaint()
  end

  local function onwheel(ev)
    local f = (ev.deltaY < 0) and 1.25 or 0.8
    st.view:zoomAt(ev.x, ev.y, f)
    repaint()
  end

  ---------------------------------------------------------------- actions
  local function afterEdit()
    syncSelection()
    syncGroupUi()
    if syncAnimUi then syncAnimUi() end
    if syncFrame then syncFrame() end
    save()
    repaint()
  end

  local function doUndo()
    local s = table.remove(st.undo)
    if not s then return end
    st.redo[#st.redo + 1] = rig:snapshot()
    rig:restore(s)
    afterEdit()
  end

  local function doRedo()
    local s = table.remove(st.redo)
    if not s then return end
    st.undo[#st.undo + 1] = rig:snapshot()
    rig:restore(s)
    afterEdit()
  end

  local function setTool(name)
    if st.playing and stopPlay then stopPlay() end
    st.tool = name
    st.drag = nil
    if name == "pose" or name == "move" then
      -- Rotate/Move keep Assembly active when editing the initial layout.
      if st.mode ~= "assembly" then st.mode = "pose" end
      if st.artDirty then refreshArt() end
    elseif name == "ik" then
      st.mode = "pose"
      if st.artDirty then refreshArt() end
    elseif name == "create" or name == "edit" or name == "link" or
      name == "delete" or name == "radius" then
      st.mode = "rest"
    end
    status(HINTS[name] or name)
    repaint()
  end

  -- Apply a change to the current IK (and to its mirrored twin when mirror is on).
  local function ikChange(fields)
    local ik = curIK()
    if not ik then
      status("No IK yet: select a hand / foot bone and press Add controller.")
      return false
    end
    local snap = rig:snapshot()
    local ok, why = rig:updateIK(ik, fields)
    if not ok then
      status(why)
      return false
    end
    local tk = rig.mirror.enabled and rig:twinIK(ik) or nil
    if tk then
      local tf = {}
      for k, v in pairs(fields) do tf[k] = v end
      if tf.bend then tf.bend = -tf.bend end
      rig:updateIK(tk, tf)
    end
    pushUndo(snap)
    afterEdit()
    return true
  end

  -- Chain length is *number of bones*, not IK influence (%).  The shortcut
  -- stays near the top of the Bone panel, even when Inspector is long.
  -- Before an IK exists it configures the next controller (1..8).
  local function stepIkChain(step)
    local ik = curIK()
    if ik then
      local before = math.max(1, math.min(8, math.floor(tonumber(ik.chain) or 2)))
      local value = math.max(1, math.min(8, before + step))
      if value ~= before then
        ikChange({ chain = value })
      else
        status("IK chain length is limited to 1..8 bones.")
      end
    else
      st.newIkChain = math.max(1, math.min(8, (st.newIkChain or 2) + step))
      status("New IK controller will affect " .. st.newIkChain .. " bone(s).")
    end
  end

  local function cycleIk(step)
    local n = #(rig.iks or {})
    if n == 0 then
      status("No IK yet: select a hand / foot bone and press Add controller.")
      return
    end
    local idx = 1
    for i, k in ipairs(rig.iks) do
      if k.id == st.curIk then idx = i; break end
    end
    local ik = rig.iks[((idx - 1 + step) % n) + 1]
    st.curIk = ik.id
    st.sel = ik.tip
    syncSelection()
    repaint()
  end

  -- Select the hand / foot bone, press Add controller: a helper bone appears at
  -- its tip and the limb follows it (with mirror on, the other limb too).
  local function addController()
    local rb = rig:get(st.sel)
    if not rb then
      status("Select the hand / foot bone (the tip of the limb) first.")
      return
    end
    local bend = rig:ikBendSide(curAnim(), st.frame, rb.id) or 1
    local snap = rig:snapshot()
    -- Place the controller at the tip's current position (Animate) or at the
    -- assembly position (Assemble), so creating it never snaps the limb.
    local a, f
    if isAssemble() then
      a, f = nil, 1
    else
      a, f = curAnim(), st.frame
    end
    local want = st.newIkChain or 2
    local ik, ctl = rig:addController(rb.id, want, bend, a, f)
    if not ik then
      status(ctl)
      return
    end
    pushUndo(snap)
    st.curIk = ik.id
    setTool("ik")
    if showTab then showTab("Bone") end
    afterEdit()
    local chain, _, stop = rig:ikResolve(ik)
    local n = chain and #chain or 0
    local msg = "Controller '" .. ctl.name .. "' created: " .. n .. " bone" .. (n == 1 and "" or "s") .. "."
    if n < want then
      msg = msg .. " Only " .. n .. " of " .. want .. " requested bones are usable (" ..
        (stop == "branch" and "the next joint is a branch point" or
         stop == "disconnected" and "the next bone is not connected" or
         stop == "root" and "the chain reached the root" or "the limb is shorter") .. ")."
    end
    status(msg .. " Drag the ring with IK, or move the body with the Move tool.")
  end

  local function deleteIk()
    local ik = curIK()
    if not ik then return end
    local snap = rig:snapshot()
    local tk = rig.mirror.enabled and rig:twinIK(ik) or nil
    rig:deleteIK(ik.id)
    if tk then rig:deleteIK(tk.id) end
    st.curIk = nil
    pushUndo(snap)
    afterEdit()
    status("IK deleted (the controller bone is kept; delete it with the Delete tool).")
  end

  local function setIkBone(field)
    local rb = rig:get(st.sel)
    if not rb then
      status("Select a bone first.")
      return
    end
    local ik = curIK()
    if not ik then
      status("No IK yet.")
      return
    end
    if field == "tip" and (rb.parent == 0 or not rb.connected) then
      status("The tip must be connected to its parent.")
      return
    end
    ikChange({ [field] = rb.id })
  end

  -- Swap the elbow / knee side: of the selected limb's IK if it has one,
  -- otherwise of a quick (rotation-key) IK pose, keeping the hand / foot.
  local function flipBend()
    local rb = rig:get(st.sel)
    local ik = rb and (rig:ikForTip(rb.id) or rig:ikForTarget(rb.id)) or curIK()
    if ik then
      st.curIk = ik.id
      if (ik.chain or 2) ~= 2 then
        status("Flip bend only applies to chains of two bones.")
        return
      end
      ikChange({ bend = -(ik.bend or 1) })
      return
    end
    if not rb or rb.parent == 0 or not rb.connected then
      status("Flip bend: select a forearm / shin bone (connected to its parent) first.")
      return
    end
    if not isPose() then setTool("ik") end
    local a = curAnim()
    local side = rig:ikBendSide(a, st.frame, rb.id) or st.ikBend[rb.id] or 1
    local nb = -side
    local posed = rig:pose(a, st.frame, true)
    local pb = byId(posed, rb.id)
    if not pb then return end
    local snap = rig:snapshot()
    local ok, err = ikApply(rb.id, pb.bx, pb.by, nb)
    if ok then
      st.ikBend[rb.id] = nb
      pushUndo(snap)
      afterEdit()
    else
      status(err)
    end
  end

  local KEYTOOL = { c = "create", e = "edit", l = "link", d = "delete", r = "radius",
                    p = "pose", i = "ik", m = "move",
                    ["1"] = "create", ["2"] = "edit", ["3"] = "link", ["4"] = "delete", ["5"] = "radius",
                    ["6"] = "pose", ["7"] = "move" }
  local function onkeydown(ev)
    local k = tostring(ev.code or ev.key or ""):lower()
    k = (k:gsub("^key", ""):gsub("^digit", ""))
    if ev.ctrlKey and k == "z" then
      if ev.shiftKey then doRedo() else doUndo() end
    elseif ev.ctrlKey and k == "y" then
      doRedo()
    elseif not ev.ctrlKey and KEYTOOL[k] then
      setTool(KEYTOOL[k])
    end
  end

  ---------------------------------------------------------------- workspace
  -- All three work areas live inside this ONE canvas widget.  The standard
  -- Dialog row layout cannot put a scrolling settings panel beside a canvas
  -- and a grid timeline on 1.3-rc4-dev; owner drawing avoids that limitation.
  -- Text/color editors use short-lived *native* dialogs for safe input only.
  local function workspaceSize()
    local w, h = DEFAULT_W, DEFAULT_H
    pcall(function()
      local b = app.window and app.window.bounds
      if b and b.width and b.height then
        local s = math.max(1, tonumber(app.uiScale) or 1)
        -- Leave room for the Aseprite chrome, dialog borders and taskbar.
        w = math.max(560, math.min(1020, math.floor((b.width - 145) / s)))
        h = math.max(330, math.min(625, math.floor((b.height - 145) / s)))
      end
    end)
    return w, h
  end
  local UI_W, UI_H = workspaceSize()
  local LEFT_W = math.floor(UI_W * LEFT_FRAC)
  local RIGHT_X = LEFT_W + 1
  local FOOT_Y = UI_H - 22
  local TL_Y = UI_H - math.max(145, math.floor(UI_H * 0.28)) - 24
  local AREA = { x = RIGHT_X + 8, y = 44, w = UI_W - RIGHT_X - 16,
                 h = TL_Y - 52 }
  local TL = { x = RIGHT_X + 2, y = TL_Y, w = UI_W - RIGHT_X - 4,
               h = FOOT_Y - TL_Y - 2 }
  st.area = AREA
  st.cw, st.ch = AREA.w, AREA.h
  st.view:fit(st.cw, st.ch, sprite.width, sprite.height)
  -- View includes the absolute offset of the scene, not a translated GC.
  st.view.ox = st.view.ox + AREA.x
  st.view.oy = st.view.oy + AREA.y
  st.timelineOffset, st.boneOffset = 1, 0
  st.poseSlots = {}
  st.slotNumber = 0
  st.focusArea = nil
  st.cursorX, st.cursorY = 0, 0

  local UI = {
    bg = Color{r=26,g=27,b=32}, sidebar=Color{r=34,g=35,b=42},
    panel=Color{r=44,g=45,b=53}, panelHi=Color{r=59,g=60,b=69},
    border=Color{r=72,g=75,b=85}, text=Color{r=218,g=222,b=229},
    quiet=Color{r=150,g=156,b=169}, accent=Color{r=236,g=207,b=92},
    accentDark=Color{r=88,g=79,b=48}, blue=Color{r=92,g=145,b=211},
    row=Color{r=38,g=40,b=48}, rowAlt=Color{r=47,g=49,b=57},
    key=Color{r=218,g=219,b=227}, selected=Color{r=68,g=91,b=123},
    checker1=Color{r=89,g=89,b=96}, checker2=Color{r=105,g=105,b=112},
  }
  local TABS = {"Rig", "Bone", "Groups", "Paint", "Animation", "Onion", "Poses", "More"}
  local function within(x, y, r)
    return r and x >= r.x and y >= r.y and x < r.x+r.w and y < r.y+r.h
  end
  local function rect(ctx, x, y, w, h, color)
    if w < 1 or h < 1 then return end
    ctx.color = color
    ctx:fillRect(Rectangle(math.floor(x), math.floor(y), math.floor(w), math.floor(h)))
  end
  local function stroke(ctx, x, y, w, h, color)
    if w < 1 or h < 1 then return end
    ctx.color = color
    ctx.strokeWidth = 1
    ctx:strokeRect(Rectangle(math.floor(x),math.floor(y),math.floor(w),math.floor(h)))
  end
  local function txt(ctx, s, x, y, color)
    ctx.color = color or UI.text
    ctx:fillText(tostring(s), math.floor(x), math.floor(y))
  end
  local function short(s, max)
    s = tostring(s or "")
    local n = math.max(1, math.floor(max / 7))
    if #s > n then return s:sub(1, math.max(1,n-3)) .. "..." end
    return s
  end
  local function hit(x,y,w,h,action)
    -- Only register visible, non-scrolled widgets as interactive.
    if action then st.hits[#st.hits + 1] = {x=x,y=y,w=w,h=h,action=action} end
  end
  local function button(ctx, text, x, y, w, h, action, selected, disabled)
    local hover = within(st.cursorX,st.cursorY,{x=x,y=y,w=w,h=h})
    local fill = selected and UI.accentDark or (hover and UI.panelHi or UI.panel)
    if disabled then fill = UI.bg end
    rect(ctx,x,y,w,h,fill)
    stroke(ctx,x,y,w,h, selected and UI.accent or UI.border)
    txt(ctx,short(text,w-10),x+5,y+math.max(2,(h-13)/2),
        disabled and UI.quiet or (selected and UI.accent or UI.text))
    if not disabled then hit(x,y,w,h,action) end
  end
  local function checkbox(ctx,text,x,y,w,on,action)
    rect(ctx,x,y+3,11,11,on and UI.accent or UI.panelHi)
    stroke(ctx,x,y+3,11,11,UI.border)
    if on then txt(ctx,"x",x+2,y+1,UI.bg) end
    txt(ctx,short(text,w-20),x+17,y+1,UI.text)
    hit(x,y,w,18,action)
  end
  local function divider(ctx,label,x,y,w)
    txt(ctx,label,x,y+1,UI.accent)
    line(ctx,x,y+20,x+w,y+20,UI.border)
  end
  local function prompt(kind,title,initial,callback)
    local edit = Dialog{title="PixelBone - " .. title}
    if not edit then status("Native input dialog is not available."); return end
    if kind == "number" then
      edit:number{id="value",text=tostring(initial),decimals=2}
    elseif kind == "color" then
      edit:color{id="value",color=initial}
    else
      edit:entry{id="value",text=tostring(initial or "")}
    end
    edit:button{text="Apply",onclick=function()
      local value = edit.data.value
      local ok, err = pcall(callback,value)
      if not ok then status("Input error: " .. tostring(err)) end
      edit:close()
      repaint()
    end}
    edit:button{text="Cancel",onclick=function() edit:close() end}
    edit:show{wait=false}
  end
  local function pickColor(title, c, apply)
    prompt("color",title,Color{r=c.r,g=c.g,b=c.b},function(color)
      if color then apply({r=color.red,g=color.green,b=color.blue}) end
    end)
  end
  local function setMode(mode)
    if st.playing and stopPlay then stopPlay() end
    st.mode = mode
    if mode == "rest" then
      if st.tool == "pose" or st.tool == "ik" or st.tool == "move" then
        st.tool = "select"
      end
    elseif mode == "assembly" or mode == "pose" then
      -- Entering an animation mode always enables a visible FK Rotate tool.
      st.tool = "pose"
    end
    status(mode=="assembly" and "ASSEMBLY: Move/Rotate sets the initial character layout (no timeline keys)." or
      mode=="pose" and "ANIMATE: Move/Rotate writes keys on the selected timeline frame." or
      "REST: edit the separated bones; the Paint Sheet stays in these coordinates.")
    if st.artDirty then refreshArt() end
    repaint()
  end
  showTab = function(name)
    st.panel = name
    repaint()
  end
  local function setFrame(frame)
    local n = curAnim().frames
    st.frame = math.max(1,math.min(n,math.floor(tonumber(frame) or 1)))
    if syncFrame then syncFrame() end
  end
  local function copyPose()
    local a = curAnim()
    st.clip = {}
    for _, b in ipairs(rig.bones) do
      local r, dx, dy = rig:channels(a,b.id,st.frame)
      st.clip[b.id] = {r,dx,dy}
    end
    status("Copied pose from frame " .. st.frame)
  end
  local function pastePose()
    if isAssemble() then status("Switch to Animate to paste a frame pose."); return end
    if not st.clip then status("Copy a pose first."); return end
    pushUndo()
    local a = curAnim()
    for id,v in pairs(st.clip) do
      if rig:get(id) then rig:setKey(a,id,st.frame,v[1],v[2],v[3]) end
    end
    afterEdit()
  end
  local function keyFrame(delete)
    if isAssemble() then status("Assembly is independent of frames. Switch to Animate to edit keys."); return end
    local a = curAnim()
    if delete then
      if st.sel == 0 or not rig:hasKey(a,st.sel,st.frame) then
        status("Select a bone with a key on this frame."); return
      end
      pushUndo()
      rig:deleteKey(a,st.sel,st.frame)
    else
      if #rig.bones == 0 then status("Create a skeleton first."); return end
      pushUndo()
      if st.sel ~= 0 then rig:setKey(a,st.sel,st.frame)
      else for _,b in ipairs(rig.bones) do rig:setKey(a,b.id,st.frame) end end
    end
    afterEdit()
  end
  local function exportAnimation()
    if stopPlay then stopPlay() end
    local ok,res=Export.exportAnimation(sprite,rig,curAnim())
    if ok then status(string.format("Exported %d layers, %d frames.",res,curAnim().frames))
    else status(res); app.alert(res) end
  end
  local function exportSkin()
    local f=(app.frame and app.frame.frameNumber) or 1
    local ok,res=Export.export(sprite,rig,f)
    if ok then status("Exported "..res.." skin layers.")
    else status(res); app.alert(res) end
  end
  local function createPaint()
    local ok,msg=Paint.create(sprite,rig)
    if ok then
      st.artDirty = true
      refreshArt()
      status("Created "..msg..". Paint on its Aseprite layers.")
    else status(msg); app.alert(msg) end
    repaint()
  end
  local function openPaint()
    -- Keep "Open Paint Sheet" consistent with the binder: both use the most
    -- recently generated sheet, never a stale source from an earlier run.
    local sheet = Binding.activeSheet(sprite)
    if not sheet then
      status("No Paint Sheet: use Generate Paint Sheet first.")
      return
    end
    local function belongsToSheet(layer)
      local guard = 0
      while layer and guard < 64 do
        if layer == sheet then return true end
        layer = layer.parent
        guard = guard + 1
      end
      return false
    end
    local sourceLayer = app.layer
    if not sourceLayer or sourceLayer.isGroup or not belongsToSheet(sourceLayer) then
      local function findEditable(layers)
        for _, layer in ipairs(layers or {}) do
          if layer.isGroup then
            local nested = findEditable(layer.layers)
            if nested then return nested end
          else
            return layer
          end
        end
        return nil
      end
      sourceLayer = findEditable(sheet.layers)
    end
    if not sourceLayer then
      status("The active Paint Sheet has no editable artwork layers.")
      return
    end
    local ok=pcall(function()
      app.frame=1
      app.layer=sourceLayer
      app.refresh()
    end)
    if ok then
      status("Opened active '"..sheet.name.."' artwork layer in Aseprite. Preview auto-refreshes.")
    else status("Paint Sheet exists. Select its artwork layer in the Aseprite timeline.") end
  end
  local function switchAnim(step)
    local index=1
    for i,a in ipairs(rig.anims) do if a.id==rig.activeAnim then index=i; break end end
    rig.activeAnim=rig.anims[((index-1+step)%#rig.anims)+1].id
    st.frame=1
    rig:touch()
    afterEdit()
  end
  local function changeFrames(value)
    local n=math.floor(tonumber(value) or curAnim().frames)
    curAnim().frames=math.max(1,math.min(500,n))
    rig:touch(); save(); setFrame(st.frame); repaint()
  end
  local function changeFPS(value)
    local n=math.floor(tonumber(value) or curAnim().fps)
    curAnim().fps=math.max(1,math.min(60,n))
    rig:touch(); save(); repaint()
  end
  local function addPoseSlot()
    copyPose()
    st.slotNumber=st.slotNumber+1
    st.poseSlots[#st.poseSlots+1]={name="Pose "..st.slotNumber,keys=st.clip}
    status("Pose saved for this PixelBone session (not written to sprite.data).")
  end

  stopPlay = function()
    st.playing=false
    if st.timer then pcall(function() st.timer:stop() end) end
    repaint()
  end
  syncFrame = function()
    clampFrame()
    local visible=math.max(1,math.floor((TL.w-132)/16))
    if st.frame < st.timelineOffset then st.timelineOffset=st.frame end
    if st.frame >= st.timelineOffset+visible then
      st.timelineOffset=st.frame-visible+1
    end
    repaint()
  end
  syncAnimUi = function() repaint() end
  startPlay = function()
    if st.playing then return end
    st.mode="pose"
    if st.artDirty then refreshArt() end
    st.playing=true
    local ok=pcall(function()
      if st.timer then st.timer:stop() end
      st.timer=Timer{interval=1/math.max(1,curAnim().fps),ontick=function()
        if st.playing then setFrame((st.frame%curAnim().frames)+1) end
      end}
      st.timer:start()
    end)
    if not ok then
      st.playing=false
      status("Playback needs Timer support in this Aseprite version.")
    end
    repaint()
  end

  -------------------------------------------------------------- left panel
  local function paintLeft(ctx)
    local x=10
    local width=LEFT_W-22
    rect(ctx,0,0,LEFT_W,UI_H,UI.sidebar)
    txt(ctx,"PIXELBONE",10,6,UI.accent)
    txt(ctx,"v0.8.2",LEFT_W-61,6,UI.quiet)
    local xx,yy=10,27
    for i,name in ipairs(TABS) do
      local tw=math.max(37,math.min(88,math.floor(#name*7.8)+15))
      if xx+tw>LEFT_W-10 then xx=10; yy=yy+24 end
      button(ctx,name,xx,yy,tw,21,function() showTab(name) end,st.panel==name)
      xx=xx+tw+3
    end
    local top=yy+30
    rect(ctx,0,top-3,LEFT_W,1,UI.border)
    local bottom=FOOT_Y-3
    local scroll=st.scroll[st.panel] or 0
    local y=top+7-scroll
    ctx:save()
    ctx:beginPath()
    ctx:rect(Rectangle(3,top,LEFT_W-6,bottom-top))
    ctx:clip()
    local function section(label)
      divider(ctx,label,x,y,width)
      y=y+28
    end
    local function label(value)
      txt(ctx,short(value,width),x,y+2,UI.quiet)
      y=y+18
    end
    local function btn(value,action)
      if y+23>=top and y<bottom then
        button(ctx,value,x,y,width,22,function() action() end)
      else
        rect(ctx,x,y,width,22,UI.panel)
        txt(ctx,short(value,width-10),x+5,y+4)
      end
      y=y+27
    end
    local function pair(a,fa,b,fb)
      local ww=math.floor((width-5)/2)
      if y+22>=top and y<bottom then
        button(ctx,a,x,y,ww,22,fa)
        button(ctx,b,x+ww+5,y,width-ww-5,22,fb)
      end
      y=y+27
    end
    local function chk(value,isOn,action)
      if y+18>=top and y<bottom then checkbox(ctx,value,x,y,width,isOn,action) end
      y=y+23
    end
    local function field(title,value,callback,kind)
      label(title..":  "..tostring(value))
      btn("Edit "..title.."...",function() prompt(kind or "text",title,value,callback) end)
    end
    local function boneAction(labelText,action)
      btn(labelText,function()
        local b=rig:get(st.sel)
        if not b then status("Select a bone first."); return end
        action(b)
      end)
    end

    if st.panel=="Rig" then
      section("Skeleton / symmetry")
      label(string.format("Sprite: %d x %d px  |  bones: %d",sprite.width,sprite.height,#rig.bones))
      chk("Mirror",rig.mirror.enabled,function()
        rig.mirror.enabled=not rig.mirror.enabled; save(); repaint()
      end)
      field("Mirror axis X",rig.mirror.axisX,function(v)
        rig.mirror.axisX=tonumber(v) or rig.mirror.axisX; save(); repaint()
      end,"number")
      btn("Axis = sprite centre",function()
        rig.mirror.axisX=sprite.width/2; save(); repaint()
      end)
      btn("Symmetrize existing bones",function()
        local s=rig:snapshot(); local n=rig:symmetrize()
        if n>0 then pushUndo(s) end
        afterEdit(); status("Linked "..n.." bone pair(s).")
      end)
      section("Drawing preferences")
      chk("Snap to pixels",st.snap,function() st.snap=not st.snap; repaint() end)
      chk("Autosave rig data",st.autosave,function() st.autosave=not st.autosave end)
      pair("Save rig",function() save(true); status("Rig saved.") end,
           "Fit view",function()
             st.view:fit(AREA.w,AREA.h,sprite.width,sprite.height)
             st.view.ox=st.view.ox+AREA.x; st.view.oy=st.view.oy+AREA.y; repaint()
           end)
      section("Template (empty rig only)")
      btn("Create humanoid skeleton",function()
        local snap=rig:snapshot()
        local ok,info=Templates.humanoid(rig,sprite.width,sprite.height)
        if ok then pushUndo(snap); afterEdit(); status("Humanoid template: "..info.." bones created.")
        else status(info) end
      end)

    elseif st.panel=="Bone" then
      -- Always-visible IK shortcut.  Deep Inspector lists scroll, but chain
      -- length is needed frequently while animating, including on small PCs.
      local quickIk = curIK()
      label("IK chain: " .. (quickIk and quickIk.chain or st.newIkChain or 2) .. " bones (1..8)")
      pair("Chain -",function() stepIkChain(-1) end,
           "Chain +",function() stepIkChain(1) end)
      section("Bone tools")
      pair("Select",function() setTool("select") end,"Draw bone",function() setTool("create") end)
      pair("Edit",function() setTool("edit") end,"Link",function() setTool("link") end)
      pair("Delete",function() setTool("delete") end,"Radius",function() setTool("radius") end)
      pair("Rotate",function() setTool("pose") end,"Move",function() setTool("move") end)
      pair("IK",function() setTool("ik") end,"Pan",function() setTool("pan") end)
      section("IK controllers / chain length")
      local ik = curIK()
      if ik then
        local resolved = select(1, rig:ikResolve(ik))
        local used = resolved and #resolved or 0
        label(ik.name .. " (#" .. ik.id .. ")")
        label("Chain: " .. (ik.chain or 2) .. " requested / " .. used .. " used (1..8), influence: " .. math.floor(100*(ik.influence or 1)) .. "%")
      else
        label("No IK constraint. Next chain: " .. (st.newIkChain or 2) .. " bones")
      end
      label("Chain counts from the tip: 2 = thigh+shin, 3 = thigh+shin+foot.")
      btn("Add controller to selection",addController)
      if ik then
        pair("< IK",function() cycleIk(-1) end,"IK >",function() cycleIk(1) end)
        pair("Flip bend",flipBend,"Delete IK",deleteIk)
        field("IK chain (1..8)",ik.chain,function(v)
          ikChange({chain=math.max(1,math.min(8,math.floor(tonumber(v) or ik.chain or 2)))})
        end,"number")
        field("IK influence %",math.floor(100*(ik.influence or 1)),function(v)
          ikChange({influence=math.max(0,math.min(100,tonumber(v) or 100))/100})
        end,"number")
        chk("IK enabled",ik.enabled~=false,function() ikChange({enabled=ik.enabled==false}) end)
        pair("Tip = selected",function() setIkBone("tip") end,
             "Target = selected",function() setIkBone("target") end)
      else
        label("Chain = bone count; influence = FK/IK blend.")
      end

      section("Bone Inspector")
      local b=rig:get(st.sel)
      label(b and ("Selected: "..b.name.." (#"..b.id..")") or "Select a bone in the canvas / timeline")
      if b then
        local parent=rig:get(b.parent)
        local children={}
        for _, c in ipairs(rig.bones) do
          if c.parent==b.id then children[#children+1]=c end
        end
        field("Bone name",b.name,function(v)
          if v and v~="" then pushUndo(); rig:rename(b,v); afterEdit() end
        end)
        label("Parent: "..(parent and (parent.name.." (#"..parent.id..")") or "None (root)"))
        label("Connection: "..(b.connected and "Connected" or "Disconnected"))
        pair("Select Parent",function()
          if parent then st.sel=parent.id; syncSelection(); repaint() end
        end,"Change Parent",function()
          prompt("text","Parent ID or name (0=none)",parent and tostring(parent.id) or "0",function(v)
            local str=tostring(v or "")
            local id=tonumber(str:match("^%s*#?(%d+)%s*$"))
            if not id then
              for _, other in ipairs(rig.bones) do
                if other.name==str then id=other.id; break end
              end
            end
            if not id then status("Unknown parent. Use a numeric bone ID or exact name."); return end
            local snap=rig:snapshot()
            if rig:setParent(b,id,false) then
              pushUndo(snap); afterEdit()
              status("Parent changed (disconnected, no rest artwork moved).")
            else status("Invalid parent: missing bone or circular link.") end
          end)
        end)
        pair(b.connected and "Disconnect" or "Connect",function()
          if b.parent~=0 then pushUndo(); rig:setConnected(b,not b.connected); afterEdit() end
        end,"Unparent",function()
          if b.parent~=0 then pushUndo(); rig:setParent(b,0,false); afterEdit() end
        end)
        label("Children: "..(#children>0 and tostring(#children) or "None"))
        for i=1,math.min(#children,5) do
          local child=children[i]
          btn("  "..child.name.." (#"..child.id..")  - select",function()
            st.sel=child.id; syncSelection(); repaint()
          end)
        end
        if #children>5 then label("+"..(#children-5).." more children (timeline)") end
        label(string.format("Head/Tail radius: %.1f / %.1f",b.ra or 0,b.rb or 0))
        section("Assembly placement (not a keyframe)")
        local rot,dx,dy=rig:assemblyChannels(b.id)
        label(string.format("Rotation: %.1f deg",rot))
        label(string.format("Position: %+.1f, %+.1f px",dx,dy))
        pair("Edit Assembly",function() setMode("assembly") end,"Reset this bone",function()
          pushUndo(); rig:resetAssembly(b.id); afterEdit()
        end)
      end

    elseif st.panel=="Groups" then
      section("Skin groups")
      local g=rig:getGroup(rig.activeGroup)
      label(g and ("Active: "..g.name) or "No active group")
      pair("< Group",function() cycleGroup(-1) end,"Group >",function() cycleGroup(1) end)
      pair("New group",function()
        pushUndo(); local group=rig:addGroup(); afterEdit(); status("Created "..group.name)
      end,"Delete group",function()
        if #rig.groups<2 then status("Cannot delete the last group."); return end
        pushUndo(); rig:deleteGroup(rig.activeGroup); afterEdit()
      end)
      if g then
        field("Group name",g.name,function(v)
          if v and v~="" then pushUndo(); rig:renameGroup(g.id,v); afterEdit() end
        end)
        btn("Group colour...",function()
          pickColor("Group colour",g.color,function(color)
            g.color=color; rig:touch(); save(); repaint()
          end)
        end)
      end
      section("Assignment")
      boneAction("Assign selected bone",function(b)
        pushUndo(); rig:assignGroup(b,rig.activeGroup,false); afterEdit()
      end)
      boneAction("Assign bone and children",function(b)
        pushUndo(); rig:assignGroup(b,rig.activeGroup,true); afterEdit()
      end)
      boneAction("Set selected bone as helper",function(b)
        pushUndo(); rig:assignGroup(b,0,false); afterEdit()
      end)
      section("Skin preview")
      chk("Outline: pixel",rig.outline=="pixel",function()
        rig.outline=(rig.outline=="pixel") and "none" or "pixel"; rig:touch(); save(); repaint()
      end)
      btn("Outline colour...",function()
        pickColor("Outline colour",rig.outlineColor,function(c)
          rig.outlineColor=c; rig:touch(); save(); repaint()
        end)
      end)

    elseif st.panel=="Paint" then
      section("Paint Sheet")
      label("Edit pixels once; animate every frame.")
      local previewY=y
      local previewH=math.min(185,math.max(82,math.floor(width*0.68)))
      rect(ctx,x,previewY,width,previewH,UI.panel)
      local cell=12
      for py=0,math.floor(previewH/cell) do
        for px=0,math.floor(width/cell) do
          if (px+py)%2==0 then
            rect(ctx,x+px*cell,previewY+py*cell,cell,cell,UI.checker1)
          end
        end
      end
      if st.artRest then
        local zoom=math.min((width-16)/sprite.width,(previewH-12)/sprite.height)
        local iw,ih=math.max(1,math.floor(sprite.width*zoom)),math.max(1,math.floor(sprite.height*zoom))
        ctx:drawImage(st.artRest,Rectangle(0,0,sprite.width,sprite.height),
          Rectangle(x+math.floor((width-iw)/2),previewY+math.floor((previewH-ih)/2),iw,ih))
      else
        txt(ctx,"No Paint Sheet yet",x+8,previewY+12,UI.text)
      end
      stroke(ctx,x,previewY,width,previewH,UI.border)
      y=y+previewH+9
      btn("Open Paint Sheet in Aseprite",openPaint)
      btn("Refresh artwork",function()
        local found=refreshArt()
        status(found and "Artwork binding and preview refreshed." or "No bound artwork pixels found.")
        repaint()
      end)
      btn("Generate new Paint Sheet",createPaint)
      btn("New layer for selected bone...",function()
        local b=rig:get(st.sel)
        if not b then status("Select a bone first (Bone tab or Timeline)."); return end
        prompt("text","New artwork layer", "Hat", function(name)
          local ok,msg=Paint.addBoneLayer(sprite,rig,b.id,name)
          if ok then
            st.artDirty=true; refreshArt()
            status("Created "..msg..". Paint on it in Aseprite.")
          else status(msg) end
        end)
      end)
      label("New tagged layers bind to the chosen bone.")
      label("Original source cels and keys are preserved.")

    elseif st.panel=="Animation" then
      section("Assembly / animation")
      label("Rest: separated art; Assemble: initial layout.")
      label("Animate: keys start on frame 1 (no setup frame).")
      pair("Assembly",function() setMode("assembly") end,"Animate",function() setMode("pose") end)
      btn("Reset ALL Assembly (confirm)...",function()
        local confirm=Dialog{title="PixelBone - Reset Assembly?"}
        confirm:label{text="Keep your Paint Sheets and animation keys."}
        confirm:label{text="Reset all initial bone offsets?"}
        confirm:button{text="Reset Assembly",onclick=function()
          pushUndo(); rig:resetAssembly(); afterEdit(); confirm:close()
        end}
        confirm:button{text="Cancel",onclick=function() confirm:close() end}
        confirm:show{wait=false}
      end)
      section("Animation clip")
      label("Active: "..curAnim().name)
      pair("< Animation",function() switchAnim(-1) end,
        "Animation >",function() switchAnim(1) end)
      pair("New animation",function()
        pushUndo(); rig:addAnim(); st.frame=1; afterEdit()
      end,"Delete animation",function()
        if #rig.anims<2 then status("Cannot delete last animation."); return end
        pushUndo(); rig:deleteAnim(curAnim().id); st.frame=1; afterEdit()
      end)
      field("Animation name",curAnim().name,function(v)
        if v and v~="" then pushUndo(); rig:renameAnim(curAnim().id,v); afterEdit() end
      end)
      field("Frames",curAnim().frames,changeFrames,"number")
      field("FPS",curAnim().fps,changeFPS,"number")
      chk("Step interpolation",curAnim().interp=="step",function()
        curAnim().interp=(curAnim().interp=="step") and "linear" or "step"
        rig:touch(); save(); repaint()
      end)
      field("Angle snap (degrees)",st.angleSnap,function(v)
        st.angleSnap=math.max(0,tonumber(v) or 0)
      end,"number")
      section("Keyframes")
      pair("+ Key",function() keyFrame(false) end,
           "- Key",function() keyFrame(true) end)
      pair("Copy pose",copyPose,"Paste pose",pastePose)
      label("Double-click a timeline cell to toggle its key.")

    elseif st.panel=="Onion" then
      section("Onion skin")
      chk("Enable onion skin",st.onion.on,function() st.onion.on=not st.onion.on; repaint() end)
      label("Shown in Animate mode only.")
      label("Red = earlier, green = later frames.")
      section("Frames back: "..st.onion.back)
      pair("Back -",function() onionStep("back",-1) end,"Back +",function() onionStep("back",1) end)
      section("Frames forward: "..st.onion.fwd)
      pair("Forward -",function() onionStep("fwd",-1) end,"Forward +",function() onionStep("fwd",1) end)
      section("Ghost artwork")
      chk("Also show Artwork (slower)",st.onion.art,function() st.onion.art=not st.onion.art; repaint() end)
      label("Settings last for this session only.")

    elseif st.panel=="Poses" then
      section("Pose library (session only)")
      label("Copy/paste and preview use the existing FK keys.")
      pair("Copy pose",copyPose,"Paste pose",pastePose)
      btn("Add current pose to session library",addPoseSlot)
      label("Slots are not saved; v0.6 data remains unchanged.")
      for i,slot in ipairs(st.poseSlots) do
        btn(slot.name.." - Apply",function()
          st.clip=slot.keys; pastePose(); setMode("pose")
        end)
      end

    elseif st.panel=="More" then
      section("Display")
      chk("Show Artwork",st.showArt,function() st.showArt=not st.showArt; repaint() end)
      chk("Show Capsules",st.showSkin,function()
        st.manualCapsules=true; st.showSkin=not st.showSkin; repaint()
      end)
      chk("Show Bones",st.showBones,function() st.showBones=not st.showBones; repaint() end)
      chk("Show Sprite (when no artwork)",st.showSprite,function()
        st.showSprite=not st.showSprite; repaint()
      end)
      chk("Show all radii",st.showRadii,function() st.showRadii=not st.showRadii; repaint() end)
      chk("Show bone names",st.showNames,function() st.showNames=not st.showNames; repaint() end)
      section("File / export")
      btn("Export skin to layers",exportSkin)
      btn("Export animation to layers",exportAnimation)
      btn("Generate Paint Sheet",createPaint)
      btn("Save rig into sprite",function() save(true); status("Rig saved.") end)
      section("History")
      pair("Undo",doUndo,"Redo",doRedo)
    end

    st.panelTotal=math.max(0,y-(top+7-scroll))
    st.panelVisible=bottom-top-7
    ctx:restore()
    local overflow=st.panelTotal-st.panelVisible
    if overflow>0 then
      local track=bottom-top
      local thumb=math.max(18,math.floor(track*st.panelVisible/st.panelTotal))
      local pos=math.floor((track-thumb)*(scroll/math.max(1,overflow)))
      rect(ctx,LEFT_W-6,top+pos,3,thumb,UI.accent)
    end
    rect(ctx,LEFT_W,0,1,FOOT_Y,UI.border)
  end

  ------------------------------------------------------------ right toolbar
  local function paintToolbar(ctx)
    local x=RIGHT_X+8
    local compact = UI_W < 735
    local wRest,wAsm,wAnim = compact and 36 or 40,compact and 52 or 68,compact and 51 or 65
    button(ctx,"Rest",x,10,wRest,26,function() setMode("rest") end,st.mode=="rest"); x=x+wRest+3
    button(ctx,compact and "Build" or "Assemble",x,10,wAsm,26,function() setMode("assembly") end,st.mode=="assembly"); x=x+wAsm+3
    button(ctx,compact and "Anim" or "Animate",x,10,wAnim,26,function() setMode("pose") end,st.mode=="pose"); x=x+wAnim+4
    local items=compact and {
      {"Sel","select",39},{"Rotate","pose",52},{"Move","move",42},
      {"IK","ik",28},{"Pan","pan",33},
    } or {
      {"Select","select",54},{"Rotate","pose",56},{"Move","move",47},
      {"IK","ik",29},{"Pan","pan",34},
    }
    for _,it in ipairs(items) do
      if x+it[3]<UI_W-3 then
        button(ctx,it[1],x,10,it[3],26,function() setTool(it[2]) end,st.tool==it[2]); x=x+it[3]+3
      end
    end
    if x+48<UI_W-3 then
      button(ctx,"Art",x,10,42,26,function() st.showArt=not st.showArt; repaint() end,st.showArt)
      x=x+45
    end
    if x+52<UI_W-3 then
      button(ctx,"Caps",x,10,48,26,function()
        st.manualCapsules=true; st.showSkin=not st.showSkin; repaint()
      end,st.showSkin)
      x=x+51
    end
    if x+60<UI_W-3 then
      button(ctx,"Bones",x,10,54,26,function() st.showBones=not st.showBones; repaint() end,st.showBones)
    end
    rect(ctx,RIGHT_X,40,UI_W-RIGHT_X,1,UI.border)
  end

  --------------------------------------------------------------- timeline
  local function paintTimeline(ctx)
    rect(ctx,TL.x,TL.y,TL.w,TL.h,UI.bg)
    rect(ctx,TL.x,TL.y,TL.w,1,UI.border)
    local tx=TL.x+5
    local function tool(text,w,act,sel)
      if tx+w+5<=UI_W then
        button(ctx,text,tx,TL.y+4,w,22,act,sel)
      end
      tx=tx+w+3
    end
    tool(st.playing and "Stop" or "Play",46,function()
      if st.playing then stopPlay() else startPlay() end
    end,st.playing)
    tool("<",22,function() setFrame(st.frame-1) end)
    tool(">",22,function() setFrame(st.frame+1) end)
    tool("+Key",45,function() keyFrame(false) end)
    tool("-Key",45,function() keyFrame(true) end)
    tool("Copy",46,copyPose)
    tool("Paste",47,pastePose)
    local labelW=math.max(85,math.min(132,math.floor(TL.w*0.22)))
    local timeX=TL.x+labelW
    local fw=16
    local visible=math.max(1,math.floor((TL.w-labelW-7)/fw))
    st.timelineColumns=visible
    st.timelineOffset=math.max(1,math.min(st.timelineOffset,math.max(1,curAnim().frames-visible+1)))
    local headY=TL.y+30
    local rowsY=headY+19
    local rowH=15
    local nRows=math.max(1,math.floor((TL.h-52)/rowH))
    st.timelineRows=nRows
    local maxRow=math.max(0,#rig.bones-nRows)
    st.boneOffset=math.max(0,math.min(maxRow,st.boneOffset))
    txt(ctx,string.format("%d/%d  %d fps",st.frame,curAnim().frames,curAnim().fps),TL.x+6,headY+2,UI.quiet)
    for column=0,visible-1 do
      local frame=st.timelineOffset+column
      if frame>curAnim().frames then break end
      local cx=timeX+column*fw
      rect(ctx,cx,headY,fw-1,16,(frame==st.frame) and UI.accentDark or UI.panel)
      txt(ctx,tostring(frame),cx+2,headY+2,(frame==st.frame) and UI.accent or UI.quiet)
      hit(cx,headY,fw,16,function() setFrame(frame) end)
    end
    local anim=curAnim()
    for row=1,nRows do
      local index=row+st.boneOffset
      local b=rig.bones[index]
      local ry=rowsY+(row-1)*rowH
      if ry+rowH>TL.y+TL.h-4 then break end
      rect(ctx,TL.x+3,ry,TL.w-7,rowH-1,(row%2==1) and UI.row or UI.rowAlt)
      if b then
        if st.sel==b.id then rect(ctx,TL.x+3,ry,labelW-2,rowH-1,UI.selected) end
        txt(ctx,short(b.name,labelW-12),TL.x+7,ry+1,(st.sel==b.id) and UI.accent or UI.text)
        hit(TL.x+3,ry,labelW-3,rowH,function()
          st.sel=b.id; syncSelection(); repaint()
        end)
        local boneKeys=anim.keys[tostring(b.id)] or {}
        for column=0,visible-1 do
          local frame=st.timelineOffset+column
          if frame>anim.frames then break end
          local cx=timeX+column*fw
          if frame==st.frame then rect(ctx,cx,ry,fw-1,rowH-1,UI.selected) end
          if boneKeys[tostring(frame)] then
            rect(ctx,cx+5,ry+4,6,6,(frame==st.frame) and UI.accent or UI.key)
          end
          hit(cx,ry,fw,rowH,function()
            st.sel=b.id; syncSelection(); setFrame(frame)
          end)
        end
      end
    end
    stroke(ctx,TL.x+2,headY,TL.w-5,TL.h-33,UI.border)
    st.timelineGrid={x=timeX,y=headY,w=visible*fw,h=TL.h-34,labelW=labelW,rowsY=rowsY,rowH=rowH,fw=fw}
  end

  ------------------------------------------------------------------ events
  local function paintWorkspace(ev)
    local ctx=ev.context
    st.hits={}
    if st.artDirty then refreshArt() end
    rect(ctx,0,0,UI_W,UI_H,UI.bg)
    paintLeft(ctx)
    paintToolbar(ctx)
    ctx:save()
    ctx:beginPath()
    ctx:rect(Rectangle(AREA.x,AREA.y,AREA.w,AREA.h))
    ctx:clip()
    onpaint(ev)
    ctx:restore()
    stroke(ctx,AREA.x,AREA.y,AREA.w,AREA.h,UI.border)
    paintTimeline(ctx)
    rect(ctx,0,FOOT_Y,UI_W,1,UI.border)
    txt(ctx,short(st.selectedInfo or "No bone selected",LEFT_W-15),8,FOOT_Y+5,UI.quiet)
    txt(ctx,short(st.statusText,UI_W-RIGHT_X-14),RIGHT_X+8,FOOT_Y+5,UI.quiet)
  end
  local function hitAction(x,y)
    -- The most recently drawn control has precedence.
    for i=#st.hits,1,-1 do
      local h=st.hits[i]
      if within(x,y,h) then return h end
    end
    return nil
  end
  local function mouseDown(ev)
    st.cursorX,st.cursorY=ev.x,ev.y
    if within(ev.x,ev.y,AREA) then
      st.focusArea="canvas"
      onmousedown(ev)
      return
    end
    st.focusArea="ui"
    st.pressed=hitAction(ev.x,ev.y)
  end
  local function mouseMove(ev)
    st.cursorX,st.cursorY=ev.x,ev.y
    if st.focusArea=="canvas" and st.drag then onmousemove(ev)
    else repaint() end
  end
  local function mouseUp(ev)
    if st.focusArea=="canvas" then
      onmouseup(ev)
    elseif st.pressed and within(ev.x,ev.y,st.pressed) then
      st.pressed.action()
    end
    st.focusArea=nil; st.pressed=nil
    repaint()
  end
  local function wheel(ev)
    if within(ev.x,ev.y,AREA) then
      onwheel(ev)
    elseif ev.x<LEFT_W then
      local maxscroll=math.max(0,(st.panelTotal or 0)-(st.panelVisible or 0))
      local delta=ev.deltaY>0 and 40 or -40
      st.scroll[st.panel]=math.max(0,math.min(maxscroll,(st.scroll[st.panel] or 0)+delta))
      repaint()
    elseif within(ev.x,ev.y,TL) then
      if ev.shiftKey or ev.x>(st.timelineGrid and st.timelineGrid.x or 0) then
        local n=curAnim().frames
        local delta=ev.deltaY>0 and 4 or -4
        local vis=st.timelineColumns or 25
        st.timelineOffset=math.max(1,math.min(math.max(1,n-vis+1),st.timelineOffset+delta))
      else
        local delta=ev.deltaY>0 and 3 or -3
        st.boneOffset=math.max(0,math.min(math.max(0,#rig.bones-(st.timelineRows or 5)),st.boneOffset+delta))
      end
      repaint()
    end
  end
  local function doubleClick(ev)
    if isAssemble() then
      status("Switch to Animate before adding or removing keys.")
      return
    end
    if not within(ev.x,ev.y,TL) then return end
    local g=st.timelineGrid
    if not g or ev.x<g.x or ev.y<g.rowsY then return end
    local column=math.floor((ev.x-g.x)/g.fw)
    local row=math.floor((ev.y-g.rowsY)/g.rowH)
    local f=st.timelineOffset+column
    local b=rig.bones[st.boneOffset+row+1]
    if not b or f<1 or f>curAnim().frames then return end
    st.sel=b.id; setFrame(f)
    local a=curAnim()
    pushUndo()
    if rig:hasKey(a,b.id,f) then rig:deleteKey(a,b.id,f)
    else rig:setKey(a,b.id,f) end
    afterEdit()
  end

  dlg=Dialog{
    title="PixelBone v0.8.2",
    onclose=function()
      if stopPlay then stopPlay() end
      save(true)
      if st.listener then pcall(function() sprite.events:off(st.listener) end) end
      if st.siteListener then pcall(function() app.events:off(st.siteListener) end) end
      dlg=nil
    end,
  }
  if not dlg then app.alert("PixelBone needs the Aseprite GUI."); return end
  dlg:canvas{
    id="workspace",width=UI_W,height=UI_H,
    onpaint=paintWorkspace,
    onmousedown=mouseDown,onmousemove=mouseMove,onmouseup=mouseUp,
    onwheel=wheel,ondblclick=doubleClick,
  }
  -- Mark caches dirty, don't regenerate or modify artwork inside event callbacks.
  pcall(function()
    st.listener=sprite.events:on("change",function()
      st.img=nil; st.artDirty=true; repaint()
    end)
  end)
  pcall(function()
    st.siteListener=app.events:on("sitechange",function()
      if app.sprite==sprite then
        st.img=nil; st.artDirty=true; repaint()
      end
    end)
  end)
  refreshArt()
  syncSelection()
  dlg:show{wait=false}
end

return M
