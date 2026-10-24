import SwiftUI

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            switch toast.style {
            case .working:
                ProgressView().tint(Color.nvPaper)
            case .success:
                Image(systemName: "checkmark")
            case .failure:
                Image(systemName: "exclamationmark.triangle.fill")
            }
            Text(toast.text)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
        }
        .foregroundStyle(Color.nvPaper)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.nvInk, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}

/// Placed on the root view and on the post viewer, since a full-screen cover hides the root.
struct ToastHost: View {
    @EnvironmentObject private var downloads: DownloadCenter

    var body: some View {
        VStack {
            Spacer()
            if let toast = downloads.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: downloads.toast)
        .allowsHitTesting(false)
    }
}

struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mono(.footnote, weight: .bold))
            .foregroundStyle(Color.nvPaper)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.nvInk.opacity(configuration.isPressed ? 0.8 : 1))
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mono(.footnote, weight: .bold))
            .foregroundStyle(Color.nvInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.nvCard.opacity(configuration.isPressed ? 0.6 : 1))
            .overlay(Rectangle().strokeBorder(Color.nvRule, lineWidth: 1))
    }
}

/// Loading and failure states for a profile.
struct StatusPanel: View {
    let symbol: String?
    let title: String
    let detail: String?
    let showsActions: Bool
    let onRetry: () -> Void
    let onShowPage: () -> Void
    /// Debug details, offered alongside the actions.
    var onDetails: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Color.nvSignal)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.nvMuted)
            }
            Text(title)
                .font(.mono(.subheadline, weight: .bold))
                .foregroundStyle(Color.nvInk)
                .multilineTextAlignment(.center)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.nvMuted)
                    .multilineTextAlignment(.center)
            }
            if showsActions {
                HStack(spacing: 10) {
                    Button("Try again", action: onRetry).buttonStyle(InkButtonStyle())
                    Button("Show page", action: onShowPage).buttonStyle(OutlineButtonStyle())
                }
                .padding(.top, 4)
            }
            if showsActions, let onDetails {
                Button("Debug details", action: onDetails)
                    .font(.mono(.caption, weight: .semibold))
                    .foregroundStyle(Color.nvMuted)
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .accessibilityHint("Shows what went wrong, step by step")
            }
        }
        .padding(32)
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SectionLabel<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.mono(.footnote, weight: .bold))
                .foregroundStyle(Color.nvInk)
            Spacer()
            accessory()
        }
        .textCase(nil)
    }
}

extension SectionLabel where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Avatar for saved and recent profiles, from the on-device cache.
struct AvatarView: View {
    let handle: String
    @EnvironmentObject private var avatars: AvatarStore

    var body: some View {
        ZStack {
            if let image = avatars.image(for: handle) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.nvRule
                Text(String(handle.replacingOccurrences(of: "ig~", with: "").prefix(1)).uppercased())
                    .font(.mono(.headline, weight: .bold))
                    .foregroundStyle(Color.nvMuted)
            }
        }
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.nvRule, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

struct SavedRow: View {
    let item: SavedProfile
    var showsDate = false

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(handle: item.id)
                .frame(width: 42, height: 42)
                .overlay(alignment: .bottomTrailing) {
                    WatchBadge(handle: item.handle, platform: item.site)
                        .offset(x: 3, y: 3)
                }
            VStack(alignment: .leading, spacing: 2) {
                if item.name.isEmpty {
                    Text("@\(item.handle)")
                        .font(.mono(.body, weight: .semibold))
                        .foregroundStyle(Color.nvInk)
                        .lineLimit(1)
                } else {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.nvInk)
                        .lineLimit(1)
                    Text("@\(item.handle)")
                        .font(.mono(.footnote))
                        .foregroundStyle(Color.nvSignal)
                        .lineLimit(1)
                }
                if item.site == .instagram {
                    Text("Instagram")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.nvMuted)
                }
            }
            Spacer(minLength: 8)
            if showsDate {
                Text(item.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    .font(.caption)
                    .foregroundStyle(Color.nvMuted)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Small label on a thumbnail (date, play count), styled like tik.ninja's.
struct Chip: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.55))
    }
}
