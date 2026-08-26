--[[--
Kindle's reading chrome: the two bands that drop from the top edge when you tap
it with a book open, plus the progress band that rises from the bottom at the
same moment.

The firmware draws each as its own X window, and the names it gives the top two
are actively misleading (see kindleui_geom.lua for the xwininfo dump):

    searchBar   1236x115 @ y=101    the ICON toolbar, no search field in sight
    appToolBar  1236x126 @ y=216    the BOOK TITLE, nothing app-like about it
    footerBar   1236x311 @ y=1337   chapter, position and the scrubber

    ┌──────────────────────────────────────────┐
    │ ← Home        Aa   ☰   ✎   🔍   ⋮        │  115
    │ ---------------------------------------- │  hairline, inset
    │ The Name of the Wind                     │  126
    │ ══════════════════════════════════════── │  thick, full bleed
    └──────────────────────────────────────────┘
                    ... page, untouched ...
    ┌──────────────────────────────────────────┐  thin rule, full bleed
    │              Chapter 11                  │
    │  ◀    Page 812 of 1,096 | 4 m | 74%   ▶  │
    │            │      │         │            │  chapter ticks
    │  ▦  ━━━━━━━━━━●───────(○)─────────────   │
    └──────────────────────────────────────────┘  311

Three things follow from those rects and are the reason this file looks the way
it does.

First, the firmware's bands simply stop: nothing between them is dimmed or
covered, so this widget must not set `covers_fullscreen` and must never paint
over the middle of the screen.

Second, the separator that belongs to a band is carved out of that band's
height, never added to it, so each frame gives up exactly the rule's height to
make room. Get that wrong and the title strip sits a rule lower than the
firmware's.

Third -- and this is the one that bites -- the top bands and the footer are
DISJOINT rects with two thirds of the screen between them, and main.lua shows us
with `UIManager:show(widget, "ui", widget.dimen)`, i.e. it refreshes exactly one
rect. See the comment on `Toolbar:onShow` for how that is resolved and why it is
not resolved by growing `self.dimen`.

Structurally this is kindleui_controlcentre.lua with a shorter body: the same
TopContainer anchor, the same "tap outside me closes me", the same swipe north.
]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
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
local LeftContainer = require("ui/widget/container/leftcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local Theme = require("kindleui_theme")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")
local Screen = Device.screen

-- Kindle reference pixels, against kindleui_geom.lua's 1236x1648 panel.
-- Anything not listed here comes from Theme.REF, which is the shared set.
local REF_HOME_GAP  = 20   -- between the back arrow and the word "Home"
local REF_ICON_CELL = 112  -- one right-hand icon's slot; 5 of them = 560 of 1124 inner px
local REF_AA_H      = 52   -- "Aa" is letterforms, not a full-bleed glyph, so it needs a
                           -- larger em to read at the same optical size as its neighbours

-- The footer band. Measured off the same PW5 screenshot as everything else.
local REF_FOOT_LINE_GAP = 10  -- between the chapter title and the status line
local REF_FOOT_ROW_GAP  = 33  -- between the chapter block and the scrubber row
local REF_SCRUB_ROW_H   = 66  -- row 2, the grid glyph and the track
local REF_SCRUB_GAP     = 24  -- between the grid glyph and the start of the track
local REF_TRACK_THICK   = 8   -- bar behind the read part
local REF_TRACK_THIN    = 3   -- line ahead of it
local REF_KNOB_D        = 40
local REF_KNOB_RING     = 5
local REF_TICK_H        = 16  -- chapter boundary marks, standing above the bar
local REF_TICK_W        = 3
local REF_TICK_GAP      = 6   -- between the foot of a tick and the bar

--- The separator between the parts of the status line, as Kindle spaces it.
local STATUS_SEP = "  |  "

--------------------------------------------------------------------------------
-- Scrubber: the position bar in the footer band.
--
-- Hand-painted for the same reason kindleui_slider.lua is: KOReader's
-- ProgressWidget draws a bordered, filled bar (progresswidget.lua:112 onwards)
-- and has no concept of a knob, let alone two of them. Kindle's shape is a bare
-- rule with a disc riding it, so the blitbuffer is the shortest honest route.
--
-- Two knobs, because they mean different things. The SOLID one is where the
-- book actually is and never moves until a jump commits; the HOLLOW one only
-- exists mid-drag and is where the finger is. Showing one knob that follows the
-- finger would claim the jump had already happened.
--------------------------------------------------------------------------------
local Scrubber = InputContainer:extend{
    width = nil,
    height = nil,
    percent = 0,       -- 0..1, the current reading position
    ticks = nil,       -- array of 0..1 fractions, one per chapter start
    on_seek = nil,     -- on_seek(fraction), fired once, on commit
    is_blocked = nil,  -- function() -> bool; true while gestures must be ignored
    drag_percent = nil,
}

function Scrubber:init()
    self.track_thick = math.max(Size.line.thick, Layout.y(REF_TRACK_THICK))
    self.track_thin  = math.max(Size.line.medium, Layout.y(REF_TRACK_THIN))
    self.knob_r      = math.floor(Layout.x(REF_KNOB_D) / 2)
    self.knob_ring   = math.max(Size.line.thick, Layout.x(REF_KNOB_RING))
    self.tick_h      = Layout.y(REF_TICK_H)
    self.tick_w      = math.max(Size.line.medium, Layout.x(REF_TICK_W))
    self.tick_gap    = Layout.y(REF_TICK_GAP)

    if not Device:isTouchDevice() then return end

    -- gesturerange.lua:29 documents the closure form: a widget's dimen only
    -- exists once it has been painted, so match() resolves the rect at gesture
    -- time. The widening while a drag is live is deliberate: a finger that
    -- drifts off the 66px-tall row mid-drag must still be able to release, or
    -- the hollow knob is stranded and the jump never commits.
    local function range()
        if self.drag_percent then
            return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
        end
        return self.dimen
    end

    self.ges_events = {
        TapScrub = {
            GestureRange:new{ ges = "tap", range = function() return self.dimen end },
        },
        PanScrub = {
            GestureRange:new{
                ges = "pan",
                range = range,
                -- Same throttle FrontLightWidget uses (frontlightwidget.lua:34);
                -- an e-ink panel cannot keep up with raw pan event rates.
                rate = Screen.low_pan_rate and 3 or 30,
            },
        },
        -- Both endings have to be registered. Contact:panState splits the lift
        -- two ways (gesturedetector.lua:794-799): a drag fast enough to pass
        -- isSwipe becomes a `swipe`, anything slower falls through to
        -- handlePanRelease and becomes `pan_release`. Registering only one of
        -- them leaves half of all real drags uncommitted -- and which half
        -- depends on how briskly the reader happens to move a finger.
        PanReleaseScrub = {
            GestureRange:new{ ges = "pan_release", range = range },
        },
        SwipeScrub = {
            GestureRange:new{ ges = "swipe", range = range },
        },
    }
end

function Scrubber:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Scrubber:paintTo(bb, x, y)
    -- Recorded on every paint, not just at init: the parent group decides where
    -- this lands, and a stale rect would route drags to the wrong place.
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }

    -- The knobs move and refresh() repaints only this widget, so the previous
    -- frame has to be wiped or the old knob is left stranded on the track.
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)

    local content_h = self.tick_h + self.tick_gap + 2 * self.knob_r
    local top = y + math.max(0, math.floor((self.height - content_h) / 2))
    local cy = top + self.tick_h + self.tick_gap + self.knob_r

    -- Inset by the knob radius at both ends so a knob at 0% or 100% still sits
    -- inside the row instead of half-way into the margin.
    local t0 = x + self.knob_r
    local t1 = x + self.width - self.knob_r
    local travel = t1 - t0
    if travel < 0 then travel = 0 end
    self._t0, self._travel = t0, travel

    -- paintRect(x, y, w, h, value) and paintCircle below: signatures as cited in
    -- kindleui_slider.lua (blitbuffer.lua:1704 and 1948), which paints the same
    -- primitives for the brightness track.
    -- Ticks are drawn only when they can still be read as separate marks.
    --
    -- A 21,000-page book with several hundred chapters puts a boundary every
    -- pixel or two, and the row stops being a set of marks and becomes one solid
    -- black bar across the whole width -- which is exactly what it looked like on
    -- device. A bar that dense carries no information: it says "there are
    -- chapters", which the reader already knew.
    --
    -- The threshold is the tick's own width plus a gap of the same size, so the
    -- test is "would two neighbouring ticks touch", answered in the units of the
    -- thing being drawn rather than a number picked to look right.
    local ticks_readable = true
    if self.ticks and #self.ticks > 1 then
        local min_gap = self.tick_w * 2
        if (travel / #self.ticks) < min_gap then
            ticks_readable = false
        end
    end
    if self.ticks and ticks_readable then
        for _idx, frac in ipairs(self.ticks) do
            local tx = t0 + math.floor(travel * frac + 0.5)
            bb:paintRect(tx - math.floor(self.tick_w / 2), top,
                self.tick_w, self.tick_h, Blitbuffer.COLOR_BLACK)
        end
    end

    local cx = t0 + math.floor(travel * self.percent + 0.5)
    if cx > t0 then
        bb:paintRect(t0, cy - math.floor(self.track_thick / 2), cx - t0,
            self.track_thick, Blitbuffer.COLOR_BLACK)
    end
    if t1 > cx then
        bb:paintRect(cx, cy - math.floor(self.track_thin / 2), t1 - cx,
            self.track_thin, Blitbuffer.COLOR_BLACK)
    end

    -- paintCircle's `w` is the ring width and defaults to r, i.e. a solid disc.
    bb:paintCircle(cx, cy, self.knob_r, Blitbuffer.COLOR_BLACK, self.knob_r)

    if self.drag_percent then
        local dx = t0 + math.floor(travel * self.drag_percent + 0.5)
        -- White fill first, or the bar and the solid knob show through the ring.
        bb:paintCircle(dx, cy, self.knob_r, Blitbuffer.COLOR_WHITE, self.knob_r)
        bb:paintCircle(dx, cy, self.knob_r, Blitbuffer.COLOR_BLACK, self.knob_ring)
    end
end

function Scrubber:_fracFromX(pos_x)
    if not self._t0 or self._travel <= 0 then return self.percent end
    local frac = (pos_x - self._t0) / self._travel
    if frac < 0 then return 0 end
    if frac > 1 then return 1 end
    return frac
end

function Scrubber:_blocked()
    return self.dimen == nil or (self.is_blocked ~= nil and self.is_blocked())
end

--- Repaints this row and nothing else, for the live drag.
-- Same dance as kindleui_slider.lua and readerfooter.lua:2382: paint first so
-- the dimen is current, then setDirty with a nil widget so nothing underneath is
-- redrawn. "fast" (A2) rather than "ui", because a full-flash per pan sample
-- would make dragging unusable on e-ink.
function Scrubber:refresh()
    if not self.dimen then return end
    UIManager:widgetRepaint(self, self.dimen.x, self.dimen.y)
    UIManager:setDirty(nil, "fast", self.dimen)
end

--- Hands the jump over and drops the hollow knob.
-- No repaint here: on_seek rebuilds the whole band (chapter title, position,
-- percentage all move together) and asks for one refresh covering the lot.
function Scrubber:_commit(frac)
    self.drag_percent = nil
    self.percent = frac
    if self.on_seek then self.on_seek(frac) end
    return true
end

function Scrubber:onTapScrub(_arg, ges_ev)
    if self:_blocked() then return false end
    return self:_commit(self:_fracFromX(ges_ev.pos.x))
end

function Scrubber:onPanScrub(_arg, ges_ev)
    if self:_blocked() then return false end
    self.drag_percent = self:_fracFromX(ges_ev.pos.x)
    self:refresh()
    return true
end

function Scrubber:onPanReleaseScrub(_arg, ges_ev)
    -- Not dragging means this release belongs to somebody else -- most likely
    -- the very gesture that opened the toolbar, whose tail lands on top of us.
    if not self.drag_percent then return false end
    return self:_commit(self:_fracFromX(ges_ev.pos.x))
end

function Scrubber:onSwipeScrub()
    if not self.drag_percent then return false end
    -- Deliberately NOT ges_ev.pos: alone among the gestures, a swipe reports the
    -- CONTACT point rather than the lift (gesturedetector.lua:942-946). The last
    -- pan sample is the only truthful "where the finger ended up" we have.
    return self:_commit(self.drag_percent)
end

--------------------------------------------------------------------------------
-- Toolbar
--------------------------------------------------------------------------------
local Toolbar = InputContainer:extend{
    name = "kindleui_toolbar",
    modal = true,
    ui = nil, -- ReaderUI
    -- Deliberately NOT covers_fullscreen: Kindle leaves the page below visible.
}

function Toolbar:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.margin_x = Theme.margin()
    self.toolbar_h = Layout.h(Layout.TOOLBAR)
    self.bookbar_h = Layout.h(Layout.BOOKBAR)
    self.footer_h  = Layout.h(Layout.FOOTER)

    self.face_icon    = Theme.face(Theme.REF.icon_h)
    self.face_label   = Theme.face(Theme.REF.title_h)        -- "Home", normal weight
    self.face_aa      = Theme.face(REF_AA_H)
    self.face_title   = Theme.faceBold(Theme.REF.heading_h)  -- the book title
    self.face_chapter = Theme.face(Theme.REF.title_h)        -- footer line 1
    self.face_status  = Theme.face(Theme.REF.sub_h)          -- footer line 2, smaller

    -- Mirrors ConfigDialog (configdialog.lua:877) and the control centre: a
    -- screen-wide range whose handler decides whether the point fell outside.
    -- The bands' own controls are children, and WidgetContainer:handleEvent
    -- propagates to children before itself (widgetcontainer.lua:96-105), so a
    -- tap on an icon is consumed there and never reaches this.
    self.ges_events = {
        TapCloseToolbar = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h },
            },
        },
        SwipeCloseToolbar = {
            GestureRange:new{
                ges = "swipe",
                range = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h },
            },
        },
    }

    if Device:hasKeys() then
        -- Without this a non-touch device could open the toolbar and never close
        -- it; ConfigDialog wires the same group at configdialog.lua:897.
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end

    self:update()

    -- Cleared one tick after the opening gesture can plausibly still be running.
    self._opening = true
    UIManager:scheduleIn(0.35, function() self._opening = false end)
