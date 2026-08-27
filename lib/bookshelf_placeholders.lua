--[[
Placeholder books — entries for books that belong in the library but are not on
this device yet.

WHAT THIS IS FOR

A sync plugin (xtreader is the one this was written against) knows about books
the account holds which this particular reader has never downloaded. Showing
them greyed out on the shelf, tappable to fetch, is the difference between "my
library" meaning the card and meaning the account.

Bookshelf must not depend on any of that. So this file is a registry and
nothing else: with no provider registered, `entriesFor` answers empty and every
listing behaves exactly as it did before. The sync plugin calls `setProvider`
when it loads; if it is absent, uninstalled, or fails to load, the shelf is
unchanged rather than broken.

WHY THE ENTRIES ARE lfs-SHAPED

`Repo.getAll` builds its listing from `lfs.dir` records — `{ name, fp, attr }` —
sorts THOSE, then turns them into shapes, paginates the shapes, and only then
hydrates the visible slice into book records. Placeholders enter as the same
shape at the same point, which is what makes them sort by title or author or
series alongside real books, land on the right page, and cost nothing on the
pages they are not on. Appending them to the finished list instead would put
every placeholder after every real book and break the page arithmetic — the
caller is told a total, and a total that does not match what it can fetch
paginates into a gap.

THE PSEUDO-PATH

A placeholder's `fp` is a path that does not exist on disk. That is deliberate
and it must stay obviously fake, because a lot of code downstream takes a
filepath and asks the filesystem about it. Every such call answers "no" for a
placeholder, which is the correct answer — there is no file. The one thing that
must NOT happen is a placeholder path colliding with a real one, so the marker
segment below is part of the filename rather than the directory: a directory
prefix would make `dirname` lie about which folder the book belongs to, and the
folder is the whole point of where it sorts.
]]

local Placeholders = {}

-- Marker embedded in the filename, before the extension. Chosen to be
-- something no real book file would carry, and to survive being read back out
-- of a path by `isPlaceholderPath` without a lookup table.
local MARK = ".xtph-"

-- The provider, or nil. One only: two sync plugins both claiming the shelf
-- would interleave two catalogues with no way for the user to tell which
-- entry came from where, and neither would own the download.
local _provider = nil

--- Register the source of placeholder entries, or nil to remove it.
--
-- `fn(path)` is called with an absolute directory path and must return an array
-- of plain tables, each describing one book that belongs in THAT directory and
-- is not on disk:
--
--     { id       = "bok_...",        -- opaque; handed back on tap
--       name     = "Muc Than Ky.epub",  -- the filename it will have once here
--       title    = "Mục Thần Ký",
--       authors  = "Nhĩ Muội",       -- string, or array of strings
--       series   = "Mục Thần Ký",
--       series_index = 1,
--       size     = 4210688 }         -- bytes, for the size column; optional
--
-- Only `name` is required. It is called during a directory listing, so it must
-- be cheap and must not block: read from a cache the provider already holds,
-- never from the network.
function Placeholders.setProvider(fn)
    _provider = (type(fn) == "function") and fn or nil
end

function Placeholders.hasProvider()
    return _provider ~= nil
end

--- True when `filepath` names a placeholder rather than a file on disk.
function Placeholders.isPlaceholderPath(filepath)
    return type(filepath) == "string" and filepath:find(MARK, 1, true) ~= nil
end

-- Build the pseudo-path for one entry. The id goes in the filename so a
-- placeholder can be identified from its path alone, which is what lets the
-- tap handler work from a book record that has been copied around and lost
-- every field but `filepath`.
local function pseudoPath(dir, entry)
    local name = tostring(entry.name)
    local stem, ext = name:match("^(.*)%.([^.]+)$")
    if not stem then stem, ext = name, "epub" end
    local sep = (dir:sub(-1) == "/") and "" or "/"
    return dir .. sep .. stem .. MARK .. tostring(entry.id or "x") .. "." .. ext
end

--- lfs-shaped entries for the placeholders belonging directly in `path`.
--
-- Returns an empty table when there is no provider, when it throws, or when it
-- answers with anything other than an array — a sync plugin having a bad day
-- must not take the file listing down with it.
function Placeholders.entriesFor(path)
    if not _provider or type(path) ~= "string" then return {} end
    local ok, list = pcall(_provider, path)
    if not ok then
        local ok_log, logger = pcall(require, "logger")
        if ok_log then
            logger.warn("[bookshelf] placeholder provider failed:", tostring(list))
        end
        return {}
    end
    if type(list) ~= "table" then return {} end

    local out = {}
    for _i, e in ipairs(list) do
        if type(e) == "table" and type(e.name) == "string" and e.name ~= "" then
            local fp = pseudoPath(path, e)
            -- `attr` mimics what lfs.attributes returns for a regular file,
            -- because the listing branches on `attr.mode` and the size column
            -- reads `attr.size`. `modification = 0` rather than os.time(): a
            -- placeholder has no date on this device, and stamping it with now
            -- would sort it to the top of "recently added" every single walk.
            out[#out + 1] = {
                name = e.name,
                fp   = fp,
                attr = { mode = "file", size = tonumber(e.size) or 0, modification = 0 },
                ph   = {
                    id           = e.id,
                    name         = e.name,
                    title        = e.title,
                    authors      = e.authors,
                    series       = e.series,
                    series_index = tonumber(e.series_index),
                    size         = tonumber(e.size) or 0,
                },
                -- Pre-set the fields the sort prefetch would otherwise ask BIM
                -- for. There is no BIM row for a file that was never here, so
                -- without these a placeholder sorts under its raw filename
                -- while everything around it sorts by title.
                doc_props = { display_title = e.title or e.name },
                authors   = type(e.authors) == "table"
                            and table.concat(e.authors, "; ") or e.authors,
                series       = e.series,
                series_index = tonumber(e.series_index),
            }
        end
    end
    return out
