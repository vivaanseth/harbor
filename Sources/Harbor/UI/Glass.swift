import SwiftUI
import AppKit

/// Behind-window blur with real rounded corners (SwiftUI clipping does not
/// reach the window-server blur, so the mask has to live on the effect view).
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var cornerRadius: CGFloat
    var alpha: CGFloat = 1

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        view.maskImage = Self.mask(radius: cornerRadius)
        view.alphaValue = alpha
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        if view.alphaValue != alpha { view.alphaValue = alpha }
        if context.coordinator.radius != cornerRadius {
            context.coordinator.radius = cornerRadius
            view.maskImage = Self.mask(radius: cornerRadius)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(radius: cornerRadius) }
    final class Coordinator { var radius: CGFloat; init(radius: CGFloat) { self.radius = radius } }

    static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Liquid Glass's two variants: see-through, or thicker for text.
enum GlassVariant { case clear, regular }

/// The glass every widget, drawer and preview sits on, after Apple's Liquid
/// Glass. `clear` for widgets beside the Dock (the wallpaper reads through),
/// `regular` for surfaces that carry a lot of text (drawers, previews, the
/// switcher): a thicker blur with a dimming layer so text stays legible.
/// Light catches the rim at the top-left and, faintly, the bottom-right; the
/// edge brightens a little where the glass would bend light. With Reduce
/// Transparency it turns into a solid dark surface.
struct GlassBackground: View {
    var radius: CGFloat
    var emphasized: Bool = false
    var variant: GlassVariant = .clear
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let tint = settings.glassTint
        let lift: Double = emphasized ? 1 : 0
        ZStack {
            if reduceTransparency {
                shape.fill(Color(white: 0.17))
            } else {
                switch variant {
                case .clear:
                    // Fully blurred like real glass (a partial blur lets sharp
                    // wallpaper detail through); the tint setting only darkens it.
                    VisualEffectBlur(material: .fullScreenUI, cornerRadius: radius)
                    shape.fill(Color.white.opacity(0.04 * (1 - tint)))
                    shape.fill(Color.black.opacity(0.32 * tint))
                case .regular:
                    VisualEffectBlur(material: .hudWindow, cornerRadius: radius, alpha: 0.96)
                    shape.fill(Color.black.opacity(0.16 + 0.2 * tint))
                }
            }
            // A soft highlight across the top, like light on a curved surface.
            shape.fill(LinearGradient(stops: [
                .init(color: .white.opacity((variant == .clear ? 0.11 : 0.07) + 0.04 * lift), location: 0),
                .init(color: .white.opacity(0.02), location: 0.4),
                .init(color: .clear, location: 0.7),
            ], startPoint: .top, endPoint: .bottom))
            // The edge bends light: a faint glow just inside the rim.
            shape.strokeBorder(Color.white.opacity(0.07 + 0.03 * lift), lineWidth: 5)
                .blur(radius: 3)
                .clipShape(shape)
        }
        .overlay(
            shape.strokeBorder(
                AngularGradient(stops: [
                    .init(color: .white.opacity(0.5 + 0.15 * lift), location: 0),
                    .init(color: .white.opacity(0.12), location: 0.18),
                    .init(color: .white.opacity(0.07), location: 0.32),
                    .init(color: .white.opacity(0.28 + 0.1 * lift), location: 0.5),
                    .init(color: .white.opacity(0.07), location: 0.68),
                    .init(color: .white.opacity(0.12), location: 0.82),
                    .init(color: .white.opacity(0.5 + 0.15 * lift), location: 1),
                ], center: .center, angle: .degrees(-135)),
                lineWidth: 0.8)
        )
        // A hairline of shadow outside the rim keeps the edge on bright wallpapers.
        .overlay(shape.inset(by: -0.5).stroke(Color.black.opacity(0.14), lineWidth: 0.5))
        .animation(Motion.snappy, value: emphasized)
    }
}

extension View {
    func glass(radius: CGFloat, emphasized: Bool = false, variant: GlassVariant = .clear) -> some View {
        background(GlassBackground(radius: radius, emphasized: emphasized, variant: variant))
    }
}
