--[[--
Kindle's "Aa" reading-settings sheet.

ConfigDialog puts every option of the active panel on screen at once, in a grid
of toggles that is exhaustive rather than legible. Kindle instead shows a bottom
sheet with four tabs and only the handful of controls a reader reaches for.

    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  <- full-bleed thick rule
     Themes   Font   Layout   More
     ━━━━━━
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     ✓                        ✓
     ┌──┐ Compact             ┌──┐ Standard
     │A │ tight               │A │ KOReader default
     └──┘                     └──┘
     ┌──┐ Large               ┌──┐ Low vision
     │A │ roomy               │A │ big and bold
     └──┘                     └──┘

     ┌────────────────────────────────────────┐
     │          Save current settings         │
     └────────────────────────────────────────┘
     ────────────────────────────────────────
     Manage themes                          ›

GEOMETRY

The sheet is the bottom ~60% of the screen and nothing more. Like the control
centre it never sets `covers_fullscreen` and keeps `self.dimen` clamped to its
own band, so UIManager only ever repaints that band and the page above stays as
it was -- no dimming, no full-screen flash on a tab switch.

It anchors with `BottomContainer{ dimen = Screen:getSize(), <frame> }`, which is
exactly what ConfigDialog does (configdialog.lua:945), and closes on a tap above
the sheet or a swipe south, as ConfigDialog does (configdialog.lua:1491, 1501).

HOW A CHANGE IS COMMITTED

This is the part that has to be right, because a settings panel that looks
correct and changes nothing is worse than the ugly one. ConfigDialog commits an
option through exactly two calls:

    ConfigDialog:onConfigChoice(name, value)                 configdialog.lua:982
        -> ui:handleEvent(Event:new("ConfigChange", name, value))
    ConfigDialog:onConfigEvent(option.event, args[i], cb)    configdialog.lua:987
        -> ui:handleEvent(Event:new(option.event, arg, cb))

`ConfigChange` is caught by ReaderCoptListener:onConfigChange
(readercoptlistener.lua:228) or ReaderKoptListener:onConfigChange
(readerkoptlistener.lua:91), both of which do `document.configurable[name] =
value`. That table is the one ReaderConfig persists on close --
`self.configurable:saveSettings(doc_settings, "copt_")` at readerconfig.lua:193 --
and the one it is handed at readerui.lua:254, so writing to it *is* persistence.
The second call is what applies the change to the live document.

Everything numeric, enumerated or preset in this file goes down that same path,
with `values`, `args` and `event` read out of KOReader's own option tables
(ui/data/creoptions.lua for crengine, ui/data/koptoptions.lua for the koptinterface
formats) rather than restated here. An option this file cannot find in the loaded
table simply does not get a row.
]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local CreOptions = require("ui/data/creoptions")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local KoptOptions = require("ui/data/koptoptions")
local Layout = require("kindleui_geom") -- this plugin's proportions, not ui/geometry
local LeftContainer = require("ui/widget/container/leftcontainer")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Presets = require("ui/presets")
local Size = require("ui/size")
local Slider = require("kindleui_slider")
local TextWidget = require("ui/widget/textwidget")
local Theme = require("kindleui_theme")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local REF = Theme.REF

-- Kindle reference pixels, against kindleui_geom.lua's 1236x1648 panel.
local REF_RULE          = 5   -- the two full-bleed rules that frame the tab row
local REF_TAB_RULE      = 7   -- the bar under the active tab word
local REF_TAB_H         = 50  -- tab label height
local REF_TAB_PAD       = 26  -- above and below the tab row
local REF_TAB_GAP       = 52  -- between tab words; they are left-aligned, not spread
local REF_CHIP_H        = 38  -- a choice word in an option row
local REF_CHIP_GAP      = 34
local REF_CHIP_RULE     = 5
local REF_CHIP_RULE_GAP = 9   -- between a chip's baseline box and its bar
local REF_ROW_PAD       = 20  -- above and below an option row
local REF_SECTION_GAP   = 34
local REF_PAD_TOP       = 30
local REF_PAD_BOTTOM    = 30
local REF_BTN_PAD       = 26  -- inside the outlined button
local REF_CARD_BOX      = 96  -- the outlined square on a theme card
local REF_CARD_GLYPH    = 44
local REF_CARD_GAP      = 24  -- square to label
local REF_CARD_ROW_GAP  = 26
local REF_TICK_H        = 36
local REF_CHEV_H        = 40
-- The font picker (see below); it is a sheet of its own, not a row of this one.
local REF_PICK_TITLE_H  = 48  -- the "back" strip: chevron plus the word
local REF_PICK_ROW_H    = 96  -- one font row, as tall as a Go To chapter row
local REF_PICK_NAME_H   = 44  -- the name, set in the font it names
local REF_PICK_INFO_H   = 62  -- the page strip under the rows
local REF_PICK_INFO_T_H = 32

-- The sheet's share of the screen, measured off a PW5 screenshot: the page keeps
-- roughly its top third.
--
-- This has to be at least as tall as the TALLEST tab needs, not as tall as the
-- design drawing. The band is a fixed fraction, so a tab that overflows it makes
-- `update` grow the sheet for that tab alone -- and then the sheet is a different
-- height on different tabs, which is both wrong to look at and the thing that
-- used to leave a stale rule behind on the way back down (see AaMenu:refresh).
--
-- 0.60 gave the body 768px. Layout -- line spacing and margins are sliders, and
-- sliders are tall -- needs 811px, measured off the device's own warning. 0.65
-- gives it 851px, so every tab fits inside one band and no tab grows it. Adding
-- a row to a tab means re-checking that: the warning in `update` is what says so.
local SHEET_RATIO = 0.65

-- Chips are only legible while the run stays short; anything longer becomes a
-- Stepper instead, which shows one choice at a time.
local MAX_CHIPS = 5

--- An italic face, for a theme card's second line.
-- Font:getFace resolves a bare name against the bundled font dir (font.lua:306)
-- and returns nil when freetype cannot open it (font.lua:326). Theme.face would
-- then index that nil, so probe first and fall back to the regular face.
local ITALIC_FONT = "noto/NotoSans-Italic.ttf"
local function italicFace(ref_h)
    if Font:getFace(ITALIC_FONT, 20) then
        return Theme.face(ref_h, ITALIC_FONT)
    end
    return Theme.face(ref_h)
end

--------------------------------------------------------------------------------
-- Chips: a run of words with a bar under the active one.
--
-- This is Kindle's single selection idiom, used both for the tab row and for
-- every short enumerated option. Never a filled background: on e-ink a fill
-- repaints its whole region and flashes on every change (see kindleui_theme.lua).
--------------------------------------------------------------------------------
local Chips = InputContainer:extend{
    label = nil,        -- optional text pinned left; tabs have none
    items = nil,        -- array of strings
    active = 1,
    width = nil,
    align = "left",     -- "left" for the tab row, "right" for an option row
    label_face = nil,
    face = nil,
    face_bold = nil,
    gap = nil,
    rule_h = nil,
    rule_gap = nil,
    pad_top = 0,
    pad_bottom = 0,
    on_select = nil,    -- on_select(index)
}

function Chips:init()
    self.chips = {}
    self.text_h = 0
    for i, text in ipairs(self.items) do
        -- Bold is baked in at build time rather than swapped at paint time: the
        -- whole sheet is rebuilt when the selection moves anyway.
        local widget = TextWidget:new{
            text = text,
            face = (i == self.active) and self.face_bold or self.face,
            padding = 0,
        }
        self.chips[i] = widget
        self.text_h = math.max(self.text_h, widget:getSize().h)
    end
    if self.label then
        self.label_widget = TextWidget:new{ text = self.label, face = self.label_face, padding = 0 }
        self.text_h = math.max(self.text_h, self.label_widget:getSize().h)
    end
    -- The bar's height is reserved whether or not this row has an active chip,
    -- so rows in a column keep the same rhythm.
    self.height = self.pad_top + self.text_h + self.rule_gap + self.rule_h + self.pad_bottom
    self._zones = {}
    if Device:isTouchDevice() then
        self.ges_events = {
            TapChip = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        }
    end
end

function Chips:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Chips:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local ty = y + self.pad_top

    if self.label_widget then
        local size = self.label_widget:getSize()
        self.label_widget:paintTo(bb, x, ty + math.floor((self.text_h - size.h) / 2))
    end

    local run = self.gap * (#self.chips - 1)
    for _idx, widget in ipairs(self.chips) do
        run = run + widget:getSize().w
    end
    local cx = self.align == "right" and (x + self.width - run) or x

    for i, widget in ipairs(self.chips) do
        local size = widget:getSize()
        widget:paintTo(bb, cx, ty + math.floor((self.text_h - size.h) / 2))
        -- Half the gap on each side, because a single word is a small target on
        -- a 300dpi panel.
        self._zones[i] = { x1 = cx - math.floor(self.gap / 2), x2 = cx + size.w + math.floor(self.gap / 2) }
        if i == self.active then
            -- blitbuffer.lua:1704 -> paintRect(x, y, w, h, value). Under that
            -- word only, which is what makes the tab row read as a tab row.
            bb:paintRect(cx, ty + self.text_h + self.rule_gap, size.w, self.rule_h, Blitbuffer.COLOR_BLACK)
        end
        cx = cx + size.w + self.gap
    end
end

function Chips:onTapChip(_, ges_ev)
    if not self.dimen then return false end
    local pos_x = ges_ev.pos.x
    for i, zone in ipairs(self._zones) do
        if pos_x >= zone.x1 and pos_x <= zone.x2 then
            if i ~= self.active and self.on_select then
                self.on_select(i)
            end
            return true
        end
    end
    return true -- swallow: a miss inside the sheet must not reach the document
end

function Chips:free()
    -- Our text widgets live in named fields, not the array part, so
    -- WidgetContainer:free would never reach their glyph caches.
    for _idx, widget in ipairs(self.chips) do
        widget:free()
    end
    if self.label_widget then self.label_widget:free() end
end

--------------------------------------------------------------------------------
-- Stepper: label, then "‹ value ›".
--
-- For enumerated options with too many choices to lay out as chips (kopt's font
-- scale factors have fifteen). One value on screen, chevrons to walk the list.
--------------------------------------------------------------------------------
local Stepper = InputContainer:extend{
    label = nil,
    items = nil,
    active = 1,
    width = nil,
    label_face = nil,
    face = nil,
    face_bold = nil,
    chev_face = nil,
    gap = nil,
    pad_top = 0,
    pad_bottom = 0,
    on_select = nil,
}

function Stepper:init()
    self.label_widget = TextWidget:new{ text = self.label, face = self.label_face, padding = 0 }
    self.value_widget = TextWidget:new{ text = self.items[self.active] or "", face = self.face_bold, padding = 0 }
    -- Greyed rather than hidden at the ends of the list: the row must not change
    -- width as the value moves, or the whole column would jitter.
    local at_start = self.active <= 1
    local at_end = self.active >= #self.items
    self.left_widget = TextWidget:new{
        text = Theme.GLYPH.chev_left,
        face = self.chev_face,
        fgcolor = at_start and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK,
        padding = 0,
    }
    self.right_widget = TextWidget:new{
        text = Theme.GLYPH.chev_right,
        face = self.chev_face,
        fgcolor = at_end and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK,
        padding = 0,
    }
    -- Widest label wins, so stepping does not shuffle the chevrons about.
    self.value_w = 0
    for _idx, text in ipairs(self.items) do
        local probe = TextWidget:new{ text = text, face = self.face_bold, padding = 0 }
        self.value_w = math.max(self.value_w, probe:getSize().w)
        probe:free()
    end

    self.text_h = math.max(self.label_widget:getSize().h, self.value_widget:getSize().h,
                           self.left_widget:getSize().h, self.right_widget:getSize().h)
    self.height = self.pad_top + self.text_h + self.pad_bottom

    if Device:isTouchDevice() then
        self.ges_events = {
            TapStep = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        }
    end
end

function Stepper:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Stepper:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local ty = y + self.pad_top
    local function centred(widget, at_x)
        local size = widget:getSize()
        widget:paintTo(bb, at_x, ty + math.floor((self.text_h - size.h) / 2))
        return size.w
    end

    centred(self.label_widget, x)

    local right_w = self.right_widget:getSize().w
    local left_w = self.left_widget:getSize().w
    local right_x = x + self.width - right_w
    local value_x = right_x - self.gap - self.value_w
    local left_x = value_x - self.gap - left_w

    centred(self.left_widget, left_x)
    centred(self.right_widget, right_x)
    -- Right-align the value against the closing chevron so digits do not wander.
    centred(self.value_widget, right_x - self.gap - self.value_widget:getSize().w)

    -- Half the gap on the inner side of each chevron, so the target is finger
    -- sized without the two zones ever meeting in the middle.
    self._left_x1 = left_x - math.floor(self.gap / 2)
    self._left_x2 = left_x + left_w + math.floor(self.gap / 2)
    self._right_x1 = right_x - math.floor(self.gap / 2)
end

function Stepper:onTapStep(_, ges_ev)
    if not self.dimen or not self.on_select then return true end
    local pos_x = ges_ev.pos.x
    local target
    if self._left_x1 and pos_x >= self._left_x1 and pos_x <= self._left_x2 then
        target = self.active - 1
    elseif pos_x >= (self._right_x1 or math.huge) then
        target = self.active + 1
    end
    if target and target >= 1 and target <= #self.items then
        self.on_select(target)
    end
    return true
end

function Stepper:free()
    self.label_widget:free()
    self.value_widget:free()
    self.left_widget:free()
    self.right_widget:free()
end

--------------------------------------------------------------------------------
-- Card: one theme in the two-column grid.
--
-- An outlined rounded square holding a letter or glyph, a bold label beside it,
-- an optional italic second line. Selection is a tick floating above-left of the
-- square -- never a fill, for the reason given in kindleui_theme.lua.
--------------------------------------------------------------------------------
local Card = InputContainer:extend{
    width = nil,
    box = nil,
    gap = nil,
    overhang = nil,   -- room reserved at the top-left for the tick
    glyph = nil,
    label = nil,
    sub = nil,
    selected = false,
    glyph_face = nil,
    label_face = nil,
    sub_face = nil,
    tick_face = nil,
    on_tap = nil,
}

function Card:init()
    local text_w = self.width - self.overhang - self.box - self.gap
    self.glyph_widget = TextWidget:new{ text = self.glyph, face = self.glyph_face, padding = 0 }
    self.label_widget = TextWidget:new{
        text = self.label, face = self.label_face, padding = 0, max_width = text_w,
    }
    if self.sub then
        self.sub_widget = TextWidget:new{
            text = self.sub, face = self.sub_face, padding = 0, max_width = text_w,
        }
    end
    if self.selected then
        self.tick_widget = TextWidget:new{ text = Theme.GLYPH.check, face = self.tick_face, padding = 0 }
    end
    self.border = math.max(Size.border.button, Layout.x(4))
    self.height = self.overhang + self.box
    if Device:isTouchDevice() then
        self.ges_events = {
            TapCard = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        }
    end
end

function Card:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Card:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local bx, by = x + self.overhang, y + self.overhang

    -- blitbuffer.lua:2096 -> paintBorder(x, y, w, h, bw, c, r): outline only, no
    -- fill, so switching theme repaints a frame rather than a black block.
    bb:paintBorder(bx, by, self.box, self.box, self.border, Blitbuffer.COLOR_BLACK,
        Size.radius.button)

    local glyph_size = self.glyph_widget:getSize()
    self.glyph_widget:paintTo(bb,
        bx + math.floor((self.box - glyph_size.w) / 2),
        by + math.floor((self.box - glyph_size.h) / 2))

    local tx = bx + self.box + self.gap
    local label_size = self.label_widget:getSize()
    if self.sub_widget then
        local sub_size = self.sub_widget:getSize()
        local block = label_size.h + sub_size.h
        local top = by + math.floor((self.box - block) / 2)
        self.label_widget:paintTo(bb, tx, top)
        self.sub_widget:paintTo(bb, tx, top + label_size.h)
    else
        self.label_widget:paintTo(bb, tx, by + math.floor((self.box - label_size.h) / 2))
    end

    if self.tick_widget then
        -- Centred on the square's top-left corner: it reads as floating over the
        -- card rather than as part of it.
        local size = self.tick_widget:getSize()
        self.tick_widget:paintTo(bb, bx - math.floor(size.w / 2), by - math.floor(size.h / 2))
    end
end

function Card:onTapCard()
    if self.on_tap then self.on_tap() end
    return true
end

function Card:free()
    self.glyph_widget:free()
    self.label_widget:free()
    if self.sub_widget then self.sub_widget:free() end
    if self.tick_widget then self.tick_widget:free() end
end

--------------------------------------------------------------------------------
-- The font picker: a sheet of font names, each set in the font it names.
--
-- Two things put it here rather than on a plain `Menu`.
--
-- WHY IT IS MODAL. UIManager:show walks the window stack downwards and drops
-- the new window in above the first entry it outranks (uimanager.lua:169-182).
-- The test a plain widget fails is `widget.modal or not top_window.widget.modal`:
-- shown while a modal is topmost it satisfies neither clause at any level, so
-- the loop runs to the bottom and files it UNDER the modal. The Aa sheet sets
-- `modal`, so the Menu this replaces was inserted beneath the sheet -- painted,
-- tappable, and invisible.
--
-- Modal, rather than closing the sheet first, because of where the user has to
-- end up. The sheet is what this was opened from and what has to show the new
-- typeface afterwards, so it stays alive underneath: choosing costs one close
-- and one repaint of the band, and so does backing out. Closing the sheet
-- instead would mean repainting the page under it, painting the picker over
-- that, and rebuilding the sheet from nothing on the way back -- three full-band
-- updates and a rebuilt widget tree, to leave a panel we never wanted to leave.
--
-- WHY THE ROWS ARE HAND-BUILT. A column of font names all set in one face tells
-- you nothing about any of them. MenuItem resolves its face once, from
-- `self.font` / `self.font_size` (menu.lua:173), and `Menu` passes no per-item
-- hook down to it; the font list upstream draws IS per-item, but it is a
-- TouchMenu item table, where `font_func` exists (readerfont.lua:112-118). So
-- the rows are Theme.Tappable + TextWidget, the way every other row in this
-- plugin is built, and each one carries the face of the font it names.
--------------------------------------------------------------------------------

--- The list body: fixed size, paged, one page of TextWidgets realised at a time.
--
-- Paged rather than pixel-scrolled for the reason kindleui_pagelist.lua gives at
-- length: a partial row means repainting the whole band on every touch sample,
-- which on e-ink is precisely the thrash paging exists to avoid.
local FontRows = InputContainer:extend{
    entries = nil,      -- { { name =, file =, index = }, ... }; file may be nil
    current = nil,      -- name of the face the document is using, or nil
    width = nil,
    height = nil,
    row_h = nil,
    info_h = nil,       -- the strip under the rows carrying "‹ 3 / 12 ›"
    margin = nil,
    gap = nil,          -- tick column to name
    name_size = nil,    -- pre-scaling point size every preview face is built at
    face_name = nil,    -- the fallback face, and every row's face when previews are off
    face_tick = nil,
    face_info = nil,
    on_select = nil,    -- on_select(entry)
    show_parent = nil,
}

function FontRows:init()
    -- The tick column is as wide as the glyph whether or not a given row carries
    -- one, so every name starts at the same x and the column reads as a column.
    local probe = TextWidget:new{ text = Theme.GLYPH.check, face = self.face_tick, padding = 0 }
    self.tick_w = probe:getSize().w
    probe:free()

    self.rows_h = self.height - self.info_h
    self.per_page = math.max(1, math.floor(self.rows_h / self.row_h))
    self.total_pages = math.max(1, math.ceil(#self.entries / self.per_page))

    -- Open on the page holding the face in use, the way the Go To list opens on
    -- the current chapter. That is also why the list is left in the order
    -- crengine reports it rather than floated current-first, as the Menu version
    -- of this had to be: the order stays the one the user learned, and the tick
    -- is on screen anyway.
    self.page = 1
    for i, entry in ipairs(self.entries) do
        if entry.name == self.current then
            self.page = math.floor((i - 1) / self.per_page) + 1
            break
        end
    end

    -- Pixels of drag that buy one page turn; the same compromise, and the same
    -- flooring against an endless loop, as kindleui_pagelist.lua:206-213.
    self.pan_step = math.max(1, self.row_h, math.floor(self.rows_h / 2))

    if Device:isTouchDevice() then
        local in_list = function() return self.dimen end
        self.ges_events = {
            TapRows = { GestureRange:new{ ges = "tap", range = in_list } },
            -- All three of these, never just the swipe. A drag is reported as a
            -- "swipe" only when the contact lifts inside ges_swipe_interval
            -- (gesturedetector.lua:347); a slower one arrives as a stream of
            -- "pan" events (gesturedetector.lua:986) closed by a "pan_release"
            -- (gesturedetector.lua:1196). Binding swipe alone is what once made
            -- the Go To list look like it ignored scrolling; the full reasoning,
            -- including why the two hit-test differently, is at
            -- kindleui_pagelist.lua:222-236.
            SwipeRows = { GestureRange:new{ ges = "swipe", range = in_list } },
            PanRows = { GestureRange:new{ ges = "pan", range = in_list } },
            PanRowsRelease = { GestureRange:new{ ges = "pan_release", range = in_list } },
        }
    end

    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self:_buildPage()
end

function FontRows:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

--- One row: tick column, then the name in its own face.
function FontRows:_buildRow(entry)
    -- Font:getFace falls back to the name it was handed when that name is not a
    -- fontmap key (font.lua:278-281), which is what lets a bare file path
    -- through; it returns nil when freetype cannot open the file (font.lua:331),
    -- and TextWidget would index that nil to death. So: the default face, always.
    local face = self.face_name
    if entry.file then
        face = Font:getFace(entry.file, self.name_size, entry.index) or self.face_name
    end

    local mark
    if entry.name == self.current then
        -- A tick, never a filled row. See the top of kindleui_theme.lua.
        mark = TextWidget:new{ text = Theme.GLYPH.check, face = self.face_tick, padding = 0 }
    else
        mark = HorizontalSpan:new{ width = self.tick_w }
    end

    local name_w = self.width - 2 * self.margin - self.tick_w - self.gap
    local name = TextWidget:new{
        text = entry.name,
        face = face,
        padding = 0,
        max_width = name_w > 0 and name_w or nil,
    }

    return Theme.Tappable:new{
        on_tap = function() self.on_select(entry) end,
        FrameContainer:new{
            bordersize = 0,
            margin = 0,
            padding = 0,
            -- The row is exactly row_h whatever the preview face's metrics turn
            -- out to be, which is what makes per_page above the truth rather
            -- than an estimate; LeftContainer centres the content in that box
            -- (leftcontainer.lua:23) and reports the box as its size, where a
            -- FrameContainer height would have been painted but not reported
            -- (framecontainer.lua:54-66).
            LeftContainer:new{
                dimen = Geom:new{ w = self.width, h = self.row_h },
                HorizontalGroup:new{
                    align = "center",
                    HorizontalSpan:new{ width = self.margin },
                    mark,
                    HorizontalSpan:new{ width = self.gap },
                    name,
                },
            },
        },
    }
end

--- Realise the visible page only.
-- A preview face is a freetype face cached for the life of the process
-- (font.lua:348), so building one per row of a forty-font list to show eight is
-- memory spent on rows nobody is looking at.
function FontRows:_buildPage()
    self:free()

    local group = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page + 1
    local last = math.min(first + self.per_page - 1, #self.entries)
    for i = first, last do
        table.insert(group, self:_buildRow(self.entries[i]))
    end
    self[1] = group

    if self.total_pages > 1 then
        -- Painted inside this widget's own rect rather than by the picker, so a
        -- page turn's setDirty carries it along instead of leaving a stale count
        -- behind.
        self.info = TextWidget:new{
            text = Theme.GLYPH.chev_left .. "   " .. self.page .. " / " .. self.total_pages
                   .. "   " .. Theme.GLYPH.chev_right,
            face = self.face_info,
            padding = 0,
        }
    end
end

--- Move to `page`, clamped. True only when the page really changed: onPanRows
-- must not bank distance a clamped page turn never spent, or reversing mid-drag
-- would have to pay that phantom debt back before anything moved.
function FontRows:_setPage(page)
    if page < 1 then page = 1 end
    if page > self.total_pages then page = self.total_pages end
    if page == self.page then return false end
    self.page = page
    self:_buildPage()
    -- This widget's rect and nothing else: the head above and the page behind
    -- the sheet are untouched, so the e-ink update stays inside the list.
    UIManager:setDirty(self.show_parent or self, "ui", self.dimen)
    return true
end

function FontRows:paintTo(bb, x, y)
    -- Refreshed on every paint: the enclosing group decides where this lands and
    -- a stale rect would route drags to where the list used to be.
    self.dimen.x, self.dimen.y = x, y
    if self[1] then
        self[1]:paintTo(bb, x, y)
    end
    if self.info then
        local size = self.info:getSize()
        self.info:paintTo(bb,
            x + math.floor((self.width - size.w) / 2),
            y + self.rows_h + math.floor((self.info_h - size.h) / 2))
    end
end

function FontRows:onTapRows(_, ges_ev)
    -- Rows are Tappables and consume their own taps before this runs
    -- (widgetcontainer.lua:100 propagates to children first), so anything
    -- arriving here missed a row.
    if self.total_pages > 1 and ges_ev.pos.y >= self.dimen.y + self.rows_h then
        -- The whole strip pages, not just the two chevrons in it: a 30px glyph
        -- is a cruel target and the halves are unambiguous.
        if ges_ev.pos.x < self.dimen.x + math.floor(self.width / 2) then
            self:_setPage(self.page - 1)
        else
            self:_setPage(self.page + 1)
        end
    end
    -- Swallowed either way: inside the list a tap never reaches anything else.
    return true
end

--- A flick: north (finger up) reveals later entries, so content follows the finger.
function FontRows:onSwipeRows(_, ges_ev)
    -- Nobody flicks at exactly 90 degrees, and "northeast" means nothing else
    -- on a list, so match the prefix.
    local dir = (ges_ev.direction or ""):sub(1, 5)
    if dir == "north" then
        self:_setPage(self.page + 1)
    elseif dir == "south" then
        self:_setPage(self.page - 1)
    end
    self._pan_from_x, self._pan_from_y = nil, nil
    -- Swallowed even at an end stop: inside this rect a drag is a scroll and
    -- never a dismissal. That is the whole close-vs-scroll rule.
    return true
end

--- The slow half of the same gesture. `relative` is re-sent on every sample and
-- measured from the contact point, so one anchor is all the state a drag needs
-- and a sample lost to a repaint simply catches up on the next one.
function FontRows:onPanRows(_, ges_ev)
    local start = ges_ev.start_pos
    local dy = ges_ev.relative and ges_ev.relative.y
    if not start or not dy then return true end

    if start.x ~= self._pan_from_x or start.y ~= self._pan_from_y then
        -- A fresh drag, identified by its contact point because a pan carries no
        -- id. onPanRowsRelease clears it too, but only fires when the finger
        -- happens to lift inside the list, so this is the reliable one.
        self._pan_from_x, self._pan_from_y = start.x, start.y
        self._pan_anchor = 0
    end

    local moved = dy - self._pan_anchor
    while moved <= -self.pan_step do
        if not self:_setPage(self.page + 1) then break end
        self._pan_anchor = self._pan_anchor - self.pan_step
        moved = moved + self.pan_step
    end
    while moved >= self.pan_step do
        if not self:_setPage(self.page - 1) then break end
        self._pan_anchor = self._pan_anchor + self.pan_step
        moved = moved - self.pan_step
    end
    return true
end

function FontRows:onPanRowsRelease()
    self._pan_from_x, self._pan_from_y = nil, nil
    return true
end

function FontRows:onNextListPage()
    self:_setPage(self.page + 1)
    return true
end

function FontRows:onPrevListPage()
    self:_setPage(self.page - 1)
    return true
end

function FontRows:free()
    -- Rebuilt on every page turn, so this runs often; the glyph caches behind a
    -- page of shaped names are worth releasing.
    if self[1] then
        self[1]:free()
        self[1] = nil
    end
    if self.info then
        self.info:free()
        self.info = nil
    end
end

--------------------------------------------------------------------------------
-- FontPicker: the sheet the list sits in.
--------------------------------------------------------------------------------
local FontPicker = InputContainer:extend{
    name = "kindleui_font_picker",
    -- The flag this whole widget exists for; see the note above.
    modal = true,
    -- Deliberately NOT covers_fullscreen: like the sheet it covers, only the
    -- bottom band is ours, and the page above it stays as it was.
    entries = nil,
    current = nil,
    on_select = nil,
}

function FontPicker:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.margin = Theme.margin()
    -- The same band as the Aa sheet, so the picker lands exactly over the thing
    -- it was opened from rather than beside it.
    self.sheet_h = math.floor(self.screen_h * SHEET_RATIO)
    self.rule_h = math.max(Size.line.thick, Layout.y(REF_RULE))

    self.face_title = Theme.faceBold(REF_PICK_TITLE_H)
    self.face_chev = Theme.face(REF_CHEV_H)
    self.face_tick = Theme.face(REF_TICK_H)
    self.face_info = Theme.face(REF_PICK_INFO_T_H)
    -- The size is kept, not just the face: Font:getFace re-scales whatever it is
    -- handed (font.lua:276), so this is the pre-scaling point size that every
    -- preview face is then built at -- the same trick Theme.face turns.
    self.name_size = TextWidget:getFontSizeToFitHeight("cfont", Layout.y(REF_PICK_NAME_H), 0)
    self.face_name = Font:getFace("cfont", self.name_size)

    if Device:isTouchDevice() then
        self.ges_events = {
            TapClosePicker = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h },
                },
            },
            SwipeClosePicker = {
                GestureRange:new{
                    ges = "swipe",
                    -- Everything except the list, which owns every drag inside
                    -- itself. The split is spatial for the reason argued at
                    -- kindleui_pagelist.lua:882-901.
                    range = function() return self.close_zone end,
                },
            },
        }
    end

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            -- Paging by key, since the strip and the drag both need a finger.
            NextListPage = { { Device.input.group.PgFwd } },
            PrevListPage = { { Device.input.group.PgBack } },
        }
    end

    self:update()
end

--- "‹ Typeface": the title, and the way back to the sheet.
function FontPicker:_buildHead()
    local chev = TextWidget:new{ text = Theme.GLYPH.chev_left, face = self.face_chev, padding = 0 }
    local title = TextWidget:new{ text = _("Typeface"), face = self.face_title, padding = 0 }
    local gap = Layout.x(REF.gap)
    -- Padded out to the full screen width, for two reasons: the whole strip is
    -- then the target -- this is the way back, and a 40px chevron is not a
    -- target -- and the frame's white background reaches both edges, so no sliver
    -- of the sheet underneath shows through beside it.
    local filler = self.screen_w - self.margin - chev:getSize().w - gap - title:getSize().w
    if filler < 0 then filler = 0 end

    return Theme.Tappable:new{
        on_tap = function() UIManager:close(self) end,
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            margin = 0,
            padding = 0,
            padding_top = Layout.y(REF_TAB_PAD),
            padding_bottom = Layout.y(REF_TAB_PAD),
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = self.margin },
                chev,
                HorizontalSpan:new{ width = gap },
                title,
                HorizontalSpan:new{ width = filler },
            },
        },
    }
