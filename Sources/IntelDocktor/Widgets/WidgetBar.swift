import AppKit
import SwiftUI
import Combine

/// Per-widget state the SwiftUI views read (how tall the Dock is, whether
/// there was room for the full-width layout, hover).
@MainActor
final class WidgetHostModel: ObservableObject {
    let kind: WidgetKind
    @Published var height: CGFloat = 60
    @Published var width: CGFloat = 60
    @Published var compact = true
    @Published var hovering = false
    init(kind: WidgetKind) { self.kind = kind }
}

struct SizedWidget {
    var kind: WidgetKind
    var width: CGFloat
    var compact: Bool
    var size: CGFloat = 1
}

enum WidgetMetrics {
    struct Spec { var ideal: CGFloat; var min: CGFloat }

    @MainActor
    static func spec(_ kind: WidgetKind, height h: CGFloat, size: CGFloat = 1) -> Spec {
        let base = baseSpec(kind, height: h)
        return Spec(ideal: base.ideal * size, min: base.min * min(1, max(0.85, size)))
    }

    /// Glance tiles are square at medium size.
    static func compactWidth(_ h: CGFloat, size: CGFloat) -> CGFloat {
        round(h * min(1.2, max(0.8, size)))
    }

    @MainActor
    private static func baseSpec(_ kind: WidgetKind, height h: CGFloat) -> Spec {
        switch kind {
        case .music: return Spec(ideal: min(7.1 * h, 470), min: 236)
        case .stats: return Spec(ideal: min(7.1 * h, 470), min: 236)
        case .weather: return Spec(ideal: min(6.2 * h, 410), min: 214)
        case .calendar: return Spec(ideal: min(6.0 * h, 400), min: 196)
        case .timer: return Spec(ideal: min(3.4 * h, 220), min: 150)
        case .battery:
            let n = CGFloat(max(1, BatteryService.shared.visibleDevices.count))
            return Spec(ideal: min(n == 1 ? 3.4 * h : n * 2.35 * h, 520), min: n == 1 ? 150 : n * 112)
        }
    }

    @MainActor
    static func wantsWide(_ config: WidgetConfig) -> Bool {
        switch config.style {
        case .compact: return false
        case .wide: return true
        case .auto:
            switch config.kind {
            case .calendar: return CalendarService.shared.shouldExpand
            case .music: return MusicService.shared.nowPlaying != nil
            case .battery: return BatteryService.shared.visibleDevices.count > 1
            case .timer: return FocusTimer.shared.isRunning
            default: return true
            }
        }
    }

    /// Fit one side's widgets into the space between the Dock and the screen edge.
    /// `configs` are ordered from the outer screen edge toward the Dock.
    @MainActor
    static func fit(_ configs: [WidgetConfig], height h: CGFloat, available: CGFloat, gap: CGFloat) -> [SizedWidget] {
        var items: [SizedWidget] = configs.map { c in
            let wide = wantsWide(c)
            let size = CGFloat(c.size)
            return SizedWidget(kind: c.kind, width: wide ? spec(c.kind, height: h, size: size).ideal : compactWidth(h, size: size),
                               compact: !wide, size: size)
        }
        func total() -> CGFloat {
            items.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, items.count - 1))
        }
        // 1) Shrink full-width widgets toward their minimum.
        var excess = total() - available
        if excess > 0 {
            let shrinkable = items.indices.filter { !items[$0].compact }
                .reduce(CGFloat(0)) { $0 + items[$1].width - spec(items[$1].kind, height: h, size: items[$1].size).min }
            if shrinkable > 0 {
                let ratio = min(1, excess / shrinkable)
                for i in items.indices where !items[i].compact {
                    let s = spec(items[i].kind, height: h, size: items[i].size)
                    items[i].width -= (items[i].width - s.min) * ratio
                }
            }
        }
        // 2) Fall back to the glance layout, outermost first.
        excess = total() - available
        var i = 0
        while excess > 0.5 && i < items.count {
            if !items[i].compact {
                items[i].compact = true
                items[i].width = compactWidth(h, size: items[i].size)
                excess = total() - available
            }
            i += 1
        }
        // 3) Narrow the glance tiles a little before giving any up.
        excess = total() - available
        let compactCount = items.filter(\.compact).count
        if excess > 0.5 && compactCount > 0 {
            let squeeze = min(excess / CGFloat(compactCount), h * 0.2)
            for i in items.indices where items[i].compact { items[i].width = compactWidth(h, size: items[i].size) - squeeze }
        }
        // 4) Still too wide: drop widgets from the outer edge.
        while total() > available + 0.5 && !items.isEmpty { items.removeFirst() }
        return items
    }
}

