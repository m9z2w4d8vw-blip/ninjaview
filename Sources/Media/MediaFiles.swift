import Foundation
import UIKit

enum MediaError: LocalizedError {
    case http(Int)
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .http(let code): return "The server answered \(code)."
        case .unreadableImage: return "The image couldn't be read."
        }
    }
}

struct SniffedMedia {
    let kind: MediaKind
    let ext: String
}

/// Identifies media by its first bytes; CDN URLs and headers aren't reliable about it.
enum MediaSniffer {
    static func sniff(_ file: URL) -> SniffedMedia? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32) else { return nil }
        return sniff(data)
    }

    static func sniff(_ data: Data) -> SniffedMedia? {
        let b = [UInt8](data)
        func ascii(_ range: Range<Int>) -> String {
            guard b.count >= range.upperBound else { return "" }
            return String(bytes: b[range], encoding: .ascii) ?? ""
        }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return SniffedMedia(kind: .photo, ext: "jpg") }
        if b.count >= 4, b[0] == 0x89, ascii(1..<4) == "PNG" { return SniffedMedia(kind: .photo, ext: "png") }
        if ascii(0..<4) == "GIF8" { return SniffedMedia(kind: .photo, ext: "gif") }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "WEBP" { return SniffedMedia(kind: .photo, ext: "webp") }
        if ascii(4..<8) == "ftyp" {
            let brand = ascii(8..<12).lowercased()
            if ["heic", "heix", "heim", "heis", "mif1", "msf1"].contains(brand) { return SniffedMedia(kind: .photo, ext: "heic") }
            if brand == "avif" { return SniffedMedia(kind: .photo, ext: "avif") }
            if brand.hasPrefix("m4a") || brand.hasPrefix("m4b") { return SniffedMedia(kind: .audio, ext: "m4a") }
            if brand == "qt  " { return SniffedMedia(kind: .video, ext: "mov") }
            return SniffedMedia(kind: .video, ext: "mp4")
        }
        if ascii(0..<3) == "ID3" { return SniffedMedia(kind: .audio, ext: "mp3") }
        if b.count >= 2, b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 {
            return SniffedMedia(kind: .audio, ext: (b[1] & 0x06) == 0 ? "aac" : "mp3")
        }
        return nil
    }

    static func ext(forMIME mime: String?) -> String? {
        guard let mime = mime?.lowercased() else { return nil }
        switch mime {
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/aac": return "m4a"
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        default: return nil
        }
    }
}

enum MediaFiles {
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// A saved or local video, by its file name (carousels can mix photos and videos).
    static func isVideoFile(name: String) -> Bool { videoExtensions.contains((name as NSString).pathExtension.lowercased()) }
    static func isVideoFile(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }

    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NinjaView", isDirectory: true)
    }

    /// Moves a finished download into place with an extension that matches its bytes.
    static func place(_ temp: URL, baseName: String, suggestedName: String?, mimeType: String?) throws -> URL {
        var ext = MediaSniffer.sniff(temp)?.ext ?? MediaSniffer.ext(forMIME: mimeType)
        if ext == nil, let suggestedName {
            let fromName = URL(fileURLWithPath: suggestedName).pathExtension.lowercased()
            if !fromName.isEmpty { ext = fromName }
        }
        let finalExt = ext ?? "bin"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = sanitize(baseName, fallback: "tiktok")
        var destination = folder.appendingPathComponent("\(base).\(finalExt)")
        var n = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            n += 1
            destination = folder.appendingPathComponent("\(base)-\(n).\(finalExt)")
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    static func sanitize(_ name: String, fallback: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.newlines).union(.controlCharacters)
        let cleaned = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        let trimmed = String(cleaned.prefix(80))
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Photos takes JPEG, PNG, HEIC and GIF as-is; anything else (WebP, AVIF) becomes JPEG.
    static func photoData(_ file: URL) throws -> Data {
        let data = try Data(contentsOf: file)
        if ["jpg", "jpeg", "png", "heic", "gif"].contains(file.pathExtension.lowercased()) { return data }
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.95) else {
            throw MediaError.unreadableImage
        }
        return jpeg
    }
}
