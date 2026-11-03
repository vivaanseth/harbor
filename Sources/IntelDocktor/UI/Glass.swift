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

/// The glass slab every widget, drawer and preview sits on — styled after
/// macOS 26 Liquid Glass: a light, see-through blur, no heavy tint, a bright
/// specular edge that catches light top-left and bottom-right, and a soft
/// sheen across the top.
struct GlassBackground: View {
    var radius: CGFloat
    var emphasized: Bool = false
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let tint = settings.glassTint
        ZStack {
            // A thinner blur: partly transparent so the wallpaper reads through.
            VisualEffectBlur(material: .fullScreenUI, cornerRadius: radius, alpha: 0.5 + 0.4 * tint)
            shape.fill(Color.black.opacity(0.06 + 0.3 * tint))
            // Sheen across the top half, like light on a curved surface.
            shape.fill(
                LinearGradient(stops: [
                    .init(color: Color.white.opacity(emphasized ? 0.20 : 0.15), location: 0),
                    .init(color: Color.white.opacity(0.04), location: 0.45),
                    .init(color: .clear, location: 0.6),
                    .init(color: Color.white.opacity(0.05), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
        }
        // Specular rim: brightest at the top-left and bottom-right corners.
        .overlay(
            shape.strokeBorder(
                AngularGradient(colors: [
                    Color.white.opacity(0.75), Color.white.opacity(0.18), Color.white.opacity(0.08),
                    Color.white.opacity(0.45), Color.white.opacity(0.08), Color.white.opacity(0.18),
                    Color.white.opacity(0.75),
                ], center: .center, angle: .degrees(-135)),
                lineWidth: 1.1)
        )
        .overlay(shape.inset(by: 1.1).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}

extension View {
    func glass(radius: CGFloat, emphasized: Bool = false) -> some View {
        background(GlassBackground(radius: radius, emphasized: emphasized))
    }
}
