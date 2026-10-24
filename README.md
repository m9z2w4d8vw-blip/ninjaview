# NinjaView

An iOS 17 app for viewing public TikTok profiles without an account, using [tik.ninja](https://tik.ninja). Every screen is native SwiftUI; tik.ninja's page runs hidden in the background as the data source.

## Install

Everything happens in the browser on github.com.

1. Download `NinjaView-repo.zip` and extract it (right-click, **Extract All**). Don't upload the .zip itself; GitHub won't unpack it.
2. On the repo page, choose **Add file > Upload files**.
3. Open the extracted folder, select everything inside it with Ctrl+A, and drag it onto the upload page. Folders have to be dragged; the "choose your files" picker only takes single files.
4. Leave it on **Commit directly to the main branch** and click **Commit changes**.

Uploaded files replace the ones with the same name and folder. Files you don't upload are left alone, so if an update ever removes or renames a file, delete the old copy on GitHub (open the file, then **... > Delete file**).

Uploads skip anything whose name starts with a dot, so they never change `.github/workflows/build.yml`. To change the workflow, open that file on GitHub, tap the pencil, replace its contents, and commit to `main`.

Every commit builds the app; watch it under **Actions** (about five minutes). If GitHub ever misses an upload, an hourly check at 17 minutes past the hour builds the newest commit on `main` once (it never builds a commit twice, and it removes its own checks that had nothing to do). **Run workflow** on the Actions tab builds on demand. Each build on `main` is published on the **Releases** page as `NinjaView.ipa`, a plain .ipa, not a zip. The newest one is always at `https://github.com/<you>/<repo>/releases/latest/download/NinjaView.ipa` (for a public repo). Builds on other branches attach the .ipa to their run on the Actions page instead.

On the iPhone, download the .ipa from Releases, open it in TrollStore, and tap **Install**. The build number goes up with every run, so TrollStore treats each one as an update.

If the build passes but the release step fails with a 403, go to **Settings > Actions > General > Workflow permissions**, choose **Read and write permissions**, and re-run the job.

If the build fails, open the failed run. The **Summarize compiler errors** step lists every error in one place.

## Using it

- Search for a username, or paste a TikTok profile, post or `vm.tiktok.com` link. The Paste button skips iOS's paste prompt.
- Profiles are laid out like Instagram's. The avatar has a ring when the account has stories; tap it to watch them. Highlights sit in a row of circles. Tap the Followers or Following count to open the list.
- The icon tabs switch between posts, reposts and stories. Grids load more as you scroll, and pulling down refreshes.
- Tap a post to open it in a list of posts, the way Instagram used to show them: the post you tapped, then the rest below it. Media stays inside the post at full width; nothing opens full screen. The video nearest the middle of the screen plays, muted until you tap it; the button in its corner pauses it. Swipe sideways through photo posts.
- Under each post: comments (with reply threads), share, audio (through tik.ninja's own download) and save to Photos. The ... menu has the same, plus copying the caption. Tapping an @mention in a caption opens that profile.
- Tapping a follower, a followed account or a commenter opens their profile.

### Comments and replies in archives

With **Include comments** on, an archive saves each post's comments (up to 400) and opens their reply threads (up to 150 threads per post, with every reply in each). Threads open one at a time with a short pause. A thread that won't open is almost always tik.ninja limiting requests, so the archive waits (5, then 10, then 20 seconds) and tries again, and after three refusals in a row it leaves the rest of that post's threads for later. **Update** on the archive revisits only those posts for their missing replies, without downloading the media again; archives made before this change get their missing replies the same way. A saved post's comments say when some replies are still missing.

### Instagram

Switch the home screen to **Instagram** and enter a username, @username or an instagram.com profile link. Instagram profiles come from insta-stories-viewer.com, loaded in a hidden page like tik.ninja is for TikTok; everything you see is native.

- **Stories and posts.** The profile shows the header, a row of current stories and a grid of posts. Tap a story (or the picture, when it has a pink ring) for full-screen stories that move on by themselves, or a post to page through posts. Swipe down to close; save to Photos or share from the bottom bar. The site lists an account's newest posts (12 at a time); **Show more posts** asks it for more when it has them.
- **Archive.** **Archive** on a profile saves its current stories to **Documents/Instagram/<username>/** (also in the Files app under On My iPhone > NinjaView > Instagram), and, signed in, every post with its comments. An Instagram archive looks and works exactly like a TikTok one: the header, **Update archive** / **Files** / more, then posts and stories in a grid that opens the same post list (swipe through carousels, including their videos) and the same comments sheet. **Update archive** adds only what's new, so stories stay after they disappear from Instagram, and it re-checks any post whose comments aren't all saved. Archived accounts are listed on the home screen; they open offline.
- **Notifications.** The bell on an Instagram profile offers **Posts** and **Stories**. Checks use the same schedule and modes as TikTok. When a watched account also has an archive, every check saves its new stories and posts into the archive, which is the reliable way to keep stories: they're saved within about one check interval of appearing.
- **Checks by the site.** If insta-stories-viewer.com asks to confirm you're a person, the profile says so; tap **Open the page**, finish the check, and close it. Automatic checks rest when the site refuses requests, the same way they do for tik.ninja.

The Instagram engine (`Sources/Instagram/IGAssets.swift`) is byte-identical to `igengine.js`, which was tested in Chromium against five saved insta-stories-viewer.com pages (stories, the story viewer, posts and the post viewer) plus simulated private, empty, retry, captcha and missing-account states.

### Signing in to Instagram (full posts and comments)

Without signing in, Instagram shows only an account's newest posts and NinjaView can't reach older ones; stories come from insta-stories-viewer.com. Sign in to archive an account's **full post history with comments**.

Add a sign-in under **Settings > Instagram sign-in** (username and password, kept only in this iPhone's Keychain). **Posts only ever come from your Instagram session**; the viewer site is used for stories alone.

- **The profile's posts, live.** Opening a profile loads its whole grid the way Instagram shows it: 3:4 tiles, pinned posts first, with the pin, carousel and reel badges, and the account's display name in the header. A carousel is one post, however many slides it has.
- **A post.** Tap a tile: its photos and videos open at once at their real shape (swipe through a carousel), with likes, caption and date, then its comments appear as they load, replies threaded underneath, with a count against Instagram's own (the number its grid shows when you hover over a post). GIF comments show their image.
- **Every comment.** Comments load the way they do on instagram.com: each **View replies** is opened, **+** (load more comments) is pressed until it's gone, and the list is scrolled to its end, since that loads more too. Each step waits for Instagram's answer rather than a fixed time, so a slow connection doesn't cut it short. A post counts as complete when nothing is left to open and its comments match Instagram's count; one that falls short says so (some may be hidden or deleted) and is retried on the next update. Each comment's text, author and time come from Instagram's own data whenever it sent that comment, and from the page otherwise. NinjaView's hidden page sometimes gets a different layout than desktop Chrome (no `<h3>` around names, "Hide all replies" toggles placed before the replies), and both are read correctly. When the page and Instagram's data disagree, the debug log says so with a short sample of the markup.
- **Archive all posts** scrolls the whole grid on the hidden page and opens each post for its photos, videos and complete comment threads, saving them into the same archive as the stories.

The hidden page asks for Instagram's **desktop** site, at a desktop size behind the app: there a post opens with its comments beside it, which the engine reads. (The phone site lists comments on a separate page, which is why they never loaded.) Because the session changed from the phone site to the desktop one, Instagram may ask once to confirm it's you; clear it from **Settings > Instagram sign-in > Open Instagram**.

**Important:**
- **Use a throwaway account.** Automating a real account can get it rate-limited or flagged. While signed in, that account is no longer anonymous; it's used only for archiving posts and comments.
- **Stories and highlights never use the sign-in**, under any circumstances. A guard injected before Instagram's own page runs refuses every story and highlight tap, request and navigation; this was tested against saved pages.
- **It runs only while the app is open.** A full history of a large account is a one-time wait, and Instagram may rate-limit partway; archiving saves as it goes and resumes on the next run, skipping posts already saved. A pause between posts keeps it under Instagram's limits.
- **A checkpoint** ("was this you", a code, or two-factor) surfaces as a prompt; open the page from Settings or the archiver, clear it, and run again.

The signed-in engine (`Sources/Instagram/IGSessionAssets.swift`) reads Instagram's own data first (its API answers and the JSON embedded in each page) and the page's markup as a fallback. It was checked in Chromium against saved desktop instagram.com pages (a signed-in profile grid, and a post's comments before and after opening replies) plus Instagram-shaped API data: the grid's order and badges, carousel slides never becoming posts, other accounts' posts left out, every comment and reply with its author, time and likes, clicking the icon-only "Load more comments" button, the post's own date, and stopping a read when another post opens. Comment loading was also run against those saved posts made to behave like the live page (each **+**, **View replies** and scroll to the end answering after a network delay, at 0.9 and 3.5 seconds): every comment and reply loaded on both posts, the count against Instagram's own was right both when it matched and when Instagram counted more than it shows, and comments arrived while loading was still running. A post opened as its own page (rather than over the grid) reads the same, and reading 2,000 comments takes about a tenth of a second.

### New-post notifications

Tap the **bell** on a profile to choose what that account notifies you about: **Posts**, **Stories** and **Reposts** (the three tik.ninja tabs, each checked separately and only if it's turned on). The bell turns pink, a line under the profile's buttons says which kinds are on, and a small pink bell appears on that account's picture on the home screen. Manage the list, change an account, or tap **Check now** under **Settings > Notifications > Watched accounts**. The first check of each kind is silent, so posts that were already there don't notify. Allow notifications when asked.

**Rate limits.** tik.ninja refuses requests when it gets too many (HTTP 429). When that happens, automatic checks rest for 5 minutes, then 10, 20, 40, up to an hour, and a tab that didn't load cleanly is never compared, so a refused check can't make old posts look new.

**Two background modes (Settings > Notifications > Background checking):**

- **Instant** (default) keeps NinjaView running with a silent, mixable audio session — the same idea as "keep my app alive" jailbreak tweaks, but built into the app, so it works through TrollStore with no jailbreak. It checks every poll interval (default 3 minutes), so alerts land within about one interval. It uses some battery, and **swiping NinjaView away in the app switcher stops it**; the "stopped watching" warning tells you if that happens. Background App Refresh runs as a backup.
- **Standard** checks only when the app is open and when iOS wakes it (Background App Refresh) — iOS's own schedule, usually every 15 minutes to a few hours, more often the more you use the app, never while force-quit. Lighter on battery.

The TrollStore build is fakesigned (with `ldid`, in the workflow) carrying the Time Sensitive notification entitlement, so alerts can get through Focus modes and the scheduled summary. Keep **Background App Refresh** on for NinjaView in iOS Settings for the background checks.

**One honest caveat.** NinjaView detects new activity by driving a hidden tik.ninja page, and iOS throttles web content in the background. Instant mode keeps the whole app awake, which gives the background checks their best chance, but whether that hidden page runs reliably in the background is the open question. The checks when the app is open always work. **Settings > Diagnostics > Export debug log (.txt)** records every check (filter the in-app log by the `watch` area) and whether it completed, so after a day you can see whether background checks are landing. If they aren't, a small script on an always-on computer is the reliable route — ask and I can build one.

### Offline copy for the session

Opening a profile starts a background download of everything on it: posts, reposts, stories and highlights (video files, photos and covers), comments with their reply threads, follower and following lists, and analytics. A line under the profile's buttons shows progress. Posts that have finished play from the phone. The copy is erased when NinjaView closes. It runs on its own hidden page, one profile at a time, newest first. Turn it off, or leave out comments or lists, in **Settings > Offline**.

### Archives

**Archive** on a profile saves the account's own content to keep: posts, stories, highlights, covers, comments, follower and following lists, and analytics. Reposts are left out. Archives survive restarts and work without a connection, in the same layout under **Archived** on the home screen.

- If the app closes mid-archive, the archive shows as paused. Tap **Resume** to continue where it stopped.
- **Update archive** fetches new posts. Posts that were deleted from the account stay in the archive.
- **Files** opens the archive in the Files app (On My iPhone > NinjaView > Archives). The menu can export it as a .zip, or delete it.

Limits per profile: 300 posts per tab for a session copy, 5,000 for an archive, 400 comments and 60 reply threads per post, and 2,000 accounts per follower list.

## How it works

Each profile screen owns an off-screen copy of tik.ninja's page, parked behind the app's interface. Swift drives it through a small injected script, `window.__nv`, which can search, open a tab, load more, open a post, read comments and expand replies. The script reads what tik.ninja rendered and returns JSON for SwiftUI to draw. Video and photo URLs come straight from that page, so playback and saving are native.

If tik.ninja shows a verification check, the profile screen says so, and **Show page** lets you get past it.

## When tik.ninja changes

The selectors live in `Sources/Engine/WebAssets.swift` (`engineJS`) and match tik.ninja's markup as of October 2026. **Settings > Diagnostics > Export debug log (.txt)** writes a report you can save to Files or send: a snapshot of the app, phone and connection, a summary of tik.ninja traffic (this launch, the last minute and five minutes, and minute by minute for the last hour), the latest lookup failure in full, then the log of this launch and the four before it. The log covers page loads and every engine call with its timing, each request tik.ninja's page makes (status, time, size, rate-limit headers), script errors and console warnings, downloads, playback, storage and app lifecycle. **Debug log** shows the same in the app, filterable by area and by warnings and errors, with a live count of tik.ninja traffic at the top.

### Debugging a refused lookup (HTTP 429)

"Server error — please try again. (HTTP 429)" is tik.ninja's own message: its server refused the search because too many requests reached it recently. NinjaView's hidden pages (the profile on screen, offline copies, archives and notification checks) and the app's own requests for thumbnails, saved media and video all share one connection, so they count against the same limit.

When a profile can't load, the error screen has **Debug details** under its buttons. The report it shows has:

- the lookup step by step: typing the handle, the click, each change of tik.ninja's status line, and every request the page made, with when it was sent, its status and how long it took;
- the page right after: its status line and markup, the search box, any verification elements, cookies and storage by name, its latest requests and any still waiting;
- tik.ninja traffic from the whole app in the last minute and the last five, by source (each hidden page, the app's images, saved media and so on), by endpoint and by status;
- what was running (offline copies, archives, notification checks), the connection (Wi-Fi or cellular, a VPN), and a short reading of what the evidence points to.

Copy it, or export the full log from the same screen.

In the debug log, lines from a hidden page start with its name, like `[P3 screen @name]`, `[P5 session copy @name]` or `[P7 watch check @name]`. The **traffic** area counts every request that reaches tik.ninja, writes one line a minute while there's traffic, and writes a full report the moment tik.ninja refuses something: the refused request with the headers sent and received and the start of the answer, Retry-After if tik.ninja sent it, the requests in the 10 seconds, minute and five minutes before it, and what was running. **Settings > Diagnostics > Verbose network log** adds headers and the start of the answer to requests that worked too, from the next profile you open.

Every hidden tik.ninja page has its own session (its own cookie jar), so one page loading tik.ninja can't knock out the session another page is using; Cloudflare's clearance cookie is carried into each new page. When tik.ninja refuses a page's session (HTTP 403: "⚠ Forbidden" or "The operation failed for an operation-specific reason"), the page starts a new session and tries again on its own. A page whose session went 18 minutes without an answer (the phone slept, say) starts a new one before it's used again: a profile on screen when the app comes back, or when you return to it; an offline copy or archive starts over on a fresh page and skips what it already saved. A preloaded page that waited more than 10 minutes is thrown away.

Errors in tik.ninja's status line are recognized by its error styling and by the page's own refused requests, so a refused lookup ends in under a second with the reason (rate limit, refused session, not found) instead of waiting 30 seconds. A list tik.ninja refuses shows why with Try again instead of looking finished, and copies wait out Retry-After and ask again rather than saving it as empty or skipping posts.

## Project layout

```
.github/workflows/build.yml   CI: XcodeGen, unsigned build, IPA, release
Sources/Instagram/              Instagram: anonymous viewer + signed-in posts/comments archiver
project.yml                   XcodeGen spec (iOS 17, unsigned)
Config/Info.plist             build number comes from the Actions run number
Resources/Assets.xcassets     app icon and accent color
Sources/App                   app entry, theme, settings, navigation, saved profiles
Sources/Engine                hidden pages: factory, dock, bridge, per-profile engine, injected JS and CSS
Sources/Library               offline copies and archives: storage, background downloader
Sources/Media                 saving to Photos, image loading, avatars, video player
Sources/Model                 data types and input parsing
Sources/Support               debug log, request tally, connection status, exported report
Sources/Views                 SwiftUI screens
```

NinjaView is unofficial and isn't affiliated with TikTok, ByteDance or tik.ninja.
