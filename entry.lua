-- PixRig entry point (source). build.py bundles every module plus this file
-- into a single main.lua, so the extension needs no require() at runtime.
-- The bundle prelude provides __req (module loader) and __reset (cache clear).

function init(plugin)
  plugin:newCommand{
    id = "PixRigOpen",
    title = "PixRig...",
    group = "file_scripts",
    onenabled = function() return app.sprite ~= nil end,
    onclick = function()
      __reset()
      local handler = (debug and debug.traceback) or tostring
      local ok, err = xpcall(function() __req("pixrig.ui").open() end, handler)
      if not ok then
        -- Aseprite's console shows only the first line of an error, so show
        -- the full message (and traceback) in an alert instead.
        local lines = {}
        for l in tostring(err):gmatch("[^\r\n]+") do
          lines[#lines + 1] = l
          if #lines >= 14 then break end
        end
        print(tostring(err))
        app.alert{ title = "PixRig error", text = lines }
      end
    end
  }
end

function exit(plugin)
end