end

function FontPicker:update()
    local head = self:_buildHead()
    local head_h = self.rule_h + head:getSize().h + self.rule_h

    local row_h = Layout.y(REF_PICK_ROW_H)
    local info_h = Layout.y(REF_PICK_INFO_H)
    local list_h = self.sheet_h - head_h
    if list_h < row_h + info_h then
        -- A shorter screen than the PW5 this was measured on: grow the sheet
        -- rather than show a list that cannot hold a row.
        logger.warn("kindleui: the font picker's head takes", head_h, "px of a",
            self.sheet_h, "px band; growing the sheet")
        list_h = row_h + info_h
    end

    self.list = FontRows:new{
        entries = self.entries,
        current = self.current,
        width = self.screen_w,
        height = list_h,
        row_h = row_h,
        info_h = info_h,
        margin = self.margin,
        gap = Layout.x(REF.gap),
        name_size = self.name_size,
        face_name = self.face_name,
        face_tick = self.face_tick,
        face_info = self.face_info,
        show_parent = self,
        on_select = function(entry) self:_choose(entry) end,
    }

    self[1] = BottomContainer:new{
        dimen = Screen:getSize(),
        VerticalGroup:new{
            align = "left",
            -- Full bleed, so they cannot live inside a frame that carries side
            -- padding; the same head the Aa sheet wears, so this reads as a
            -- drill-down of it rather than a different panel.
            Theme.rule(self.rule_h),
            head,
            Theme.rule(self.rule_h),
            FrameContainer:new{
                background = Blitbuffer.COLOR_WHITE,
                bordersize = 0,
                margin = 0,
                padding = 0,
                -- FrameContainer paints its background over width x height
                -- (framecontainer.lua:118) even though getSize reports the
                -- content box, which is how the sheet fills its band exactly and
                -- hides the Aa sheet still sitting underneath it.
                width = self.screen_w,
                height = list_h,
                self.list,
            },
        },
    }

    local total_h = head_h + list_h
    -- The band, and only the band: setDirty regions are matched against this.
    self.dimen = Geom:new{ x = 0, y = self.screen_h - total_h, w = self.screen_w, h = total_h }
    -- Where a swipe means "close": everything that is not the list.
    self.close_zone = Geom:new{ x = 0, y = 0, w = self.screen_w,
                                h = self.screen_h - total_h + head_h }
