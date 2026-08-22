local Version = require("version")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local urlmod = require("socket.url")
local util = require("util")

local InstapaperEpub = {}

--------------------------------------------------------------------
-- MIME type helpers
--------------------------------------------------------------------

local ext_to_mimetype = {
    png  = "image/png",
    jpg  = "image/jpeg",
    jpeg = "image/jpeg",
    gif  = "image/gif",
    svg  = "image/svg+xml",
    webp = "image/webp",
    bmp  = "image/bmp",
}

local mimetype_to_ext = {
    ["image/png"]     = "png",
    ["image/jpeg"]    = "jpg",
    ["image/gif"]     = "gif",
    ["image/svg+xml"] = "svg",
    ["image/webp"]    = "webp",
    ["image/bmp"]     = "bmp",
}

--------------------------------------------------------------------
-- Image download helpers
--------------------------------------------------------------------

local function resolveUrl(src, base_url)
    if not src or src == "" then return nil end
    local scheme = src:match("^([%w][%w%+%-.]*):")
    if scheme then
        -- Only http(s) is downloadable; reject data:, file:, mailto:, ftp:, etc.
        -- (socket.http has no handler for other schemes and errors uncaught).
        scheme = scheme:lower()
        if scheme == "http" or scheme == "https" then return src end
        return nil
    end
    if not base_url or base_url == "" then return nil end
    return urlmod.absolute(base_url, src)
end

local function downloadImageToMemory(url)
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local pok, ok, code, headers = pcall(http.request, {
        url     = url,
        method  = "GET",
        sink    = ltn12.sink.table(sink),
        headers = {
            ["Accept-Encoding"] = "identity",
            ["User-Agent"]      = "KOReader Instapaper",
        },
    })
    socketutil:reset_timeout()
    if not pok then
        logger.info("InstapaperEpub: image download errored", url, ok)
        return nil, nil
    end
    if not ok or tostring(code):sub(1, 1) ~= "2" then
        logger.info("InstapaperEpub: image download failed", url, code)
        return nil, nil
    end
    local content = table.concat(sink)
    local ct = headers and headers["content-type"] or ""
    ct = ct:match("^([^;]+)") or ct
    return content, ct:lower()
end

local function xmlEsc(s)
    return (s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

local function isTinyImage(tag)
    local function getAttr(t, attr)
        return t:match(attr .. '%s*=%s*"([^"]*)"')
            or t:match(attr .. "%s*=%s*'([^']*)'")
    end
    local w = tonumber(getAttr(tag, "width"))
    local h = tonumber(getAttr(tag, "height"))
    if w and w <= 1 and h and h <= 1 then return true end
    return false
end

--------------------------------------------------------------------
-- Metadata helpers
--
-- Everything below derives metadata from bytes we have already downloaded
-- (the article HTML and its images). Nothing here ever issues an extra HTTP
-- request: Instapaper's API carries no author, excerpt or thumbnail field,
-- and fetching the original page just to look for them would cost one full
-- page load per article on a device that is often on slow/metered WiFi.
--------------------------------------------------------------------

local function collapseSpaces(s)
    if not s or s == "" then return "" end
    s = s:gsub("\194\160", " ") -- UTF-8 no-break space, not matched by %s
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function stripTags(s)
    return util.htmlEntitiesToUtf8((s or ""):gsub("<[^>]*>", " "))
end

-- Truncate to at most max_chars UTF-8 characters, backing off to a word
-- boundary so the excerpt does not end mid-word.
local function truncateText(text, max_chars)
    local ok, chars = pcall(util.splitToChars, text)
    if not ok or type(chars) ~= "table" or #chars <= max_chars then
        return text
    end
    local truncated = table.concat(chars, "", 1, max_chars)
    local cut = truncated:match("^(.*)%s%S*$")
    if cut and #cut >= #truncated / 2 then
        truncated = cut
    end
    -- Only ASCII punctuation here: %p would risk slicing a UTF-8 sequence.
    truncated = truncated:gsub("[%s,;:%.%-]+$", "")
    return truncated .. "\u{2026}"
end

-- Build a short plain-text excerpt from the article body we already have.
-- Instapaper's own "description" field is user-supplied (the bookmarklet's
-- text selection, or a source tweet) and is empty for most articles, so
-- without this the book description stays blank.
function InstapaperEpub.buildExcerpt(html, max_chars)
    if type(html) ~= "string" or html == "" then return nil end
    local body = html
    local _, body_open_end = body:find("<body[^>]*>")
    local body_close_start = body:find("</body>")
    if body_open_end and body_close_start and body_close_start > body_open_end then
        body = body:sub(body_open_end + 1, body_close_start - 1)
    end
    -- Headings and figure captions are labels, not prose: they would make the
    -- excerpt read as a repetition of the title.
    body = body:gsub("<[hH][1-6][^>]*>[%s%S]-</[hH][1-6]%s*>", " ")
    body = body:gsub("<figcaption[^>]*>[%s%S]-</figcaption>", " ")
    body = body:gsub("<figure[^>]*>[%s%S]-</figure>", " ")
    local ok, text = pcall(util.htmlToPlainText, body)
    if not ok or type(text) ~= "string" then return nil end
    text = collapseSpaces(text)
    if #text < 40 then return nil end
    return util.fixUtf8(truncateText(text, max_chars or 320), "")
