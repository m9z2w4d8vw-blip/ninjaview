import SwiftUI
import UIKit

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
        List {
            Section {
                TrafficSummary()
                    .listRowBackground(Color.nvPaper)
            }
            Section {
                ForEach(rows) { entry in
                    EntryRow(entry: entry)
                        .listRowBackground(Color.nvPaper)
                }
                if rows.isEmpty {
                    Text(log.entries.isEmpty ? "Nothing logged yet" : "No matching entries")
                        .font(.footnote)
                        .foregroundStyle(Color.nvMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.nvPaper)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.nvPaper)
        .searchable(text: $filter, prompt: "Filter")
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
                    Button {
                        if let report = Diagnostics.lastFailureReport {
                            UIPasteboard.general.string = report
                            downloads.show(.success, "Failure report copied")
                        } else {
                            downloads.show(.failure, "No lookup has failed since NinjaView opened.")
                        }
                    } label: {
                        Label("Copy latest failure report", systemImage: "doc.on.doc")
                    }
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

private struct EntryRow: View {
    let entry: DebugLog.Entry

    var body: some View {
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
    }
}

/// A live count of tik.ninja traffic at the top of the log, refreshed every two seconds.
private struct TrafficSummary: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            VStack(alignment: .leading, spacing: 3) {
                Text("tik.ninja traffic")
                    .font(.mono(.caption, weight: .bold))
                    .foregroundStyle(Color.nvInk)
                ForEach(Array(NetLedger.shared.liveLines().enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.mono(.caption2))
                        .foregroundStyle(Color.nvMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