end

--- A book record for one placeholder shape, shaped like buildBookMeta's.
--
-- `is_placeholder` is what the renderer keys on. Everything else is either
-- carried from the provider or deliberately absent: no cover_bb (there is no
-- file to extract one from), no page_count, no progress. A placeholder that
-- reported progress would be claiming the user had read a book they have not
-- got.
function Placeholders.buildRecord(shape)
    local m = shape and shape.ph
    if not m then return nil end
    local authors = m.authors
    if type(authors) == "string" then authors = { authors } end
    return {
        filepath       = shape.fp,
        filename       = m.name,
        title          = m.title or m.name,
        author         = authors and authors[1] or nil,
        authors        = authors,
        series         = m.series,
        series_name    = m.series,
        series_num     = m.series_index,
        format         = (m.name:match("%.([^.]+)$") or ""):upper(),
        -- Identity for the tap handler, and the flag every renderer checks.
        is_placeholder = true,
        placeholder_id = m.id,
        -- Size is known from the manifest even though the bytes are not here,
        -- so the size column can say how big the download will be.
        size           = m.size,
    }
end

-- ── Folders ─────────────────────────────────────────────────────────────────
--
-- Books alone are not enough, and the gap is total rather than cosmetic.
--
-- `getAll` drops any directory with no book FILE under it: it asks
-- `findFirstBookIn` and `folderHasBooks`, both of which walk the real
-- filesystem. So a folder whose books are all still on the server is either
-- empty (dropped) or does not exist here at all (never listed), and in both
-- cases the placeholders inside it are unreachable -- there is no folder card
-- to tap. That is precisely the state a newly paired device is in, which would
-- have made the whole feature invisible on the one device that needs it most.

local _folder_provider = nil

--- Register the source of placeholder FOLDERS, or nil to remove it.
--
-- `fn(path)` returns an array of plain subfolder NAMES sitting directly under
-- `path` that contain catalogue books at ANY depth -- not just directly. A
-- folder three levels above a book still has to be listed, or the reader
-- cannot walk down to it.
--
-- Names, not paths: the listing builds the path itself, and a provider that
-- returned paths could return one that is not under `path` at all.
function Placeholders.setFolderProvider(fn)
    _folder_provider = (type(fn) == "function") and fn or nil
end

--- The set of placeholder subfolder names directly under `path`.
--
-- Returned as a SET rather than an array because both callers ask membership
-- questions of it -- "should this on-disk folder survive the emptiness check"
-- and "which of these have no directory on disk yet".
function Placeholders.folderNamesFor(path)
    if not _folder_provider or type(path) ~= "string" then return {} end
    local ok, list = pcall(_folder_provider, path)
    if not ok then
        local ok_log, logger = pcall(require, "logger")
        if ok_log then
            logger.warn("[bookshelf] placeholder folder provider failed:", tostring(list))
        end
        return {}
    end
    if type(list) ~= "table" then return {} end
    local set = {}
    for _i, name in ipairs(list) do
        if type(name) == "string" and name ~= "" and name ~= "." and name ~= ".."
                and not name:find("/", 1, true) then
            set[name] = true
        end
    end
    return set
end

-- ── Fetching ────────────────────────────────────────────────────────────────
--
-- Downloading belongs to whichever plugin supplied the entry: it owns the
-- account, the transport and the credentials. Bookshelf only knows that a tap
-- on a placeholder means "get this", so it asks and gets out of the way.

local _opener = nil

--- Register what to do when the reader taps a placeholder, or nil to remove it.
--
-- `fn(book, done)` receives the book record `buildRecord` produced (so
-- `placeholder_id` and `filepath` are both on it) and MUST call
-- `done(real_path_or_nil, err_message_or_nil)` exactly once, whenever the
-- download finishes or fails. It may return immediately and call `done` later
-- -- the caller shows its own progress and does not block.
function Placeholders.setOpener(fn)
    _opener = (type(fn) == "function") and fn or nil
end

function Placeholders.hasOpener()
    return _opener ~= nil
end

--- Ask the provider to fetch `book`. Returns false when nobody can.
--
-- `done` is guaranteed to be called at most once even if the opener calls it
-- twice: a second call arriving after the caller has already re-rendered would
-- open the book a second time on top of itself.
function Placeholders.fetch(book, done)
    if not _opener or type(book) ~= "table" then return false end
    local fired = false
    local function once(path, err)
        if fired then return end
        fired = true
        if type(done) == "function" then done(path, err) end
    end
    local ok, err = pcall(_opener, book, once)
    if not ok then
        local ok_log, logger = pcall(require, "logger")
        if ok_log then
            logger.warn("[bookshelf] placeholder opener failed:", tostring(err))
        end
        once(nil, tostring(err))
    end
    return true
end

Placeholders.MARK = MARK

return Placeholders