end

-- Reject anything that does not read like a person's name. Bylines are the
-- one piece of metadata we can only guess at, so a wrong guess (a date, a
-- section name, a URL) is worse than no author at all.
local function sanitizeAuthor(raw)
    local s = collapseSpaces(stripTags(raw))
    s = s:gsub("^[Bb][Yy][%s:]+", ""):gsub("^[Ww]ritten%s+[Bb][Yy][%s:]+", "")
    s = collapseSpaces(s)
    if s == "" or #s > 80 then return nil end
    if s:find("http", 1, true) or s:find("@", 1, true) or s:find("|", 1, true) then return nil end
    if s:find("%d%d%d%d") then return nil end -- a year: this is a date line
    local words = 0
    for _ in s:gmatch("%S+") do words = words + 1 end
    if words > 6 then return nil end
    return util.fixUtf8(s, "")
end

-- Best-effort byline, read only from markup Instapaper's text view happens to
-- keep. Usually returns nil, and that is fine: the site name below is always
-- available, and guessing harder would mean downloading the original page.
function InstapaperEpub.extractAuthor(html)
    if type(html) ~= "string" or html == "" then return nil end
    local head = html:sub(1, 20000)
    for tag in head:gmatch("<[Mm][Ee][Tt][Aa][^>]*>") do
        local key = tag:match('[Nn]ame%s*=%s*"([^"]*)"') or tag:match("[Nn]ame%s*=%s*'([^']*)'")
                 or tag:match('[Pp]roperty%s*=%s*"([^"]*)"') or tag:match("[Pp]roperty%s*=%s*'([^']*)'")
        if key and (key:lower() == "author" or key:lower() == "article:author") then
            local content = tag:match('[Cc]ontent%s*=%s*"([^"]*)"')
                         or tag:match("[Cc]ontent%s*=%s*'([^']*)'")
            local author = content and sanitizeAuthor(content)
            if author then return author end
        end
    end
    -- Explicitly marked-up bylines only (rel/itemprop). Class-name guessing
    -- ("byline", "author") matches too much boilerplate to be trustworthy.
    for _, pattern in ipairs({
        '<%a+[^>]-itemprop%s*=%s*["\']author["\'][^>]*>([%s%S]-)</',
        '<%a+[^>]-rel%s*=%s*["\']author["\'][^>]*>([%s%S]-)</',
    }) do
        local inner = head:match(pattern)
        local author = inner and sanitizeAuthor(inner)
        if author then return author end
    end
    return nil
end

-- Site name, e.g. "https://www.example.com/a/b.html" -> "example.com".
function InstapaperEpub.deriveSiteName(url)
    if not url or url == "" then return nil end
    local domain = url:match("^https?://([^/]+)")
    if not domain then return nil end
    domain = domain:gsub("^www%.", "")
    if domain == "" then return nil end
    return domain
end

--------------------------------------------------------------------
-- Cover selection
--------------------------------------------------------------------

