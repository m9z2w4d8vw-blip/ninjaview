import SwiftUI
import UIKit

/// Neutral greys in the manner of Instagram's iOS app: white or black backgrounds,
/// grey button fills, hairline separators. Pink is kept for small accents.
enum Palette {
    static let paper = dynamic(light: 0xFFFFFF, dark: 0x000000)
    static let card = dynamic(light: 0xEFEFEF, dark: 0x262626)
    static let ink = dynamic(light: 0x0A0A0A, dark: 0xF5F5F5)
    static let rule = dynamic(light: 0xDBDBDB, dark: 0x363636)
    static let muted = dynamic(light: 0x737373, dark: 0xA8A8A8)
    static let signal = dynamic(light: 0xFF2D55, dark: 0xFF375F)
    /// Second stop of the story ring.
    static let ember = dynamic(light: 0xFF8A00, dark: 0xFF9F0A)
    /// Hashtags, mentions and carousel dots.
    static let link = dynamic(light: 0x00376B, dark: 0xE0F1FF)

    private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light) }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Color {
    static let nvPaper = Color(uiColor: Palette.paper)
    static let nvCard = Color(uiColor: Palette.card)
    static let nvInk = Color(uiColor: Palette.ink)
    static let nvRule = Color(uiColor: Palette.rule)
    static let nvMuted = Color(uiColor: Palette.muted)
    static let nvSignal = Color(uiColor: Palette.signal)
    static let nvLink = Color(uiColor: Palette.link)
}

extension Font {
    /// Handles, counts and labels use the monospaced face, echoing tik.ninja's
    /// Space Mono. Handles also read better in mono (l, I and 1 stay distinct).
    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var style: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
enum Chrome {
    static func configure() {
        let base = UIFont.monospacedSystemFont(ofSize: 30, weight: .bold)
        let large = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: base)
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: large, .foregroundColor: Palette.ink]
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: Palette.ink]
    }

    /// Setting the window style directly is more reliable than
    /// `.preferredColorScheme(nil)` when switching back to System.
    static func apply(_ mode: AppearanceMode) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = mode.style }
        }
    }
}
