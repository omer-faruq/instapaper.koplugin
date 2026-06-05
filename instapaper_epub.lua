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
    if src:find("^data:") then return nil end
    if src:find("^[%w][%w%+%-.]*:") then return src end
    if not base_url or base_url == "" then return nil end
    return urlmod.absolute(base_url, src)
end

local function downloadImageToMemory(url)
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, headers = http.request{
        url     = url,
        method  = "GET",
        sink    = ltn12.sink.table(sink),
        headers = {
            ["Accept-Encoding"] = "identity",
            ["User-Agent"]      = "KOReader Instapaper",
        },
    }
    socketutil:reset_timeout()
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

        local ext = abs_src:match("%.([%w]+)%??") or ""
        ext = ext:lower()

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
-- EPUB path helper
--------------------------------------------------------------------

function InstapaperEpub.buildEpubPath(download_dir, bookmark)
    local safe_title = (bookmark.title or "article")
        :gsub("[/\\%?%%%*%:%|%\"%<%>]", "_")
        :sub(1, 100)
    safe_title = util.fixUtf8(safe_title, "_")
    return download_dir .. "/"
        .. tostring(bookmark.bookmark_id) .. "_" .. safe_title .. ".epub"
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
    local author_str = article_url:match("^https?://([^/]+)")
    if author_str then author_str = author_str:gsub("^www%.", "") end
    local desc_str = (bookmark.description ~= nil and bookmark.description ~= "") and bookmark.description or nil

    local meta_extra = ""
    if author_str then
        meta_extra = meta_extra .. "    <dc:creator>" .. xmlEsc(author_str) .. "</dc:creator>\n"
    end
    if desc_str then
        meta_extra = meta_extra .. "    <dc:description>" .. xmlEsc(desc_str) .. "</dc:description>\n"
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
    local toc_ncx = string.format([[
<?xml version='1.0' encoding='utf-8'?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="instapaper_article"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>%s</text></docTitle>
  <navMap>
    <navPoint id="navpoint-1" playOrder="1">
      <navLabel><text>%s</text></navLabel>
      <content src="content.xhtml"/>
    </navPoint>
  </navMap>
</ncx>
]], escaped_title, escaped_title)
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
