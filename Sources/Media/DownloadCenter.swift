import Photos
import SwiftUI
import UIKit
import WebKit

enum MediaKind: String {
    case video, photo, audio, unknown

    var noun: String {
        switch self {
        case .video: return "video"
        case .photo: return "photo"
        case .audio: return "audio"
        case .unknown: return "file"
        }
    }
}

struct Toast: Identifiable, Equatable {
    enum Style: Equatable { case working, success, failure }
    let id = UUID()
    let style: Style
    let text: String
}

/// Presents the system share sheet from whatever is on top (profile, post viewer or sheet).
@MainActor
enum ShareSheet {
    static func present(_ url: URL) {
        guard let root = EngineDock.hostWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}

/// Saves media to Photos. Videos and photos come straight from their CDN URLs;
/// audio goes through tik.ninja's own download and lands in the share sheet.
@MainActor
final class DownloadCenter: NSObject, ObservableObject {
    static let shared = DownloadCenter()

    @Published private(set) var toast: Toast? = nil

    private var destinations: [ObjectIdentifier: URL] = [:]
    private var active: Set<WKDownload> = []
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    func show(_ style: Toast.Style, _ text: String) {
        let toast = Toast(style: style, text: text)
        self.toast = toast
        guard style != .working else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }

    func fetch(_ url: URL, kind: MediaKind, baseName: String) {
        Task { _ = await retrieve(url, kind: kind, baseName: baseName, announce: true) }
    }

    func fetchAll(_ urls: [URL], kind: MediaKind, baseName: String) {
        guard urls.count > 1 else {
            if let first = urls.first { fetch(first, kind: kind, baseName: baseName) }
            return
        }
        Task {
            var saved = 0
            for (offset, url) in urls.enumerated() {
                show(.working, "Saving \(offset + 1) of \(urls.count)…")
                if await retrieve(url, kind: kind, baseName: "\(baseName)_\(offset + 1)", announce: false) { saved += 1 }
            }
            if saved == urls.count {
                show(.success, "\(saved) photos saved to Photos")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                show(.failure, "Saved \(saved) of \(urls.count) photos")
            }
        }
    }

    private func retrieve(_ url: URL, kind: MediaKind, baseName: String, announce: Bool) async -> Bool {
        if announce { show(.working, "Downloading \(kind.noun)…") }
        DebugLog.shared.add(.download, "Fetching \(kind.rawValue) from \(url.host ?? "?")")
        do {
            var request = URLRequest(url: url)
            request.setValue(WebFactory.userAgent, forHTTPHeaderField: "User-Agent")
            let (temp, response) = try await session.download(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: temp)
                throw MediaError.http(http.statusCode)
            }
            let file = try MediaFiles.place(temp, baseName: baseName, suggestedName: response.suggestedFilename, mimeType: response.mimeType)
            return await deliver(file, hint: kind, announce: announce)
        } catch {
            DebugLog.shared.add(.download, "Fetch failed: \(error.localizedDescription)")
            if announce { show(.failure, "Download failed. \(error.localizedDescription)") }
            return false
        }
    }

    private func deliver(_ file: URL, hint: MediaKind, announce: Bool) async -> Bool {
        let kind = MediaSniffer.sniff(file)?.kind ?? hint
        switch kind {
        case .video, .photo:
            return await saveToPhotos(file, kind: kind, announce: announce)
        case .audio, .unknown:
            if announce { show(.success, "Downloaded \(kind.noun)") }
            ShareSheet.present(file)
            return true
        }
    }

    private func saveToPhotos(_ file: URL, kind: MediaKind, announce: Bool) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            show(.failure, "Photos access is off, so choose where to save it.")
            ShareSheet.present(file)
            return false
        }
        do {
            if kind == .video {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: nil)
                }
            } else {
                let data = try MediaFiles.photoData(file)
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
            }
            DebugLog.shared.add(.download, "Saved \(file.lastPathComponent) to Photos")
            if announce {
                show(.success, kind == .video ? "Video saved to Photos" : "Photo saved to Photos")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            return true
        } catch {
            DebugLog.shared.add(.download, "Photos save failed: \(error.localizedDescription)")
            if announce {
                show(.failure, "Couldn't add it to Photos, so choose where to save it.")
                ShareSheet.present(file)
            }
            return false
        }
    }
}

/// Downloads tik.ninja starts itself (its audio button, mainly).
extension DownloadCenter: WKDownloadDelegate {
    func adopt(_ download: WKDownload) {
        download.delegate = self
        active.insert(download)
        show(.working, "Downloading…")
        DebugLog.shared.add(.download, "Site download from \(download.originalRequest?.url?.host ?? "?")")
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(MediaFiles.sanitize(suggestedFilename, fallback: "download"))
            destinations[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        } catch {
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        active.remove(download)
        guard let file = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        Task {
            do {
                let placed = try MediaFiles.place(file, baseName: file.deletingPathExtension().lastPathComponent,
                                                  suggestedName: file.lastPathComponent, mimeType: nil)
                _ = await deliver(placed, hint: .unknown, announce: true)
            } catch {
                show(.failure, "Download failed. \(error.localizedDescription)")
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        active.remove(download)
        destinations.removeValue(forKey: ObjectIdentifier(download))
        DebugLog.shared.add(.download, "Site download failed: \(error.localizedDescription)")
        show(.failure, "Download failed. \(error.localizedDescription)")
    }
}
