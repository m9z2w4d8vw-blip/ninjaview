import SwiftUI
import UIKit

/// Instagram-style notification settings for one account: which kinds of activity notify.
struct NotifySheet: View {
    let handle: String
    let name: String
    var platform: Platform = .tiktok
    @ObservedObject private var watch = WatchCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var denied = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        AvatarView(handle: platform.key(handle))
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name.isEmpty ? "@\(handle)" : name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.nvInk)
                                .lineLimit(1)
                            Text("@\(handle)")
                                .font(.mono(.footnote))
                                .foregroundStyle(Color.nvSignal)
                                .lineLimit(1)
                        }
                    }
                }
                Section {
                    ForEach(Activity.kinds(for: platform)) { kind in
                        Toggle(isOn: binding(for: kind)) {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(kind.title)
                                        .foregroundStyle(Color.nvInk)
                                    Text(kind.detail)
                                        .font(.caption)
                                        .foregroundStyle(Color.nvMuted)
                                }
                            } icon: {
                                Image(systemName: kind.symbol)
                                    .foregroundStyle(Color.nvInk)
                            }
                        }
                        .disabled(working)
                    }
                } header: {
                    Text("Notify me about")
                } footer: {
                    Text(footer)
                }
                if denied {
                    Section {
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    } footer: {
                        Text("Notifications are turned off for NinjaView, so nothing changed. Turn them on in iOS Settings, then try again.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func binding(for kind: Activity) -> Binding<Bool> {
        Binding(
            get: { watch.activities(for: handle, platform: platform).contains(kind) },
            set: { on in
                working = true
                Task {
                    let allowed = await watch.set(kind, on, handle: handle, name: name, platform: platform)
                    denied = !allowed
                    working = false
                    if allowed && on { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                }
            })
    }

    private var footer: String {
        let schedule: String
        if watch.mode == .instant {
            schedule = "NinjaView checks about every \(Int(watch.pollInterval / 60)) min, open or in the background (Instant mode)."
        } else {
            schedule = "NinjaView checks when you open it and when iOS wakes it in the background (Standard mode)."
        }
        var text = schedule + " The first check of each kind is silent, so what's already there doesn't notify."
        if platform == .instagram {
            text += IGArchive.shared.has(handle)
                ? " New stories and posts are also saved to this account's archive, so they stay after they expire."
                : " Archive this account too and every new story gets saved before it disappears."
        }
        return text
    }
}

/// A small pink bell on an avatar's corner when NinjaView notifies you about that account.
struct WatchBadge: View {
    let handle: String
    var size: CGFloat = 18
    var platform: Platform = .tiktok
    @ObservedObject private var watch = WatchCenter.shared

    var body: some View {
        if watch.isWatched(handle, platform: platform) {
            Image(systemName: "bell.fill")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.nvSignal))
                .overlay(Circle().strokeBorder(Color.nvPaper, lineWidth: 2))
                .accessibilityLabel("Notifications on")
        }
    }
}

/// Under a profile's buttons: which kinds of activity notify. Tapping it changes them.
struct WatchStatusLine: View {
    let handle: String
    var platform: Platform = .tiktok
    let onTap: () -> Void
    @ObservedObject private var watch = WatchCenter.shared

    var body: some View {
        let kinds = watch.activities(for: handle, platform: platform)
        if !kinds.isEmpty {
            Button(action: onTap) {
                HStack(spacing: 6) {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(Color.nvSignal)
                    Text("Notifying you about \(Activity.list(kinds).lowercased())")
                        .foregroundStyle(Color.nvInk)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.nvMuted)
                }
                .font(.footnote)
                .padding(.top, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Changes which notifications you get")
        }
    }
}