-- Read pixel dimensions straight out of the bytes already in memory.
-- Returns width, height, or nil for formats we cannot parse cheaply.
local function imageDimensions(data, mimetype)
    if type(data) ~= "string" then return nil end
    if mimetype == "image/png" and #data >= 24 and data:sub(2, 4) == "PNG" then
        local w1, w2, w3, w4, h1, h2, h3, h4 = data:byte(17, 24)
        return ((w1 * 256 + w2) * 256 + w3) * 256 + w4,
               ((h1 * 256 + h2) * 256 + h3) * 256 + h4
    end
    if mimetype == "image/gif" and #data >= 10 and data:sub(1, 3) == "GIF" then
        local w1, w2, h1, h2 = data:byte(7, 10)
        return w2 * 256 + w1, h2 * 256 + h1 -- little-endian
    end
    if mimetype == "image/jpeg" and #data >= 4
            and data:byte(1) == 0xFF and data:byte(2) == 0xD8 then
        local pos = 3
        while pos + 8 <= #data do
            if data:byte(pos) ~= 0xFF then
                pos = pos + 1
            else
                local marker = data:byte(pos + 1)
                -- Padding and standalone markers carry no length field.
                if marker == 0xFF or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD9) then
                    pos = pos + 2
                else
                    local len = data:byte(pos + 2) * 256 + data:byte(pos + 3)
                    if len < 2 then return nil end
                    -- SOF0..SOF15, minus DHT (C4), JPG (C8) and DAC (CC).
                    if marker >= 0xC0 and marker <= 0xCF
                            and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                        local h1, h2, w1, w2 = data:byte(pos + 5, pos + 8)
                        return w1 * 256 + w2, h1 * 256 + h2
                    end
                    pos = pos + 2 + len
                end
            end
        end
    end
    return nil
end

-- Use the article's lead image as the EPUB cover. Only images already
-- downloaded for the body are considered, so this costs no extra traffic.
local function pickCoverIndex(images)
    for i, img in ipairs(images) do
        if img.mimetype ~= "image/svg+xml" then
            local w, h = imageDimensions(img.content, img.mimetype)
            if w and h then
                local ratio = h > 0 and (w / h) or 0
                -- Big enough to be an illustration, and not a banner strip.
                if w >= 300 and h >= 200 and ratio >= 0.4 and ratio <= 3.0 then
                    return i
                end
            elseif #img.content >= 30000 then
                -- Format we cannot measure (webp...): weight stands in for size.
                return i
            end
        end
    end
    return nil
end

--------------------------------------------------------------------
-- Chapters from heading levels
--------------------------------------------------------------------

-- Give every heading an id and collect it as a TOC entry, so the EPUB carries
-- a real navMap instead of a single "whole article" entry. One extra gsub over
-- a body that already goes through a dozen of them.
local function extractHeadings(body)
    local entries = {}
    local counter = 0
    local rewritten = body:gsub("<[hH]([1-6])([^>]*)>([%s%S]-)</[hH]%1%s*>",
        function(level, attrs, inner)
            local text = collapseSpaces(stripTags(inner))
            if text == "" then return nil end -- untouched: nothing to label it with
            local id = attrs:match('[%s]id%s*=%s*"([^"]*)"')
                    or attrs:match("[%s]id%s*=%s*'([^']*)'")
            if not id or id == "" then
                counter = counter + 1
                id = string.format("toc%03d", counter)
                attrs = attrs .. string.format(' id="%s"', id)
            end
            table.insert(entries, { level = tonumber(level), title = text, id = id })
            return "<h" .. level .. attrs .. ">" .. inner .. "</h" .. level .. ">"
        end)
    return rewritten, entries
end

-- Map the heading levels actually used onto consecutive depths, so an article
-- built out of <h2>/<h3> still starts at TOC depth 1.
local function normalizeLevels(entries)
    local used = {}
    for _, e in ipairs(entries) do used[e.level] = true end
    local sorted = {}
    for level in pairs(used) do table.insert(sorted, level) end
    table.sort(sorted)
    local depth_of = {}
    for i, level in ipairs(sorted) do depth_of[level] = i end
    local max_depth = 0
    for _, e in ipairs(entries) do
        e.depth = depth_of[e.level]
        if e.depth > max_depth then max_depth = e.depth end
    end
    return max_depth
end

local function buildNavMap(entries)
    local parts = {}
    local play = 0
    local open = 0 -- navPoints currently left open
    local function indent(n) return string.rep("  ", n + 2) end
    for _, e in ipairs(entries) do
        -- Never skip a level: <h1> followed by <h3> must not produce a hole.
        local depth = math.min(e.depth, open + 1)
        while open >= depth do
            table.insert(parts, indent(open - 1) .. "</navPoint>\n")
            open = open - 1
        end
        play = play + 1
        local pad = indent(depth - 1)
        table.insert(parts, string.format(
            '%s<navPoint id="navpoint-%d" playOrder="%d">\n'
            .. '%s  <navLabel><text>%s</text></navLabel>\n'
            .. '%s  <content src="content.xhtml#%s"/>\n',
            pad, play, play, pad, xmlEsc(e.title), pad, xmlEsc(e.id)))
        open = depth
    end
    while open > 0 do
        table.insert(parts, indent(open - 1) .. "</navPoint>\n")
        open = open - 1
    end
    return table.concat(parts)
