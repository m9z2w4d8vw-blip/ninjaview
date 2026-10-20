import SwiftUI

struct DebugLogView: View {
    @EnvironmentObject private var log: DebugLog
    @EnvironmentObject private var downloads: DownloadCenter
    @State private var filter = ""
    @State private var area: DebugLog.Category? = nil
    @State private var problemsOnly = false

    private var rows: [DebugLog.Entry] {
        var list = Array(log.entries.reversed())
        if let area { list = list.filter { $0.category == area } }
        if problemsOnly { list = list.filter { $0.level != .info } }
        let needle = filter.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty { list = list.filter { $0.message.localizedCaseInsensitiveContains(needle) } }
        return list
    }

    var body: some View {
        List(rows) { entry in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.date.formatted(date: .omitted, time: .standard))
                    Text(entry.category.rawValue)
                    if entry.level != .info {
                        Text(entry.level.rawValue)
                            .foregroundStyle(entry.level == .error ? Color.red : Color.orange)
                    }
                }
                .font(.mono(.caption2))
                .foregroundStyle(Color.nvMuted)
                Text(entry.message)
                    .font(.mono(.caption))
                    .foregroundStyle(entry.level == .error ? Color.red : Color.nvInk)
                    .textSelection(.enabled)
            }
            .listRowBackground(Color.nvPaper)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.nvPaper)
        .searchable(text: $filter, prompt: "Filter")
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(log.entries.isEmpty ? "Nothing logged yet" : "No matching entries", systemImage: "text.alignleft")
            }
        }
        .navigationTitle("Debug log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Area", selection: $area) {
                        Text("All areas").tag(DebugLog.Category?.none)
                        ForEach(DebugLog.Category.allCases, id: \.self) { category in
                            Text(category.rawValue).tag(DebugLog.Category?.some(category))
                        }
                    }
                    Toggle("Warnings and errors only", isOn: $problemsOnly)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter")
                Button {
                    if let url = Diagnostics.exportReport() {
                        ShareSheet.present(url)
                    } else {
                        downloads.show(.failure, "Couldn't create the log file.")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Export as .txt")
            }
        }
    }
}
