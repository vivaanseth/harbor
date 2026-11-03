import SwiftUI
import AppKit

/// Behind-window blur with real rounded corners (SwiftUI clipping does not
/// reach the window-server blur, so the mask has to live on the effect view).
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        view.maskImage = Self.mask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
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

/// The glass slab every widget, drawer and preview sits on.
struct GlassBackground: View {
    var radius: CGFloat
    var emphasized: Bool = false
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            VisualEffectBlur(material: .hudWindow, cornerRadius: radius)
            shape.fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.09, green: 0.11, blue: 0.24).opacity(settings.glassTint * 0.55),
                        Color(red: 0.04, green: 0.05, blue: 0.14).opacity(settings.glassTint * 0.75),
                    ],
                    startPoint: .top, endPoint: .bottom)
            )
            shape.fill(
                LinearGradient(colors: [Color.white.opacity(emphasized ? 0.10 : 0.06), .clear],
                               startPoint: .topLeading, endPoint: .center)
            )
        }
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.34), Color.white.opacity(0.07), Color.white.opacity(0.16)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
        )
        .overlay(
            shape.inset(by: 1).strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
        )
    }
}

extension View {
    func glass(radius: CGFloat, emphasized: Bool = false) -> some View {
        background(GlassBackground(radius: radius, emphasized: emphasized))
    }
}
