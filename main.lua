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
    self:loadPendingPool()
    if self.ui and self.ui.link then
        self:registerLinkPopupButton()
    end
end

function Instapaper:onReaderReady()
    if self:countPending() > 0 then
        local NetworkMgr = require("ui/network/manager")
        if NetworkMgr:isOnline() then
            UIManager:scheduleIn(2, function()
                self:drainPendingQueue({ silent = true })
            end)
        end
    end
end

function Instapaper:onNetworkConnected()
    if self:countPending() == 0 then return end
    UIManager:scheduleIn(1, function()
        self:drainPendingQueue({ silent = false })
    end)
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
    self.auto_connect_network = self.settings:readSetting("auto_connect_network")
    if self.auto_connect_network == nil then
        self.auto_connect_network = true
    end
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
    self.settings:saveSetting("auto_connect_network", self.auto_connect_network)
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
            },
            {
                text_func = function()
                    local count = #self:getPendingUrls()
                    if count > 0 then
                        return T(_("Process pending URLs (%1)"), tostring(count))
                    else
                        return _("Process pending URLs")
                    end
                end,
                callback = function()
                    self:processPendingPool()
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
    local auto_connect = self.auto_connect_network
    if auto_connect == nil then
        auto_connect = true
    end

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

        local auto_label = auto_connect and _("ON") or _("OFF")
        
        settings_dialog = ButtonDialog:new{
            title = _("Instapaper settings")
                .. "\n" .. _("Article list limit: ") .. limit_label
                .. "\n" .. _("Output format: ") .. fmt_label
                .. "\n" .. _("Include images (EPUB): ") .. img_label
                .. "\n" .. _("After download: ") .. action_label
                .. "\n" .. _("Auto connect network: ") .. auto_label
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
                        text = _("Auto connect: ") .. (auto_connect and _("ON") or _("OFF")),
                        callback = function()
                            auto_connect = not auto_connect
                            rebuildSettingsDialog()
                        end,
                    },
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
                            self.auto_connect_network = auto_connect
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
                            -- Security check: prevent dangerous paths
                            if self:isDangerousPath(new_path) then
                                UIManager:show(InfoMessage:new{
                                    text = _("This path cannot be used as a cache folder for safety reasons.\n\nPlease choose a subfolder instead of a system directory."),
                                })
                                if return_callback then
                                    return_callback(current_folder)
                                end
                                return
                            end
                            
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
    local InstapaperEpub = require("instapaper_epub")
    return InstapaperEpub.buildFilePath(self:getDownloadDir(), bookmark, "html")
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
    -- <h1>, not a smaller heading: the EPUB builder turns heading levels into
    -- chapters, and the article title has to sit at the top of that hierarchy.
    local inject = "<h1>" .. escaped .. "</h1>\n"
    -- Insert after <body> tag if present, otherwise prepend
    local result, n = html:gsub("(<body[^>]*>)", "%1\n" .. inject, 1)
    if n == 0 then
        result = inject .. html
    end
    return result
end

-- Write KOReader's own metadata sidecar (custom_metadata.lua) for a downloaded
-- article so that the title, author/origin and description show up in the file
-- manager and "Book information" dialog.
--
-- This is needed because crengine only reads <title> from plain HTML; it does
-- not extract author/description from HTML <meta> tags (EPUB gets these from the
-- OPF instead). custom_props override whatever the engine extracts.
function Instapaper:writeBookMetadata(filepath, bookmark, html)
    if not filepath then return end

    local InstapaperEpub = require("instapaper_epub")
    local title = bookmark.title
    if title == "" then title = nil end

    -- Byline (when the article markup happens to carry one) above the source
    -- site, matching how crengine reports several dc:creator entries in EPUBs.
    local site = InstapaperEpub.deriveSiteName(bookmark.url)
    local author = html and InstapaperEpub.extractAuthor(html) or nil
    local authors
    if author and site then
        authors = author .. "\n" .. site
    else
        authors = author or site
    end

    local description = bookmark.description
    if description == "" then description = nil end
    if not description and html then
        description = InstapaperEpub.buildExcerpt(html)
    end

    if not (title or authors or description) then return end

    local props = {}
    if title       then props.title       = title       end
    if authors     then props.authors     = authors     end
    if description then props.description  = description end

    -- Wrapped in pcall: writing metadata is best-effort. If a future KOReader
    -- release changes the DocSettings custom-metadata API, we must not let that
    -- break the article download itself -- worst case, metadata is just skipped.
    local ok, err = pcall(function()
        local DocSettings = require("docsettings")
        local doc_settings = DocSettings.openSettingsFile()
        -- doc_props: a backup of the "original" metadata, used as a fast fallback
        -- for display before the document has ever been opened.
        doc_settings:saveSetting("doc_props", {
            title = title, authors = authors, description = description,
        })
        -- custom_props: overrides that always win over engine-extracted metadata.
        doc_settings:saveSetting("custom_props", props)
        return doc_settings:flushCustomMetadata(filepath)
    end)
    if not ok then
        logger.warn("Instapaper: could not write metadata sidecar for", filepath, err)
    end
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
    local filepath
    local is_html = true
    if fmt == "epub" then
        local InstapaperEpub = require("instapaper_epub")
        local err
        filepath, err = InstapaperEpub.createEpub(
            bookmark, html, self:getDownloadDir(), self.include_images)
        if filepath then
            is_html = false
        else
            logger.warn("Instapaper: EPUB creation failed, falling back to HTML", err)
            filepath = self:saveArticleHtml(bookmark, html)
        end
    else
        filepath = self:saveArticleHtml(bookmark, html)
    end
    -- EPUB carries its metadata in the OPF (read natively by crengine), so we
    -- only need the KOReader metadata sidecar for HTML output.
    if is_html then
        self:writeBookMetadata(filepath, bookmark, html)
    end
    return filepath
end

-- Download only (no open), keeps caller menu open
function Instapaper:downloadArticleOnly(bookmark)
    -- Painted before the blocking fetch, and closed by hand afterwards: a
    -- timeout alone would never make it to the screen.
    local info = InfoMessage:new{
        text = _("Downloading article..."),
    }
    UIManager:show(info)
    UIManager:forceRePaint()

    local html, err = self:fetchArticleHtml(bookmark)
    if not html then
        UIManager:close(info)
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed (HTTP %1)"), tostring(err)),
        })
        return
    end

    local filepath = self:saveArticle(bookmark, html)
    UIManager:close(info)
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
    local info = InfoMessage:new{
        text = _("Downloading article..."),
    }
    UIManager:show(info)
    UIManager:forceRePaint()

    local html, err = self:fetchArticleHtml(bookmark)
    if not html then
        UIManager:close(info)
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed (HTTP %1)"), tostring(err)),
        })
        return
    end

    local filepath = self:saveArticle(bookmark, html)
    UIManager:close(info)
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

    -- Security check: if using custom folder, disable cache wipe
    local using_custom = self.cache_folder and self.cache_folder ~= ""
    if using_custom then
        UIManager:show(InfoMessage:new{
            text = _("Cache clearing is disabled when using a custom cache folder for safety reasons.\n\nTo clear the cache, please manually delete Instapaper files from your custom folder."),
        })
        return
    end

    -- Additional safety check for dangerous paths
    if self:isDangerousPath(dir) then
        UIManager:show(InfoMessage:new{
            text = _("Cannot clear cache: the cache folder path appears to be a system directory.\n\nPlease check your cache folder settings."),
        })
        return
    end

    UIManager:show(ConfirmBox:new{
        text = _("Delete Instapaper files (.html, .epub, .sdr, .tmp) from the downloads folder?"),
        ok_text = _("Delete"),
        ok_callback = function()
            self:_doClearDownloadsCache(dir)
        end,
    })
