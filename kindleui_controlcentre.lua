--[[--
Kindle's Quick Settings panel.

The firmware's own window is `QuickSettingsWindow`, 1236x1331 at y=0 on a
Paperwhite 5 (see kindleui_geom.lua for the xwininfo dump this is derived from), i.e. it
hangs off the top edge and simply stops. It does not dim or cover what is
underneath, which is why this widget never sets `covers_fullscreen` and keeps
`self.dimen` clamped to the panel band: UIManager then only ever repaints that
band, and the page behind it stays exactly as it was.

Structurally this is ConfigDialog turned upside down. ConfigDialog anchors
itself with `BottomContainer{ dimen = Screen:getSize(), <frame> }`
(configdialog.lua:945) and closes on a tap outside the frame or a swipe south
(configdialog.lua:1491, 1501). This does the same with TopContainer and a swipe
north.

    ┌──────────────────────────────────────────┐
    │ Kindle Paperwhite            82 % [batt] │
    │ 04:32 PM • Aug 25, 2026                  │
    │                                          │
    │      (✈)        (BT)        (◐)          │
    │       On         Off     Dark Mode       │
    │             (↻)        (⚙)               │
    │            Sync    All Settings          │
    │ ──────────────────────────────────────── │
    │ Brightness                               │
    │ −  ━━━━━━(O)──────────────────────  +    │
    │ Warmth                Schedule: Off ›    │
    │ −  ━━(O)──────────────────────────  +    │
    │                                          │
    │                    ^                     │
    └──────────────────────────────────────────┘
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Layout = require("kindleui_geom") -- this plugin's proportions, not ui/geometry
local LineWidget = require("ui/widget/linewidget")
local NetworkMgr = require("ui/network/manager")
local Size = require("ui/size")
local Slider = require("kindleui_slider")
local TaskCard = require("kindleui_taskcard")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local datetime = require("datetime")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

--[[
Glyphs.

KOReader ships `nerdfonts/symbols.ttf` as fallback #6 (font.lua:114), so a plain
TextWidget holding one of these codepoints renders without asking for a special
face. Every codepoint below was checked against the copy of that font on a real
device install (/koreader/fonts/nerdfonts/symbols.ttf) by rendering it, not by
trusting a cheat sheet:

    U+E71C  airplane        (glyph name "airplane")
    U+F293  bluetooth       (FontAwesome block, unnamed gid, renders as the rune)
    U+E7DC  brightness-4    (glyph name "brightness-4", a moon in a circle)
    U+F013  cog             (glyph name "cog")
    U+F021  refresh         (glyph name "refresh", the two chasing arrows)
    U+F240  battery-full    (FontAwesome block)
    U+F077  chevron up      (glyph name "chevron_up")

Two of the Material Design codepoints originally proposed are wrong for the
font we actually ship: U+F4E6 (mdi sync) has no glyph at all in it, and U+F493
maps to "circuit-board", not a cog. This symbols.ttf predates Nerd Fonts v3, so
the whole U+F0001..U+F1AF0 MDI plane is absent. FontAwesome's refresh and cog
are used instead.
]]
local GLYPH_WIFI      = "\u{F1EB}"
local GLYPH_DARKMODE  = "\u{E7DC}"
local GLYPH_SYNC      = "\u{F021}"
local GLYPH_SETTINGS  = "\u{F013}"
local GLYPH_BATTERY   = "\u{F240}"
local GLYPH_CHEVRON_UP = "\u{F077}"

-- Kindle reference pixels, against kindleui_geom.lua's 1236x1648 panel.
local REF_SIDE_MARGIN  = 56
local REF_PAD_TOP      = 48
local REF_PAD_BOTTOM   = 28
local REF_CLOCK_H      = 36   -- "04:32 PM • Aug 25, 2026"
local REF_BATTERY_H    = 40
local REF_DISC_D       = 104
local REF_DISC_GLYPH_H = 46
local REF_DISC_LABEL_H = 32
local REF_DISC_GAP     = 14   -- between a disc and its label
local REF_SECTION_GAP  = 44
local REF_ROW_GAP      = 28
local REF_TASK_TITLE_H = 30
local REF_TASK_SUB_H   = 25
local REF_TASK_CLOSE_H = 44
local REF_CHEVRON_H    = 56
-- Distance from the last control to the chevron, measured off the firmware's own
-- panel: the warmth slider ends around y=1105 and the chevron sits near y=1245.
-- The panel is NOT stretched to Kindle's full 1331 when our content is shorter
-- than theirs -- doing that left a third of the panel empty, which reads as a
-- layout bug rather than as breathing room.
local REF_TAIL_GAP     = 48

--------------------------------------------------------------------------------
-- Disc: one circular toggle plus the caption under it.
--
-- Filled black with a white glyph when on, a black ring with a black glyph when
-- off. Drawn rather than composed because FrameContainer's radius is capped by
-- paintBorder's rounded-rect code (framecontainer.lua:104) and does not give a
-- true circle at radius == w/2.
--------------------------------------------------------------------------------
local Disc = InputContainer:extend{
    diameter = nil,
    width = nil,      -- cell width; may exceed the diameter so labels can be wide
    glyph = nil,
    icon = nil,        -- KOReader SVG icon name; wins over `glyph` when set
    label = nil,
    active = false,
    disabled = false, -- painted grey and inert
    glyph_face = nil,
    label_face = nil,
    gap = nil,
    on_tap = nil,
}

function Disc:init()
    local fg
    if self.disabled then
        fg = Blitbuffer.COLOR_GRAY
    elseif self.active then
        fg = Blitbuffer.COLOR_WHITE -- glyph sits on the filled disc
    else
        fg = Blitbuffer.COLOR_BLACK
    end
    self.ring_color = self.disabled and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK

    -- Two ways to fill the disc, because the font cannot always be trusted.
    --
    -- Every codepoint in Theme.GLYPH was verified by parsing the cmap of the
    -- symbols.ttf on the target device -- a check worth doing, since two
    -- codepoints from an early draft turned out to be absent or to render as
    -- something else entirely. An icon that cannot be verified that way has no
    -- business being guessed at, so `icon` takes the KOReader SVG route
    -- instead: IconWidget resolves from resources/icons/mdlight
    -- (iconwidget.lua:20-33), which ships with KOReader and cannot go missing
    -- the way a font subset can.
    if self.icon then
        local ok, IconWidget = pcall(require, "ui/widget/iconwidget")
        if ok and IconWidget then
            local d = math.floor(self.diameter * 0.46)
            self.glyph_widget = IconWidget:new{
                icon = self.icon, width = d, height = d,
                dim = self.disabled or nil,
                -- IconWidget has no fgcolor; on an active (filled) disc the
                -- black artwork would vanish, so an icon disc is never active.
            }
        end
    end
    if not self.glyph_widget then
        self.glyph_widget = TextWidget:new{ text = self.glyph, face = self.glyph_face, fgcolor = fg, padding = 0 }
    end
    self.label_widget = TextWidget:new{
        text = self.label,
        face = self.label_face,
        fgcolor = self.disabled and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK,
        padding = 0,
        max_width = self.width,
    }
    self.radius = math.floor(self.diameter / 2)
    self.ring_width = math.max(Size.line.thick, math.floor(self.diameter / 22))
    self.height = self.diameter + self.gap + self.label_widget:getSize().h

    self.ges_events = {
        TapDisc = {
            GestureRange:new{ ges = "tap", range = function() return self.dimen end },
        },
    }
end

function Disc:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Disc:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local cx = x + math.floor(self.width / 2)
    local cy = y + self.radius
    -- blitbuffer.lua:1948 -> paintCircle(cx, cy, r, c, w); w defaults to r, which
    -- fills the disc, so pass r for "on" and the ring width for "off".
    if self.active and not self.disabled then
        bb:paintCircle(cx, cy, self.radius, Blitbuffer.COLOR_BLACK, self.radius)
    else
        bb:paintCircle(cx, cy, self.radius, self.ring_color, self.ring_width)
    end

    local glyph_size = self.glyph_widget:getSize()
    self.glyph_widget:paintTo(bb, cx - math.floor(glyph_size.w / 2), cy - math.floor(glyph_size.h / 2))

    local label_size = self.label_widget:getSize()
    self.label_widget:paintTo(bb, x + math.floor((self.width - label_size.w) / 2),
        y + self.diameter + self.gap)
end

function Disc:onTapDisc()
    -- Swallow the tap either way, so a disabled control does not fall through
    -- to the panel's "tap outside closes me" handler.
    if not self.disabled and self.on_tap then
        self.on_tap()
    end
    return true
end

function Disc:free()
    self.glyph_widget:free()
    self.label_widget:free()
end

--------------------------------------------------------------------------------
-- Tappable: the smallest possible hit target wrapper.
--
-- InputContainer already records the painted rect in self.dimen
-- (inputcontainer.lua:66), which is all a GestureRange needs.
--------------------------------------------------------------------------------
local Tappable = InputContainer:extend{ on_tap = nil }

function Tappable:init()
    self.ges_events = {
        TapTappable = {
            GestureRange:new{ ges = "tap", range = function() return self.dimen end },
        },
    }
end

function Tappable:onTapTappable()
    if self.on_tap then self.on_tap() end
    return true
end

--------------------------------------------------------------------------------
-- ControlCentre
--------------------------------------------------------------------------------
local ControlCentre = InputContainer:extend{
    name = "kindleui_control_centre",
    modal = true,
    -- Deliberately NOT covers_fullscreen: Kindle leaves the page below visible.
}

function ControlCentre:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.panel_h = Layout.h(Layout.PANEL)
    self.side_margin = Layout.x(REF_SIDE_MARGIN)
    self.pad_top = Layout.y(REF_PAD_TOP)
    self.pad_bottom = Layout.y(REF_PAD_BOTTOM)
    self.inner_w = self.screen_w - 2 * self.side_margin

    -- Font:getFace() re-scales whatever size it is handed (font.lua:276) and
    -- getFontSizeToFitHeight measures the result in real pixels, so chaining
    -- them lands on the Kindle reference height without double-scaling.
    local function faceFor(ref_h, font)
        font = font or "cfont"
        return Font:getFace(font, TextWidget:getFontSizeToFitHeight(font, Layout.y(ref_h), 0))
    end
    self.face_clock = faceFor(REF_CLOCK_H)
    self.face_battery = faceFor(REF_BATTERY_H)
    self.face_disc_glyph = faceFor(REF_DISC_GLYPH_H)
    self.face_disc_label = faceFor(REF_DISC_LABEL_H)
    self.face_chevron = faceFor(REF_CHEVRON_H)
    -- The task card's three sizes, derived here so they scale with the panel
    -- like everything else rather than being fixed points.
    self.face_task_title = faceFor(REF_TASK_TITLE_H)
    self.face_task_sub   = faceFor(REF_TASK_SUB_H)
    self.face_task_close = faceFor(REF_TASK_CLOSE_H)

    -- Mirrors ConfigDialog (configdialog.lua:877): a screen-wide tap range whose
    -- handler decides whether the point fell outside the frame.
    self.ges_events = {
        TapClosePanel = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h },
            },
        },
        SwipeClosePanel = {
            GestureRange:new{
                ges = "swipe",
                range = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h },
            },
        },
    }

    if Device:hasKeys() then
        -- Without this a non-touch device could open the panel and never close
        -- it; ConfigDialog wires the same group at configdialog.lua:897.
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end

    self:update()
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

