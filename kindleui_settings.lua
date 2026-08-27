--[[--
Kindle's Settings page.

The firmware draws Settings as a flat, full-screen list. There are no section
headings anywhere on it -- the grouping is carried entirely by the eight row
labels and by the solid icon in each row's left margin. (Solid here, hollow
rings in the control centre; kindleui_theme.lua explains why that contrast is
deliberate.)

    ┌──────────────────────────────────────────┐
    │ Settings                          ⋮  ✕   │  115px band + hairline
    │ ──────────────────────────────────────── │
    │ (user)  Your account                   › │
    │         Paired as Kindle.                │
    │  ────────────────────────────────────    │  hairline, inset
    │ (wifi)  Wi-Fi and Sync         Home  ›   │
    │  ────────────────────────────────────    │
    │ (mobi)  Device options                 › │
    │  ────────────────────────────────────    │
    │ (sun)   Screen and brightness          › │
    │  ────────────────────────────────────    │
    │ (font)  Reading  Font, layout, page tu.› │
    │  ────────────────────────────────────    │
    │ (book)  Home and Library               › │
    │  ────────────────────────────────────    │
    │ (chart) Reading Insights               › │
    │  ────────────────────────────────────    │
    │ (?)     Help                           › │
    └──────────────────────────────────────────┘

WHERE THE CONTENT COMES FROM

Nothing here defines a setting. KOReader assembles every settings item into a
flat `menu_items` table and then *sorts* it into a hierarchy using a separate
order table, so the grouping and the definitions are already divorced:
ReaderMenu:setUpdateItemTable (readermenu.lua:179) fills `self.menu_items` and
hands it to MenuSorter:mergeAndSort (readermenu.lua:349-351) together with
frontend/ui/elements/reader_menu_order.lua. The container entries carry a text
and nothing else -- see common_settings_menu_table.lua:573, whose entire body
is `text` plus the comment "submenus are filled by menu_order". That is the
seam this file uses: a different grouping is just a different order table, and
no item definition has to be touched.

So this widget takes the *sorted* result, indexes it by id, and re-groups those
same live entries under Kindle's eight headings. Their `callback`s,
`checked_func`s and `text_func`s are the originals, so a toggle flipped here is
the same toggle KOReader's own menu would flip.

HOW `menu_items` IS OBTAINED, AND WHY IT LOOKS TIMID

    if menu.tab_item_table == nil then menu:setUpdateItemTable() end
    local sorted = menu.tab_item_table

That guard is copied verbatim from ReaderMenu:onShowMenu (readermenu.lua:392)
and FileManagerMenu:onShowMenu (filemanagermenu.lua:1029), and it is load
bearing, not decorative: **setUpdateItemTable can only ever be called once per
ReaderMenu instance.** MenuSorter:sort consumes `menu_items` destructively --
it nils out each leaf as it places it (menusorter.lua:74), each submenu
(menusorter.lua:130), and finally the root itself (menusorter.lua:159). A
second call would reach menusorter.lua:139, `ipairs(menu_table["KOMenu:menu_buttons"])`,
with that key now nil, and die. Upstream never notices because both call sites
are guarded exactly like this.

The consequence to be honest about: `tab_item_table` is a *snapshot* taken the
first time anything opened a menu in this session. Items added afterwards (a
plugin loaded late) will not appear until the session restarts. What does stay
live is every value, because `text_func` / `checked_func` / `enabled_func` are
closures that this file re-evaluates on each repaint.

We read the sorted output rather than raw `menu_items` for the same reason:
after the sort, `menu_items` has been emptied of nearly everything, while
`tab_item_table` holds the complete tree with `id` stamped on every node
(menusorter.lua:57, 71, 167).

WHAT THIS COSTS

`Menu` (ui/widget/menu.lua) is the right shell -- it already does hierarchical
drill-down (Menu:onMenuSelect pushes onto `item_table_stack`, menu.lua:1377)
and back-navigation (Menu:onClose pops it, menu.lua:1458) -- but its `MenuItem`
is not `TouchMenuItem`. It renders text, an optional left "state" widget and a
right-aligned "mandatory" string, and that is all. It has no checkbox, no radio
button, no notion of `keep_menu_open`. Everything below that is worked around
by re-implementing TouchMenu:onMenuSelect's branches (touchmenu.lua:856) over
this widget instead, and by rendering check state as a tick in `mandatory`.
The three things that could not be reproduced are listed at CAVEATS, at the
bottom of this file.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local LeftContainer = require("ui/widget/container/leftcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Layout = require("kindleui_geom") -- this plugin's proportions, not ui/geometry
local MENU_ICONS = require("kindleui_menu_icons")
local Theme = require("kindleui_theme")
local logger = require("logger")
local _ = require("gettext")
-- Needed by every message below that interpolates. Missing it is not a syntax
-- error; it is `attempt to call global 'T'` the first time such a message is
-- built, which no compile check catches.
local T = require("ffi/util").template
local Screen = Device.screen

local GLYPH = Theme.GLYPH
local REF = Theme.REF

-- MenuItem's own fonts, so our sizes land on the faces it will actually use
-- (menu.lua:87-88 declare font = "smallinfofont", infont = "infont").
local ITEM_FONT = "smallinfofont"
local ITEM_INFONT = "infont"

--------------------------------------------------------------------------------
-- Header
--
-- Menu will accept any widget as `custom_title_bar` and only ever asks it for
-- getHeight(), setTitle(), setSubTitle() and generateVerticalLayout()
-- (menu.lua:657, 1191, 1197, 1148). That is a small enough surface to satisfy
-- directly, which is cheaper than bending TitleBar: TitleBar's buttons are
-- IconButtons reading PNGs out of icons/, and Kindle's header is two font
-- glyphs against a bold word.
--------------------------------------------------------------------------------
local Header = WidgetContainer:extend{
    title = nil,
    -- Called for the ⋮ glyph and the ✕ glyph respectively.
    on_overflow = nil,
    on_search = nil,
    on_close = nil,
    -- Called when the ‹ glyph is tapped; the glyph only appears when this
    -- returns true, i.e. when the Menu has something on its item_table_stack.
    is_nested = nil,
    on_back = nil,
}

function Header:init()
    self.face_title = Theme.faceBold(REF.heading_h)
    self.face_glyph = Theme.face(REF.icon_h)
    self:update()
end

--- Rebuilds the band. Called on every title change, because the back chevron
-- appears and disappears with the navigation depth.
function Header:update()
    if self[1] then
        -- Rebuilt on every title change, so release the glyph caches the old
        -- TextWidgets are holding. TextWidget:free is idempotent and re-renders
        -- lazily (textwidget.lua:380).
        self[1]:free()
    end
    local margin = Theme.margin()
    local gap = Layout.x(REF.gap)
    local screen_w = Screen:getWidth()

    -- Every header control is a BLOCK, not a glyph.
    --
    -- A Tappable wrapped straight around a TextWidget has the glyph's own ink
    -- box for a hit area -- a chevron is a few tens of pixels of actual mark,
    -- so the tap has to land on the stroke itself. Reported from the device:
    -- going back meant hitting the arrow exactly.
    --
    -- The firmware treats each of these as a square button, and squares are
    -- also what makes them reachable: the target becomes the whole cell rather
    -- than the drawing inside it. `hit` is the cell, sized from the band it
    -- lives in, not from the glyph.
    local hit = Layout.y(REF.title_bar_h)
    local function iconButton(glyph, on_tap, label)
        if label then
            -- Back carries its label INSIDE the button, so tapping the words
            -- goes back too. Otherwise the title beside a back arrow is dead
            -- space that looks exactly like part of the control.
            --
            -- LEFT-ALIGNED, and padded by a gap rather than by a whole cell.
            -- The first version centred this inside a cell `hit` wider than its
            -- contents, which put half a title bar of empty space on each side
            -- -- so the chevron floated away from the margin and the word
            -- floated away from the chevron. It measured as a button and read
            -- as a mistake.
            local inner = HorizontalGroup:new{
                align = "center",
                TextWidget:new{ text = glyph, face = self.face_glyph, padding = 0 },
                HorizontalSpan:new{ width = math.floor(gap / 2) },
                TextWidget:new{
                    text = label, face = self.face_title, padding = 0,
                    max_width = screen_w - 2 * margin - 3 * hit,
                },
            }
            -- Flush to the screen edge, with a MARGIN OF PADDING ON EACH SIDE.
            --
            -- Both halves matter and the first attempt only had one. Reaching
            -- x = 0 makes the highlight run to the edge the way the firmware's
            -- does; equal padding is what stops it looking like the button was
            -- mis-measured. A margin on the left and a half-gap on the right
            -- put the chevron in the right place and still read as lopsided,
            -- because it was.
            --
            -- The padding lives INSIDE the button rather than in front of it,
            -- so the glyph still lands on the margin: it grows inward, never
            -- outward into the layout.
            return Theme.Tappable:new{
                on_tap = on_tap,
                CenterContainer:new{
                    dimen = Geom:new{ w = inner:getSize().w + 2 * margin, h = hit },
                    inner,
                },
            }
        end
        -- Icon-only controls follow the SAME rule: a margin of padding either
        -- side of the glyph. That makes them flush at their edge with the glyph
        -- sitting on the margin, exactly like the labelled one, rather than a
        -- square whose size happens to be close to that.
        local g = TextWidget:new{ text = glyph, face = self.face_glyph, padding = 0 }
        return Theme.Tappable:new{
            on_tap = on_tap,
            CenterContainer:new{
                dimen = Geom:new{ w = g:getSize().w + 2 * margin, h = hit },
                g,
            },
        }
    end

    -- Nothing in front of a labelled button: it carries its own leading margin
    -- so it can start at the screen edge. A plain title still needs one.
    local lead = (self.is_nested and self.is_nested()) and 0 or margin
    local row = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = lead } }

    -- Kindle's sub-pages put a back chevron left of the title. Without one the
    -- only ways back would be a swipe south (Menu:onSwipe, menu.lua:1490) or a
    -- hardware key, neither of which is visible.
    -- On a sub-page the back control IS the title: one button carrying the
    -- chevron and the page name, so the whole thing goes back. On the root
    -- there is nothing to go back to, so the title is plain text.
    local nested = self.is_nested and self.is_nested()
    local title
    if nested then
        title = iconButton(GLYPH.chev_left, self.on_back, self.title or "")
    else
        title = TextWidget:new{
            text = self.title or "",
            face = self.face_title,
            padding = 0,
            max_width = screen_w - 2 * margin - 3 * hit,
        }
    end
    table.insert(row, title)

    -- The overflow button is gone from here. It opened "All settings", which is
    -- a destination like any other -- now the last row of the list, where a
    -- fallback belongs. A header is for acting on this page, and listing every
    -- menu KOReader has is not that.
    --
    -- Search IS an action on this page, so it stays. Root only: a sub-page
    -- already has the back button on the left, and three controls across a
    -- header is one more than a header can hold without becoming a toolbar.
    local search = (not nested) and self.on_search
                   and iconButton(GLYPH.search, self.on_search) or nil
    local close = iconButton(GLYPH.close, self.on_close)

    -- Flexible space: title hard left, the two glyphs hard right.
    --
    -- Everything already IN the row is measured by the loop -- the leading span
    -- and the title both live there by now -- so the base holds only what has
    -- not been inserted yet. Adding `lead` to the base as well double-counted
    -- it and stole that many pixels from the gap in the middle.
    -- The close button sits flush against the right edge, so there is no
    -- trailing margin to reserve either.
    local used = close:getSize().w + (search and search:getSize().w or 0)
    for _idx, widget in ipairs(row) do
        used = used + widget:getSize().w
    end
    local flex = screen_w - used
    if flex < gap then flex = gap end

    table.insert(row, HorizontalSpan:new{ width = flex })
    if search then table.insert(row, search) end
    table.insert(row, close)

    self[1] = VerticalGroup:new{
        align = "left",
        CenterContainer:new{
            -- The band is 1236x115 on a PW5 (kindleui_geom.lua names the
            -- xwininfo rect this comes from). CenterContainer with a row that
            -- is exactly screen-wide centres it vertically and leaves it at
            -- x = 0, which is what the firmware does.
            dimen = Geom:new{ w = screen_w, h = Layout.y(REF.title_bar_h) },
            row,
        },
        -- Full-bleed, unlike the row separators below it: this is the rule that
        -- closes the header against the list, not a separator inside it.
        Theme.hairline(screen_w),
    }