end

function Instapaper:_doClearDownloadsCache(dir)
    -- Only delete files created by Instapaper plugin
    local function isInstapaperFile(filename)
        local lower = filename:lower()
        -- Match .html, .epub files, .sdr folders, and .tmp files from failed EPUB creation
        return lower:match("%.html$") or lower:match("%.epub$") or lower:match("%.sdr$") or lower:match("%.tmp$")
    end

    local function removeInstapaperFiles(path)
        local attr = lfs.attributes(path)
        if not attr then return 0 end
        
        local removed = 0
        if attr.mode == "directory" then
            -- Recursively remove files in .sdr folders
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    removed = removed + removeInstapaperFiles(path .. "/" .. entry)
                end
            end
            -- Try to remove the directory if it's a .sdr folder and now empty
            if path:match("%.sdr$") then
                lfs.rmdir(path)
            end
        else
            -- Only remove if it's an Instapaper file
            if isInstapaperFile(path) then
                os.remove(path)
                removed = 1
            end
        end
        return removed
    end

    local count = 0
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local full_path = dir .. "/" .. entry
            count = count + removeInstapaperFiles(full_path)
        end
    end
    
    UIManager:show(InfoMessage:new{
        text = T(_("Deleted %1 Instapaper file(s) from downloads folder."), count),
        timeout = 3,
    })
end

function Instapaper:isDangerousPath(path)
    if not path or path == "" then
        return false
    end
    
    -- Normalize path
    local normalized = path:gsub("//+", "/"):gsub("/$", "")
    
    -- Dangerous paths that should never be used as cache folder
    local dangerous_paths = {
        "/",
        "/mnt",
        "/mnt/onboard",
        "/mnt/sd",
        "/mnt/us",
        "/mnt/us/documents",
        "/sdcard",
        "/storage",
        "/system",
        "/data",
        "/etc",
        "/bin",
        "/usr",
        "/lib",
        "/home",
        "/root"
    }
    
    for _, dangerous in ipairs(dangerous_paths) do
        if normalized == dangerous then
            return true
        end
    end
    
    return false
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

