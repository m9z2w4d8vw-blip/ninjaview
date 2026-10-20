# NinjaView

An iOS 17 app for viewing public TikTok profiles without an account, using [tik.ninja](https://tik.ninja). Every screen is native SwiftUI; tik.ninja's page runs hidden in the background as the data source.

## Install

Everything happens in the browser on github.com.

1. Download `NinjaView-repo.zip` and extract it (right-click, **Extract All**). Don't upload the .zip itself; GitHub won't unpack it.
2. On the repo page, choose **Add file > Upload files**.
3. Open the extracted folder, select everything inside it with Ctrl+A (including `.github` and `.gitignore`), and drag it onto the upload page. Folders have to be dragged; the "choose your files" picker only takes single files.
4. Leave it on **Commit directly to the main branch** and click **Commit changes**.

Uploaded files replace the ones with the same name and folder. Files you don't upload are left alone, so if an update ever removes or renames a file, delete the old copy on GitHub (open the file, then **... > Delete file**).

Every commit builds the app; watch it under **Actions** (about five minutes). Each build on `main` is published on the **Releases** page as `NinjaView.ipa`, a plain .ipa, not a zip. The newest one is always at `https://github.com/<you>/<repo>/releases/latest/download/NinjaView.ipa` (for a public repo). Builds on other branches attach the .ipa to their run on the Actions page instead.

On the iPhone, download the .ipa from Releases, open it in TrollStore, and tap **Install**. The build number goes up with every run, so TrollStore treats each one as an update.

If the build passes but the release step fails with a 403, go to **Settings > Actions > General > Workflow permissions**, choose **Read and write permissions**, and re-run the job.

If the build fails, open the failed run. The **Summarize compiler errors** step lists every error in one place.

## Using it

- Search for a username, or paste a TikTok profile, post or `vm.tiktok.com` link. The Paste button skips iOS's paste prompt.
- Profiles are laid out like Instagram's. The avatar has a ring when the account has stories; tap it to watch them. Highlights sit in a row of circles. Tap the Followers or Following count to open the list.
- The icon tabs switch between posts, reposts and stories. Grids load more as you scroll, and pulling down refreshes.
- Tap a post to open the viewer. Swipe up and down between posts and sideways through photo posts. Tap a video to pause it, and drag along the bottom bar to scrub.
- The viewer's buttons: **Comments** (with reply threads), **Save** (video or photos to Photos), **Audio** (through tik.ninja's own download, opens the share sheet), **Sound**, and **Player** (the system player, with Picture in Picture and AirPlay).
- Tapping a follower, a followed account or a commenter opens their profile.

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

The selectors live in `Sources/Engine/WebAssets.swift` (`engineJS`) and match tik.ninja's markup as of October 2026. **Settings > Debug log** records page loads, script errors, each request tik.ninja's page makes (filter by `net`), downloads and playback failures. Share it to diagnose a break.

## Project layout

```
.github/workflows/build.yml   CI: XcodeGen, unsigned build, IPA, release
project.yml                   XcodeGen spec (iOS 17, unsigned)
Config/Info.plist             build number comes from the Actions run number
Resources/Assets.xcassets     app icon and accent color
Sources/App                   app entry, theme, settings, navigation, saved profiles
Sources/Engine                hidden pages: factory, dock, bridge, per-profile engine, injected JS and CSS
Sources/Library               offline copies and archives: storage, background downloader
Sources/Media                 saving to Photos, image loading, avatars, video player
Sources/Model                 data types and input parsing
Sources/Views                 SwiftUI screens
```

NinjaView is unofficial and isn't affiliated with TikTok, ByteDance or tik.ninja.