/// Transparent, click-through-where-empty container that holds one side's widgets.
private final class StripView: NSView {
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@MainActor
final class WidgetBarController: NSObject {
    static let shared = WidgetBarController()

    private struct Base { var rect: NSRect; var side: WidgetSide }
    private struct Tween { var from: NSRect; var start: CFTimeInterval; var duration: Double }

    /// One stationary window per side of the Dock. Widgets move *inside* it:
    /// moving windows is a synchronous window-server round trip (6–120 ms on
    /// Intel GPUs while the Dock animates), moving views is not.
    private var strips: [WidgetSide: FloatingPanel] = [:]
    private var hosts: [WidgetKind: NSView] = [:]
    private var models: [WidgetKind: WidgetHostModel] = [:]
    /// Resting frames beside the resting Dock (screen coordinates).
    private var bases: [WidgetKind: Base] = [:]
    /// Frames currently shown (screen coordinates).
    private(set) var frames: [WidgetKind: NSRect] = [:]
    private var tweens: [WidgetKind: Tween] = [:]
    private let motion = DockMotion()
    private var link: CADisplayLink?
    private var linkScreenFrame: CGRect = .zero
    private var idleTicks = 0
    private var wakeTimer: Timer?
    private var mouseMonitor: Any?
    private var lastKeepAlive = false
    private var lastSlide: CGFloat = 0
    private var lastLiveMinY: CGFloat?
    private var layoutDock = DockState()
    private var pointerOverWidgets = false
    private var cancellables = Set<AnyCancellable>()
    private var layoutScheduled = false
    private let settings = AppSettings.shared

    /// Widgets stay up (even if the Dock hides) while you use them.
    var keepsDockAreaAlive: Bool { DrawerController.shared.openKind != nil || pointerOverWidgets }

    private override init() {}

