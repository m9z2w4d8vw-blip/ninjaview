# NinjaView patch notes — October 21, 2026

## Fixed

- **Open Instagram never finishes loading:** allow `https://instagram.com` and its subdomains **only** for the authenticated Instagram web view; previously the navigation delegate blocked every such navigation.
- **Spinner with no action:** make the manual login/verification web view interactive as soon as it is requested; show a loading error and Retry rather than waiting indefinitely.
- **Login information in debug logs:** redact the `p` JavaScript parameter (the password) and common credential parameter names.
- **Logout did not log out of website:** clear the persistent Instagram WebKit session when signing out or changing saved Instagram accounts.
- **Keychain reliability:** update passwords in place rather than deleting the previous entry first.
- **Link spoofing:** require correctly bounded hostnames for Instagram and the viewer domain.
- **Web Inspector:** enabled only in debug builds, not releases.
- **JavaScript call timeout race:** guard continuation consumption using a lock.
- **Closing the login sheet:** always re-dock borrowed web views behind the app.
- **Documentation:** clarify unsigned build and limitations of automated story blocking.

## How to use

Upload these source files as a Git repository or extract the ZIP into an existing `main` branch. GitHub Actions (`.github/workflows/build.yml`) will run static checks, compile with Xcode and publish an unsigned IPA after a push. **The original uploaded build 13 IPA remains unchanged.**

Run `python3 Tests/check_source.py` to reproduce the syntax and host-rule smoke checks. See `audit/REVIEW.md`, `audit/FILE_INVENTORY.md` and `audit/line-index.tsv` for issue-level, per-file and line-level audit details.

## What is not proved

Static checks passed on Linux but the iOS app was **not built or run here**; only Xcode and a real iOS 17 device can verify that login works against the live site. The app still depends on external sites, which can change their DOM, and the log shows frequent rate-limit responses during intensive crawling.
