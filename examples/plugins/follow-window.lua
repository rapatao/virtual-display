-- Keeps the region glued to a particular app's window while mirroring runs.
--
-- Copy to ~/.config/virtual-display/plugins/, edit APP, then Reload Plugins.
-- Everything here is the whole API: commands, events, timers, a shortcut, a menu item.

local APP = "Preview"
local INTERVAL = 0.5

local following = false

local function windowOf(app)
    for _, w in ipairs(vd.windows()) do
        if w.app == app then return w end
    end
end

local function follow()
    if not following then return end

    local w = windowOf(APP)
    if w then
        local region = vd.region()
        -- Only move when it actually moved: set-region re-arms the capture.
        if region.x ~= w.x or region.y ~= w.y or region.w ~= w.w or region.h ~= w.h then
            vd.command("set-region", { x = w.x, y = w.y, w = w.w, h = w.h })
        end
    end

    vd.timer(INTERVAL, follow)   -- one-shot timers, so re-arm to repeat
end

local function setFollowing(on)
    following = on
    vd.log("following " .. APP .. ": " .. tostring(on))
    if on then follow() end
end

-- Stop following when mirroring stops: nothing to follow into.
vd.on("mirroring", function(event)
    if event.on == false then setFollowing(false) end
end)

vd.menu("Follow " .. APP, function() setFollowing(not following) end)
vd.hotkey("ctrl-opt-cmd-f", function() setFollowing(not following) end)

-- Also reachable as: open 'virtualdisplay://follow?on=true'
vd.register("follow", function(args)
    setFollowing(args.on ~= "false")
    return tostring(following)
end)

-- A preset this workflow wants and the app does not ship.
vd.preset("Notes strip", 700, 1000)
