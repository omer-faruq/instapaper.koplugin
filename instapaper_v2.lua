-- Instapaper API v2 helpers that need no network and no KOReader: request
-- paths for the plugin's folder values, and conversion of v2 responses into
-- the bookmark shape the rest of the plugin already works with (the v1 one).
--
-- KOReader's JSON decoder turns `null` into a sentinel rather than nil, so
-- every field read here goes through a type check.

local V2 = {}

local function str(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

local function num(v)
    if type(v) == "number" then return v end
    return nil
end

V2.str = str
V2.num = num

-- RFC 3986 percent-encoding for query strings.
local function percent_encode(s)
    return (tostring(s):gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Build "?a=1&b=2" (sorted, so requests are stable in logs). Empty for no params.
function V2.buildQuery(params)
    if type(params) ~= "table" then return "" end
    local keys = {}
    for k, v in pairs(params) do
        if v ~= nil then keys[#keys + 1] = k end
    end
    if #keys == 0 then return "" end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = percent_encode(k) .. "=" .. percent_encode(params[k])
    end
    return "?" .. table.concat(parts, "&")
end

-- The plugin names lists the v1 way: "unread", "starred", "archive", or a
-- numeric folder id. Returns the GET /bookmarks query params for one of them.
function V2.listParams(folder_id)
    if folder_id == nil or folder_id == "unread" then
        return { section = "home" }
    elseif folder_id == "starred" then
        return { section = "liked" }
    elseif folder_id == "archive" then
        return { section = "archive" }
    end
    return { section = "folder", folder_id = tostring(folder_id) }
end

-- v2 Bookmark -> the v1-shaped table used everywhere else in the plugin.
-- The v2-only fields (author, image, pubtime) ride along for metadata.
function V2.normalizeBookmark(b)
    if type(b) ~= "table" or num(b.id) == nil then return nil end
    local progress = type(b.progress) == "table" and b.progress or {}
    return {
        type               = "bookmark",
        bookmark_id        = b.id,
        url                = str(b.url),
        title              = str(b.title),
        description        = str(b.description),
        time               = num(b.time),
        progress           = num(progress.percentage) or 0,
        progress_timestamp = num(progress.timestamp) or 0,
        starred            = (b.liked == true) and "1" or "0",
        author             = str(b.author),
        image              = str(b.image),
        pubtime            = num(b.pubtime),
        folder_id          = num(b.folder_id),
    }
end

-- Decoded GET /bookmarks response -> list of normalized bookmarks, plus the
-- raw count of entries on the page (bookmarks + deleted ids) for paging.
function V2.parseBookmarkList(data)
    local bookmarks = {}
    local page_count = 0
    if type(data) ~= "table" then return bookmarks, page_count end
    if type(data.bookmarks) == "table" then
        for _, item in ipairs(data.bookmarks) do
            page_count = page_count + 1
            local bm = V2.normalizeBookmark(item)
            if bm then bookmarks[#bookmarks + 1] = bm end
        end
    end
    if type(data.deleted_ids) == "table" then
        page_count = page_count + #data.deleted_ids
    end
    return bookmarks, page_count, num(data.total)
end

-- Decoded GET /folders response -> {text, value} menu entries.
function V2.parseFolders(data)
    local folders = {}
    local list = type(data) == "table" and data.folders
    if type(list) ~= "table" then return folders end
    for _, item in ipairs(list) do
        if type(item) == "table" and num(item.id) then
            folders[#folders + 1] = {
                text  = str(item.title) or str(item.slug) or tostring(item.id),
                value = tostring(item.id),
            }
        end
    end
    return folders
end

local function escText(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function escAttr(s)
    return (escText(s):gsub('"', "&quot;"))
end

-- The parse endpoint returns only the article body. Wrap it into the kind of
-- full document v1's get_text served, so the HTML/EPUB code downstream keeps
-- working unchanged: <title>, and the byline as <meta name="author">, which
-- InstapaperEpub.extractAuthor already reads.
-- Returns html, author (nil when the page gave none), or nil when there is no body.
function V2.buildArticleHtml(parsed, bookmark)
    if type(parsed) ~= "table" then return nil end
    local content  = type(parsed.content)  == "table" and parsed.content  or {}
    local metadata = type(parsed.metadata) == "table" and parsed.metadata or {}
    local body = str(content.body)
    if not body then return nil end

    bookmark = bookmark or {}
    local title = bookmark.title or str(metadata.title)
    local author_tbl = type(metadata.author) == "table" and metadata.author or {}
    local author = str(author_tbl.name) or bookmark.author
    local dir = content.direction == "rtl" and ' dir="rtl"' or ""

    local head = { '<meta charset="utf-8"/>' }
    if title then
        head[#head + 1] = "<title>" .. escText(title) .. "</title>"
    end
    if author then
        head[#head + 1] = '<meta name="author" content="' .. escAttr(author) .. '"/>'
    end
    return "<!DOCTYPE html>\n<html" .. dir .. "><head>" .. table.concat(head)
        .. "</head><body" .. dir .. ">\n" .. body .. "\n</body></html>", author
end

-- Human-readable message out of a v2 error body {error = {code, message}}.
function V2.errorMessage(data)
    local err = type(data) == "table" and data.error
    if type(err) == "table" then
        return str(err.message)
    end
    return nil
end

return V2
