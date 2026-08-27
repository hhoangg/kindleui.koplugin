-- bookshelf_text_segments.lua
-- UTF-8 aware label segmentation for mixed text + icon labels.
--
-- Ordinary Unicode text (Latin-1, CJK, combining accents, punctuation) stays
-- in the text class so it can be bolded. Icon-like codepoints (Nerd Font PUA,
-- dingbats, emoji ranges) are isolated so renderers can leave them regular.

local Utf8Proc = require("ffi/utf8proc")
local util     = require("util")

local Segments = {}

-- UTF-8-aware uppercase. Lua's string.upper / :upper() only touches
-- ASCII bytes, so accented characters pass through unchanged --
-- "séries" uppercases to "SéRIES" instead of "SÉRIES" (issue #81).
-- Utf8Proc.uppercase_dumb uppercases each codepoint correctly;
-- util.fixUtf8 guards against malformed input (the same pattern
-- KOReader's util.lower uses for lowercasing).
function Segments.upper(str)
    if not str or str == "" then return str end
    return Utf8Proc.uppercase_dumb(util.fixUtf8(str, "?"))
end

local function isContinuation(byte)
    return byte and byte >= 0x80 and byte < 0xC0
end

local function decodeAt(str, index)
    local b1 = string.byte(str, index)
    if not b1 then return nil end
    if b1 < 0x80 then
        return 1, b1, true
    end
    if b1 < 0xC0 then
        return 1, b1, false
    end

    local b2 = string.byte(str, index + 1)
    if b1 < 0xE0 then
        if not isContinuation(b2) then return 1, b1, false end
        return 2, (b1 - 0xC0) * 0x40 + (b2 - 0x80), true
    end

    local b3 = string.byte(str, index + 2)
    if b1 < 0xF0 then
        if not isContinuation(b2) or not isContinuation(b3) then
            return 1, b1, false
        end
        return 3,
            (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80),
            true
    end

    local b4 = string.byte(str, index + 3)
    if b1 < 0xF8 then
        if not isContinuation(b2) or not isContinuation(b3) or not isContinuation(b4) then
            return 1, b1, false
        end
        return 4,
            (b1 - 0xF0) * 0x40000
                + (b2 - 0x80) * 0x1000
                + (b3 - 0x80) * 0x40
                + (b4 - 0x80),
            true
    end

    return 1, b1, false
end

function Segments.isIconCodepoint(cp)
    return (cp >= 0xE000 and cp <= 0xF8FF)       -- BMP private use: Nerd Font / MDI
        or (cp >= 0xF0000 and cp <= 0xFFFFD)     -- supplementary private use A
        or (cp >= 0x100000 and cp <= 0x10FFFD)   -- supplementary private use B
        or (cp >= 0x2600 and cp <= 0x27BF)       -- misc symbols / dingbats
        or (cp >= 0x1F000 and cp <= 0x1FAFF)     -- emoji and pictographs
end

function Segments.labelSegments(label)
    label = label or ""
    local segments = {}
    local current = nil
    local i = 1

    while i <= #label do
        local chunk_len, codepoint, valid = decodeAt(label, i)
        chunk_len = chunk_len or 1
        local class = (not valid or Segments.isIconCodepoint(codepoint)) and "icon" or "text"
        local chunk = label:sub(i, i + chunk_len - 1)

        if current and current.class == class then
            current.text = current.text .. chunk
        else
            current = { class = class, text = chunk }
            segments[#segments + 1] = current
        end

        i = i + chunk_len
    end

    return segments
end

return Segments
