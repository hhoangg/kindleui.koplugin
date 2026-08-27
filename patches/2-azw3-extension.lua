--[[
Let KOReader open `.azw3` without renaming it.

AZW3 *is* mobi8, and KOReader already knows how to read mobi8 -- credocument
registers `azw` against `application/vnd.amazon.mobi8-ebook`
(credocument.lua:1586). It just never registers the `azw3` extension, and the
registry dispatches on extension, so a file whose only difference is four
characters in its name is unopenable.

Verified on the target device before writing this: renaming one of these files
to `.azw` opens it and renders it correctly. So there is nothing to convert and
nothing to reimplement; there is a missing line in a table.

WHAT THIS DOES NOT FIX

The table of contents. crengine does not build a ToC from KF8's own NCX, so an
AZW3 opened this way has no chapter list, and that is unchanged by registering
the extension -- it was already true of the renamed file.

The fix for that is KOReader's own **Alternative table of contents**
(navi -> Settings -> Alternative table of contents), which builds the list from
the document's `<h1>`-`<h6>` headings instead. It is offered for any CreDocument,
so it is offered for these. Where a book has no usable headings, converting it
to EPUB really is the only route left.

`weight = 90` matches what credocument gives its own mobi-family entries, so
this sits alongside them rather than outranking anything.
]]

local logger = require("logger")

local ok, err = pcall(function()
    local DocumentRegistry = require("document/documentregistry")
    -- Requiring credocument is what runs its own registration block, so this
    -- has to happen first or the canonical-extension bookkeeping in
    -- addProvider (documentregistry.lua:40-41) would see azw3 before azw.
    local CreDocument = require("document/credocument")

    if DocumentRegistry.filetype_provider and DocumentRegistry.filetype_provider["azw3"] then
        return -- already known, here or upstream
    end
    DocumentRegistry:addProvider("azw3", "application/vnd.amazon.mobi8-ebook", CreDocument, 90)
end)

if ok then
    logger.info("kindle-jb: azw3 extension registered")
else
    -- A reader who cannot open one file format is a small loss; a patch that
    -- raises during startup takes the whole reader with it.
    logger.warn("kindle-jb: could not register azw3:", tostring(err))
end