end

--------------------------------------------------------------------
-- HTML → EPUB image rewriting
--------------------------------------------------------------------

-- Rewrites <img> src attributes to local paths and returns image data table.
-- Returns rewritten_html, images_table
-- images_table entries: { imgpath, content, mimetype, no_compress }
local function rewriteImages(html, base_url)
    local images = {}
    local seen = {}
    local imagenum = 1

    local function processTag(img_tag)
        if isTinyImage(img_tag) then return "" end

        local src = img_tag:match('[%s<][Ss][Rr][Cc]%s*=%s*"([^"]*)"')
                 or img_tag:match("[%s<][Ss][Rr][Cc]%s*=%s*'([^']*)'")
        -- fallback: data-src lazy load
        if not src or src == "" then
            src = img_tag:match('data%-src%s*=%s*"([^"]*)"')
               or img_tag:match("data%-src%s*=%s*'([^']*)'")
        end
        if not src or src == "" then return "" end

        -- Decode HTML entities in URL (&amp; -> &)
        src = src:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")

        local abs_src = resolveUrl(src, base_url)
        if not abs_src then return "" end

        if seen[abs_src] then
            local alt = img_tag:match('[Aa][Ll][Tt]%s*=%s*"([^"]*)"') or ""
            return '<img src="' .. seen[abs_src] .. '" alt="' .. alt .. '"/>'
        end

        -- Extension of the last path segment only: matching the first dot in
        -- the whole URL turns "//www.example.com/a.jpg" into ext "example".
        local url_path = abs_src:match("^[^?#]*") or abs_src
        local ext = (url_path:match("%.([%w]+)$") or ""):lower()

        local imgid = string.format("img%05d", imagenum)
        imagenum = imagenum + 1

        local content, ct = downloadImageToMemory(abs_src)
        if not content then return img_tag end

        -- Resolve extension from content-type if missing
        if ext == "" and ct and ct ~= "" then
            ext = mimetype_to_ext[ct] or ""
        end

        local filename = ext ~= "" and (imgid .. "." .. ext) or imgid
        local imgpath  = "images/" .. filename
        local mimetype = ext_to_mimetype[ext] or (ct ~= "" and ct or "application/octet-stream")
        local no_compress = (mimetype ~= "image/svg+xml")

        seen[abs_src] = imgpath
        table.insert(images, {
            imgpath     = imgpath,
            content     = content,
            mimetype    = mimetype,
            no_compress = no_compress,
        })

        -- Build a clean self-closing XHTML img tag
        local alt = img_tag:match('[Aa][Ll][Tt]%s*=%s*"([^"]*)"') or ""
        local new_tag = '<img src="' .. imgpath .. '" alt="' .. alt .. '"/>'
        return new_tag
    end

    -- Match both <img ...> and <img .../> forms
    local rewritten = html:gsub("(<%s*[Ii][Mm][Gg][^>]*/?%s*>)", processTag)
    return rewritten, images
end

--------------------------------------------------------------------
-- Download path helpers
--------------------------------------------------------------------

-- Build a download path named after the article title. Instapaper's numeric
-- bookmark_id is only used as a fallback, so that untitled articles still get
-- distinct filenames instead of all collapsing onto the same one.
-- Articles sharing a title share a filename: re-downloading overwrites.
function InstapaperEpub.buildFilePath(download_dir, bookmark, ext)
    local safe_title = (bookmark.title or "")
        :gsub("[/\\%?%%%*%:%|%\"%<%>]", "_")
        :gsub("[%z\1-\31\127]", " ")
        :sub(1, 100)
    safe_title = util.fixUtf8(safe_title, "_")
    -- Leading/trailing spaces and trailing dots are illegal or silently
    -- stripped on FAT/NTFS, which the usual USB/SD workflows run on.
    safe_title = safe_title:gsub("^%s+", ""):gsub("[%s%.]+$", "")
    if safe_title == "" then
        safe_title = tostring(bookmark.bookmark_id or "article")
    end
    return download_dir .. "/" .. safe_title .. "." .. ext
end

function InstapaperEpub.buildEpubPath(download_dir, bookmark)
    return InstapaperEpub.buildFilePath(download_dir, bookmark, "epub")
end

--------------------------------------------------------------------
-- Main EPUB creation
--------------------------------------------------------------------

