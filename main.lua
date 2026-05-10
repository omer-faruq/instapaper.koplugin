local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local FFIUtil = require("ffi/util")
local InfoMessage = require("ui/widget/infomessage")
local JSON = require("json")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local https = require("ssl.https")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")
local T = FFIUtil.template
local Dispatcher = require("dispatcher")

local base64_encode = require("mime").b64
local sha2 = require("ffi/sha2")

--------------------------------------------------------------------
-- OAuth 1.0a helpers
--------------------------------------------------------------------

-- RFC 3986 percent-encoding
local function percent_encode(str)
    if not str then return "" end
    str = tostring(str)
    return (str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function generate_nonce()
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local t = {}
    for i = 1, 32 do
        local idx = math.random(1, #chars)
        t[i] = chars:sub(idx, idx)
    end
    return table.concat(t)
end

--------------------------------------------------------------------
-- Plugin
--------------------------------------------------------------------

local Instapaper = WidgetContainer:extend{
    name = "instapaper",
    api_base = "https://www.instapaper.com",
}

-- OAuth 1.0a signature (HMAC-SHA1)
function Instapaper:oauthSign(method, request_url, all_params, consumer_secret, token_secret)
    local keys = {}
    for k in pairs(all_params) do keys[#keys + 1] = k end
    table.sort(keys)

    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = percent_encode(k) .. "=" .. percent_encode(all_params[k])
    end
    local param_string = table.concat(parts, "&")

    local base_string = method:upper()
        .. "&" .. percent_encode(request_url)
        .. "&" .. percent_encode(param_string)

    local signing_key = percent_encode(consumer_secret or "")
        .. "&" .. percent_encode(token_secret or "")

    local hmac_hex = sha2.hmac(sha2.sha1, signing_key, base_string)
    local hmac_binary = sha2.hex_to_bin(hmac_hex)
    return base64_encode(hmac_binary)
end

-- Signed POST request to the Instapaper API.
-- Returns ok, body, http_code.
-- When raw_response is true the body is returned as-is (for non-JSON endpoints).
function Instapaper:apiRequest(endpoint, body_params, raw_response)
    local request_url = self.api_base .. endpoint
    body_params = body_params or {}

    -- OAuth parameters
    local oauth = {
        oauth_consumer_key     = self.consumer_key,
        oauth_nonce            = generate_nonce(),
        oauth_signature_method = "HMAC-SHA1",
        oauth_timestamp        = tostring(os.time()),
        oauth_version          = "1.0",
    }
    if self.oauth_token and self.oauth_token ~= "" then
        oauth.oauth_token = self.oauth_token
    end

    -- Merge all params for signature computation
    local all_params = {}
    for k, v in pairs(oauth)        do all_params[k] = v end
    for k, v in pairs(body_params)  do all_params[k] = v end

    oauth.oauth_signature = self:oauthSign(
        "POST", request_url, all_params,
        self.consumer_secret, self.oauth_token_secret)

    -- Build Authorization header
    local auth_parts = {}
    local oauth_keys = {}
    for k in pairs(oauth) do oauth_keys[#oauth_keys + 1] = k end
    table.sort(oauth_keys)
    for _, k in ipairs(oauth_keys) do
        auth_parts[#auth_parts + 1] = percent_encode(k)
            .. '="' .. percent_encode(oauth[k]) .. '"'
    end
    local auth_header = "OAuth " .. table.concat(auth_parts, ", ")

    -- Build POST body
    local bp = {}
    for k, v in pairs(body_params) do
        bp[#bp + 1] = percent_encode(k) .. "=" .. percent_encode(v)
    end
    local body = table.concat(bp, "&")

    -- Execute request
    local chunks = {}
    socketutil:set_timeout(
        socketutil.DEFAULT_BLOCK_TIMEOUT,
        socketutil.DEFAULT_TOTAL_TIMEOUT)
    local result, code = https.request{
        url     = request_url,
        method  = "POST",
        headers = {
            ["Authorization"]  = auth_header,
            ["Content-Type"]   = "application/x-www-form-urlencoded",
            ["Content-Length"]  = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink   = ltn12.sink.table(chunks),
    }
    socketutil:reset_timeout()

    local response_body = table.concat(chunks)

    if result ~= 1 then
        logger.warn("Instapaper: network error on", endpoint, code)
        return false, tostring(code), 0
    end

    if raw_response then
        return code == 200, response_body, code
    end

    if code ~= 200 then
        local ok_json, err_data = pcall(JSON.decode, response_body)
        if ok_json and type(err_data) == "table" then
            for _, item in ipairs(err_data) do
                if item.type == "error" then
                    return false, item.message or "Unknown error", code
                end
            end
        end
        return false, response_body, code
    end

    return true, response_body, code
end

--------------------------------------------------------------------
-- Profile Actions
--------------------------------------------------------------------

function Instapaper:onInstapaperBulkDownload()
    self:ensureOnlineAndLoggedIn(function()
        self:showBulkDownloadDialog()
    end)
    return true
end

function Instapaper:onInstapaperDownloadUnread()
    self:ensureOnlineAndLoggedIn(function()
        local folder_val    = "unread"
        local days_limit    = 0 -- 0 = no limit
        local archive_after = self.settings:readSetting("bulk_archive_after") or false
        local delete_after  = self.settings:readSetting("bulk_delete_after") or false
        self:runBulkDownload(folder_val, days_limit, archive_after, delete_after)
    end)
    return true
end

function Instapaper:onInstapaperUnread()
    self:ensureOnlineAndLoggedIn(function()
        self:fetchAndShowArticles("unread")
    end)
    return true
end

function Instapaper:onDispatcherRegisterActions()
    Dispatcher:registerAction("instapaper_bulk_download",
        { category = "none", event = "InstapaperBulkDownload", title = _("Instapaper bulk download"), general = true, })
    Dispatcher:registerAction("instapaper_download_unread",
        { category = "none", event = "InstapaperDownloadUnread", title = _("Instapaper download unread"), general = true, })
    Dispatcher:registerAction("instapaper_unread",
        { category = "none", event = "InstapaperUnread", title = _("Instapaper: unread"), general = true, separator = true, })
end

--------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------

function Instapaper:init()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:loadSettings()
end

function Instapaper:loadSettings()
    self.settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/instapaper.lua")
    self.consumer_key       = self.settings:readSetting("consumer_key")
    self.consumer_secret    = self.settings:readSetting("consumer_secret")
    self.oauth_token        = self.settings:readSetting("oauth_token")
    self.oauth_token_secret = self.settings:readSetting("oauth_token_secret")
    self.username           = self.settings:readSetting("username")
    self.article_limit      = self.settings:readSetting("article_limit") or 50
    self.output_format      = self.settings:readSetting("output_format") or "html"
    self.include_images     = self.settings:readSetting("include_images") or false
    self.after_download_action = self.settings:readSetting("after_download_action") or "none"
    self.cache_folder       = self.settings:readSetting("cache_folder")
end

function Instapaper:saveSettings()
    self.settings:saveSetting("consumer_key",       self.consumer_key)
    self.settings:saveSetting("consumer_secret",    self.consumer_secret)
    self.settings:saveSetting("oauth_token",        self.oauth_token)
    self.settings:saveSetting("oauth_token_secret", self.oauth_token_secret)
    self.settings:saveSetting("username",           self.username)
    self.settings:saveSetting("article_limit",      self.article_limit)
    self.settings:saveSetting("output_format",      self.output_format)
    self.settings:saveSetting("include_images",     self.include_images)
    self.settings:saveSetting("after_download_action", self.after_download_action)
    self.settings:saveSetting("cache_folder",       self.cache_folder)
    self.settings:flush()
end

function Instapaper:isConfigured()
    return self.consumer_key    and self.consumer_key    ~= ""
       and self.consumer_secret and self.consumer_secret ~= ""
end

function Instapaper:isLoggedIn()
    return self:isConfigured()
       and self.oauth_token        and self.oauth_token        ~= ""
       and self.oauth_token_secret and self.oauth_token_secret ~= ""
end

--------------------------------------------------------------------
-- Main menu
--------------------------------------------------------------------

function Instapaper:addToMainMenu(menu_items)
    menu_items.instapaper = {
        text = _("Instapaper"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Unread articles"),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:fetchAndShowArticles("unread")
                    end)
                end,
            },
            {
                text = _("Starred articles"),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:fetchAndShowArticles("starred")
                    end)
                end,
            },
            {
                text = _("Archived articles"),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:fetchAndShowArticles("archive")
                    end)
                end,
                separator = true,
            },
            {
                text = _("Custom folders"),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:fetchAndShowUserFolders()
                    end)
                end,
            },
            {
                text = _("Bulk download..."),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:showBulkDownloadDialog()
                    end)
                end,
            },
            {
                text = _("Open downloads folder"),
                callback = function()
                    self:openDownloadsFolder()
                end,
            },
            {
                text = _("Clear downloads cache"),
                keep_menu_open = true,
                callback = function()
                    self:clearDownloadsCache()
                end,
                separator = true,
            },
            {
                text = _("Settings"),
                keep_menu_open = true,
                callback = function()
                    self:showSettingsDialog()
                end,
            },
            {
                text = _("API credentials"),
                keep_menu_open = true,
                callback = function()
                    self:showCredentialsDialog()
                end,
            },
            {
                text_func = function()
                    if self:isLoggedIn() then
                        if self.username and self.username ~= "" then
                            return T(_("Log out (%1)"), self.username)
                        else
                            return _("Log out")
                        end
                    else
                        return _("Log in")
                    end
                end,
                keep_menu_open = true,
                callback = function()
                    if self:isLoggedIn() then
                        self:logout()
                    else
                        if not self:isConfigured() then
                            UIManager:show(InfoMessage:new{
                                text = _("Please set API credentials first.\nGet them at: instapaper.com/main/request_oauth_consumer_token"),
                            })
                            return
                        end
                        NetworkMgr:runWhenOnline(function()
                            self:showLoginDialog()
                        end)
                    end
                end,
            },
        },
    }
end

function Instapaper:ensureOnlineAndLoggedIn(callback)
    if not self:isLoggedIn() then
        UIManager:show(InfoMessage:new{
            text = _("Please configure API credentials and log in first."),
        })
        return
    end
    NetworkMgr:runWhenOnline(function()
        callback()
    end)
end

--------------------------------------------------------------------
-- Dialogs
--------------------------------------------------------------------

function Instapaper:showCredentialsDialog()
    self.cred_dialog = MultiInputDialog:new{
        title = _("Instapaper API credentials"),
        fields = {
            {
                text = self.consumer_key or "",
                hint = _("Consumer key"),
            },
            {
                text = self.consumer_secret or "",
                hint = _("Consumer secret"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.cred_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = self.cred_dialog:getFields()
                        self.consumer_key    = fields[1]
                        self.consumer_secret = fields[2]
                        -- Invalidate tokens when credentials change
                        self.oauth_token        = nil
                        self.oauth_token_secret = nil
                        self:saveSettings()
                        UIManager:close(self.cred_dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("Credentials saved."),
                            timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(self.cred_dialog)
    self.cred_dialog:onShowKeyboard()
end

function Instapaper:showSettingsDialog()
    local limit_choices = { 10, 25, 50, 100, 200, 500 }
    local current_limit = self.article_limit or 50

    -- Find current index for limit
    local limit_idx = 2  -- default to 25
    for i, v in ipairs(limit_choices) do
        if v == current_limit then
            limit_idx = i
            break
        end
    end

    local output_format = self.output_format or "html"
    local include_images = self.include_images or false
    local after_download_action = self.after_download_action or "none"
    local cache_folder = self.cache_folder

    local settings_dialog
    local function rebuildSettingsDialog()
        if settings_dialog then
            UIManager:close(settings_dialog)
        end

        local default_dir = DataStorage:getDataDir() .. "/instapaper"
        local fmt_label = output_format == "epub" and "EPUB" or "HTML"
        local img_label = include_images and _("ON") or _("OFF")
        local limit_label = tostring(limit_choices[limit_idx])
        local action_label
        if after_download_action == "archive" then
            action_label = _("Archive only")
        elseif after_download_action == "read" then
            action_label = _("Archive + Mark read")
        else
            action_label = _("None")
        end
        
        local cache_label
        if cache_folder and cache_folder ~= "" then
            if #cache_folder > 40 then
                cache_label = "..." .. cache_folder:sub(-37)
            else
                cache_label = cache_folder
            end
        else
            cache_label = _("Default")
        end

        settings_dialog = ButtonDialog:new{
            title = _("Instapaper settings")
                .. "\n" .. _("Article list limit: ") .. limit_label
                .. "\n" .. _("Output format: ") .. fmt_label
                .. "\n" .. _("Include images (EPUB): ") .. img_label
                .. "\n" .. _("After download: ") .. action_label
                .. "\n" .. _("Cache folder: ") .. cache_label,
            buttons = {
                {
                    {
                        text = _("< Limit >"),
                        callback = function()
                            limit_idx = (limit_idx % #limit_choices) + 1
                            rebuildSettingsDialog()
                        end,
                    },
                    {
                        text = _("< Format >"),
                        callback = function()
                            output_format = output_format == "html" and "epub" or "html"
                            rebuildSettingsDialog()
                        end,
                    },
                },
                {
                    {
                        text = _("Images: ") .. img_label,
                        callback = function()
                            include_images = not include_images
                            rebuildSettingsDialog()
                        end,
                    },
                    {
                        text = _("< After download >"),
                        callback = function()
                            if after_download_action == "none" then
                                after_download_action = "archive"
                            elseif after_download_action == "archive" then
                                after_download_action = "read"
                            else
                                after_download_action = "none"
                            end
                            rebuildSettingsDialog()
                        end,
                    },
                },
                {
                    {
                        text = _("< Cache folder >"),
                        callback = function()
                            UIManager:close(settings_dialog)
                            self:showCacheFolderDialog(function(new_path)
                                cache_folder = new_path
                                rebuildSettingsDialog()
                            end, cache_folder)
                        end,
                    },
                },
                {
                    {
                        text = _("Save"),
                        callback = function()
                            UIManager:close(settings_dialog)
                            self.article_limit  = limit_choices[limit_idx]
                            self.output_format  = output_format
                            self.include_images = include_images
                            self.after_download_action = after_download_action
                            self.cache_folder = cache_folder
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("Settings saved."),
                                timeout = 2,
                            })
                        end,
                    },
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(settings_dialog)
                        end,
                    },
                },
            },
        }
        UIManager:show(settings_dialog)
    end

    rebuildSettingsDialog()
end

function Instapaper:showCacheFolderDialog(return_callback, current_folder)
    local default_dir = DataStorage:getDataDir() .. "/instapaper"
    
    local cache_dialog
    cache_dialog = MultiInputDialog:new{
        title = _("Cache folder"),
        fields = {
            {
                text = current_folder or "",
                hint = current_folder and current_folder ~= "" and current_folder or default_dir,
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(cache_dialog)
                        if return_callback then
                            return_callback(current_folder)
                        end
                    end,
                },
                {
                    text = _("OK"),
                    is_enter_default = true,
                    callback = function()
                        local fields = cache_dialog:getFields()
                        local new_path = fields[1]
                        UIManager:close(cache_dialog)
                        
                        if new_path and new_path ~= "" then
                            local attr = lfs.attributes(new_path)
                            if attr and attr.mode == "directory" then
                                if return_callback then
                                    return_callback(new_path)
                                end
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("The specified path does not exist."),
                                })
                                if return_callback then
                                    return_callback(current_folder)
                                end
                            end
                        else
                            if return_callback then
                                return_callback(nil)
                            end
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(cache_dialog)
    cache_dialog:onShowKeyboard()
end

function Instapaper:showLoginDialog()
    self.login_dialog = MultiInputDialog:new{
        title = _("Instapaper login"),
        fields = {
            {
                text = self.username or "",
                hint = _("Email or username"),
            },
            {
                text = "",
                hint = _("Password, if you have one"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.login_dialog)
                    end,
                },
                {
                    text = _("Login"),
                    is_enter_default = true,
                    callback = function()
                        local fields = self.login_dialog:getFields()
                        UIManager:close(self.login_dialog)
                        if fields[1] and fields[1] ~= "" then
                            self:xauthLogin(fields[1], fields[2] or "")
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Username is required."),
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.login_dialog)
    self.login_dialog:onShowKeyboard()
end

--------------------------------------------------------------------
-- Auth
--------------------------------------------------------------------

function Instapaper:xauthLogin(username, password)
    UIManager:show(InfoMessage:new{
        text = _("Logging in..."),
        timeout = 1,
    })

    -- Temporarily clear tokens for xAuth (no token yet)
    local prev_t, prev_s = self.oauth_token, self.oauth_token_secret
    self.oauth_token, self.oauth_token_secret = nil, nil

    -- raw_response = true because xAuth returns qline, not JSON
    local ok, body, code = self:apiRequest("/api/1/oauth/access_token", {
        x_auth_username = username,
        x_auth_password = password,
        x_auth_mode     = "client_auth",
    }, true)

    if ok then
        local token  = body:match("oauth_token=([^&]+)")
        local secret = body:match("oauth_token_secret=([^&]+)")
        if token and secret then
            self.oauth_token        = token
            self.oauth_token_secret = secret
            self.username           = username
            self:saveSettings()
            UIManager:show(InfoMessage:new{
                text = _("Login successful!"),
                timeout = 2,
            })
            return
        end
    end

    -- Restore previous tokens on failure
    self.oauth_token, self.oauth_token_secret = prev_t, prev_s
    UIManager:show(InfoMessage:new{
        text = T(_("Login failed (HTTP %1)"), tostring(code)),
    })
end

function Instapaper:logout()
    self.oauth_token        = nil
    self.oauth_token_secret = nil
    self.username           = nil
    self:saveSettings()
    UIManager:show(InfoMessage:new{
        text = _("Logged out."),
        timeout = 2,
    })
end

--------------------------------------------------------------------
-- Bookmarks
--------------------------------------------------------------------

function Instapaper:fetchAndShowArticles(folder_id, folder_name)
    local info = InfoMessage:new{
        text = _("Fetching articles..."),
    }
    UIManager:show(info)
    UIManager:forceRePaint()

    local params = { limit = tostring(self.article_limit or 50) }
    if folder_id then
        params.folder_id = folder_id
    end

    local ok, body, code = self:apiRequest("/api/1/bookmarks/list", params)

    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to fetch articles: %1"), body or tostring(code)),
        })
        return
    end

    local parse_ok, data = pcall(JSON.decode, body)
    if not parse_ok or type(data) ~= "table" then
        UIManager:show(InfoMessage:new{
            text = _("Failed to parse article list."),
        })
        return
    end

    -- /api/1/bookmarks/list returns array of objects, first is user info
    local bookmarks = {}
    if type(data) == "table" then
        for _, item in ipairs(data) do
            if type(item) == "table" and item.type == "bookmark" then
                table.insert(bookmarks, item)
            end
        end
    end

    if #bookmarks == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No articles found."),
        })
        return
    end

    UIManager:close(info)
    UIManager:forceRePaint()
    self:showArticleMenu(bookmarks, folder_id, folder_name)
end

function Instapaper:showArticleMenu(bookmarks, folder_id, folder_name)
    local folder_names = {
        unread  = _("Unread"),
        starred = _("Starred"),
        archive = _("Archive"),
    }

    local menu
    local menu_items = {}
    for _, bm in ipairs(bookmarks) do
        local title = bm.title
        if not title or title == "" or type(title) ~= "string" then
            title = "Untitled"
        end

        local progress_str = nil
        if bm.progress and bm.progress > 0 then
            progress_str = string.format("%d%%", bm.progress * 100)
        end

        local item = {
            text = title,
            _bookmark = bm,
            callback = function()
                NetworkMgr:runWhenOnline(function()
                    self:downloadAndOpenArticle(bm)
                end)
            end,
            hold_callback = function()
                self:showArticleActions(bm, menu, folder_id)
            end,
            hold_keep_menu_open = true,
        }

        if progress_str then
            item.mandatory = progress_str
        end

        table.insert(menu_items, item)
    end

    local menu_title = folder_name or folder_names[folder_id] or folder_id or "Articles"
    if type(menu_title) ~= "string" then
        menu_title = "Articles"
    end
    
    menu = Menu:new{
        title = "Instapaper - " .. menu_title,
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        close_callback = function()
            UIManager:close(menu)
        end,
        onMenuHold = function(_, item)
            if item and type(item.hold_callback) == "function" then
                item.hold_callback()
            end
            return true
        end,
    }

    UIManager:show(menu, "full")
end

function Instapaper:buildArticleMetaTitle(bookmark)
    local title = bookmark.title
    if not title or title == "" then
        title = _("Untitled")
    end

    local lines = { title }

    -- Date
    if bookmark.time and bookmark.time > 0 then
        local date_str = os.date("%Y-%m-%d", bookmark.time)
        lines[#lines + 1] = _("Date: ") .. date_str
    end

    -- Word count / reading time
    if bookmark.word_count and bookmark.word_count > 0 then
        local wc = tostring(bookmark.word_count) .. " " .. _("words")
        local mins = math.ceil(bookmark.word_count / 200)
        wc = wc .. "  (~" .. tostring(mins) .. " min)"
        lines[#lines + 1] = wc
    end

    -- Reading progress
    if bookmark.progress and bookmark.progress > 0 then
        lines[#lines + 1] = _("Progress: ") .. string.format("%d%%", bookmark.progress * 100)
    end

    -- URL (truncated)
    if bookmark.url and bookmark.url ~= "" then
        local url = bookmark.url
        if #url > 60 then
            url = url:sub(1, 57) .. "..."
        end
        lines[#lines + 1] = url
    end

    return table.concat(lines, "\n")
end

function Instapaper:showArticleActions(bookmark, parent_menu, folder_id)
    local dialog_title = self:buildArticleMetaTitle(bookmark)

    local actions_dialog
    actions_dialog = ButtonDialog:new{
        title = dialog_title,
        buttons = {
            {
                {
                    text = _("Download"),
                    callback = function()
                        UIManager:close(actions_dialog)
                        NetworkMgr:runWhenOnline(function()
                            self:downloadArticleOnly(bookmark)
                        end)
                    end,
                },
                {
                    text = _("Open"),
                    callback = function()
                        UIManager:close(actions_dialog)
                        NetworkMgr:runWhenOnline(function()
                            self:downloadAndOpenArticle(bookmark)
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Archive"),
                    callback = function()
                        UIManager:close(actions_dialog)
                        self:archiveBookmark(
                            bookmark.bookmark_id, parent_menu, folder_id)
                    end,
                },
                {
                    text = _("Star"),
                    callback = function()
                        UIManager:close(actions_dialog)
                        self:starBookmark(bookmark.bookmark_id)
                    end,
                },
            },
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:close(actions_dialog)
                        self:deleteBookmark(
                            bookmark.bookmark_id, parent_menu, folder_id)
                    end,
                },
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(actions_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(actions_dialog)
end

function Instapaper:getDownloadDir()
    local dir
    if self.cache_folder and self.cache_folder ~= "" then
        dir = self.cache_folder
    else
        dir = DataStorage:getDataDir() .. "/instapaper"
    end
    lfs.mkdir(dir)
    return dir
end

function Instapaper:buildFilepath(bookmark)
    local safe_title = (bookmark.title or "article")
        :gsub("[/\\%?%%%*%:%|%\"%<%>]", "_")
        :sub(1, 100)
    safe_title = util.fixUtf8(safe_title, "_")
    return self:getDownloadDir() .. "/"
        .. tostring(bookmark.bookmark_id) .. "_" .. safe_title .. ".html"
end

function Instapaper:injectTitleIfMissing(html, bookmark)
    local title = bookmark.title
    if not title or title == "" then
        return html
    end
    -- Only inject if no h1/h2/h3 found near the top of the document
    local head = html:sub(1, 2000):lower()
    if head:find("<h1") or head:find("<h2") or head:find("<h3") then
        return html
    end
    local escaped = title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local inject = "<h3>" .. escaped .. "</h3>\n"
    -- Insert after <body> tag if present, otherwise prepend
    local result, n = html:gsub("(<body[^>]*>)", "%1\n" .. inject, 1)
    if n == 0 then
        result = inject .. html
    end
    return result
end

function Instapaper:fetchArticleHtml(bookmark)
    local ok, html, code = self:apiRequest("/api/1/bookmarks/get_text", {
        bookmark_id = tostring(bookmark.bookmark_id),
    }, true)
    if not ok then
        return nil, code
    end
    html = self:injectTitleIfMissing(html, bookmark)
    return html, nil
end

function Instapaper:saveArticleHtml(bookmark, html)
    local filepath = self:buildFilepath(bookmark)
    local f = io.open(filepath, "w")
    if not f then
        return nil
    end
    f:write(html)
    f:close()
    return filepath
end

-- Save article in the configured output format (html or epub).
-- Returns filepath on success, nil on failure.
function Instapaper:saveArticle(bookmark, html)
    local fmt = self.output_format or "html"
    if fmt == "epub" then
        local InstapaperEpub = require("instapaper_epub")
        local filepath, err = InstapaperEpub.createEpub(
            bookmark, html, self:getDownloadDir(), self.include_images)
        if not filepath then
            logger.warn("Instapaper: EPUB creation failed, falling back to HTML", err)
            return self:saveArticleHtml(bookmark, html)
        end
        return filepath
    else
        return self:saveArticleHtml(bookmark, html)
    end
end

-- Download only (no open), keeps caller menu open
function Instapaper:downloadArticleOnly(bookmark)
    UIManager:show(InfoMessage:new{
        text = _("Downloading article..."),
        timeout = 1,
    })

    local html, err = self:fetchArticleHtml(bookmark)
    if not html then
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed (HTTP %1)"), tostring(err)),
        })
        return
    end

    local filepath = self:saveArticle(bookmark, html)
    if not filepath then
        UIManager:show(InfoMessage:new{
            text = _("Could not save article file."),
        })
        return
    end

    local short_title = (bookmark.title or "article"):sub(1, 40)
    UIManager:show(InfoMessage:new{
        text = T(_("Saved: %1"), short_title),
        timeout = 2,
    })

    if self.after_download_action == "archive" then
        self:apiRequest("/api/1/bookmarks/archive", {
            bookmark_id = tostring(bookmark.bookmark_id),
        })
    elseif self.after_download_action == "read" then
        self:apiRequest("/api/1/bookmarks/archive", {
            bookmark_id = tostring(bookmark.bookmark_id),
        })
        self:apiRequest("/api/1/bookmarks/update_read_progress", {
            bookmark_id = tostring(bookmark.bookmark_id),
            progress = "1.0",
            progress_timestamp = tostring(os.time()),
        })
    end
end

function Instapaper:downloadAndOpenArticle(bookmark)
    UIManager:show(InfoMessage:new{
        text = _("Downloading article..."),
        timeout = 1,
    })

    local html, err = self:fetchArticleHtml(bookmark)
    if not html then
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed (HTTP %1)"), tostring(err)),
        })
        return
    end

    local filepath = self:saveArticle(bookmark, html)
    if not filepath then
        UIManager:show(InfoMessage:new{
            text = _("Could not save article file."),
        })
        return
    end

    if self.after_download_action == "archive" then
        self:apiRequest("/api/1/bookmarks/archive", {
            bookmark_id = tostring(bookmark.bookmark_id),
        })
    elseif self.after_download_action == "read" then
        self:apiRequest("/api/1/bookmarks/archive", {
            bookmark_id = tostring(bookmark.bookmark_id),
        })
        self:apiRequest("/api/1/bookmarks/update_read_progress", {
            bookmark_id = tostring(bookmark.bookmark_id),
            progress = "1.0",
            progress_timestamp = tostring(os.time()),
        })
    end

    -- Open in KOReader
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(filepath)
end

--------------------------------------------------------------------
-- Downloads folder
--------------------------------------------------------------------

function Instapaper:clearDownloadsCache()
    local dir = self:getDownloadDir()
    local ConfirmBox = require("ui/widget/confirmbox")

    UIManager:show(ConfirmBox:new{
        text = _("Delete all files and folders in the Instapaper downloads folder?"),
        ok_text = _("Delete"),
        ok_callback = function()
            self:_doClearDownloadsCache(dir)
        end,
    })
end

function Instapaper:_doClearDownloadsCache(dir)
    local function removeAll(path)
        local attr = lfs.attributes(path)
        if not attr then return end
        if attr.mode == "directory" then
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    removeAll(path .. "/" .. entry)
                end
            end
            lfs.rmdir(path)
        else
            os.remove(path)
        end
    end

    local count = 0
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            removeAll(dir .. "/" .. entry)
            count = count + 1
        end
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Deleted %1 item(s) from downloads folder."), count),
        timeout = 3,
    })
end

function Instapaper:openDownloadsFolder()
    local dir = self:getDownloadDir()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:reinit(dir)
    else
        FileManager:showFiles(dir)
    end
end

--------------------------------------------------------------------
-- Custom folders
--------------------------------------------------------------------

-- Returns a list of {text, value} for user-created folders, or nil on error.
function Instapaper:fetchUserFolders()
    local ok, body, code = self:apiRequest("/api/1/folders/list", {})
    if not ok then
        logger.warn("Instapaper: failed to fetch folders", code)
        return nil
    end
    local parse_ok, data = pcall(JSON.decode, body)
    if not parse_ok or type(data) ~= "table" then
        return nil
    end
    local folders = {}
    for _, item in ipairs(data) do
        if type(item) == "table" and item.type == "folder" then
            table.insert(folders, {
                text  = item.title or item.slug or tostring(item.folder_id),
                value = tostring(item.folder_id),
            })
        end
    end
    return folders
end

function Instapaper:fetchAndShowUserFolders()
    UIManager:show(InfoMessage:new{
        text = _("Fetching folders..."),
        timeout = 1,
    })

    local folders = self:fetchUserFolders()
    if not folders then
        UIManager:show(InfoMessage:new{
            text = _("Failed to fetch folders."),
        })
        return
    end
    if #folders == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No custom folders found."),
        })
        return
    end

    local folder_menu
    local menu_items = {}
    for _, folder in ipairs(folders) do
        local f = folder
        table.insert(menu_items, {
            text = f.text,
            callback = function()
                UIManager:close(folder_menu)
                NetworkMgr:runWhenOnline(function()
                    self:fetchAndShowArticles(f.value, f.text)
                end)
            end,
        })
    end

    folder_menu = Menu:new{
        title = _("Instapaper - Custom folders"),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        close_callback = function()
            UIManager:close(folder_menu)
        end,
    }
    UIManager:show(folder_menu, "full")
end

--------------------------------------------------------------------
-- Bulk download
--------------------------------------------------------------------

function Instapaper:showBulkDownloadDialog()
    -- Start with built-in folders; custom folders appended after fetch
    local folder_choices = {
        { text = _("Unread"),  value = "unread"  },
        { text = _("Starred"), value = "starred" },
        { text = _("Archive"), value = "archive" },
    }

    -- Fetch user folders and append
    local user_folders = self:fetchUserFolders()
    if user_folders then
        for _, f in ipairs(user_folders) do
            table.insert(folder_choices, f)
        end
    end

    -- State for the dialog
    local selected_folder_idx = 1
    local days_limit = 0   -- 0 = no limit
    local archive_after = self.settings:readSetting("bulk_archive_after") or false
    local delete_after  = self.settings:readSetting("bulk_delete_after")  or false

    local function folderLabel()
        return folder_choices[selected_folder_idx].text
    end

    local function daysLabel()
        if days_limit == 0 then
            return _("All time")
        else
            return T(_("Last %1 days"), tostring(days_limit))
        end
    end

    local bulk_dialog
    local function rebuildDialog()
        if bulk_dialog then
            UIManager:close(bulk_dialog)
        end
        bulk_dialog = ButtonDialog:new{
            title = _("Bulk download settings")
                .. "\n" .. _("Folder: ") .. folderLabel()
                .. "\n" .. _("Period: ") .. daysLabel()
                .. "\n" .. _("Archive after download: ") .. (archive_after and _("Yes") or _("No"))
                .. "\n" .. _("Delete after download: ")  .. (delete_after  and _("Yes") or _("No")),
            buttons = {
                {
                    {
                        text = _("< Folder >"),
                        callback = function()
                            selected_folder_idx = (selected_folder_idx % #folder_choices) + 1
                            rebuildDialog()
                        end,
                    },
                    {
                        text = _("< Period >"),
                        callback = function()
                            UIManager:close(bulk_dialog)
                            local spin = SpinWidget:new{
                                title_text = _("Days limit (0 = all)"),
                                value = days_limit,
                                value_min = 0,
                                value_max = 365,
                                value_step = 1,
                                ok_text = _("Set"),
                                callback = function(spin_widget)
                                    days_limit = spin_widget.value
                                    rebuildDialog()
                                end,
                                cancel_callback = function()
                                    rebuildDialog()
                                end,
                            }
                            UIManager:show(spin)
                        end,
                    },
                },
                {
                    {
                        text = _("Archive after: ") .. (archive_after and _("ON") or _("OFF")),
                        callback = function()
                            archive_after = not archive_after
                            if archive_after then delete_after = false end
                            rebuildDialog()
                        end,
                    },
                    {
                        text = _("Delete after: ") .. (delete_after and _("ON") or _("OFF")),
                        callback = function()
                            delete_after = not delete_after
                            if delete_after then archive_after = false end
                            rebuildDialog()
                        end,
                    },
                },
                {
                    {
                        text = _("Start download"),
                        callback = function()
                            UIManager:close(bulk_dialog)
                            -- Save preferences
                            self.settings:saveSetting("bulk_archive_after", archive_after)
                            self.settings:saveSetting("bulk_delete_after",  delete_after)
                            self.settings:flush()
                            local folder_val = folder_choices[selected_folder_idx].value
                            self:runBulkDownload(folder_val, days_limit, archive_after, delete_after)
                        end,
                    },
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(bulk_dialog)
                        end,
                    },
                },
            },
        }
        UIManager:show(bulk_dialog)
    end

    rebuildDialog()
end

function Instapaper:runBulkDownload(folder_id, days_limit, archive_after, delete_after)
    UIManager:show(InfoMessage:new{
        text = _("Fetching article list..."),
        timeout = 1,
    })

    local params = { limit = "500" }  -- bulk always fetches max
    if folder_id then
        params.folder_id = folder_id
    end

    local ok, body, code = self:apiRequest("/api/1/bookmarks/list", params)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to fetch articles: %1"), body or tostring(code)),
        })
        return
    end

    local parse_ok, data = pcall(JSON.decode, body)
    if not parse_ok or type(data) ~= "table" then
        UIManager:show(InfoMessage:new{
            text = _("Failed to parse article list."),
        })
        return
    end

    local bookmarks = {}
    for _, item in ipairs(data) do
        if type(item) == "table" and item.type == "bookmark" then
            -- Apply days filter (client-side)
            local include = true
            if days_limit and days_limit > 0 then
                local cutoff = os.time() - (days_limit * 86400)
                if not item.time or item.time < cutoff then
                    include = false
                end
            end
            if include then
                table.insert(bookmarks, item)
            end
        end
    end

    if #bookmarks == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No articles match the selected filters."),
        })
        return
    end

    -- Download sequentially, show progress
    local downloaded = 0
    local failed = 0
    for _, bm in ipairs(bookmarks) do
        local html, err = self:fetchArticleHtml(bm)
        if html then
            local saved = self:saveArticle(bm, html)
            if saved then
                downloaded = downloaded + 1
                -- Archive or delete after successful download
                if archive_after then
                    self:apiRequest("/api/1/bookmarks/archive", {
                        bookmark_id = tostring(bm.bookmark_id),
                    })
                elseif delete_after then
                    self:apiRequest("/api/1/bookmarks/delete", {
                        bookmark_id = tostring(bm.bookmark_id),
                    })
                end
            else
                failed = failed + 1
            end
        else
            logger.warn("Instapaper bulk: failed to download", bm.bookmark_id, err)
            failed = failed + 1
        end
    end

    local msg = T(_("Bulk download complete.\nDownloaded: %1  Failed: %2"),
        tostring(downloaded), tostring(failed))
    UIManager:show(InfoMessage:new{
        text = msg,
    })