end

function Header:getHeight()
    return self[1]:getSize().h
end

--- Menu calls this from switchItemTable (menu.lua:1191) on every drill-down and
-- every step back, which is exactly when the back chevron has to change.
function Header:setTitle(title)
    self.title = title
    self:update()
end

--- Menu only calls this when a caller passes a subtitle (menu.lua:1196); we
-- never do. Present so the contract is complete rather than accidentally met.
function Header:setSubTitle() end

--- FocusManager rows for key navigation (menu.lua:1148 merges these in).
-- Empty: the two glyphs are Theme.Tappables, which have no onFocus/onUnfocus,
-- so handing them to FocusManager would break D-pad navigation rather than
-- extend it. On a touch Kindle nothing is lost; see CAVEATS.
function Header:generateVerticalLayout()
    return {}
end

--------------------------------------------------------------------------------
-- Reading the sorted menu
--------------------------------------------------------------------------------

--- Every node of the sorted tree, keyed by the id MenuSorter stamped on it.
-- Containers are recorded as the *stub* that carries `sub_item_table`
-- (menusorter.lua:124-126), so index[id].sub_item_table is a container's
-- children and index[id] on its own is a leaf.
local function indexById(tab_item_table)
    local index, seen = {}, {}
    local function walk(list, depth)
        -- Depth and identity guards: a plugin is free to point a
        -- sub_item_table back at an ancestor, and a stack overflow inside a
        -- settings screen is a much worse outcome than a missing row.
        if depth > 12 or seen[list] then return end
        seen[list] = true
        if list.id and index[list.id] == nil then
            index[list.id] = list
        end
        for _idx, item in ipairs(list) do
            if type(item) == "table" then
                if item.id and index[item.id] == nil then
                    index[item.id] = item
                end
                if type(item.sub_item_table) == "table" then
                    walk(item.sub_item_table, depth + 1)
                end
            end
        end
    end
    for _idx, tab in ipairs(tab_item_table) do
        walk(tab, 1)
    end
    return index
