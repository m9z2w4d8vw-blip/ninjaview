import SwiftUI
import UIKit

/// Comments the way Instagram drew them around 2016–2017, for TikTok and Instagram alike: a plain
/// "Comments" bar with a back chevron, the caption as the first entry, then each comment as a round
/// picture, the name in bold with the text running on after it, a grey line with its age, likes and
/// Reply, and a heart on the right. Replies sit indented under their comment behind "View All N
/// replies". NinjaView only reads comments, so the "Add a comment…" bar at the bottom is drawn but
/// doesn't post.
enum Retro {
    /// The grey of ages, likes and "Reply".
    static let gray = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x8E8E8E) : UIColor(hex: 0x999999) })
    /// The bar behind "Comments".
    static let bar = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x121212) : UIColor(hex: 0xFAFAFA) })
    /// "Post" before anything has been typed.
    static let postBlue = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x2D5F86) : UIColor(hex: 0xB2DFFC) })
    static let verified = Color(uiColor: UIColor(hex: 0x3897F0))

    static let avatar: CGFloat = 34
    static let replyAvatar: CGFloat = 24
    static let gap: CGFloat = 12
    static let side: CGFloat = 14
    /// Where a comment's text starts, which is also where its replies start.
    static let replyIndent: CGFloat = avatar + gap

    static func likes(_ count: Int) -> String {
        count <= 0 ? "" : (count == 1 ? "1 like" : "\(count.formatted()) likes")
    }

    /// tik.ninja gives likes as text ("12", "1.2K").
    static func likes(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "0" { return "" }
        return trimmed == "1" ? "1 like" : "\(trimmed) likes"
    }

    static func viewReplies(_ count: Int) -> String {
        count == 1 ? "View 1 reply" : "View All \(count.formatted()) replies"
    }

    /// tik.ninja's own label ("3 replies", "1 reply", "1.2K replies") in Instagram's words.
    static func viewReplies(_ label: String) -> String {
        let first = label.split(separator: " ").first.map(String.init) ?? ""
        if let count = Int(first) { return viewReplies(count) }
        return label.lowercased().hasPrefix("view") ? label : "View All \(label)"
    }

    /// The profile a ninjaview:// mention points at ("ninjaview://@name", "ninjaview://instagram/name").
    static func handle(in url: URL) -> String? {
        guard url.scheme?.lowercased() == "ninjaview" else { return nil }
        if url.host?.lowercased() == "instagram" {
            return url.pathComponents.last(where: { $0 != "/" })
        }
        guard let host = url.host, !host.isEmpty else { return nil }
        return host.hasPrefix("@") ? String(host.dropFirst()) : host
    }
}

enum RetroAvatar {
    case url(URL?)
    /// One kept by AvatarStore (saved and recent profiles), by its key.
    case stored(String)
}

@MainActor
struct RetroAvatarView: View {
    let avatar: RetroAvatar
    let size: CGFloat
    @ObservedObject private var store = AvatarStore.shared

    var body: some View {
        picture
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.nvRule.opacity(0.7), lineWidth: 0.5))
    }

    @ViewBuilder private var picture: some View {
        switch avatar {
        case .url(let url):
            RemoteImage(url, maxPixel: size * 3)
        case .stored(let key):
            if let image = store.image(for: key) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.nvRule
                    Text(String(key.replacingOccurrences(of: "ig~", with: "").prefix(1)).uppercased())
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(Color.nvMuted)
                }
            }
        }
    }
}