    func start() {
        let trigger = PassthroughSubject<Void, Never>()
        trigger.sink { [weak self] in self?.scheduleLayout() }.store(in: &cancellables)

        DockMonitor.shared.$state.map { _ in () }.subscribe(trigger).store(in: &cancellables)
        settings.$widgets.map { _ in () }.subscribe(trigger).store(in: &cancellables)
        settings.$widgetsHidden.map { _ in () }.subscribe(trigger).store(in: &cancellables)
        settings.$widgetGap.map { _ in () }.subscribe(trigger).store(in: &cancellables)
        settings.$widgetHeight.map { _ in () }.subscribe(trigger).store(in: &cancellables)
        CalendarService.shared.$shouldExpand.removeDuplicates().map { _ in () }.subscribe(trigger).store(in: &cancellables)
        MusicService.shared.$nowPlaying.map { $0 != nil }.removeDuplicates().map { _ in () }
            .subscribe(trigger).store(in: &cancellables)
        FocusTimer.shared.$endDate.map { $0 != nil }.removeDuplicates().map { _ in () }
            .subscribe(trigger).store(in: &cancellables)
        BatteryService.shared.$devices.map { $0.count }.removeDuplicates().map { _ in () }
            .subscribe(trigger).store(in: &cancellables)
        settings.$hiddenDevices.map { _ in () }.subscribe(trigger).store(in: &cancellables)

        settings.$widgets
            .sink { [weak self] widgets in self?.updateServices(widgets) }
            .store(in: &cancellables)

        // Restart frame-by-frame tracking the moment the pointer heads for the
        // Dock (mouse monitors need no permission), plus a slow fallback check.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            let location = NSEvent.mouseLocation
            let time = event.timestamp
            MainActor.assumeIsolated { self?.pointerMoved(to: location, at: time) }
        }
        wakeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeIfNeeded() }
        }
        layout()
    }

    func frame(for kind: WidgetKind) -> NSRect? { frames[kind] }

    func setHoverHighlight(_ hovering: Bool, kind: WidgetKind) {
        if models[kind]?.hovering != hovering { models[kind]?.hovering = hovering }
    }

    private func updateServices(_ widgets: [WidgetConfig]) {
        let enabled = Set(widgets.filter(\.enabled).map(\.kind))
        StatsService.shared.setActive(enabled.contains(.stats))
        BatteryService.shared.setActive(enabled.contains(.battery))
        WeatherService.shared.setActive(enabled.contains(.weather))
        MusicService.shared.setActive(enabled.contains(.music))
        CalendarService.shared.setActive(enabled.contains(.calendar))
        FocusTimer.shared.setActive(enabled.contains(.timer))
    }

    func scheduleLayout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.layoutScheduled = false
            self?.layout()
        }
    }

    // MARK: - Layout (when the resting Dock or the widget set changes)

    private func layout() {
        let dock = DockMonitor.shared.state
        layoutDock = dock
        let hideAll = settings.widgetsHidden || dock.orientation != .bottom || dock.frame.isEmpty
        var placed: [WidgetKind: Base] = [:]
        var compactness: [WidgetKind: Bool] = [:]
        let gap = CGFloat(settings.widgetGap)

        if !hideAll {
            let h = round(dock.frame.height * CGFloat(min(1, max(0.5, settings.widgetHeight))))
            // Shorter-than-Dock widgets sit centred on the Dock's slab.
            let y = round(dock.frame.minY + (dock.frame.height - h) / 2)
            // Leave room for the Dock to grow under the pointer.
            let grow = dock.model.maxGrowth
            // Fit each side; widgets that don't fit move to the other side's outer
            // end rather than disappearing (and only vanish if neither side has room).
            func available(_ side: WidgetSide) -> CGFloat {
                side == .left
                    ? dock.frame.minX - dock.screenFrame.minX - gap * 2 - ceil(grow.left)
                    : dock.screenFrame.maxX - dock.frame.maxX - gap * 2 - ceil(grow.right)
            }
            func outward(_ configs: [WidgetConfig], _ side: WidgetSide) -> [WidgetConfig] {
                side == .left ? configs : configs.reversed()
            }
            var configsBySide: [WidgetSide: [WidgetConfig]] = [:]
            for side in WidgetSide.allCases { configsBySide[side] = settings.widgets.filter { $0.enabled && $0.side == side } }
            var spill: [WidgetSide: [WidgetConfig]] = [.left: [], .right: []]
            for side in WidgetSide.allCases {
                let list = outward(configsBySide[side] ?? [], side)
                let kept = Set(WidgetMetrics.fit(list, height: h, available: available(side), gap: gap).map(\.kind))
                spill[side == .left ? .right : .left]! += list.filter { !kept.contains($0.kind) }
            }
            for side in WidgetSide.allCases {
                // Spilled widgets join at the outer edge (first to go if still too wide).
                var configs = configsBySide[side] ?? []
                let extra = spill[side] ?? []
                configs = side == .left ? extra.reversed() + configs : configs + extra
                let sized = WidgetMetrics.fit(outward(configs, side), height: h, available: available(side), gap: gap)
                var x = side == .left ? dock.frame.minX - gap : dock.frame.maxX + gap
                for item in sized.reversed() { // Dock → outer edge
                    let w = round(item.width)
                    let rect: NSRect
                    if side == .left {
                        rect = NSRect(x: x - w, y: y, width: w, height: h)
                        x -= w + gap
                    } else {
                        rect = NSRect(x: x, y: y, width: w, height: h)
                        x += w + gap
                    }
                    placed[item.kind] = Base(rect: rect, side: side)
                    compactness[item.kind] = item.compact
                }
            }
        }

        // Strip windows: from the screen edge to a little past the resting Dock's
        // end, from the bottom of the screen to the top of the widgets. The
        // overlap is fully transparent (clicks and hover fall through to the
        // Dock) and lets the strip stay put while the Dock gains or loses a tile:
        // moving a window and the views inside it can't happen in the same frame.
        let overlap = dock.tileSize * 1.6
        for side in WidgetSide.allCases {
            let hasWidgets = placed.values.contains { $0.side == side }
            guard hasWidgets else { strips[side]?.orderOut(nil); continue }
            let top = dock.frame.maxY + 2
            let height = top - dock.screenFrame.minY
            let strip = ensureStrip(side)
            let current = strip.frame
            let sameBand = current.minY == dock.screenFrame.minY && current.height == height
            let stillFits: Bool
            switch side {
            case .left:
                stillFits = current.minX == dock.screenFrame.minX &&
                    current.maxX >= dock.frame.minX - gap && current.maxX <= dock.frame.minX + overlap * 2
            case .right:
                stillFits = current.maxX == dock.screenFrame.maxX &&
                    current.minX <= dock.frame.maxX + gap && current.minX >= dock.frame.maxX - overlap * 2
            }
            if !(sameBand && stillFits) {
                let rect: NSRect = side == .left
                    ? NSRect(x: dock.screenFrame.minX, y: dock.screenFrame.minY,
                             width: max(1, dock.frame.minX + overlap - dock.screenFrame.minX), height: height)
                    : NSRect(x: dock.frame.maxX - overlap, y: dock.screenFrame.minY,
                             width: max(1, dock.screenFrame.maxX - dock.frame.maxX + overlap), height: height)
                strip.setFrame(rect, display: false)
            }
            if !strip.isVisible { strip.orderFrontRegardless() }
        }

        let now = CACurrentMediaTime()
        let screenChanged = dock.screenFrame != linkScreenFrame
        for kind in WidgetKind.allCases {
            if let base = placed[kind] {
                let (host, model) = ensureHost(kind, side: base.side)
                if model.height != base.rect.height { model.height = base.rect.height }
                if model.width != base.rect.width { model.width = base.rect.width }
                let compact = compactness[kind] ?? true
                if model.compact != compact { model.compact = compact }
                if let old = bases[kind], let shown = frames[kind], !screenChanged, old.rect != base.rect || old.side != base.side {
                    tweens[kind] = Tween(from: shown, start: now, duration: 0.26)
                }
                bases[kind] = base
                if frames[kind] == nil {
                    // First appearance: fade in where it belongs.
                    host.alphaValue = 0
                    NSAnimationContext.runAnimationGroup { $0.duration = 0.2; host.animator().alphaValue = 1 }
                }
            } else if bases[kind] != nil {
                bases[kind] = nil
                frames[kind] = nil
                tweens[kind] = nil
                if let host = hosts[kind] {
                    NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; host.animator().alphaValue = 0 },
                                                         completionHandler: { [weak self] in
                        MainActor.assumeIsolated {
                            if self?.bases[kind] == nil { host.isHidden = true }
                        }
                    })
                }
                if DrawerController.shared.openKind == kind { DrawerController.shared.close() }
            }
        }
        if screenChanged { rebuildLink(for: dock.screenFrame) }
        wake()
        tick()
    }

    private func target(for base: Base) -> NSRect {
        let dy = keepsDockAreaAlive ? 0 : motion.slide
        let dx = base.side == .left ? -motion.growLeft : motion.growRight
        return base.rect.offsetBy(dx: dx, dy: dy)
    }

    // MARK: - Per-frame motion

    private func rebuildLink(for screenFrame: CGRect) {
        link?.invalidate()
        link = nil
        linkScreenFrame = screenFrame
        guard let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) ?? NSScreen.main else { return }
        let l = screen.displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// The Dock announced a new tile; start making room before it grows.
    func anticipateDockGrowth(_ growth: CGFloat) {
        motion.anticipate(growth: growth, restWidth: DockMonitor.shared.state.frame.width, now: CACurrentMediaTime())
        wake()
    }

    func wake() {
        idleTicks = 0
        if link == nil { rebuildLink(for: DockMonitor.shared.state.screenFrame) }
        link?.isPaused = false
        DockAXSampler.shared.fast = true
    }

    private func pointerMoved(to location: CGPoint, at time: TimeInterval) {
        let screen = DockMonitor.shared.state.screenFrame
        let atEdge = screen.insetBy(dx: 0, dy: -2).contains(location) && location.y <= screen.minY + 1
        if atEdge { if motion.edgeArrival == nil { motion.edgeArrival = time } } else { motion.edgeArrival = nil }
        wakeIfNeeded()
    }

    private func wakeIfNeeded() {
        guard link?.isPaused ?? true, !bases.isEmpty else { return }
        let dock = DockMonitor.shared.state
        if pointerNearDock(dock) { wake(); return }
        // The Dock can also slide for reasons other than the pointer (⌥⌘D).
        if dock.autohide, let live = DockMonitor.shared.liveListFrame(maxAge: 0.5) {
            if let last = lastLiveMinY, abs(live.minY - last) > 1 { wake() }
            lastLiveMinY = live.minY
        }
    }

    private func pointerNearDock(_ dock: DockState) -> Bool {
        let m = NSEvent.mouseLocation
        guard dock.screenFrame.insetBy(dx: 0, dy: -2).contains(m) else { return false }
        return m.y <= dock.frame.maxY + max(dock.largeSize, dock.tileSize) + 40
    }

    /// Compute each frame for the moment it reaches the screen, not when the
    /// callback runs, so widgets land where the Dock is when both are shown.
    @objc private func step(_ link: CADisplayLink) { tick(at: link.targetTimestamp) }

    private func tick(at time: CFTimeInterval? = nil) {
        let now = time ?? CACurrentMediaTime()
        // The Dock as the current layout saw it: a newer resting frame only takes
        // effect together with the widget positions computed for it.
        let dock = layoutDock
        let mouse = NSEvent.mouseLocation
        pointerOverWidgets = frames.values.contains { $0.insetBy(dx: -2, dy: -2).contains(mouse) }
        let keep = keepsDockAreaAlive
        motion.update(state: dock, now: now, keepAlive: keep)

        if keep != lastKeepAlive {
            lastKeepAlive = keep
            // Only animate if the Dock is actually away; otherwise nothing moves.
            if motion.slide < -0.5 {
                for (kind, shown) in frames { tweens[kind] = Tween(from: shown, start: now, duration: max(0.18, dock.autohideDuration)) }
            }
        }

        var animating = false
        let scale = NSScreen.screens.first(where: { $0.frame == dock.screenFrame })?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (kind, base) in bases {
            let goal = target(for: base)
            var rect = goal
            if let tw = tweens[kind] {
                let t = (now - tw.start) / tw.duration
                if t >= 1 {
                    tweens[kind] = nil
                } else {
                    rect = Self.lerp(tw.from, goal, Self.easeInOut(t))
                    animating = true
                }
            }
            rect.origin.x = (rect.origin.x * scale).rounded() / scale
            rect.origin.y = (rect.origin.y * scale).rounded() / scale
            apply(kind, rect, side: base.side)
        }
        CATransaction.commit()

        DrawerController.shared.follow()

        let moving = animating || abs(motion.slide - lastSlide) > 0.01 || !motion.isSettled
        lastSlide = motion.slide
        if moving || pointerNearDock(dock) {
            idleTicks = 0
        } else {
            idleTicks += 1
            if idleTicks > 30 {
                link?.isPaused = true
                DockAXSampler.shared.fast = false
            }
        }
    }

    private func apply(_ kind: WidgetKind, _ rect: NSRect, side: WidgetSide) {
        guard let host = hosts[kind], let strip = strips[side] else { return }
        if host.superview !== strip.contentView { strip.contentView?.addSubview(host) }
        host.isHidden = false
        // Screen → strip-local coordinates, against the strip's current frame
        // (so a strip that moved never leaves its widgets at a stale offset).
        let local = NSRect(x: rect.minX - strip.frame.minX, y: rect.minY - strip.frame.minY, width: rect.width, height: rect.height)
        if host.frame.size != local.size {
            host.frame = local
        } else if host.frame.origin != local.origin {
            host.setFrameOrigin(local.origin)
        }
        frames[kind] = rect
    }

    private static func easeInOut(_ x: Double) -> CGFloat {
        let t = min(max(x, 0), 1)
        return CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
    }

    private static func lerp(_ a: NSRect, _ b: NSRect, _ t: CGFloat) -> NSRect {
        NSRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    private func ensureStrip(_ side: WidgetSide) -> FloatingPanel {
        if let s = strips[side] { return s }
        let panel = FloatingPanel(level: PanelLevel.widgets)
        // Leave ignoresMouseEvents unset: by default the window server hit-tests
        // by alpha, so clicks on the gaps between widgets (and on the whole strip
        // while the Dock is hidden) fall through. Setting it to false disables that.
        let root = StripView()
        root.wantsLayer = true
        panel.contentView = root
        strips[side] = panel
        return panel
    }

    private func ensureHost(_ kind: WidgetKind, side: WidgetSide) -> (NSView, WidgetHostModel) {
        let strip = ensureStrip(side)
        if let h = hosts[kind], let m = models[kind] {
            if h.superview !== strip.contentView { strip.contentView?.addSubview(h) }
            return (h, m)
        }
        let model = WidgetHostModel(kind: kind)
        let host = FirstMouseHostingView(rootView: AnyView(WidgetContainer(model: model).environment(\.colorScheme, .dark)))
        host.wantsLayer = true
        strip.contentView?.addSubview(host)
        hosts[kind] = host
        models[kind] = model
        return (host, model)
    }

    func isWidgetWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return strips.values.contains { $0 === window }
    }
}