-- Shorten a title for the one-line progress message (UTF-8 safe).
local function shortenForProgress(title)
    if not title or title == "" or type(title) ~= "string" then
        return _("Untitled")
    end
    local chars = util.splitToChars(title)
    if #chars <= 48 then
        return title
    end
    return table.concat(chars, "", 1, 45) .. "…"
end

function Instapaper:runBulkDownload(folder_id, days_limit, archive_after, delete_after)
    local Trapper = require("ui/trapper")
    -- The whole run happens inside a Trapper coroutine so that Trapper:info()
    -- can repaint between articles and let the user abort; without it the
    -- download loop blocks the UI event loop and the device looks frozen.
    Trapper:wrap(function()
        Trapper:info(_("Fetching article list..."))

        local params = { limit = "500" }  -- bulk always fetches max
        if folder_id then
            params.folder_id = folder_id
        end

        local ok, body, code = self:apiRequest("/api/1/bookmarks/list", params)
        if not ok then
            Trapper:clear()
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to fetch articles: %1"), body or tostring(code)),
            })
            return
        end

        local parse_ok, data = pcall(JSON.decode, body)
        if not parse_ok or type(data) ~= "table" then
            Trapper:clear()
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
            Trapper:clear()
            UIManager:show(InfoMessage:new{
                text = _("No articles match the selected filters."),
            })
            return
        end

        -- Download sequentially, reporting progress between articles.
        -- setPausedText writes to Trapper's singleton state, so the exit below
        -- must reset() (not just clear()) or this text leaks into every other
        -- Trapper user for the rest of the session.
        Trapper:setPausedText(_("Bulk download paused."), _("Abort"), _("Continue"))
        local total      = #bookmarks
        local downloaded = 0
        local failed     = 0
        local aborted    = false
        local started_at = os.time()

        for i, bm in ipairs(bookmarks) do
            -- Estimate remaining time from the articles done so far.
            local eta = ""
            if i > 1 then
                local per_article = (os.time() - started_at) / (i - 1)
                local minutes_left = math.ceil(per_article * (total - i + 1) / 60)
                if minutes_left > 0 then
                    eta = "\n" .. T(_("about %1 min left"), tostring(minutes_left))
                end
            end
            -- Returns false when the user dismisses the message and confirms Abort.
            local go_on = Trapper:info(T(_("Downloading %1 / %2\n%3%4"),
                tostring(i), tostring(total), shortenForProgress(bm.title), eta))
            if not go_on then
                aborted = true
                break
            end

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

        Trapper:reset()

        local msg
        if aborted then
            msg = T(_("Bulk download aborted.\nDownloaded: %1  Failed: %2  Left: %3"),
                tostring(downloaded), tostring(failed),
                tostring(total - downloaded - failed))
        else
            msg = T(_("Bulk download complete.\nDownloaded: %1  Failed: %2"),
                tostring(downloaded), tostring(failed))
        end
        UIManager:show(InfoMessage:new{
            text = msg,
        })
    end)
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

--------------------------------------------------------------------
-- Pending pool for offline link saving
--------------------------------------------------------------------

function Instapaper:loadPendingPool()
    self.pending_pool = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/instapaper_pending.lua")
end

function Instapaper:getPendingUrls()
    if not self.pending_pool then
        self:loadPendingPool()
    end
    return self.pending_pool:readSetting("pending_urls") or {}
end

function Instapaper:savePendingUrls(urls)
    if not self.pending_pool then
        self:loadPendingPool()
    end
    self.pending_pool:saveSetting("pending_urls", urls)
    self.pending_pool:flush()
end

function Instapaper:addToPendingPool(url, title)
    local pending = self:getPendingUrls()
    table.insert(pending, {
        url = url,
        title = title or url,
        added_at = os.time(),
    })
    self:savePendingUrls(pending)
end

function Instapaper:countPending()
    return #self:getPendingUrls()
end