-- Create a standalone EPUB from Instapaper HTML.
-- Returns filepath on success, nil + error string on failure.
function InstapaperEpub.createEpub(bookmark, html, download_dir, include_images)
    if type(html) ~= "string" or html == "" then
        return nil, "empty_html"
    end

    local epub_path = InstapaperEpub.buildEpubPath(download_dir, bookmark)
    local article_url = bookmark.url or ""
    local title = bookmark.title or "Untitled"
    local escaped_title = title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local mtime = os.time()

    -- Strip DOCTYPE, xml declarations, and HTML comments (newline-safe with [%s%S])
    html = html:gsub("<!%-%-%[%s%S]-%-%->", "")
    html = html:gsub("<!DOCTYPE[^>]*>", "")
    html = html:gsub("<%?xml[%s%S]-%?>", "")

    -- Remove script and style blocks (multiline-safe)
    html = html:gsub("<script[^>]*>[%s%S]-</script>", "")
    html = html:gsub("<style[^>]*>[%s%S]-</style>", "")

    -- Metadata we can only read off the original markup, before it is trimmed
    -- down to the body below.
    local author_str = InstapaperEpub.extractAuthor(html)
    local excerpt_str = InstapaperEpub.buildExcerpt(html)

    -- Balance HTML tags using crengine if available
    local ok_cre, cre = pcall(require, "libs/libkoreader-cre")
    if ok_cre and cre then
        local balanced = cre.getBalancedHTML(html, 0x0)
        if type(balanced) == "string" and balanced ~= "" then
            html = balanced
        end
    end

    -- Extract body content using find+sub (multiline-safe, Lua '.' doesn't match newlines)
    local body_content
    local _, body_open_end  = html:find("<body[^>]*>")   -- end pos of opening <body...>
    local body_close_start  = html:find("</body>")        -- start pos of </body>
    if body_open_end and body_close_start and body_close_start > body_open_end then
        body_content = html:sub(body_open_end + 1, body_close_start - 1)
    end
    if not body_content or body_content:match("^%s*$") then
        body_content = html  -- fallback: use entire content
    end

    -- Fix void elements to be XHTML self-closing (br, hr, input)
    body_content = body_content:gsub("<(br)(%s*)>",       "<%1%2/>")
    body_content = body_content:gsub("<(hr)(%s*)>",       "<%1%2/>")
    body_content = body_content:gsub("<(input)([^/>]-)>", "<%1%2/>")

    -- Rewrite images on body_content BEFORE XHTML wrap
    local images = {}
    if include_images then
        body_content, images = rewriteImages(body_content, article_url)
    else
        body_content = body_content:gsub("<%s*[Ii][Mm][Gg][^>]*/?>%s*", "")
    end

    -- Escape unrecognized tags inside <code>/<pre> blocks for XHTML validity
    local function escapeCodeBlock(open_tag, content, close_tag)
        content = content:gsub("<([^>]+)>", function(inner)
            if inner:match("^/?[%a][%w%-]*") then
                return "<" .. inner .. ">"
            end
            return "&lt;" .. inner .. "&gt;"
        end)
        return open_tag .. content .. close_tag
    end
    body_content = body_content:gsub("(<code[^>]*>)(.-)(</code>)", escapeCodeBlock)
    body_content = body_content:gsub("(<pre[^>]*>)(.-)(</pre>)",   escapeCodeBlock)

    -- Turn the article's own heading levels into chapters (anchors + navMap).
    local toc_entries
    body_content, toc_entries = extractHeadings(body_content)
    local toc_depth = normalizeLevels(toc_entries)

    -- Wrap in minimal XHTML (no external DTD to avoid crengine render errors)
    html = '<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
        .. '<meta http-equiv="Content-Type" content="application/xhtml+xml; charset=utf-8"/>'
        .. '<title>' .. escaped_title .. '</title>'
        .. '<link rel="stylesheet" type="text/css" href="stylesheet.css"/>'
        .. '</head><body>'
        .. body_content
        .. '</body></html>'

    -- Open archiver
    local ok_arch, Archiver = pcall(require, "ffi/archiver")
    if not ok_arch or not Archiver then
        logger.warn("InstapaperEpub: Archiver not available")
        return nil, "archiver_unavailable"
    end

    local epub_path_tmp = epub_path .. ".tmp"
    local epub = Archiver.Writer:new{}
    if not epub:open(epub_path_tmp, "epub") then
        return nil, "epub_open_failed"
    end

    -- mimetype (must be uncompressed, first entry)
    epub:setZipCompression("store")
    epub:addFileFromMemory("mimetype", "application/epub+zip", mtime)
    epub:setZipCompression("deflate")

    -- META-INF/container.xml
    epub:addFileFromMemory("META-INF/container.xml", [[
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]], mtime)

    -- OEBPS/content.opf
    -- crengine joins several dc:creator entries with newlines, and KOReader's
    -- book information renders them one per line, so byline and source site
    -- can both be shown without a publisher field (which KOReader never reads).
    local site_str = InstapaperEpub.deriveSiteName(article_url)
    -- Instapaper's description is user-supplied and usually empty; fall back
    -- to the excerpt we built from the article text itself.
    local desc_str = (bookmark.description ~= nil and bookmark.description ~= "")
        and bookmark.description or excerpt_str

    local meta_extra = ""
    if author_str then
        meta_extra = meta_extra .. "    <dc:creator>" .. xmlEsc(author_str) .. "</dc:creator>\n"
    end
    if site_str then
        meta_extra = meta_extra .. "    <dc:creator>" .. xmlEsc(site_str) .. "</dc:creator>\n"
    end
    if desc_str then
        meta_extra = meta_extra .. "    <dc:description>" .. xmlEsc(desc_str) .. "</dc:description>\n"
    end
    -- Lead image as cover. crengine only looks at <meta name="cover">, so no
    -- cover page or guide entry is needed.
    local cover_idx = include_images and pickCoverIndex(images) or nil
    if cover_idx then
        meta_extra = meta_extra .. string.format('    <meta name="cover" content="img%05d"/>\n', cover_idx)
    end

    local opf_parts = {}
    table.insert(opf_parts, string.format([[
<?xml version='1.0' encoding='utf-8'?>
<package xmlns="http://www.idpf.org/2007/opf"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        unique-identifier="bookid" version="2.0">
  <metadata>
    <dc:title>%s</dc:title>
%s    <dc:publisher>KOReader %s</dc:publisher>
  </metadata>
  <manifest>
    <item id="ncx"     href="toc.ncx"      media-type="application/x-dtbncx+xml"/>
    <item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>
    <item id="css"     href="stylesheet.css" media-type="text/css"/>
]], escaped_title, meta_extra, Version:getCurrentRevision()))

    if include_images then
        for i, img in ipairs(images) do
            table.insert(opf_parts, string.format(
                '    <item id="img%05d" href="%s" media-type="%s"/>\n',
                i, img.imgpath, img.mimetype))
        end
    end

    table.insert(opf_parts, [[
  </manifest>
  <spine toc="ncx">
    <itemref idref="content"/>
  </spine>
</package>
]])
    epub:addFileFromMemory("OEBPS/content.opf", table.concat(opf_parts), mtime)

    -- OEBPS/stylesheet.css
    epub:addFileFromMemory("OEBPS/stylesheet.css", "/* Instapaper */\n", mtime)

    -- OEBPS/toc.ncx
    local nav_map, ncx_depth
    if #toc_entries > 0 then
        nav_map = buildNavMap(toc_entries)
        ncx_depth = toc_depth
    else
        -- No headings in the article: keep the single whole-article entry.
        nav_map = string.format([[
    <navPoint id="navpoint-1" playOrder="1">
      <navLabel><text>%s</text></navLabel>
      <content src="content.xhtml"/>
    </navPoint>
]], escaped_title)
        ncx_depth = 1
    end
    local toc_ncx = string.format([[
<?xml version='1.0' encoding='utf-8'?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="instapaper_article"/>
    <meta name="dtb:depth" content="%d"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>%s</text></docTitle>
  <navMap>
%s  </navMap>
</ncx>
]], ncx_depth, escaped_title, nav_map)
    epub:addFileFromMemory("OEBPS/toc.ncx", toc_ncx, mtime)

    -- OEBPS/content.xhtml
    epub:addFileFromMemory("OEBPS/content.xhtml", html, mtime)

    collectgarbage()
    collectgarbage()

    -- OEBPS/images/*
    if include_images then
        for _, img in ipairs(images) do
            epub:addFileFromMemory("OEBPS/" .. img.imgpath, img.content, img.no_compress, mtime)
        end
    end

    epub:close()

    -- Move tmp to final path
    local ok_rename = os.rename(epub_path_tmp, epub_path)
    if not ok_rename then
        os.remove(epub_path_tmp)
        return nil, "epub_rename_failed"
    end

    collectgarbage()
    collectgarbage()

    logger.info("InstapaperEpub: created", epub_path)
    return epub_path, nil
end

return InstapaperEpub