end

--------------------------------------------------------------------------------
-- Actions
--
-- Every one of these closes first. The handlers all live *below* us on
-- UIManager's window stack, and several of them (ShowMenu, ShowBookmark) push a
-- widget of their own; leaving the toolbar up would strand it behind whatever
-- opened, with no gesture left that could reach it.
--------------------------------------------------------------------------------

function Toolbar:_close()
    UIManager:close(self)
end

function Toolbar:_goHome()
    self:_close()
    if not (self.ui and self.ui.handleEvent) then return end
    -- ReaderUI:onHome (readerui.lua:929) closes the document and hands the file
    -- back to the file manager. It is a real, currently-registered handler --
    -- readerback.lua:173 reaches the file browser through exactly this event --
    -- so no fallback is needed.
    self.ui:handleEvent(Event:new("Home"))
end

function Toolbar:_showAaMenu()
    self:_close()
    -- Not a KOReader event. A sibling module in this plugin is meant to answer
    -- it with the Kindle font/layout sheet; until one registers a handler
    -- nothing consumes this and the tap is a silent no-op, which is the intended
    -- fallback (the same contract kindleui_controlcentre.lua uses for
    -- "XtreaderSync"). sendEvent rather than self.ui:handleEvent because the
    -- handler may be a plugin mounted on the FileManager side too.
    UIManager:sendEvent(Event:new("ShowKindleAaMenu"))
