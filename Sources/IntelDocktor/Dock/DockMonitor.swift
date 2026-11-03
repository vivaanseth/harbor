import AppKit
@preconcurrency import ApplicationServices
import Combine

enum DockOrientation: String { case bottom, left, right }

/// One Dock tile at rest (Cocoa x), used to predict magnification.
struct DockItemSlot: Equatable {
    var minX: CGFloat
    var width: CGFloat
}

/// Where the Dock sits at rest. Live motion (magnification, auto-hide slide)
/// is computed per frame by `DockMotion` from this plus the pointer.
struct DockState: Equatable {
    var screenFrame: CGRect = .zero
    /// The Dock's background slab at rest, in Cocoa global coordinates.
    var frame: CGRect = .zero
    var orientation: DockOrientation = .bottom
    var autohide = false
    var magnification = false
    var tileSize: CGFloat = 48
    var largeSize: CGFloat = 64
    var autohideDelay: Double = 0.195
    var autohideDuration: Double = 0.20
    var items: [DockItemSlot] = []
    var measured = false

    var model: MagnificationModel {
        MagnificationModel(items: items, tile: tileSize, large: magnification ? max(largeSize, tileSize) : tileSize)
    }
}

/// How the Dock grows under the pointer. Measured on Sonoma: each tile grows by
/// (large − tile) × cos(π/2 · d / R), R ≈ 3.08 slots, and the point under the
/// pointer stays put, so growth left of it pushes the left edge and vice versa.
struct MagnificationModel {
    var items: [DockItemSlot]
    var tile: CGFloat
    var large: CGFloat

    var slot: CGFloat { tile * 1.065 }
    var radius: CGFloat { slot * 3.08 }
    var enabled: Bool { large > tile + 0.5 && !items.isEmpty }

    func growth(at mx: CGFloat) -> (left: CGFloat, right: CGFloat) {
        guard enabled else { return (0, 0) }
        var l: CGFloat = 0, r: CGFloat = 0
        for it in items {
            let d = abs(it.minX + it.width / 2 - mx)
            guard d < radius else { continue }
            let g = (it.width / slot) * (large - tile) * cos(.pi / 2 * d / radius)
            let frac = min(max((mx - it.minX) / max(it.width, 1), 0), 1)
            l += g * frac
            r += g * (1 - frac)
        }
        return (l, r)
    }

    /// The most either edge can move, for reserving room beside the Dock.
    var maxGrowth: (left: CGFloat, right: CGFloat) {
        guard enabled, let first = items.first, let last = items.last else { return (0, 0) }
        var l: CGFloat = 0, r: CGFloat = 0
        var x = first.minX
        while x <= last.minX + last.width {
            let g = growth(at: x)
            l = max(l, g.left)
            r = max(r, g.right)
            x += 4
        }
        return (l, r)
    }
}

/// Tracks where the Dock rests and how it's configured. Uses the Dock's
/// accessibility tree when allowed, and estimates from its preferences otherwise.
@MainActor
final class DockMonitor: ObservableObject {
    static let shared = DockMonitor()

    @Published private(set) var state = DockState()

    private var timer: Timer?
    private var dockList: AXUIElement?
    private var dockPID: pid_t = 0
    private var listValidatedAt = Date.distantPast
    private var prefs = DockPrefs()
    private var prefsReadAt = Date.distantPast
    private var pendingRest: (CGRect, Date)?
    private var observers: [NSObjectProtocol] = []

    /// Cocoa minY of the AX list when the Dock is fully shown.
    private(set) var restListMinY: CGFloat?

    private init() {}

