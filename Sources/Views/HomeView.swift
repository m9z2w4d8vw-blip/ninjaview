import SwiftUI

@MainActor
struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    @State private var rejected = false
    @State private var showingSettings = false
    @FocusState private var fieldFocused: Bool
    @ObservedObject private var archives = ProfileStore.archive
    @State private var pendingDelete: StoredProfile? = nil
    @ObservedObject private var igArchives = IGArchive.shared
    @State private var pendingIGDelete: IGArchive.Account? = nil
    @AppStorage("searchPlatform") private var platformRaw = Platform.tiktok.rawValue

    var body: some View {
        List {
            Section {
                searchArea
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 18, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if !app.saved.isEmpty {
                Section {
                    ForEach(app.saved) { item in
                        row(item, showsDate: false)
                            .swipeActions {
                                Button(role: .destructive) { app.unsave(item) } label: {
                                    Label("Unsave", systemImage: "star.slash")
                                }
                            }
                    }
                } header: {
                    SectionLabel(title: "Saved")
                }
            }

            if !archiveList.isEmpty || !igArchives.accounts.isEmpty {
                Section {
                    ForEach(archiveList) { profile in
                        Button { app.openArchive(profile.handle) } label: {
                            ArchiveRow(profile: profile, avatarURL: archives.avatarURL(profile.handle),
                                       crawl: CrawlCenter.shared.find(profile.handle, .archive))
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.nvPaper)
                        .listRowSeparatorTint(Color.nvRule)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                        .swipeActions {
                            Button { pendingDelete = profile } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                    ForEach(igArchives.sortedAccounts) { account in
                        Button { app.openInstagramArchive(account.handle) } label: {
                            IGArchiveRow(account: account)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.nvPaper)
                        .listRowSeparatorTint(Color.nvRule)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                        .swipeActions {
                            Button { pendingIGDelete = account } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                } header: {
                    SectionLabel(title: "Archived")
                }
            }

            if !app.history.isEmpty {
                Section {
                    ForEach(app.history) { item in
                        row(item, showsDate: true)
                            .swipeActions {
                                Button(role: .destructive) { app.forget(item) } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    SectionLabel(title: "Recent") {
                        Button("Clear") { app.clearHistory() }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.nvMuted)
                    }
                }
            }

            if app.saved.isEmpty && app.history.isEmpty && archives.profiles.isEmpty {
                Section {
                    Text("Profiles you save with the star, and ones you've opened recently, show up here.")
                        .font(.footnote)
                        .foregroundStyle(Color.nvMuted)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.nvPaper.ignoresSafeArea())
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("NinjaView")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .confirmationDialog("Delete this archive?", isPresented: deleteShown, titleVisibility: .visible, presenting: pendingDelete) { profile in
            Button("Delete @\(profile.handle)", role: .destructive) { CrawlCenter.shared.deleteArchive(profile.handle) }
        } message: { _ in
            Text("Its saved videos, photos and comments will be removed from this iPhone.")
        }
        .confirmationDialog("Delete this archive?", isPresented: igDeleteShown, titleVisibility: .visible, presenting: pendingIGDelete) { account in
            Button("Delete @\(account.handle)", role: .destructive) { IGArchive.shared.delete(account.handle) }
        } message: { _ in
            Text("Its saved stories and posts will be removed from this iPhone.")
        }
    }

    private var archiveList: [StoredProfile] {
        archives.profiles.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var platform: Platform { Platform(rawValue: platformRaw) ?? .tiktok }

    private var igDeleteShown: Binding<Bool> {
        Binding(get: { pendingIGDelete != nil }, set: { if !$0 { pendingIGDelete = nil } })
    }

    private var searchArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Site", selection: $platformRaw) {
                ForEach(Platform.allCases) { site in
                    Text(site.title).tag(site.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Text(platform == .instagram ? "View public Instagram stories and posts without an account." : "View public TikTok profiles without an account.")
                .font(.subheadline)
                .foregroundStyle(Color.nvMuted)

            HStack(spacing: 0) {
                // A hand-made binding so only typing (not a paste) clears the warning.
                TextField(platform == .instagram ? "@username or Instagram link" : "@username or TikTok link", text: Binding(get: { query }, set: { query = $0; rejected = false }))
                    .font(.mono(.body))
                    .foregroundStyle(Color.nvInk)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.twitter)
                    .submitLabel(.go)
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .padding(.leading, 14)
                    .frame(minHeight: 50)
                if !query.isEmpty {
                    Button {
                        query = ""
                        rejected = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.nvMuted)
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 10)
                    .accessibilityLabel("Clear")
                }
                Button(action: submit) {
                    Text("View")
                        .font(.mono(.subheadline, weight: .bold))
                        .foregroundStyle(Color.nvPaper)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 50)
                        .background(Color.nvInk)
                }
                .buttonStyle(.borderless)
                .disabled(trimmed.isEmpty)
                .opacity(trimmed.isEmpty ? 0.45 : 1)
            }
            .background(Color.nvCard)
            .overlay(Rectangle().strokeBorder(Color.nvRule, lineWidth: 1))

            HStack(spacing: 12) {
                // The system paste button skips the "Allow Paste" prompt.
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in paste(strings.first ?? "") }
                }
                .buttonBorderShape(.roundedRectangle(radius: 4))
                .tint(Color.nvInk)
                if rejected {
                    Text(platform == .instagram ? "Enter a username or an instagram.com profile link." : "Enter a username or a tiktok.com link.")
                        .font(.footnote)
                        .foregroundStyle(Color.nvSignal)
                }
            }
        }
    }

    private func row(_ item: SavedProfile, showsDate: Bool) -> some View {
        Button { app.reopen(item) } label: {
            SavedRow(item: item, showsDate: showsDate)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.nvPaper)
        .listRowSeparatorTint(Color.nvRule)
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
    }

    private func paste(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        submit()
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        if app.open(trimmed, platform: platform) {
            query = ""
            rejected = false
            fieldFocused = false
        } else {
            rejected = true
        }
    }
}