end

function FontPicker:_choose(entry)
    -- Closed first, so the band's repaint reveals the sheet the caller is about
    -- to update, rather than fighting with it.
    UIManager:close(self)
    if self.on_select then self.on_select(entry) end
end

function FontPicker:paintTo(bb, x, y)
    -- Not InputContainer's version: that one would derive self.dimen from the
    -- full-screen BottomContainer and we would repaint the whole display.
    self[1]:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y + self.screen_h - self.dimen.h
end

function FontPicker:onCloseWidget()
    if self.list then self.list:free() end
    -- Same reasoning as ConfigDialog:onCloseWidget (configdialog.lua:955): the
    -- widgets underneath -- here, the Aa sheet -- have to be redrawn where we
    -- were, and nowhere else.
    UIManager:setDirty(nil, "ui", self.dimen)
end

function FontPicker:onTapClosePicker(_, ges_ev)
    if ges_ev.pos.y < self.dimen.y then
        UIManager:close(self)
    end
    -- Taps inside that got this far missed every control; swallow them so they
    -- reach neither the sheet below nor the document below that.
    return true
end

function FontPicker:onSwipeClosePicker(_, ges_ev)
    if ges_ev.direction == "south" then
        UIManager:close(self)
        return true
    end
end

function FontPicker:onNextListPage()
    return self.list and self.list:onNextListPage()
