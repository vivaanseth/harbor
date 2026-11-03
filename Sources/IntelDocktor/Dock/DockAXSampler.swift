import AppKit
import ApplicationServices

/// Reads the Dock's accessibility frame on a background thread.
///
/// While the Dock animates (magnifying, sliding in or out) it can take 50–100 ms
/// to answer AX requests, so nothing on the main thread ever waits for it: the
/// UI reads the most recent sample, and motion itself comes from `DockMotion`.
final class DockAXSampler: @unchecked Sendable {
    static let shared = DockAXSampler()

    struct Sample {
        var frameCG: CGRect
        var time: CFTimeInterval
    }

    private let lock = NSLock()
    private var _latest: Sample?
    private var _items: [CGRect]?
    private var _trusted = false
    private var _fast = false
    private var _wantItems = true
    private var thread: Thread?

    private var dockPID: pid_t = 0
    private var list: AXUIElement?
    private var trustCheckedAt: CFTimeInterval = 0
    private var lastWidth: CGFloat?

    /// Called on the main queue when the Dock's width changes.
    var onWidthChange: (@Sendable () -> Void)?

    private init() {}

    var latest: Sample? { lock.lock(); defer { lock.unlock() }; return _latest }
    var trusted: Bool { lock.lock(); defer { lock.unlock() }; return _trusted }

    /// Sample every frame while widgets are moving, slowly otherwise.
    var fast: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _fast }
        set { lock.lock(); _fast = newValue; lock.unlock() }
    }

    /// Item frames (CG) from the last item read, if any.
    func takeItems() -> [CGRect]? {
        lock.lock(); defer { lock.unlock() }
        return _items
    }

    func requestItems() {
        lock.lock(); _wantItems = true; lock.unlock()
    }

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.loop() }
        t.name = "dock.ax-sampler"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
    }

    private func loop() {
        while true {
            autoreleasepool { sampleOnce() }
            usleep(fast ? 8_000 : 120_000)
        }
    }

    private func sampleOnce() {
        let now = CACurrentMediaTime()
        if now - trustCheckedAt > 2 {
            trustCheckedAt = now
            let trusted = AXIsProcessTrusted()
            lock.lock(); _trusted = trusted; lock.unlock()
            if !trusted {
                list = nil
                lock.lock(); _latest = nil; lock.unlock()
            }
        }
        guard trusted else { return }

        if list == nil || dockPID == 0 || kill(dockPID, 0) != 0 {
            dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
            guard dockPID != 0 else { return }
            let app = AXUIElementCreateApplication(dockPID)
            AXUIElementSetMessagingTimeout(app, 0.25)
            list = AX.children(app).first(where: { AX.role($0) == kAXListRole as String })
            requestItems()
        }
        guard let list, let frame = AX.frame(list) else {
            self.list = nil
            return
        }
        if let last = lastWidth, abs(last - frame.width) > 0.5, let onWidthChange {
            DispatchQueue.main.async(execute: onWidthChange)
        }
        lastWidth = frame.width
        let wantItems: Bool
        lock.lock()
        _latest = Sample(frameCG: frame, time: now)
        wantItems = _wantItems
        lock.unlock()

        if wantItems {
            let items = AX.children(list).compactMap { AX.frame($0) }
            lock.lock()
            _items = items.isEmpty ? nil : items
            _wantItems = false
            lock.unlock()
        }
    }
}