--- Ignore everything until the stroke that opened us has ended.
--
-- The top-band zone claims `pan` as well as `swipe`, because KOReader reports a
-- slow drag as a pan and registering only `swipe` loses the gesture for anyone
-- who does not flick. The cost is that a pan opens the panel with the finger
-- STILL DOWN, and every further event of that one stroke lands on the panel
-- that just appeared -- so a swipe carried a little too far arrives at the
-- brightness slider, which listens for `pan` (kindleui_slider.lua:132), and
-- drags it.
--
-- Nothing is inferred from position or timing here. The stroke has an end and
-- KOReader reports it (`pan_release`, gesturedetector.lua:18), so that is what
-- is waited for.
function ControlCentre:armAfterOpen()
    self._armed = true
    -- If the release never arrives -- the finger leaves past the screen edge,
    -- the event is dropped, the detector reclassifies mid-stroke -- the panel
    -- would stay inert forever. An unusable control centre is a far worse
    -- outcome than the stray drag this exists to prevent, so the wait is
    -- bounded and the bound is generous enough not to cut a slow drag short.
    UIManager:scheduleIn(2, function()
        if self._armed then
            logger.dbg("kindleui: control centre never saw its pan release, arming anyway")
            self._armed = false
        end
    end)
end

--- Gesture events go to children BEFORE the parent gets a look
-- (widgetcontainer.lua:100-107), so a slider would consume the stroke long
-- before any handler of ours ran. Intercepting here, above the propagation, is
-- the only place that can hold the whole panel back at once.
function ControlCentre:handleEvent(event)
    if self._armed and event and event.handler == "onGesture" then
        local ges = event.args and event.args[1]
        local kind = type(ges) == "table" and ges.ges or nil
        if kind == "pan_release" or kind == "swipe" or kind == "hold_release" then
            self._armed = false
        end
        -- Swallowed either way: the releasing event is the last of the opening
        -- stroke and is not an interaction the user meant to make.
        return true
    end
    return InputContainer.handleEvent(self, event)
