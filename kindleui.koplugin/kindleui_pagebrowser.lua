--[[--
Kindle's Page Flip: a full-screen grid of page thumbnails.

This is the one panel in the plugin that DOES claim the whole screen. Kindle's
page flip replaces the page entirely -- there is no reader chrome left to keep
lit -- so unlike kindleui_toolbar.lua and kindleui_pagelist.lua this widget sets
`covers_fullscreen` and paints an opaque white frame over the display.

    ┌──────────────────────────────────────────┐
    │                                        ✕ │  no title bar; just the close
    │   ┌────┐    ┌────┐    ┌────┐             │
    │ ‹ ▐41▌ │    ▐42▌ │    ▐43▌ │           › │  badge straddles the top edge
    │   └────┘    └────┘    └────┘             │
    │   ┌────┐    ┌━━━━┓    ┌────┐             │
    │   ▐44▌ │    ▐45▌ ┃    ▐46▌ │             │  thick border = current page
    │   └────┘    └━━━━┛    └────┘             │
    │   ┌────┐    ┌────┐    ┌────┐             │
    │   ▐47▌ │    ▐48▌ │    ▐49▌ │             │
    │   └────┘    └────┘    └────┘             │
    │ ──────────────────────────────────────── │  thin, full bleed
    │ |◀            Chapter 3              ▶|  │
    │   ━━━━━━━━━━━━━━(○)---------------       │
    └──────────────────────────────────────────┘

WHY 3x3 RATHER THAN KOReader's 3x2

PageBrowserWidget's grid is only half the screen: the bottom half is a BookMapRow
carrying a chapter name in a box under every span it can fit
(pagebrowserwidget.lua:700-717 builds the view finder over it). On a book with
hundreds of chapters those boxes are narrower than the words inside them, so they
clip and overlap, which is the bug this file exists to fix. Deleting that row
frees the height for a third row of thumbnails, and everything the row was trying
to say is said instead by one centred chapter name and one progress bar.

WHY THE GRID IS HAND-DRAWN

Same answer as kindleui_pagelist.lua's chapter list. The badge is the reason: it
is a black rectangle straddling the card's top border, i.e. it deliberately
paints OUTSIDE the box that owns it. Every container KOReader ships clips its
child to its own rect or reflows around it, so an off-box overlay would mean
overriding paintTo anyway -- at which point the container is only costing us
indirection. A card is nine paintRect calls and one blit.

WHY THE THUMBNAILS ARE NOT GENERATED HERE

They are already solved. ReaderThumbnail renders each page in a SUBPROCESS and
ships the scaled BlitBuffer back over a pipe (readerthumbnail.lua:340-369), keeps
an LRU tile cache sized to about five screenfuls (readerthumbnail.lua:130-147),
and serialises the requests so only one subprocess is alive at a time
(readerthumbnail.lua:287-338). Reimplementing any of that would be strictly
worse. We call exactly one entry point,
`ReaderThumbnail:getPageThumbnail(page, w, h, batch_id, cb)`
(readerthumbnail.lua:257), and one cancel,
`ReaderThumbnail:cancelPageThumbnailRequests(batch_id)`
(readerthumbnail.lua:245). The module is registered as a ReaderUI child at
readerui.lua:421, so it is reachable as `self.ui.thumbnail`.

The callback is `cb(tile, batch_id, async_response)`. `async_response` is false
when the tile was already cached and the callback ran inline, true when it came
back from a subprocess. That flag is the whole refresh policy: an inline tile
needs no refresh of its own (the caller's one refresh covers the lot), an async
tile repaints its own card and nothing else. Nine cards must never mean nine
full-screen e-ink updates.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Layout = require("kindleui_geom") -- this plugin's proportions, not ui/geometry
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local Theme = require("kindleui_theme")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

-- The grid. Fixed, not a setting: the card size, the badge size and the bottom
-- band were all measured against this shape, and KOReader's own adjustable
-- rows/cols is what let its layout collapse in the first place.
local COLS, ROWS = 3, 3
local PER_SCREEN = COLS * ROWS

-- Kindle reference pixels, against kindleui_geom.lua's 1236x1648 panel.
local REF_TOP_H        = 132 -- the close-glyph row; nothing else lives up there
local REF_CLOSE_H      = 52
local REF_CLOSE_CELL   = 124 -- tap target around the ✕, wider than the glyph
local REF_GRID_GAP     = 26  -- between cards, both axes
local REF_SIDE_MIN     = 104 -- narrowest the chevron columns are allowed to get
local REF_SIDE_CHEV_H  = 56
local REF_CARD_BORDER  = 3
local REF_CARD_BORDER_CUR = 9 -- "noticeably thicker", never a fill
local REF_BADGE_H      = 46
local REF_BADGE_PAD    = 15  -- left/right of the page number inside the badge
local REF_BADGE_TEXT_H = 30

-- The bottom band. Its height is fixed and the grid takes what is left, rather
-- than the other way round: a band that shrinks would clip the progress bar,
-- while a grid that shrinks only makes the thumbnails smaller.
local REF_BAND_TOP_GAP = 30
local REF_LABEL_H      = 44
local REF_LABEL_GAP    = 28
local REF_BAR_ROW_H    = 96
local REF_BAND_BOT_GAP = 36
local REF_CAP_W        = 96  -- one end-jump cell
local REF_CAP_TRI_W    = 30
local REF_CAP_TRI_H    = 38
local REF_CAP_BAR_W    = 7
local REF_CAP_GAP      = 11  -- between the bar and the triangle
local REF_TRACK_THICK  = 12  -- the read part, solid
local REF_TRACK_THIN   = 3   -- the outline around the unread part
local REF_KNOB_D       = 56
local REF_KNOB_RING    = 6
local REF_TICK_H       = 14
local REF_TICK_W       = 3
local REF_TICK_GAP     = 8

-- Monotonic, so two grids built inside the same second cannot share a batch id.
-- PageBrowserWidget builds its own from os.time() (pagebrowserwidget.lua:444),
-- which is fine for a widget that is only ever opened by hand but not for one
-- that rebuilds its batch on every swipe.
local batch_seq = 0

--------------------------------------------------------------------------------
-- Primitive drawing
--
-- paintRect(x, y, w, h, value) and paintCircle(cx, cy, r, value, w) are the only
-- two blitbuffer primitives used here, the same pair kindleui_pagelist.lua:106
-- and kindleui_controlcentre.lua:173 cite and paint with. Deliberately not
-- paintBorder: kindleui_pagelist.lua already builds an outline out of four
-- paintRects and two files should not draw the same shape two ways. Nothing
-- below reaches outside the rect it was handed except Card's badge, which says
-- so.
--------------------------------------------------------------------------------

--- A rectangular outline `t` pixels thick, drawn inside x/y/w/h.
local function paintOutline(bb, x, y, w, h, t)
    if w <= 0 or h <= 0 then return end
    if t * 2 > h then t = math.max(1, math.floor(h / 2)) end
    bb:paintRect(x, y, w, t, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y + h - t, w, t, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y, t, h, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + w - t, y, t, h, Blitbuffer.COLOR_BLACK)
end

--- A solid triangle pointing left or right, vertically centred on `cy`.
-- Hand-drawn for the reason kindleui_pagelist.lua:112-115 gives for its vertical
-- twin: symbols.ttf carries chevrons but no filled caret at a codepoint verified
-- against the device cmap, and kindleui_theme.lua forbids inventing one. A
-- column-at-a-time fill is also exact at any size, which a glyph is not.
local function paintTriangleH(bb, left, cy, w, h, point_left)
    for i = 0, w - 1 do
        local frac = point_left and (i + 1) / w or (w - i) / w
        local rh = math.max(1, math.floor(h * frac))
        bb:paintRect(left + i, cy - math.floor(rh / 2), 1, rh, Blitbuffer.COLOR_BLACK)
    end
end

--------------------------------------------------------------------------------
-- Card: one page of the grid.
--
-- Paints, in order: a white wipe, the thumbnail, the border, the badge. The
-- order is the whole trick. The wipe exists because a card is repainted ALONE
-- when its thumbnail lands, so the placeholder underneath has to go. The border
-- goes over the thumbnail so that the current page's thicker border eats into
-- the image instead of growing the card -- every card must ask for the same
-- thumbnail size or the current page would get its own entry in a cache keyed by
-- "w%d_h%d" (readerthumbnail.lua:259) and be rendered twice.
--
-- The badge goes last and deliberately paints ABOVE this widget's own box: it
-- straddles the card's top border, which is Kindle's signature detail. See
-- refreshRect() for the consequence.
--------------------------------------------------------------------------------
local Card = Widget:extend{
    page = nil,
    width = nil,
    height = nil,
    border = nil,
    badge_h = nil,
    badge_pad = nil,
    badge_overhang = nil, -- how far the badge sticks up past the card's top edge
    face_badge = nil,
    image = nil,          -- ImageWidget, once a thumbnail has arrived
    painted = false,
}

function Card:init()
    self.badge = TextWidget:new{
        text = tostring(self.page),
        face = self.face_badge,
        -- White on the black badge, the same trick kindleui_controlcentre.lua:140
        -- plays for a glyph sitting on a filled disc.
        fgcolor = Blitbuffer.COLOR_WHITE,
        padding = 0,
    }
    local text_w = self.badge:getSize().w
    self.badge_w = math.min(self.width, text_w + 2 * self.badge_pad)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function Card:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

--- Hand a generated tile over. Never called with a nil tile; the grid filters.
function Card:setTile(tile)
    if self.image then self.image:free() end
    self.image = ImageWidget:new{
        image = tile.bb,
        -- The tile belongs to ReaderThumbnail's cache, which frees it on
        -- eviction; freeing it here too would be a double free.
        image_disposable = false,
        -- Upstream's wording (pagebrowserwidget.lua:838): false means "let night
        -- mode invert this", which is what we want for a picture of a page.
        original_in_nightmode = false,
    }
end

--- The rect an e-ink refresh has to cover to show this card, badge included.
-- self.dimen cannot be used directly: the badge is painted above the card's top
-- edge, so a refresh clipped to dimen would leave half of it stale.
function Card:refreshRect()
    if not self.painted then return nil end
    return Geom:new{
        x = self.dimen.x,
        y = self.dimen.y - self.badge_overhang,
        w = self.dimen.w,
        h = self.dimen.h + self.badge_overhang,
    }
end

function Card:paintTo(bb, x, y)
    -- Refreshed on every paint, not just at init: the grid decides where this
    -- lands, and a stale rect would refresh where the card used to be.
    self.dimen.x, self.dimen.y = x, y
    self.painted = true

    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)

    if self.image then
        local size = self.image:getSize()
        self.image:paintTo(bb,
            x + math.floor((self.width - size.w) / 2),
            y + math.floor((self.height - size.h) / 2))
    end

    paintOutline(bb, x, y, self.width, self.height, self.border)

    local by = y - self.badge_overhang
    bb:paintRect(x, by, self.badge_w, self.badge_h, Blitbuffer.COLOR_BLACK)
    local bs = self.badge:getSize()
    self.badge:paintTo(bb,
        x + math.floor((self.badge_w - bs.w) / 2),
        by + math.floor((self.badge_h - bs.h) / 2))
end

function Card:free()
    if self.badge then self.badge:free() end
    if self.image then
        self.image:free()
        self.image = nil
    end
end

--------------------------------------------------------------------------------
-- Grid: the 3x3 body.
--
-- Paged on a fixed lattice anchored at page 1, so screenful N always holds the
-- same nine pages however you arrived at it. That matters more here than in a
-- list: the reader is memorising positions ("the map was two screens back"), and
-- a grid whose contents depend on the route taken there breaks that.
--
-- The paging scheme itself -- swipe AND pan both registered, the drag paid out
-- in pan_step instalments off a signed anchor -- is kindleui_pagelist.lua's,
-- copied so the two screens feel the same under the finger. The reasoning is at
-- kindleui_pagelist.lua:222-236 and :425-431 and is not repeated here.
--------------------------------------------------------------------------------
local Grid = InputContainer:extend{
    ui = nil,
    width = nil,
    height = nil,
    card_w = nil,
    card_h = nil,
    hgap = nil,
    vgap = nil,
    thumb_w = nil,      -- what we ask ReaderThumbnail for; card interior
    thumb_h = nil,
    border = nil,
    border_cur = nil,
    badge_h = nil,
    badge_pad = nil,
    badge_overhang = nil,
    face_badge = nil,
    nb_pages = nil,
    cur_page = nil,     -- the page actually being read, for the thick border
    first_page = nil,
    on_select = nil,        -- function(page)
    on_page_change = nil,   -- function(first_page)
}

function Grid:init()
    self.total_screens = math.max(1, math.ceil(self.nb_pages / PER_SCREEN))
    self.last_first_page = (self.total_screens - 1) * PER_SCREEN + 1

    -- Pixels of drag that buy one screenful. Half the grid width, for the reason
    -- kindleui_pagelist.lua:208-213 gives for half the list height, and floored
    -- at 1px because onPanGrid pays the drag out in instalments and a zero step
    -- would loop forever.
    self.pan_step = math.max(1, math.floor(self.width / 2))

    if Device:isTouchDevice() then
        local in_grid = function() return self.dimen end
        self.ges_events = {
            TapGrid = { GestureRange:new{ ges = "tap", range = in_grid } },
            SwipeGrid = { GestureRange:new{ ges = "swipe", range = in_grid } },
            PanGrid = { GestureRange:new{ ges = "pan", range = in_grid } },
            PanGridRelease = { GestureRange:new{ ges = "pan_release", range = in_grid } },
        }
    end

    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.cards = {}
    self:_build()
end

function Grid:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

--- Snap a page number onto the screenful lattice, clamped to the book.
function Grid:_snap(page)
    if page < 1 then page = 1 end
    if page > self.last_first_page then page = self.last_first_page end
    return page - ((page - 1) % PER_SCREEN)
end

function Grid:_build()
    self:free()
    self.cards = {}
    for idx = 1, PER_SCREEN do
        local page = self.first_page + idx - 1
        -- The tail of the last screenful is left empty rather than padded: a
        -- bordered card holding nothing would read as a page that failed to
        -- render.
        if page <= self.nb_pages then
            self.cards[idx] = Card:new{
                page = page,
                width = self.card_w,
                height = self.card_h,
                border = page == self.cur_page and self.border_cur or self.border,
                badge_h = self.badge_h,
                badge_pad = self.badge_pad,
                badge_overhang = self.badge_overhang,
                face_badge = self.face_badge,
            }
        end
    end
    self:_requestThumbnails()
end

--- Ask ReaderThumbnail for this screenful, and only this screenful.
--
-- No preloading of the neighbouring screens. PageBrowserWidget does that
-- (pagebrowserwidget.lua:939-970) behind an opt-in setting, and it is a genuine
-- win when the reader steps through row by row; here a screenful is nine pages
-- rather than three, so preloading both neighbours would queue eighteen more
-- subprocess renders behind the nine that are actually on screen and make the
-- visible grid fill in slower. Speed of what you are looking at wins.
function Grid:_requestThumbnails()
    local thumb = self.ui and self.ui.thumbnail
    -- ReaderThumbnail:init returns before creating `thumbnails_requests` on a
    -- device with neither touch nor D-pad action keys (readerthumbnail.lua:24-39),
    -- and getPageThumbnail would then index a nil table. The field is the honest
    -- test for "this service was actually set up".
    if not (thumb and thumb.thumbnails_requests and thumb.getPageThumbnail) then
        logger.warn("kindleui: no thumbnail service; page browser will show empty cards")
        return
    end

    if self.batch_id then
        thumb:cancelPageThumbnailRequests(self.batch_id)
    end
    batch_seq = batch_seq + 1
    self.batch_id = "kindleui_pagebrowser_" .. batch_seq
    local batch = self.batch_id

    for idx = 1, PER_SCREEN do
        local card = self.cards[idx]
        if card then
            thumb:getPageThumbnail(card.page, self.thumb_w, self.thumb_h, batch,
                function(tile, batch_id, async_response)
                    -- A response from the screenful we have already swiped away
                    -- from. cancelPageThumbnailRequests drops the queue but a
                    -- render already in flight still reports back.
                    if batch_id ~= self.batch_id then return end
                    -- Failure notification (readerthumbnail.lua:324, :392); the
                    -- card keeps its placeholder rather than showing an error.
                    if not (tile and tile.bb) then return end
                    local live = self.cards[idx]
                    if not live then return end
                    live:setTile(tile)
                    -- async_response is false when the tile came straight out of
                    -- the cache and this ran inline, i.e. before the caller's own
                    -- refresh. Refreshing here would be a second e-ink update of
                    -- a region that is about to be updated anyway.
                    if async_response then self:_repaintCard(idx) end
                end)
        end
    end
end

--- Put one card on screen, without touching the other eight.
-- Same two-step as kindleui_toolbar.lua:264-268: widgetRepaint paints into the
-- framebuffer (uimanager.lua:1398 is a bare `widget:paintTo(Screen.bb, x, y)`),
-- then setDirty with a nil widget enqueues the e-ink update for that rect alone
-- and repaints nothing else. Nine thumbnails arriving must cost nine small
-- updates, not nine full-screen ones.
function Grid:_repaintCard(idx)
    local card = self.cards[idx]
    if not card then return end
    local rect = card:refreshRect()
    if not rect then return end -- never painted, so there is nothing to update
    UIManager:widgetRepaint(card, card.dimen.x, card.dimen.y)
    UIManager:setDirty(nil, "ui", rect)
end

--- Move to the screenful starting at `page`, snapped and clamped.
-- Returns true only when it really moved, because onPanGrid must not bank drag
-- distance against an end stop (kindleui_pagelist.lua:290-293).
function Grid:_setPage(page)
    local first = self:_snap(page)
    if first == self.first_page then return false end
    self.first_page = first
    self:_build()
    -- The refresh is the parent's: a new screenful changes the chapter label and
    -- the knob position too, and those want to arrive in the same update.
    if self.on_page_change then self.on_page_change(first) end
    return true
end

function Grid:_cardOrigin(idx)
    local row = math.floor((idx - 1) / COLS)
    local col = (idx - 1) % COLS
    return col * (self.card_w + self.hgap), row * (self.card_h + self.vgap)
end

function Grid:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    for idx = 1, PER_SCREEN do
        local card = self.cards[idx]
        if card then
            local ox, oy = self:_cardOrigin(idx)
            card:paintTo(bb, x + ox, y + oy)
        end
    end
end

function Grid:onTapGrid(_arg, ges_ev)
    local lx = ges_ev.pos.x - self.dimen.x
    local ly = ges_ev.pos.y - self.dimen.y
    local col = math.floor(lx / (self.card_w + self.hgap))
    local row = math.floor(ly / (self.card_h + self.vgap))
    if col >= 0 and col < COLS and row >= 0 and row < ROWS then
        -- Reject the gaps explicitly. Without this a tap in the gutter would be
        -- attributed to the card on its left, which is a jump to a page the
        -- reader did not point at.
        local inside = (lx - col * (self.card_w + self.hgap)) < self.card_w
                   and (ly - row * (self.card_h + self.vgap)) < self.card_h
        local card = inside and self.cards[row * COLS + col + 1]
        if card and self.on_select then
            self.on_select(card.page)
        end
    end
    -- Swallowed either way: inside the grid rect a tap is never anything else.
    return true
end

--- Which way a gesture pages.
-- Horizontal wins on a diagonal because the on-screen affordance is horizontal:
-- the ‹ and › chevrons sit either side of the grid. Vertical is accepted too,
-- because kindleui_pagelist.lua's list pages north/south and a reader arriving
-- from Go To will try that first. Either way the content travels with the
-- finger: dragging left or up brings later pages in.
local function pagingDirection(dir)
    if not dir then return 0 end
    if dir:find("west", 1, true) then return 1 end
    if dir:find("east", 1, true) then return -1 end
    if dir:sub(1, 5) == "north" then return 1 end
    if dir:sub(1, 5) == "south" then return -1 end
    return 0
end

function Grid:onSwipeGrid(_arg, ges_ev)
    local step = pagingDirection(ges_ev.direction)
    if step ~= 0 then
        self:_setPage(self.first_page + step * PER_SCREEN)
    end
    self._pan_from_x, self._pan_from_y = nil, nil
    return true
end

--- The slow half of the same gesture.
-- gesturedetector.lua:988-1004 re-sends `relative` measured from the CONTACT
-- point on every sample, so one anchor is all the state a drag needs and a
-- sample lost to a repaint catches up on the next one.
function Grid:onPanGrid(_arg, ges_ev)
    local start = ges_ev.start_pos
    local rel = ges_ev.relative
    if not (start and rel) then return true end

    if start.x ~= self._pan_from_x or start.y ~= self._pan_from_y then
        -- A fresh drag, identified by its contact point because a pan carries no
        -- id. onPanGridRelease clears it too, but only fires when the finger
        -- happens to lift inside the grid, so this is the reliable one.
        self._pan_from_x, self._pan_from_y = start.x, start.y
        self._pan_anchor = 0
    end

    -- One axis, the dominant one, for the same reason pagingDirection prefers
    -- horizontal: mixing both would let a lazy diagonal count twice.
    local dx, dy = rel.x or 0, rel.y or 0
    local travelled = math.abs(dx) >= math.abs(dy) and dx or dy

    -- Distance not yet paid out. Signed, so reversing mid-drag pages back rather
    -- than having to undo the whole drag first.
    local moved = travelled - self._pan_anchor
    while moved <= -self.pan_step do
        if not self:_setPage(self.first_page + PER_SCREEN) then break end
        self._pan_anchor = self._pan_anchor - self.pan_step
        moved = moved + self.pan_step
    end
    while moved >= self.pan_step do
        if not self:_setPage(self.first_page - PER_SCREEN) then break end
        self._pan_anchor = self._pan_anchor + self.pan_step
        moved = moved - self.pan_step
    end
    return true
end

function Grid:onPanGridRelease()
    self._pan_from_x, self._pan_from_y = nil, nil
    return true
end

function Grid:onNextGridPage()
    self:_setPage(self.first_page + PER_SCREEN)
    return true
end

function Grid:onPrevGridPage()
    self:_setPage(self.first_page - PER_SCREEN)
    return true
end

--- Drop every queued render. Called when the browser closes.
function Grid:cancelRequests()
    local thumb = self.ui and self.ui.thumbnail
    if thumb and self.batch_id and thumb.cancelPageThumbnailRequests then
        thumb:cancelPageThumbnailRequests(self.batch_id)
        self.batch_id = nil
    end
end

function Grid:free()
    if not self.cards then return end
    for idx = 1, PER_SCREEN do
        local card = self.cards[idx]
        if card then card:free() end
    end
end

--------------------------------------------------------------------------------
-- EndJump: the |◀ and ▶| controls at the ends of the bottom band.
--
-- A painted vertical bar next to a painted solid triangle. Neither is a glyph:
-- symbols.ttf as shipped on the device carries chev_left / chev_right
-- (kindleui_theme.lua:59-60) but nothing cmap-verified that means "to the start"
-- -- no double arrow, no bar-and-caret -- and inventing a codepoint is what
-- kindleui_theme.lua:16-23 exists to forbid. Using a bare chevron instead was
-- rejected for a different reason: the same chevron already sits at the screen
-- edge meaning "one screenful", and two identical marks doing different things
-- is worse than a shape drawn by hand.
--------------------------------------------------------------------------------
local EndJump = Widget:extend{
    width = nil,
    height = nil,
    tri_w = nil,
    tri_h = nil,
    bar_w = nil,
    gap = nil,
    at_start = true, -- |◀ ; false gives ▶|
}

function EndJump:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function EndJump:paintTo(bb, x, y)
    local unit_w = self.bar_w + self.gap + self.tri_w
    local left = x + math.floor((self.width - unit_w) / 2)
    local cy = y + math.floor(self.height / 2)
    local bar_top = cy - math.floor(self.tri_h / 2)

    if self.at_start then
        bb:paintRect(left, bar_top, self.bar_w, self.tri_h, Blitbuffer.COLOR_BLACK)
        paintTriangleH(bb, left + self.bar_w + self.gap, cy, self.tri_w, self.tri_h, true)
    else
        paintTriangleH(bb, left, cy, self.tri_w, self.tri_h, false)
        bb:paintRect(left + self.tri_w + self.gap, bar_top,
            self.bar_w, self.tri_h, Blitbuffer.COLOR_BLACK)
    end
end

--------------------------------------------------------------------------------
-- ProgressBar: the chunky bar under the chapter name.
--
-- Hand-painted for the reason kindleui_toolbar.lua:101-104 gives for its
-- scrubber: ProgressWidget draws a bordered filled bar (progresswidget.lua:112
-- onwards) and has no concept of a knob.
--
-- ONE knob here, not the toolbar's two. The toolbar needs a second, hollow knob
-- because a drag there proposes a jump that has not happened yet; here the knob
-- IS the grid's position and there is nothing else it could mean, so the single
-- large hollow knob the design asks for follows the finger while dragging and
-- sits on the grid's own position otherwise.
--
-- The grid still only moves on release, though. A pan sample commits nine
-- thumbnail renders and a full-screen e-ink update; paying that per sample would
-- make the bar unusable, so the drag repaints this one row "fast" and hands the
-- jump over once, on lift. That is the same split kindleui_toolbar.lua:264-278
-- settled on.
--------------------------------------------------------------------------------
local ProgressBar = InputContainer:extend{
    width = nil,
    height = nil,
    percent = 0,      -- 0..1, where the grid is
    ticks = nil,      -- array of 0..1 fractions, one per chapter start
    on_seek = nil,    -- on_seek(fraction), fired once, on commit
    drag_percent = nil,
}

function ProgressBar:init()
    self.track_thick = math.max(Size.line.thick, Layout.y(REF_TRACK_THICK))
    self.track_thin = math.max(Size.line.medium, Layout.y(REF_TRACK_THIN))
    self.knob_r = math.floor(Layout.x(REF_KNOB_D) / 2)
    self.knob_ring = math.max(Size.line.thick, Layout.x(REF_KNOB_RING))
    self.tick_h = Layout.y(REF_TICK_H)
    self.tick_w = math.max(Size.line.medium, Layout.x(REF_TICK_W))
    self.tick_gap = Layout.y(REF_TICK_GAP)

    if not Device:isTouchDevice() then return end

    -- gesturerange.lua:29 documents the closure form: a widget's dimen only
    -- exists once it has been painted. Widening to the whole screen while a drag
    -- is live is deliberate -- a finger that drifts off this row mid-drag must
    -- still be able to release, or the knob is stranded and the jump never
    -- commits.
    local range = function()
        if self.drag_percent then
            return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
        end
        return self.dimen
    end

    self.ges_events = {
        TapBar = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        PanBar = {
            GestureRange:new{
                ges = "pan",
                range = range,
                -- The throttle FrontLightWidget uses (frontlightwidget.lua:34);
                -- an e-ink panel cannot keep up with raw pan event rates.
                rate = Screen.low_pan_rate and 3 or 30,
            },
        },
        -- Both endings have to be registered. Contact:panState splits the lift
        -- two ways (gesturedetector.lua:794-799): a drag brisk enough to pass
        -- isSwipe becomes a `swipe`, a slower one becomes `pan_release`.
        -- Registering only one leaves half of all real drags uncommitted.
        PanReleaseBar = { GestureRange:new{ ges = "pan_release", range = range } },
        SwipeBar = { GestureRange:new{ ges = "swipe", range = range } },
    }
end

function ProgressBar:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function ProgressBar:paintTo(bb, x, y)
    -- Recorded on every paint: the knob moves and refresh() repaints only this
    -- widget, so a stale rect would route drags to the wrong place.
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    -- Wipe, or the previous frame's knob is left stranded on the track.
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)

    local content_h = self.tick_h + self.tick_gap + 2 * self.knob_r
    local top = y + math.max(0, math.floor((self.height - content_h) / 2))
    local cy = top + self.tick_h + self.tick_gap + self.knob_r

    -- Inset by the knob radius at both ends, so a knob at 0% or 100% still sits
    -- inside the row instead of half-way into the margin.
    local t0 = x + self.knob_r
    local t1 = x + self.width - self.knob_r
    local travel = math.max(0, t1 - t0)
    self._t0, self._travel = t0, travel

    -- Ticks only while they can still be read as separate marks.
    --
    -- A 21,000-page book with several hundred chapters puts a boundary every
    -- pixel or two and the row stops being a set of marks and becomes one solid
    -- black bar -- which is exactly what it looked like on device. A bar that
    -- dense carries no information: it says "there are chapters", which the
    -- reader already knew. The threshold is the tick's own width plus a gap of
    -- the same size, i.e. "would two neighbours touch", answered in the units of
    -- the thing being drawn rather than a number picked to look right. Same
    -- guard, same reasoning as kindleui_toolbar.lua:200-217.
    local ticks_readable = true
    if self.ticks and #self.ticks > 1 and (travel / #self.ticks) < self.tick_w * 2 then
        ticks_readable = false
    end
    if self.ticks and ticks_readable then
        for _idx, frac in ipairs(self.ticks) do
            local tx = t0 + math.floor(travel * frac + 0.5)
            bb:paintRect(tx - math.floor(self.tick_w / 2), top,
                self.tick_w, self.tick_h, Blitbuffer.COLOR_BLACK)
        end
    end

    local shown = self.drag_percent or self.percent
    local cx = t0 + math.floor(travel * shown + 0.5)
    local track_top = cy - math.floor(self.track_thick / 2)

    -- Read: solid. Unread: the same rectangle, outlined. A thin filled line
    -- would read as a lighter bar; an outline reads as an empty one, which is
    -- what it is.
    if cx > t0 then
        bb:paintRect(t0, track_top, cx - t0, self.track_thick, Blitbuffer.COLOR_BLACK)
    end
    if t1 > cx then
        paintOutline(bb, cx, track_top, t1 - cx, self.track_thick, self.track_thin)
    end

    -- paintCircle's `w` is the ring width and defaults to r, i.e. a solid disc.
    -- White fill first, or the track shows through the ring.
    bb:paintCircle(cx, cy, self.knob_r, Blitbuffer.COLOR_WHITE, self.knob_r)
    bb:paintCircle(cx, cy, self.knob_r, Blitbuffer.COLOR_BLACK, self.knob_ring)
end

function ProgressBar:_fracFromX(pos_x)
    if not self._t0 or self._travel <= 0 then return self.percent end
    local frac = (pos_x - self._t0) / self._travel
    if frac < 0 then return 0 end
    if frac > 1 then return 1 end
    return frac
end

--- Repaints this row and nothing else, for the live drag.
-- Paint first so the dimen is current, then setDirty with a nil widget so
-- nothing underneath is redrawn. "fast" (A2) rather than "ui", because a full
-- update per pan sample would make dragging unusable on e-ink.
function ProgressBar:refresh()
    if not self.dimen then return end
    UIManager:widgetRepaint(self, self.dimen.x, self.dimen.y)
    UIManager:setDirty(nil, "fast", self.dimen)
end

function ProgressBar:_commit(frac)
    self.drag_percent = nil
    -- No repaint here: on_seek rebuilds the grid and the chapter label, and asks
    -- for one refresh covering the lot.
    if self.on_seek then self.on_seek(frac) end
    return true
end

function ProgressBar:onTapBar(_arg, ges_ev)
    if not self.dimen then return false end
    return self:_commit(self:_fracFromX(ges_ev.pos.x))
end

function ProgressBar:onPanBar(_arg, ges_ev)
    if not self.dimen then return false end
    self.drag_percent = self:_fracFromX(ges_ev.pos.x)
    self:refresh()
    return true
end

function ProgressBar:onPanReleaseBar(_arg, ges_ev)
    -- Not dragging means this release belongs to somebody else -- most likely
    -- the gesture that opened this screen, whose tail lands on top of us.
    if not self.drag_percent then return false end
    return self:_commit(self:_fracFromX(ges_ev.pos.x))
end

function ProgressBar:onSwipeBar()
    if not self.drag_percent then return false end
    -- Deliberately NOT ges_ev.pos: alone among the gestures, a swipe reports the
    -- CONTACT point rather than the lift (gesturedetector.lua:942-946). The last
    -- pan sample is the only truthful "where the finger ended up" we have.
    return self:_commit(self.drag_percent)
end

--------------------------------------------------------------------------------
-- PageBrowser: the screen.
--------------------------------------------------------------------------------
local PageBrowser = InputContainer:extend{
    name = "kindleui_page_browser",
    modal = true,
    -- Unlike every other panel in this plugin: Kindle's page flip replaces the
    -- page rather than hanging off the reader's chrome, so there is nothing
    -- underneath worth keeping lit.
    covers_fullscreen = true,
    ui = nil,
}

function PageBrowser:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.margin = Theme.margin()
    self.inner_w = Theme.innerW()

    self.face_close = Theme.face(REF_CLOSE_H)
    self.face_side_chev = Theme.face(REF_SIDE_CHEV_H)
    self.face_badge = Theme.faceBold(REF_BADGE_TEXT_H)
    self.face_label = Theme.face(REF_LABEL_H)

    self:_measure()
    self:_readBook()

    if Device:hasKeys() then
        -- Without this a non-touch device could open the browser and never close
        -- it; ConfigDialog wires the same group at configdialog.lua:897.
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextGridPage = { { Device.input.group.PgFwd } },
            PrevGridPage = { { Device.input.group.PgBack } },
        }
    end

    self:update()