struct WidgetContainer: View {
    @ObservedObject var model: WidgetHostModel
    @ObservedObject private var drawer = DrawerController.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        let h = model.height
        let radius = Theme.barRadius(h)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GlassBackground(radius: radius, emphasized: drawer.openKind == model.kind || model.hovering))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onTapGesture { if settings.drawerMode != .never { DrawerController.shared.toggle(model.kind) } }
            .onHover { inside in
                WidgetBarController.shared.setHoverHighlight(inside, kind: model.kind)
                hoverTask?.cancel()
                if inside && settings.drawerMode == .hover && drawer.openKind != model.kind {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        if !Task.isCancelled { DrawerController.shared.open(model.kind) }
                    }
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.hovering)
    }

    @ViewBuilder private var content: some View {
        // Glance tiles may be squeezed narrower than the Dock is tall.
        let h = model.compact ? min(model.width, model.height) : model.height
        switch model.kind {
        case .music: MusicBarView(compact: model.compact, height: h)
        case .calendar: CalendarBarView(compact: model.compact, height: h)
        case .weather: WeatherBarView(compact: model.compact, height: h, width: model.width)
        case .stats: StatsBarView(compact: model.compact, height: h, width: model.width)
        case .battery: BatteryBarView(compact: model.compact, height: h)
        case .timer: TimerBarView(compact: model.compact, height: h)
        }
    }
}

