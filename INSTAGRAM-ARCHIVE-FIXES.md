# Instagram archive fixes

## What changed

1. Archived Instagram stories and posts now use the same icon tabs and three-column grid pattern as TikTok archives. Selecting either opens a **scrolling post-card feed**, with author header, media, carousel navigation, save/share actions, caption/date, and (for posts) a comment sheet. Stories no longer open in the black fullscreen viewer **from the archive**. The live Instagram viewer is unchanged.
2. The signed-in Instagram post collector expands **View replies (N)** and **Load more comments** controls and scrolls the comments pane, not merely the window. It accumulates each batch before React replaces/virtualizes it. Replies retain parent IDs.
3. Collection checks a known expected count when Instagram supplies one, but requires the reply and load-more controls to be exhausted as well. A limit, timeout, or stalled control **does not claim completeness**. The exact count visible on a profile's hover isn't always available in the initial API response; when missing, completeness relies on exhausting the UI and is best-effort.
4. Posts now store `commentsComplete`, `expectedComments`, and `commentsNote` in the existing backward-compatible archive JSON. Older posts are **not** incorrectly considered complete just because a single comment was saved. Reruns revisit partial posts and posts with newly reported comments.
5. Existing comments/replies merge by stable ID on rearchive, and existing media files are reused. Retries won't replace an archive with a smaller set of comments. The comment sheet reports incompleteness instead of implying the count is final.

## How to use

Build using the repository's existing `.github/workflows/build.yml` GitHub Actions workflow (the iOS toolchain and signing environment are not available in this Linux sandbox). In NinjaView, sign in under Instagram settings, open the Instagram archive, and choose **Archive posts**. Updating/re-running posts attempts to complete previously partial threads. Story collection remains separate.

## Validation completed

- `swiftc -frontend -parse Sources/Instagram/*.swift` — passes on Linux (syntax only, **not** a full iOS SDK typecheck/build).
- Extracting the injected JavaScript from `IGSessionAssets.swift`, then running `node --check` — passes.
- Browser DOM smoke test against the six supplied saved Instagram pages (offline, without requesting Instagram): observed comment counts **9 → 14 → 20** in the progressively expanded example, with load-more still present in all three; another snapshot sequence showed **15 → 18** and remaining expandable replies.
- `Tests/check_instagram_snapshots.py` can be run locally with separately saved HTML files. Those private HTML snapshots are not bundled.

## Limitations

- Instagram may rate-limit, delay, hide, delete, or refuse some comments. A numeric total alone cannot prove all parent/reply relationships are accessible. In these cases the archive stays marked incomplete rather than silently saying it is complete.
- Changes have **not** been run on an actual iPhone or against a live authenticated Instagram session here. The browser test covers DOM control detection, not a real authenticated network crawl. Verify on-device after an iOS build, including large threaded posts, video/carousel playback, and story cards.
- The saved Instagram story objects do not contain per-story view/like counts, so those fields are not fabricated in the new feed.
