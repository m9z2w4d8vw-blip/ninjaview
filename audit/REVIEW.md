# NinjaView b13 — source, IPA and debug-log audit

**Scope:** uploaded `ninjaview-main` Swift project, the supplied NinjaView 1.0 build 13 IPA, and the October 21, 2026 diagnostic log. This repository is a **patch to the Swift sources**, not a modified or tested IPA. The user's raw debug log and IPA are **not** bundled in the patched repository.

## Coverage and confidence

- Every line of all 53 Swift source files was included in the automated source-level inventory (`audit/line-index.tsv`). The inventory adds configuration and documentation. Each line records its path, line, lexical classification, any heuristic risk flags, and original text. `audit/source-summary.json` provides per-file totals. The checks also cover the **embedded JavaScript** copied verbatim from Swift raw strings.
- Each Swift source file passed `swiftc -frontend -parse` in a Linux toolchain. Four embedded JavaScript blocks passed `node --check`. Navigation-domain smoke tests compile the **real Swift production files** and exercise 24 cases on Linux. Static checks assert that the principal fixes are present.
- Manual review concentrated on the incident path (Settings → signed-in Instagram web view → navigation delegate → injected JS ready event), credential lifecycle, persisted WebKit cookies, diagnostic logging, script bridge, and high-risk hostname rules; the remaining files were scanned for risky constructs and dependencies. **This is not an assertion that a human has semantically proved each of 12,238 Swift lines correct.** No static tool can provide that guarantee.
- IPA inspection confirms `com.parv.ninjaview`, app 1.0, build 13, iOS minimum 17.0, with an embedded Mach-O executable. The local environment lacks macOS/Xcode and an iOS 17 device: **no end-to-end iOS compilation, signing, simulator, or live login test was possible**. External website behavior is not verified here. The previous IPA retains its original bug until a new IPA is built and installed.

## Critical incident and fixes

| Priority | Finding | Evidence | Remediation | Validation |
| --- | --- | --- | --- | --- |
| P0 fixed in source | All top-level `instagram.com` navigations were blocked by the generic WebKit navigation delegate. The sign-in sheet therefore waited for a readiness message from a page that never loaded. | Diagnostic log: 61 `Blocked a navigation to www.instagram.com` entries. Before patch, `PageBridge.routeTopLevel` allowed tik.ninja and the third-party Instagram viewer, not instagram.com. | `LinkRules.isInstagram` verifies HTTPS and exact/suffix-bounded host; `PageBridge` grants permission only for the dedicated `IGSession` bridge. | Swift URL classification smoke test; iOS runtime still needed. |
| P1 fixed in source | Verification sheet could sit on the spinner while it waited for an automated login before allowing a user to complete a challenge. | Original `IGSession.prepareForDisplay` awaited `ensureSignedIn(timeout: 15)` before enabling UI. | Immediately make the web page interactive, wait only for page-ready, and display visible error + Retry if loading fails. | Swift parse/static regression; iOS runtime still needed. |
| P1 fixed in source | WebKit state survived removal of saved Keychain credentials. | Original `IGCredentials.signOut` removed only Keychain / UserDefaults. | Sign-out clears the Instagram persistent WebKit website data; account switch clears session cookies before associating a new username. | Source/static verification; on-device logout needed. |
| P1 fixed in source | Diagnostic script-call logger would include `p=<password>` if the automated login code ran. | `IGSession.ensureSignedIn` passes `["p": password]`; original `PageBridge.describe` printed unfiltered arguments. | Redact sensitive argument names, including `p`, for success and failure logging. | Source/static verification. Do not upload unredacted older diagnostics publicly. |
| P2 fixed in source | Updating a Keychain password deleted the old entry before checking whether the new write succeeded. | Original `IGCredentials.store` called `remove(account:)` then `SecItemAdd`. | Use `SecItemUpdate` first; `SecItemAdd` only if no entry exists. | Swift syntax parse, source review; Keychain integration needs iOS test. |
| P2 fixed in source | `ResumeOnce` could be touched by the JS completion and a timeout without synchronization. | Original `PageBridge.ResumeOnce` stored an unsynchronized continuation. | Atomically take and clear the continuation under `NSLock` to prevent racing double-resumes. | Swift syntax parse; race testing on iOS still needed. |
| P2 fixed in source | Host-substring matching could mistake phishing/lookalike domains for Instagram or the viewer site. | Original `IGTarget.isInstagramLink` used `contains("instagram.com")`; `IGLinks.isViewer` used an unrestricted `hasSuffix`. | Compare parsed URL hosts and HTTPS schemes with dot-boundary rules. | Production Swift model/link test: valid and spoofed hosts. |
| P2 fixed in source | Release web views were inspectable by default. | `isInspectable = true` in three page factories. | Enable Web Inspector only under `#if DEBUG`. | Source/static verification. |
| P2 fixed in source | README claimed an `ldid` signing step that was absent from workflow, and overstated the story-protection guarantee. | Compared workflow to documentation and inspected story guard. | Corrected the build / artifact description and qualified story guard as best-effort. | Read against workflow; no entitlement test. |
| P2 fixed in source | Failed top-level navigation offered no user-visible reason while the verification screen waited. | `PageBridge.waitUntilReady` originally had no failure channel. | Capture load errors, fail the wait early, present Retry with a short explanation. | Swift parse / static check, needs device. |
| P2 fixed in source | Closing the verification sheet while borrowing an archiver web view could leave that view removed from its hidden host. | Original `finish()` parked only owned sessions. | Always re-park on sheet close; tear down only if session was created by sheet. | Source/static verification. |