end

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

--- Everything the layout needs, derived once.
--
-- The bottom band's height is fixed and the grid takes the remainder, because a
-- band that shrinks clips the progress bar while a grid that shrinks only makes
-- the thumbnails smaller. Card WIDTH is then derived from card height and the
-- screen's own aspect ratio rather than from the width available: a CRE page
-- thumbnail has exactly the screen's proportions (readerthumbnail.lua:440-441),
-- so a card shaped that way holds the image with no letterboxing. Whatever width
-- is left over becomes the two chevron columns, which is where the design wants
-- it anyway.
function PageBrowser:_measure()
    self.top_h = Layout.y(REF_TOP_H)
    self.hgap = Layout.x(REF_GRID_GAP)
    self.vgap = Layout.y(REF_GRID_GAP)

    self.rule_h = Size.line.thin
    self.label_h = Layout.y(REF_LABEL_H)
    self.bar_row_h = Layout.y(REF_BAR_ROW_H)
    self.band_top_gap = Layout.y(REF_BAND_TOP_GAP)
    self.label_gap = Layout.y(REF_LABEL_GAP)
    self.band_bot_gap = Layout.y(REF_BAND_BOT_GAP)
    self.band_h = self.rule_h + self.band_top_gap + self.label_h
                + self.label_gap + self.bar_row_h + self.band_bot_gap

    local grid_avail = self.screen_h - self.top_h - self.band_h
    self.card_h = math.max(1, math.floor((grid_avail - (ROWS - 1) * self.vgap) / ROWS))
    self.card_w = math.max(1, math.floor(self.card_h * self.screen_w / self.screen_h))

    -- A very wide screen would otherwise push the chevrons off the edge.
    local max_grid_w = self.screen_w - 2 * Layout.x(REF_SIDE_MIN)
    local max_card_w = math.floor((max_grid_w - (COLS - 1) * self.hgap) / COLS)
    if max_card_w > 0 and self.card_w > max_card_w then
        self.card_w = max_card_w
    end

    self.grid_w = COLS * self.card_w + (COLS - 1) * self.hgap
    self.grid_h = ROWS * self.card_h + (ROWS - 1) * self.vgap
    self.side_w = math.max(0, math.floor((self.screen_w - self.grid_w) / 2))
    -- Integer division above loses a pixel or two; give them to a spacer above
    -- the band so the band stays pinned to the bottom edge.
    self.slack_h = math.max(0, grid_avail - self.grid_h)

    self.card_border = math.max(Size.line.medium, Layout.x(REF_CARD_BORDER))
    self.card_border_cur = math.max(Size.line.thick, Layout.x(REF_CARD_BORDER_CUR))
    -- Every card asks for the same thumbnail size -- the interior of a THIN
    -- border -- because the cache is keyed on it (readerthumbnail.lua:259) and
    -- the current page would otherwise be rendered a second time at its own
    -- size. Its thicker border simply eats a few pixels of the image.
    self.thumb_w = math.max(1, self.card_w - 2 * self.card_border)
    self.thumb_h = math.max(1, self.card_h - 2 * self.card_border)

    self.badge_h = Layout.y(REF_BADGE_H)
    self.badge_pad = Layout.x(REF_BADGE_PAD)
    -- The badge straddles the card's top edge. Half of it hangs above, but never
    -- so far that it lands on the card in the row above.
    self.badge_overhang = math.min(math.floor(self.badge_h / 2),
        math.max(0, self.vgap - self.card_border))
