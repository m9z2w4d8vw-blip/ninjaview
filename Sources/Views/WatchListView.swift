import SwiftUI

/// Manage watched accounts: what each one notifies about, when it was last checked,
/// change or stop it, or check now.
@MainActor
struct WatchListView: View {
    @ObservedObject private var watch = WatchCenter.shared
    @EnvironmentObject private var app: AppModel
    @State private var editing: WatchCenter.Watched? = nil

    var body: some View {
        List {
            if watch.isResting || watch.lastResult != nil {
                Section {
                    if let until = watch.restingUntil, watch.isResting {
                        Label("tik.ninja asked NinjaView to slow down. Automatic checks resume at \(until.formatted(date: .omitted, time: .shortened)).",
                              systemImage: "hourglass")
                            .font(.footnote)
                            .foregroundStyle(Color.nvInk)
                    }
                    if let result = watch.lastResult {
                        Text(result)
                            .font(.footnote)
                            .foregroundStyle(Color.nvMuted)
                    }
                }
            }
            Section {
                ForEach(watch.watched) { entry in
                    Button { open(entry) } label: { row(entry) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { watch.unwatch(entry.handle, platform: entry.platform) } label: {
                                Label("Stop watching", systemImage: "bell.slash")
                            }
                            Button { editing = entry } label: {
                                Label("Change", systemImage: "slider.horizontal.3")
                            }
                            .tint(Color.nvInk)
                        }
                }
            } footer: {
                if !watch.watched.isEmpty {
                    Text("Swipe an account to change what it notifies you about, or to stop watching it.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Watched")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if watch.isChecking {
                    ProgressView()
                } else {
                    Button("Check now") { Task { await watch.checkNow() } }
                        .disabled(watch.watched.isEmpty)
                }
            }
        }
        .overlay {
            if watch.watched.isEmpty {
                ContentUnavailableView("No watched accounts", systemImage: "bell",
                    description: Text("Tap the bell on a TikTok or Instagram profile and choose what it notifies you about."))
            }
        }
        .sheet(item: $editing) { entry in
            NotifySheet(handle: entry.handle, name: entry.name, platform: entry.platform)
                .environmentObject(AvatarStore.shared)
        }
    }

    private func row(_ entry: WatchCenter.Watched) -> some View {
        HStack(spacing: 12) {
            AvatarView(handle: entry.id)
                .frame(width: 42, height: 42)
                .overlay(alignment: .bottomTrailing) {
                    WatchBadge(handle: entry.handle, platform: entry.platform)
                        .offset(x: 3, y: 3)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name.isEmpty ? "@\(entry.handle)" : entry.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.nvInk)
                    .lineLimit(1)
                Text(Activity.list(entry.activities))
                    .font(.footnote)
                    .foregroundStyle(Color.nvSignal)
                    .lineLimit(1)
                Text(subtitle(entry))
                    .font(.caption)
                    .foregroundStyle(Color.nvMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }

    private func open(_ entry: WatchCenter.Watched) {
        if entry.platform == .instagram {
            app.openInstagram(entry.handle)
        } else {
            _ = app.open("@" + entry.handle)
        }
    }

    private func subtitle(_ entry: WatchCenter.Watched) -> String {
        var parts = [entry.label]
        if let last = entry.lastChecked {
            parts.append("checked \(last.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("not checked yet")
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}