end

--- Resolves one group's id list into a flat array of live menu entries.
-- "network/*" means that container's children; "night_mode" means the entry
-- itself. Unknown ids are skipped in silence *by design*: the reader and the
-- file manager have different order tables (reader_menu_order.lua vs
-- filemanager_menu_order.lua) and neither offers the whole set, so a group is
-- written as a superset of both and thins itself out at runtime.
local function collect(index, refs)
    local out = {}
    for _idx, ref in ipairs(refs) do
        local container = ref:match("^(.-)/%*$")
        local entry = index[container or ref]
        if entry then
            if container then
                for _i, child in ipairs(entry.sub_item_table or entry) do
                    table.insert(out, child)
                end
            else
                table.insert(out, entry)
            end
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- Turning KOReader entries into MenuItem entries
--------------------------------------------------------------------------------

--- A shallow copy of a menu entry, with the bits MenuItem understands filled in
-- from the bits it does not.
--
-- Copying rather than annotating in place matters: these tables belong to
-- KOReader and are still wired into the stock TouchMenu. Writing `dim` or
-- `mandatory_func` onto them would be invisible today (TouchMenuItem reads
-- neither) and a landmine the next time upstream starts reading one of them.
-- The original is kept on `kindleui_src` so selection can consult the live
-- entry rather than our copy.
--- `opts` carries the two measurements the icon column needs.
--
-- decorate is a plain local, not a method, so there is no `self` here -- the
-- first version read `self.glyph_col_w` and would have been nil at run time,
-- which no syntax check catches. The caller has them and passes them in.
local function decorate(list, opts)
    opts = opts or {}
    local out = {}
    for _idx, src in ipairs(list) do
        if type(src) == "table" and (src.text or src.text_func)
                -- MenuSorter's separator sentinel (menusorter.lua:18). The
                -- sorter normally folds these into `.separator` on the
                -- preceding item, but a plugin may hand one to us raw.
                and src.text ~= "KOMenu:separator" then
            local copy = {}
            for k, v in pairs(src) do copy[k] = v end
            copy.kindleui_src = src

            -- An icon in the left column, the same place the eleven top-level
            -- rows put theirs, so a sub-page reads as the same kind of screen
            -- rather than as a bare list.
            --
            -- Keyed on the id: a title is translated and a title gets reworded,
            -- an id is neither. Rows KOReader gives no id -- a plugin's own
            -- entries, mostly -- get no icon rather than a wrong one, and the
            -- column simply stays empty for them.
            local icon = src.id and MENU_ICONS[src.id]
            if icon and opts.glyph_col_w and opts.glyph_face then
                copy.state = CenterContainer:new{
                    dimen = Geom:new{ w = opts.glyph_col_w, h = Layout.y(REF.icon_h) },
                    TextWidget:new{ text = icon, face = opts.glyph_face, padding = 0 },
                }
            end

            if src.checked_func or src.checked ~= nil then
                -- MenuItem draws no checkbox. A tick in the right-hand
                -- "mandatory" column is the only place check state can go, and
                -- it has to be a *function* (menu.lua:187 prefers
                -- mandatory_func) so that toggling an option and repainting
                -- shows the new state instead of the state at build time.
                copy.mandatory_func = function()
                    local base = src.mandatory_func and src.mandatory_func() or src.mandatory
                    local checked = src.checked_func and src.checked_func() or src.checked
                    -- BOTH states drawn, which a tick cannot do.
                    --
                    -- There is no "unticked" glyph, so an off toggle used to
                    -- render as nothing -- identical to a row that is not a
                    -- toggle at all. A switch shows its position either way,
                    -- which is the only thing that makes the column readable.
                    --
                    -- `radio` entries keep the tick: a radio is one choice out
                    -- of a set, and a row of switches where only one can be on
                    -- reads as a set of independent options that happen to
                    -- disagree.
                    -- A radio keeps a tick: it is one choice out of a set, and
                    -- a row of switches where only one may be on reads as
                    -- independent options that happen to disagree.
                    if src.radio then
                        if not checked then return base end
                        return base and (base .. " " .. GLYPH.check) or GLYPH.check
                    end
                    -- A real switch is PAINTED over this row, not typed into
                    -- it -- see _paintSwitches. The glyph is still returned so
                    -- MenuItem reserves a slot on the right and lays the title
                    -- out clear of it; the paint then covers the glyph
                    -- completely, being larger in both directions.
                    local mark = checked and GLYPH.toggle_on or GLYPH.toggle_off
                    return base and (base .. " " .. mark) or mark
                end
            end

            table.insert(out, copy)
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- The eight rows
--
-- Kindle's own grouping, mapped onto KOReader ids. Read the id lists as
-- "whatever of these exists here": see collect() above.
--------------------------------------------------------------------------------
local function groupSpecs()
    return {
        {
            glyph = GLYPH.user,
            title = _("Your account"),
            -- The xtreader plugin is this repo's, not KOReader's. No plugin,
            -- no account, no row.
            needs = "xtreader",
            refs = { "xtreader/*" },
        },
        {
            glyph = GLYPH.wifi,
            title = _("Wi-Fi and Sync"),
            refs = { "network/*", "progress_sync", "cloudstorage", "cloud_storage" },
            value = function()
                -- NetworkMgr:isWifiOn is a stub on the base class and is
                -- replaced per platform (manager.lua:182; Kindle installs
                -- sysfsWifiOn at device/kindle/device.lua:523).
                if not NetworkMgr:isWifiOn() then return _("Off") end
                local nw = NetworkMgr:getCurrentNetwork()
                return nw and nw.ssid or _("On")
            end,
        },
        {
            glyph = GLYPH.adjust,
            title = _("Appearance"),
            sub = _("Lock screen, control centre, toolbar"),
            -- THE ROW THIS PAGE WAS MISSING.
            --
            -- Everything this fork actually draws -- the lock screen, the
            -- control centre, the reading toolbar -- was registered under
            -- `taps_and_gestures` because that is a convenient place for a
            -- plugin to attach, and so it ended up inside the "Reading" row,
            -- described as "Font, layout, page turns", four levels down.
            --
            -- Finding the lock screen took the owner ten minutes and he could
            -- not remember the route afterwards. Nobody would guess it: it is
            -- not a reading setting and it is not a gesture.
            refs = { "kindleui/*", "night_mode", "screensaver" },
        },
        {
            glyph = GLYPH.sun,
            title = _("Screen and Light"),
            -- Kept apart from Appearance on purpose: one is what the interface
            -- LOOKS like, the other is how bright the panel is. They read as
            -- the same thing only until you go looking for one of them.
            refs = { "frontlight", "screen/*" },
        },
        {
            glyph = GLYPH.font,
            title = _("Reading"),
            sub = _("Fonts, layout, page turns"),
            refs = {
                "change_font", "typography", "set_render_style", "style_tweaks",
                "document_settings", "page_overlap", "highlight_options",
                "taps_and_gestures/*",
            },
        },
        {
            glyph = GLYPH.book,
            title = _("Library"),
            sub = _("Home screen, sorting, collections"),
            refs = {
                "filebrowser_settings", "filemanager_display_mode", "show_filter",
                "sort_by", "reverse_sorting", "sort_mixed",
                "start_with", "history", "favorites", "collections",
                "bookmark_browser", "document/*", "open_last_document",
                "move_to_archive", "calibre",
                -- bookshelf.koplugin registers a whole TAB of its own, and a
                -- tab is not something this page can show. `collect` skips a
                -- ref it cannot resolve, so these cost nothing when absent.
                "bookshelf_settings", "bookshelf_shelf_size", "bookshelf_shelf_tabs",
                "bookshelf_hardcover", "bookshelf_updates", "bookshelf_toggle",
            },
        },
        {
            glyph = GLYPH.search,
            title = _("Search and Lookup"),
            sub = _("Dictionary, Wikipedia, catalogues"),
            -- KOReader's entire `search` tab, which this page did not reach at
            -- all. Looking a word up is something you do WHILE reading, and it
            -- was only ever available from the stock menu.
            refs = {
                "dictionary_lookup", "dictionary_lookup_history",
                "wikipedia_lookup", "wikipedia_history",
                "file_search", "file_search_results",
                "find_book_in_calibre_catalog", "opds",
                "vocabbuilder", "search_settings",
            },
        },
        {
            glyph = GLYPH.grid,
            title = _("Tools"),
            sub = _("Statistics, profiles, export"),
            -- Most of KOReader's `tools` tab, likewise unreachable from here.
            refs = {
                "statistics", "profiles", "exporter", "read_timer",
                "text_editor", "qrclipboard", "wallabag", "news_downloader",
                "more_tools",
            },
        },
        {
            glyph = GLYPH.chart,
            title = _("Reading Insights"),
            -- readinginsights registers this id with no sorting_hint, so
            -- MenuSorter treats it as an orphan and gives it a "NEW: " prefix
            -- -- which is why the row's title is written here rather than
            -- taken from the entry.
            needs = "reading_insights_popup",
            refs = { "reading_insights_popup/*" },
        },
        {
            glyph = GLYPH.mobile,
            title = _("Device"),
            sub = _("Language, gestures, power"),
            refs = { "language", "device/*", "navigation/*", "ota_update", "exit_menu" },
        },
        {
            glyph = GLYPH.question,
            title = _("Help"),
            refs = { "help/*" },
        },
    }