end

--------------------------------------------------------------------------------
-- Data
--------------------------------------------------------------------------------

function PageBrowser:_readBook()
    local doc = self.ui and self.ui.document
    -- pagebrowserwidget.lua:172 reads the same accessor.
    local pages = doc and doc.getPageCount and doc:getPageCount()
    self.nb_pages = (pages and pages > 0) and pages or 1

    -- pagebrowserwidget.lua:173 takes ReaderToc's live page number, which is fed
    -- by the PageUpdate/PosUpdate events (readertoc.lua:127, :153).
    -- ReaderUI:getCurrentPage (readerui.lua:1000) covers the moment before the
    -- first of those has fired, the same fallback kindleui_pagelist.lua:611 uses.
    local toc = self.ui and self.ui.toc
    local cur = toc and toc.pageno
    if not cur and self.ui and self.ui.getCurrentPage then
        cur = self.ui:getCurrentPage()
    end
    self.cur_page = cur or 1

    -- Open on the screenful holding the page being read.
    self.first_page = self.cur_page - ((self.cur_page - 1) % PER_SCREEN)
end

--- The book's title, as the rest of KOReader would print it.
-- readerui.lua:495 publishes doc_props and `display_title` is already
-- filename-without-extension when the file carries no title metadata
-- (filemanagerbookinfo.lua:315), so the usual fallback is upstream's job. The
-- remaining branches only cover being built against something that is not a
-- fully-opened ReaderUI.
function PageBrowser:_bookTitle()
    local props = self.ui and self.ui.doc_props
    if props and props.display_title and props.display_title ~= "" then
        return props.display_title
    end
    local file = self.ui and self.ui.document and self.ui.document.file
    local base = file and file:match("([^/\\]+)$")
    if base then return (base:gsub("%.[^.]+$", "")) end
    return _("Document")