end

function ControlCentre:_buildHeader()
    -- No device name here, unlike Kindle's own panel. Kindle shows the name you
    -- registered the device under, which lives behind lipc's
    -- `com.lab126.amazon GetDeviceName` -- a source that is not running while
    -- KOReader has the framework stopped, so it cannot be read. What was left to
    -- print was `Device.model`, i.e. the literal string "KindlePaperWhite5":
    -- true, useless, and not what the row is for.
    local powerd = Device.powerd
    local batt_text = string.format("%d%%", powerd:getCapacity())
    if powerd:isCharging() then
        batt_text = batt_text .. " " .. _("Charging")
    end
    local batt_widget = TextWidget:new{ text = batt_text, face = self.face_battery, padding = 0 }
    local batt_glyph = TextWidget:new{ text = GLYPH_BATTERY, face = self.face_battery, padding = 0 }

    local right = HorizontalGroup:new{
        align = "center",
        batt_widget,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        batt_glyph,
    }

    -- e.g. "04:32 PM • Aug 25, 2026". secondsToHour honours the user's
    -- twelve_hour_clock setting (datetime.lua:238); the date is assembled from
    -- datetime's own short month names so it follows the UI language.
    local now = os.time()
    local clock = datetime.secondsToHour(now, G_reader_settings:isTrue("twelve_hour_clock"))
    local month = datetime.shortMonthTranslation[os.date("%b", now)] or os.date("%b", now)
    local date_text = string.format("%s \u{2022} %s %s, %s",
        clock, month, os.date("%d", now), os.date("%Y", now))
    local date_widget = TextWidget:new{ text = date_text, face = self.face_clock, padding = 0 }

    -- One row: time and date left, battery right -- the same split Kindle's own
    -- titleBar uses. With the device name gone there is nothing left for a
    -- second line, and a lone battery above a lone date reads as a mistake.
    local spacer = math.max(Size.span.horizontal_default,
        self.inner_w - date_widget:getSize().w - right:getSize().w)
    return HorizontalGroup:new{
        align = "center",
        date_widget,
        HorizontalSpan:new{ width = spacer },
        right,
    }
