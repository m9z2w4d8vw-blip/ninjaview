import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var downloads: DownloadCenter
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false

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
                    Toggle("Tidy up tik.ninja's page", isOn: $settings.cleanLayout)
                } header: {
                    Text("Page view")
                } footer: {
                    Text("Only matters when you open tik.ninja's page itself from a profile's menu. It hides the site's header, search box and footer.")
                }

                Section("Diagnostics") {
                    NavigationLink("Debug log") { DebugLogView() }
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