// MARK: - Drawers

@MainActor
final class DrawerController: ObservableObject {
    static let shared = DrawerController()

    @Published private(set) var openKind: WidgetKind?
    @Published var searchVisible = false
    @Published var searchText = ""

    private var panel: FloatingPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var animatingUntil: CFTimeInterval = 0
    static let searchBarHeight: CGFloat = 50
    static let searchGap: CGFloat = 10

    private init() {
        $searchVisible.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reposition(animated: true) }
        }.store(in: &cancellables)
    }

    func toggle(_ kind: WidgetKind) {
        if openKind == kind { close() } else { open(kind) }
    }

    func open(_ kind: WidgetKind) {
        guard WidgetBarController.shared.frame(for: kind) != nil else { return }
        let panel = self.panel ?? makePanel()
        let switching = openKind != nil
        searchVisible = false
        searchText = ""
        openKind = kind
        panel.host(DrawerContainer(kind: kind))
        guard let target = targetFrame(for: kind) else { return }
        if switching {
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
        } else {
            panel.setFrame(target.offsetBy(dx: 0, dy: -10), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
        animatingUntil = CACurrentMediaTime() + 0.22
        installMonitors()
        WidgetBarController.shared.wake()
    }

    func close() {
        guard let panel, openKind != nil else { return }
        openKind = nil
        searchVisible = false
        removeMonitors()
        let end = panel.frame.offsetBy(dx: 0, dy: -8)
        animatingUntil = CACurrentMediaTime() + 0.17
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
            panel.animator().setFrame(end, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.openKind == nil else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                panel.contentView = nil
            }
        })
        WidgetBarController.shared.wake()
    }

    func focusSearch() {
        panel?.makeKey()
    }

    func reposition(animated: Bool = false) {
        guard let kind = openKind, let panel else { return }
        guard let target = targetFrame(for: kind) else { close(); return }
        if animated { animatingUntil = CACurrentMediaTime() + 0.2 }
        panel.setFrame(target, animated: animated, duration: 0.18)
    }

    /// Called every frame by the widget bar so the drawer rides along with its widget.
    func follow() {
        guard let kind = openKind, let panel, CACurrentMediaTime() > animatingUntil else { return }
        guard let target = targetFrame(for: kind) else { close(); return }
        if panel.frame.size != target.size {
            panel.setFrame(target, display: true)
        } else if panel.frame.origin != target.origin {
            panel.setFrameOrigin(target.origin)
        }
    }

    private func targetFrame(for kind: WidgetKind) -> NSRect? {
        guard let anchor = WidgetBarController.shared.frame(for: kind) else { return nil }
        let screen = DockMonitor.shared.state.screenFrame
        var size = DrawerMetrics.size(kind)
        if searchVisible { size.height += Self.searchBarHeight + Self.searchGap }
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        return NSRect(x: round(x), y: round(anchor.maxY + 10), width: size.width, height: size.height)
    }

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel(level: PanelLevel.drawers)
        p.allowsKey = true
        panel = p
        return p
    }

    private func installMonitors() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel && !WidgetBarController.shared.isWidgetWindow(event.window) {
                self.close()
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc
                if self.searchVisible { self.searchVisible = false; self.searchText = "" } else { self.close() }
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        keyMonitor = nil
    }
}

