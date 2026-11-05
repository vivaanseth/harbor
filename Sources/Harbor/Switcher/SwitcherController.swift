import AppKit
import SwiftUI
import Combine

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<SwitcherKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

/// The Cmd+Tab event tap, on its own thread. Every keystroke on the Mac passes
/// through it, so it only decides swallow/pass and hands the rest to the UI.
final class SwitcherKeyTap: @unchecked Sendable {
    enum Action { case begin(reverse: Bool), step(Int), key(Int64, CGEventFlags), release, tile(Int64) }

    private let lock = NSLock()
    private var _active = false
    private var _switcherOn = true
    private var _tilingOn = false

    /// Which features the tap serves; set from the main thread.
    func configure(switcher: Bool, tiling: Bool) {
        lock.lock(); _switcherOn = switcher; _tilingOn = tiling; lock.unlock()
    }
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private let onAction: @Sendable (Action) -> Void

    init(onAction: @escaping @Sendable (Action) -> Void) { self.onAction = onAction }

    /// Whether a switch is in progress (keys are swallowed while true).
    var active: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _active }
        set { lock.lock(); _active = newValue; lock.unlock() }
    }

    var isRunning: Bool { port != nil }
    var isEnabled: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        guard port == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: keyTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let rl = CFRunLoopGetCurrent()
            CFRunLoopAddSource(rl, source, .commonModes)
            self?.runLoop = rl
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "switcher.keytap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        port = nil
        runLoop = nil
        active = false
    }

    /// Runs on the tap thread. Returns true to swallow the event.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        case .keyDown:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            lock.lock()
            let switcherOn = _switcherOn, tilingOn = _tilingOn
            lock.unlock()
            // ⌃⌥ + arrow: window tiling.
            if tilingOn && (123...126).contains(key) && flags.contains(.maskControl) && flags.contains(.maskAlternate)
                && !flags.contains(.maskCommand) && !flags.contains(.maskShift) {
                post(.tile(key))
                return true
            }
            guard switcherOn else { return false }
            if key == 48 && flags.contains(.maskCommand) && !flags.contains(.maskControl) && !flags.contains(.maskAlternate) {
                lock.lock()
                let wasActive = _active
                _active = true
                lock.unlock()
                let shift = flags.contains(.maskShift)
                post(wasActive ? .step(shift ? -1 : 1) : .begin(reverse: shift))
                return true
            }
            guard active else { return false }
            post(.key(key, flags))
            return true
        case .keyUp:
            return active
        case .flagsChanged:
            if !event.flags.contains(.maskCommand) {
                lock.lock()
                let wasActive = _active
                _active = false
                lock.unlock()
                if wasActive { post(.release) }
            }
            return false
        default:
            return false
        }
    }

    private func post(_ action: Action) {
        let callback = onAction
        DispatchQueue.main.async { callback(action) }
    }
}

/// Cmd+Tab replacement that shows the highlighted app's windows as thumbnails.
@MainActor
final class SwitcherController: ObservableObject {
    static let shared = SwitcherController()

    @Published private(set) var apps: [NSRunningApplication] = []
    @Published var appIndex = 0
    @Published private(set) var windows: [WindowInfo] = []
    @Published var windowIndex: Int?
    @Published private(set) var thumbs: [CGWindowID: NSImage] = [:]
    @Published private(set) var visible = false

    private lazy var keyTap = SwitcherKeyTap { action in
        MainActor.assumeIsolated { SwitcherController.shared.perform(action) }
    }
    private var watchdogStarted = false
    private var loadGeneration = 0
    private var mru: [pid_t] = []
    private var active = false
    private var panel: FloatingPanel?
    private var showTask: Task<Void, Never>?
    private var retryTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let settings = AppSettings.shared

    private init() {}