end

--- What the centred label says for a given screenful.
--
-- The chapter containing the FIRST page of the grid, not the page being read.
-- The label sits under a grid that moves; pinning it to the reading position
-- would leave it saying "Chapter 3" while the reader is looking at Chapter 40,
-- which is worse than saying nothing.
--
-- ReaderToc:getTocTitleByPage (readertoc.lua:445) already runs the title through
-- cleanUpTocTitle and calls fillToc itself (readertoc.lua:383), and returns ""
-- for a book with no table of contents -- at which point Kindle shows the book
-- title, so we do too.
function PageBrowser:_labelFor(page)
    local toc = self.ui and self.ui.toc
    if toc and toc.getTocTitleByPage then
        -- A malformed TOC should cost us the chapter name, not the screen.
        local ok, title = pcall(function() return toc:getTocTitleByPage(page) end)
        if ok and title and title ~= "" then return title end
        if not ok then logger.warn("kindleui: getTocTitleByPage failed:", title) end
    end
    return self:_bookTitle()
end

--- Chapter starts as 0..1 fractions of the book.
-- The same source readerfooter.lua:2230 feeds its own progress bar with
-- (readertoc.lua:548), on the raw page scale so the ticks and the knob cannot
-- disagree -- the reasoning is spelled out at kindleui_toolbar.lua:661-670.
function PageBrowser:_ticks()
    local toc = self.ui and self.ui.toc
    if not (toc and toc.getTocTicksFlattened) then return nil end
    local ok, pages = pcall(function() return toc:getTocTicksFlattened() end)
    if not (ok and pages) then return nil end
    local ticks = {}
    for _idx, page in ipairs(pages) do
        -- Page 1 is the bar's own left cap; a tick there reads as a smudge.
        if page > 1 and page <= self.nb_pages then
            ticks[#ticks + 1] = self:_pageFraction(page)
        end
    end
    return ticks
end

function PageBrowser:_pageFraction(page)
    if self.nb_pages <= 1 then return 0 end
    local frac = (page - 1) / (self.nb_pages - 1)
    if frac < 0 then return 0 end
    if frac > 1 then return 1 end
    return frac
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

--- Jump to a page and leave.
-- Exactly the path kindleui_pagelist.lua:651-661 takes for a chapter row, which
-- is itself ReaderToc's own (readertoc.lua:984-990) and PageBrowserWidget's
-- (pagebrowserwidget.lua:1635-1636). The location-stack push is what makes
-- "back" return here. No xpointer form: a thumbnail is a page number by
-- construction, there is no ToC entry to take a pointer from.
function PageBrowser:_gotoPage(page)
    UIManager:close(self)
    if not (self.ui and self.ui.handleEvent) then return end
    if self.ui.link then
        self.ui.link:addCurrentLocationToStack()
    end
    self.ui:handleEvent(Event:new("GotoPage", page))
end

--- Move the grid to the screenful holding `page`.
-- Returns true when it moved; the grid itself asks for the refresh, through
-- on_page_change -> _syncBand.
function PageBrowser:_showPage(page)
    return self.grid ~= nil and self.grid:_setPage(page)
end

--- Bring the band into line with the grid, and ask for ONE refresh.
-- Paging changes nine thumbnails, the chapter name and the knob at once, so
-- they want to arrive in the same e-ink update rather than three.
function PageBrowser:_syncBand(first_page)
    self.first_page = first_page
    if self.label_container then
        local old = self.label_container[1]
        if old and old.free then old:free() end
        self.label_container[1] = self:_labelWidget(first_page)
    end
    if self.bar then
        self.bar.percent = self:_pageFraction(first_page)
    end
    UIManager:setDirty(self, "ui", self.dimen)
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

function PageBrowser:_buildTopRow()
    local close = Theme.Tappable:new{
        on_tap = function() UIManager:close(self) end,
        CenterContainer:new{
            dimen = Geom:new{ w = Layout.x(REF_CLOSE_CELL), h = self.top_h },
            TextWidget:new{ text = Theme.GLYPH.close, face = self.face_close, padding = 0 },
        },
    }
    -- Pushed right with a span rather than a RightContainer, the way
    -- kindleui_pagelist.lua:743-746 pushes its chevron: a span is one number in
    -- one place and the group stays a plain widget tree.
    local lead = self.screen_w - self.margin - Layout.x(REF_CLOSE_CELL)
    if lead < 0 then lead = 0 end
    return HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = lead },
        close,
        HorizontalSpan:new{ width = self.margin },
    }
