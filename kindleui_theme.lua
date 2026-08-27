--[[
The shared visual vocabulary, so five screens look like one product.

Kindle's design language is narrow and consistent, and three of its rules exist
because the panel is e-ink rather than because someone liked the look:

  * Selection is NEVER a filled background. The current chapter in Go To is bold
    with a bar in the left margin; the current theme in the Aa menu is a tick
    floating above its card. A fill would repaint that whole region on every
    scroll, and on e-ink a repaint is a visible flash.
  * Icon weight flips with context. Solid glyphs in the settings list, hollow
    rings in the control centre. Nothing is half-way.
  * Rules carry hierarchy. A hairline separates rows, a thick rule separates
    sections, and every panel closes against the page with one.

GLYPHS

All of these were verified present by parsing the cmap of the exact
`fonts/nerdfonts/symbols.ttf` on the target device, not taken from a cheat
sheet. That matters: the shipped file predates Nerd Fonts v3, so the whole
U+F0001..U+F1AF0 Material Design plane is missing, and two codepoints from a
first draft (U+F4E6 "sync", U+F493 "cog") were absent or wrong. Anything added
here later must be checked the same way.

KOReader registers this font as fallback #6 (font.lua:114), so a plain
TextWidget holding one of these renders with no special face.
]]

local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local Layout = require("kindleui_geom")
local Screen = Device.screen

local Theme = {}

Theme.GLYPH = {
    airplane   = "\u{E71C}",
    darkmode   = "\u{E7DC}",
    search     = "\u{F002}",
    user       = "\u{F007}",
    grid       = "\u{F00A}",
    check      = "\u{F00C}",
    close      = "\u{F00D}",
    cog        = "\u{F013}",
    home       = "\u{F015}",
    clock      = "\u{F017}",
    sync       = "\u{F021}",
    tags       = "\u{F02C}",
    book       = "\u{F02D}",
    bookmark   = "\u{F02E}",
    font       = "\u{F031}",
    toc        = "\u{F03A}",
    adjust     = "\u{F042}",
    chev_left  = "\u{F053}",
    chev_right = "\u{F054}",
    question   = "\u{F059}",
    arrow_left = "\u{F060}",
    chev_up    = "\u{F077}",
    chev_down  = "\u{F078}",
    folder     = "\u{F07B}",
    chart      = "\u{F080}",
    mobile     = "\u{F10B}",
    info       = "\u{F129}",
    ellipsis_v = "\u{F142}",
    sun        = "\u{F185}",
    moon       = "\u{F186}",
    bank       = "\u{F19C}",
    wifi       = "\u{F1EB}",
    battery    = "\u{F240}",
    note       = "\u{F249}",
    bluetooth  = "\u{F293}",
}

-- Kindle reference pixels, measured from xwininfo dumps + screenshots of a real
-- PW5. See kindleui_geom.lua for the window rects these came from.
Theme.REF = {
    side_margin   = 56,
    row_h         = 137,  -- a settings list row
    row_inset     = 33,   -- hairlines stop this far from each edge
    title_bar_h   = 115,  -- the icon toolbar (firmware calls it "searchBar")
    book_bar_h    = 126,  -- the book-title strip ("appToolBar")
    icon_h        = 46,
    title_h       = 44,   -- bold row label
    sub_h         = 32,   -- the grey second line
    heading_h     = 48,   -- a screen title, e.g. "Settings"
    tab_h         = 42,
    gap           = 28,
}

--- A face sized so its rendered height matches a Kindle reference measurement.
-- Font:getFace re-applies Screen:scaleBySize to whatever size it is given
-- (font.lua:276) and getFontSizeToFitHeight measures the result in real pixels,
-- so chaining them lands on the reference height without double-scaling.
function Theme.face(ref_h, font)
    font = font or "cfont"
    return Font:getFace(font, TextWidget:getFontSizeToFitHeight(font, Layout.y(ref_h), 0))
end

--- Bold face. `tfont` is NotoSans-Bold (font.lua:44).
function Theme.faceBold(ref_h)
    return Theme.face(ref_h, "tfont")
end

function Theme.margin()  return Layout.x(Theme.REF.side_margin) end
function Theme.innerW()  return Screen:getWidth() - 2 * Theme.margin() end

--- A hairline, inset from both screen edges the way Kindle's row separators are.
function Theme.hairline(width)
    return LineWidget:new{
        dimen = Geom:new{ w = width or Theme.innerW(), h = Size.line.thin },
    }
end

--- A full-bleed rule, used to close a panel against the page below it.
function Theme.rule(weight)
    return LineWidget:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = weight or Size.line.thick },
    }
end

--------------------------------------------------------------------------------
-- Tappable: wraps any widget with a tap handler.
--
-- Every screen needs this and none of them needs anything more elaborate, so it
-- lives here rather than being reinvented four times.
--------------------------------------------------------------------------------
local Tappable = InputContainer:extend{
    on_tap = nil,
    -- Set when the row should render but not respond (Bluetooth in the control
    -- centre, an option the device cannot support). Callers grey the content;
    -- this only swallows the tap.
    inert = false,
}

function Tappable:init()
    if not self[1] then return end
    self.dimen = self[1]:getSize()
    if not Device:isTouchDevice() then return end
    local GestureRange = require("ui/gesturerange")
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function Tappable:paintTo(bb, x, y)
    -- The dimen has to be refreshed on every paint, not just at init: the
    -- parent group decides where this lands, and a stale rect would route taps
    -- to wherever the widget used to be.
    self.dimen = self[1]:getSize()
    self.dimen.x, self.dimen.y = x, y
    return InputContainer.paintTo(self, bb, x, y)
end

--- Tap, with the flash every touch target needs.
--
-- A control that does nothing visible when you press it reads as broken, and on
-- e-ink the lag before a callback's own repaint is long enough for that doubt to
-- set in. So the sequence below is Button's, not an invention
-- (button.lua:450-513), and the order matters at every step:
--
--   invert -> forceRePaint drains the queue NOW, so the highlight is seen on its
--   own rather than coalesced into whatever the callback paints;
--   yieldToEPDC hands the kernel a slice, because writing to a framebuffer
--   region we just asked the EPDC to read is racy and shows up as a papercut
--   glitch;
--   un-invert is PAINTED but not fenced, so it blends into the callback's own
--   refresh instead of delaying it -- and it happens BEFORE the callback,
--   while this widget is still guaranteed to exist. A callback that closes its
--   own panel would otherwise leave us un-inverting a freed widget.
--
-- `flash_ui` is a real user setting (button.lua:453); someone who turned the
-- flashing off did so deliberately and does not want ours either.
function Tappable:onTap()
    if self.inert then return true end
    if not self.on_tap then return true end

    local UIManager = require("ui/uimanager")
    if not self.dimen or G_reader_settings:isFalse("flash_ui") then
        self.on_tap()
        return true
    end

    local d = self.dimen
    UIManager:widgetInvert(self, d.x, d.y, d.w, d.h)
    UIManager:setDirty(nil, "fast", d)
    UIManager:forceRePaint()
    UIManager:yieldToEPDC()

    UIManager:widgetInvert(self, d.x, d.y, d.w, d.h)
    UIManager:setDirty(nil, "fast", d)

    self.on_tap()
    UIManager:forceRePaint()
    return true
end

Theme.Tappable = Tappable

return Theme