end

function Toolbar:_showPageList()
    self:_close()
    -- Same contract as ShowKindleAaMenu: a sibling module's event, silently
    -- inert if that module is not loaded. Note this is NOT main.lua's
    -- "ShowKindlePageBrowser" (the thumbnail grid on a swipe up from the
    -- bottom); Kindle's toc icon opens the chapter *list*, a different screen.
    UIManager:sendEvent(Event:new("ShowKindlePageList"))
end

function Toolbar:_showBookmarks()
    self:_close()
    if not (self.ui and self.ui.handleEvent) then return end
    -- ReaderBookmark:onShowBookmark (readerbookmark.lua:675), also what
    -- SkimToWidget fires (skimtowidget.lua:280) and what Dispatcher's
    -- "bookmarks" action maps to (dispatcher.lua:207).
    self.ui:handleEvent(Event:new("ShowBookmark"))
end

function Toolbar:_showSearch()
    self:_close()
    if not (self.ui and self.ui.handleEvent) then return end
    -- ReaderSearch:onShowFulltextSearchInput (readersearch.lua:294); Dispatcher
    -- exposes it as the "fulltext_search" action (dispatcher.lua:200). Called
    -- with no argument, which is the "open the empty input box" form.
    self.ui:handleEvent(Event:new("ShowFulltextSearchInput"))