end

--- One of the two screen-edge chevrons, centred against the grid's height.
function PageBrowser:_buildSideChevron(glyph, step)
    return Theme.Tappable:new{
        on_tap = function()
            self:_showPage(self.first_page + step * PER_SCREEN)
        end,
        CenterContainer:new{
            -- The whole column is the tap target, not just the glyph: a 56px
            -- chevron on a screen edge is a cruel thing to aim at.
            dimen = Geom:new{ w = self.side_w, h = self.grid_h },
            TextWidget:new{ text = glyph, face = self.face_side_chev, padding = 0 },
        },
    }
end

function PageBrowser:_labelWidget(page)
    return TextWidget:new{
        text = self:_labelFor(page),
        face = self.face_label,
        padding = 0,
        -- Never wider than the space between the two end-jump cells. A chapter
        -- name that outgrows its box is exactly the failure this file exists to
        -- fix, so it is truncated with an ellipsis rather than allowed to run.
        max_width = math.max(1, self.screen_w - 2 * (self.margin + Layout.x(REF_CAP_W))),
    }
end

function PageBrowser:_buildEndJump(at_start)
    return Theme.Tappable:new{
        on_tap = function()
            self:_showPage(at_start and 1 or self.nb_pages)
        end,
        CenterContainer:new{
            dimen = Geom:new{ w = Layout.x(REF_CAP_W), h = self.label_h },
            EndJump:new{
                width = Layout.x(REF_CAP_W),
                height = self.label_h,
                tri_w = Layout.x(REF_CAP_TRI_W),
                tri_h = Layout.y(REF_CAP_TRI_H),
                bar_w = math.max(Size.line.thick, Layout.x(REF_CAP_BAR_W)),
                gap = Layout.x(REF_CAP_GAP),
                at_start = at_start,
            },
        },
    }
