--[[--
Kindle's "Go To" panel: the table of contents, plus the row that opens the
jump-to-page dialog.

The firmware hangs this off the bottom of the reader's own chrome rather than
covering it: on a Paperwhite 5 the status strip (101px), the icon toolbar
(115px) and the book-title strip (126px) stay visible, so the panel starts at
y=342 and runs to the bottom edge. kindleui_geom.lua carries those three bands
as STATUS/TOOLBAR/BOOKBAR, so the offset is derived rather than hard-coded and
survives a screen that is not 1236x1648.

Because the chrome above stays readable, this widget must NOT dim or claim the
full screen. Like kindleui_controlcentre.lua it therefore never sets
`covers_fullscreen`, and it clamps `self.dimen` to its own band so UIManager's
setDirty only ever repaints from y=342 down.

    ┌──────────────────────────────────────────┐  y = 342
    │                    v                     │  chev_down: swipe me away
    │ The Left Hand of Darkness                │  large, bold
    │ Ursula K. Le Guin                        │
    │ ════════════════════════════════════════ │  thick, full bleed
    │ Go to page or location                 › │  -> ReaderGoto's own dialog
    │ ──────────────────────────────────────── │  hairline
    │ ▌Chapter 1                          1  ▲ │  current: bold + margin bar
    │    A Parade in Erhenrang           12  ▨ │  hatched rail...
    │  Chapter 2                         31  ▨ │
    │  Chapter 3                         44  ▓ │  ...carrying a solid thumb
    │                                     ▲    │
    │  Chapter 9                        180  ▼ │
    └──────────────────────────────────────────┘  y = screen bottom

WHY THE LIST IS HAND-DRAWN RATHER THAN A `Menu`

Menu would give two of the three things this list needs for free: per-item bold
(`bold = self.item_table.current == index or item.bold == true`, menu.lua:1110)
and a right-aligned "mandatory" column (menu.lua:187-200) -- which is exactly
what ReaderToc feeds it (readertoc.lua:846). It cannot give the third. The
current-chapter bar lives in the screen's LEFT MARGIN, outside the menu's
content box, and MenuItem paints strictly inside that box; reaching it would
mean overriding MenuItem:paintTo, i.e. forking the widget anyway.

Menu also brings chrome this design does not have and cannot switch off
piecemeal: a TitleBar header (menu.lua:882), a centred chevron page-info footer
(menu.lua:884) and a floating return arrow (menu.lua:888), all wrapped in its
own white FrameContainer (menu.lua:917). Kindle's Go To replaces that entire
footer with a hatched rail and two solid triangles pinned to the right edge. So
the list is drawn here: ~120 lines against a widget we would have had to
subclass in three places.

A note on the current-chapter marker: bold text plus a bar, never a filled
background. See the rationale at the top of kindleui_theme.lua -- a fill has to
be repainted on every scroll, and on e-ink a repaint is a visible flash.
]]