end

function Toolbar:_showStockMenu()
    self:_close()
    -- The deliberate escape hatch. Everything this reskin has not covered yet is
    -- still one tap away through ReaderMenu:onShowMenu (readermenu.lua:390).
    UIManager:sendEvent(Event:new("ShowMenu"))
end

--------------------------------------------------------------------------------
-- Footer actions
--
-- These are the exception to the "close first" rule above: on the firmware the
-- band stays up while you skip chapters or drag the scrubber, and every one of
-- them changes what the band itself prints. So they dispatch, then rebuild.
--
-- All three go through `self.ui:handleEvent`, NEVER `UIManager:sendEvent`.
-- sendEvent hands the event to the topmost widget and, if that widget does not
-- consume it, only continues on to widgets flagged `is_always_active` or holding
-- `active_widgets` (uimanager.lua:915-961). While this band is open WE are the
-- topmost widget and ReaderUI is neither of those things, so a sendEvent here
-- would be delivered to ourselves and silently dropped. That is not a
-- hypothetical: it already cost this plugin a debug cycle.
--------------------------------------------------------------------------------

--- Rebuild both bands and refresh only the footer.
-- Called after anything that moves the reading position. The top bands hold the
-- book title, which a jump cannot change, so there is nothing up there to
-- refresh -- but update() rebuilds them anyway because it is one code path and
-- repainting identical pixels into the framebuffer costs nothing on its own.
-- Only the footer rect is handed to setDirty, so only the footer reaches the
-- EPDC. The `self` (rather than nil) marks us dirty so _repaint calls our
-- paintTo (uimanager.lua:1259) even when the reader below did not repaint.
function Toolbar:_rebuildFooter()
    self:update()
    UIManager:setDirty(self, "ui", self.footer_dimen)
end

function Toolbar:_gotoChapter(event_name)
    if not (self.ui and self.ui.handleEvent) then return end
    -- ReaderRolling:onGotoNextChapter / onGotoPrevChapter (readerrolling.lua:704
    -- and 725) for reflowable documents, ReaderPaging's namesakes
    -- (readerpaging.lua:1191 and 1201) for fixed-layout ones; exactly one of the
    -- two modules is registered per document (readerui.lua:297 vs 382).
    -- Dispatcher exposes the same pair as "prev_chapter"/"next_chapter"
    -- (dispatcher.lua:170-171). Both implementations push the current location
    -- onto the stack themselves, so unlike _seek below we must not do it here or
    -- "back" would need two presses.
    self.ui:handleEvent(Event:new(event_name))
    self:_rebuildFooter()
end

function Toolbar:_showPageBrowser()
    -- The one footer control that does close: whatever answers this pushes a
    -- full-screen grid, and leaving the band up would strand it behind.
    self:_close()
    if not (self.ui and self.ui.handleEvent) then return end
    -- ShowKindlePageBrowser rather than ShowPageBrowser: main.lua answers it with
    -- this plugin's own grid and itself falls back to KOReader's
    -- (readerthumbnail.lua:102) when that cannot load, so the fallback lives in
    -- one place instead of being duplicated at every call site.
    self.ui:handleEvent(Event:new("ShowKindlePageBrowser"))
end

--- Jump to a fraction of the book.
-- Same path kindleui_pagelist.lua:653-660 uses for a chapter row, and for the
-- same reasons: the location-stack push is what makes "back" return here, and
-- GotoPage is answered by ReaderRolling:onGotoPage (readerrolling.lua:756) or
-- ReaderPaging:onGotoPage (readerpaging.lua:1147). The xpointer form pagelist
-- prefers has no meaning here -- a scrubber position is a page number by
-- construction, there is no ToC entry to take a pointer from.
function Toolbar:_seek(frac)
    local pages = self.total_pages
    if not (pages and pages > 0) then return end
    local page = math.floor(frac * pages + 0.5)
    if page < 1 then page = 1 elseif page > pages then page = pages end
    if self.ui and self.ui.handleEvent then
        if self.ui.link then
            self.ui.link:addCurrentLocationToStack()
        end
        self.ui:handleEvent(Event:new("GotoPage", page))
    end
    self:_rebuildFooter()
end

--------------------------------------------------------------------------------
-- Content
--------------------------------------------------------------------------------

--- The book's title as the rest of KOReader would print it.
-- ReaderUI publishes `doc_props` at readerui.lua:495 and `display_title` is the
-- field the footer uses for exactly this (readerfooter.lua:401). It is already
-- filename-with-no-extension when the file carries no title metadata
-- (filemanagerbookinfo.lua:315), so the usual "or the filename" fallback is
-- upstream's job, not ours. The remaining branches only cover being constructed
-- against something that is not a fully-opened ReaderUI.
function Toolbar:_documentTitle()
    local ui = self.ui
    if not ui then return "" end

    if ui.doc_props and ui.doc_props.display_title then
        return ui.doc_props.display_title
    end

    -- doc_settings holds the raw props dict saved at readerui.lua:493, i.e.
    -- before extendProps synthesised display_title.
    if ui.doc_settings and ui.doc_settings.readSetting then
        local props = ui.doc_settings:readSetting("doc_props")
        if type(props) == "table" and props.title then
            return props.title
        end
    end

    if ui.document and ui.document.file then
        -- Last resort: basename, extension and all. Deliberately not
        -- filemanagerutil.splitFileNameType, to avoid pulling the file manager
        -- into the reader for a path that should never be taken.
        local base = ui.document.file:match("([^/]+)$")
        if base then return base end
    end

    logger.warn("kindleui: toolbar could not determine a document title")
    return ""
