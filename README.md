# NinjaView

An iOS 17 app for viewing public TikTok profiles without an account, using [tik.ninja](https://tik.ninja). Every screen is native SwiftUI; tik.ninja's page runs hidden in the background as the data source.

## Install

1. Create an empty GitHub repo (for example `NinjaView`) and clone it with GitHub Desktop.
2. Unzip `NinjaView-repo.zip` and copy everything inside it (`.github`, `.gitignore`, `Config`, `README.md`, `Resources`, `Sources`, `project.yml`) into the top of the clone. Don't copy an enclosing folder.
3. Commit and push. In GitHub Desktop's list of changes, check that `.github/workflows/build.yml` is included. If it isn't, open the repo on github.com, choose **Add file > Create new file**, name it `.github/workflows/build.yml`, paste in the file's contents, and commit.
4. The push starts **Actions > Build unsigned IPA**, which takes about five minutes. Each successful build on `main` is published under **Releases** as `NinjaView-b<number>.ipa`.
5. On the iPhone, download the IPA from Releases, open it in TrollStore, and tap **Install**.

If the build passes but the release step fails with a 403, go to **Settings > Actions > General > Workflow permissions**, choose **Read and write permissions**, and re-run the job.

If the build fails, open the failed run. The **Summarize compiler errors** step lists every error in one place.

## Using it

- Search for a username, or paste a TikTok profile, post or `vm.tiktok.com` link. The Paste button skips iOS's paste prompt.
- On a profile, tap the Followers or Following count to jump to that tab. Grids load more as you scroll, and pulling down refreshes.
- Tap a post to open the viewer. Swipe up and down between posts and sideways through photo posts. Tap a video to pause it, and drag along the bottom bar to scrub.
- The viewer's buttons: **Comments** (with reply threads), **Save** (video or photos to Photos), **Audio** (through tik.ninja's own download, opens the share sheet), **Sound**, and **Player** (the system player, with Picture in Picture and AirPlay).
- Tapping a follower, a followed account or a commenter opens their profile. Back returns you to where you were.
- The star saves a profile to the home screen, where recent profiles are listed too.
- The profile menu can copy or share the TikTok link, reload, show tik.ninja's page itself, or start a new search.

### Share sheet shortcut

NinjaView opens `ninjaview://open?q=<username or link>` and `ninjaview://@username`. To send links from TikTok or Safari's share sheet, make a Shortcut that receives URLs from the share sheet, URL-encodes the Shortcut Input, and opens `ninjaview://open?q=` followed by the encoded text.

## Privacy

- No TikTok account or login is involved.
- tik.ninja's cookies and site data stay in memory and are erased when the app quits. Settings can clear them sooner.
- Saved profiles, history and cached avatars stay on the phone. History can be turned off.
- Ads and trackers on tik.ninja's page are blocked by default.
- tik.ninja's servers see the lookups you make. Videos and images load directly from TikTok's CDN, which sees your IP address, as it would for any site that shows TikTok media.

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
Sources/Media                 saving to Photos, image loading, avatars, video player
Sources/Model                 data types and input parsing
Sources/Views                 SwiftUI screens
```

NinjaView is unofficial and isn't affiliated with TikTok, ByteDance or tik.ninja.