    func start() {
        // Never let one unresponsive app stall us for the 6 s AX default.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        DockAXSampler.shared.start()
        // React as soon as the Dock resizes (a window minimized into it, an app
        // launched) instead of waiting for the next slow refresh.
        DockAXSampler.shared.onWidthChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.refresh()
                WidgetBarController.shared.wake()
            }
        }
        MinimizedWindowCounter.shared.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }
        MinimizedWindowCounter.shared.start()
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // The Dock animates the new tile in; measure once it settles.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.refresh(force: true) }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(force: true) }
            })
    }

    // MARK: - Dock element access

    var dockProcessID: pid_t {
        if dockPID == 0 || NSRunningApplication(processIdentifier: dockPID)?.isTerminated != false {
            dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
            dockList = nil
        }
        return dockPID
    }

    func dockListElement() -> AXUIElement? {
        guard PermissionCache.shared.accessibility else { return nil }
        let pid = dockProcessID
        guard pid != 0 else { return nil }
        if let dockList {
            if Date().timeIntervalSince(listValidatedAt) < 2 { return dockList }
            if AX.role(dockList) != nil { listValidatedAt = Date(); return dockList }
        }
        let app = AXUIElementCreateApplication(pid)
        dockList = AX.children(app).first(where: { AX.role($0) == kAXListRole as String })
        listValidatedAt = Date()
        return dockList
    }

    /// The AX list's most recent frame in Cocoa coordinates, sampled off the
    /// main thread; nil if Accessibility is off or the sample is too old.
    func liveListFrame(maxAge: CFTimeInterval = 1) -> CGRect? {
        guard let sample = DockAXSampler.shared.latest, CACurrentMediaTime() - sample.time <= maxAge else { return nil }
        return ScreenGeometry.cocoaRect(fromCG: sample.frameCG)
    }

    // MARK: - Refresh (slow path)

    func refresh(force: Bool = false) {
        if force || Date().timeIntervalSince(prefsReadAt) > 2 {
            prefs = DockPrefs.read()
            prefsReadAt = Date()
        }
        var s = DockState()
        s.orientation = prefs.orientation
        s.autohide = prefs.autohide
        s.magnification = prefs.magnification
        s.tileSize = prefs.tileSize
        s.largeSize = prefs.largeSize
        s.autohideDelay = prefs.autohideDelay
        s.autohideDuration = prefs.autohideDuration

        ensureStructureObserver()
        let live = liveListFrame()
        let screen = pickScreen(live: live)
        s.screenFrame = screen.frame
        let restHeight = prefs.tileSize + 15

        if let live, prefs.orientation == .bottom {
            s.measured = true
            let height = min(live.height, restHeight + 4)
            // The drawn slab sits 5 pt above the screen edge and 5 pt below the
            // AX list. Derived from the live frame rather than visibleFrame,
            // which can lag when the Dock moves to another display.
            let bottom = screen.frame.minY + 5
            let candidate = CGRect(x: live.minX, y: bottom, width: live.width, height: height)

            if s.screenFrame != state.screenFrame { restListMinY = nil }
            if !prefs.autohide {
                restListMinY = live.minY
            } else {
                // Fully shown, the list rests ~10 pt above the bottom edge.
                restListMinY = max(restListMinY ?? -.infinity, live.minY, screen.frame.minY + 10)
            }

            let previous = state.frame
            let sameAsPrevious = abs(previous.width - candidate.width) < 0.5 && abs(previous.minX - candidate.minX) < 0.5
                && previous.minY == candidate.minY
            let movedDisplay = s.screenFrame != state.screenFrame
            if !previous.isEmpty && !movedDisplay && pointerMayMagnify(previous) {
                // Live width includes magnification; keep the resting frame.
                s.frame = previous
            } else if previous.isEmpty || force || sameAsPrevious || movedDisplay {
                s.frame = candidate
                pendingRest = nil
            } else {
                // Icons animating in or out briefly resize the list; only move
                // once the new width has held for a moment (briefly, when the
                // Dock told us a tile was added or removed).
                let hold = CACurrentMediaTime() - lastStructureChange < 2 ? 0.12 : 0.4
                if pendingRest?.0 != candidate { pendingRest = (candidate, Date()) }
                if Date().timeIntervalSince(pendingRest!.1) >= hold {
                    s.frame = candidate
                    pendingRest = nil
                } else {
                    s.frame = previous
                }
            }
            // Tile layout for the magnification model, read while not magnified.
            if !pointerMayMagnify(s.frame) {
                if s.frame != state.frame { DockAXSampler.shared.requestItems() }
                s.items = readItems(matching: s.frame) ?? (s.frame == state.frame && !state.items.isEmpty
                    ? state.items : estimatedItems(in: s.frame, prefs: prefs))
            } else {
                s.items = state.items.isEmpty ? estimatedItems(in: s.frame, prefs: prefs) : state.items
            }
        } else {
            s.frame = estimatedFrame(prefs: prefs, screen: screen)
            s.items = estimatedItems(in: s.frame, prefs: prefs)
            restListMinY = nil
        }

        if s != state { state = s }
    }

    // MARK: - Tiles appearing and disappearing

    /// When the Dock last added or removed a tile.
    private(set) var lastStructureChange: CFTimeInterval = 0
    private var structureObserver: AXObserver?
    private var structurePID: pid_t = 0

    /// The Dock posts AXCreated for a new tile (a minimized window, a launching
    /// app) ~40 ms before it starts widening, so widgets can move first.
    private func ensureStructureObserver() {
        guard PermissionCache.shared.accessibility else { return }
        let pid = dockProcessID
        guard pid != 0, structureObserver == nil || structurePID != pid else { return }
        if let old = structureObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
            structureObserver = nil
        }
        guard let list = dockListElement() else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<DockMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let created = (notification as String) == kAXCreatedNotification
            MainActor.assumeIsolated { me.dockStructureChanged(element, created: created) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for element in [list, AXUIElementCreateApplication(pid)] {
            AXObserverAddNotification(observer, element, kAXCreatedNotification as CFString, refcon)
            AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        structureObserver = observer
        structurePID = pid
    }

    private var lastCreated: (AXUIElement, CFTimeInterval)?

    private func dockStructureChanged(_ element: AXUIElement, created: Bool) {
        let now = CACurrentMediaTime()
        // The same tile is announced to both the list and the app observer.
        if created, let last = lastCreated, now - last.1 < 0.3, CFEqual(last.0, element) { return }
        if created { lastCreated = (element, now) }
        lastStructureChange = now
        WidgetBarController.shared.wake()
        guard created else { return }
        let tile = state.tileSize
        // Ask what was created off the main thread; the Dock is about to animate.
        WindowService.queue.async {
            guard let subrole = AX.subrole(element), subrole.hasSuffix("DockItem") else { return }
            let growth = subrole == "AXSeparatorDockItem" ? tile * 0.475 : tile * 1.065
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WidgetBarController.shared.anticipateDockGrowth(growth) }
            }
        }
    }

    /// Without Accessibility: the Dock's own window sits on whichever display
    /// shows the Dock (visibleFrame can lag behind when it moves).
    private func dockWindowScreen() -> NSScreen? {
        let pid = dockProcessID
        let level = Int(CGWindowLevelForKey(.dockWindow))
        guard pid != 0, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == level {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: dict) else { continue }
            let rect = ScreenGeometry.cocoaRect(fromCG: bounds)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }) { return screen }
        }
        return nil
    }

    /// True when the pointer is somewhere the Dock could be magnified.
    private func pointerMayMagnify(_ rest: CGRect) -> Bool {
        guard prefs.magnification else { return false }
        let m = NSEvent.mouseLocation
        let grow = prefs.largeSize - prefs.tileSize
        return m.x >= rest.minX - grow * 3 && m.x <= rest.maxX + grow * 3 &&
            m.y <= rest.maxY + grow + 12 && m.y >= rest.minY - 20
    }

    /// Sampled tile frames, if they add up to the resting Dock (not magnified, not stale).
    private func readItems(matching rest: CGRect) -> [DockItemSlot]? {
        guard let frames = DockAXSampler.shared.takeItems(), !frames.isEmpty else { return nil }
        let total = frames.reduce(0) { $0 + $1.width }
        guard abs(total - rest.width) < rest.width * 0.03 + 8,
              let first = frames.first, abs(first.minX - rest.minX) < 12 else {
            DockAXSampler.shared.requestItems()
            return nil
        }
        return frames.map { DockItemSlot(minX: $0.minX, width: $0.width) }
    }

    private func estimatedItems(in frame: CGRect, prefs: DockPrefs) -> [DockItemSlot] {
        let slot = prefs.tileSize * 1.065
        let pad = prefs.tileSize * 0.05
        let n = max(1, Int(((frame.width - pad * 2) / slot).rounded()))
        let w = (frame.width - pad * 2) / CGFloat(n)
        return (0..<n).map { DockItemSlot(minX: frame.minX + pad + CGFloat($0) * w, width: w) }
    }

    private func pickScreen(live: CGRect?) -> NSScreen {
        if let live, let s = NSScreen.screens.first(where: { $0.frame.intersects(live.insetBy(dx: 0, dy: -live.height)) }) { return s }
        if NSScreen.screens.count > 1, let s = dockWindowScreen() { return s }
        let screens = NSScreen.screens
        if let s = screens.first(where: { $0.visibleFrame.minY > $0.frame.minY + 1 }) { return s }
        return screens.first ?? NSScreen.main!
    }

    /// Without Accessibility, estimate the Dock's width from its contents.
    private func estimatedFrame(prefs: DockPrefs, screen: NSScreen) -> CGRect {
        let t = prefs.tileSize
        let persistentIDs = Set(prefs.persistentBundleIDs)
        let runningExtra = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !persistentIDs.contains($0.bundleIdentifier ?? "") &&
                $0.bundleIdentifier != "com.apple.finder"
        }.count
        let recents = prefs.showRecents ? min(prefs.recentCount, 3) : 0
        // Each minimized window gets its own tile unless it minimizes into its app.
        let minimized = prefs.minimizeToApplication ? 0 : MinimizedWindowCounter.shared.count
        let slots = 1 + prefs.persistentBundleIDs.count + runningExtra + recents + prefs.othersCount + minimized + 1
        let separators = 1 + (prefs.showRecents && runningExtra + recents > 0 ? 1 : 0)
        // Measured: tile slot = 1.065 t, separator = 0.475 t, end padding = 0.05 t each.
        let width = CGFloat(slots) * t * 1.065 + CGFloat(separators) * t * 0.475 + t * 0.1
        let height = t + 15
        return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.minY + 5, width: width, height: height)
    }
}