end

-- The names of KOReader's own top-level tabs, for the overflow page. The tabs
-- themselves carry only an `icon` and no text (readermenu.lua:26-53), so there
-- is nothing to read them from.
local TAB_NAMES = {
    navi                = _("Navigation"),
    typeset             = _("Typeset"),
    setting             = _("Settings"),
    tools               = _("Tools"),
    search              = _("Search"),
    filemanager         = _("File browser"),
    filemanager_settings = _("File browser"),
    main                = _("Main menu"),
}

--------------------------------------------------------------------------------
-- KindleUISettings
--------------------------------------------------------------------------------
local KindleUISettings = Menu:extend{
    name = "kindleui_settings",
    ui = nil, -- ReaderUI or FileManager; mandatory

    -- opdsbrowser.lua:223-225 builds a full-screen Menu exactly this way.
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,

    -- Kindle's rows are one line of text with a smaller trailing phrase, never
    -- a wrapped paragraph. single_line is also the only mode in which MenuItem
    -- honours post_text at all (menu.lua:225).
    single_line = true,
}

function KindleUISettings:init()
    self.title = _("Settings")

    -- Sizes, not faces: MenuItem builds its own faces from these
    -- (menu.lua:172-174), so handing it a face object would be ignored.
    -- Chaining getFontSizeToFitHeight onto the reference height is the same
    -- trick Theme.face() uses, and lands on Kindle's measurements.
    self.items_font_size = TextWidget:getFontSizeToFitHeight(ITEM_FONT, Layout.y(REF.title_h), 0)
    self.items_mandatory_font_size = TextWidget:getFontSizeToFitHeight(ITEM_INFONT, Layout.y(REF.sub_h), 0)

    -- Kindle's separators are hairlines, not the medium rule Menu defaults to
    -- (menu.lua:634-635).
    self.linesize = Size.line.thin
    self.line_color = Blitbuffer.COLOR_GRAY

    self.face_row_glyph = Theme.face(REF.icon_h)
    self.glyph_col_w = Layout.x(REF.icon_h)
    -- MenuItem indents its text by state_w and paints entry.state in the gap
    -- (menu.lua:159-170), which is how the solid icon gets a column of its own.
    self.state_w = self.glyph_col_w + Layout.x(REF.gap)

    self.custom_title_bar = Header:new{
        title = self.title,
        is_nested = function() return #(self.item_table_stack or {}) > 0 end,
        on_back = function() self:onClose() end,
        on_close = function() self:onCloseAllMenus() end,
        on_overflow = function() self:showAllSettings() end,
        on_search = function() self:showSearch() end,
    }

    self.item_table = self:buildRoot()
    Menu.init(self)