local Blitbuffer = require("ffi/blitbuffer")
local LineWidget = require("ui/widget/linewidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Layout = require("kindleui_geom") -- this plugin's proportions, not ui/geometry
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local Theme = require("kindleui_theme")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

-- Kindle reference pixels, against kindleui_geom.lua's 1236x1648 panel.
local REF_PAD_TOP      = 20
local REF_CHEVRON_H    = 40   -- the "swipe me away" affordance
local REF_CHEVRON_GAP  = 22
local REF_BOOK_TITLE_H = 64   -- large and bold
local REF_AUTHOR_H     = 34
local REF_TITLE_GAP    = 10   -- between title and author
local REF_HEADER_GAP   = 26   -- author baseline to the thick rule
local REF_GOTO_ROW_H   = 108
local REF_GOTO_TEXT_H  = 42
local REF_GOTO_CHEV_H  = 34
local REF_ROW_H        = 96   -- one chapter row
local REF_ROW_TEXT_H   = 40
local REF_ROW_NUM_H    = 34
local REF_INDENT       = 40   -- per TOC depth level
local REF_BAR_W        = 10   -- current-chapter bar, in the left margin
local REF_BAR_H        = 46
local REF_BAR_X        = 22
local REF_RAIL_COL_W   = 56   -- right-hand gutter holding triangles + rail
local REF_RAIL_TRACK_W = 16
local REF_RAIL_TRI_W   = 34
local REF_RAIL_TRI_H   = 22
local REF_RAIL_GAP     = 18   -- triangle to track
local REF_NUM_GAP      = 18   -- number column to rail gutter
local REF_EMPTY_H      = 48   -- "no table of contents" line

--------------------------------------------------------------------------------
-- Primitive drawing
--
-- blitbuffer.lua:1848 paintRect(x, y, w, h, value) clips to the buffer via
-- getBoundedRect, but knows nothing about our rail, so every helper below stays
-- inside the rect it was handed.
--------------------------------------------------------------------------------

--- A solid triangle, apex up or down, horizontally centred on `cx`.
-- Drawn rather than set in type: symbols.ttf carries chevrons (Theme.GLYPH
-- chev_up / chev_down) but no filled caret at a codepoint verified against the
-- device's cmap, and inventing one is exactly what kindleui_theme.lua forbids.
-- A scanline fill is also exact at any size, which a glyph is not.
local function paintTriangle(bb, cx, top, w, h, point_up)
    for i = 0, h - 1 do
        local frac = point_up and (i + 1) / h or (h - i) / h
        local rw = math.max(1, math.floor(w * frac))
        bb:paintRect(cx - math.floor(rw / 2), top + i, rw, 1, Blitbuffer.COLOR_BLACK)
    end
end

--- Kindle's hatched scroll track: 45-degree stripes on white.
-- The stripes are solid black at roughly a one-third duty cycle, so the track
-- reads as mid-grey without any dithering -- which matters here, because a
-- dithered fill is the one thing an e-ink panel renders differently on every
-- refresh mode.
--
-- Stepping two rows at a time (and shifting two pixels) halves the number of
-- fills while keeping the slope at 45 degrees; the rail is repainted on every
-- page turn, so the constant factor is worth having.
local function paintHatch(bb, x, y, w, h)
    local period = math.max(6, math.floor(w * 0.9))
    local stripe = math.max(2, math.floor(period / 3))
    local step = 2
    for row = 0, h - 1, step do
        local rh = math.min(step, h - row)
        -- Start one period to the left so the stripe entering from off-track is
        -- clipped rather than missing.
        local s = ((period - row % period) % period) - period
        while s < w do
            local x0 = s < 0 and 0 or s
            local x1 = math.min(w, s + stripe)
            if x1 > x0 then
                bb:paintRect(x + x0, y + row, x1 - x0, rh, Blitbuffer.COLOR_BLACK)
            end
            s = s + period
        end
    end
end

--- A one-pixel outline, so the hatch reads as a channel and not as a texture.
local function paintOutline(bb, x, y, w, h)
    local t = Size.line.thin
    bb:paintRect(x, y, w, t, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y + h - t, w, t, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y, t, h, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + w - t, y, t, h, Blitbuffer.COLOR_BLACK)
end

--------------------------------------------------------------------------------
-- ChapterList: the scrolling body.
--
-- Fixed size, paged (never pixel-scrolled): a partial page would force a
-- repaint of the whole band on every step, and paging lets setDirty stay inside
-- this widget's own dimen.
--
-- That is also the answer to "why does a drag not follow the finger". Only the
-- rows of the current page are realised as TextWidgets (_buildPage), and they
-- are painted at fixed multiples of row_h, so a pixel offset would mean
-- rebuilding the partially visible rows and repainting the whole list rect on
-- every touch sample. On e-ink that is a stream of full-band updates, i.e.
-- exactly the thrash paging exists to avoid. A drag therefore turns pages, but
-- it turns them mid-drag rather than on lift (see pan_step), so the gesture
-- still reads as scrolling.
--------------------------------------------------------------------------------
local ChapterList = InputContainer:extend{
    entries = nil,      -- { { text=, number=, depth=, page=, xpointer= }, ... }
    current = nil,      -- index into entries of the chapter being read, or nil
    width = nil,
    height = nil,
    face_row = nil,
    face_row_bold = nil,
    face_num = nil,
    face_empty = nil,
    on_select = nil,    -- function(entry)
    show_parent = nil,
    empty_text = nil,
}

function ChapterList:init()
    self.row_h = Layout.y(REF_ROW_H)
    self.margin = Theme.margin()
    self.rail_col_w = Layout.x(REF_RAIL_COL_W)
    self.rail_x = self.width - self.rail_col_w
    self.num_right = self.rail_x - Layout.x(REF_NUM_GAP)
    self.indent_w = Layout.x(REF_INDENT)

    self.per_page = math.max(1, math.floor(self.height / self.row_h))
    self.total_pages = math.max(1, math.ceil(#self.entries / self.per_page))
    -- Open on the page holding the current chapter, the way ReaderToc jumps its
    -- menu to collapsed_toc.current (readertoc.lua:1037).
    self.page = self.current and math.floor((self.current - 1) / self.per_page) + 1 or 1

    -- Pixels of drag that buy one page turn. Half the list height is the
    -- compromise between the two bad ends: a full list height maps the drag onto
    -- the content one-to-one but leaves the list visibly dead until the finger
    -- lifts, while a couple of rows makes the list bolt away under a slow drag.
    -- Floored at one row, and at 1px below that: onPanList pays the drag out in
    -- pan_step instalments, so a zero here would be an endless loop rather than
    -- a cosmetic problem.
    self.pan_step = math.max(1, self.row_h, math.floor(self.height / 2))

    if Device:isTouchDevice() then
        -- One range for all four: this widget's own rect, refreshed on every
        -- paintTo. That rect is the whole close-vs-scroll rule; the reasoning
        -- lives on PageList:onSwipeClosePanel.
        local in_list = function() return self.dimen end
        self.ges_events = {
            TapList = { GestureRange:new{ ges = "tap", range = in_list } },
            -- "swipe" and "pan" are the same finger movement at two speeds. The
            -- detector only calls a drag a swipe when the contact lifts inside
            -- ges_swipe_interval (gesturedetector.lua:347-361); a slower, more
            -- deliberate one is delivered as a stream of "pan" events
            -- (gesturedetector.lua:987) closed by a "pan_release"
            -- (gesturedetector.lua:1195). Binding only "swipe" is why an earlier
            -- cut of this panel appeared to ignore scrolling entirely.
            -- readermenu.lua:124-173 registers both for the same handler for
            -- exactly this reason.
            --
            -- Hit-testing differs between the two and it matters: a swipe
            -- reports `pos` as the CONTACT point (gesturedetector.lua:941-947),
            -- a pan reports it as the CURRENT finger position, so a pan that
            -- wanders out of the list stops matching part-way through. Harmless
            -- here -- see onPanList.
            SwipeList = { GestureRange:new{ ges = "swipe", range = in_list } },
            PanList = { GestureRange:new{ ges = "pan", range = in_list } },
            PanListRelease = { GestureRange:new{ ges = "pan_release", range = in_list } },
        }
    end

    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self:_buildPage()
end

function ChapterList:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

--- Realise TextWidgets for the visible page only.
-- A 900-entry TOC would otherwise mean 1800 shaped strings sitting in memory
-- for the sake of the ten that are on screen.
function ChapterList:_buildPage()
    self:free()
    self.rows = {}
    if #self.entries == 0 then return end

    local first = (self.page - 1) * self.per_page + 1
    local last = math.min(first + self.per_page - 1, #self.entries)
    for i = first, last do
        local entry = self.entries[i]
        local is_current = (i == self.current)
        local num = TextWidget:new{
            text = entry.number,
            face = self.face_num,
            bold = is_current,
            padding = 0,
        }
        local indent = self.indent_w * math.max(0, (entry.depth or 1) - 1)
        -- Whatever is left once the indent and the number column are paid for.
        local avail = self.num_right - Layout.x(REF_NUM_GAP) - num:getSize().w
                    - self.margin - indent
        local title = TextWidget:new{
            text = entry.text,
            face = is_current and self.face_row_bold or self.face_row,
            padding = 0,
            max_width = math.max(Layout.x(80), avail),
        }
        table.insert(self.rows, {
            entry = entry,
            title = title,
            num = num,
            indent = indent,
            current = is_current,
        })
    end
end

--- Move to `page`, clamped.
-- Returns true only when the page really changed. onPanList needs to know: a
-- drag that keeps pushing past the last page must not bank that distance, or
-- reversing would have to pay the phantom debt back before anything moved.
function ChapterList:_setPage(page)
    if page < 1 then page = 1 end
    if page > self.total_pages then page = self.total_pages end
    if page == self.page then return false end
    self.page = page
    self:_buildPage()
    -- Only this widget's rect: the header and the document behind the panel are
    -- untouched, so the e-ink update stays small. The rail's thumb is derived
    -- from self.page in _paintRail, so it rides along in this same refresh.
    UIManager:setDirty(self.show_parent or self, "ui", self.dimen)
    return true
end

function ChapterList:_paintRail(bb, x, y)
    local cx = x + self.rail_x + math.floor(self.rail_col_w / 2)
    local tri_w = Layout.x(REF_RAIL_TRI_W)
    local tri_h = Layout.y(REF_RAIL_TRI_H)
    local gap = Layout.y(REF_RAIL_GAP)

    paintTriangle(bb, cx, y + gap, tri_w, tri_h, true)
    paintTriangle(bb, cx, y + self.height - gap - tri_h, tri_w, tri_h, false)

    local track_w = Layout.x(REF_RAIL_TRACK_W)
    local track_x = cx - math.floor(track_w / 2)
    local track_y = y + gap + tri_h + gap
    local track_h = (y + self.height - gap - tri_h - gap) - track_y
    if track_h <= 0 then return end -- a very short screen: arrows only

    paintHatch(bb, track_x, track_y, track_w, track_h)
    paintOutline(bb, track_x, track_y, track_w, track_h)

    -- Length reflects how much of the list one page covers, position reflects
    -- how far down we are. Both are the whole point of the rail, so neither is
    -- faked with a fixed-size marker.
    local shown = math.min(1, self.per_page / math.max(1, #self.entries))
    local thumb_h = math.max(Layout.y(40), math.floor(track_h * shown))
    if thumb_h > track_h then thumb_h = track_h end
    local travel = track_h - thumb_h
    local thumb_y = track_y
    if self.total_pages > 1 then
        thumb_y = track_y + math.floor(travel * (self.page - 1) / (self.total_pages - 1))
    end
    bb:paintRect(track_x, thumb_y, track_w, thumb_h, Blitbuffer.COLOR_BLACK)
end

function ChapterList:paintTo(bb, x, y)
    -- Refreshed on every paint: the enclosing VerticalGroup decides where this
    -- lands, and a stale rect would route taps to where the list used to be.
    self.dimen.x, self.dimen.y = x, y

    if #self.entries == 0 then
        -- A book with no TOC gets a sentence, not an empty rectangle.
        if not self.empty_widget then
            self.empty_widget = TextWidget:new{
                text = self.empty_text,
                face = self.face_empty,
                padding = 0,
                max_width = self.width - 2 * self.margin,
            }
        end
        local size = self.empty_widget:getSize()
        self.empty_widget:paintTo(bb,
            x + math.floor((self.width - size.w) / 2),
            y + Layout.y(REF_EMPTY_H))
        return
    end

    local bar_w = Layout.x(REF_BAR_W)
    local bar_h = Layout.y(REF_BAR_H)
    local bar_x = Layout.x(REF_BAR_X)

    for i, row in ipairs(self.rows) do
        local row_y = y + (i - 1) * self.row_h
        local title_size = row.title:getSize()
        local num_size = row.num:getSize()
        row.title:paintTo(bb, x + self.margin + row.indent,
            row_y + math.floor((self.row_h - title_size.h) / 2))
        row.num:paintTo(bb, x + self.num_right - num_size.w,
            row_y + math.floor((self.row_h - num_size.h) / 2))
        if row.current then
            -- In the margin, left of the text. Never a filled row background.
            bb:paintRect(x + bar_x, row_y + math.floor((self.row_h - bar_h) / 2),
                bar_w, bar_h, Blitbuffer.COLOR_BLACK)
        end
    end

    self:_paintRail(bb, x, y)
end

function ChapterList:onTapList(_, ges_ev)
    local lx = ges_ev.pos.x - self.dimen.x
    local ly = ges_ev.pos.y - self.dimen.y

    if lx >= self.rail_x then
        -- The whole gutter pages, not just the triangles: a 34px arrow is a
        -- cruel tap target, and the top and bottom halves are unambiguous.
        if ly < math.floor(self.height / 2) then
            self:_setPage(self.page - 1)
        else
            self:_setPage(self.page + 1)
        end
        return true
    end

    local row = self.rows[math.floor(ly / self.row_h) + 1]
    if row and self.on_select then
        self.on_select(row.entry)
    end
    -- Swallow either way, so a tap on empty list space does not fall through to
    -- the panel's "tap outside closes me" handler.
    return true
end

--- A flick: north (finger up) reveals later entries, south earlier ones, so the
-- content travels with the finger.
function ChapterList:onSwipeList(_, ges_ev)
    -- A drag a few degrees off vertical is reported as "northeast" and friends
    -- (gesturedetector.lua:329-343). Nobody flicks a list at exactly 90 degrees,
    -- and on a list the diagonals mean nothing else, so match the prefix.
    local dir = (ges_ev.direction or ""):sub(1, 5)
    if dir == "north" then
        self:_setPage(self.page + 1)
    elseif dir == "south" then
        self:_setPage(self.page - 1)
    end
    self._pan_from_x, self._pan_from_y = nil, nil
    -- Swallowed even when nothing moved (an end stop, or a horizontal flick):
    -- inside this rect a drag is a scroll and never anything else.
    return true
end

--- The slow half of the same gesture.
-- gesturedetector.lua:988-1004 re-sends `relative` on every sample, measured
-- from the contact point rather than from the previous sample, so one anchor is
-- all the state a drag needs and a sample lost to a slow repaint simply catches
-- up on the next one. That also covers the range quirk noted in init: if the
-- finger leaves the list rect the events stop arriving, and whatever the drag
-- had earned so far has already been spent.
function ChapterList:onPanList(_, ges_ev)
    local start = ges_ev.start_pos
    local dy = ges_ev.relative and ges_ev.relative.y
    if not start or not dy then return true end

    if start.x ~= self._pan_from_x or start.y ~= self._pan_from_y then
        -- A fresh drag. Identified by its contact point because a pan carries no
        -- id: two contacts landing on the same pixel is not a thing a finger
        -- does. onPanListRelease clears it too, but only fires when the finger
        -- happens to lift inside the list, so this is the reliable one.
        self._pan_from_x, self._pan_from_y = start.x, start.y
        self._pan_anchor = 0
    end

    -- Distance not yet paid out as page turns. Signed, so reversing mid-drag
    -- scrolls back rather than having to undo the whole drag first.
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

function ChapterList:onPanListRelease()
    self._pan_from_x, self._pan_from_y = nil, nil
    return true
end

function ChapterList:onNextListPage()
    self:_setPage(self.page + 1)
    return true
end

function ChapterList:onPrevListPage()
    self:_setPage(self.page - 1)
    return true
end

function ChapterList:free()
    if self.rows then
        for _idx, row in ipairs(self.rows) do
            row.title:free()
            row.num:free()
        end
    end
    if self.empty_widget then
        self.empty_widget:free()
        self.empty_widget = nil
    end
end

--------------------------------------------------------------------------------
-- PageList: the panel itself.
--------------------------------------------------------------------------------
local PageList = InputContainer:extend{
    name = "kindleui_page_list",
    modal = true,
    ui = nil,
    -- Deliberately NOT covers_fullscreen: the reader's chrome above stays lit.
}

function PageList:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    -- Everything the firmware leaves visible above the panel: the clock strip,
    -- the icon toolbar and the book-title strip (kindleui_geom.lua:9-12).
    self.panel_y = Layout.h(Layout.STATUS) + Layout.h(Layout.TOOLBAR) + Layout.h(Layout.BOOKBAR)
    self.panel_h = self.screen_h - self.panel_y
    self.margin = Theme.margin()
    self.inner_w = Theme.innerW()

    self.face_title = Theme.faceBold(REF_BOOK_TITLE_H)
    self.face_author = Theme.face(REF_AUTHOR_H)
    self.face_chevron = Theme.face(REF_CHEVRON_H)
    self.face_goto = Theme.face(REF_GOTO_TEXT_H)
    self.face_goto_chev = Theme.face(REF_GOTO_CHEV_H)
    self.face_row = Theme.face(REF_ROW_TEXT_H)
    self.face_row_bold = Theme.faceBold(REF_ROW_TEXT_H)
    self.face_num = Theme.face(REF_ROW_NUM_H)

    -- Screen-wide ranges whose handlers decide what the point means, the same
    -- shape ConfigDialog uses for its own tap-outside close (configdialog.lua:877).
    if Device:isTouchDevice() then
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
                    -- Not the whole screen: everything except the chapter list.
                    -- update() builds the rect once the header's height is
                    -- known; until then match() sees nil and declines
                    -- (gesturerange.lua:36).
                    range = function() return self.close_zone end,
                },
            },
        }
    end

    if Device:hasKeys() then
        -- Without this a non-touch device could open the panel and never close
        -- it; ConfigDialog wires the same group at configdialog.lua:897.
        self.key_events = {
            Close = { { Device.input.group.Back } },
            -- Paging by key, since the rail and the drag both need a finger.
            NextListPage = { { Device.input.group.PgFwd } },
            PrevListPage = { { Device.input.group.PgBack } },
        }
    end

    self:update()
end

--------------------------------------------------------------------------------
-- Data
--------------------------------------------------------------------------------

--- Title and author, as ReaderUI itself resolves them.
-- readerui.lua:492-495 stores `document:getProps()` into doc_settings and keeps
-- an extended copy in `self.doc_props`; extendProps fills `display_title` from
-- the filename when the file carries no title metadata
-- (filemanagerbookinfo.lua:315). `authors` is a single string, newline-separated
-- when there are several, which upstream shortens the way we do here
-- (bookmarkbrowser.lua:361).
function PageList:_bookInfo()
    local props = self.ui and self.ui.doc_props
    local title = props and props.display_title
    if not title or title == "" then
        -- doc_props is only built once the document has loaded; fall back to the
        -- filename rather than showing nothing.
        local file = self.ui and self.ui.document and self.ui.document.file
        local base = file and file:match("([^/\\]+)$")
        title = base and (base:gsub("%.[^.]+$", "")) or _("Document")
    end
    local authors = props and props.authors
    if authors and authors ~= "" then
        authors = authors:gsub("\n.*", " " .. _("et al."))
    else
        authors = nil
    end
    return title, authors
end

--- The flattened TOC, as rows this panel can paint.
-- ReaderToc:fillToc (readertoc.lua:159) populates `toc.toc` from
-- `document:getToc()` and runs validateAndFixToc, so every entry is ordered and
-- carries title / page / depth (and xpointer, for CRE documents).
-- `getTocIndexByPage` (readertoc.lua:382) returns the entry covering a page --
-- the first one starting on it, else the last one before it -- which is exactly
-- the "current chapter" this panel marks.
function PageList:_readToc()
    local toc = self.ui and self.ui.toc
    if not toc then
        logger.warn("kindleui: no ReaderToc module; showing an empty Go To list")
        return {}, nil
    end

    local ok, err = pcall(function() toc:fillToc() end)
    if not ok then
        -- A malformed TOC should cost us the list, not the panel.
        logger.warn("kindleui: fillToc failed:", err)
        return {}, nil
    end

    local raw = toc.toc or {}
    -- ReaderToc keeps the live page number from PageUpdate/PosUpdate
    -- (readertoc.lua:127, 153); ReaderUI:getCurrentPage (readerui.lua:1000) is
    -- the fallback for the moment before the first of those has fired.
    local pageno = toc.pageno or (self.ui.getCurrentPage and self.ui:getCurrentPage())
    local current
    if pageno then
        current = toc:getTocIndexByPage(pageno)
    end

    -- Page labels, when the document has a page map, are what the reader shows
    -- everywhere else; readertoc.lua:877-879 substitutes them for the raw page
    -- number in its own menu, so this list does the same.
    local pagemap = self.ui.pagemap
    local use_labels = pagemap and pagemap:wantsPageLabels()

    local entries = {}
    for i, v in ipairs(raw) do
        local number
        if use_labels and v.xpointer then
            number = pagemap:getXPointerPageLabel(v.xpointer)
        end
        number = number or v.page
        entries[i] = {
            -- cleanUpTocTitle (readertoc.lua:90) strips the stray CRs some
            -- EPUBs carry and substitutes an en-dash for a blank title.
            text = toc.cleanUpTocTitle and toc:cleanUpTocTitle(v.title, true) or (v.title or ""),
            number = tostring(number or ""),
            depth = v.depth or 1,
            page = v.page,
            xpointer = v.xpointer,
        }
    end
    return entries, current
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

--- Jump to a chapter, exactly as ReaderToc's own menu does at readertoc.lua:984-990.
-- The location stack push is what makes "back" return here, and the xpointer
-- form is preferred because on a reflowable document a page number is only
-- valid for the current font size.
function PageList:_gotoEntry(entry)
    UIManager:close(self)
    if self.ui.link then
        self.ui.link:addCurrentLocationToStack()
    end
    if entry.xpointer then
        self.ui:handleEvent(Event:new("GotoXPointer", entry.xpointer, entry.xpointer))
    elseif entry.page then
        self.ui:handleEvent(Event:new("GotoPage", entry.page))
    end
end

--- Open KOReader's existing go-to dialog.
-- ReaderGoto:onShowGotoDialog (readergoto.lua:33) builds the InputDialog with
-- the page/percentage entry and the Skim and Pin buttons. It is reached by the
-- "ShowGotoDialog" event, which is how Dispatcher's own `go_to` action invokes
-- it (dispatcher.lua:178); ReaderGoto is registered as a ReaderUI child module
-- (readerui.lua:208), so a handleEvent on self.ui finds it. Reimplementing a
-- number pad here would be a second, diverging dialog.
function PageList:_openGotoDialog()
    UIManager:close(self)
    -- The row is painted even when this panel was built without a ReaderUI (a
    -- preview, a test); closing without dispatching beats an index error.
    if self.ui then
        self.ui:handleEvent(Event:new("ShowGotoDialog"))
    end
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

function PageList:_buildChevron()
    return Theme.Tappable:new{
        on_tap = function() UIManager:close(self) end,
        CenterContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = Layout.y(REF_CHEVRON_H) },
            -- The status bar shows this glyph mirrored (chev_up) as the pull-up
            -- hint; down here it means "push me back".
            TextWidget:new{ text = Theme.GLYPH.chev_down, face = self.face_chevron, padding = 0 },
        },
    }
end

function PageList:_buildHeader()
    local title, author = self:_bookInfo()
    local items = {
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = self.margin },
            TextWidget:new{
                text = title,
                face = self.face_title,
                padding = 0,
                max_width = self.inner_w,
            },
        },
    }
    if author then
        table.insert(items, VerticalSpan:new{ width = Layout.y(REF_TITLE_GAP) })
        table.insert(items, HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = self.margin },
            TextWidget:new{
                text = author,
                face = self.face_author,
                padding = 0,
                max_width = self.inner_w,
            },
        })
    end

    local group = VerticalGroup:new{ align = "left" }
    for _idx, item in ipairs(items) do
        table.insert(group, item)
    end
    return group