enum DrawerMetrics {
    @MainActor
    static func size(_ kind: WidgetKind) -> CGSize {
        switch kind {
        case .music: return CGSize(width: 400, height: 330)
        case .calendar: return CGSize(width: 410, height: 210)
        case .weather: return CGSize(width: 380, height: 282)
        case .stats: return CGSize(width: 390, height: 300)
        case .timer: return CGSize(width: 360, height: 200)
        case .battery:
            let devices = BatteryService.shared.visibleDevices
            let rows = devices.reduce(CGFloat(0)) { $0 + ($1.components.isEmpty ? 56 : 80) }
            return CGSize(width: 400, height: max(84, rows + 28))
        }
    }
}

struct DrawerContainer: View {
    let kind: WidgetKind
    @ObservedObject private var drawer = DrawerController.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: DrawerController.searchGap) {
            if drawer.searchVisible {
                searchBar
                    .frame(height: DrawerController.searchBarHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            drawerBody
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(GlassBackground(radius: Theme.drawerRadius, emphasized: true))
        }
        .foregroundStyle(Theme.primary)
    }

    @ViewBuilder private var drawerBody: some View {
        switch kind {
        case .music: MusicDrawer()
        case .calendar: CalendarDrawer()
        case .weather: WeatherDrawer()
        case .stats: StatsDrawer()
        case .battery: BatteryDrawer()
        case .timer: TimerDrawer()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            TextField(kind == .stats ? "Search processes" : "Search", text: $drawer.searchText)
                .textFieldStyle(.plain)
                .font(Theme.font(17, .semibold))
                .focused($searchFocused)
        }
        .padding(.horizontal, 18)
        .background(GlassBackground(radius: DrawerController.searchBarHeight / 2, emphasized: true))
        .onAppear {
            DrawerController.shared.focusSearch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
        }
    }
}
