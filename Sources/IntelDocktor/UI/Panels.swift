import AppKit
import SwiftUI

enum PanelLevel {
    /// One above the Dock, so widgets sit beside it over normal windows.
    static let widgets = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
    static let drawers = NSWindow.Level.popUpMenu
    static let switcher = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 2)
}

/// Borderless, transparent, non-activating panel that never steals focus
/// unless a text field inside it needs the keyboard.
final class FloatingPanel: NSPanel {
    var allowsKey = false

    init(level: NSWindow.Level, shadow: Bool = false) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = shadow
        self.level = level
        // No .fullScreenAuxiliary: panels stay off full-screen Spaces.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reacts to the first click even when the app is inactive.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension FloatingPanel {
    func host<V: View>(_ view: V) {
        let hosting = FirstMouseHostingView(rootView: AnyView(view.environment(\.colorScheme, .dark)))
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    func setFrame(_ rect: NSRect, animated: Bool, duration: TimeInterval = 0.22) {
        guard frame != rect else { return }
        if animated && isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                // Close to Apple's smooth spring: quick to start, long gentle settle.
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                animator().setFrame(rect, display: true)
            }
        } else {
            setFrame(rect, display: true)
        }
    }
}

enum ScreenGeometry {
    /// Height of the primary screen, used to flip between AX/CG (top-left)
    /// and Cocoa (bottom-left) global coordinates.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cocoaRect(fromCG r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
    }
}