end

function FontPicker:onPrevListPage()
    return self.list and self.list:onPrevListPage()
end

function FontPicker:onClose()
    UIManager:close(self)
    return true
end

--------------------------------------------------------------------------------
-- Built-in themes.
--
-- KOReader has no preset mechanism for reading settings. `ui/presets.lua` is a
-- generic preset helper, but its only consumers are ReaderDictionary and
-- ReaderFooter (grep for require("ui/presets")); nothing wires `configurable` to
-- it. So THESE ARE THIS PLUGIN'S OWN PRESETS, not KOReader's, stored under
-- `kindleui_themes` in G_reader_settings. Only the name and the values are ours:
-- applying one goes through the same ConfigChange + option event path as every
-- other control here.
--
-- crengine only. Every name below is a copt option, and kopt's `font_size` and
-- `line_spacing` mean entirely different things (a scale factor and a
-- multiplier), so a copt theme must never be offered on a paging document --
-- hence the per-prefix namespacing in _themeStore().
--
-- The values sit inside the ranges KOReader itself enforces: font size 12..255
-- (readerfont.lua:204), line spacing 50..200 (readerfont.lua:213), margins
-- 0..140 (creoptions.lua:168-175).
--
-- The names are deliberately not run through gettext: a theme's name is also its
-- key in G_reader_settings, and a translated key would orphan every saved
-- selection the first time the user changed UI language. Only the second lines
-- are translated.
--------------------------------------------------------------------------------
local BUILTIN_THEMES = {
    {
        name = "Compact",
        sub = _("tight"),
        values = { font_size = 18, line_spacing = 90, h_page_margins = { 10, 10 },
                   t_page_margin = 8, b_page_margin = 8 },
    },
    {
        name = "Standard",
        sub = _("KOReader default"),
        values = { font_size = 22, line_spacing = 100, h_page_margins = { 10, 10 },
                   t_page_margin = 15, b_page_margin = 15 },
    },
    {
        name = "Comfort",
        sub = _("roomy"),
        values = { font_size = 26, line_spacing = 110, h_page_margins = { 30, 30 },
                   t_page_margin = 20, b_page_margin = 20 },
    },
    {
        name = "Large print",
        sub = _("big and bold"),
        values = { font_size = 34, line_spacing = 125, h_page_margins = { 20, 20 },
                   t_page_margin = 15, b_page_margin = 15, font_base_weight = 0.5 },
    },
}

--------------------------------------------------------------------------------
-- AaMenu
--------------------------------------------------------------------------------
local AaMenu = InputContainer:extend{
    name = "kindleui_aa_menu",
    modal = true,
    -- Deliberately NOT covers_fullscreen: the page above the sheet stays visible.
    ui = nil,
    tab_index = 1,
}

local TAB_KEYS = { "themes", "font", "layout", "more" }

function AaMenu:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.side_margin = Theme.margin()
    self.inner_w = Theme.innerW()
    self.sheet_h = math.floor(self.screen_h * SHEET_RATIO)

    self.document = self.ui and self.ui.document
    self.configurable = self.document and self.document.configurable
    if self.document then
        -- readerconfig.lua:15 picks the option table exactly this way.
        self.options = self.document.koptinterface ~= nil and KoptOptions or CreOptions
    end
    self:_indexOptions()

    self.face_tab = Theme.face(REF_TAB_H)
    self.face_tab_bold = Theme.faceBold(REF_TAB_H)
    self.face_title = Theme.face(REF.title_h)
    self.face_title_bold = Theme.faceBold(REF.title_h)
    self.face_chip = Theme.face(REF_CHIP_H)
    self.face_chip_bold = Theme.faceBold(REF_CHIP_H)
    self.face_sub = italicFace(REF.sub_h)
    self.face_card_glyph = Theme.face(REF_CARD_GLYPH)
    self.face_tick = Theme.face(REF_TICK_H)
    self.face_chev = Theme.face(REF_CHEV_H)

    self.rule_h = math.max(Size.line.thick, Layout.y(REF_RULE))
    self.tab_rule_h = math.max(Size.line.thick, Layout.y(REF_TAB_RULE))
    self.chip_rule_h = math.max(Size.line.medium, Layout.y(REF_CHIP_RULE))

    -- Mirrors ConfigDialog (configdialog.lua:877): a screen-wide range whose
    -- handler decides whether the point fell outside the sheet.
    self.ges_events = {
        TapCloseSheet = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h },
            },
        },
        SwipeCloseSheet = {
            GestureRange:new{
                ges = "swipe",
                range = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h },
            },
        },
    }

    if Device:hasKeys() then
        -- Without this a non-touch device could open the sheet and never close
        -- it; ConfigDialog wires the same group at configdialog.lua:897.
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end

    self:update()
end

--------------------------------------------------------------------------------
-- The option table, and the one path that commits a change
--------------------------------------------------------------------------------

--- name -> option definition, flattened out of the loaded option table.
function AaMenu:_indexOptions()
    self.opt_by_name = {}
    if not self.options then return end
    for i = 1, #self.options do
        for _idx, option in ipairs(self.options[i].options) do
            if option.name then
                self.opt_by_name[option.name] = option
            end
        end
    end
end

