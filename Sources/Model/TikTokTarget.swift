import Foundation

/// Turns whatever the user typed or pasted into something tik.ninja's search box accepts.
struct TikTokTarget: Equatable {
    let query: String
    let handle: String?

    private static let handleCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._")

    static func parse(_ raw: String) -> TikTokTarget? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Shared links often arrive inside a sentence ("Check this out https://vm.tiktok.com/abc/").
        if let range = text.range(of: #"https?://\S+"#, options: .regularExpression) {
            text = String(text[range])
            while let last = text.last, ".,!?)\"'".contains(last) { text.removeLast() }
        }

        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.contains("tiktok.com") {
            let urlString = lower.hasPrefix("http") ? text : "https://" + text
            guard let url = URL(string: urlString),
                  let host = url.host?.lowercased(),
                  host == "tiktok.com" || host.hasSuffix(".tiktok.com") else { return nil }
            let parts = url.path.split(separator: "/").map(String.init)
            if let first = parts.first, first.hasPrefix("@") {
                let handle = String(first.dropFirst())
                guard isHandle(handle) else { return nil }
                // A bare profile link becomes a handle; post links go through whole.
                return parts.count == 1
                    ? TikTokTarget(query: handle, handle: handle)
                    : TikTokTarget(query: url.absoluteString, handle: handle)
            }
            return TikTokTarget(query: url.absoluteString, handle: nil) // vm.tiktok.com short links
        }

        if text.hasPrefix("@") { text.removeFirst() }
        guard isHandle(text) else { return nil }
        return TikTokTarget(query: text, handle: text)
    }

    static func isHandle(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 40 && s.unicodeScalars.allSatisfy { handleCharacters.contains($0) }
    }
}
