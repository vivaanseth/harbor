import SwiftUI

enum Theme {
    // Apple's system colors, dark-appearance values.
    static let red = Color(hex: 0xFF453A)
    static let orange = Color(hex: 0xFF9F0A)
    static let yellow = Color(hex: 0xFFD60A)
    static let green = Color(hex: 0x30D158)
    static let systemMint = Color(hex: 0x63E6E2)
    static let systemTeal = Color(hex: 0x40CBE0)
    static let systemCyan = Color(hex: 0x64D2FF)
    static let blue = Color(hex: 0x0A84FF)
    static let indigo = Color(hex: 0x5E5CE6)
    static let purple = Color(hex: 0xBF5AF2)
    static let pink = Color(hex: 0xFF375F)
    /// The accent color chosen in System Settings.
    static var accent: Color { Color(nsColor: .controlAccentColor) }

    // Roles used across the widgets, mapped onto the system palette.
    static let mint = green
    static let cyan = systemCyan
    static let teal = systemMint
    static let calendarRed = red
    static let countdownPink = pink
    static let warmOrange = orange
    static let sunYellow = yellow
    static let memoryPink = purple
    static let storagePurple = indigo
    static let netBlue = blue

    // Labels and fills as Apple's dark appearance defines them, nudged up a
    // little because they sit on see-through glass rather than a solid window.
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.6)
    static let tertiary = Color.white.opacity(0.34)
    static let tile = Color(red: 0.47, green: 0.47, blue: 0.5).opacity(0.18)
    static let tileHover = Color(red: 0.47, green: 0.47, blue: 0.5).opacity(0.3)
    static let separator = Color.white.opacity(0.12)
    static let track = Color(red: 0.47, green: 0.47, blue: 0.5).opacity(0.32)

    /// Corner radius of bar widgets: the Dock's own (measured on Sonoma), so
    /// widgets beside it read as part of the same family.
    static func barRadius(_ height: CGFloat) -> CGFloat { max(10, (height * 0.215).rounded()) }
    /// Popover-like surfaces, from Apple's widget and Control Center sizes.
    static let drawerRadius: CGFloat = 22

    /// SF Pro. Apple sets widget type a step lighter than "bold" (values
    /// semibold, labels medium); small text keeps its weight so it stays legible.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: size >= 12 ? lighter(weight) : weight, design: .default)
    }

    private static func lighter(_ w: Font.Weight) -> Font.Weight {
        switch w {
        case .black, .heavy: return .bold
        case .bold: return .semibold
        case .semibold: return .medium
        default: return w
        }
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// As the Batteries widget colors it: red when low, green otherwise.
    static func batteryColor(_ level: Double) -> Color {
        if level <= 0.2 { return red }
        if level < 0.3 { return yellow }
        return green
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