end

--- One centred row of discs, each in a cell of `cell_w` so rows of three and of
-- two share the same rhythm.
function ControlCentre:_discRow(specs, cell_w)
    local group = HorizontalGroup:new{ align = "top" }
    local diameter = Layout.x(REF_DISC_D)
    local gap = Layout.y(REF_DISC_GAP)
    local row_h = 0
    for _idx, spec in ipairs(specs) do
        local disc = Disc:new{
            diameter = diameter,
            width = cell_w,
            gap = gap,
            glyph = spec.glyph,
            label = spec.label,
            active = spec.active,
            disabled = spec.disabled,
            glyph_face = self.face_disc_glyph,
            label_face = self.face_disc_label,
            on_tap = spec.on_tap,
        }
        table.insert(group, disc)
        row_h = math.max(row_h, disc:getSize().h)
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = self.inner_w, h = row_h },
        group,
    }
end

function ControlCentre:_buildToggles()
    -- Four discs in one row, so a quarter of the inner width each.
    local cell_w = math.floor(self.inner_w / 4)

    -- Wi-Fi, stated plainly.
    --
    -- This slot used to be an "Airplane" disc, which was the same radio with its
    -- caption inverted: airplane On meant the radio Off. That reads fine on a
    -- phone, where airplane mode covers several radios at once, and badly here,
    -- where KOReader has exactly one and no notion of airplane mode at all --
    -- the toggle underneath was always NetworkMgr's. So the disc now says what
    -- it does: On when the radio is on, and tapping it turns that radio the way
    -- the caption implies rather than the opposite way.
    --
    -- NetworkMgr:isWifiOn is manager.lua:182, the toggles are 433 and 447.
    local wifi_on = NetworkMgr:isWifiOn() and true or false
    local no_radio_control = not Device:hasWifiToggle()

    local specs = {
        {
            glyph = GLYPH_WIFI,
            label = wifi_on and _("On") or _("Off"),
            active = wifi_on,
            disabled = no_radio_control,
            on_tap = function()
                if wifi_on then
                    NetworkMgr:toggleWifiOff(nil, true)
                else
                    NetworkMgr:toggleWifiOn(nil, false, true)
                end
                self:rebuild()
            end,
        },
        {
            glyph = GLYPH_DARKMODE,
            label = _("Dark Mode"),
            active = G_reader_settings:isTrue("night_mode"),
            on_tap = function()
                -- DeviceListener:onToggleNightMode (devicelistener.lua:14) flips
                -- the setting and repaints; upstream broadcasts this from
                -- common_settings_menu_table.lua:270.
                self:_dispatch(Event:new("ToggleNightMode"))
                self:rebuild()
            end,
        },
        {
            glyph = GLYPH_SYNC,
            label = _("Sync"),
            active = false,
            on_tap = function()
                -- "XtreaderSync" is registered by a sibling plugin, not by
                -- KOReader. If that plugin is absent nothing consumes the event
                -- and the tap is a no-op, which is the intended fallback.
                self:_dispatch(Event:new("XtreaderSync"))
            end,
        },
        {
            glyph = GLYPH_SETTINGS,
            label = _("All Settings"),
            active = false,
            on_tap = function()
                -- Close first: whatever answers this lives below us in the
                -- window stack, and UIManager:sendEvent only reaches the topmost
                -- non-toast widget (uimanager.lua:915).
                --
                -- main.lua answers ShowKindleSettings and itself falls back to
                -- ShowMenu if the Kindle-style page cannot load, so this stays a
                -- working button either way.
                UIManager:close(self)
                UIManager:sendEvent(Event:new("ShowKindleSettings"))
            end,
        },
    }

    return self:_discRow(specs, cell_w)