end

--------------------------------------------------------------------------------
-- Footer data
--
-- Nothing here is computed. ReaderFooter already derives every number Kindle
-- prints in this band and keeps them current -- it is fed by the same
-- PageUpdate/PosUpdate events the reader dispatches on every turn
-- (readerfooter.lua:2403 and 2425) -- so the honest thing is to read its state
-- and its module accessors rather than to run a second, quietly diverging copy
-- of the arithmetic. The instance lives at ui.view.footer (readerview.lua:131).
--
-- Each accessor returns nil rather than a placeholder when the value does not
-- exist for this document. A "N/A" in Kindle's status line would be a lie about
-- the firmware; an absent clause is just a shorter line.
--------------------------------------------------------------------------------

function Toolbar:_footer()
    local ui = self.ui
    if ui and ui.view and ui.view.footer then return ui.view.footer end
    return nil
end

--- The chapter this page belongs to.
-- ReaderToc:getTocTitleByPage (readertoc.lua:445), which already runs the title
-- through cleanUpTocTitle; it is what readerfooter.lua:406 prints for its own
-- "book_chapter" item. Returns "" for a book with no ToC, which the caller
-- treats as "no line".
function Toolbar:_chapterTitle()
    local footer = self:_footer()
    if not (footer and footer.pageno and self.ui.toc) then return nil end
    local title = self.ui.toc:getTocTitleByPage(footer.pageno)
    if title == nil or title == "" then return nil end
    return title
end

--- "Page 812 of 1,096", the branches taken straight from readerfooter.lua's
-- "page_progress" generator (readerfooter.lua:242-259). Kindle says "Loc" here,
-- but Kindle locations are a proprietary index KOReader does not have and
-- inventing one would be worse than naming what we do have.
function Toolbar:_positionText()
    local footer = self:_footer()
    local ui = self.ui
    if not (footer and footer.pageno and footer.pages) then return nil end

    if ui.pagemap and ui.pagemap:wantsPageLabels() then
        -- A book carrying real printed-page labels; they are not necessarily
        -- numbers, so they are passed through untouched (readerpagemap.lua:334
        -- and 354).
        return T(_("Page %1 of %2"),
                 ui.pagemap:getCurrentPageLabel(true), ui.pagemap:getLastPageLabel(true))
    end

    if ui.document and ui.document:hasHiddenFlows() then
        -- Non-linear fragments are being hidden, so the raw page number would
        -- count pages the reader will never see.
        local flow = ui.document:getPageFlow(footer.pageno)
        return T(_("Page %1 of %2"),
                 util.getFormattedSize(ui.document:getPageNumberInFlow(footer.pageno)),
                 util.getFormattedSize(ui.document:getTotalPagesInFlow(flow)))
    end

    -- getFormattedSize is just the thousands-separator helper (util.lua:1077);
    -- the "size" in its name is about its first caller, not its behaviour.
    return T(_("Page %1 of %2"),
             util.getFormattedSize(footer.pageno), util.getFormattedSize(footer.pages))
end

--- "4' left in chapter", or nil.
-- readerfooter.lua:332-335 exactly: pages left in the chapter, or the whole
-- book's remainder when there is no next chapter, priced at the reader's own
-- measured average. getTimeForPages returns nil unless the statistics plugin is
-- both loaded and enabled (statistics.koplugin/main.lua:3025-3030), and there is
-- no second source for this number, so nil means the clause is dropped.
function Toolbar:_chapterTimeLeft()
    local footer = self:_footer()
    local ui = self.ui
    if not (footer and footer.pageno) then return nil end
    if not (ui.statistics and ui.statistics.getTimeForPages) then return nil end

    local left = (ui.toc and ui.toc:getChapterPagesLeft(footer.pageno, true))
              or (ui.document and ui.document:getTotalPagesLeft(footer.pageno))
    if not left then return nil end

    local duration = ui.statistics:getTimeForPages(left)
    if not duration then return nil end
    return T(_("%1 left in chapter"), duration)
end

--- "74%".
-- ReaderFooter caches this as percent_finished on every page change
-- (readerfooter.lua:2420), and formats it with the user's own digit count
-- (readerfooter.lua:317-322). Both are reused so the band cannot disagree with
-- the stock footer sitting a few pixels below it.
function Toolbar:_percentText()
    local footer = self:_footer()
    if not (footer and footer.percent_finished) then return nil end
    local digits = tonumber(footer.settings and footer.settings.progress_pct_format) or 0
    return ("%." .. digits .. "f%%"):format(footer.percent_finished * 100)
end

