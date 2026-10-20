import SwiftUI

struct DebugLogView: View {
    @EnvironmentObject private var log: DebugLog
    @State private var filter = ""

    private var rows: [DebugLog.Entry] {
        let newestFirst = Array(log.entries.reversed())
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return newestFirst }
        return newestFirst.filter {
            $0.message.localizedCaseInsensitiveContains(needle) || $0.category.rawValue == needle.lowercased()
        }
    }

    var body: some View {
        List(rows) { entry in
            VStack(alignment: .leading, spacing: 3) {
                Text("\(entry.date.formatted(date: .omitted, time: .standard))  \(entry.category.rawValue)")
                    .font(.mono(.caption2))
                    .foregroundStyle(Color.nvMuted)
                Text(entry.message)
                    .font(.mono(.caption))
                    .foregroundStyle(Color.nvInk)
                    .textSelection(.enabled)
            }
            .listRowBackground(Color.nvPaper)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.nvPaper)
        .searchable(text: $filter, prompt: "Filter, or a category like net")
        .overlay {
            if log.entries.isEmpty {
                ContentUnavailableView("Nothing logged yet", systemImage: "text.alignleft")
            }
        }
        .navigationTitle("Debug log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: log.export()) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share log")
                Button(role: .destructive) { log.clear() } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Clear log")
            }
        }
    }
}