## Other risks: identified, not fully solved

**429 throttling and heavy crawl.** The diagnostic log contains **102 HTTP 429** and **21 HTTP 403** POST responses, and repeated comment/reply requests with 15-second timeouts. `CrawlCenter.collectComments` already retries refused reply threads with escalating delays; `WatchCenter` has cooldowns. The app's full-history crawling and concurrent user/watch activity can still hit site limits. More aggressive throttling may help but would significantly extend archival jobs. No speculative global throttle or bypass was applied.

**HTML-selector drift.** Tik.ninja, Instagram and insta-stories-viewer.com HTML are independent services outside this repo. The injected DOM-reading scripts are fragile if those sites change. The user's IPA does not include third-party server-side code. Fixing future selector failures requires a sanitized, representative saved HTML page (and/or a fresh log and screenshots), not credentials or session cookies.

**Session identity.** The auto-sign-in path checks that Instagram appears authenticated; it does not conclusively confirm that the *current Instagram identity* equals the saved username. The patch clears cookies when changing accounts, reducing stale-session mixups, but users can manually sign into an unexpected account. On-device session identity verification would need to be added and tested separately.

**Instagram story privacy.** JavaScript interception is not a robust guarantee against story resource prefetching by Instagram's own code, new APIs or network behavior. The original README was too categorical. Do not assume zero story-view side effects without instrumented device tests.

**Background checking and signing.** iOS throttles background WebKit. The workflow produces an **unsigned** IPA without `ldid`, despite some app documentation/entitlement expectations. TrollStore install and time-sensitive alert entitlement behavior need real-device validation; not solved by this navigation patch.

**Web content script trust.** Scripts run in the page's JavaScript world. An Instagram script DOM overhaul, anti-automation change, checkpoint or rate limit can break automatic crawling. The patch does not bypass authentication, CAPTCHA, rate limits or platform restrictions.

## Regression plan on an iOS 17 device

1. Build the repo with XcodeGen and Xcode (or its GitHub Actions workflow), install the newly produced IPA. The uploaded `NinjaView-b13.ipa` itself is unchanged.
2. In Settings, open Instagram with an active internet connection. Confirm the page appears instead of an unending spinner. Check the newest diagnostic log for **zero** `Blocked a navigation to www.instagram.com` entries from this action.
3. Temporarily disable network and retry; confirm an error and **Retry** appear (rather than remaining stuck forever). Restore network and retry.
4. Complete login / 2FA manually if Instagram requests it. Dismiss and reopen the sheet. Confirm the page is still interactive and the web view is reattached properly.
5. Open a TikTok profile and an anonymous Instagram viewer profile to ensure their navigation still works.
6. Sign out of Instagram, reopen the page and verify it is logged out. Switch saved usernames and confirm the previous session is not reused.
7. Try archiving a **test** Instagram account's posts and comments, verify that nothing accesses stories, and inspect exported logs to ensure `p=<redacted>` instead of a password. Never share raw logged-in cookies or HTML with account secrets.
8. Check notification/watch scheduling, media playback, download completion and offline archive resume on-device. Review HTTP 429 behavior under reasonable load.

## How to run local static checks

```bash
python3 audit/source_audit.py
python3 Tests/check_source.py
```

Requirements: Python 3.10+, Swift toolchain, Node.js. Swift parse and JavaScript syntax checks are not equivalent to Xcode's type-check, link or iOS device test.

## HTML files

Not needed for the blocked-navigation fix. For future selector failures, sanitized browser-saved HTML and screenshots of the **public profile** or the **non-sensitive portion** of the login/challenge screen are helpful. Remove passwords, session cookies, CSRF tokens, personal messages, account identifiers and any private account content before sharing.