end

--------------------------------------------------------------------------------
-- Building the root list
--------------------------------------------------------------------------------

--- The sorted menu tree, or nil.
-- See the header comment: the guard is not optional, setUpdateItemTable is a
-- one-shot per ReaderMenu/FileManagerMenu instance.
function KindleUISettings:getSortedMenu()
    local menu = self.ui and self.ui.menu
    if not menu or type(menu.setUpdateItemTable) ~= "function" then
        return nil
    end
    if menu.tab_item_table == nil then
        menu:setUpdateItemTable()
    end
    return menu.tab_item_table
end

--- The account row's second line, from xtreader's own public status string.
-- ReaderUI/FileManager register each plugin instance under its `name`
-- (readerui.lua:96, 473), so self.ui.xtreader is the plugin or nil.
local function accountStatus(ui)
    local plugin = ui and ui.xtreader
    if not plugin or type(plugin.statusText) ~= "function" then return nil end
    local ok, text = pcall(plugin.statusText, plugin)
    if not ok or type(text) ~= "string" then return nil end
    -- statusText is multi-line when paired (xtreader.koplugin/main.lua:192);
    -- a settings row has space for the first line only.
    return (text:gsub("\n.*$", ""))
end

function KindleUISettings:buildRoot()
    local sorted = self:getSortedMenu()
    if not sorted then
        logger.warn("kindleui: no ReaderMenu/FileManagerMenu on self.ui;",
            "the settings list has nothing to show")
        -- An inert row rather than an empty screen or a crash.
        return {
            {
                text = _("Settings are unavailable"),
                post_text = _("No KOReader menu is attached to this view."),
            },
        }
    end

    self.menu_index = indexById(sorted)
    self.sorted_menu = sorted

    local rows = {}
    -- The escape hatch, as the LAST ROW rather than a header control.
    --
    -- It used to be the three-dot button in the title bar, which put a
    -- destination among the actions and hid the one thing a reader reaches for
    -- when the eleven groups do not have what they want. At the bottom of the
    -- list it is where a fallback belongs, and it is reachable by scrolling
    -- rather than by knowing.
    local function appendAllSettings(list)
        list[#list + 1] = {
            state = CenterContainer:new{
                dimen = Geom:new{ w = self.glyph_col_w, h = Layout.y(REF.icon_h) },
                TextWidget:new{ text = GLYPH.ellipsis_v, face = self.face_row_glyph, padding = 0 },
            },
            text = _("All settings"),
            post_text = _("Everything KOReader has, ungrouped"),
            bold = true,
            mandatory_func = function() return GLYPH.chev_right end,
            kindleui_all_settings = true,
        }
    end

    for _idx, spec in ipairs(groupSpecs()) do
        if not spec.needs or self.menu_index[spec.needs] then
            local children = collect(self.menu_index, spec.refs)
            if #children > 0 then
                table.insert(rows, self:makeRow(spec, children))
            else
                logger.dbg("kindleui: settings row", spec.title, "has no items here; dropped")
            end
        end
    end
    appendAllSettings(rows)
    return rows
end

--- One Kindle row: solid glyph, bold title, optional second phrase, optional
-- value, chevron.
function KindleUISettings:makeRow(spec, children)
    local sub = spec.sub
    if spec.needs == "xtreader" then
        sub = accountStatus(self.ui) or sub
    end

    return {
        -- MenuItem paints this vertically centred in the left margin
        -- (menu.lua:162-170). A fixed-width box so the eight glyphs, which have
        -- different advance widths, still line up.
        state = CenterContainer:new{
            dimen = Geom:new{ w = self.glyph_col_w, h = Layout.y(REF.icon_h) },
            TextWidget:new{ text = spec.glyph, face = self.face_row_glyph, padding = 0 },
        },
        text = spec.title,
        -- Kindle's second line is a real second line. MenuItem cannot do that:
        -- it strips every \n out of the text (menu.lua:210) and lays the result
        -- out as one line. post_text is the nearest thing it has -- same line,
        -- mandatory font size -- so the phrase reads as secondary even though it
        -- does not wrap under the title.
        post_text = sub,
        bold = true,
        mandatory_func = function()
            local value = spec.value and spec.value()
            if value then
                return value .. "  " .. GLYPH.chev_right
            end
            return GLYPH.chev_right
        end,
        mandatory_dim = spec.value ~= nil,
        -- Deliberately NOT `sub_item_table`: Menu.getMenuText appends its own
        -- "▸" to anything that has one (menu.lua:1566-1568), which would put a
        -- second arrow immediately after the title while Kindle's chevron
        -- belongs at the far right. onMenuSelect below reads this instead.
        kindleui_sub = children,
        kindleui_title = spec.title,
    }
end

--- Everything this grouping does not surface, one page per KOReader tab.
-- Without it, any item whose id is in none of the eight lists would simply be
-- unreachable from this screen.
function KindleUISettings:showAllSettings()
    if not self.sorted_menu then return end
    local tabs = {}
    for _idx, tab in ipairs(self.sorted_menu) do
        if #tab > 0 then
            table.insert(tabs, {
                text = TAB_NAMES[tab.id] or tab.id or _("Menu"),
                mandatory = GLYPH.chev_right,
                kindleui_sub = tab,
            })
        end
    end
    self:drillDown(_("All settings"), tabs, true)
end

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