--- The whole second line, minus whatever this document cannot supply.
function Toolbar:_statusLine()
    local parts = {}
    for _idx, fn in ipairs({ self._positionText, self._chapterTimeLeft, self._percentText }) do
        local part = fn(self)
        if part then parts[#parts + 1] = part end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, STATUS_SEP)
end

--- Where the knob sits, where the ticks stand, and how many pages there are.
-- The bar's geometry is deliberately on the RAW page scale
-- (ReaderFooter:getBookProgress's own final line, readerfooter.lua:2613) rather
-- than on percent_finished, because the ticks can only be had as page numbers
-- (readertoc.lua:548, the same source readerfooter.lua:2230 feeds its progress
-- bar). Mixing the two scales on a hidden-flow book would put the knob in a
-- different chapter from the tick it is supposed to be sitting on; sharing one
-- scale keeps the picture internally consistent even where it disagrees with the
-- printed percentage by a page or two.
function Toolbar:_progress()
    local footer = self:_footer()
    if not (footer and footer.pageno and footer.pages and footer.pages > 0) then
        return 0, nil, nil
    end

    local pages = footer.pages
    local ticks = {}
    if self.ui.toc then
        for _idx, page in ipairs(self.ui.toc:getTocTicksFlattened() or {}) do
            -- Page 1 is the left end of the bar; a tick there is a mark on the
            -- bar's own cap and reads as a smudge.
            if page > 1 and page <= pages then
                ticks[#ticks + 1] = page / pages
            end
        end
    end
    return footer.pageno / pages, ticks, pages
end

--- One right-hand icon: a fixed-width slot with the glyph centred in it.
-- Fixed slots rather than measured glyph widths, because the five symbols have
-- wildly different advance widths (the ellipsis is a sliver, the toc bars are
-- wide) and spacing them by their own metrics would make the row look ragged.
-- Even *centres* is what reads as "evenly spaced".
function Toolbar:_iconCell(text, face, on_tap, band_h)
    return Theme.Tappable:new{
        on_tap = on_tap,
        CenterContainer:new{
            -- Full band height, so the hit target is the whole strip and not
            -- just the ~46px the glyph happens to ink.
            dimen = Geom:new{ w = Layout.x(REF_ICON_CELL), h = band_h },
            TextWidget:new{ text = text, face = face, padding = 0 },
        },
    }
end

--- Band 1: back/Home on the left, five controls hard right.
function Toolbar:_buildIconBand(band_h)
    -- Back arrow and the word travel together: on the firmware the whole pair
    -- lights up, and splitting them would give the arrow a 46px-wide target.
    local home_inner = HorizontalGroup:new{
        align = "center",
        TextWidget:new{ text = Theme.GLYPH.arrow_left, face = self.face_icon, padding = 0 },
        HorizontalSpan:new{ width = Layout.x(REF_HOME_GAP) },
        TextWidget:new{ text = _("Home"), face = self.face_label, padding = 0 },
    }
    local home = Theme.Tappable:new{
        on_tap = function() self:_goHome() end,
        CenterContainer:new{
            dimen = Geom:new{ w = home_inner:getSize().w, h = band_h },
            home_inner,
        },
    }

    local icons = {
        -- "Aa" is TEXT, not a glyph: Kindle draws the two letterforms in the UI
        -- face, and symbols.ttf has nothing that looks like it anyway.
        { text = "Aa",                     face = self.face_aa,   on_tap = function() self:_showAaMenu() end },
        { text = Theme.GLYPH.toc,          face = self.face_icon, on_tap = function() self:_showPageList() end },
        { text = Theme.GLYPH.note,         face = self.face_icon, on_tap = function() self:_showBookmarks() end },
        { text = Theme.GLYPH.search,       face = self.face_icon, on_tap = function() self:_showSearch() end },
        { text = Theme.GLYPH.ellipsis_v,   face = self.face_icon, on_tap = function() self:_showStockMenu() end },
    }

    local cells = {}
    local cells_w = 0
    for _idx, spec in ipairs(icons) do
        local cell = self:_iconCell(spec.text, spec.face, spec.on_tap, band_h)
        cells[#cells + 1] = cell
        cells_w = cells_w + cell:getSize().w
    end

    -- Everything the two clusters do not use. Clamped at zero rather than
    -- allowed to go negative: HorizontalGroup would happily lay out a negative
    -- span and slide the icons back over "Home".
    local flex = self.screen_w - 2 * self.margin_x - home:getSize().w - cells_w
    if flex < 0 then
        logger.warn("kindleui: toolbar is", -flex, "px too narrow; icons will crowd Home")
        flex = 0
    end

    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = self.margin_x },
        home,
        HorizontalSpan:new{ width = flex },
    }
    for _idx, cell in ipairs(cells) do
        table.insert(row, cell)
    end
    table.insert(row, HorizontalSpan:new{ width = self.margin_x })

    return row
end

--- Footer row 1: skip-back, the chapter block, skip-forward.
-- The two skip cells are the same width, so equal flex spans on either side of
-- the text block centre it in the full band without measuring anything twice.
function Toolbar:_buildChapterRow()
    local cell_w = Layout.x(REF_ICON_CELL)
    local text_w = self.screen_w - 2 * self.margin_x - 2 * cell_w

    local lines = VerticalGroup:new{ align = "center" }
    local chapter = self:_chapterTitle()
    if chapter then
        table.insert(lines, TextWidget:new{
            text = chapter,
            face = self.face_chapter,
            padding = 0,
            -- Truncated, never wrapped: a second line would push the scrubber
            -- row down out of its measured slot.
            max_width = text_w,
        })
    end
    local status = self:_statusLine()
    if status then
        if chapter then
            table.insert(lines, VerticalSpan:new{ width = Layout.y(REF_FOOT_LINE_GAP) })
        end
        table.insert(lines, TextWidget:new{
            text = status,
            face = self.face_status,
            padding = 0,
            max_width = text_w,
        })
    end

    local row_h = math.max(lines:getSize().h, Layout.y(Theme.REF.icon_h))
    -- chev_left/chev_right rather than a filled triangle-and-bar: symbols.ttf as
    -- shipped has no step-backward/step-forward glyph, and kindleui_theme.lua's
    -- table is the cmap-verified set. Inventing a codepoint would render as
    -- tofu on the device, which is worse than a chevron that reads correctly.
    local prev = self:_iconCell(Theme.GLYPH.chev_left, self.face_icon,
        function() self:_gotoChapter("GotoPrevChapter") end, row_h)
    local next_ = self:_iconCell(Theme.GLYPH.chev_right, self.face_icon,
        function() self:_gotoChapter("GotoNextChapter") end, row_h)

    local flex = math.floor((self.screen_w - 2 * self.margin_x
                             - 2 * cell_w - lines:getSize().w) / 2)
    if flex < 0 then flex = 0 end

    return HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = self.margin_x },
        prev,
        HorizontalSpan:new{ width = flex },
        lines,
        HorizontalSpan:new{ width = flex },
        next_,
        HorizontalSpan:new{ width = self.margin_x },
    }, row_h