    func start() {
        if let front = NSWorkspace.shared.frontmostApplication { mru = [front.processIdentifier] }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in
                guard let self else { return }
                self.mru.removeAll { $0 == app.processIdentifier }
                self.mru.insert(app.processIdentifier, at: 0)
            }
            .store(in: &cancellables)

        settings.$switcherEnabled.combineLatest(settings.$tilingEnabled)
            .sink { [weak self] switcher, tiling in self?.updateTap(switcher: switcher, tiling: tiling) }
            .store(in: &cancellables)

        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTap() }
        }
    }

    /// Keep the tap healthy; if it can't run, hand Cmd+Tab back to macOS.
    /// The tap serves Cmd+Tab and ⌃⌥-arrow tiling; the system Cmd+Tab is only
    /// switched off while our switcher is on.
    private func updateTap(switcher: Bool, tiling: Bool) {
        keyTap.configure(switcher: switcher, tiling: tiling)
        if switcher || tiling {
            installTap()
            if keyTap.isRunning { SymbolicHotKeys.setNativeSwitcherEnabled(!switcher) }
        } else {
            stop()
        }
        if !switcher && active { cancel() }
    }

    private func checkTap() {
        guard settings.switcherEnabled || settings.tilingEnabled else { return }
        if !PermissionCache.shared.accessibility {
            if keyTap.isRunning { stop() }
            return
        }
        if !keyTap.isRunning { installTap(); return }
        if !keyTap.isEnabled {
            keyTap.reenable()
            if !keyTap.isEnabled { stop() }
        }
    }

    private func installTap() {
        guard !keyTap.isRunning, PermissionCache.shared.accessibility else { return }
        guard keyTap.start() else { return }
        startHotKeyWatchdog()
        SymbolicHotKeys.setNativeSwitcherEnabled(!settings.switcherEnabled)
    }

    func stop() {
        keyTap.stop()
        SymbolicHotKeys.setNativeSwitcherEnabled(true)
        if active { cancel() }
    }

    /// A tiny helper process that restores the system Cmd+Tab if this app is
    /// force-quit (signal handlers can't catch SIGKILL).
    private func startHotKeyWatchdog() {
        guard !watchdogStarted, let exe = Bundle.main.executableURL else { return }
        watchdogStarted = true
        let p = Process()
        p.executableURL = exe
        p.arguments = [HotKeyWatchdog.flag, String(getpid())]
        try? p.run()
    }

    // MARK: - Actions from the key tap

    fileprivate func perform(_ action: SwitcherKeyTap.Action) {
        switch action {
        case .begin(let reverse):
            begin(reverse: reverse)
        case .step(let delta):
            if active { step(delta) } else { begin(reverse: delta < 0) }
        case .release:
            if active { commit() }
        case .tile(let key):
            WindowTiling.shared.tile(arrowKey: key)
        case .key(let key, let flags):
            guard active else { return }
            switch key {
            case 53: cancel()                                  // Esc
            case 123: horizontal(-1)                           // ←
            case 124: horizontal(1)                            // →
            case 126: enterWindows()                           // ↑
            case 125: windowIndex = nil                        // ↓
            case 36, 76: commit()                              // Return
            case 12: quitSelected()                            // Q
            case 4: hideSelected()                             // H
            case 13: closeSelectedWindow()                     // W
            case 50: step(flags.contains(.maskShift) ? -1 : 1) // `
            default: break
            }
        }
    }

    private func orderedApps() -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated
        }
        let byPID = Dictionary(running.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        var ordered = mru.compactMap { byPID[$0] }
        let seen = Set(ordered.map(\.processIdentifier))
        if let front = NSWorkspace.shared.frontmostApplication, !seen.contains(front.processIdentifier),
           byPID[front.processIdentifier] != nil {
            ordered.insert(front, at: 0)
        }
        ordered += running.filter { !seen.contains($0.processIdentifier) && $0 != NSWorkspace.shared.frontmostApplication }
        return ordered
    }


    private func begin(reverse: Bool) {
        apps = orderedApps()
        guard !apps.isEmpty else { keyTap.active = false; return }
        active = true
        windowIndex = nil
        appIndex = apps.count > 1 ? (reverse ? apps.count - 1 : 1) : 0
        loadWindows()
        showTask?.cancel()
        // Quick Cmd+Tab taps switch without flashing the panel.
        showTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled, self.active else { return }
            self.showPanel()
        }
    }

    private func step(_ delta: Int) {
        guard !apps.isEmpty else { return }
        if windowIndex != nil {
            horizontal(delta)
            return
        }
        appIndex = (appIndex + delta + apps.count) % apps.count
        loadWindows()
    }

    private func horizontal(_ delta: Int) {
        if let wi = windowIndex, !windows.isEmpty {
            windowIndex = (wi + delta + windows.count) % windows.count
        } else {
            step(delta)
        }
    }

    private func enterWindows() {
        guard settings.switcherShowsWindows, !windows.isEmpty else { return }
        if windowIndex == nil { windowIndex = 0 }
    }

    func select(app index: Int) {
        guard apps.indices.contains(index), index != appIndex else { return }
        appIndex = index
        windowIndex = nil
        loadWindows()
    }

    func commit(window index: Int? = nil) {
        if let index { windowIndex = index }
        guard active, apps.indices.contains(appIndex) else { cancel(); return }
        let app = apps[appIndex]
        let chosen = windowIndex.flatMap { windows.indices.contains($0) ? windows[$0] : nil }
        finish()
        if let chosen {
            WindowService.focus(chosen)
        } else {
            WindowService.activate(app)
        }
    }

    func cancel() { finish() }

    private func finish() {
        active = false
        keyTap.active = false
        showTask?.cancel()
        visible = false
        panel?.orderOut(nil)
    }

    private func quitSelected() {
        guard apps.indices.contains(appIndex) else { return }
        let app = apps[appIndex]
        app.terminate()
        apps.remove(at: appIndex)
        if apps.isEmpty { cancel(); return }
        appIndex = min(appIndex, apps.count - 1)
        loadWindows()
    }

    private func hideSelected() {
        guard apps.indices.contains(appIndex) else { return }
        apps[appIndex].hide()
    }

    private func closeSelectedWindow() {
        guard let wi = windowIndex, windows.indices.contains(wi) else { return }
        WindowService.close(windows[wi])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.loadWindows() }
    }

    private func loadWindows() {
        guard apps.indices.contains(appIndex) else { windows = []; return }
        let pid = apps[appIndex].processIdentifier
        guard settings.switcherShowsWindows else { windows = []; return }
        loadGeneration &+= 1
        let generation = loadGeneration
        WindowService.windows(for: pid) { [weak self] list in
            guard let self, generation == self.loadGeneration, self.active else { return }
            self.windows = list
            if let wi = self.windowIndex, wi >= list.count { self.windowIndex = list.isEmpty ? nil : list.count - 1 }
            var t: [CGWindowID: NSImage] = [:]
            for w in list { if let c = ThumbnailService.shared.cached(w.id) { t[w.id] = c } }
            self.thumbs = t
            ThumbnailService.shared.capture(list, maxHeight: 220) { [weak self] id, img in
                guard let self, self.windows.contains(where: { $0.id == id }) else { return }
                self.thumbs[id] = img
            }
        }
    }

    private func showPanel() {
        let screen = ScreenGeometry.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens[0]
        let panel = self.panel ?? {
            let p = FloatingPanel(level: PanelLevel.switcher)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.host(SwitcherView(controller: self))
            self.panel = p
            return p
        }()
        panel.setFrame(screen.frame, display: true)
        visible = true
        panel.orderFrontRegardless()
    }
}