--- Pick items-per-page so a row comes out Theme.REF.row_h tall.
--
-- Menu derives item height as available_height / perpage (menu.lua:519) and
-- available_height only becomes known once it has measured its own title bar
-- and footer. So: let it measure, then choose the count that divides what is
-- left into rows nearest the Kindle reference, then let it measure again.
-- Rounding rather than flooring keeps the drift symmetric -- an exact 137px is
-- not reachable, because the leftover pixels are shared out over the rows.
function KindleUISettings:_recalculateDimen(no_recalculate_dimen)
    Menu._recalculateDimen(self, no_recalculate_dimen)
    if not self.available_height then return end
    local row_h = Layout.y(REF.row_h)
    local want = math.max(1, math.floor(self.available_height / row_h + 0.5))
    if want ~= self.items_per_page then
        self.items_per_page = want
        Menu._recalculateDimen(self, false)
    end
end

--- Draw a real switch over the glyph MenuItem reserved for it.
--
-- Wrapping paintTo rather than replacing the mandatory widget inside MenuItem.
-- The alternative is surgery on a private structure -- FrameContainer, then
-- HorizontalGroup, then UnderlineContainer, then another HorizontalGroup, then
-- an OverlapGroup -- to reach a container KOReader is free to rearrange. This
-- touches nothing: the row paints itself exactly as it always did, and the
-- switch goes on top afterwards.
--
-- It also keeps the tap flash correct for free. MenuItem inverts the row's
-- rectangle in the framebuffer, so whatever has been painted there inverts with
-- it, switch included, and inverts back on release.
--- Give the tap flash time to actually appear before navigating.
--
-- MenuItem's own flash is tuned for its own row height. It highlights, forces a
-- repaint, waits, un-highlights, and queues a "ui" refresh -- and the wait is
-- `yieldToEPDC()`, which sleeps ONE MILLISECOND (uimanager.lua). On KOReader's
-- rows that is enough. These rows are 143px tall, and an A2 update over a band
-- that size takes two orders of magnitude longer, so the un-highlight lands
-- while the panel is still filling in the black -- which is what the owner saw
-- and read, reasonably, as something covering the row.
--
-- The second half matters as much: the un-highlight is only `setDirty`, so the
-- next page can be drawn over a rectangle that has not been repainted yet.
-- Forcing that repaint before selecting is what makes the row return to normal
-- rather than being replaced mid-flash.
--
-- FLASH_US is deliberately generous rather than measured per device. Too short
-- brings the bug back; too long is a flash somebody notices as a flash, which
-- is what it is meant to be.
local FLASH_US = 120 * 1000

function KindleUISettings:_wrapTapFlash(it)
    if it._kindleui_flash_wrapped then return end
    it._kindleui_flash_wrapped = true
    it.onTapSelect = function(self_it, _arg, ges)
        local frame = self_it[1]
        if not (frame and frame.dimen) then return end
        local pos = self_it:getGesPosition(ges)
        if G_reader_settings:isFalse("flash_ui") then
            self_it.menu:onMenuSelect(self_it.entry, pos)
            return true
        end

        frame.invert = true
        UIManager:widgetInvert(frame, frame.dimen.x, frame.dimen.y)
        UIManager:setDirty(nil, "fast", frame.dimen)
        UIManager:forceRePaint()
        UIManager:yieldToEPDC(FLASH_US)

        frame.invert = false
        UIManager:widgetInvert(frame, frame.dimen.x, frame.dimen.y)
        UIManager:setDirty(nil, "ui", frame.dimen)
        UIManager:forceRePaint()

        self_it.menu:onMenuSelect(self_it.entry, pos)
        return true
    end
end

function KindleUISettings:_paintSwitches()
    local Switch = require("kindleui_switch")
    local Size = require("ui/size")
    for _idx, it in ipairs(self.item_group or {}) do
        if type(it) == "table" and it.onTapSelect then self:_wrapTapFlash(it) end
        local entry = type(it) == "table" and it.entry
        local src = entry and entry.kindleui_src
        -- Radio rows keep their tick, so they must not get a switch painted
        -- over it.
        if src and not src.radio and (src.checked_func or src.checked ~= nil)
                and not it._kindleui_switch_wrapped then
            it._kindleui_switch_wrapped = true
            local orig_paintTo = it.paintTo
            it.paintTo = function(self_it, bb, x, y)
                orig_paintTo(self_it, bb, x, y)
                local ok = pcall(function()
                    local h = self_it.dimen and self_it.dimen.h
                    local w = self_it.dimen and self_it.dimen.w
                    if not h or not w then return end
                    local on = src.checked_func and src.checked_func() or src.checked
                    local sw = Switch:new{ row_h = h, on = on and true or false }
                    local sz = sw:getSize()
                    -- Right-aligned inside the same padding MenuItem uses for
                    -- its own right edge (menu.lua:455), so the switch lands
                    -- where the glyph it replaces was.
                    local pad = Size.padding.fullscreen

                    -- ERASE THE GLYPH FIRST.
                    --
                    -- It is still in the mandatory column, because that is what
                    -- makes MenuItem reserve the width and lay the title out
                    -- clear of it. But a glyph sits on the TEXT BASELINE while
                    -- the switch is centred on the row, so the two do not cover
                    -- each other and the old toggle showed underneath the new
                    -- one.
                    --
                    -- Wiping the band is exact, where guessing at how many
                    -- spaces make up the right width is not. Nothing else is
                    -- painted out here. Two pixels are left top and bottom so
                    -- the row's hairline separators survive.
                    local band_w = sz.w + pad * 2
                    bb:paintRect(x + w - pad - band_w + pad, y + 2,
                                 band_w, h - 4, Blitbuffer.COLOR_WHITE)

                    sw:paintTo(bb, x + w - pad - sz.w,
                                   y + math.floor((h - sz.h) / 2))
                end)
                if not ok then
                    logger.warn("kindleui: switch paint failed")
                end
            end
        end
    end
end