--- A theme holds values that end up inside `configurable`, so hand out copies
-- rather than references to the stored table.
local function copyValue(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for i = 1, #value do out[i] = value[i] end
    return out
end

local function sameValue(a, b)
    if a == b then return true end
    if type(a) == "table" and type(b) == "table" then
        if #a ~= #b then return false end
        for i = 1, #a do
            if a[i] ~= b[i] then return false end
        end
        return true
    end
    return false
end

--- True when an option's `args` are element-wise its `values`.
-- Those options (font_size, line_spacing, the margins, font_base_weight) accept
-- any value in range, not just the ones listed, so a value absent from `values`
-- can still be handed to the event verbatim.
--
-- The answer is cached here rather than on the option, because CreOptions and
-- KoptOptions are module singletons shared with ConfigDialog and we have no
-- business writing fields into them. Weak keys so an option table that somehow
-- goes away can still be collected.
local mirror_cache = setmetatable({}, { __mode = "k" })
local function argsMirrorValues(option)
    if mirror_cache[option] ~= nil then return mirror_cache[option] end
    local mirror = false
    if option.values and option.args and #option.values == #option.args then
        mirror = true
        for i = 1, #option.values do
            if not sameValue(option.values[i], option.args[i]) then
                mirror = false
                break
            end
        end
    end
    mirror_cache[option] = mirror
    return mirror
end

--- The argument the option's event should get for `value`, or nil if unknown.
-- ConfigDialog reads it as `args[position]` and passes nil when there is no
-- `args` table at all (configdialog.lua:1015-1017); this reproduces that.
local function eventArgFor(option, value)
    if option.values then
        for i, v in ipairs(option.values) do
            if sameValue(v, value) then
                return option.args and option.args[i], true
            end
        end
    end
    if argsMirrorValues(option) then
        return value, true
    end
    return nil, false
end

--- The one commit path. See the header for why it is these two events.
function AaMenu:_commit(name, value, arg)
    if not self.ui then return end
    self.ui:handleEvent(Event:new("ConfigChange", name, value))
    local option = self.opt_by_name[name]
    if option and option.event then
        self.ui:handleEvent(Event:new(option.event, arg))
    end
end

--- Commit on the next tick, then rebuild the sheet.
-- ConfigDialog defers the same work with UIManager:tickAfterNext
-- (configdialog.lua:993) so the tap's own repaint lands before a re-render that
-- may take a second on a big book.
function AaMenu:_commitLater(fn)
    UIManager:tickAfterNext(function()
        fn()
        self:refresh()
    end)
end

--- Coalesce a slider's stream of values into one commit.
-- Slider fires its callback on every pan sample (kindleui_slider.lua:231). Each
-- of these events re-renders the document, so applying every sample would lock
-- the reader up; the slider repaints itself in the meantime, so the control
-- still tracks the finger.
function AaMenu:_debounce(fn)
    if self._pending then
        UIManager:unschedule(self._pending)
    end
    self._pending = function()
        self._pending = nil
        fn()
    end
    UIManager:scheduleIn(0.4, self._pending)
end

function AaMenu:_flushPending()
    if not self._pending then return end
    local fn = self._pending
    UIManager:unschedule(fn)
    self._pending = nil
    fn()
end

--------------------------------------------------------------------------------
-- Row builders. Each returns nil when the option is not in the loaded table, so
-- a format that lacks it simply has one row fewer.
--------------------------------------------------------------------------------

--- One label per choice, or nil if this option cannot be labelled.
-- `toggle` is what ConfigDialog draws on a toggle switch, `item_text` what it
-- draws on an item list, `labels` what it uses for Dispatcher and "set as
-- default" (creoptions.lua:91, koptoptions.lua:401). Any of them will do.
--
-- Options drawn as a `buttonprogress` bar have none of the three: koptoptions'
-- `page_margin` (koptoptions.lua:123) is eight bare numbers, because a bar needs
-- no words. Those get their own values as labels. The duplicate check is a guard
-- on the same theme -- a label list that cannot tell its choices apart is no more
-- use than none at all -- rather than a fix for any particular option today.
local function choiceLabels(option)
    local values = option.values
    if not values then return nil end
    local labels = option.toggle or option.item_text or option.labels
    if labels and #labels == #values then
        local seen, collapsed = {}, false
        for _idx, text in ipairs(labels) do
            if seen[text] then collapsed = true break end
            seen[text] = true
        end
        if not collapsed then return labels end
    end
    local numeric = {}
    for i, v in ipairs(values) do
        if type(v) ~= "number" then return nil end
        numeric[i] = string.format("%g", v)
    end
    return numeric
end

function AaMenu:_currentIndex(option)
    local current = self.configurable and self.configurable[option.name]
    for i, v in ipairs(option.values or {}) do
        if sameValue(v, current) then return i end
    end
    return nil
end

--- A row of chips or a stepper, built straight from the option definition.
function AaMenu:_choiceRow(name, label)
    local option = self.opt_by_name[name]
    if not option or not option.values then return nil end
    local labels = choiceLabels(option)
    if not labels or #labels ~= #option.values then return nil end
    local active = self:_currentIndex(option)
    if not active then return nil end

    local function select(i)
        self:_commitLater(function()
            self:_commit(name, option.values[i], option.args and option.args[i])
        end)
    end

    if #labels <= MAX_CHIPS then
        return self:_chips(label, labels, active, select)
    end
    return Stepper:new{
        label = label,
        items = labels,
        active = active,
        width = self.inner_w,
        label_face = self.face_title,
        face = self.face_chip,
        face_bold = self.face_chip_bold,
        chev_face = self.face_chev,
        gap = Layout.x(REF_CHIP_GAP),
        pad_top = Layout.y(REF_ROW_PAD),
        pad_bottom = Layout.y(REF_ROW_PAD),
        on_select = select,
    }
end

--- A labelled chip row that is not backed by an option table.
function AaMenu:_chips(label, labels, active, on_select)
    return Chips:new{
        label = label,
        items = labels,
        active = active,
        width = self.inner_w,
        align = "right",
        label_face = self.face_title,
        face = self.face_chip,
        face_bold = self.face_chip_bold,
        gap = Layout.x(REF_CHIP_GAP),
        rule_h = self.chip_rule_h,
        rule_gap = Layout.y(REF_CHIP_RULE_GAP),
        pad_top = Layout.y(REF_ROW_PAD),
        pad_bottom = Layout.y(REF_ROW_PAD),
        on_select = on_select,
    }
end

--- A slider over a continuous option.
-- `wrap` turns the slider's integer into the value the option stores; margins
-- store a {left, right} pair while everything else stores the number itself.
-- `also` is a second commit driven off the same knob, for the one control that
-- legitimately owns two settings.
function AaMenu:_sliderRow(name, label, min, max, wrap, also)
    local option = self.opt_by_name[name]
    if not option or not option.event then return nil end
    local current = self.configurable and self.configurable[name]
    if type(current) == "table" then current = current[1] end
    if type(current) ~= "number" then return nil end

    return Slider:new{
        label = label,
        min = min,
        max = max,
        value = current,
        width = self.inner_w,
        callback = function(value)
            local stored = wrap and wrap(value) or value
            self:_debounce(function()
                self:_commit(name, stored, (eventArgFor(option, stored)))
                if also then also(value) end
            end)
        end,
    }
end

--- Integer bounds for a slider over this option, or nil if it does not suit one.
-- Preference goes to the range KOReader's own fine-tune widget uses; failing
-- that, the ends of the option's `values`. Both ends must be whole numbers a
-- unit apart, and the span wide enough to be worth dragging -- kopt's
-- `line_spacing` runs 1.0 to 1.4 and its `font_size` is a fractional scale
-- factor, and both would collapse to a one-step slider. Those fall through to a
-- chip row or a stepper instead.
local SLIDER_MIN_SPAN = 10
local function sliderRange(option, lo_key, hi_key)
    local lo, hi
    local param = option and option.more_options_param
    if param and param[lo_key] and param[hi_key] then
        lo, hi = param[lo_key], param[hi_key]
    elseif option and option.values and #option.values > 0 then
        lo, hi = option.values[1], option.values[#option.values]
        if type(lo) == "table" then lo, hi = lo[1], hi[1] end
    end
    if type(lo) ~= "number" or type(hi) ~= "number" then return nil end
    if math.floor(lo) ~= lo or math.floor(hi) ~= hi then return nil end
    if hi - lo < SLIDER_MIN_SPAN then return nil end
    return lo, hi
end

--- A tappable label / value / chevron row, e.g. the font face picker.
function AaMenu:_navRow(label, value, on_tap)
    local left = TextWidget:new{ text = label, face = self.face_title, padding = 0 }
    local chevron = TextWidget:new{ text = Theme.GLYPH.chev_right, face = self.face_chev, padding = 0 }
    local value_w = self.inner_w - left:getSize().w - chevron:getSize().w
                    - 2 * Size.span.horizontal_default
    local right = TextWidget:new{
        text = value,
        face = self.face_chip_bold,
        padding = 0,
        max_width = value_w > 0 and value_w or nil,
    }
    local spacer = self.inner_w - left:getSize().w - right:getSize().w - chevron:getSize().w
                   - Size.span.horizontal_default
    if spacer < Size.span.horizontal_default then spacer = Size.span.horizontal_default end

    return Theme.Tappable:new{
        on_tap = on_tap,
        FrameContainer:new{
            bordersize = 0,
            margin = 0,
            padding = 0,
            padding_top = Layout.y(REF_ROW_PAD),
            padding_bottom = Layout.y(REF_ROW_PAD),
            HorizontalGroup:new{
                align = "center",
                left,
                HorizontalSpan:new{ width = spacer },
                right,
                HorizontalSpan:new{ width = Size.span.horizontal_default },
                chevron,
            },
        },
    }
end

--------------------------------------------------------------------------------
-- Themes
--------------------------------------------------------------------------------

--- The plugin's own theme store, namespaced by option-table prefix.
-- "copt" values are meaningless to a koptinterface document and vice versa, so
-- the two never see each other's themes.
function AaMenu:_themeStore()
    local all = G_reader_settings:readSetting("kindleui_themes", {})
    local prefix = self.options and self.options.prefix or "copt"
    if type(all[prefix]) ~= "table" then all[prefix] = {} end
    return all[prefix], prefix
end

function AaMenu:_selectedTheme()
    local all = G_reader_settings:readSetting("kindleui_theme_selected", {})
    local _store, prefix = self:_themeStore()
    return all[prefix]
end

function AaMenu:_markSelected(name)
    local all = G_reader_settings:readSetting("kindleui_theme_selected", {})
    local _store, prefix = self:_themeStore()
    all[prefix] = name
end

--- The settings a theme may hold: typography and page layout, and nothing else.
--
-- Not "everything in configurable". That table also carries rotation_mode,
-- trim_page, doc_language and friends, and a theme that silently rotated the
-- screen or re-ran OCR would be a trap rather than a convenience. Names absent
-- from the loaded option table are skipped, so this one list serves both formats.
local THEMEABLE = {
    "font_size", "font_base_weight", "font_gamma", "font_hinting", "font_kerning",
    "word_spacing", "word_expansion",
    "line_spacing", "h_page_margins", "t_page_margin", "b_page_margin",
    "page_margin", "justification", "text_wrap",
}

--- Snapshot the themeable options whose event argument we can resolve.
-- An option whose event takes an argument unrelated to the stored value could not
-- be replayed, and a theme that silently drops half of what it claims to hold is
-- worse than a smaller one.
function AaMenu:_buildTheme()
    local values = {}
    if not self.configurable then return values end
    for _idx, name in ipairs(THEMEABLE) do
        local option = self.opt_by_name[name]
        local current = option and self.configurable[name]
        if current ~= nil and option.event then
            local _arg, ok = eventArgFor(option, current)
            if ok then values[name] = copyValue(current) end
        end
    end
    if self.ui and self.ui.font and self.ui.font.font_face then
        values.font_face = self.ui.font.font_face
    end
    return values
end

function AaMenu:_applyTheme(name, values)
    self:_markSelected(name)
    self:_commitLater(function()
        for opt_name, value in pairs(values) do
            if opt_name ~= "font_face" then
                local option = self.opt_by_name[opt_name]
                if option then
                    -- copyValue: configurable would otherwise end up aliasing the
                    -- stored theme, and crengine's fine-tuning mutates the table
                    -- it is given (configdialog.lua:1057 warns about exactly this).
                    local stored = copyValue(value)
                    self:_commit(opt_name, stored, (eventArgFor(option, stored)))
                end
            end
        end
        if values.font_face and self.ui and self.ui.font then
            -- ReaderFont:onSetFont (readerfont.lua:305) sets the face on the
            -- document and asks ReaderRolling to re-place the position; the face
            -- itself is persisted by ReaderFont:onSaveSettings (readerfont.lua:300).
            self.ui:handleEvent(Event:new("SetFont", values.font_face))
        end
    end)
end

--- Built-ins plus saved ones, as {name, sub, values, builtin} in display order.
function AaMenu:_themeList()
    local list = {}
    if self.options and self.options.prefix == "copt" then
        for _idx, theme in ipairs(BUILTIN_THEMES) do
            table.insert(list, { name = theme.name, sub = theme.sub, values = theme.values, builtin = true })
        end
    end
    local store = self:_themeStore()
    local names = {}
    for name in pairs(store) do table.insert(names, name) end
    table.sort(names)
    for _idx, name in ipairs(names) do
        table.insert(list, { name = name, sub = _("Custom"), values = store[name] })
    end
    return list
end

function AaMenu:_buildThemesTab()
    local rows = {}
    local list = self:_themeList()
    if #list == 0 then
        table.insert(rows, TextWidget:new{
            text = _("No themes saved yet. Tap \"Save current settings\" below."),
            face = self.face_sub,
            padding = 0,
            max_width = self.inner_w,
        })
        return rows
    end

    local selected = self:_selectedTheme()
    local col_gap = Layout.x(REF.gap)
    local col_w = math.floor((self.inner_w - col_gap) / 2)
    local box = Layout.x(REF_CARD_BOX)
    local overhang = math.floor(Layout.y(REF_TICK_H) / 2)
    local row_gap = Layout.y(REF_CARD_ROW_GAP)

    -- How many rows of cards the tab's budget allows. Beyond that the overflow
    -- is not hidden: the last slot becomes a card that opens Manage themes.
    local card_h = overhang + box
    local max_rows = math.max(1, math.floor((self.tab_budget or card_h) / (card_h + row_gap)))
    local shown = math.min(#list, max_rows * 2)
    local truncated = shown < #list
    if truncated then shown = shown - 1 end

    local i = 1
    while i <= shown do
        local group = HorizontalGroup:new{ align = "top" }
        for col = 0, 1 do
            local theme = list[i + col]
            if theme and i + col <= shown then
                if col == 1 then
                    table.insert(group, HorizontalSpan:new{ width = col_gap })
                end
                table.insert(group, Card:new{
                    width = col_w,
                    box = box,
                    gap = Layout.x(REF_CARD_GAP),
                    overhang = overhang,
                    -- A letter for the built-ins (they are type presets), the
                    -- font glyph for a saved one.
                    glyph = theme.builtin and "A" or Theme.GLYPH.font,
                    label = theme.name,
                    sub = theme.sub,
                    selected = selected == theme.name,
                    glyph_face = self.face_card_glyph,
                    label_face = self.face_title_bold,
                    sub_face = self.face_sub,
                    tick_face = self.face_tick,
                    on_tap = function() self:_applyTheme(theme.name, theme.values) end,
                })
            elseif truncated and i + col == shown + 1 then
                if col == 1 then
                    table.insert(group, HorizontalSpan:new{ width = col_gap })
                end
                table.insert(group, Card:new{
                    width = col_w,
                    box = box,
                    gap = Layout.x(REF_CARD_GAP),
                    overhang = overhang,
                    glyph = Theme.GLYPH.ellipsis_v,
                    label = _("More themes"),
                    sub = T(_("%1 more"), #list - shown),
                    glyph_face = self.face_card_glyph,
                    label_face = self.face_title_bold,
                    sub_face = self.face_sub,
                    tick_face = self.face_tick,
                    on_tap = function() self:_onManageThemes() end,
                })
            end
        end
        table.insert(rows, group)
        if i + 2 <= shown + (truncated and 1 or 0) then
            table.insert(rows, VerticalSpan:new{ width = row_gap })
        end
        i = i + 2
    end
    return rows
end

--------------------------------------------------------------------------------
-- Font
--------------------------------------------------------------------------------

--- The face list crengine reports and the engine that reported it, or nil when
-- this is not a crengine document.
function AaMenu:_fontFaces()
    if not (self.ui and self.ui.font) then return nil end
    -- ReaderFont loads the engine the same way at readerfont.lua:68.
    local ok, cre = pcall(function() return require("document/credocument"):engineInit() end)
    if not ok or not cre or not cre.getFontFaces then return nil end
    local listed, faces = pcall(cre.getFontFaces)
    if not listed or type(faces) ~= "table" or #faces == 0 then return nil end
    return faces, cre
end

--- Each face as { name, file, index }, which is what a preview needs.
--
-- `getFontFaceFilenameAndFaceIndex` is the same lookup ReaderFont does before
-- building its own previews (readerfont.lua:80-84), including the second call:
-- a script or cursive family may ship no upright face at all, and asking for the
-- italic is the difference between a preview and a fallback for those.
--
-- `font_menu_use_font_face` is a real user setting (readerfont.lua:113), and
-- someone who turned previews off did it deliberately. Off, we do not even
-- resolve the files, so every row falls back to the sheet's own face.
function AaMenu:_fontEntries()
    local faces, cre = self:_fontFaces()
    if not faces then return nil end
    local resolve = G_reader_settings:nilOrTrue("font_menu_use_font_face")
                    and cre.getFontFaceFilenameAndFaceIndex

    local entries = {}
    for i, name in ipairs(faces) do
        local file, index
        if resolve then
            local ok, f, idx = pcall(resolve, name)
            if not (ok and f) then
                ok, f, idx = pcall(resolve, name, nil, true)
            end
            if ok then file, index = f, idx end
        end
        entries[i] = { name = name, file = file, index = index }
    end
    return entries
end

function AaMenu:_showFontPicker()
    local entries = self:_fontEntries()
    if not entries then return end

    local picker = FontPicker:new{
        entries = entries,
        current = self.ui.font.font_face,
        on_select = function(entry)
            -- The same deferred commit every other control here uses, so the
            -- tap's own repaint lands before crengine re-renders the book:
            -- _commitLater refreshes this sheet afterwards, which is what puts
            -- the new name on the Typeface row.
            self:_commitLater(function()
                -- ReaderFont:onSetFont (readerfont.lua:305) sets the face on the
                -- document and asks ReaderRolling to re-place the position;
                -- ReaderFont:onSaveSettings (readerfont.lua:300) is what writes
                -- it into doc_settings, so this one event both applies and
                -- persists. font_face is not a copt option and has no entry in
                -- creoptions, so ConfigChange has nothing to carry here.
                self.ui:handleEvent(Event:new("SetFont", entry.name))
            end)
        end,
    }

    -- The refresh type and the region are named rather than left to UIManager.
    -- `show` alone marks the widget dirty with a nil refreshtype
    -- (uimanager.lua:184) and leans on _repaint's safety net, which only fires
    -- when the refresh queue is empty (uimanager.lua:1296) -- and it is not
    -- empty here, because the tap flash on the Typeface row has just queued a
    -- "fast" refresh of its own. That combination is what produced a panel that
    -- was painted, tappable and never displayed earlier in this project
    -- (main.lua:294-319).
    UIManager:show(picker, "ui", picker.dimen)
end

function AaMenu:_buildFontTab()
    local rows = {}

    local faces = self:_fontFaces()
    if faces then
        table.insert(rows, self:_navRow(_("Typeface"), self.ui.font.font_face or _("Default"),
            function() self:_showFontPicker() end))
        table.insert(rows, Theme.hairline())
    end

    -- crengine: font size is a point size, contiguous from 12 to 44
    -- (defaults.lua:102), so a slider is honest. kopt's font_size is a
    -- fractional scale factor, which sliderRange rejects, and it gets a stepper.
    local size_lo, size_hi = sliderRange(self.opt_by_name["font_size"], "value_min", "value_max")
    local size_row = size_lo and self:_sliderRow("font_size", _("Font size"), size_lo, size_hi)
    size_row = size_row or self:_choiceRow("font_size", _("Font size"))
    if size_row then table.insert(rows, size_row) end

    local weight = self:_choiceRow("font_base_weight", _("Weight"))
    if weight then table.insert(rows, weight) end

    -- Kindle offers bold on or off. crengine offers a gamma curve, and on e-ink
    -- that is the better control: it thickens the strokes of the face already
    -- chosen instead of swapping in a second one, which is what a reader on a
    -- washed-out panel actually wants. Eight values (creoptions.lua:577), so
    -- _choiceRow renders it as a Stepper -- the same shape Weight above already
    -- takes for its seven.
    --
    -- Its `labels` are numbers rather than strings (creoptions.lua:580), which is
    -- fine: TextWidget coerces with tostring (textwidget.lua:118-119).
    --
    -- The koptinterface formats have no font gamma. Their nearest equivalent is
    -- image contrast for a scanned page (koptoptions.lua:489) -- the same
    -- question asked of a different kind of page.
    local contrast = self:_choiceRow("font_gamma", _("Contrast"))
                     or self:_choiceRow("contrast", _("Contrast"))
    if contrast then table.insert(rows, contrast) end

    local gap = self:_choiceRow("word_spacing", _("Word gap"))
    if gap then table.insert(rows, gap) end

    local reflow = self:_choiceRow("text_wrap", _("Reflow"))
    if reflow then table.insert(rows, reflow) end

    return rows
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

--- Alignment, for crengine, is a style tweak rather than a copt option.
-- ReaderStyleTweak is only registered for crengine documents (readerui.lua:346)
-- and builds tweaks_by_id in its init (readerstyletweak.lua:483), so the ids are
-- available without the main menu ever being opened, and
-- ToggleStyleTweak (readerstyletweak.lua:735) resolves conflicts and applies the
-- new stylesheet immediately.
local TWEAK_LEFT = "text_align_most_left"
local TWEAK_JUSTIFY = "text_align_most_justify"

function AaMenu:_alignmentRow()
    if not (self.options and self.options.prefix == "copt") then return nil end
    local st = self.ui and self.ui.styletweak
    if not (st and st.tweaks_by_id and st.tweaks_by_id[TWEAK_LEFT] and st.tweaks_by_id[TWEAK_JUSTIFY]) then
        return nil
    end
    local ids = { nil, TWEAK_LEFT, TWEAK_JUSTIFY }
    local active = 1
    if st:isTweakEnabled(TWEAK_LEFT) then
        active = 2
    elseif st:isTweakEnabled(TWEAK_JUSTIFY) then
        active = 3
    end
    return self:_chips(_("Alignment"),
        { _("Publisher"), _("Left"), _("Justified") }, active,
        function(i)
            self:_commitLater(function()
                local target = ids[i]
                if target then
                    -- Enabling resolves the conflict with the other one for us.
                    self.ui:handleEvent(Event:new("ToggleStyleTweak", target,
                        st.tweaks_by_id[target], true))
                else
                    for _idx, id in ipairs({ TWEAK_LEFT, TWEAK_JUSTIFY }) do
                        if st:isTweakEnabled(id) then
                            self.ui:handleEvent(Event:new("ToggleStyleTweak", id,
                                st.tweaks_by_id[id], true))
                        end
                    end
                end
            end)
        end)
end

function AaMenu:_pageAnimationRow()
    -- ReaderView:onTogglePageChangeAnimation (readerview.lua:1049) flips
    -- `swipe_animations`; the effect is gated on Device:canDoSwipeAnimation()
    -- (readerview.lua:1042), which is false on everything but Kindle.
    if not Device:canDoSwipeAnimation() then return nil end
    local on = G_reader_settings:isTrue("swipe_animations")
    return self:_chips(_("Page animation"), { _("Off"), _("On") }, on and 2 or 1,
        function(i)
            self:_commitLater(function()
                if (i == 2) ~= on then
                    self.ui:handleEvent(Event:new("TogglePageChangeAnimation"))
                end
            end)
        end)
end

function AaMenu:_buildLayoutTab()
    local rows = {}

    local sp_lo, sp_hi = sliderRange(self.opt_by_name["line_spacing"], "value_min", "value_max")
    local spacing = sp_lo and self:_sliderRow("line_spacing", _("Line spacing"), sp_lo, sp_hi)
    spacing = spacing or self:_choiceRow("line_spacing", _("Line spacing"))
    if spacing then table.insert(rows, spacing) end

    -- Kindle has one "Margins" control, and so does this: the slider drives the
    -- horizontal pair and the vertical pair together. Both go down ConfigDialog's
    -- own routes -- SetPageHorizMargins takes a {left, right} pair
    -- (readertypeset.lua:477), and the top/bottom pair is the two-name case
    -- ConfigDialog handles at configdialog.lua:1220-1233: write both settings,
    -- then fire SetPageTopAndBottomMargin once (readertypeset.lua:502).
    local h_lo, h_hi = sliderRange(self.opt_by_name["h_page_margins"], "left_min", "left_max")
    -- koptinterface has a single fractional `page_margin` instead of the four
    -- crengine numbers, so it gets a stepper over its own values.
    local has_tb = self.opt_by_name["t_page_margin"] and self.opt_by_name["b_page_margin"]
    if h_lo then
        local row = self:_sliderRow("h_page_margins", _("Margins"), h_lo, h_hi,
            function(v) return { v, v } end,
            has_tb and function(v)
                self:_commit("t_page_margin", v, v)
                self:_commit("b_page_margin", v, v)
                self.ui:handleEvent(Event:new("SetPageTopAndBottomMargin", { v, v }))
            end or nil)
        if row then table.insert(rows, row) end
    else
        local row = self:_choiceRow("page_margin", _("Margin"))
        if row then table.insert(rows, row) end
    end

    local align = self:_alignmentRow() or self:_choiceRow("justification", _("Alignment"))
    if align then table.insert(rows, align) end

    -- Page or continuous scroll -- the one option in KOReader's grid that changes
    -- how the book is READ rather than how it looks, and the only reason left to
    -- go back to that grid now that the bottom edge no longer opens it.
    --
    -- crengine calls it view_mode (creoptions.lua:305) and the koptinterface
    -- formats page_scroll (koptoptions.lua:343). Both are a two-value toggle
    -- carrying their own event, so _choiceRow takes either without special
    -- casing.
    local mode = self:_choiceRow("view_mode", _("Page mode"))
                 or self:_choiceRow("page_scroll", _("Page mode"))
    if mode then table.insert(rows, mode) end

    local anim = self:_pageAnimationRow()
    if anim then table.insert(rows, anim) end

    return rows
end

--------------------------------------------------------------------------------
-- More
--------------------------------------------------------------------------------

-- The full-refresh choices KOReader itself offers, with the values it sends.
-- refresh_menu_table.lua:57-105; -1 means "every chapter".
local REFRESH_VALUES = { 0, 1, 6, -1 }

--- Whether an option's own `enabled_func` says it can act right now.
--
-- ConfigDialog greys such an option out. This sheet has no greyed state, so a
-- row that cannot act is left out instead -- which is what it already does for
-- an option missing from the loaded table, and better than a control that
-- accepts a tap and changes nothing.
--
-- Called at the row rather than inside _choiceRow, and that restraint is
-- deliberate. The koptinterface table also puts enabled_func on line_spacing,
-- justification, font_size and word_spacing (koptoptions.lua:383, 404, 433, 465),
-- all four of which this sheet shows today for a PDF. Making the check general
-- would quietly empty a PDF's Font and Layout tabs whenever reflow is off. That
-- may well be the right answer, but it is a separate change to a separate
-- format and not one to smuggle in here.
local function optionEnabled(option, configurable, document)
    if type(option.enabled_func) ~= "function" then return true end
    -- pcall because the predicate is upstream's and reaches into the document:
    -- one that throws must cost us nothing worse than a row ConfigDialog would
    -- have shown anyway, merely greyed.
    local ok, enabled = pcall(option.enabled_func, configurable, document)
    if not ok then return true end
    return enabled ~= false
end

function AaMenu:_buildMoreTab()
    local rows = {}

    -- DeviceListener is a ReaderUI module (readerui.lua:452), so ui:handleEvent
    -- reaches it. onSetNightMode (devicelistener.lua:29) is a no-op when the
    -- state already matches, which makes this idempotent.
    local night = G_reader_settings:isTrue("night_mode")
    table.insert(rows, self:_chips(_("Night mode"), { _("Off"), _("On") }, night and 2 or 1,
        function(i)
            self:_commitLater(function()
                self.ui:handleEvent(Event:new("SetNightMode", i == 2))
            end)
        end))

    local day = UIManager:getRefreshRate()
    local active = 1
    for i, v in ipairs(REFRESH_VALUES) do
        if v == day then active = i end
    end
    table.insert(rows, self:_chips(_("Full refresh"),
        { _("Never"), _("Every page"), _("6 pages"), _("Chapter") }, active,
        function(i)
            self:_commitLater(function()
                -- DeviceListener:onSetBothRefreshRates (devicelistener.lua:296)
                -- calls UIManager:setRefreshRate, which both applies it and saves
                -- it to G_reader_settings (uimanager.lua:730-736).
                self.ui:handleEvent(Event:new("SetBothRefreshRates", REFRESH_VALUES[i]))
            end)
        end))

    -- crengine's own header line; the koptinterface documents get the closest
    -- equivalent they have.
    local status = self:_choiceRow("status_line", _("Alt status bar"))
                   or self:_choiceRow("nightmode_document", _("Invert document"))
    if status then table.insert(rows, status) end

    local images = self:_choiceRow("nightmode_images", _("Invert images"))
    if images then table.insert(rows, images) end

    -- Publisher style, and the fonts that come with it. Kindle has neither, and
    -- they are the pair that decides whether the Typeface, Margins and Line
    -- spacing chosen on the other tabs are honoured at all: a book whose own CSS
    -- names a family and a leading overrides them silently, and until now there
    -- was no way to say no to that from inside kindleui.
    local css = self:_choiceRow("embedded_css", _("Publisher style"))
    if css then table.insert(rows, css) end

    -- embedded_fonts means something only while embedded_css is on AND the book
    -- actually carries fonts (creoptions.lua:701-704) -- publisher fonts arrive
    -- through publisher CSS, so with that off the question is moot.
    --
    -- Left out rather than shown dead. The row comes straight back when the one
    -- above is switched: _commitLater refreshes the sheet after every commit
    -- (kindleui_aamenu.lua:1207-1212), so it reappears on the same tap.
    local fonts_opt = self.opt_by_name["embedded_fonts"]
    if fonts_opt and optionEnabled(fonts_opt, self.configurable, self.document) then
        local fonts = self:_choiceRow("embedded_fonts", _("Publisher fonts"))
        if fonts then table.insert(rows, fonts) end
    end

    return rows
end

--------------------------------------------------------------------------------
-- Save / manage
--------------------------------------------------------------------------------

function AaMenu:_presetObj()
    local store = self:_themeStore()
    return { presets = store }
end

function AaMenu:_onSaveTheme()
    if not self.configurable then return end
    -- Presets.editPresetName (presets.lua:121) is KOReader's own naming dialog:
    -- it rejects blanks and duplicates against preset_obj.presets for us.
    Presets.editPresetName({ title = _("Name this theme") }, self:_presetObj(),
        function(name)
            local store = self:_themeStore()
            store[name] = self:_buildTheme()
            self:_markSelected(name)
            self:refresh()
        end)
end

function AaMenu:_onManageThemes()
    local store = self:_themeStore()
    local names = {}
    for name in pairs(store) do table.insert(names, name) end
    table.sort(names)
    if #names == 0 then
        UIManager:show(InfoMessage:new{
            text = _("You have not saved any themes yet."),
            timeout = 2,
        })
        return
    end

    local items = {}
    for _idx, name in ipairs(names) do
        table.insert(items, {
            text = name,
            callback = function() self:_themeActions(name) end,
        })
    end

    local manager
    local closed = false
    manager = Menu:new{
        title = _("Manage themes"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        -- Same trap the font picker fell into. UIManager:show walks the stack
        -- from the top and only places a widget above the current one when
        -- `widget.modal or not top_window.widget.modal` holds
        -- (uimanager.lua:169-182). This sheet is modal, so a plain Menu opened
        -- from it slides UNDERNEATH -- covers_fullscreen merely hides the
        -- symptom above the sheet's band while the rest stays buried.
        modal = true,
        close_callback = function()
            if closed then return end
            closed = true
            UIManager:close(manager)
            self:refresh()
        end,
    }
    self._theme_manager = manager
    UIManager:show(manager)
end

function AaMenu:_themeActions(name)
    local store = self:_themeStore()
    local dialog
    dialog = ButtonDialog:new{
        title = name,
        -- Opened from the modal theme manager, so it needs the same flag for
        -- the same reason (uimanager.lua:169-182).
        modal = true,
        buttons = {
            {
                {
                    text = _("Apply"),
                    callback = function()
                        UIManager:close(dialog)
                        if self._theme_manager then
                            UIManager:close(self._theme_manager)
                            self._theme_manager = nil
                        end
                        self:_applyTheme(name, store[name])
                    end,
                },
            },
            {
                {
                    text = _("Rename"),
                    callback = function()
                        UIManager:close(dialog)
                        Presets.editPresetName({
                            title = _("Enter new theme name"),
                            initial_value = name,
                            confirm_button_text = _("Rename"),
                        }, self:_presetObj(), function(new_name)
                            store[new_name] = store[name]
                            store[name] = nil
                            if self:_selectedTheme() == name then self:_markSelected(new_name) end
                            if self._theme_manager then
                                UIManager:close(self._theme_manager)
                                self._theme_manager = nil
                            end
                            self:refresh()
                        end)
                    end,
                },
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:close(dialog)
                        store[name] = nil
                        if self:_selectedTheme() == name then self:_markSelected(nil) end
                        if self._theme_manager then
                            UIManager:close(self._theme_manager)
                            self._theme_manager = nil
                        end
                        self:refresh()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function AaMenu:_buildFooter()
    local items = {}

    local label = TextWidget:new{ text = _("Save current settings"), face = self.face_title, padding = 0 }
    local border = Size.border.button
    local pad = Layout.y(REF_BTN_PAD)
    table.insert(items, Theme.Tappable:new{
        on_tap = function() self:_onSaveTheme() end,
        -- Outlined, never filled: same e-ink reasoning as everything else here,
        -- and it is what the firmware draws.
        FrameContainer:new{
            bordersize = border,
            radius = Size.radius.button,
            margin = 0,
            padding = 0,
            padding_top = pad,
            padding_bottom = pad,
            CenterContainer:new{
                dimen = Geom:new{ w = self.inner_w - 2 * border, h = label:getSize().h },
                label,
            },
        },
    })

    table.insert(items, VerticalSpan:new{ width = Layout.y(REF_SECTION_GAP) })
    table.insert(items, Theme.hairline())
    table.insert(items, self:_navRow(_("Manage themes"), "", function() self:_onManageThemes() end))

    return items
end

--------------------------------------------------------------------------------
-- Layout and painting
--------------------------------------------------------------------------------

function AaMenu:_buildBody()
    if not self.configurable then
        return { TextWidget:new{
            text = _("Reading settings are only available while a book is open."),
            face = self.face_sub,
            padding = 0,
            max_width = self.inner_w,
        } }
    end
    local key = TAB_KEYS[self.tab_index]
    if key == "themes" then return self:_buildThemesTab() end
    if key == "font" then return self:_buildFontTab() end
    if key == "layout" then return self:_buildLayoutTab() end
    return self:_buildMoreTab()
end

function AaMenu:update()
    if self.sheet then self.sheet:free() end

    local tabs = Chips:new{
        items = { _("Themes"), _("Font"), _("Layout"), _("More") },
        active = self.tab_index,
        width = self.inner_w,
        align = "left",
        face = self.face_tab,
        face_bold = self.face_tab_bold,
        gap = Layout.x(REF_TAB_GAP),
        rule_h = self.tab_rule_h,
        rule_gap = Layout.y(REF_CHIP_RULE_GAP),
        pad_top = Layout.y(REF_TAB_PAD),
        pad_bottom = Layout.y(REF_TAB_PAD),
        on_select = function(i)
            self.tab_index = i
            self:refresh()
        end,
    }
    local tab_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = 0,
        padding_left = self.side_margin,
        padding_right = self.side_margin,
        tabs,
    }

    local pad_top = Layout.y(REF_PAD_TOP)
    local pad_bottom = Layout.y(REF_PAD_BOTTOM)

    -- The footer is the same on every tab and the head is fixed, so the budget a
    -- tab's content has is known before that content exists. The themes grid uses
    -- it to decide how many rows of cards it may draw.
    local footer_rows = self:_buildFooter()
    local footer_h = 0
    for _idx, widget in ipairs(footer_rows) do
        footer_h = footer_h + widget:getSize().h
    end
    local head_h = self.rule_h + tab_frame:getSize().h + self.rule_h
    local body_h = self.sheet_h - head_h
    local available = body_h - pad_top - pad_bottom - Layout.y(REF_SECTION_GAP)
    self.tab_budget = available - footer_h

    local body_rows = self:_buildBody()
    local content_h = 0
    for _idx, widget in ipairs(body_rows) do
        content_h = content_h + widget:getSize().h
    end

    local slack = self.tab_budget - content_h
    if slack < 0 then
        -- A shorter screen than the PW5 this was measured on: grow the sheet
        -- rather than clip a control off the bottom.
        logger.warn("kindleui: Aa sheet content is", content_h + footer_h,
            "px but the band allows only", available, "px; growing the sheet")
        body_h = body_h - slack
        slack = 0
    end

    local body = VerticalGroup:new{ align = "left" }
    for _idx, widget in ipairs(body_rows) do
        table.insert(body, widget)
    end
    table.insert(body, VerticalSpan:new{ width = slack + Layout.y(REF_SECTION_GAP) })
    for _idx, widget in ipairs(footer_rows) do
        table.insert(body, widget)
    end

    local body_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = 0,
        padding_left = self.side_margin,
        padding_right = self.side_margin,
        padding_top = pad_top,
        padding_bottom = pad_bottom,
        -- FrameContainer paints its background over width x height
        -- (framecontainer.lua:118) even though getSize reports the content box,
        -- which is how the sheet fills its band exactly.
        width = self.screen_w,
        height = body_h,
        body,
    }

    -- The two rules are full-bleed, so they cannot live inside either frame:
    -- both carry side padding and a LineWidget in there would stop short of the
    -- screen edges.
    self.sheet = VerticalGroup:new{
        align = "left",
        Theme.rule(self.rule_h),
        tab_frame,
        Theme.rule(self.rule_h),
        body_frame,
    }
    self[1] = BottomContainer:new{
        dimen = Screen:getSize(),
        self.sheet,
    }

    -- The band, and only the band. setDirty regions are matched against this, so
    -- the page above us is never repainted.
    local total_h = head_h + body_h
    self.dimen = Geom:new{ x = 0, y = self.screen_h - total_h, w = self.screen_w, h = total_h }
end

--- Rebuild and repaint the sheet alone.
--
-- WHY THE OLD RECT IS REPAINTED TOO, AND WHY BY `nil`
--
-- The sheet is not always the same height. `update` grows the band when a tab's
-- content will not fit, and a tab can change height under its own feet -- More
-- drops the publisher-fonts row when publisher style is switched off. So a
-- refresh can leave the sheet SHORTER than it was a moment ago.
--
-- Repainting only the new rect strands the strip the old one covered. What was
-- there was the taller sheet's top rule, and it stayed on the page as a second
-- rule floating above the real one, with fragments of the row that had been
-- beside it. Reported from the device, and visible in a screenshot as two rules
-- where the design has one.
--
-- `nil` and not `self`: only the widgets UNDER us can repaint a strip we no
-- longer cover. Handing setDirty `self` marks the sheet dirty, and the sheet
-- does not reach up there any more, so nothing would be drawn over the stale
-- pixels. That is the same reasoning as onCloseWidget below -- the other place
-- this widget stops covering something it used to.
function AaMenu:refresh()
    local was = self.dimen and self.dimen:copy()
    self:update()
    if was and self.dimen and was.h > self.dimen.h then
        UIManager:setDirty(nil, "ui", was)
    end
    UIManager:setDirty(self, "ui", self.dimen)
end

function AaMenu:paintTo(bb, x, y)
    -- Not InputContainer's version: that one would derive self.dimen from the
    -- full-screen BottomContainer and we would repaint the whole display.
    self[1]:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y + self.screen_h - self.dimen.h
end

function AaMenu:onCloseWidget()
    -- A slider change still in the debounce window has to land, or letting go of
    -- the knob and tapping away would silently discard it.
    self:_flushPending()
    if self.sheet then self.sheet:free() end
    -- Same reasoning as ConfigDialog:onCloseWidget (configdialog.lua:955): the
    -- widgets underneath have to be redrawn where we were, and nowhere else.
    UIManager:setDirty(nil, "ui", self.dimen)
end

function AaMenu:onTapCloseSheet(_, ges_ev)
    if ges_ev.pos.y < self.dimen.y then
        UIManager:close(self)
    end
    -- Taps inside the sheet that got this far missed every control; swallow them
    -- so they do not fall through to the document.
    return true
end

function AaMenu:onSwipeCloseSheet(_, ges_ev)
    if ges_ev.direction == "south" then
        UIManager:close(self)
        return true
    end
end

function AaMenu:onClose()
    UIManager:close(self)
    return true
end

return AaMenu
