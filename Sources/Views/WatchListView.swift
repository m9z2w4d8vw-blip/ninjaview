import SwiftUI

/// Manage watched accounts: see when each was last checked, remove one, or check now.
@MainActor
struct WatchListView: View {
    @ObservedObject private var watch = WatchCenter.shared
    @EnvironmentObject private var app: AppModel

    var body: some View {
        List {
            if let result = watch.lastResult {
                Section {
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(Color.nvMuted)
                }
            }
            Section {
                ForEach(watch.watched) { entry in
                    Button { _ = app.open("@" + entry.handle) } label: { row(entry) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { watch.unwatch(entry.handle) } label: {
                                Label("Stop watching", systemImage: "bell.slash")
                            }
                        }
                }
            } footer: {
                if !watch.watched.isEmpty {
                    Text("Swipe an account to stop watching it. New posts show up as notifications.")
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
                    description: Text("Turn on the bell on a profile to get notified about new posts."))
            }
        }
    }

    private func row(_ entry: WatchCenter.Watched) -> some View {
        HStack(spacing: 12) {
            AvatarView(handle: entry.handle)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name.isEmpty ? "@\(entry.handle)" : entry.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.nvInk)
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

    private func subtitle(_ entry: WatchCenter.Watched) -> String {
        var parts = ["@\(entry.handle)"]
        if let count = entry.postCount { parts.append("\(count) posts") }
        if let last = entry.lastChecked {
            parts.append("checked \(last.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("not checked yet")
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}