--- MenuItem reads `dim` once, at build time (menu.lua:1109), so anything driven
-- by enabled_func has to be refreshed here or a row would stay greyed after the
-- condition that greyed it went away.
function KindleUISettings:updateItems(select_number, no_recalculate_dimen)
    for _idx, item in ipairs(self.item_table) do
        local src = item.kindleui_src
        if src and src.enabled_func then
            local ok, enabled = pcall(src.enabled_func)
            item.dim = (ok and enabled == false) or nil
        end
    end
    local result = Menu.updateItems(self, select_number, no_recalculate_dimen)

    self:_paintSwitches()

    -- Pin each row's INVERT RECTANGLE to the row.
    --
    -- MenuItem flashes a tap by inverting `self[1].dimen` -- its inner
    -- FrameContainer -- and that frame sizes itself to its content, which comes
    -- out 145px against a 143px row because UnderlineContainer adds its line on
    -- top of the height it was given. Measured on the device:
    --
    --     row 1  y=117  invert h=145        rows are 143 apart
    --     row 2  y=260
    --
    -- So every tap paints 2px over the top of the NEXT row and leaves it there
    -- until something else repaints -- which reads as a stray frame across the
    -- corner of the row below, and is what the owner saw.
    --
    -- Setting the dimen up front works because FrameContainer:paintTo only
    -- fills w/h when there is no dimen yet, and thereafter updates x/y alone
    -- (framecontainer.lua:106-113). Normally that caching is a hazard; here it
    -- is exactly the hook needed to say "this rectangle, not the one you would
    -- measure".
    if self.item_dimen then
        for _idx, it in ipairs(self.item_group or {}) do
            local frame = type(it) == "table" and it[1]
            if frame and it.dimen then
                frame.dimen = Geom:new{
                    x = frame.dimen and frame.dimen.x or 0,
                    y = frame.dimen and frame.dimen.y or 0,
                    w = self.item_dimen.w,
                    h = it.dimen.h,
                }
            end
        end
    end
    return result
end

--------------------------------------------------------------------------------
-- Navigation
--------------------------------------------------------------------------------

--- Menu never updates self.title when the item table changes, so
-- Menu:onMenuSelect's `self.item_table.title = self.title` (menu.lua:1378)
-- stores the *root* title at every depth and stepping back shows the wrong
-- heading. Keeping self.title honest here fixes both directions at once, and
-- the header repaints because Menu.switchItemTable calls setTitle
-- (menu.lua:1191).
function KindleUISettings:switchItemTable(new_title, new_item_table, itemnumber, itemmatch, new_subtitle)
    if new_title then
        self.title = new_title
    end
    return Menu.switchItemTable(self, new_title, new_item_table, itemnumber, itemmatch, new_subtitle)
end

--- Push a page, using Menu's own stack so Menu:onClose (menu.lua:1458) pops it.
-- `raw` skips decorate() for lists this file built itself.
function KindleUISettings:drillDown(title, list, raw)
    self.item_table.title = self.title
    table.insert(self.item_table_stack, self.item_table)
    self:switchItemTable(title, raw and list or decorate(list, {
        glyph_col_w = self.glyph_col_w,
        glyph_face  = self.face_row_glyph,
    }))
end

--------------------------------------------------------------------------------
-- Search
--------------------------------------------------------------------------------