end

function PageBrowser:_buildBand()
    self.label_container = CenterContainer:new{
        dimen = Geom:new{
            w = self.screen_w - 2 * (self.margin + Layout.x(REF_CAP_W)),
            h = self.label_h,
        },
        self:_labelWidget(self.first_page),
    }

    -- Fixed-width cells either side, so the label is centred on the SCREEN and
    -- not on whatever is left after two glyphs of unequal width.
    local label_row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = self.margin },
        self:_buildEndJump(true),
        self.label_container,
        self:_buildEndJump(false),
        HorizontalSpan:new{ width = self.margin },
    }

    self.bar = ProgressBar:new{
        width = self.inner_w,
        height = self.bar_row_h,
        percent = self:_pageFraction(self.first_page),
        ticks = self:_ticks(),
        on_seek = function(frac) self:_seek(frac) end,
    }

    return VerticalGroup:new{
        align = "left",
        -- Full bleed, so it cannot carry the side padding the rows do.
        Theme.rule(self.rule_h),
        VerticalSpan:new{ width = self.band_top_gap },
        label_row,
        VerticalSpan:new{ width = self.label_gap },
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = self.margin },
            self.bar,
        },
        VerticalSpan:new{ width = self.band_bot_gap },
    }
end

--- Turn a bar fraction into a screenful.
function PageBrowser:_seek(frac)
    local page = math.floor(frac * (self.nb_pages - 1) + 0.5) + 1
    if self:_showPage(page) then return end
    -- It did not move: the drag ended on the screenful it started on, or against
    -- an end stop. Nobody is going to refresh for us, and the knob has been
    -- following the finger, so put it back on the grid's own position.
    if self.bar then
        self.bar.percent = self:_pageFraction(self.first_page)
        self.bar:refresh()
    end
