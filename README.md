# Instapaper Plugin for KOReader

Download and read articles from your Instapaper account directly in KOReader.

## Features

- **Instapaper API v2** (bearer token, JSON), with API v1 kept as a fallback
- **Log in with a personal access token**, or with email and password (xAuth, until 30 September 2027)
- Browse **Unread**, **Starred**, **Archived**, and **custom folders**
- **Download and read** articles as HTML or EPUB in KOReader's built-in reader
- **EPUB output** — articles can be saved as EPUB files with optional image inclusion
- **Book metadata** — byline (when the article markup carries one) and source site as authors, plus an auto-generated excerpt as the book description
- **Cover image** — a designed cover is drawn for the book: title on top, the article's lead image in a landscape band in the middle, author at the bottom (EPUB; can be turned off, and falls back to the bare lead image)
- **Chapters from headings** — the article's `<h1>`–`<h6>` levels become a nested table of contents in the EPUB
- **Download only** (long-press → Download) without leaving the list — enables multi-article downloads
- **Article info on long-press**: date saved, word count, estimated reading time, progress, and source URL
- **Manage articles**: Archive, Delete, Star (via long-press)
- **Bulk download** with folder, time period, and post-download action (archive/delete/none)
- **Auto WiFi connect** — triggers network connection automatically when needed
- **Title injection** — missing article titles are added as a top-level heading in the downloaded HTML
- **Reading progress** display (percentage read)
- **Paged article lists** — 50 articles at a time with **Load more…** at the end (API v2); API v1 fetches one page of 10–500
- **Refresh** — the reload icon at the top left of a list reloads it with the latest data, staying on the same page
- **Continue** — for an hour after you last used a list (until KOReader restarts), **Continue: <folder> (page N)** at the top of the Instapaper menu reopens it where you left off, without a network request. Articles archived by **When finished** are left out and progress made on the device is shown. Also available as the gesture action **Instapaper: continue last list**; when there is nothing recent to continue, the gesture opens the last used folder (or Unread) fresh from the server and says so
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

There are two ways to log in. The **access token** is the recommended one: it
needs no password and nothing else to configure.

| | Access token (recommended) | Email and password (xAuth) |
|---|---|---|
| Needs | an access token | consumer key + secret, then email + password |
| API | v2 only | v2, or v1 as a fallback |
| Lifetime | until you revoke it | Instapaper turns xAuth off for new logins on **30 September 2027** (existing logins keep working) |

### 1. Create an Application on Instapaper

Both ways start with an application of your own on Instapaper:

1. Visit: <https://www.instapaper.com/developers/applications/create>
2. Fill out the form with your application details. Example:
    1. Title: `<your name> Personal`
    2. Description: `Accessing Instapaper via KOReader`
    3. URL: `https://koreader.rocks/`
    4. Admin Email: `your@email.com`
3. After you submit, the **Consumer Key** and **Consumer Secret** are displayed. Copy them if you want the email and password login.
4. Leave the OAuth key as "Owner Only" (the default). You do not need to click "Submit for Review".
   An owner-only application also means article text is fetched as *personal
   use*, which needs no Instaparser key.
5. For the access token login: on <https://www.instapaper.com/developers/applications>,
   generate an **access token** for your application and copy it.

### 2. Configure the Plugin (email and password login only)