/// Per-frame Dock motion: magnification growth on each side and the
/// auto-hide slide, predicted from the pointer and confirmed by AX when allowed.
@MainActor
final class DockMotion {
    private(set) var growLeft: CGFloat = 0
    private(set) var growRight: CGFloat = 0
    /// ≤ 0: how far the Dock has slid below its resting position.
    private(set) var slide: CGFloat = 0
    /// Whether the pointer is in the Dock's hover area.
    private(set) var pointerInDock = false

    private var magnify: CGFloat = 0          // 0…1 ramp
    private var lastMagnifyX: CGFloat = 0
    private var hide = HideMachine()
    private var lastTime: CFTimeInterval = 0

    /// When the pointer arrived at the bottom edge, from the mouse event itself
    /// (more precise than the next frame tick).
    var edgeArrival: CFTimeInterval?

    // A tile the Dock announced but hasn't made room for yet.
    private var anticipated: CGFloat = 0
    private var anticipatedSince: CFTimeInterval = 0
    private var anticipatedBaseWidth: CGFloat = 0

    func anticipate(growth: CGFloat, restWidth: CGFloat, now: CFTimeInterval) {
        if anticipated == 0 || now - anticipatedSince > 1.5 {
            anticipated = 0
            anticipatedBaseWidth = restWidth
        }
        anticipated += growth
        anticipatedSince = now
    }

