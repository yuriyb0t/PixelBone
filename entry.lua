-- PixelBone entry.  All Lua modules are embedded by build.py.
local function runWindow(module)
  __reset()
  local handler = (debug and debug.traceback) or tostring
  local ok, err = xpcall(function() __req(module).open() end, handler)
  if not ok then
    local lines = {}
    for l in tostring(err):gmatch("[^\r\n]+") do
      lines[#lines + 1] = l
      if #lines >= 14 then break end
    end
    print(tostring(err))
    app.alert{ title="PixelBone error", text=lines }
  end
end

function init(plugin)
  plugin:newCommand{
    id="PixelBoneOpen", title="PixelBone 0.8.2...", group="file_scripts",
    onenabled=function() return app.sprite ~= nil end,
    onclick=function() runWindow("pixrig.ui") end,
  }
end

function exit(plugin)
end
