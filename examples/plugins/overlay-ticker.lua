-- Puts a lower third on the shared window: a logo, a clock, and a line of text pulled
-- from an HTTP API every 30 seconds.
--
-- Copy to ~/.config/virtual-display/plugins/, edit LOGO and API, then Reload Plugins.
-- Overlays are drawn in the window meetings share, so everyone on the call sees them.

local LOGO = os.getenv("HOME") .. "/Pictures/logo.png"
local API = "https://worldtimeapi.org/api/timezone/Etc/UTC"
local REFRESH = 30

local visible = false

local function band()
    vd.overlay("band", { background = "#000000cc", x = 0, y = 0.86, w = 1, h = 0.14 })
    vd.overlay("logo", { image = LOGO, x = 0.02, y = 0.88, h = 0.10 })
end

local function clock()
    if not visible then return end
    vd.overlay("clock", {
        text = os.date("%H:%M"),
        x = 0.98, y = 0.89, size = 44, align = "right", color = "#ffffff",
    })
    vd.timer(1, clock)
end

local function headline()
    if not visible then return end

    vd.fetch(API, { headers = { Accept = "application/json" } }, function(res)
        -- res: body, status, ok, error. Never raises; check and carry on.
        local text = res.ok and res.body:sub(1, 60) or ("offline: " .. res.error)
        vd.overlay("headline", {
            text = text,
            x = 0.5, y = 0.895, size = 34, align = "center", color = "#66ff99",
        })
    end)

    vd.timer(REFRESH, headline)
end

local function show(on)
    visible = on
    if on then
        band()
        clock()
        headline()
    else
        vd.clear_overlays()
    end
end

-- Only while you are actually sharing.
vd.on("mirroring", function(event) show(event.on == true) end)

vd.menu("Toggle lower third", function() show(not visible) end)
vd.hotkey("ctrl-opt-cmd-l", function() show(not visible) end)