    private var lastRest: CGRect = .zero

    func update(state s: DockState, now: CFTimeInterval, keepAlive: Bool) {
        let dt = lastTime == 0 ? 1.0 / 60 : min(0.1, now - lastTime)
        lastTime = now
        let mouse = NSEvent.mouseLocation
        let rest = s.frame
        // When the resting Dock itself moves out (it absorbed a new tile), the
        // offsets that were making room for it are now part of the base.
        if !lastRest.isEmpty && lastRest.minY == rest.minY && lastRest != rest {
            growLeft = max(0, growLeft - (lastRest.minX - rest.minX))
            growRight = max(0, growRight - (rest.maxX - lastRest.maxX))
        }
        lastRest = rest
        // Only fresh samples; the sampler runs off-main and may lag while the Dock animates.
        let live = s.measured ? DockMonitor.shared.liveListFrame(maxAge: 0.035) : nil
        let travel = rest.maxY - s.screenFrame.minY + 6

        // Auto-hide slide: timed locally (smooth), nudged by AX when it sees the Dock move.
        if s.autohide {
            var hint: CGFloat?
            if let live, let restMin = DockMonitor.shared.restListMinY {
                let hiddenMin = s.screenFrame.minY - live.height
                hint = min(1, max(0, (live.minY - hiddenMin) / max(1, restMin - hiddenMin)))
            }
            slide = hide.update(mouse: mouse, state: s, now: now, travel: travel, keepOpen: keepAlive, hint: hint,
                                edgeArrival: edgeArrival)
        } else {
            slide = 0
            hide.reset()
        }
        let dockShown = slide > -1

        // Magnification.
        let model = s.model
        let liveLeft = rest.minX - growLeft, liveRight = rest.maxX + growRight
        let topLimit = magnify > 0.01 ? rest.maxY + (s.largeSize - s.tileSize) + 2 : rest.maxY
        let inX = magnify > 0.01 ? (mouse.x >= liveLeft && mouse.x <= liveRight) : (mouse.x >= rest.minX && mouse.x <= rest.maxX)
        // The Dock magnifies while it slides in under a resting pointer, so this
        // doesn't wait for the slide to finish.
        pointerInDock = (dockShown || slide > -travel + 1) && inX && mouse.y <= topLimit && mouse.y >= s.screenFrame.minY - 1

        let wants = pointerInDock && model.enabled
        // The Dock magnifies within a frame or two of the pointer arriving and
        // relaxes over ~0.15 s: lead on the way out, never lag on the way in.
        if wants {
            magnify = min(1, magnify + CGFloat(dt / 0.03))
        } else {
            magnify = max(0, magnify - CGFloat(dt / 0.16))
        }
        let eased = magnify * magnify * (3 - 2 * magnify)

        var l: CGFloat = 0, r: CGFloat = 0
        if eased > 0 {
            let g = model.growth(at: wants ? mouse.x : lastMagnifyX)
            l = g.left * eased
            r = g.right * eased
        }
        if wants { lastMagnifyX = mouse.x }
        // Never be narrower than what the Dock reports (AX can lag by a frame).
        // Magnified, the Dock grows lopsided around the pointer, so use its
        // edges; otherwise it stays centred, so use half its extra width — its
        // AX position can trail its size by a frame while a tile animates in.
        if let live, dockShown {
            if eased > 0 {
                l = max(l, rest.minX - live.minX)
                r = max(r, live.maxX - rest.maxX)
            } else {
                let half = (live.width - rest.width) / 2
                l = max(l, half)
                r = max(r, half)
            }
        }
        // Make room for an announced tile before the Dock starts growing; the
        // Dock stays centred, so each side gets half. Done once the resting
        // frame has caught up (or after 1.5 s if the tile never came).
        var ahead: CGFloat = 0
        if anticipated > 0 {
            let caughtUp = rest.width >= anticipatedBaseWidth + anticipated - 3
            let shrank = rest.width < anticipatedBaseWidth - 3
            if caughtUp || shrank || now - anticipatedSince > 1.5 {
                anticipated = 0
            } else {
                let ramp = CGFloat(min(1, max(0, (now - anticipatedSince) / 0.12)))
                ahead = ((anticipatedBaseWidth + anticipated - rest.width) / 2 + 3) * ramp * ramp * (3 - 2 * ramp)
            }
        }

        // Edges may jump outward instantly but only retreat at the Dock's pace.
        let retreat = CGFloat(dt) * 420
        let margin = 3 * eased
        growLeft = max(0, l + margin, ahead, growLeft - retreat)
        growRight = max(0, r + margin, ahead, growRight - retreat)
    }