end

--------------------------------------------------------------------
-- Bookmark actions
--------------------------------------------------------------------

function Instapaper:archiveBookmark(bookmark_id, parent_menu, folder_id)
    local ok, body = self:apiRequest("/api/1/bookmarks/archive", {
        bookmark_id = tostring(bookmark_id),
    })
    UIManager:show(InfoMessage:new{
        text = ok and _("Archived.") or T(_("Failed: %1"), body or ""),
        timeout = 2,
    })
    if ok and parent_menu then
        UIManager:close(parent_menu)
        self:fetchAndShowArticles(folder_id)
    end
end

function Instapaper:deleteBookmark(bookmark_id, parent_menu, folder_id)
    local ok, body = self:apiRequest("/api/1/bookmarks/delete", {
        bookmark_id = tostring(bookmark_id),
    })
    UIManager:show(InfoMessage:new{
        text = ok and _("Deleted.") or T(_("Failed: %1"), body or ""),
        timeout = 2,
    })
    if ok and parent_menu then
        UIManager:close(parent_menu)
        self:fetchAndShowArticles(folder_id)
    end
end

function Instapaper:starBookmark(bookmark_id)
    local ok, body = self:apiRequest("/api/1/bookmarks/star", {
        bookmark_id = tostring(bookmark_id),
    })
    UIManager:show(InfoMessage:new{
        text = ok and _("Starred.") or T(_("Failed: %1"), body or ""),
        timeout = 2,
    })
end

return Instapaper