function Instapaper:drainPendingQueue(opts)
    opts = opts or {}
    if self._draining then return end
    if not self:isLoggedIn() then return end
    
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then return end
    
    local pending = self:getPendingUrls()
    if #pending == 0 then return end
    
    self._draining = true
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local success_count = 0
        local fail_count = 0
        local remaining = {}
        local stopped_for_network = false
        local last_err
        
        for i, item in ipairs(pending) do
            if stopped_for_network then
                table.insert(remaining, item)
            else
                -- Background drains stay quiet; an explicit drain reports progress.
                if not opts.silent then
                    Trapper:info(T(_("Sending pending URL %1 / %2"),
                        tostring(i), tostring(#pending)))
                end
                local ok = self:addBookmark(item.url, item.title)
                if ok then
                    success_count = success_count + 1
                else
                    fail_count = fail_count + 1
                    if not NetworkMgr:isOnline() then
                        stopped_for_network = true
                        table.insert(remaining, item)
                    else
                        table.insert(remaining, item)
                        last_err = "Failed to add bookmark"
                    end
                end
            end
        end
        
        self:savePendingUrls(remaining)
        self._draining = false
        Trapper:clear()

        if opts.silent then return end
        if success_count == 0 and fail_count == 0 then return end
        
        local parts = {}
        if success_count > 0 then
            table.insert(parts, T(_("Sent %1 pending URL(s) to Instapaper."), success_count))
        end
        if fail_count > 0 then
            table.insert(parts, T(_("Failed: %1"), fail_count))
            if last_err then
                table.insert(parts, "(" .. last_err .. ")")
            end
        end
        if #remaining > 0 then
            table.insert(parts, T(_("%1 still pending."), #remaining))
        end
        
        local Notification = require("ui/widget/notification")
        UIManager:show(Notification:new{ text = table.concat(parts, " ") })
    end)
end

function Instapaper:processPendingPool()
    if not self:isLoggedIn() then
        UIManager:show(InfoMessage:new{
            text = _("Please log in first."),
        })
        return
    end
    
    local pending = self:getPendingUrls()
    if #pending == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No pending URLs."),
            timeout = 2,
        })
        return
    end
    
    NetworkMgr:runWhenOnline(function()
        self:drainPendingQueue({ silent = false })
    end)
end

--------------------------------------------------------------------
-- Add bookmark API
--------------------------------------------------------------------

function Instapaper:addBookmark(url, title, description)
    if not url or url == "" then
        return false
    end
    
    local params = { url = url }
    if title and title ~= "" then
        params.title = title
    end
    if description and description ~= "" then
        params.description = description
    end
    
    local ok, body, code = self:apiRequest("/api/1/bookmarks/add", params)
    
    if ok then
        logger.info("Instapaper: bookmark added", url)
        return true
    else
        logger.warn("Instapaper: failed to add bookmark", url, code)
        return false
    end
end

function Instapaper:addBookmarkFromLink(url, title)
    if not self:isLoggedIn() then
        UIManager:show(InfoMessage:new{
            text = _("Please configure and log in to Instapaper first."),
            timeout = 2,
        })
        return
    end
    
    local NetworkMgr = require("ui/network/manager")
    
    -- If network is already online, try to send immediately
    if NetworkMgr:isOnline() then
        local ok = self:addBookmark(url, title)
        if ok then
            UIManager:show(InfoMessage:new{
                text = _("Added to Instapaper."),
                timeout = 2,
            })
        else
            self:addToPendingPool(url, title)
            UIManager:show(InfoMessage:new{
                text = _("Failed. Added to pending pool."),
                timeout = 2,
            })
        end
        return
    end
    
    -- Network is offline
    if self.auto_connect_network then
        -- Try to connect and send
        NetworkMgr:runWhenOnline(function()
            local ok = self:addBookmark(url, title)
            if ok then
                UIManager:show(InfoMessage:new{
                    text = _("Added to Instapaper."),
                    timeout = 2,
                })
            else
                self:addToPendingPool(url, title)
                UIManager:show(InfoMessage:new{
                    text = _("Failed. Added to pending pool."),
                    timeout = 2,
                })
            end
        end)
    else
        -- Auto connect is off, add to pool
        self:addToPendingPool(url, title)
        UIManager:show(InfoMessage:new{
            text = _("Added to pending pool."),
            timeout = 2,
        })
    end
end

--------------------------------------------------------------------
-- Link popup button
--------------------------------------------------------------------

function Instapaper:registerLinkPopupButton()
    if not self.ui or not self.ui.link then
        return
    end
    
    local Blitbuffer = require("ffi/blitbuffer")
    
    self.ui.link:addToExternalLinkDialog("45_add_to_instapaper", function(external_dialog, link_url)
        return {
            text = _("Add to Instapaper"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(external_dialog.external_link_dialog)
                local target_url = link_url
                if type(target_url) ~= "string" or not target_url:match("^https?://") then
                    UIManager:show(InfoMessage:new{
                        text = _("Invalid URL."),
                        timeout = 2,
                    })
                    return
                end
                self:addBookmarkFromLink(target_url, target_url)
            end,
            show_in_dialog_func = function()
                return type(link_url) == "string" and link_url:match("^https?://") ~= nil
            end,
        }
    end)
end

return Instapaper
