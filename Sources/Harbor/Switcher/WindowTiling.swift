import AppKit

/// ⌃⌥← / ⌃⌥→ snap the front window to the left/right half, then a third, then a
/// fourth on repeated presses; ⌃⌥↑ fills the screen, ⌃⌥↓ centres it. Off by default.
@MainActor
final class WindowTiling {
    static let shared = WindowTiling()

    private enum Action { case left, right, up, down }
    private var lastAction: (Action, Int, Date)?

    private init() {}

    /// Called by the app's keyboard tap for ⌃⌥ + an arrow key (keycodes 123–126).
    func tile(arrowKey: Int64) {
        let action: Action
        switch arrowKey {
        case 123: action = .left
        case 124: action = .right
        case 126: action = .up
        default: action = .down
        }
        perform(action)
    }

    private func perform(_ action: Action) {
        guard PermissionCache.shared.accessibility, let app = NSWorkspace.shared.frontmostApplication else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = AX.element(appElement, kAXFocusedWindowAttribute),
              let frame = AX.frame(window) else { return }
        let cocoa = ScreenGeometry.cocoaRect(fromCG: frame)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: cocoa.midX, y: cocoa.midY)) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame

        // Repeating the same key within 1.5 s steps through ½ → ⅓ → ¼.
        var step = 0
        if let last = lastAction, last.0 == action, Date().timeIntervalSince(last.2) < 1.5 { step = (last.1 + 1) % 3 }
        lastAction = (action, step, Date())
        let fraction: CGFloat = [0.5, 1.0 / 3.0, 0.25][step]

        var target: CGRect
        switch action {
        case .left: target = CGRect(x: area.minX, y: area.minY, width: area.width * fraction, height: area.height)
        case .right: target = CGRect(x: area.maxX - area.width * fraction, y: area.minY, width: area.width * fraction, height: area.height)
        case .up: target = area
        case .down:
            let size = CGSize(width: area.width * 2 / 3, height: area.height * 2 / 3)
            target = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        }
        target = target.integral
        // AX uses top-left coordinates.
        var origin = CGPoint(x: target.minX, y: ScreenGeometry.primaryHeight - target.maxY)
        var size = target.size
        if let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) {
            AX.set(window, kAXSizeAttribute, sz)
            AX.set(window, kAXPositionAttribute, pos)
            AX.set(window, kAXSizeAttribute, sz)   // again, in case the move freed room
        }
    }
}