--- Every reachable setting, flattened, each with the path that leads to it.
--
-- Built on demand and cached for the life of the page. Walking the tree costs a
-- few milliseconds and the tree does not change while the page is open; caching
-- it means typing stays instant no matter how deep the menu goes.
--
-- The PATH is the point, not a by-product. The complaint that led to this was
-- not "I cannot find the lock screen" -- it was "I found it and could not
-- remember how". A result that jumps you there teaches nothing; one that says
-- Appearance > Lock screen is a route you can walk yourself next time.
function KindleUISettings:_searchIndex()
    if self._search_index then return self._search_index end
    local index = {}
    local seen = {}

    local function label(entry)
        if type(entry.text) == "string" then return entry.text end
        if entry.text_func then
            local ok, t = pcall(entry.text_func)
            if ok and type(t) == "string" then return t end
        end
        return nil
    end

    local function walk(list, trail, depth)
        -- Same guards indexById needs, and for the same reason: a plugin may
        -- point a sub_item_table back at an ancestor, and a stack overflow
        -- inside a search box is a worse outcome than a missing result.
        if depth > 12 or seen[list] then return end
        seen[list] = true
        for _idx, entry in ipairs(list) do
            if type(entry) == "table" then
                local text = label(entry)
                if text and text ~= "" then
                    local sub = entry.sub_item_table
                    if not sub and entry.sub_item_table_func then
                        local ok, t = pcall(entry.sub_item_table_func)
                        if ok then sub = t end
                    end
                    if type(sub) == "table" then
                        -- A branch is worth indexing too: "Appearance" is a
                        -- thing somebody searches for.
                        index[#index + 1] = { text = text, trail = trail, entry = entry, branch = true }
                        local next_trail = trail == "" and text or (trail .. "  \u{203A}  " .. text)
                        walk(sub, next_trail, depth + 1)
                    else
                        index[#index + 1] = { text = text, trail = trail, entry = entry }
                    end
                end
            end
        end
    end

    -- From the GROUPS, not from KOReader's raw tabs, so a result's path is the
    -- route through this page rather than through a menu the reader is being
    -- steered away from.
    for _i, spec in ipairs(groupSpecs()) do
        if not spec.needs or (self.menu_index and self.menu_index[spec.needs]) then
            local children = self.menu_index and collect(self.menu_index, spec.refs) or {}
            if #children > 0 then
                walk(children, spec.title, 1)
            end
        end
    end

    self._search_index = index
    return index
end

--- Case- and accent-insensitive contains.
--
-- Lua patterns are avoided entirely: a reader typing "(" or "%" into a search
-- box would otherwise get a pattern error rather than no results, and `plain`
-- find is both safer and faster.
local function matches(haystack, needle)
    return haystack:lower():find(needle:lower(), 1, true) ~= nil
end

function KindleUISettings:showSearch()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Search settings"),
        input = self._last_query or "",
        input_hint = _("lock screen"),
        buttons = { {
            { text = _("Cancel"), id = "close",
              callback = function() UIManager:close(dialog) end },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local q = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    UIManager:close(dialog)
                    if q == "" then return end
                    self._last_query = q
                    self:_showSearchResults(q)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KindleUISettings:_showSearchResults(query)
    local hits = {}
    for _i, item in ipairs(self:_searchIndex()) do
        if matches(item.text, query) then
            hits[#hits + 1] = item
        end
    end

    if #hits == 0 then
        self:drillDown(T(_("No match for \u{201C}%1\u{201D}"), query), { {
            text = _("Nothing found"),
            post_text = _("Try a shorter word, or a word from the setting's own name."),
        } }, true)
        return
    end

    -- Branches first: somebody searching "appearance" wants the page, not the
    -- seven rows inside it that happen to mention the word.
    table.sort(hits, function(a, b)
        if a.branch ~= b.branch then return a.branch == true end
        return a.text:lower() < b.text:lower()
    end)

    local rows = {}
    for _i, hit in ipairs(hits) do
        local copy = {}
        for k, v in pairs(hit.entry) do copy[k] = v end
        copy.kindleui_src = hit.entry
        -- The trail, in the place a second line goes. See _searchIndex.
        copy.post_text = hit.trail ~= "" and hit.trail or nil
        copy.bold = true
        local icon = hit.entry.id and MENU_ICONS[hit.entry.id]
        if icon then
            copy.state = CenterContainer:new{
                dimen = Geom:new{ w = self.glyph_col_w, h = Layout.y(REF.icon_h) },
                TextWidget:new{ text = icon, face = self.face_row_glyph, padding = 0 },
            }
        end
        rows[#rows + 1] = copy
    end

    self:drillDown(T(_("%1 for \u{201C}%2\u{201D}"), #hits, query), rows, true)
end

--- TouchMenu's close: it calls close_callback (touchmenu.lua:949-951). Callbacks
-- are handed `self` and a good few of them call `menu:closeMenu()`, so the name
-- has to exist here too or those settings would leave the screen open.
function KindleUISettings:closeMenu()
    return self:onCloseAllMenus()
end

--- TouchMenu:onMenuSelect (touchmenu.lua:856-905), branch for branch, over
-- Menu's plainer MenuItem. Menu:onMenuSelect (menu.lua:1363) only understands
-- sub_item_table and callback, which is why this is replaced wholesale rather
-- than extended.
function KindleUISettings:onMenuSelect(item)
    local src = item.kindleui_src or item

    -- TouchMenuItem refuses the tap before it ever reaches onMenuSelect
    -- (touchmenu.lua:171-177). MenuItem has no such check, so it goes here.
    local enabled = src.enabled
    if src.enabled_func then
        enabled = src.enabled_func()
    end
    if enabled == false then return true end

    if item.kindleui_all_settings then
        self:showAllSettings()
        return true
    end

    -- One of the grouping rows, or a tab on the All settings page. Either way
    -- the contents are KOReader's own entries and need decorating.
    if item.kindleui_sub then
        self:drillDown(item.kindleui_title or item.text, item.kindleui_sub)
        return true
    end

    -- touchmenu.lua:867-873
    if src.tap_input or src.tap_input_func then
        if not src.keep_menu_open then
            self:closeMenu()
        end
        -- InputContainer:onInput (inputcontainer.lua:365); Menu inherits it
        -- through FocusManager.
        self:onInput(src.tap_input or src.tap_input_func())
        return true
    end

    -- touchmenu.lua:875-886
    local sub_item_table = src.sub_item_table_func and src.sub_item_table_func() or src.sub_item_table
    if sub_item_table then
        if #sub_item_table > 0 then
            self:drillDown(src.text_func and src.text_func() or src.text, sub_item_table)
        end
        -- An empty submenu is a no-op upstream too; swallow the tap.
        return true
    end

    -- touchmenu.lua:889-903
    local callback = src.callback_func and src.callback_func() or src.callback
    if callback then
        callback(self)
        if src.checked ~= nil or src.checked_func then
            -- A check option stays on screen so the tick can be seen to move,
            -- unless the callback said it handles the repaint itself.
            if not (src.check_callback_updates_menu or src.check_callback_closes_menu) then
                self:updateItems()
            end
        elseif not src.keep_menu_open then
            self:closeMenu()
        end
    end
    return true
end

--- TouchMenu:onMenuHold (touchmenu.lua:907-940).
function KindleUISettings:onMenuHold(item)
    local src = item.kindleui_src or item

    if src.hold_input or src.hold_input_func then
        if src.hold_keep_menu_open == false then
            self:closeMenu()
        end
        self:onInput(src.hold_input or src.hold_input_func())
        return true
    end

    local hold_callback = src.hold_callback_func and src.hold_callback_func() or src.hold_callback
    if hold_callback then
        -- Hold defaults to keeping the menu open: it usually raises a
        -- ConfirmBox that can still be cancelled.
        if src.hold_keep_menu_open == false then
            self:closeMenu()
        end
        hold_callback(self, item)
        return true
    end

    local help_text = src.help_text_func and src.help_text_func(self) or src.help_text
    if help_text then
        UIManager:show(InfoMessage:new{ text = help_text })
    end
    return true
end

--[[
CAVEATS -- what MenuItem could not be made to do

  * checkmark_callback. TouchMenuItem reserves a strip at the left of the row
    for the checkbox and reports a tap there separately (touchmenu.lua:104,
    172-186), which onMenuSelect turns into checkmark_callback
    (touchmenu.lua:861). MenuItem draws no checkbox and hands onMenuSelect a
    fractional position instead (menu.lua:505-510), so there is no strip to
    aim at. One item in the whole tree uses it -- readerfont.lua:526, the
    per-family font override -- and it also has a sub_item_table, so the row
    still opens; only that shortcut gesture is gone.

  * radio versus checkbox. TouchMenuItem picks RadioMark or CheckMark from
    item.radio (touchmenu.lua:84-95). Here both render as the same tick in the
    right-hand column, so a one-of-many group looks like a set of independent
    checkboxes. Behaviour is unaffected -- the callbacks are KOReader's.

  * font_func. TouchMenuItem renders each font name in its own face
    (touchmenu.lua:110-125). MenuItem has no equivalent, so the font list is
    legible but not previewed.

  * A true second line. MenuItem collapses \n (menu.lua:210); the eight rows
    use post_text instead, which trails the title on the same line at the
    smaller mandatory size. `bold` also applies to the whole row rather than
    the title alone (menu.lua:196, 234, 243), so the value and the phrase come
    out heavier than the firmware draws them.

  * Row-separator inset. Kindle insets its hairlines by REF.row_inset (33px).
    MenuItem's underline spans content_width, fixed at Size.padding.fullscreen
    from each edge (menu.lua:101, 425-433) -- about 27px at PW5 density -- and
    that padding is not separately settable, because content_width is computed
    from it. Close, not exact.

  * D-pad focus on the header glyphs. generateVerticalLayout returns nothing,
    so ⋮ and ✕ are reachable by touch only. Back and close both also have key
    bindings through Menu (menu.lua:966), so nothing is unreachable.
]]

return KindleUISettings
