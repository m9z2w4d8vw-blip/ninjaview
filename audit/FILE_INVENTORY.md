# File-by-file audit inventory

Automated every-line scan of patched source, configuration and main README. Flags are heuristic matches for triage, not confirmed defects. A zero-flag file is not guaranteed bug-free. See `source-summary.json` and `line-index.tsv` for every line.

| File | Lines | Heuristic flags |
| --- | ---: | --- |
| `.github/workflows/build.yml` | 109 | — |
| `Config/Info.plist` | 86 | network:1 |
| `README.md` | 123 | java-script-bridge:1, log-or-sensitive:1, network:1 |
| `Resources/Assets.xcassets/AccentColor.colorset/Contents.json` | 20 | — |
| `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` | 11 | — |
| `Resources/Assets.xcassets/Contents.json` | 3 | — |
| `Sources/App/AppModel.swift` | 191 | log-or-sensitive:8, navigation-or-domain:1 |
| `Sources/App/AppSettings.swift` | 70 | persistent-settings:9 |
| `Sources/App/NinjaViewApp.swift` | 67 | log-or-sensitive:4, try-catch:1 |
| `Sources/App/Theme.swift` | 89 | — |
| `Sources/Engine/EngineDock.swift` | 47 | webview:3 |
| `Sources/Engine/LinkRules.swift` | 29 | navigation-or-domain:7 |
| `Sources/Engine/PageBridge.swift` | 360 | deferred-cleanup:1, java-script-bridge:1, log-or-sensitive:16, navigation-or-domain:9, network:3, task-or-timing:8, try-catch:2, webview:13 |
| `Sources/Engine/ProfileEngine.swift` | 453 | deferred-cleanup:1, java-script-bridge:14, log-or-sensitive:5, network:1, task-or-timing:64, try-catch:4 |
| `Sources/Engine/ScriptRouter.swift` | 37 | task-or-timing:1 |
| `Sources/Engine/WebAssets.swift` | 825 | java-script-bridge:10, navigation-or-domain:1, network:2, task-or-timing:46, try-catch:12 |
| `Sources/Engine/WebFactory.swift` | 171 | forced-url-construction:1, java-script-bridge:2, log-or-sensitive:3, navigation-or-domain:3, network:2, task-or-timing:15, webview:4 |
| `Sources/Instagram/IGArchive.swift` | 473 | deferred-cleanup:3, filesystem:13, log-or-sensitive:11, navigation-or-domain:1, network:5, task-or-timing:21, try-catch:6 |
| `Sources/Instagram/IGAssets.swift` | 233 | java-script-bridge:2, potential-unbounded-loop:1, task-or-timing:6, try-catch:2 |
| `Sources/Instagram/IGCredentials.swift` | 103 | keychain:18, log-or-sensitive:10, persistent-settings:3, task-or-timing:4 |
| `Sources/Instagram/IGEngine.swift` | 269 | deferred-cleanup:2, java-script-bridge:5, log-or-sensitive:7, network:1, task-or-timing:18, try-catch:3, webview:1 |
| `Sources/Instagram/IGModels.swift` | 133 | forced-url-construction:2, navigation-or-domain:7, network:7 |
| `Sources/Instagram/IGPostArchiver.swift` | 121 | deferred-cleanup:1, task-or-timing:9 |
| `Sources/Instagram/IGPostDetailView.swift` | 206 | network:1, task-or-timing:2 |
| `Sources/Instagram/IGScreens.swift` | 715 | task-or-timing:16 |
| `Sources/Instagram/IGSession.swift` | 254 | forced-url-construction:1, java-script-bridge:6, log-or-sensitive:13, network:3, task-or-timing:27, try-catch:3, webview:1 |
| `Sources/Instagram/IGSessionAssets.swift` | 321 | java-script-bridge:2, log-or-sensitive:5, network:3, potential-unbounded-loop:5, task-or-timing:10, try-catch:5 |
| `Sources/Instagram/IGSessionModels.swift` | 69 | — |
| `Sources/Instagram/IGSettings.swift` | 197 | deferred-cleanup:1, log-or-sensitive:10, task-or-timing:7, webview:1 |
| `Sources/Instagram/IGViewer.swift` | 316 | network:1, task-or-timing:5 |
| `Sources/Library/BackgroundScheduler.swift` | 101 | log-or-sensitive:2, task-or-timing:3, try-catch:1 |
| `Sources/Library/CrawlCenter.swift` | 545 | deferred-cleanup:1, filesystem:11, log-or-sensitive:12, navigation-or-domain:1, network:5, potential-unbounded-loop:1, task-or-timing:51, try-catch:4 |
| `Sources/Library/KeepAlive.swift` | 119 | filesystem:2, log-or-sensitive:7, try-catch:1 |
| `Sources/Library/NotificationManager.swift` | 94 | log-or-sensitive:3, task-or-timing:9, try-catch:1 |
| `Sources/Library/ProfileStore.swift` | 246 | filesystem:11, log-or-sensitive:2, task-or-timing:4 |
| `Sources/Library/StoredModels.swift` | 157 | — |
| `Sources/Library/WatchCenter.swift` | 619 | deferred-cleanup:3, log-or-sensitive:12, persistent-settings:6, potential-unbounded-loop:1, task-or-timing:33 |
| `Sources/Media/AvatarStore.swift` | 68 | deferred-cleanup:1, filesystem:5, log-or-sensitive:1, network:2, task-or-timing:2, try-catch:1 |
| `Sources/Media/ClipPlayer.swift` | 151 | log-or-sensitive:4, navigation-or-domain:1, task-or-timing:3 |
| `Sources/Media/DownloadCenter.swift` | 243 | filesystem:6, log-or-sensitive:9, navigation-or-domain:2, network:6, task-or-timing:20, try-catch:4 |
| `Sources/Media/ImagePipeline.swift` | 133 | log-or-sensitive:8, navigation-or-domain:5, network:4, task-or-timing:7, try-catch:1 |
| `Sources/Media/MediaFiles.swift` | 112 | deferred-cleanup:1, filesystem:4 |
| `Sources/Model/Models.swift` | 224 | navigation-or-domain:1, network:1, persistent-settings:2 |
| `Sources/Model/TikTokTarget.swift` | 46 | navigation-or-domain:2, network:2 |
| `Sources/Support/DebugLog.swift` | 141 | filesystem:5, log-or-sensitive:2, task-or-timing:1 |
| `Sources/Support/Diagnostics.swift` | 127 | filesystem:1, log-or-sensitive:3, try-catch:1 |
| `Sources/Views/ArchiveProfileView.swift` | 265 | task-or-timing:5 |
| `Sources/Views/CommentsSheet.swift` | 318 | deferred-cleanup:2, task-or-timing:16, try-catch:4 |
| `Sources/Views/Components.swift` | 224 | — |
| `Sources/Views/DebugLogView.swift` | 77 | log-or-sensitive:7 |
| `Sources/Views/HomeView.swift` | 241 | persistent-settings:1, task-or-timing:1 |
| `Sources/Views/InstaProfile.swift` | 492 | potential-unbounded-loop:1 |
| `Sources/Views/ItemViewer.swift` | 830 | log-or-sensitive:4, network:4, task-or-timing:15, try-catch:3 |
| `Sources/Views/NotifySheet.swift` | 162 | task-or-timing:2 |
| `Sources/Views/ProfileScreen.swift` | 358 | network:1, task-or-timing:17 |
| `Sources/Views/RootView.swift` | 41 | log-or-sensitive:1 |
| `Sources/Views/SettingsView.swift` | 175 | log-or-sensitive:3, task-or-timing:3 |
| `Sources/Views/WatchListView.swift` | 117 | task-or-timing:1 |
| `Sources/Views/WebPageSheet.swift` | 63 | webview:4 |
| `project.yml` | 53 | — |

**Total:** 12643 indexed lines across 60 files.