    var isSettled: Bool {
        magnify == 0 && anticipated == 0 && growLeft < 0.5 && growRight < 0.5 && hide.isSettled
    }
}

/// Auto-hide timing, measured on screen (Sonoma): the Dock starts sliding in ~0.2 s
/// after the pointer touches the bottom edge, starts sliding out as soon as the
/// pointer leaves it, and each slide takes ~0.2 s.
/// `hint` (0 hidden … 1 shown, from AX when available) only catches slides the
/// pointer didn't cause, such as ⌥⌘D.
private struct HideMachine {
    enum Phase { case hidden, waiting(CFTimeInterval), showing(CFTimeInterval), shown, hiding(CFTimeInterval) }
    var phase: Phase = .hidden
    private var started = false

    var isSettled: Bool {
        switch phase {
        case .hidden, .shown: return true
        default: return false
        }
    }

    mutating func reset() { phase = .hidden; started = false }

    /// Fitted to recorded Dock slides: half linear, half sine ease-in-out.
    static func ease(_ x: Double) -> CGFloat {
        let t = min(max(x, 0), 1)
        return CGFloat(0.5 * t + 0.25 * (1 - cos(.pi * t)))
    }

    /// Time offset that puts the eased curve at `fraction` (inverse of `ease`).
    static func time(for fraction: CGFloat, duration: Double) -> Double {
        let target = min(max(fraction, 0), 1)
        var lo = 0.0, hi = 1.0
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if ease(mid) < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2 * duration
    }

