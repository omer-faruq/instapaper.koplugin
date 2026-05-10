# Instapaper Plugin for KOReader

Download and read articles from your Instapaper account directly in KOReader.

## Features

- **OAuth 1.0a authentication** using Instapaper's official Full API
- Browse **Unread**, **Starred**, **Archived**, and **custom folders**
- **Download and read** articles as HTML or EPUB in KOReader's built-in reader
- **EPUB output** — articles can be saved as EPUB files with optional image inclusion
- **Download only** (long-press → Download) without leaving the list — enables multi-article downloads
- **Article info on long-press**: date saved, word count, estimated reading time, progress, and source URL
- **Manage articles**: Archive, Delete, Star (via long-press)
- **Bulk download** with folder, time period, and post-download action (archive/delete/none)
- **Auto WiFi connect** — triggers network connection automatically when needed
- **Title injection** — missing article titles are added as a heading in the downloaded HTML
- **Reading progress** display (percentage read)
- **Configurable article list limit** — fetch up to 10, 25, 50, 100, 200, or 500 articles at once
- **Send to Instapaper** — Add web links to Instapaper directly from document link popups
- **Offline queue** — Links are queued when offline and automatically sent when network becomes available
- **Auto WiFi connect for links** — Configurable automatic network connection when adding links
- **Open downloads folder** shortcut in the menu
- **Clear downloads cache** — delete all downloaded files and folders with a single tap
- **Persistent credentials** — stay logged in across sessions

## Installation

1. Copy the `instapaper.koplugin` folder to your KOReader plugins directory:
   - For most devices: `koreader/plugins/instapaper.koplugin/`
   
2. Restart KOReader

## Setup

### 1. Get OAuth Consumer Credentials

Before you can use this plugin, you need to create OAuth consumer credentials on Instapaper:

1. Visit: <https://www.instapaper.com/developers/applications/create>
2. Fill out the form with your application details. Example:
    1. Title: `<your name> Personal`
    2. Description: `Accessing Instapaper via KOReader`
    3. URL: `https://koreader.rocks/`
    4. Admin Email: `your@email.com`
3. After you submit the **Consumer Key** and **Consumer Secret** are displayed. Copy these values.
4. Leave the OAuth key as "Owner Only" (the default). You do not need to click "Submit for Review".

### 2. Configure the Plugin

#### Option A: Via KOReader Menu (Recommended)

1. Open KOReader and go to the main menu (tap the top of the screen)
2. Navigate to **Tools** → (2nd or 3rd page) → **Instapaper**
3. Select **API credentials**
4. Enter your **Consumer Key** and **Consumer Secret**
5. Tap **Save**

#### Option B: Manual Configuration File

Alternatively, you can create a configuration file manually:

1. Create a file named `instapaper.lua` with the following content:
   ```lua
   -- instapaper.lua
   return {
       ["consumer_key"] = "your_consumer_key_here",
       ["consumer_secret"] = "your_consumer_secret_here",
   }
   ```

2. Copy this file to your KOReader settings directory:
   - **Kobo/Kindle/Android**: `koreader/settings/instapaper.lua`
   - **Desktop/Emulator**: `~/.config/koreader/settings/instapaper.lua` (Linux/macOS) or `%APPDATA%\koreader\settings\instapaper.lua` (Windows)

3. Restart KOReader

### 3. Log In