end

--- Human-readable name of the AutoWarmth plugin's current mode.
-- The plugin persists it as `autowarmth_activate` (autowarmth.koplugin/main.lua:183)
-- with the constants declared at main.lua:34-37.
local function autoWarmthModeName()
    local mode = G_reader_settings:readSetting("autowarmth_activate") or 0
    if mode == 1 then return _("Sun")
    elseif mode == 2 then return _("Schedule")
    elseif mode == 3 then return _("Closer noon")
    elseif mode == 4 then return _("Closer midnight")
    end
    return _("Off")
end

--- Sends an event to something that can actually hear it.
--
-- `UIManager:sendEvent` only reaches the topmost non-toast widget, plus any
-- widget below it flagged `is_always_active` (uimanager.lua:915-961). While this
-- panel is open, the topmost widget IS this panel -- so every action wired
-- through sendEvent was being delivered to itself and dropped.
--
-- That is not a hypothetical: Dark Mode is handled by DeviceListener
-- (devicelistener.lua:14), Sync by the xtreader plugin, and the warmth schedule
-- by AutoWarmth (autowarmth.koplugin/main.lua:161). All three are CHILDREN of
-- ReaderUI/FileManager, all three sit below us, and all three were dead on tap.
-- Only "All Settings" worked, and only because it happens to close first.
--
-- The same actions work when bound to a gesture precisely because there is no
-- panel in the way then: ReaderUI is topmost and sendEvent finds it.
--
-- `self.ui:handleEvent` walks ReaderUI and its registered modules directly
-- (widgetcontainer.lua propagates to children), so it does not care what the
-- window stack looks like. sendEvent stays as the fallback for the case where
-- this widget was built without a ui.
function ControlCentre:_dispatch(event)
    if self.ui and self.ui.handleEvent and self.ui:handleEvent(event) then
        return true
    end
    UIManager:sendEvent(event)
    return false
end

function ControlCentre:_onScheduleTap()
    -- There is no event that opens AutoWarmth's settings page: it exists only as
    -- a main-menu submenu ("autowarmth" in reader_menu_order.lua:153) and
    -- onShowMenu only takes a tab index. What the plugin *does* register is
    -- AutoWarmthMode with no argument, which cycles through the modes
    -- (main.lua:148, handler at main.lua:161). So cycle, then check whether the
    -- persisted setting actually moved; if it did not, the plugin is not loaded
    -- and we say so rather than leaving the tap silently dead.
    local before = G_reader_settings:readSetting("autowarmth_activate") or 0
    self:_dispatch(Event:new("AutoWarmthMode"))
    local after = G_reader_settings:readSetting("autowarmth_activate") or 0
    if before == after then
        UIManager:show(InfoMessage:new{
            text = _("Auto warmth is not available. Enable the AutoWarmth plugin to schedule warmth changes."),
        })
    else
        self:rebuild()
    end
