import SwiftUI
import UIKit

extension ProfileTab {
    /// Icons for the Instagram-style tab bar.
    var symbol: String {
        switch self {
        case .videos: return "square.grid.3x3"
        case .reposts: return "arrow.2.squarepath"
        case .stories: return "clock"
        case .highlights: return "star.circle"
        case .followers: return "person.2"
        case .following: return "person.crop.circle.badge.checkmark"
        }
    }
}

/// Sheets a profile screen can show.
enum ProfilePanel: String, Identifiable {
    case followers, following, analytics
    var id: String { rawValue }
}

/// Avatar with a story ring when there are stories to watch.
struct StoryAvatar: View {
    let url: URL?
    let ringed: Bool
    var size: CGFloat = 86

    var body: some View {
        RemoteImage(url, maxPixel: 320)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.nvRule, lineWidth: ringed ? 0 : 0.5))
            .padding(4)
            .overlay {
                if ringed {
                    Circle().strokeBorder(
                        AngularGradient(gradient: Gradient(colors: [Color.nvSignal, Color(uiColor: Palette.ember), Color.nvSignal]), center: .center),
                        lineWidth: 2.5)
                }
            }
    }
}

/// Instagram's header: avatar beside the counts, then the name and bio.
struct InstaHeader: View {
    let header: ProfileHeader
    let avatarURL: URL?
    let hasStories: Bool
    let onAvatarTap: () -> Void
    let onStatTap: (ProfileTab) -> Void
    @State private var bioExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                Button(action: onAvatarTap) {
                    StoryAvatar(url: avatarURL, ringed: hasStories)
                }
                .buttonStyle(.plain)
                .disabled(!hasStories)
                .accessibilityLabel(hasStories ? "Watch stories" : "Profile photo")
                HStack(spacing: 0) {
                    ForEach(orderedStats, id: \.label) { stat in
                        statColumn(stat)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 3) {
                if !header.name.isEmpty {
                    Text(header.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.nvInk)
                }
                if !header.bio.isEmpty {
                    Text(header.bio)
                        .font(.subheadline)
                        .foregroundStyle(Color.nvInk)
                        .lineLimit(bioExpanded ? nil : 4)
                        .textSelection(.enabled)
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { bioExpanded.toggle() } }
                }
            }
        }
    }

    /// Posts first, then followers and following, the way Instagram orders them.
    private var orderedStats: [Stat] {
        func rank(_ stat: Stat) -> Int {
            switch stat.label.lowercased() {
            case "videos", "posts": return 0
            case "followers": return 1
            case "following": return 2
            default: return 3
            }
        }
        return header.stats.sorted { rank($0) < rank($1) }
    }

    @ViewBuilder private func statColumn(_ stat: Stat) -> some View {
        let column = VStack(spacing: 1) {
            Text(stat.value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.nvInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(stat.label.lowercased() == "videos" ? "Posts" : stat.label)
                .font(.subheadline)
                .foregroundStyle(Color.nvInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        if let tab = ProfileTab(statLabel: stat.label), tab.showsUsers {
            Button { onStatTap(tab) } label: { column }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the list")
        } else {
            column
        }
    }
}

/// Instagram's flat grey profile buttons.
struct InstaButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.nvInk)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Color.nvCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// Story highlights as a row of circles.
struct HighlightsRow: View {
    let items: [PostItem]
    let onTap: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                    Button { onTap(position) } label: {
                        VStack(spacing: 5) {
                            RemoteImage(item.thumbURL, maxPixel: 200)
                                .frame(width: 62, height: 62)
                                .clipShape(Circle())
                                .padding(3)
                                .overlay(Circle().strokeBorder(Color.nvRule, lineWidth: 1))
                            Text(label(item))
                                .font(.caption)
                                .foregroundStyle(Color.nvInk)
                                .lineLimit(1)
                                .frame(width: 70)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func label(_ item: PostItem) -> String {
        if !item.title.isEmpty { return item.title }
        if !item.date.isEmpty { return item.date }
        return "Highlight"
    }
}

/// Icon tabs with the underline under the selected one.
struct InstaTabBar: View {
    let tabs: [ProfileTab]
    let selected: ProfileTab
    let onSelect: (ProfileTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                Button { onSelect(tab) } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 21, weight: tab == selected ? .semibold : .regular))
                        .foregroundStyle(tab == selected ? Color.nvInk : Color.nvMuted)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(tab == selected ? Color.nvInk : Color.clear)
                                .frame(height: 1.5)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(tab == selected ? .isSelected : [])
            }
        }
        .background(alignment: .bottom) {
            Rectangle().fill(Color.nvRule).frame(height: 0.5)
        }
    }
}

/// Three square thumbnails per row.
struct SquareGrid: View {
    let items: [PostItem]
    let onTap: (Int) -> Void
    var onNearEnd: ((Int) -> Void)? = nil

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                Button { onTap(position) } label: { SquareCell(item: item) }
                    .buttonStyle(.plain)
                    .onAppear { onNearEnd?(position) }
            }
        }
    }
}

struct SquareCell: View {
    let item: PostItem