/// One comment, one reply, or the caption at the top.
@MainActor
struct RetroCommentRow: View {
    let author: String
    let avatar: RetroAvatar
    var verified = false
    let text: String
    var age = ""
    var likes = ""
    var gif: URL? = nil
    var isReply = false
    /// The caption at the top: its age, and no likes, Reply or heart.
    var isCaption = false
    var platform: Platform = .tiktok
    /// Opens a profile (the author's, or one mentioned). Without it, mentions are plain blue text.
    var onOpenProfile: ((String) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: Retro.gap) {
            RetroAvatarView(avatar: avatar, size: isReply ? Retro.replyAvatar : Retro.avatar)
                .onTapGesture {
                    if let onOpenProfile, !author.isEmpty { onOpenProfile(author) }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                line
                    .font(.system(size: 15))
                    .foregroundStyle(Color.nvInk)
                    .tint(Color.nvLink)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        if let handle = Retro.handle(in: url), let onOpenProfile {
                            Task { @MainActor in onOpenProfile(handle) }
                        }
                        return .handled
                    })
                if let gif {
                    RemoteImage(gif, maxPixel: 400, mode: .fit, placeholder: .clear)
                        .frame(maxWidth: 140, maxHeight: 140, alignment: .leading)
                }
                meta
            }
            Spacer(minLength: 8)
            if !isCaption {
                Image(systemName: "heart")
                    .font(.system(size: 13))
                    .foregroundStyle(Retro.gray)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let onOpenProfile, !author.isEmpty {
                Button { onOpenProfile(author) } label: { Label("View @\(author)", systemImage: "person.crop.circle") }
            }
            Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
    }

    /// The name in bold with the text running on after it, mentions and hashtags in blue.
    private var line: Text {
        var line = Text(author).fontWeight(.semibold)
        if verified {
            line = line + Text(" ") + Text(Image(systemName: "checkmark.seal.fill")).foregroundColor(Retro.verified)
        }
        if !text.isEmpty {
            var rest = CaptionText.attributed(text, platform: platform)
            if onOpenProfile == nil { rest.link = nil }
            line = line + Text(" ") + Text(rest)
        }
        return line
    }

    @ViewBuilder private var meta: some View {
        if !age.isEmpty || !isCaption {
            HStack(spacing: 16) {
                if !age.isEmpty { Text(age) }
                if !isCaption {
                    if !likes.isEmpty { Text(likes).fontWeight(.semibold) }
                    Text("Reply")
                        .fontWeight(.semibold)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Retro.gray)
        }
    }
}

/// "View All 2 replies" (with the repliers' pictures when they're known), "Hide replies", "View more replies".
struct RetroRepliesToggle: View {
    let title: String
    var avatars: [RetroAvatar] = []
    var loading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if avatars.isEmpty {
                    Rectangle()
                        .fill(Retro.gray.opacity(0.6))
                        .frame(width: 24, height: 1)
                } else {
                    HStack(spacing: -8) {
                        ForEach(Array(avatars.prefix(2).enumerated()), id: \.offset) { item in
                            RetroAvatarView(avatar: item.element, size: 24)
                                .overlay(Circle().stroke(Color.nvPaper, lineWidth: 2))
                        }
                    }
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Retro.gray)
                if loading { ProgressView().controlSize(.mini) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct RetroHairline: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.nvRule)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

/// The plain bar with a back chevron and the title in the middle.
struct RetroNavBar: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.nvInk)
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 21, weight: .regular))
                        .foregroundStyle(Color.nvInk)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                Spacer()
            }
            .padding(.leading, 4)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(Retro.bar.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { RetroHairline() }
    }
}

/// Drawn like Instagram's, but NinjaView can't post, so a tap only says so.
struct RetroComposeBar: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "paperplane")
                .font(.system(size: 21, weight: .light))
                .foregroundStyle(Color.nvInk)
            Text("Add a comment\u{2026}")
                .font(.system(size: 15))
                .foregroundStyle(Retro.gray)
            Spacer(minLength: 8)
            Text("Post")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Retro.postBlue)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .frame(maxWidth: .infinity)
        .background(Color.nvPaper.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { RetroHairline() }
        .contentShape(Rectangle())
        .onTapGesture { DownloadCenter.shared.show(.failure, "NinjaView only reads comments; it can't post them.") }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Commenting isn't available in NinjaView")
    }
}

/// The whole screen: the bar, the comments, and the compose bar at the bottom.
@MainActor
struct RetroCommentsScreen<Content: View>: View {
    let onBack: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            RetroNavBar(title: "Comments", onBack: onBack)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.bottom, 12)
            }
            RetroComposeBar()
        }
        .background(Color.nvPaper.ignoresSafeArea())
        .overlay { ToastHost() }
        .environmentObject(DownloadCenter.shared)
    }
}