end

function ControlCentre:_buildSliders()
    local items = {}
    local powerd = Device.powerd

    if Device:hasFrontlight() then
        table.insert(items, Slider:new{
            label = _("Brightness"),
            min = powerd.fl_min,
            max = powerd.fl_max,
            value = powerd:frontlightIntensity(),
            width = self.inner_w,
            callback = function(value)
                -- setIntensity takes the native scale (powerd.lua:215).
                powerd:setIntensity(value)
            end,
        })
    end

    if Device:hasNaturalLight() then
        -- The two scales differ and it is easy to get wrong: fl_warmth_min/max
        -- are the *native* range, while frontlightWarmth() and setWarmth() speak
        -- KOReader's 0..100 scale (powerd.lua:242). FrontLightWidget converts the
        -- same way at frontlightwidget.lua:71. Driving the slider in native units
        -- means one step of the slider is one step of the hardware.
        if #items > 0 then
            table.insert(items, VerticalSpan:new{ width = Layout.y(REF_ROW_GAP) })
        end
        table.insert(items, Slider:new{
            label = _("Warmth"),
            label_right = string.format("%s: %s \u{203A}", _("Schedule"), autoWarmthModeName()),
            label_right_callback = function() self:_onScheduleTap() end,
            min = powerd.fl_warmth_min,
            max = powerd.fl_warmth_max,
            value = powerd:toNativeWarmth(powerd:frontlightWarmth()),
            width = self.inner_w,
            callback = function(value)
                powerd:setWarmth(powerd:fromNativeWarmth(value))
            end,
        })
    end

    return items
end

function ControlCentre:update()
    if self.panel_frame then
        -- Rebuilt on every toggle, so release the old glyph caches.
        self.panel_frame:free()
    end

    local section_gap = Layout.y(REF_SECTION_GAP)

    local items = {}
    table.insert(items, self:_buildHeader())
    table.insert(items, VerticalSpan:new{ width = section_gap })

    table.insert(items, self:_buildToggles())
    table.insert(items, VerticalSpan:new{ width = section_gap })

    table.insert(items, LineWidget:new{
        dimen = Geom:new{ w = self.inner_w, h = Size.line.medium },
    })
    table.insert(items, VerticalSpan:new{ width = section_gap })

    for _idx, slider in ipairs(self:_buildSliders()) do
        table.insert(items, slider)
    end

    -- Background work, BELOW the sliders. Above them it would push the controls
    -- the panel exists for down the screen every time a job ran; below, the
    -- panel a reader knows stays where they know it and the card appears in the
    -- slack at the bottom.
    local card = TaskCard.build(self.inner_w, {
        title = self.face_task_title,
        sub   = self.face_task_sub,
        close = self.face_task_close,
    }, function() self:rebuild() end)
    if card then
        table.insert(items, VerticalSpan:new{ width = Layout.y(REF_ROW_GAP) })
        table.insert(items, card)
    end

    local chevron = Tappable:new{
        on_tap = function() UIManager:close(self) end,
        CenterContainer:new{
            dimen = Geom:new{ w = self.inner_w, h = Layout.y(REF_CHEVRON_H) },
            -- The status bar shows this glyph mirrored (pointing down) as the
            -- pull-down hint; up here it means "push me back".
            TextWidget:new{ text = GLYPH_CHEVRON_UP, face = self.face_chevron, padding = 0 },
        },
    }

    -- Pad so the chevron sits on the panel's bottom edge. If the content is
    -- already taller than Kindle's band (a much shorter screen), let the content
    -- win rather than clipping controls off the bottom.
    local content_h = 0
    for _idx, widget in ipairs(items) do
        content_h = content_h + widget:getSize().h
    end
    content_h = content_h + chevron:getSize().h
    -- Kindle closes the panel with a rule against the page below. That rule is
    -- part of the 1331px band, not an addition to it, so the frame gives up
    -- exactly its height -- otherwise the panel would sit one rule lower than
    -- the firmware's and every measurement below it would drift.
    local rule_h = Size.line.thick
    local frame_h = self.panel_h - rule_h
    local available = self.panel_h - rule_h - self.pad_top - self.pad_bottom
    if available > content_h then
        -- Take the slack only up to Kindle's own tail gap, then shrink the panel
        -- to whatever is left. Filling the full band would be faithful to the
        -- number and wrong to the eye.
        local slack = math.min(available - content_h, Layout.y(REF_TAIL_GAP))
        table.insert(items, VerticalSpan:new{ width = slack })
        frame_h = self.pad_top + content_h + slack + self.pad_bottom
    else
        logger.warn("kindleui: control centre content is", content_h,
            "px but the Kindle panel band is only", available,
            "px; growing the panel instead of clipping it")
        frame_h = content_h + self.pad_top + self.pad_bottom
    end
    table.insert(items, chevron)

    local content = VerticalGroup:new{ align = "left" }
    for _idx, widget in ipairs(items) do
        table.insert(content, widget)
    end

    self.panel_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = 0,
        padding_left = self.side_margin,
        padding_right = self.side_margin,
        padding_top = self.pad_top,
        padding_bottom = self.pad_bottom,
        -- FrameContainer paints its background over width x height
        -- (framecontainer.lua:118) even though getSize reports the content box,
        -- which is how the panel fills the band exactly.
        width = self.screen_w,
        height = frame_h,
        content,
    }
    self.panel_h_actual = frame_h + rule_h

    -- The rule is full-bleed, so it cannot live inside panel_frame: that frame
    -- carries side padding for the content, and a LineWidget in there would stop
    -- short of both screen edges.
    self[1] = TopContainer:new{
        dimen = Screen:getSize(),
        VerticalGroup:new{
            align = "left",
            self.panel_frame,
            LineWidget:new{
                dimen = Geom:new{ w = self.screen_w, h = rule_h },
            },
        },
    }

    -- The band, and only the band. UIManager refreshes setDirty regions against
    -- this, so the document below is never touched.
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = frame_h + rule_h }
end

