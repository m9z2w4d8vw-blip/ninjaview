import SwiftUI
import UIKit

/// Colors follow tik.ninja's own palette so the app reads as the same product.
/// Dark mode swaps paper and ink.
enum Palette {
    static let paper = dynamic(light: 0xF5F4F0, dark: 0x000000)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x141414)
    static let ink = dynamic(light: 0x0F0F0F, dark: 0xF5F4F0)
    static let rule = dynamic(light: 0xD8D6D0, dark: 0x2A2A2A)
    static let muted = dynamic(light: 0x6E6E6E, dark: 0x9A9A9A)
    static let signal = dynamic(light: 0xFF2D55, dark: 0xFF375F)

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