Skip this step if you log in with an access token.

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
2. Choose a method:
   - **Access token** — paste the token and tap **Login**. The plugin checks it
     against Instapaper and shows your username in the **Log out** entry.
   - **Email and password** — enter your Instapaper **email or username** and
     your **password** (leave blank if you don't have one), then tap **Login**
3. Once logged in, the token is saved and you won't need to log in again unless you explicitly log out.

### Upgrading from 1.5 or earlier

Nothing to do. The token saved by the old email and password login is used as
an API v2 bearer token, so you stay logged in. If Instapaper ever turns that
token away on v2 before v2 has worked once for it, the plugin switches itself
to API v1 and asks you to try again. You can also switch by hand under
**Settings → API**.

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
- **After download** — None, **Archive**, or **Delete from Instapaper** for each downloaded article (the downloaded file is kept)

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

**Settings** in the Instapaper menu opens a submenu. Each row shows its current value, and changes are saved immediately:

- **Article list limit (API v1)** — Number of articles fetched per request: 10, 25, 50, 100, 200, or 500 (default: 50). Disabled with API v2, where lists load 50 at a time with **Load more…**
- **Output format** — Save articles as **HTML** (default) or **EPUB**
- **Include images (EPUB)** — When EPUB format is selected, optionally download and embed article images into the EPUB file (ON/OFF)
- **Designed cover (EPUB)** — Draw a title/image/author cover instead of using the lead image as is (ON/OFF, default ON). With images off, the cover is still drawn, just without the picture
- **After single download** — Action to perform after downloading individual articles (tap or long-press → Download/Open; bulk download has its own setting):
  - **None** (default) — No action, article stays in its current folder
  - **Archive only** — Move article to Archive folder
  - **Archive + Mark read** — Move to Archive and mark as 100% read
- **When finished** — Action when you close an article you have finished (last page reached, or marked as finished in KOReader):
  - **None** (default) — No action
  - **Archive** — Move the article to the Archive folder
  - **Archive + Delete file** — Archive it, then delete the downloaded file and its sidecar from the device

  Works offline: the article is archived (and deleted) the next time the device is online.
- **Return to list from an article** — ways back to the list an article was opened from (articles opened from the file browser are not affected):
  - **Button position** — Top left, Top right, Bottom left, Bottom right (default; above the status bar), or Off
  - **Show button** — Show the small **Insta** button in that corner. When hidden, tapping the corner still returns to the list
  - **Ask at end of article** — Replace the end-of-document dialog with one offering **Back to Instapaper list**, **Go to beginning** and **File browser**
  - **Back key returns to the list** — On devices with keys, when there is nothing to go back to inside the article

  Closing the list you returned to also closes the article and opens the file browser, so the two do not loop.
- **Auto connect network** — When adding links to Instapaper:
  - **ON** (default) — Automatically open network connection and send immediately
  - **OFF** — Add to pending queue without connecting; links are sent when network is opened elsewhere
- **API** — **v2** (default) or **v1**. v1 is only available after an email and
  password login; an access token works with v2 only. It is there as a way back
  in case v2 misbehaves, and v1 lists stop at 500 articles.

## Implementation Details

This plugin uses the **Instapaper API v2** (`https://www.instapaper.com/api/2`,
JSON, OAuth 2 bearer token). API v1 (OAuth 1.0a) is kept behind the same
functions as a fallback; `instapaper_v2.lua` maps v2 responses onto the
bookmark shape the rest of the plugin has always used.

### Authentication
- **Access token**: sent as `Authorization: Bearer <token>`, checked on login with `GET /me`
- **xAuth login** (v1, until 30 September 2027): `/api/1/oauth/access_token` with username/password → OAuth token + token secret. The token also works as a v2 bearer token.
- **HMAC-SHA1 signing**: v1 requests only
- **Persistent storage**: tokens saved in `settings/instapaper.lua` (`oauth_token`; `oauth_token_secret` only for xAuth). `api_version` and `v2_confirmed` record which API is in use and whether v2 has worked for this login yet.

### API Endpoints

| Action | v2 | v1 fallback |
|---|---|---|
| List articles | `GET /bookmarks?section=home\|liked\|archive\|folder&folder_id=&limit=&offset=` (paged, no cap) | `/api/1/bookmarks/list` (max 500) |
| Article text | `GET /bookmarks/{id}/parse` (JSON: body HTML + metadata) | `/api/1/bookmarks/get_text` |
| Add a link | `POST /bookmarks` | `/api/1/bookmarks/add` |
| Archive | `POST /bookmarks/{id}/move` `{"section":"archive"}` | `/api/1/bookmarks/archive` |
| Reading progress | `POST /bookmarks/{id}` `{"progress":{"percentage","timestamp"}}` | `/api/1/bookmarks/update_read_progress` |
| Delete | `DELETE /bookmarks/{id}` | `/api/1/bookmarks/delete` |
| Star | `POST /bookmarks/{id}/like` | `/api/1/bookmarks/star` |
| Custom folders | `GET /folders` | `/api/1/folders/list` |
| Username | `GET /me` | — |

The v2 parse endpoint returns only the article body. The plugin wraps it into a
full HTML document (`<title>`, the byline as `<meta name="author">`, `dir="rtl"`
for right-to-left articles), so the HTML and EPUB builders work the same on
both APIs.

### Book Metadata

API v2 returns the byline (`author`) with each bookmark and the parsed article;
v1 returns no author at all. Neither gives a usable excerpt or cover, so the
rest below is derived from bytes the plugin has already downloaded — no article
ever costs an extra HTTP request for metadata:

- **Authors** — the source site (from the URL host) is always written. The
  byline from API v2 is written above it; on v1 (or when v2 has none), a
  `<meta name="author">`, `article:author`, `rel="author"` or
  `itemprop="author"` in the article HTML is used instead. Two
  `dc:creator` entries: crengine joins them with a newline and KOReader's book
  information shows one per line. Guesses that look like a date, a URL or a
  sentence are dropped — no author is better than a wrong one.
- **Description** — Instapaper's own `description` is used when it has one (on
  v1 it is user-supplied and empty for most articles; v2 falls back to the
  article's opening text). Otherwise a ~320-character excerpt is built from the
  article's first paragraphs, with headings and figure captions removed.
- **Cover** — the lead image is picked from the images already downloaded for
  the body: the first one at least 300×200 with a sane aspect ratio, measured by
  reading PNG/GIF/JPEG headers straight out of memory. API v2 does return a
  thumbnail URL, but using it would cost an extra download per article, so it
  is not used yet.

  With **Designed cover** on, that image is not used as the cover directly.
  Instead a 600×800 grayscale bitmap is painted — title (up to 4 lines), the
  image filling a landscape band no taller than 320px, then the
  author (up to 2 lines) with the source site in smaller type under it — and
  stored as `images/cover.png`. The signature follows the EPUB metadata: when
  the article carries no byline, the site takes the author slot instead of
  leaving the cover unsigned. Title and author
  fonts shrink until the widest word fits, and whatever still does not fit is
  cut with an ellipsis, so long headlines and long bylines both stay inside the
  page. The image is scaled to fill the band rather than fit inside it — the
  aspect ratio is kept, small images are scaled up, and the overflow is cropped
  off the long axis (centered horizontally, slightly above center vertically),
  so the band is never left with empty margins. If anything goes wrong the plain
  lead-image cover is used instead.

  With no usable lead image the cover switches to a text-only layout rather than
  leaving a hole in the middle: bigger type (title up to 72px over 8 lines,
  byline up to 44px) and the whole block centered on the page. The title only
  gets as many lines as the signature leaves room for, so nothing runs off the
  page.
- **Chapters** — `<h1>`–`<h6>` in the article get anchors, and the NCX gets a
  nested navMap pointing at them. Heading levels are normalized, so an article
  built out of `<h2>`/`<h3>` still starts at TOC depth 1.

For HTML output the same values are written to KOReader's metadata sidecar
instead (`custom_metadata.lua`), since crengine only reads `<title>` from plain
HTML. Cover and chapters are EPUB-only.

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

- API v2 announcement: https://blog.instapaper.com/2026/09/29/instapaper-api-v2/
- API v2 docs: https://www.instapaper.com/developers/overview/introduction
- API v2 OpenAPI spec: https://www.instapaper.com/api/2/openapi.json
- Migrating from v1: https://www.instapaper.com/developers/overview/migrating-from-v1
- Full API (v1): https://www.instapaper.com/api/full

## Troubleshooting

### "Email and password login needs API credentials first"
The email and password login needs your application's consumer key and secret.
See **Setup** above, or log in with an access token instead.

### "Login failed"
- Access token: check that you copied the whole token and that it has not been revoked (HTTP 401)
- Email and password: check your username/email and password, and that the consumer key and secret are correct. After 30 September 2027 this login no longer works; use an access token
- Ensure you have network connectivity

### "API v2 did not accept this login, so the plugin switched back to API v1"
Your saved email and password login was turned away by v2 before v2 had ever
worked for it. Everything keeps working on v1. To try v2 again, pick
**Settings → API → v2**, or log out and log in with an access token.

### Download failed: HTTP 402 / HTTP 429
Instapaper's article parser (Instaparser) is out of free credits (402) or rate
limited (429). Wait a while and try again; for bulk downloads, download fewer
articles at a time.

### Articles won't download
- Check network connection
- Verify you're still logged in (tokens may have expired)
- Try logging out and back in

## Development

This plugin was developed with assistance from [Windsurf](https://codeium.com/windsurf), an AI-powered code editor.

## License

This project is licensed under the GNU General Public License v3.0 (GPL-3.0). See the [LICENSE](LICENSE) file for details.