/// Laid out like Apple's Cmd+Tab: one rounded panel of icons, a highlight
/// that slides to the selected app, its name underneath. The panel itself
/// appears and goes away at once, as Apple's does: it's used too often to
/// animate. Above it, the selected app's windows when there are several.
struct SwitcherView: View {
    @ObservedObject var controller: SwitcherController
    @Namespace private var selection

    var body: some View {
        GeometryReader { geo in
            let apps = controller.apps
            let maxWidth = geo.size.width - 120
            let iconSize = min(96, max(40, (maxWidth - 48) / CGFloat(max(apps.count, 1)) - 26))
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                if !controller.windows.isEmpty {
                    windowsCard(maxWidth: maxWidth)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
                }
                iconsCard(iconSize: iconSize)
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture { controller.cancel() }
        }
        .foregroundStyle(Theme.primary)
        .animation(Motion.snappy, value: controller.appIndex)
        .animation(Motion.snappy, value: controller.windowIndex)
        .animation(Motion.smooth, value: controller.windows.map(\.id))
    }

    private func windowsCard(maxWidth: CGFloat) -> some View {
        let h: CGFloat = 190
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        let selected = controller.windowIndex.flatMap { controller.windows.indices.contains($0) ? controller.windows[$0] : nil }
        let app = controller.apps.indices.contains(controller.appIndex) ? controller.apps[controller.appIndex] : nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let icon = app?.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                Text((selected ?? controller.windows.first)?.title.nilIfEmpty ?? app?.localizedName ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(controller.windows.enumerated()), id: \.element.id) { i, w in
                        let width = DockPreviewController.cardWidth(for: w, height: h)
                        thumb(w, width: width, height: h, selected: controller.windowIndex == i)
                            .onTapGesture { controller.commit(window: i) }
                    }
                }
                .padding(4)
            }
            .frame(maxWidth: maxWidth - 60)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(20)
        .background(GlassBackground(radius: 26, variant: .regular))
        .outerShadow(shape, radius: 22, y: 10, opacity: 0.35)
    }

    private func thumb(_ w: WindowInfo, width: CGFloat, height: CGFloat, selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Group {
            if let img = controller.thumbs[w.id] {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    shape.fill(Theme.tile)
                    Text(w.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary).padding()
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.1)),
                                    lineWidth: selected ? 3 : 0.5))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .scaleEffect(selected ? 1.02 : 1)
        .opacity(w.isMinimized ? 0.65 : 1)
    }

    private func iconsCard(iconSize: CGFloat) -> some View {
        let pad = (iconSize * 0.12).rounded()
        let cell = iconSize + pad * 2
        let spacing: CGFloat = 4
        let shape = RoundedRectangle(cornerRadius: (cell * 0.28 + 12).rounded(), style: .continuous)
        let apps = controller.apps
        let index = controller.appIndex
        // Centre of the selected cell, from the middle of the row.
        let offset = (CGFloat(index) - CGFloat(apps.count - 1) / 2) * (cell + spacing)
        return VStack(spacing: 8) {
            HStack(spacing: spacing) {
                ForEach(Array(apps.enumerated()), id: \.element.processIdentifier) { i, app in
                    let selected = i == index
                    Image(nsImage: app.icon ?? NSImage())
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                        .padding(pad)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: (cell * 0.24).rounded(), style: .continuous)
                                    .fill(Color.white.opacity(controller.windowIndex == nil ? 0.17 : 0.09))
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .opacity(app.isHidden ? 0.5 : 1)
                        .onHover { if $0 { controller.select(app: i) } }
                        .onTapGesture { controller.select(app: i); controller.commit() }
                }
            }
            // The name sits under the selected icon, as in Apple's switcher.
            Text(apps.indices.contains(index) ? (apps[index].localizedName ?? "") : "")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.primary.opacity(0.9))
                .lineLimit(1)
                .fixedSize()
                .offset(x: offset)
                .frame(height: 16)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(GlassBackground(radius: (cell * 0.28 + 12).rounded(), variant: .regular))
        .outerShadow(shape, radius: 22, y: 10, opacity: 0.35)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