    var body: some View {
        Color.nvRule.opacity(0.3)
            .aspectRatio(1, contentMode: .fit)
            .overlay { RemoteImage(item.thumbURL, maxPixel: 400) }
            .clipped()
            .overlay(alignment: .topTrailing) {
                Image(systemName: item.isPhotos ? "square.on.square" : "video.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(7)
            }
            .overlay(alignment: .bottomLeading) {
                if !item.plays.isEmpty {
                    Label(item.plays, systemImage: "play")
                        .labelStyle(CompactLabelStyle())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [item.isPhotos ? "Photo post" : "Video"]
        if !item.title.isEmpty { parts.append(item.title) }
        if !item.date.isEmpty { parts.append(item.date) }
        if !item.plays.isEmpty { parts.append("\(item.plays) plays") }
        return parts.joined(separator: ", ")
    }
}

struct UserRow: View {
    let user: UserCard

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(user.avatarURL, maxPixel: 140)
                .frame(width: 48, height: 48)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.nvRule, lineWidth: 0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(user.handle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.nvInk)
                    .lineLimit(1)
                if !user.nick.isEmpty {
                    Text(user.nick)
                        .font(.subheadline)
                        .foregroundStyle(Color.nvMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !user.stat.isEmpty {
                Text(user.stat)
                    .font(.caption)
                    .foregroundStyle(Color.nvMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// Followers or following, as a searchable sheet.
struct UserListSheet: View {
    let title: String
    let users: [UserCard]
    let isLoading: Bool
    let note: String
    var onNearEnd: (() -> Void)? = nil
    let onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    private var shown: [UserCard] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return users }
        return users.filter { $0.handle.lowercased().contains(needle) || $0.nick.lowercased().contains(needle) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(shown) { user in
                    Button { onOpen(user.handle) } label: { UserRow(user: user) }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.nvPaper)
                        .onAppear { if user.index >= users.count - 5 { onNearEnd?() } }
                }
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .listRowBackground(Color.nvPaper)
                        .listRowSeparator(.hidden)
                } else if users.isEmpty {
                    Text(note.isEmpty ? "No accounts to show." : note)
                        .font(.footnote)
                        .foregroundStyle(Color.nvMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .listRowBackground(Color.nvPaper)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.nvPaper)
            .searchable(text: $filter, prompt: "Search")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Re-renders its content whenever a download's progress changes.
struct CrawlAware<Content: View>: View {
    @ObservedObject var crawl: Crawl
    @ViewBuilder var content: (Crawl) -> Content

    var body: some View { content(crawl) }
}

/// "Saving for this session: 12 of 40 posts", with a progress bar, while a download runs.
struct CrawlStatusLine: View {
    @ObservedObject var crawl: Crawl
    var topPadding: CGFloat = 0

    var body: some View {
        if crawl.isActive {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: crawl.mode == .archive ? "archivebox" : "arrow.down.circle")
                    Text(text).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(Color.nvMuted)
                ProgressView(value: crawl.fraction)
                    .tint(crawl.mode == .archive ? Color.nvSignal : Color.nvInk)
            }
            .padding(.top, topPadding)
            .accessibilityElement(children: .combine)
        }
    }

    private var text: String {
        if crawl.state == .queued {
            return crawl.mode == .archive ? "Archive waiting to start" : "Offline copy waiting to start"
        }
        let progress: String
        if crawl.postsTotal > 0 {
            progress = "\(crawl.postsDone) of \(crawl.postsTotal) posts"
        } else {
            progress = crawl.activity.isEmpty ? "starting" : crawl.activity.lowercased()
        }
        return (crawl.mode == .archive ? "Archiving: " : "Saving for this session: ") + progress
    }
}

struct AnalyticsRow: Identifiable {
    let id: Int
    let label: String
    let value: String?

    /// tik.ninja's analytics panel is plain text; pair each figure with its label,
    /// whichever order the two come in.
    static func pair(_ lines: [String]) -> [AnalyticsRow] {
        var rows: [AnalyticsRow] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let next: String? = i + 1 < lines.count ? lines[i + 1] : nil
            if let next, isFigure(line), !isFigure(next) {
                rows.append(AnalyticsRow(id: rows.count, label: next, value: line))
                i += 2
            } else if let next, !isFigure(line), isFigure(next) {
                rows.append(AnalyticsRow(id: rows.count, label: line, value: next))
                i += 2
            } else {
                rows.append(AnalyticsRow(id: rows.count, label: line, value: nil))
                i += 1
            }
        }
        return rows
    }

    static func isFigure(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        if first.isNumber { return true }
        guard "+-~\u{2248}".contains(first) else { return false }
        return trimmed.dropFirst().first?.isNumber == true
    }
}

struct AnalyticsSheet: View {
    let lines: [String]?
    let isLoading: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if isLoading || lines == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if let lines, !lines.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                              alignment: .leading, spacing: 18) {
                        ForEach(AnalyticsRow.pair(lines)) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                if let value = row.value {
                                    Text(value)
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(Color.nvInk)
                                }
                                Text(row.label)
                                    .font(.footnote)
                                    .foregroundStyle(row.value == nil ? Color.nvInk : Color.nvMuted)
                            }
                        }
                    }
                    .padding(20)
                } else {
                    Text("tik.ninja didn't return analytics for this account.")
                        .font(.footnote)
                        .foregroundStyle(Color.nvMuted)
                        .padding(32)
                }
            }
            .background(Color.nvPaper)
            .navigationTitle("Account analytics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