    mutating func update(mouse: CGPoint, state s: DockState, now: CFTimeInterval, travel: CGFloat,
                         keepOpen: Bool, hint: CGFloat?, edgeArrival: CFTimeInterval?) -> CGFloat {
        let duration = max(0.01, s.autohideDuration)
        if !started {
            // Start in whatever state the Dock is actually in.
            started = true
            phase = (hint ?? 0) > 0.5 ? .shown : .hidden
        }
        let onScreen = s.screenFrame.insetBy(dx: 0, dy: -2).contains(mouse)
        let atEdge = onScreen && mouse.y <= s.screenFrame.minY + 1
        let grow = s.magnification ? s.largeSize - s.tileSize : 0
        let overDock = onScreen && mouse.y <= s.frame.maxY + grow + 4 &&
            mouse.x >= s.frame.minX - grow * 2 - 4 && mouse.x <= s.frame.maxX + grow * 2 + 4

        // AX runs ~3–4 frames ahead of what the Dock draws, so it only starts
        // slides the pointer didn't cause (⌥⌘D, Mission Control), shifted back.
        let axLead = 0.06
        switch phase {
        case .hidden:
            if atEdge {
                phase = .waiting(min(now, edgeArrival ?? now))
            } else if let hint, hint > 0.3 {
                phase = .showing(now - max(0, Self.time(for: hint, duration: duration) - axLead))
            }
        case .waiting(let t):
            if now - t >= s.autohideDelay {
                phase = .showing(now)
            } else if !atEdge && !overDock {
                phase = .hidden
            }
        case .showing(let t):
            if now - t >= duration { phase = .shown }
        case .shown:
            if !overDock && !keepOpen {
                phase = .hiding(now)
            } else if let hint, hint < 0.5, !overDock {
                phase = .hiding(now - max(0, Self.time(for: 1 - hint, duration: duration) - axLead))
            }
        case .hiding(let t):
            if overDock || keepOpen {
                // Reverse from wherever the slide got to.
                let shown = 1 - Self.ease((now - t) / duration)
                phase = .showing(now - Self.time(for: shown, duration: duration))
            } else if now - t >= duration {
                phase = .hidden
            }
        }

        switch phase {
        case .hidden, .waiting: return -travel
        case .showing(let t): return -travel * (1 - Self.ease((now - t) / duration))
        case .shown: return 0
        case .hiding(let t): return -travel * Self.ease((now - t) / duration)
        }
    }
}

struct DockPrefs: Equatable {
    var orientation: DockOrientation = .bottom
    var autohide = false
    var magnification = false
    var tileSize: CGFloat = 48
    var largeSize: CGFloat = 64
    var autohideDelay: Double = 0.195
    var autohideDuration: Double = 0.20
    var showRecents = true
    var recentCount = 0
    var othersCount = 0
    var persistentBundleIDs: [String] = []
    var minimizeToApplication = false

    static func read() -> DockPrefs {
        let app = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(app)
        func value(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, app) }
        func number(_ key: String) -> Double? { (value(key) as? NSNumber)?.doubleValue }
        var p = DockPrefs()
        p.orientation = DockOrientation(rawValue: value("orientation") as? String ?? "bottom") ?? .bottom
        p.autohide = (value("autohide") as? Bool) ?? false
        p.magnification = (value("magnification") as? Bool) ?? false
        p.tileSize = CGFloat(number("tilesize") ?? 48)
        p.largeSize = CGFloat(number("largesize") ?? 64)
        // Measured on screen (Sonoma): ~0.2 s until the slide starts, ~0.2 s slide.
        // The delay pref doesn't include the ~25 ms it takes the Dock to start drawing.
        p.autohideDelay = number("autohide-delay").map { $0 + 0.025 } ?? 0.195
        p.autohideDuration = number("autohide-time-modifier").map { $0 * 0.4 } ?? 0.20
        p.showRecents = (value("show-recents") as? Bool) ?? true
        p.recentCount = (value("recent-apps") as? [Any])?.count ?? 0
        p.othersCount = (value("persistent-others") as? [Any])?.count ?? 0
        let apps = (value("persistent-apps") as? [[String: Any]]) ?? []
        p.minimizeToApplication = (value("minimize-to-application") as? Bool) ?? false
        p.persistentBundleIDs = apps.compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String }
        return p
    }
}

