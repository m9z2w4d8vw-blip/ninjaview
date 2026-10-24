import SwiftUI
import UIKit

/// The whole story of a failed lookup: the report the engine wrote (or, when nothing has failed
/// yet, a snapshot taken now), with buttons to copy it or export the full debug log.
@MainActor
struct FailureDetailsSheet: View {
    @ObservedObject var engine: ProfileEngine
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: String? = nil
    @State private var copied = false

    private var report: String? { engine.failureReport ?? snapshot }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let report {
                    Text(report)
                        .font(.mono(.caption2))
                        .foregroundStyle(Color.nvInk)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Asking the page what happened\u{2026}")
                            .font(.footnote)
                            .foregroundStyle(Color.nvMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .background(Color.nvPaper.ignoresSafeArea())
            .navigationTitle("Debug details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { copy() } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                        .disabled(report == nil)
                        .accessibilityLabel("Copy the report")
                    Button { export() } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Export the full debug log")
                }
            }
            .task {
                if engine.failureReport == nil { snapshot = await engine.snapshotReport() }
            }
        }
    }

    private func copy() {
        guard let report else { return }
        UIPasteboard.general.string = report
        copied = true
    }

    private func export() {
        if let url = Diagnostics.exportReport() {
            ShareSheet.present(url)
        } else {
            DownloadCenter.shared.show(.failure, "Couldn't create the log file.")
        }
    }
}