--- Rebuild after a toggle so the captions match the new state.
function ControlCentre:rebuild()
    self:update()
    UIManager:setDirty(self, "ui", self.dimen)
end

function ControlCentre:paintTo(bb, x, y)
    -- Not InputContainer's version: that one would derive self.dimen from the
    -- full-screen TopContainer and we would repaint the whole display.
    self[1]:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
end

--- Repaint the panel once a second while a background job is running.
--
-- Only while the panel is OPEN, and only while something is actually moving:
-- the point of a background job is that it costs nothing when nobody is
-- looking, and a timer that survives the panel would spend a wakeup a second
-- redrawing a widget that is not on screen -- on a device where that is
-- battery.
--
-- The e-ink cost is why it is one second and not faster. Each tick is a real
-- partial refresh of the card's rectangle; at four a second the panel would
-- visibly churn and the figures would be no more useful.
function ControlCentre:_scheduleTick()
    self:_cancelTick()
    if not TaskCard.isLive() then return end
    self._tick = function()
        if not TaskCard.isLive() then
            -- One last repaint so the card settles on its finished state
            -- instead of freezing mid-progress.
            self:rebuild()
            self._tick = nil
            return
        end
        self:rebuild()
        UIManager:scheduleIn(1, self._tick)
    end
    UIManager:scheduleIn(1, self._tick)
end

function ControlCentre:_cancelTick()
    if self._tick then
        UIManager:unschedule(self._tick)
        self._tick = nil
    end
end

function ControlCentre:onShow()
    self:_scheduleTick()
end

function ControlCentre:onCloseWidget()
    -- The timer must not outlive the panel: it repaints self.dimen, and after a
    -- close that rectangle belongs to the document underneath.
    self:_cancelTick()
    -- Same reasoning as ConfigDialog:onCloseWidget (configdialog.lua:955): the
    -- widgets underneath have to be redrawn where we were, and nowhere else.
    UIManager:setDirty(nil, "ui", self.dimen)
end

function ControlCentre:onTapClosePanel(_, ges_ev)
    if ges_ev.pos.y >= self.dimen.h then
        UIManager:close(self)
    end
    -- Taps inside the panel that reached us missed every control; swallow them
    -- so they do not fall through to the document.
    return true
end

function ControlCentre:onSwipeClosePanel(_, ges_ev)
    if ges_ev.direction == "north" then
        UIManager:close(self)
        return true
    end
end

function ControlCentre:onClose()
    UIManager:close(self)
    return true
end

return ControlCentre
