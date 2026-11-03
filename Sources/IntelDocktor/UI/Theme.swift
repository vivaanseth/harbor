import SwiftUI

enum Theme {
    static let mint = Color(red: 0.18, green: 0.91, blue: 0.56)
    static let cyan = Color(red: 0.16, green: 0.78, blue: 0.95)
    static let teal = Color(red: 0.13, green: 0.84, blue: 0.74)
    static let calendarRed = Color(red: 0.91, green: 0.15, blue: 0.29)
    static let countdownPink = Color(red: 1.0, green: 0.24, blue: 0.55)
    static let warmOrange = Color(red: 1.0, green: 0.55, blue: 0.16)
    static let sunYellow = Color(red: 1.0, green: 0.80, blue: 0.20)
    static let memoryPink = Color(red: 0.93, green: 0.30, blue: 0.80)
    static let storagePurple = Color(red: 0.62, green: 0.36, blue: 0.98)
    static let netBlue = Color(red: 0.25, green: 0.55, blue: 1.0)

    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
    static let tile = Color.white.opacity(0.07)
    static let tileHover = Color.white.opacity(0.13)
    static let separator = Color.white.opacity(0.14)
    static let track = Color.white.opacity(0.14)

    /// Corner radius used by bar widgets, scaled to the Dock's height.
    static func barRadius(_ height: CGFloat) -> CGFloat { max(14, height * 0.29) }
    static let drawerRadius: CGFloat = 26

    static func font(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func batteryColor(_ level: Double) -> Color {
        if level < 0.15 { return Color(red: 1, green: 0.27, blue: 0.3) }
        if level < 0.3 { return sunYellow }
        return mint
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }

    init(cgColor: CGColor?, fallback: Color) {
        if let cgColor { self.init(cgColor: cgColor) } else { self = fallback }
    }
}