end

--- Footer row 2: the page-browser glyph, then the scrubber across the rest.
function Toolbar:_buildScrubberRow(row_h)
    local cell_w = Layout.x(REF_ICON_CELL)
    local gap = Layout.x(REF_SCRUB_GAP)
    local grid = self:_iconCell(Theme.GLYPH.grid, self.face_icon,
        function() self:_showPageBrowser() end, row_h)

    local percent, ticks, pages = self:_progress()
    self.total_pages = pages

    local track_w = self.screen_w - 2 * self.margin_x - cell_w - gap
    if track_w < 0 then track_w = 0 end

    self.scrubber = Scrubber:new{
        width = track_w,
        height = row_h,
        percent = percent,
        ticks = ticks,
        on_seek = function(frac) self:_seek(frac) end,
        -- The toolbar is ALSO opened by a northward pull from the BOTTOM edge
        -- (main.lua:228-239), which is to say the opening gesture ends with the
        -- finger somewhere over this very row. Without this the toolbar would
        -- appear and immediately jump the book to wherever the pull stopped.
        -- Same grace window, and the same reasoning, as onSwipeCloseToolbar.
        is_blocked = function() return self._opening end,
    }

    return HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = self.margin_x },
        grid,
        HorizontalSpan:new{ width = gap },
        self.scrubber,
        HorizontalSpan:new{ width = self.margin_x },
    }
end

--- The whole bottom band, exactly footer_h tall.
-- The height has to come out exact: BottomContainer anchors by the size its
-- child REPORTS, and FrameContainer:getSize reports its content rather than its
-- .height (framecontainer.lua:54), so a frame that under-reports would hang off
-- the bottom edge with the page showing above it. Whatever the two rows do not
-- use is therefore handed back as padding rather than left implicit.
function Toolbar:_buildFooterBand()
    -- Thin, not thick: this rule opens the band against the page above it. The
    -- thick one in the title band closes the top panel against the page below,
    -- and using the same weight for both would flatten that distinction.
    local rule_h = Size.line.thin
    local row_gap = Layout.y(REF_FOOT_ROW_GAP)
    local chapter_row, row1_h = self:_buildChapterRow()
    local row2_h = Layout.y(REF_SCRUB_ROW_H)
    local scrubber_row = self:_buildScrubberRow(row2_h)

    local slack = self.footer_h - rule_h - row1_h - row_gap - row2_h
    if slack < 0 then
        logger.warn("kindleui: footer band is", -slack, "px short; padding dropped")
        slack = 0
    end
    local pad_top = math.floor(slack / 2)

    local content = VerticalGroup:new{
        align = "left",
        Theme.rule(rule_h),
        VerticalSpan:new{ width = pad_top },
        CenterContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = row1_h },
            chapter_row,
        },
        VerticalSpan:new{ width = row_gap },
        CenterContainer:new{
            dimen = Geom:new{ w = self.screen_w, h = row2_h },
            scrubber_row,
        },
        VerticalSpan:new{ width = slack - pad_top },
    }

    self.footer_group = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE, -- opaque: the page is still under us
        bordersize = 0, margin = 0, padding = 0,
        content,
    }
    -- Read back rather than assumed to be footer_h: on a panel too short for the
    -- two rows the padding above was clamped away and the band is TALLER than
    -- the firmware's rect. The refresh region has to follow what was actually
    -- laid out, or the overflow is painted and never sent to the EPDC.
    self.footer_band_h = self.footer_group:getSize().h
    return self.footer_group
end

