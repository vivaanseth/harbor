import AppKit

/// Spots a window being minimized when Accessibility is off.
///
/// With Accessibility the Dock announces each new tile (see DockMonitor).
/// Without it, a minimized window only shows up once its animation has ended,
/// by which time the Dock has already grown into the widgets. The window
/// server does show the animation itself, though: the window's bounds start
/// sliding toward the Dock at the moment the Dock would have announced the
/// tile. So follow the window that might be minimizing for a moment: after a
/// click in its title bar (the minimize button, or a double-click set to
/// minimize), or while Command is held (Cmd+M itself can't be seen without
/// Accessibility, but modifier keys can).
final class MinimizeWatcher: @unchecked Sendable {
    static let shared = MinimizeWatcher()

    private let queue = DispatchQueue(label: "dock.minimize-watch", qos: .userInteractive)
    private var monitors: [Any] = []
    private let lock = NSLock()
    private var commandDown = false
    private var commandUpAt: CFTimeInterval = 0

    private init() {}

    @MainActor
    func start() {
        guard monitors.isEmpty else { return }
        // Mouse and modifier-key monitors need no permission (other keys do).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            let clicks = event.clickCount
            MainActor.assumeIsolated { self?.mouseUp(clicks: clicks) }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let down = event.modifierFlags.contains(.command)
            MainActor.assumeIsolated { self?.commandChanged(down) }
        }) { monitors.append(m) }
    }

    /// Where the Dock is (CG y) and how much a new tile widens it, if a
    /// minimize would add a tile and nothing better reports it.
    @MainActor
    private var context: (dockY: CGFloat, growth: CGFloat)? {
        // With Accessibility the Dock's own notification is exact.
        guard !PermissionCache.shared.accessibility else { return nil }
        let dock = DockMonitor.shared
        guard dock.state.orientation == .bottom, !dock.state.frame.isEmpty, !dock.minimizeToApplication else { return nil }
        return (ScreenGeometry.primaryHeight - dock.state.frame.midY, dock.state.tileSize * 1.065)
    }

    @MainActor
    private func mouseUp(clicks: Int) {
        guard let context else { return }
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x, y: ScreenGeometry.primaryHeight - mouse.y)
        let anywhere = clicks == 2 && Self.doubleClickMinimizes
        queue.async { [weak self] in
            guard let self, let (id, start) = Self.window(at: point, anywhereInTitleBar: anywhere) else { return }
            // The animation starts 0.1–0.3 s after the click.
            let began = CACurrentMediaTime()
            self.follow(id, from: start, context) { CACurrentMediaTime() - began < 0.6 }
        }
    }

    @MainActor
    private func commandChanged(_ down: Bool) {
        lock.lock()
        let wasDown = commandDown
        commandDown = down
        if !down { commandUpAt = CACurrentMediaTime() }
        lock.unlock()
        guard down, !wasDown, let context, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        queue.async { [weak self] in
            guard let self, let (id, start) = Self.frontWindow(of: pid) else { return }
            self.follow(id, from: start, context) { self.commandHeldRecently() }
        }
    }

    private func commandHeldRecently() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return commandDown || CACurrentMediaTime() - commandUpAt < 0.9
    }

    private static var doubleClickMinimizes: Bool {
        let defaults = UserDefaults.standard
        if let action = defaults.string(forKey: "AppleActionOnDoubleClick") { return action == "Minimize" }
        return defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick")
    }

    // MARK: - Window server (on `queue`; CG top-left coordinates)

    private static func bounds(_ info: [String: Any]) -> CGRect? {
        (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
    }

    private static func onScreenWindows() -> [[String: Any]] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 && (bounds($0)?.height ?? 0) > 60 }
    }

    /// The window clicked, if the click was where its minimize button could be.
    private static func window(at point: CGPoint, anywhereInTitleBar: Bool) -> (CGWindowID, CGRect)? {
        guard let info = onScreenWindows().first(where: { bounds($0)?.contains(point) == true }),
              let id = info[kCGWindowNumber as String] as? CGWindowID, let b = bounds(info) else { return nil }
        // The traffic lights sit in the top-left corner; where exactly varies by app.
        guard point.y - b.minY < 44, anywhereInTitleBar || point.x - b.minX < 80 else { return nil }
        return (id, b)
    }

    private static func frontWindow(of pid: pid_t) -> (CGWindowID, CGRect)? {
        guard let info = onScreenWindows().first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }),
              let id = info[kCGWindowNumber as String] as? CGWindowID, let b = bounds(info) else { return nil }
        return (id, b)
    }

    /// Polls one window while `keepGoing` holds; if it starts the minimize
    /// animation, tells the widgets when it began.
    private func follow(_ id: CGWindowID, from start: CGRect, _ context: (dockY: CGFloat, growth: CGFloat),
                        while keepGoing: () -> Bool) {
        var raw: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
        guard let ids = CFArrayCreate(nil, &raw, 1, nil) else { return }
        let began = CACurrentMediaTime()
        var firstChange: CFTimeInterval?
        while keepGoing() && CACurrentMediaTime() - began < 4 {
            guard let info = (CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]])?.first,
                  (info[kCGWindowIsOnscreen as String] as? Bool) == true,
                  let b = Self.bounds(info) else { return }   // closed or hidden
            if b != start {
                let changed = firstChange ?? CACurrentMediaTime()
                firstChange = changed
                // Genie and scale effects carry the window toward the Dock
                // without making it taller; zooming grows it, moving it needs
                // the mouse button held.
                if abs(context.dockY - b.midY) <= abs(context.dockY - start.midY) - 3, b.height <= start.height + 2,
                   NSEvent.pressedMouseButtons == 0 {
                    // Bounds change ~20 ms after the Dock would have announced the tile.
                    let growth = context.growth
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { WidgetBarController.shared.anticipateDockGrowth(growth, at: changed - 0.02) }
                    }
                    return
                }
            }
            usleep(10_000)
        }
    }
}
