import SwiftUI
import UIKit

/// Small avatars for saved and recent profiles, cached on device so the home
/// screen can show them without asking tik.ninja again.
@MainActor
final class AvatarStore: ObservableObject {
    static let shared = AvatarStore()

    @Published private(set) var revision = 0
    private let folder: URL
    private var memory: [String: UIImage] = [:]
    private var inFlight: Set<String> = []
    private lazy var session = URLSession(configuration: .ephemeral)

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = caches.appendingPathComponent("Avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func file(for key: String) -> URL { folder.appendingPathComponent(key + ".jpg") }

    func image(for handle: String) -> UIImage? {
        let key = handle.lowercased()
        if let image = memory[key] { return image }
        guard let image = UIImage(contentsOfFile: file(for: key).path) else { return nil }
        memory[key] = image
        return image
    }

    func refresh(handle: String, from url: URL, force: Bool = false) {
        let key = handle.lowercased()
        guard !inFlight.contains(key) else { return }
        let target = file(for: key)
        if !force,
           let modified = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 6 * 60 * 60 { return }
        inFlight.insert(key)
        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove(key) }
            do {
                var request = URLRequest(url: url)
                request.setValue(WebFactory.userAgent, forHTTPHeaderField: "User-Agent")
                if let referer = LinkRules.referer(for: url) { request.setValue(referer, forHTTPHeaderField: "Referer") }
                let (data, _) = try await self.session.data(for: request)
                guard let image = UIImage(data: data) else { return }
                let thumb = image.preparingThumbnail(of: CGSize(width: 160, height: 160)) ?? image
                guard let jpeg = thumb.jpegData(compressionQuality: 0.85) else { return }
                try jpeg.write(to: target, options: .atomic)
                self.memory[key] = UIImage(data: jpeg)
                self.revision += 1
            } catch {
                DebugLog.shared.add(.download, "Avatar for @\(handle) failed: \(error.localizedDescription)")
            }
        }
    }

    func prune(keeping keys: Set<String>) {
        memory = memory.filter { keys.contains($0.key) }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keys.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        revision += 1
    }
}