end

function PageBrowser:update()
    if self.frame then self.frame:free() end

    self.grid = Grid:new{
        ui = self.ui,
        width = self.grid_w,
        height = self.grid_h,
        card_w = self.card_w,
        card_h = self.card_h,
        hgap = self.hgap,
        vgap = self.vgap,
        thumb_w = self.thumb_w,
        thumb_h = self.thumb_h,
        border = self.card_border,
        border_cur = self.card_border_cur,
        badge_h = self.badge_h,
        badge_pad = self.badge_pad,
        badge_overhang = self.badge_overhang,
        face_badge = self.face_badge,
        nb_pages = self.nb_pages,
        cur_page = self.cur_page,
        first_page = self.first_page,
        on_select = function(page) self:_gotoPage(page) end,
        on_page_change = function(first) self:_syncBand(first) end,
    }

    local body = HorizontalGroup:new{
        align = "center",
        self:_buildSideChevron(Theme.GLYPH.chev_left, -1),
        self.grid,
        self:_buildSideChevron(Theme.GLYPH.chev_right, 1),
    }

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = 0,
        -- FrameContainer paints its background over width x height
        -- (framecontainer.lua:118) even though getSize reports the content box,
        -- which is how the screen is filled exactly and the page hidden.
        width = self.screen_w,
        height = self.screen_h,
        VerticalGroup:new{
            align = "left",
            self:_buildTopRow(),
            body,
            VerticalSpan:new{ width = self.slack_h },
            self:_buildBand(),
        },
    }
    self[1] = self.frame

    -- Named so main.lua can pass it to UIManager:show as the refresh region;
    -- see the note at main.lua:294-315 about the nil-refreshtype trap.
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
end

function PageBrowser:paintTo(bb, x, y)
    self[1]:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function PageBrowser:onCloseWidget()
    if self.grid then self.grid:cancelRequests() end
    -- Drop tiles rendered at a size we are no longer using
    -- (pagebrowserwidget.lua:1231); the cache is capped at about five screenfuls
    -- (readerthumbnail.lua:130-147) and the reader is about to want it back for
    -- the page it just jumped to.
    local thumb = self.ui and self.ui.thumbnail
    if thumb and thumb.tidyCache then thumb:tidyCache() end

    -- "full", not "ui". Nine downscaled page images leave real ghosting behind,
    -- and PageBrowserWidget flashes for the same reason on the way out
    -- (pagebrowserwidget.lua:1244).
    UIManager:setDirty(nil, "full", self.dimen)
end

function PageBrowser:onNextGridPage()
    return self.grid and self.grid:onNextGridPage()
end

function PageBrowser:onPrevGridPage()
    return self.grid and self.grid:onPrevGridPage()
end

function PageBrowser:onClose()
    UIManager:close(self)
    return true
end

return PageBrowser