end

function PageList:_buildGotoRow()
    local label = TextWidget:new{
        text = _("Go to page or location"),
        face = self.face_goto,
        padding = 0,
    }
    local chev = TextWidget:new{
        text = Theme.GLYPH.chev_right,
        face = self.face_goto_chev,
        padding = 0,
    }
    -- Push the chevron to the far right; never let the spacer go negative, or
    -- HorizontalGroup would stack the two on top of each other.
    local spacer = self.inner_w - label:getSize().w - chev:getSize().w
    if spacer < Size.span.horizontal_default then
        spacer = Size.span.horizontal_default
    end

    return Theme.Tappable:new{
        on_tap = function() self:_openGotoDialog() end,
        CenterContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = Layout.y(REF_GOTO_ROW_H) },
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = self.margin },
                label,
                HorizontalSpan:new{ width = spacer },
                chev,
                HorizontalSpan:new{ width = self.margin },
            },
        },
    }
end

function PageList:update()
    if self.panel_frame then
        self.panel_frame:free()
    end

    local items = {}
    table.insert(items, VerticalSpan:new{ width = Layout.y(REF_PAD_TOP) })
    table.insert(items, self:_buildChevron())
    table.insert(items, VerticalSpan:new{ width = Layout.y(REF_CHEVRON_GAP) })
    table.insert(items, self:_buildHeader())
    table.insert(items, VerticalSpan:new{ width = Layout.y(REF_HEADER_GAP) })
    -- Full bleed, so it cannot carry the side padding the rows do.
    table.insert(items, Theme.rule())
    table.insert(items, self:_buildGotoRow())
    table.insert(items, HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = self.margin },
        Theme.hairline(),
    })

    local header_h = 0
    for _idx, widget in ipairs(items) do
        header_h = header_h + widget:getSize().h
    end

    local entries, current = self:_readToc()
    -- Kindle separates this panel from the page above it with a rule, and the
    -- page it interrupts is mid-paragraph -- without one the panel reads as a
    -- chunk of text that simply stopped rendering. The rule is taken OUT of the
    -- band rather than added to it, or the list would run past the bottom edge.
    local rule_h = Size.line.thick
    local list_h = self.panel_h - header_h - rule_h
    if list_h < Layout.y(REF_ROW_H) then
        -- A screen too short for even one row: let the panel grow past the band
        -- rather than clip the list to nothing.
        logger.warn("kindleui: Go To header takes", header_h,
            "px of a", self.panel_h, "px band; growing the panel")
        list_h = Layout.y(REF_ROW_H)
    end

    self.list = ChapterList:new{
        entries = entries,
        current = current,
        width = self.screen_w,
        height = list_h,
        face_row = self.face_row,
        face_row_bold = self.face_row_bold,
        face_num = self.face_num,
        face_empty = self.face_author,
        empty_text = _("This book has no table of contents."),
        show_parent = self,
        on_select = function(entry) self:_gotoEntry(entry) end,
    }
    table.insert(items, self.list)

    local content = VerticalGroup:new{ align = "left" }
    for _idx, widget in ipairs(items) do
        table.insert(content, widget)
    end

    self.panel_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = 0,
        -- FrameContainer paints its background over width x height
        -- (framecontainer.lua:118) even though getSize reports the content box,
        -- which is how the panel fills its band exactly and hides the page below.
        width = self.screen_w,
        height = header_h + list_h,
        content,
    }

    -- Anchoring. TopContainer over the whole screen plus a leading VerticalSpan,
    -- rather than positioning the frame itself: a widget's own x/y is only
    -- honoured by the containers that read dimen.x (LeftContainer does,
    -- CenterContainer does not), so "set the frame's position" would mean
    -- overriding paintTo with a literal offset and keeping self.dimen in sync by
    -- hand. A span is one number in one place, and the group below stays a plain
    -- widget tree that free() and getSize() already understand.
    self[1] = TopContainer:new{
        dimen = Screen:getSize(),
        VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = self.panel_y },
            -- Outside panel_frame on purpose: that frame pads its content in
            -- from both margins, and a rule inside it would stop short of the
            -- screen edges instead of closing the band off.
            LineWidget:new{
                dimen = Geom:new{ w = self.screen_w, h = rule_h },
            },
            self.panel_frame,
        },
    }

    -- The band, and only the band: UIManager refreshes setDirty regions against
    -- this, so the reader's chrome above is never repainted.
    self.dimen = Geom:new{ x = 0, y = self.panel_y, w = self.screen_w, h = rule_h + header_h + list_h }

    -- Where a swipe means "close": the reader's chrome above the panel plus the
    -- panel's own header, which is to say everything that is not the chapter
    -- list. Recomputed here rather than in init() because the header's height
    -- depends on whether the book has an author line.
    self.close_zone = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.panel_y + rule_h + header_h }
