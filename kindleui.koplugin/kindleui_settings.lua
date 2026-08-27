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
local Theme = require("kindleui_theme")
local logger = require("logger")
local _ = require("gettext")
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

    local row = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = margin } }

    -- Kindle's sub-pages put a back chevron left of the title. Without one the
    -- only ways back would be a swipe south (Menu:onSwipe, menu.lua:1490) or a
    -- hardware key, neither of which is visible.
    if self.is_nested and self.is_nested() then
        table.insert(row, Theme.Tappable:new{
            on_tap = self.on_back,
            TextWidget:new{ text = GLYPH.chev_left, face = self.face_glyph, padding = 0 },
        })
        table.insert(row, HorizontalSpan:new{ width = math.floor(gap / 2) })
    end

    local title = TextWidget:new{
        text = self.title or "",
        face = self.face_title,
        padding = 0,
        -- Leave room for both glyphs plus their gaps before truncating.
        max_width = screen_w - 2 * margin - 4 * Layout.x(REF.icon_h),
    }
    table.insert(row, title)

    local overflow = Theme.Tappable:new{
        on_tap = self.on_overflow,
        TextWidget:new{ text = GLYPH.ellipsis_v, face = self.face_glyph, padding = 0 },
    }
    local close = Theme.Tappable:new{
        on_tap = self.on_close,
        TextWidget:new{ text = GLYPH.close, face = self.face_glyph, padding = 0 },
    }

    -- Flexible space: title hard left, the two glyphs hard right.
    local used = margin * 2 + title:getSize().w + overflow:getSize().w + close:getSize().w + gap
    for _idx, widget in ipairs(row) do
        if widget ~= title then used = used + widget:getSize().w end
    end
    used = used - margin -- the leading span is already counted in margin * 2
    local flex = screen_w - used
    if flex < gap then flex = gap end

    table.insert(row, HorizontalSpan:new{ width = flex })
    table.insert(row, overflow)
    table.insert(row, HorizontalSpan:new{ width = gap })
    table.insert(row, close)
    table.insert(row, HorizontalSpan:new{ width = margin })

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
local function decorate(list)
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

            if src.checked_func or src.checked ~= nil then
                -- MenuItem draws no checkbox. A tick in the right-hand
                -- "mandatory" column is the only place check state can go, and
                -- it has to be a *function* (menu.lua:187 prefers
                -- mandatory_func) so that toggling an option and repainting
                -- shows the new state instead of the state at build time.
                copy.mandatory_func = function()
                    local base = src.mandatory_func and src.mandatory_func() or src.mandatory
                    local checked = src.checked_func and src.checked_func() or src.checked
                    if checked then
                        return base and (base .. " " .. GLYPH.check) or GLYPH.check
                    end
                    return base
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
                -- getCurrentNetwork is likewise (manager.lua:195, Kindle at
                -- device/kindle/device.lua:513) and answers { ssid = ... }.
                if not NetworkMgr:isWifiOn() then return _("Off") end
                local nw = NetworkMgr:getCurrentNetwork()
                return nw and nw.ssid or _("On")
            end,
        },
        {
            glyph = GLYPH.mobile,
            title = _("Device options"),
            refs = { "language", "device/*", "navigation/*" },
        },
        {
            glyph = GLYPH.sun,
            title = _("Screen and brightness"),
            refs = { "frontlight", "night_mode", "screen/*" },
        },
        {
            glyph = GLYPH.font,
            title = _("Reading"),
            sub = _("Font, layout, page turns"),
            -- Everything up to taps_and_gestures is reader-only; the file
            -- manager keeps only the last one, which is why it is here.
            refs = {
                "change_font", "typography", "set_render_style", "style_tweaks",
                "document_settings", "page_overlap", "highlight_options",
                "taps_and_gestures/*",
            },
        },
        {
            glyph = GLYPH.book,
            title = _("Home and Library"),
            refs = {
                "filebrowser_settings", "filemanager_display_mode", "show_filter",
                "sort_by", "start_with", "history", "favorites", "collections",
                "bookmark_browser", "document/*",
                -- bookshelf.koplugin registers a whole TAB of its own
                -- (`menu_items.bookshelf_tab`), and a tab is not something this
                -- page can show. Without naming its entries here they were
                -- reachable only from KOReader's own menu, so a reader who used
                -- this page as their settings screen simply could not find how
                -- to configure their home screen. `collect` skips a ref it
                -- cannot resolve, so these cost nothing when the plugin is
                -- absent.
                "bookshelf_settings", "bookshelf_shelf_size", "bookshelf_shelf_tabs",
                "bookshelf_hardcover", "bookshelf_updates", "bookshelf_about",
            },
        },
        {
            glyph = GLYPH.chart,
            title = _("Reading Insights"),
            -- readinginsights registers this id with no sorting_hint
            -- (readinginsights.koplugin/main.lua:916), so MenuSorter treats it
            -- as an orphan and gives it the "NEW: " prefix
            -- (menusorter.lua:168) -- which is precisely why the row's own
            -- title is written here rather than taken from the entry.
            needs = "reading_insights_popup",
            refs = { "reading_insights_popup/*" },
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
    return Menu.updateItems(self, select_number, no_recalculate_dimen)
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
    self:switchItemTable(title, raw and list or decorate(list))
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

    -- One of the eight grouping rows, or a tab on the overflow page. Either way
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
