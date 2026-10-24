import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var downloads: DownloadCenter
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false
    @State private var confirmingDeleteArchives = false
    @ObservedObject private var archives = ProfileStore.archive
    @ObservedObject private var watch = WatchCenter.shared

    private func intervalLabel(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds / 60)) min"
    }

    private var backgroundFooter: String {
        if watch.mode == .standard {
            return "Standard checks only when NinjaView is open and when iOS wakes it in the background \u{2014} usually every 15 minutes to a few hours, more often the more you use the app, and never while it's force-quit. Lighter on battery. Keep Background App Refresh on for NinjaView in iOS Settings."
        }
        var text = "Instant keeps NinjaView awake with a silent audio session (it never interrupts your music) and checks on the schedule above, so alerts land within about one interval. It uses some battery, and swiping NinjaView away in the app switcher stops it \u{2014} the warning above tells you if that happens. Background App Refresh is still used as a backup."
        if watch.watched.isEmpty {
            text = "It starts once an account has notifications on: tap the bell on a profile and choose posts, stories or reposts. " + text
        }
        return text
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section {
                    Toggle("Keep viewing history", isOn: $settings.keepHistory)
                    Toggle("Block ads and trackers", isOn: $settings.blockAds)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Ad blocking applies to the next profile you open.")
                }

                Section {
                    Button("Clear viewing history", role: .destructive) { confirmingClear = true }
                        .disabled(app.history.isEmpty)
                    Button("Clear tik.ninja cookies and site data") {
                        Task {
                            await WebFactory.shared.clearBrowsingData()
                            downloads.show(.success, "Site data cleared")
                        }
                    }
                } footer: {
                    Text("Site data is kept in memory only and is erased whenever NinjaView quits. History and saved profiles stay on this iPhone.")
                }

                Section {
                    Toggle("Download profiles you open", isOn: $settings.prefetch)
                    Toggle("Archives include comments", isOn: $settings.saveComments)
                    Toggle("Archives include followers and following", isOn: $settings.saveLists)
                } header: {
                    Text("Offline")
                } footer: {
                    Text("Opening a profile saves its posts, videos and photos in the background so they open instantly; comments and follower lists load when you open them. That copy is erased when NinjaView closes. Archive on a profile keeps a copy, with comments, replies and follower lists when the switches above are on. This can use a lot of cellular data.")
                }

                Section {
                    LabeledContent("Archives", value: ByteCountFormatter.string(fromByteCount: archives.totalBytes, countStyle: .file))
                    Button("Delete all archives", role: .destructive) { confirmingDeleteArchives = true }
                        .disabled(archives.profiles.isEmpty)
                        .confirmationDialog("Delete every archive?", isPresented: $confirmingDeleteArchives, titleVisibility: .visible) {
                            Button("Delete all archives", role: .destructive) { CrawlCenter.shared.deleteAllArchives() }
                        } message: {
                            Text("Every archived profile, with its videos, photos and comments, will be removed from this iPhone.")
                        }
                } footer: {
                    Text("Archives are also in the Files app, under On My iPhone > NinjaView > Archives.")
                }

                Section {
                    Toggle("New-post notifications", isOn: Binding(
                        get: { watch.enabled },
                        set: { on in Task { await watch.setEnabled(on) } }))
                    NavigationLink("Watched accounts (\(watch.count))") { WatchListView() }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Tap the bell on a profile to choose what it notifies you about: posts, stories or reposts. A pink bell on an account's picture means notifications are on. NinjaView checks each time you open the app, and in the background depending on the mode below.")
                }

                if watch.enabled {
                    Section {
                        Picker("Mode", selection: $watch.mode) {
                            ForEach(WatchMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .pickerStyle(.segmented)
                        if watch.mode == .instant {
                            Picker("Check every", selection: $watch.pollInterval) {
                                ForEach(WatchCenter.intervals, id: \.self) { seconds in
                                    Text(intervalLabel(seconds)).tag(seconds)
                                }
                            }
                            Toggle("Warn me if watching stops", isOn: $watch.watchdog)
                        }
                        Toggle("Time Sensitive alerts", isOn: $watch.timeSensitive)
                        if watch.mode == .instant {
                            LabeledContent("Keeping awake", value: watch.keepAwakeStatus)
                        }
                        if let until = watch.restingUntil, watch.isResting {
                            LabeledContent("Checks paused until", value: until.formatted(date: .omitted, time: .shortened))
                        }
                    } header: {
                        Text("Background checking")
                    } footer: {
                        Text(backgroundFooter)
                    }
                }

                Section {
                    Toggle("Tidy up tik.ninja's page", isOn: $settings.cleanLayout)
                } header: {
                    Text("Page view")
                } footer: {
                    Text("Only matters when you open tik.ninja's page itself from a profile's menu. It hides the site's header, search box and footer.")
                }

                IGSettingsSection()

                Section {
                    NavigationLink("Debug log") { DebugLogView() }
                    Button("Export debug log (.txt)") {
                        if let url = Diagnostics.exportReport() {
                            ShareSheet.present(url)
                        } else {
                            downloads.show(.failure, "Couldn't create the log file.")
                        }
                    }
                    Toggle("Verbose network log", isOn: $settings.verboseNetLog)
                    Button("Clear debug log", role: .destructive) { DebugLog.shared.clear() }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("The .txt report covers this launch and the four before it: page loads and engine calls with their timing, every request tik.ninja's page makes (with what was sent and what came back when one is refused), how many requests each hidden page and the app send to tik.ninja, script errors and console warnings, downloads, playback and storage, plus a snapshot of the app, phone and connection. Verbose network log also records headers and the start of the answer for requests that worked, from the next profile you open. The report stays on this iPhone unless you share it.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.versionString)
                    Link("Open tik.ninja in Safari", destination: WebFactory.homeURL)
                } header: {
                    Text("About")
                } footer: {
                    Text("NinjaView is an unofficial app and isn't affiliated with TikTok, ByteDance or tik.ninja. It only shows public content.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.nvPaper.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear viewing history?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { app.clearHistory() }
            }
        }
    }
}