1. In the Instapaper menu, select **Log in**
2. Enter your Instapaper **email or username**
3. Enter your **password** (leave blank if you don't have one)
4. Tap **Login**

Once logged in, your OAuth tokens are saved and you won't need to log in again unless you explicitly log out.

## Usage

### Browse Articles

From the Instapaper menu, choose:
- **Unread articles** — Your reading list
- **Starred articles** — Articles you've starred
- **Archived articles** — Completed articles
- **Custom folders** — Lists your user-created Instapaper folders; tap one to browse its articles

### Read an Article

- **Tap** an article to download and open it in KOReader's reader
- Articles are saved to `koreader/instapaper/` as HTML or EPUB files depending on your settings
- If the article has no heading, its Instapaper title is automatically added at the top

### Long-press an Article

Long-pressing an article shows its metadata (date saved, word count, reading time, progress, URL) and the following actions:

- **Download** — Save the article locally without opening it or closing the list (useful for downloading multiple articles one by one)
- **Open** — Download and open the article immediately
- **Archive** — Move to archive
- **Star** — Add to starred
- **Delete** — Permanently delete from Instapaper

### Bulk Download

Select **Bulk download...** from the menu to download multiple articles at once:

- **Folder** — Choose which folder to download from (Unread, Starred, Archive, or any custom folder)
- **Period** — Limit to articles saved within the last N days (0 = all)
- **Archive after** — Automatically archive each article after downloading
- **Delete after** — Automatically delete each article after downloading (mutually exclusive with Archive)

### Open Downloads Folder

Select **Open downloads folder** to open the local `koreader/instapaper/` directory in KOReader's file manager.

### Clear Downloads Cache

Select **Clear downloads cache** to delete all downloaded files and folders (including `.sdr` metadata folders) from the downloads directory. A confirmation dialog is shown before deletion.

### Send Web Links to Instapaper

When reading a document that contains web links:

1. **Tap a link** in the document
2. In the link popup dialog, select **Add to Instapaper**
3. The link is sent to your Instapaper account:
   - If **network is online** → Sent immediately
   - If **Auto connect network** is ON → Network opens automatically and link is sent
   - If **Auto connect network** is OFF → Link is added to pending queue
4. Queued links are **automatically sent** when network becomes available

#### Process Pending Links Manually

If you have links waiting in the queue:

1. Open the Instapaper menu
2. Select **Process pending URLs (X)** where X is the number of queued links
3. Network will connect and all pending links will be sent

### Settings

Select **Settings** from the Instapaper menu to configure:

- **Article list limit** — Number of articles fetched per request: 10, 25, 50, 100, 200, or 500 (default: 50)
- **Output format** — Save articles as **HTML** (default) or **EPUB**
- **Include images (EPUB)** — When EPUB format is selected, optionally download and embed article images into the EPUB file (ON/OFF)
- **After download** — Action to perform after downloading individual articles (tap or long-press → Download/Open):
  - **None** (default) — No action, article stays in its current folder
  - **Archive only** — Move article to Archive folder
  - **Archive + Mark read** — Move to Archive and mark as 100% read
- **Auto connect network** — When adding links to Instapaper:
  - **ON** (default) — Automatically open network connection and send immediately
  - **OFF** — Add to pending queue without connecting; links are sent when network is opened elsewhere

## Implementation Details

This plugin uses the **Instapaper Full API** (OAuth 1.0a):

### Authentication
- **xAuth login**: `/api/1/oauth/access_token` with username/password → OAuth tokens
- **HMAC-SHA1 signing**: All API requests are signed using `openssl.hmac`
- **Persistent storage**: OAuth tokens saved in `settings/instapaper.lua`

### API Endpoints
- **`/api/1/bookmarks/list`** — Fetch articles (with folder filtering)
- **`/api/1/bookmarks/get_text`** — Download article HTML
- **`/api/1/bookmarks/add`** — Add a new bookmark (URL) to Instapaper
- **`/api/1/bookmarks/archive`** — Archive an article
- **`/api/1/bookmarks/update_read_progress`** — Update reading progress on an article
- **`/api/1/bookmarks/delete`** — Delete an article
- **`/api/1/bookmarks/star`** — Star an article
- **`/api/1/folders/list`** — Fetch user-created folders

### Offline Queue
- Pending links are stored in `settings/instapaper_pending.lua`
- Each queued item contains: URL, title, and timestamp
- Queue is automatically processed when:
  - Network connection is established (`onNetworkConnected` event)
  - Plugin loads and network is already online (`onReaderReady` event)
  - User manually triggers **Process pending URLs** from the menu

### OAuth 1.0a Signature
The plugin implements RFC 5849 OAuth 1.0a signature generation:
1. Percent-encode all parameters (RFC 3986)
2. Build signature base string (method + URL + sorted params)
3. Sign with HMAC-SHA1 using consumer secret + token secret
4. Base64-encode and add to Authorization header

## API Documentation

- Simple API: https://www.instapaper.com/api/simple
- Full API: https://www.instapaper.com/api/full

## Troubleshooting

### "Please set API credentials first"
You need to obtain OAuth consumer credentials from Instapaper first. See **Setup** section above.

### "Login failed"
- Check your username/email and password
- Verify your consumer key and secret are correct
- Ensure you have network connectivity

### Articles won't download
- Check network connection
- Verify you're still logged in (tokens may have expired)
- Try logging out and back in

## Development

This plugin was developed with assistance from [Windsurf](https://codeium.com/windsurf), an AI-powered code editor.

## License

This project is licensed under the GNU General Public License v3.0 (GPL-3.0). See the [LICENSE](LICENSE) file for details.
