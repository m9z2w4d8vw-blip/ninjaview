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

/// Presents the system share sheet from whatever is on top (a profile, a sheet).
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

/// Saves media to Photos or hands it to the share sheet. Videos and photos come from
/// their CDN URLs or from the phone (downloaded copies); audio goes through tik.ninja's
/// own download and lands in the share sheet.
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

    /// Gets the file (downloading it if needed) and opens the share sheet, without saving to Photos.
    func share(_ url: URL, kind: MediaKind, baseName: String) {
        Task {
            show(.working, "Preparing the \(kind.noun)…")
            guard let file = await localCopy(of: url, baseName: baseName) else {
                show(.failure, "Couldn't get the \(kind.noun) to share.")
                return
            }
            toast = nil
            DebugLog.shared.add(.download, "Sharing \(file.lastPathComponent)")
            ShareSheet.present(file)
        }
    }

    private func retrieve(_ url: URL, kind: MediaKind, baseName: String, announce: Bool) async -> Bool {
        if announce { show(.working, "Downloading \(kind.noun)…") }
        let started = Date()
        guard let file = await localCopy(of: url, baseName: baseName) else {
            if announce { show(.failure, "Download failed. Settings › Debug log has the details.") }
            return false
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
        DebugLog.shared.add(.download, "Got \(file.lastPathComponent), \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)), in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return await deliver(file, hint: kind, announce: announce)
    }

    /// A copy of the media in the temporary folder, named by what its bytes turn out to be.
    private func localCopy(of url: URL, baseName: String) async -> URL? {
        do {
            let temp: URL
            var suggested: String? = url.lastPathComponent
            var mime: String?
            if url.isFileURL {
                temp = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID().uuidString)")
                try FileManager.default.copyItem(at: url, to: temp)
            } else {
                var request = URLRequest(url: url)
                request.setValue(WebFactory.userAgent, forHTTPHeaderField: "User-Agent")
                let (downloaded, response) = try await session.download(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    try? FileManager.default.removeItem(at: downloaded)
                    throw MediaError.http(http.statusCode)
                }
                temp = downloaded
                suggested = response.suggestedFilename
                mime = response.mimeType
            }
            return try MediaFiles.place(temp, baseName: baseName, suggestedName: suggested, mimeType: mime)
        } catch {
            let source = url.isFileURL ? url.lastPathComponent : (url.host ?? "?")
            DebugLog.shared.error(.download, "Couldn't get \(source): \(error.localizedDescription)")
            return nil
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
            DebugLog.shared.warn(.download, "Photos access isn't allowed (status \(status.rawValue))")
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
            DebugLog.shared.error(.download, "Photos refused \(file.lastPathComponent): \(error.localizedDescription)")
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
            DebugLog.shared.add(.download, "Site download: \(suggestedFilename), \(response.mimeType ?? "unknown type")")
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
        DebugLog.shared.error(.download, "Site download failed: \(error.localizedDescription)")
        show(.failure, "Download failed. \(error.localizedDescription)")
    }
}
