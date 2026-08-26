--[[--
Clock / date / lunar date / quote, painted over the screensaver wallpaper.

    ┌──────────────────────────────────────────┐
    │                                          │
    │            (the wallpaper, untouched)    │
    │                                          │
    │  21:04                                   │
    │  Thứ Ba, 25 tháng 8, 2026                │
    │  13 tháng 7 · Bính Ngọ                   │
    │                                          │
    │  "Sách là nơi cất giữ những giấc mơ"     │
    │  — Tác giả, Tên sách                     │
    │                                          │
    └──────────────────────────────────────────┘

Three decisions here are not stylistic, and each of them is forced by something
in KOReader or in the panel:

ADAPTIVE COLOUR IS SAMPLED FROM THE FRAMEBUFFER, NOT FROM A FILE.

    This widget is shown on top of ScreenSaverWidget, so by the time our
    paintTo runs the wallpaper has already been composited into the very
    blitbuffer we are handed (uimanager.lua:1398 hands out Screen.bb; the
    screensaver below us painted into the same one). Reading the pixels back
    therefore works for *every* screensaver mode - a file, a book cover, the
    last page read - and not only for images we could have opened ourselves.

    It has to be adaptive: across the user's own wallpaper set the mean
    luminance runs from 2 to 251, so any fixed ink colour is provably invisible
    at one end of that range.

THE GLOW IS AN OUTLINE, BECAUSE THERE IS NO BLUR.

    blitbuffer.lua has no blur, gaussian or convolution primitive of any kind -
    its whole drawing vocabulary is fills, blits, rects, circles and dithering.
    So a soft halo is not on the menu, and legibility has to come from painting
    each line eight times at small offsets in the opposite colour before
    painting it once on top. Nine passes per line, and the radius stays at
    REF_GLOW_R: on e-ink a fat outline closes up the counters of the letters,
    and the quote is the smallest text on screen so it is the first to turn to
    mush.

    Deliberately NOT a scrim, a box or a FrameContainer background. That is also
    why the quote is wrapped by hand into TextWidgets instead of handed to
    TextBoxWidget: TextBoxWidget fills its internal buffer with `bgcolor` and
    blits it opaquely (textboxwidget.lua:862 and :1277), i.e. it would paint a
    white rectangle over the wallpaper. TextWidget blits glyph coverage only
    (textwidget.lua:369-375), which is what we need.

TWO REFRESH BANDS, BECAUSE THE CLOCK TICKS AND NOTHING ELSE DOES.

    The date, the lunar date and the quote change once a day; the time changes
    every minute. Waking every minute to push a full-screen e-ink refresh would
    be a battery bug and a visible flash, so the painted area is exposed as two
    separate rects, `clock_dimen` and `rest_dimen`, and `updateClock()`
    repaints only the first one.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local Layout = require("kindleui_geom") -- this plugin's proportions, not ui/geometry
local TextWidget = require("ui/widget/textwidget")
local Theme = require("kindleui_theme")
local UIManager = require("ui/uimanager")
local datetime = require("datetime")
local logger = require("logger")
local Screen = Device.screen

-- Kindle reference pixels, against kindleui_geom.lua's 1236x1648 panel.
local REF_BOTTOM_GAP  = 150  -- from the bottom edge to the bottom of the block
local REF_TIME_H      = 156
local REF_DATE_H      = 46
local REF_LUNAR_H     = 34
local REF_QUOTE_H     = 32
local REF_ATTRIB_H    = 26
-- Between the time and the date. Must stay wider than 2*REF_GLOW_R, or the two
-- refresh bands would overlap and a clock-only repaint would eat the top of the
-- date line's outline. _computeBands() clamps for it as well, belt and braces.
local REF_GAP_TIME    = 14
local REF_GAP_DATE    = 8    -- date -> lunar
local REF_GAP_BLOCK   = 46   -- the breathing space before the quote
local REF_GAP_ATTRIB  = 12   -- quote -> attribution
local REF_QUOTE_LEAD  = 10   -- between two wrapped lines of the quote
local REF_GLOW_R      = 3

-- A quote set at the full text width reads as a paragraph, not as an epigraph.
local QUOTE_WIDTH_FRAC = 0.8
-- Past this the block starts climbing towards the middle of the wallpaper.
-- Anything longer is cut with an ellipsis rather than allowed to push upwards.
local QUOTE_MAX_LINES = 4

-- Luminance sampling. Every 6th pixel on both axes is ~36x fewer reads than the
-- full rect, and the answer only has to survive one comparison against a
-- midpoint, so the sampling error is irrelevant.
local SAMPLE_STRIDE = 6
local LUMA_MIDPOINT = 128

-- The eight directions of the outline: four axes, four diagonals.
local GLOW_OFFSETS = {
    { -1,  0 }, { 1,  0 }, { 0, -1 }, { 0,  1 },
    { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1,  1 },
}

-- os.date("*t").wday is 1 = Sunday .. 7 = Saturday.
local VI_WEEKDAY = {
    "Chủ Nhật", "Thứ Hai", "Thứ Ba", "Thứ Tư", "Thứ Năm", "Thứ Sáu", "Thứ Bảy",
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- A face at a Kindle reference height, or the default face if that font is
-- missing. Font:getFace returns nil for a font it cannot open (font.lua:330)
-- and TextWidget:getFontSizeToFitHeight dereferences `face.ftsize` without
-- checking (textwidget.lua:84), so an absent font file is a crash, not a
-- fallback. In a screensaver that is the worst possible place to find out.
local function safeFace(ref_h, font)
    local ok, face = pcall(Theme.face, ref_h, font)
    if ok and face then return face end
    logger.warn("kindleui: lockscreen font", font, "unavailable, using the default face")
    return Theme.face(ref_h)
end

--- The italic serif used for the quote.
--
-- NotoSerif-Italic.ttf is shipped but is *not* in Font.fontmap, so every
-- Font:getFace call for it misses the direct `./fonts/<name>` path and falls
-- through to a scan of the whole font list (font.lua:316-328).
-- getFontSizeToFitHeight probes one size per pixel counting down from the
-- target height, which would be a hundred-odd scans for one face. So the size
-- is borrowed from the sans face that was already fitted to the same reference
-- height: both are Noto, their vertical metrics are close enough that the
-- difference is invisible at 32 reference px, and this costs exactly one lookup.
local function quoteFace(ref_h)
    local sans = Theme.face(ref_h)
    local ok, serif = pcall(Font.getFace, Font, "NotoSerif-Italic.ttf", sans.orig_size)
    if ok and serif then return serif end
    logger.warn("kindleui: lockscreen has no italic serif, falling back to the default face")
    return sans
end

--- Greedy word wrap, measured with the same widget that will do the painting.
--
-- Measuring through TextWidget rather than RenderText matters: TextWidget goes
-- through xtext/HarfBuzz shaping (textwidget.lua:185-193) and RenderText does
-- not, so a RenderText measurement would disagree with the painted width on
-- exactly the text we care about - Vietnamese, with its stacked diacritics.
-- One widget is reused via setText, which frees the previous shaping
-- (textwidget.lua:317-324), instead of building one per candidate line.
local function wrapText(text, face, max_w)
    local probe = TextWidget:new{ text = "", face = face, padding = 0 }
    local lines, current = {}, nil
    for word in text:gmatch("%S+") do
        local candidate = current and (current .. " " .. word) or word
        probe:setText(candidate)
        if probe:getWidth() <= max_w then
            current = candidate
        elseif current then
            lines[#lines + 1] = current
            current = word
        else
            -- A single word wider than the measure. Let it overhang rather than
            -- breaking it mid-diacritic; a URL in a quote is not worth the code.
            lines[#lines + 1] = word
        end
    end
    if current then lines[#lines + 1] = current end
    probe:free()

    if #lines > QUOTE_MAX_LINES then
        for i = #lines, QUOTE_MAX_LINES + 1, -1 do
            lines[i] = nil
        end
        lines[QUOTE_MAX_LINES] = lines[QUOTE_MAX_LINES] .. "\u{2026}"
    end
    return lines
end

--- Paints one line nine times: eight outline passes, then the ink.
--
-- `fgcolor` is read at paint time and nothing about it is cached in the widget
-- (textwidget.lua:346 and :375), so flipping it between passes reuses the
-- shaping from the first pass. Doing this with nine separate TextWidgets would
-- shape the same string nine times.
local function paintGlowed(widget, bb, x, y, ink, glow, radius)
    widget.fgcolor = glow
    for i = 1, #GLOW_OFFSETS do
        local off = GLOW_OFFSETS[i]
        widget:paintTo(bb, x + off[1] * radius, y + off[2] * radius)
    end
    widget.fgcolor = ink
    widget:paintTo(bb, x, y)
end

--------------------------------------------------------------------------------
-- LockScreen
--------------------------------------------------------------------------------

local LockScreen = InputContainer:extend{
    name = "kindleui_lockscreen",
    modal = true,
    -- Deliberately NOT covers_fullscreen: the whole point is that the wallpaper
    -- underneath stays visible and stays unrepainted.

    -- The two refresh bands, in screen coordinates once painted.
    clock_dimen = nil, -- the time line alone
    rest_dimen = nil,  -- date + lunar + quote + attribution
}

function LockScreen:init()
    self.glow_r = math.max(1, Layout.x(REF_GLOW_R))
    self.margin = Theme.margin()
    self.inner_w = Theme.innerW()

    self.show_clock = G_reader_settings:nilOrTrue("kindleui_lock_clock")
    self.show_date  = G_reader_settings:nilOrTrue("kindleui_lock_date")
    self.show_lunar = G_reader_settings:nilOrTrue("kindleui_lock_lunar")
    self.show_quote = G_reader_settings:nilOrTrue("kindleui_lock_quote")

    -- Each entry is { w = TextWidget, x, y, h }, positioned relative to the
    -- paint origin. Painting is a flat walk of this list; there is no container
    -- hierarchy because nothing here needs one and a VerticalGroup would give
    -- us a single rect where we need two.
    self.items = {}
    self.clock_item = nil

    self:_build()
    self:_computeBands()

    -- No gestures, on purpose.
    --
    -- ScreenSaverWidget already owns a screen-wide tap that dismisses the
    -- screensaver (screensaverwidget.lua:22-26), and ScreenSaverLockWidget owns
    -- the unlock gesture. We sit above both. UIManager:sendEvent offers an
    -- event to the topmost non-toast widget first, and only if *nobody*
    -- returned true does it keep walking down the window stack
    -- (uimanager.lua:915-946). So a widget that registers nothing is
    -- transparent to input: the tap reaches the screensaver exactly as it would
    -- if we were not here. Registering even a swallowing handler would strand
    -- the user on a lock screen they cannot dismiss.
end

--- The time, honouring the user's 12/24h preference.
--
-- `twelve_hour_clock` is the setting KOReader itself reads for every clock it
-- draws - the footer does it at readerfooter.lua:236, and datetime does it as
-- its own default at datetime.lua:298-299. secondsToHour (datetime.lua:239)
-- returns "%H:%M" or "%-I:%M AM/PM" accordingly, already translated.
local function clockText()
    return datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
end

--- "Thứ Ba, 25 tháng 8, 2026".
--
-- Written out in Vietnamese rather than run through gettext: this is a
-- Vietnamese lock screen by design, and datetime's month names follow the UI
-- language, which is not the same choice.
local function dateText()
    local t = os.date("*t")
    return string.format("%s, %d tháng %d, %d",
        VI_WEEKDAY[t.wday] or "", t.day, t.month, t.year)
end

--- A sibling module, or nil. Both of these are optional: a missing or broken
-- one drops its line and leaves the rest of the screen alone. Failing to draw
-- a quote is a blank space; throwing inside a screensaver paint is a device
-- that looks bricked until the next power cycle.
local function optionalModule(name)
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then return mod end
    logger.warn("kindleui: lockscreen could not load", name)
    return nil
end

function LockScreen:_append(text, face, gap_above, leading)
    if not text or text == "" then return nil end
    local widget = TextWidget:new{ text = text, face = face, padding = 0 }
    local item = {
        w = widget,
        h = widget:getSize().h,
        gap = gap_above,
        -- Wrapped quote lines sit closer together than two different elements do.
        lead = leading,
    }
    self.items[#self.items + 1] = item
    return item
end

function LockScreen:_build()
    if self.show_clock then
        self.clock_item = self:_append(clockText(), safeFace(REF_TIME_H), 0)
    end
    if self.show_date then
        self:_append(dateText(), safeFace(REF_DATE_H), REF_GAP_TIME)
    end
    if self.show_lunar then
        local Lunar = optionalModule("kindleui_lunar")
        if Lunar then
            local ok, text = pcall(function() return Lunar.format(Lunar.today()) end)
            if ok then
                self:_append(text, safeFace(REF_LUNAR_H), REF_GAP_DATE)
            else
                logger.warn("kindleui: lunar date failed:", text)
            end
        end
    end
    if self.show_quote then
        self:_buildQuote()
    end
end

function LockScreen:_buildQuote()
    local Quotes = optionalModule("kindleui_quotes")
    if not Quotes then return end
    local ok, quote = pcall(Quotes.ofTheDay)
    if not ok or type(quote) ~= "table" or not quote.q then
        logger.warn("kindleui: quote of the day failed:", quote)
        return
    end

    local face = quoteFace(REF_QUOTE_H)
    local max_w = math.floor(self.inner_w * QUOTE_WIDTH_FRAC)
    -- U+201C / U+201D. Curly quotes, because the serif italic has them and a
    -- straight ASCII quote next to Vietnamese diacritics looks like a typo.
    local lines = wrapText("\u{201C}" .. quote.q .. "\u{201D}", face, max_w)

    for i = 1, #lines do
        -- Only the first line gets the block gap; the rest are one paragraph.
        self:_append(lines[i], face, i == 1 and REF_GAP_BLOCK or REF_QUOTE_LEAD)
    end
    if #lines == 0 then return end

    local attrib = quote.a
    if attrib and attrib ~= "" then
        if quote.b and quote.b ~= "" then
            attrib = attrib .. ", " .. quote.b
        end
        -- U+2014 with a hair of space, the conventional attribution dash.
        self:_append("\u{2014} " .. attrib, safeFace(REF_ATTRIB_H), REF_GAP_ATTRIB)
    end
end

--- Lays the block out bottom-up and derives the two refresh rects.
function LockScreen:_computeBands()
    local zero = function()
        return Geom:new{ x = 0, y = 0, w = 0, h = 0 }
    end

    if #self.items == 0 then
        -- Everything switched off. Zero height, and paintTo bails immediately.
        self.has_content = false
        self.dimen, self.clock_dimen, self.rest_dimen = zero(), zero(), zero()
        return
    end
    self.has_content = true

    -- Whichever element ends up first carries its own leading gap (the date
    -- expects to follow a clock, the quote expects to follow the lunar line).
    -- With the elements above it switched off that gap is dead space at the top
    -- of the block, and it would inflate rest_dimen by that much for nothing.
    self.items[1].gap = 0

    local total_h = 0
    for i = 1, #self.items do
        total_h = total_h + Layout.y(self.items[i].gap) + self.items[i].h
    end

    -- Bottom-left: the standard side margin, sitting REF_BOTTOM_GAP above the
    -- bottom edge. Fixed, not centred - a block that moves with the length of
    -- the quote reads as a layout bug on a screen you glance at.
    local block_bottom = Screen:getHeight() - Layout.y(REF_BOTTOM_GAP)
    local y = block_bottom - total_h
    local top = y

    for i = 1, #self.items do
        local item = self.items[i]
        y = y + Layout.y(item.gap)
        item.x, item.y = self.margin, y
        y = y + item.h
    end

    local g = self.glow_r
    -- Every rect is inflated by the glow radius: the outline is painted outside
    -- the glyph box, and a refresh region that stopped at the glyph box would
    -- leave a ring of stale pixels behind on a partial update.
    local band_x = self.margin - g
    local band_w = self.inner_w + 2 * g

    if self.clock_item then
        local clock_bottom = self.clock_item.y + self.clock_item.h + g
        if #self.items > 1 then
            -- Do not let the clock band reach into the next line's outline: a
            -- clock-only repaint restores this band from a snapshot of the
            -- wallpaper, which would wipe whatever of the date line fell inside.
            local next_top = self.items[2].y - g
            if clock_bottom > next_top then clock_bottom = next_top end
        end
        self.clock_dimen = Geom:new{
            x = band_x, y = self.clock_item.y - g,
            w = band_w, h = clock_bottom - (self.clock_item.y - g),
        }
        if #self.items > 1 then
            local rest_top = self.items[2].y - g
            self.rest_dimen = Geom:new{
                x = band_x, y = rest_top,
                w = band_w, h = block_bottom + g - rest_top,
            }
        else
            self.rest_dimen = zero()
        end
    else
        self.clock_dimen = zero()
        self.rest_dimen = Geom:new{
            x = band_x, y = top - g, w = band_w, h = block_bottom + g - (top - g),
        }
    end

    self.dimen = Geom:new{
        x = band_x, y = top - g, w = band_w, h = block_bottom + g - (top - g),
    }
    -- Kept so paintTo can re-anchor the three rects if UIManager ever places us
    -- somewhere other than the origin (UIManager:show takes an x,y).
    self._rel_x, self._rel_y = self.dimen.x, self.dimen.y
end

--------------------------------------------------------------------------------
-- Colour
--------------------------------------------------------------------------------

--- Mean luminance of the framebuffer under the block, or nil if it cannot be read.
--
-- `bb:getPixel(x, y)` is blitbuffer's read accessor (blitbuffer.lua:819); it
-- already applies the buffer's inverse flag, so what we measure is what will be
-- displayed under night mode. The value it returns is a colour cdata of
-- whatever type the buffer is, and `:getColor8()` is defined on every one of
-- them - Color4L/Color4U at blitbuffer.lua:448/452, Color8 at :456, Color8A
-- aliased at :457, ColorRGB16 at :458, ColorRGB24 at :464 and ColorRGB32
-- aliased at :467, the last two using the ITU-R luma weights. `.a` is the
-- resulting 0..255 grey level.
--
-- Wrapped in pcall regardless: this is FFI pointer arithmetic over a buffer we
-- did not allocate, and a wrong answer about ink colour is a cosmetic bug while
-- an error thrown here would take the screensaver down with it.
function LockScreen:_meanLuminance(bb)
    local rect = self.dimen
    local ok, mean = pcall(function()
        local x0 = math.max(0, rect.x)
        local y0 = math.max(0, rect.y)
        local x1 = math.min(bb:getWidth() - 1, rect.x + rect.w - 1)
        local y1 = math.min(bb:getHeight() - 1, rect.y + rect.h - 1)
        local sum, n = 0, 0
        for py = y0, y1, SAMPLE_STRIDE do
            for px = x0, x1, SAMPLE_STRIDE do
                sum = sum + bb:getPixel(px, py):getColor8().a
                n = n + 1
            end
        end
        if n == 0 then return nil end
        return sum / n
    end)
    if ok then return mean end
    logger.warn("kindleui: lockscreen could not sample the framebuffer:", mean)
    return nil
end

--- Ink and glow colours for this paint.
--
-- `kindleui_lock_colour` is "auto" (the default), "black" or "white", naming
-- the *ink*; the glow is always its opposite. The override exists because
-- "auto" is a single threshold and a wallpaper that sits near the midpoint, or
-- one whose light area happens to be exactly where the block lands, can be
-- argued with.
function LockScreen:_resolveColour(bb)
    local forced = G_reader_settings:readSetting("kindleui_lock_colour") or "auto"
    if forced == "black" then
        return Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    elseif forced == "white" then
        return Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
    end

    local mean = self:_meanLuminance(bb)
    if mean and mean > LUMA_MIDPOINT then
        -- Light wallpaper: black ink, white halo.
        return Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    end
    -- Dark wallpaper, or no reading at all. White ink on a black halo is the
    -- safer default of the two: the halo is what carries the text over a busy
    -- mid-grey, and a white glyph is the more visible failure.
    return Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
end

--------------------------------------------------------------------------------
-- Painting
--------------------------------------------------------------------------------

--- Keeps a copy of the wallpaper under the clock band.
--
-- updateClock has to erase the old digits before drawing the new ones, and the
-- pixels underneath belong to the screensaver, not to us. Screensaver itself
-- does exactly this for its extra-flash feature - `self.bb_copy =
-- Screen.bb:copy()` at screensaver.lua:675, restored before each flash "so that
-- transparent areas always composite over the original content". Same problem,
-- same answer, only a band instead of the whole screen.
--
-- Retaken on every full paint, because a full paint means the wallpaper below
-- may be a different one.
function LockScreen:_snapshotClockBand(bb)
    local rect = self.clock_dimen
    if rect.w <= 0 or rect.h <= 0 then return end
    self:_freeSnapshot()
    local ok, snapshot = pcall(function()
        local copy = Blitbuffer.new(rect.w, rect.h, bb:getType())
        copy:blitFrom(bb, 0, 0, rect.x, rect.y, rect.w, rect.h)
        return copy
    end)
    if ok then
        self.clock_bg = snapshot
    else
        logger.warn("kindleui: lockscreen could not snapshot the clock band:", snapshot)
    end
end

function LockScreen:_freeSnapshot()
    if self.clock_bg then
        self.clock_bg:free()
        self.clock_bg = nil
    end
end

function LockScreen:paintTo(bb, x, y)
    if not self.has_content then return end

    -- Re-anchor the three rects to wherever we were actually placed. They were
    -- laid out against the origin, which is where UIManager:show puts a widget
    -- unless told otherwise.
    local dx = (x or 0) + self._rel_x - self.dimen.x
    local dy = (y or 0) + self._rel_y - self.dimen.y
    if dx ~= 0 or dy ~= 0 then
        for _, rect in ipairs({ self.dimen, self.clock_dimen, self.rest_dimen }) do
            rect.x, rect.y = rect.x + dx, rect.y + dy
        end
    end

    local ink, glow = self:_resolveColour(bb)
    self.ink, self.glow = ink, glow
    self:_snapshotClockBand(bb)

    for i = 1, #self.items do
        local item = self.items[i]
        paintGlowed(item.w, bb, item.x + (x or 0), item.y + (y or 0), ink, glow, self.glow_r)
    end
end

--- Re-render the time and refresh only the clock band.
--
-- The idiom is ReaderFooter's (readerfooter.lua:2382-2386): paint the widget
-- into Screen.bb yourself, *then* setDirty with `nil` as the widget and an
-- explicit region. Passing nil is what makes it a region refresh rather than a
-- "repaint this widget's whole window stack entry" refresh - which for us would
-- mean the screensaver below repainting the entire wallpaper, i.e. exactly the
-- full-screen flash this method exists to avoid. ReaderFooter paints first "to
-- ensure self.footer_content.dimen is sane"; here it is to ensure the new
-- digits are in the buffer before the EPDC is pointed at them.
--
-- Returns false when there is nothing to do, so a caller polling on a timer can
-- skip the refresh entirely on the ~59 out of 60 wakes where the minute has not
-- turned over.
function LockScreen:updateClock(refresh_type)
    if not self.has_content or not self.clock_item then return false end
    local text = clockText()
    if text == self.clock_item.w.text then return false end
    if not self.clock_bg then
        -- No snapshot means we have never had a full paint, so there is nothing
        -- to restore and no safe way to erase the old time. Let the caller fall
        -- back to a normal show/refresh rather than smearing digits.
        return false
    end

    self.clock_item.w:setText(text)
    self.clock_item.h = self.clock_item.w:getSize().h

    local rect = self.clock_dimen
    local ok, err = pcall(function()
        -- Wallpaper back first, then the new time over it.
        Screen.bb:blitFrom(self.clock_bg, rect.x, rect.y, 0, 0, rect.w, rect.h)
        paintGlowed(self.clock_item.w, Screen.bb, self.clock_item.x, self.clock_item.y,
            self.ink or Blitbuffer.COLOR_WHITE, self.glow or Blitbuffer.COLOR_BLACK,
            self.glow_r)
    end)
    if not ok then
        logger.warn("kindleui: lockscreen clock repaint failed:", err)
        return false
    end

    UIManager:setDirty(nil, refresh_type or "ui", rect)
    return true
end

function LockScreen:onCloseWidget()
    -- Whatever is under us has to be redrawn where we were, and nowhere else.
    if self.has_content then
        UIManager:setDirty(nil, "ui", self.dimen)
    end
    -- UIManager:close only broadcasts CloseWidget; it never calls free() for
    -- us, and xtext shaping is malloc'ed on the C side (textwidget.lua:380-387),
    -- so leaving it to the Lua GC leaks until the next collection.
    self:free()
end

function LockScreen:free()
    self:_freeSnapshot()
    for i = 1, #self.items do
        self.items[i].w:free()
    end
end

return LockScreen