function Toolbar:update()
    if self.band_group then
        -- update() is cheap to re-run, but the glyph caches are not free.
        self.band_group:free()
    end
    if self.footer_group then
        self.footer_group:free()
    end

    -- Each band's separator is carved out of the band, never added to it -- see
    -- the header. hairline() is inset from both margins (Kindle's row-separator
    -- weight); rule() is full bleed, which is how a panel closes against the
    -- page. That contrast is the whole hierarchy signal here.
    local hair_h = Size.line.thin
    local rule_h = Size.line.thick
    local icon_band_h = self.toolbar_h - hair_h
    local title_band_h = self.bookbar_h - rule_h

    -- FrameContainer:getSize reports content + padding and ignores .width/.height
    -- (framecontainer.lua:54), so the bands are sized by giving their contents a
    -- fixed dimen instead. Stacking two frames in a VerticalGroup only lands the
    -- second one correctly if the first reports its true height.
    local icon_band = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE, -- opaque: the page is still under us
        bordersize = 0, margin = 0, padding = 0,
        VerticalGroup:new{
            align = "left",
            CenterContainer:new{
                dimen = Geom:new{ w = self.screen_w, h = icon_band_h },
                self:_buildIconBand(icon_band_h),
            },
            -- The hairline is inset, so it needs the surrounding white of a
            -- full-width container or the page would show through beside it.
            CenterContainer:new{
                dimen = Geom:new{ w = self.screen_w, h = hair_h },
                Theme.hairline(),
            },
        },
    }

    local title = TextWidget:new{
        text = self:_documentTitle(),
        face = self.face_title,
        padding = 0,
        -- Truncated with an ellipsis rather than wrapped: the band is one line
        -- tall and a second line would push the rule off its measured position.
        max_width = Theme.innerW(),
    }
    local title_band = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, margin = 0, padding = 0,
        VerticalGroup:new{
            align = "left",
            LeftContainer:new{
                -- LeftContainer pins x and centres y (leftcontainer.lua:22-23),
                -- which is exactly "left-aligned, vertically centred in the band".
                dimen = Geom:new{ w = self.screen_w, h = title_band_h },
                HorizontalGroup:new{
                    align = "center",
                    HorizontalSpan:new{ width = self.margin_x },
                    title,
                },
            },
            Theme.rule(rule_h),
        },
    }

    self.band_group = VerticalGroup:new{
        align = "left",
        icon_band,
        title_band,
    }
    self[1] = TopContainer:new{
        dimen = Screen:getSize(),
        self.band_group,
    }
    -- BottomContainer is the mirror of the anchor above, and the same one
    -- ConfigDialog uses to hang itself off the bottom edge (configdialog.lua:948).
    -- Both containers are the size of the screen but paint only their child, so
    -- nothing between the two bands is touched.
    --
    -- Two entries in the array part rather than one wrapper, because
    -- WidgetContainer walks `ipairs(self)` for both propagateEvent and free
    -- (widgetcontainer.lua:80-88 and 110-116): the footer's controls get gestures
    -- and its glyph caches get released without either being wired up by hand.
    self[2] = BottomContainer:new{
        dimen = Screen:getSize(),
        self:_buildFooterBand(),
    }

    -- The two TOP bands, and only those. UIManager clips its refresh regions to
    -- this, so the document below is never touched.
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = self.screen_w,
        h = self.toolbar_h + self.bookbar_h,
    }
    -- The footer band, kept separate. See onShow.
    self.footer_dimen = Geom:new{
        x = 0, y = self.screen_h - self.footer_band_h,
        w = self.screen_w,
        h = self.footer_band_h,
    }
end

function Toolbar:paintTo(bb, x, y)
    -- Not InputContainer's version: that one would derive self.dimen from the
    -- full-screen TopContainer and we would repaint the whole display.
    self[1]:paintTo(bb, x, y)
    self[2]:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.footer_dimen.x = x
    self.footer_dimen.y = y + self.screen_h - self.footer_band_h
end

--- The second refresh region, without which the footer band is invisible.
--
-- UIManager:show takes ONE refreshregion (uimanager.lua:156) and main.lua hands
-- it self.dimen, so only the rect it names reaches the EPDC. A band we paint but
-- never refresh is drawn into the framebuffer, is present on the window stack,
-- and answers taps -- while the panel keeps showing the page. That is precisely
-- the bug main.lua:294-315 was written to fix; reintroducing it here in a
-- different shape would be worse than not shipping the band.
--
-- The alternative was to let self.dimen span both, which is to say from y=0 to
-- the bottom edge: the ENTIRE screen. That is rejected on three counts. It would
-- push a full-screen "ui" refresh on every open and every close, which is the
-- e-ink flash this file's header says it exists to avoid, for a widget that inks
-- 26% of the panel. It would make onCloseWidget repaint the whole document to
-- restore two strips. And it would break onTapCloseToolbar, whose whole test is
-- "did this tap land outside me" -- against a full-screen dimen nothing ever
-- does.
--
-- So: a second, explicitly named region. UIManager:show calls setDirty before it
-- dispatches this event (uimanager.lua:184-186), and setDirty with a nil widget
-- only appends to the refresh queue (uimanager.lua:667), so both regions are
-- queued before _repaint drains them and both are refreshed in the same cycle.
-- Cost: one extra entry in that queue. The middle of the screen is never
-- refreshed and never painted, which is exactly what the firmware does.
function Toolbar:onShow()
    UIManager:setDirty(nil, "ui", self.footer_dimen)
end

function Toolbar:onCloseWidget()
    -- Same reasoning as ConfigDialog:onCloseWidget (configdialog.lua:955): the
    -- widgets underneath have to be redrawn where we were -- and, symmetrically
    -- with onShow, in BOTH places we were, or the footer band stays burned into
    -- the panel over a page that no longer has one.
    UIManager:setDirty(nil, "ui", self.dimen)
    UIManager:setDirty(nil, "ui", self.footer_dimen)
end

function Toolbar:onTapCloseToolbar(_arg, ges_ev)
    -- Only the strip BETWEEN the bands is "outside". The old test was
    -- "y >= self.dimen.h", which with a band at the bottom would have closed the
    -- toolbar on every tap that missed a footer control -- including the release
    -- of a scrubber drag.
    local y = ges_ev.pos.y
    if y >= self.dimen.y + self.dimen.h and y < self.footer_dimen.y then
        UIManager:close(self)
    end
    -- Taps inside a band that reached us missed every control; swallow them so
    -- they do not fall through and turn the page.
    return true
end

function Toolbar:onSwipeCloseToolbar(_arg, ges_ev)
    -- North only: the toolbar came down from the top edge, so it goes back up
    -- the way it arrived. Any other direction falls through untouched.
    if ges_ev.direction ~= "north" then return end
    -- ...but the toolbar is ALSO opened by a northward pull from the bottom
    -- edge, and that gesture does not end when we appear. The touch zone that
    -- opened us consumed its own event, yet a pan emits a sample per movement
    -- and the detector still posts a final `swipe` when the finger lifts -- by
    -- which time we are the topmost widget and would swallow it as a close.
    -- The result is a toolbar that flashes open and shuts in one motion.
    -- Ignoring close gestures for the tail of the opening one is the cheapest
    -- fix that does not require guessing where the gesture started.
    if self._opening then return true end
    UIManager:close(self)
    return true
end

function Toolbar:onClose()
    UIManager:close(self)
    return true
end

return Toolbar