end

function PageList:paintTo(bb, x, y)
    -- Not InputContainer's version: that one would derive self.dimen from the
    -- full-screen TopContainer and we would repaint the whole display.
    self[1]:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y + self.panel_y
end

function PageList:onCloseWidget()
    -- Same reasoning as ConfigDialog:onCloseWidget (configdialog.lua:955): the
    -- widgets underneath have to be redrawn where we were, and nowhere else.
    UIManager:setDirty(nil, "ui", self.dimen)
end

function PageList:onTapClosePanel(_, ges_ev)
    if ges_ev.pos.y < self.panel_y then
        UIManager:close(self)
    end
    -- Taps inside the panel that reached us missed every control; swallow them
    -- so they do not fall through to the document.
    return true
end

--- Push the panel back up the way it came.
--
-- South, because the panel hangs from the top. It used to be south ANYWHERE,
-- which is why the list only paged by tap; the hardware scrolls its Go To list
-- by drag, so that had to go and the two gestures had to be told apart.
--
-- The alternative was to keep the screen-wide range and let south close only
-- while the list already sits on its first page. Rejected: the same finger
-- movement in the same place would then do two different things according to a
-- scroll position the user is not looking at, and a gesture that is sometimes a
-- scroll and sometimes a dismissal is one users learn to distrust.
--
-- So the split is spatial, and the boundary is the one thing on screen that
-- cannot be hidden state -- the edge of the list itself. Inside the list rect a
-- drag always scrolls (ChapterList swallows it in onSwipeList / onPanList),
-- including on a book with no table of contents, where it scrolls nothing:
-- consistent beats helpful. Above the list -- the chevron, the title, the "Go to
-- page" row, and the reader's own chrome above the panel -- a south swipe always
-- closes. Tapping the chevron and tapping outside the panel are unchanged, so
-- there are three ways out and none of them is the list.
function PageList:onSwipeClosePanel(_, ges_ev)
    if ges_ev.direction == "south" then
        UIManager:close(self)
        return true
    end
end

function PageList:onNextListPage()
    return self.list and self.list:onNextListPage()
end

function PageList:onPrevListPage()
    return self.list and self.list:onPrevListPage()
end

function PageList:onClose()
    UIManager:close(self)
    return true
end

return PageList
