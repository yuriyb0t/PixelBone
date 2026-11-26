-- PixRig dialog: canvas with bone editing tools, skin groups and export.

local Rig = require("pixrig.rig")
local Store = require("pixrig.store")
local View = require("pixrig.view")
local Skin = require("pixrig.skin")
local Export = require("pixrig.export")

local M = {}

local CANVAS_W, CANVAS_H = 720, 340

local HINTS = {
  create = "Create: drag to draw a bone. Start on a bone's tip to chain, on its body for a loose child. Shift = new root.",
  edit   = "Edit: drag a tip to move it, drag a bone's body to move it with its children.",
  link   = "Link: drag from a bone onto another bone to make it the parent (release on the tip to connect).",
  delete = "Delete: click a bone to delete it (children are kept).",
  radius = "Radius: drag a joint outward or inward to change the skin thickness there.",
  pose   = "Pose: drag a bone to rotate it around its head. A key is set on the current frame.",
  move   = "Move: drag to move the whole character (keys the root bone's position).",
}

local TOOLS = { "create", "edit", "link", "delete", "radius", "pose", "move" }

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
    snap = true, showSprite = true, showNames = false, autosave = true,
    showSkin = true, showRadii = false,
    img = nil, skinImg = nil, skinKey = nil,
    frame = 1, angleSnap = 0, playing = false, clip = nil,
    cw = CANVAS_W, ch = CANVAS_H,
  }
  st.view:fit(st.cw, st.ch, sprite.width, sprite.height)

  local dlg, tdlg, syncAnimUi, syncFrame, stopPlay, openTimeline

  ------------------------------------------------------------------ helpers
  local function status(text)
    if dlg then dlg:modify{ id = "status", text = text } end
  end

  local function repaint()
    if dlg then dlg:repaint() end
    if tdlg then tdlg:repaint() end
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

  local function pushUndo(snapshot)
    st.undo[#st.undo + 1] = snapshot or rig:snapshot()
    if #st.undo > 100 then table.remove(st.undo, 1) end
    st.redo = {}
  end

  local function groupNames()
    local t = {}
    for _, g in ipairs(rig.groups) do t[#t + 1] = g.name end
    return t
  end

  local function syncGroupUi()
    if not dlg then return end
    local g = rig:getGroup(rig.activeGroup)
    local args = { id = "group", options = groupNames() }
    if g then args.option = g.name end
    dlg:modify(args)
    dlg:modify{ id = "gname", text = g and g.name or "" }
    if g then
      dlg:modify{ id = "gcolor", color = Color{ r = g.color.r, g = g.color.g, b = g.color.b } }
    end
  end

  local function syncSelection()
    if not rig:get(st.sel) then st.sel = 0 end
    local b = rig:get(st.sel)
    if dlg then
      dlg:modify{ id = "name", text = b and b.name or "" }
      local info = "No bone selected"
      if b then
        local p = rig:get(b.parent)
        local g = rig:getGroup(b.group)
        info = string.format("id %d | parent: %s%s | twin: %s | group: %s | r: %.1f / %.1f",
          b.id, p and p.name or "none", (p and b.connected) and " (connected)" or "",
          rig:twin(b) and rig:twin(b).name or "none", g and g.name or "none", b.ra or 0, b.rb or 0)
      end
      dlg:modify{ id = "info", text = info }
    end
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

  -- Pose view is active for the Pose/Move tools and while playing.
  local function isPose()
    return st.tool == "pose" or st.tool == "move" or st.playing
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
    local key = rig.rev .. ":" .. a.id .. ":" .. st.frame
    if st.poseKey ~= key then
      st.posed, st.T = rig:pose(a, st.frame)
      st.poseKey = key
    end
    return st.posed
  end

  ------------------------------------------------------------------- paint
  local function onpaint(ev)
    local ctx = ev.context
    local W, H = ctx.width, ctx.height
    st.cw, st.ch = W, H
    local v = st.view
    local pose = isPose()
    local bones = currentBones()

    ctx.color = COL.bg
    ctx:fillRect(Rectangle(0, 0, W, H))

    local x0, y0 = v:toScreen(0, 0)
    local sw, sh = sprite.width * v.zoom, sprite.height * v.zoom
    local dst = Rectangle(ifloor(x0), ifloor(y0), math.max(1, ifloor(sw)), math.max(1, ifloor(sh)))
    local src = Rectangle(0, 0, sprite.width, sprite.height)

    ctx.color = COL.canvas
    ctx:fillRect(dst)
    if st.showSprite then
      if not st.img then refreshImage() end
      if st.img then ctx:drawImage(st.img, src, dst) end
    end
    if st.showSkin then
      local key = rig.rev .. ":" .. (pose and (curAnim().id .. ":" .. st.frame) or "rest")
      if not st.skinImg or st.skinKey ~= key then refreshSkin(bones, key) end
      pcall(function() ctx.opacity = 190 end)
      ctx:drawImage(st.skinImg, src, dst)
      pcall(function() ctx.opacity = 255 end)
    end
    ctx.color = COL.border
    ctx.strokeWidth = 1
    ctx:strokeRect(dst)

    if rig.mirror.enabled and not pose then
      local ax = v:toScreen(rig.mirror.axisX, 0)
      line(ctx, ax, 0, ax, H, COL.axis)
    end

    local selBone = byId(bones, st.sel)
    local restSel = rig:get(st.sel)
    local restTwin = restSel and rig:twin(restSel) or nil
    local selTwin = restTwin and byId(bones, restTwin.id) or nil

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

    if not pose then
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
    if ev.button == MouseButton.MIDDLE or ev.button == MouseButton.RIGHT or ev.spaceKey then
      st.drag = { mode = "pan", sx = ev.x, sy = ev.y, ox = v.ox, oy = v.oy }
      return
    end
    if ev.button ~= MouseButton.LEFT then return end
    if st.playing then return end

    local x, y = v:toRig(ev.x, ev.y)
    local tol = 8 / v.zoom
    local tool = st.tool

    if tool == "pose" then
      local pb = rig:hit(x, y, tol, currentBones())
      if pb then
        st.sel = pb.id
        syncSelection()
        st.drag = { mode = "rotate", boneId = pb.id, snapshot = rig:snapshot(), moved = false }
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
        local root = rig:rootOf(rb)
        local _, dx, dy = rig:channels(curAnim(), root.id, st.frame)
        st.sel = pb.id
        syncSelection()
        st.drag = {
          mode = "movechar", rootId = root.id, x0 = x, y0 = y, dx0 = dx, dy0 = dy,
          snapshot = rig:snapshot(), moved = false,
        }
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
      -- Point the bone at the mouse: rot = mouse angle - rest angle - parent angle.
      local rb = rig:get(d.boneId)
      if rb then
        local a = curAnim()
        local posed, T = rig:pose(a, st.frame)
        local pbone = byId(posed, rb.id)
        local x, y = v:toRig(ev.x, ev.y)
        local ang = math.deg(math.atan(y - pbone.ay, x - pbone.ax))
        local restAng = math.deg(math.atan(rb.by - rb.ay, rb.bx - rb.ax))
        local parentAng = 0
        local pt = T[rb.parent]
        if rb.parent ~= 0 and pt then parentAng = math.deg(math.atan(pt.s, pt.c)) end
        local rot = (ang - restAng - parentAng + 180) % 360 - 180
        if st.angleSnap > 0 then rot = math.floor(rot / st.angleSnap + 0.5) * st.angleSnap end
        rig:setKey(a, rb.id, st.frame, rot)
        if rig.mirror.enabled then
          local tw = rig:twin(rb)
          if tw then rig:setKey(a, tw.id, st.frame, -rot) end
        end
        d.moved = true
      end

    elseif d.mode == "movechar" then
      local x, y = v:toRig(ev.x, ev.y)
      local ddx, ddy = x - d.x0, y - d.y0
      if st.snap then ddx, ddy = ifloor(ddx), ifloor(ddy) end
      rig:setKey(curAnim(), d.rootId, st.frame, nil, d.dx0 + ddx, d.dy0 + ddy)
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

    elseif d.mode == "move" or d.mode == "radius" or d.mode == "rotate" or d.mode == "movechar" then
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
    if dlg then
      for _, t in ipairs(TOOLS) do
        local label = t:sub(1, 1):upper() .. t:sub(2)
        dlg:modify{ id = "tb_" .. t, text = (t == name) and ("[" .. label .. "]") or label }
      end
    end
    status(HINTS[name])
    repaint()
  end

  local KEYTOOL = { c = "create", e = "edit", l = "link", d = "delete", r = "radius",
                    p = "pose", m = "move",
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

  ----------------------------------------------------------------- dialog
  dlg = Dialog{
    title = "PixRig",
    onclose = function()
      if stopPlay then stopPlay() end
      if tdlg then
        local t = tdlg
        tdlg = nil
        pcall(function() t:close() end)
      end
      save(true)
      if st.listener then pcall(function() sprite.events:off(st.listener) end) end
      if st.siteListener then pcall(function() app.events:off(st.siteListener) end) end
    end,
  }

  dlg:button{ id = "tb_create", text = "[Create]", onclick = function() setTool("create") end }
  dlg:button{ id = "tb_edit",   text = "Edit",     onclick = function() setTool("edit") end }
  dlg:button{ id = "tb_link",   text = "Link",     onclick = function() setTool("link") end }
  dlg:button{ id = "tb_delete", text = "Delete",   onclick = function() setTool("delete") end }
  dlg:button{ id = "tb_radius", text = "Radius",   onclick = function() setTool("radius") end }
  dlg:button{ id = "tb_pose",   text = "Pose",     onclick = function() setTool("pose") end }
  dlg:button{ id = "tb_move",   text = "Move",     onclick = function() setTool("move") end }
  dlg:button{ text = "Undo", onclick = doUndo }
  dlg:button{ text = "Redo", onclick = doRedo }
  dlg:button{ text = "Fit", onclick = function()
    st.view:fit(st.cw, st.ch, sprite.width, sprite.height)
    repaint()
  end }
  dlg:button{ text = "Timeline...", onclick = function() openTimeline() end }
  dlg:newrow()

  dlg:canvas{
    id = "cv", width = CANVAS_W, height = CANVAS_H,
    onpaint = onpaint,
    onmousedown = onmousedown,
    onmousemove = onmousemove,
    onmouseup = onmouseup,
    onwheel = onwheel,
  }
  dlg:newrow()

  ------------------------------------------------------------- tab: Rig
  -- Older Aseprite builds may not have Dialog:tab(); fall back to separators.
  local hasTabs = false
  pcall(function() hasTabs = (dlg.tab ~= nil) and (dlg.endtabs ~= nil) end)
  local function section(id, text)
    if hasTabs then dlg:tab{ id = id, text = text } else dlg:separator{ text = text } end
  end

  section("tabRig", "Rig")

  dlg:check{ id = "mirror", text = "Mirror", selected = rig.mirror.enabled, onclick = function()
    rig.mirror.enabled = dlg.data.mirror
    save()
    repaint()
  end }
  dlg:number{ id = "axis", text = tostring(rig.mirror.axisX), decimals = 1,
    onchange = function()
      rig.mirror.axisX = dlg.data.axis
      save()
      repaint()
    end }
  dlg:button{ text = "Axis = center", onclick = function()
    rig.mirror.axisX = sprite.width / 2
    dlg:modify{ id = "axis", text = tostring(rig.mirror.axisX) }
    save()
    repaint()
  end }
  dlg:button{ text = "Symmetrize", onclick = function()
    local snap = rig:snapshot()
    local n = rig:symmetrize()
    if n > 0 then pushUndo(snap) end
    status(string.format("Symmetrize: linked %d pair(s).", n))
    afterEdit()
  end }
  dlg:newrow()

  dlg:check{ id = "snap", text = "Snap to pixels", selected = st.snap,
    onclick = function() st.snap = dlg.data.snap end }
  dlg:check{ id = "showSprite", text = "Show sprite", selected = st.showSprite,
    onclick = function() st.showSprite = dlg.data.showSprite; repaint() end }
  dlg:check{ id = "showNames", text = "All names", selected = st.showNames,
    onclick = function() st.showNames = dlg.data.showNames; repaint() end }
  dlg:check{ id = "autosave", text = "Autosave", selected = st.autosave,
    onclick = function() st.autosave = dlg.data.autosave end }
  dlg:newrow()

  dlg:entry{ id = "name", text = "", onchange = function()
    local b = rig:get(st.sel)
    local n = dlg.data.name
    if not b or n == "" or n == b.name then return end
    pushUndo()
    rig:rename(b, n)
    afterEdit()
  end }
  dlg:button{ text = "Connect / Disconnect", onclick = function()
    local b = rig:get(st.sel)
    if not b or b.parent == 0 then return end
    pushUndo()
    rig:setConnected(b, not b.connected)
    afterEdit()
  end }
  dlg:button{ text = "Unparent", onclick = function()
    local b = rig:get(st.sel)
    if not b or b.parent == 0 then return end
    pushUndo()
    rig:setParent(b, 0, false)
    afterEdit()
  end }
  dlg:button{ text = "Save", onclick = function()
    save(true)
    status("Saved into the sprite.")
  end }

  ------------------------------------------------------------ tab: Skin
  section("tabSkin", "Skin")

  local g0 = rig:getGroup(rig.activeGroup)
  dlg:check{ id = "showSkin", text = "Show skin", selected = st.showSkin,
    onclick = function() st.showSkin = dlg.data.showSkin; repaint() end }
  dlg:check{ id = "showRadii", text = "Show all radii", selected = st.showRadii,
    onclick = function() st.showRadii = dlg.data.showRadii; repaint() end }
  dlg:button{ text = "New group", onclick = function()
    pushUndo()
    rig:addGroup()
    afterEdit()
  end }
  dlg:button{ text = "Delete group", onclick = function()
    local g = rig:getGroup(rig.activeGroup)
    if not g then return end
    pushUndo()
    if not rig:deleteGroup(g.id) then
      st.undo[#st.undo] = nil
      status("Can't delete the last group.")
      return
    end
    afterEdit()
  end }
  dlg:newrow()

  dlg:combobox{ id = "group", option = g0 and g0.name or nil, options = groupNames(),
    onchange = function()
      local g = rig:groupByName(dlg.data.group)
      if g then
        rig.activeGroup = g.id
        syncGroupUi()
        save()
      end
    end }
  dlg:color{ id = "gcolor", color = g0 and Color{ r = g0.color.r, g = g0.color.g, b = g0.color.b } or Color{ r = 200, g = 160, b = 130 },
    onchange = function()
      local g = rig:getGroup(rig.activeGroup)
      local c = dlg.data.gcolor
      if g and c then
        g.color = { r = c.red, g = c.green, b = c.blue }
        rig:touch()
        save()
        repaint()
      end
    end }
  dlg:entry{ id = "gname", text = g0 and g0.name or "", onchange = function()
    local g = rig:getGroup(rig.activeGroup)
    local n = dlg.data.gname
    if not g or n == "" or n == g.name then return end
    pushUndo()
    rig:renameGroup(g.id, n)
    afterEdit()
  end }
  dlg:newrow()

  dlg:button{ text = "Assign to group", onclick = function()
    local b = rig:get(st.sel)
    if not b then return status("Select a bone first.") end
    pushUndo()
    rig:assignGroup(b, rig.activeGroup, false)
    afterEdit()
  end }
  dlg:button{ text = "Assign + children", onclick = function()
    local b = rig:get(st.sel)
    if not b then return status("Select a bone first.") end
    pushUndo()
    rig:assignGroup(b, rig.activeGroup, true)
    afterEdit()
  end }
  dlg:button{ text = "No group (helper)", onclick = function()
    local b = rig:get(st.sel)
    if not b then return status("Select a bone first.") end
    pushUndo()
    rig:assignGroup(b, 0, false)
    afterEdit()
  end }
  dlg:newrow()

  local oc = rig.outlineColor
  dlg:combobox{ id = "outline", option = rig.outline == "pixel" and "Pixel" or "None",
    options = { "None", "Pixel" },
    onchange = function()
      rig.outline = (dlg.data.outline == "Pixel") and "pixel" or "none"
      rig:touch()
      save()
      repaint()
    end }
  dlg:color{ id = "ocolor", color = Color{ r = oc.r, g = oc.g, b = oc.b },
    onchange = function()
      local c = dlg.data.ocolor
      if c then
        rig.outlineColor = { r = c.red, g = c.green, b = c.blue }
        rig:touch()
        save()
        repaint()
      end
    end }
  dlg:button{ text = "Export skin to layers", onclick = function()
    local f = (app.frame and app.frame.frameNumber) or 1
    local ok, res = Export.export(sprite, rig, f)
    if ok then
      status(string.format("Exported %d layer(s) into the 'PixRig' group.", res))
    else
      status(res)
      app.alert(res)
    end
  end }

  if hasTabs then dlg:endtabs{ id = "tabs", selected = "tabRig" } end

  dlg:separator()
  dlg:label{ id = "info", text = "No bone selected" }
  dlg:newrow()
  dlg:label{ id = "status", text = HINTS.create }

  -- Keep the backdrop in sync with edits / frame changes.
  pcall(function()
    st.listener = sprite.events:on("change", function()
      st.img = nil
      repaint()
    end)
  end)
  pcall(function()
    st.siteListener = app.events:on("sitechange", function()
      st.img = nil
      repaint()
    end)
  end)

  -------------------------------------------------------------- timeline
  local function animNames()
    local t = {}
    for _, a in ipairs(rig.anims) do t[#t + 1] = a.name end
    return t
  end

  stopPlay = function()
    st.playing = false
    if st.timer then pcall(function() st.timer:stop() end) end
    if tdlg then pcall(function() tdlg:modify{ id = "tplay", text = "Play" } end) end
    repaint()
  end

  syncFrame = function()
    clampFrame()
    if tdlg then
      local a = curAnim()
      tdlg:modify{ id = "tframe", text = string.format("Frame %d / %d  |  %s", st.frame, a.frames, a.name) }
    end
    repaint()
  end

  syncAnimUi = function()
    if not tdlg then return end
    local a = curAnim()
    tdlg:modify{ id = "tanim", options = animNames(), option = a.name }
    tdlg:modify{ id = "taname", text = a.name }
    tdlg:modify{ id = "tframes", text = tostring(a.frames) }
    tdlg:modify{ id = "tfps", text = tostring(a.fps) }
    tdlg:modify{ id = "tinterp", option = (a.interp == "step") and "Step" or "Linear" }
  end

  local function startPlay()
    local a = curAnim()
    st.playing = true
    local ok = pcall(function()
      if st.timer then st.timer:stop() end
      st.timer = Timer{
        interval = 1 / math.max(1, a.fps),
        ontick = function()
          st.frame = (st.frame % curAnim().frames) + 1
          syncFrame()
        end,
      }
      st.timer:start()
    end)
    if not ok then
      st.playing = false
      status("Playback needs Timer support, which this Aseprite build lacks.")
      return
    end
    tdlg:modify{ id = "tplay", text = "Stop" }
    repaint()
  end

  local function setFrame(f)
    st.frame = f
    syncFrame()
  end

  local function tlpaint(ev)
    local ctx = ev.context
    local W, H = ctx.width, ctx.height
    st.tlw = W
    ctx.color = COL.bg
    ctx:fillRect(Rectangle(0, 0, W, H))
    local a = curAnim()
    local n = a.frames
    local cw = W / n
    local selKeys = (st.sel ~= 0) and a.keys[string.format("%d", st.sel)] or nil
    local anyKey = {}
    for _, bk in pairs(a.keys) do
      for f in pairs(bk) do anyKey[tonumber(f)] = true end
    end
    for f = 1, n do
      local x = math.floor((f - 1) * cw)
      local w = math.max(1, math.floor(f * cw) - x - 1)
      ctx.color = (f == st.frame) and COL.tlCur or COL.tlCell
      ctx:fillRect(Rectangle(x, 0, w, H))
      if anyKey[f] then
        ctx.color = COL.tlKey
        ctx:fillRect(Rectangle(x, H - 8, w, 4))
      end
      if selKeys and selKeys[string.format("%d", f)] then
        ctx.color = COL.selLine
        ctx:fillRect(Rectangle(x, H - 16, w, 6))
      end
      if cw >= 18 then
        ctx.color = COL.text
        ctx:fillText(tostring(f), x + 3, 3)
      end
    end
  end

  local function tlset(ev)
    local W = st.tlw or 720
    local n = curAnim().frames
    local f = math.floor(ev.x / (W / n)) + 1
    f = math.max(1, math.min(n, f))
    if f ~= st.frame then setFrame(f) end
  end

  local function buildTimeline()
    tdlg = Dialog{
      title = "PixRig Timeline",
      onclose = function()
        stopPlay()
        tdlg = nil
      end,
    }

    local a0 = curAnim()
    tdlg:combobox{ id = "tanim", option = a0.name, options = animNames(),
      onchange = function()
        for _, a in ipairs(rig.anims) do
          if a.name == tdlg.data.tanim then
            rig.activeAnim = a.id
            st.frame = 1
            st.poseKey = nil
            rig:touch()
            syncAnimUi()
            syncFrame()
            save()
            return
          end
        end
      end }
    tdlg:entry{ id = "taname", text = a0.name, onchange = function()
      local n = tdlg.data.taname
      local a = curAnim()
      if n == "" or n == a.name then return end
      pushUndo()
      rig:renameAnim(a.id, n)
      afterEdit()
    end }
    tdlg:button{ text = "New", onclick = function()
      pushUndo()
      rig:addAnim()
      st.frame = 1
      afterEdit()
    end }
    tdlg:button{ text = "Delete", onclick = function()
      local a = curAnim()
      pushUndo()
      if not rig:deleteAnim(a.id) then
        st.undo[#st.undo] = nil
        status("Can't delete the last animation.")
        return
      end
      st.frame = 1
      afterEdit()
    end }
    tdlg:newrow()

    tdlg:label{ text = "Frames" }
    tdlg:number{ id = "tframes", text = tostring(a0.frames), decimals = 0, onchange = function()
      local n = math.max(1, math.min(500, math.floor(tdlg.data.tframes or 1)))
      curAnim().frames = n
      rig:touch()
      syncFrame()
      save()
    end }
    tdlg:label{ text = "FPS" }
    tdlg:number{ id = "tfps", text = tostring(a0.fps), decimals = 0, onchange = function()
      curAnim().fps = math.max(1, math.min(60, math.floor(tdlg.data.tfps or 12)))
      save()
    end }
    tdlg:combobox{ id = "tinterp", option = (a0.interp == "step") and "Step" or "Linear",
      options = { "Linear", "Step" },
      onchange = function()
        curAnim().interp = (tdlg.data.tinterp == "Step") and "step" or "linear"
        rig:touch()
        save()
        repaint()
      end }
    tdlg:label{ text = "Angle snap" }
    tdlg:combobox{ id = "tsnap", option = "Free", options = { "Free", "5", "15", "45" },
      onchange = function()
        st.angleSnap = tonumber(tdlg.data.tsnap) or 0
      end }
    tdlg:newrow()

    tdlg:canvas{
      id = "tl", width = 720, height = 46,
      onpaint = tlpaint,
      onmousedown = function(ev) st.tlDrag = true; tlset(ev) end,
      onmousemove = function(ev) if st.tlDrag then tlset(ev) end end,
      onmouseup = function() st.tlDrag = false end,
    }
    tdlg:newrow()

    tdlg:button{ text = "|<", onclick = function() setFrame(1) end }
    tdlg:button{ text = "<", onclick = function() setFrame(math.max(1, st.frame - 1)) end }
    tdlg:button{ id = "tplay", text = "Play", onclick = function()
      if st.playing then stopPlay() else startPlay() end
    end }
    tdlg:button{ text = ">", onclick = function() setFrame(math.min(curAnim().frames, st.frame + 1)) end }
    tdlg:button{ text = ">|", onclick = function() setFrame(curAnim().frames) end }
    tdlg:newrow()

    tdlg:button{ text = "Key all bones", onclick = function()
      pushUndo()
      local a = curAnim()
      for _, b in ipairs(rig.bones) do rig:setKey(a, b.id, st.frame) end
      afterEdit()
    end }
    tdlg:button{ text = "Delete key", onclick = function()
      local a = curAnim()
      if st.sel == 0 then return status("Select a bone first.") end
      if not rig:hasKey(a, st.sel, st.frame) then return status("No key on this frame for the selected bone.") end
      pushUndo()
      rig:deleteKey(a, st.sel, st.frame)
      afterEdit()
    end }
    tdlg:button{ text = "Copy pose", onclick = function()
      local a = curAnim()
      st.clip = {}
      for _, b in ipairs(rig.bones) do
        local r, dx, dy = rig:channels(a, b.id, st.frame)
        st.clip[b.id] = { r, dx, dy }
      end
      status("Pose copied from frame " .. st.frame .. ".")
    end }
    tdlg:button{ text = "Paste pose", onclick = function()
      if not st.clip then return status("Copy a pose first.") end
      pushUndo()
      local a = curAnim()
      for id, v in pairs(st.clip) do
        if rig:get(id) then rig:setKey(a, id, st.frame, v[1], v[2], v[3]) end
      end
      afterEdit()
    end }
    tdlg:newrow()

    tdlg:button{ text = "Export animation to layers", onclick = function()
      if st.playing then stopPlay() end
      local ok, res = Export.exportAnimation(sprite, rig, curAnim())
      if ok then
        status(string.format("Exported %d layer(s), %d frame(s).", res, curAnim().frames))
      else
        status(res)
        app.alert(res)
      end
    end }
    tdlg:newrow()
    tdlg:label{ id = "tframe", text = "" }
  end

  openTimeline = function()
    if tdlg then return end
    buildTimeline()
    tdlg:show{ wait = false }
    syncFrame()
  end

  dlg:show{ wait = false }
end

return M
