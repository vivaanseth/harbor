import AppKit
@preconcurrency import ApplicationServices
import SwiftUI
import Combine

@MainActor
final class PreviewModel: ObservableObject {
    @Published var app: NSRunningApplication?
    @Published var windows: [WindowInfo] = []
    @Published var thumbs: [CGWindowID: NSImage] = [:]
    @Published var thumbHeight: CGFloat = 170
    @Published var hovered: CGWindowID?
}

/// Watches which Dock icon is under the pointer and shows that app's windows.
@MainActor
final class DockPreviewController {
    static let shared = DockPreviewController()

    private let model = PreviewModel()
    private var panel: FloatingPanel?
    private var observer: AXObserver?
    private var observedList: AXUIElement?
    private var observedPID: pid_t = 0
    private var watchdog: Timer?
    private var trackTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private var clickMonitor: Any?
    private var currentItemFrame: CGRect = .zero
    private var hoverGeneration = 0
    private var cancellables = Set<AnyCancellable>()
    private let settings = AppSettings.shared

    private init() {}

    func start() {
        settings.$dockPreviewsEnabled
            .removeDuplicates()
            .sink { [weak self] on in
                guard let self else { return }
                if on { self.ensureObserver() } else { self.teardown() }
            }
            .store(in: &cancellables)
        // Re-attach when the Dock restarts or Accessibility gets granted.
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.settings.dockPreviewsEnabled else { return }
                self.ensureObserver()
            }
        }
    }

    private func ensureObserver() {
        guard PermissionCache.shared.accessibility else { return }
        let pid = DockMonitor.shared.dockProcessID
        guard pid != 0 else { return }
        if observer != nil && observedPID == pid { return }
        teardownObserver()
        guard let list = DockMonitor.shared.dockListElement() else { return }

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<DockPreviewController>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.selectionChanged() }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, list, kAXSelectedChildrenChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedList = list
        observedPID = pid
    }

    private func teardownObserver() {
        if let obs = observer {
            if let list = observedList {
                AXObserverRemoveNotification(obs, list, kAXSelectedChildrenChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        observedList = nil
        observedPID = 0
    }

    private func teardown() {
        teardownObserver()
        hide(immediately: true)
    }

    // MARK: - Hover

    private func selectionChanged() {
        guard settings.dockPreviewsEnabled, let list = observedList else { return }
        hoverGeneration &+= 1
        let generation = hoverGeneration
        // The Dock is busy animating while the pointer moves over it; ask it
        // what's hovered off the main thread so widgets keep moving smoothly.
        WindowService.queue.async {
            var hovered: (NSRunningApplication, CGRect)?
            if let item = (AX.value(list, kAXSelectedChildrenAttribute) as? [AXUIElement])?.first,
               AX.subrole(item) == "AXApplicationDockItem",
               let url = AX.url(item), let frame = AX.frame(item),
               let app = Self.runningApp(for: url) {
                hovered = (app, frame)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.hovered(hovered, generation: generation) }
            }
        }
    }

    private func hovered(_ item: (NSRunningApplication, CGRect)?, generation: Int) {
        guard generation == hoverGeneration else { return }
        guard let (app, frame) = item else {
            scheduleHide()
            return
        }
        let itemFrame = ScreenGeometry.cocoaRect(fromCG: frame)
        WindowService.windows(for: app.processIdentifier) { [weak self] windows in
            // Drop results for an icon the pointer has already left.
            guard let self, generation == self.hoverGeneration else { return }
            guard !windows.isEmpty else { self.scheduleHide(delay: 0.05); return }
            self.currentItemFrame = itemFrame
            self.show(app: app, windows: windows)
        }
    }

    /// Off-main: `bundleURL` is a LaunchServices round trip per app.
    nonisolated private static func runningApp(for url: URL) -> NSRunningApplication? {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == target
        }
    }

    private func show(app: NSRunningApplication, windows: [WindowInfo]) {
        hideTask?.cancel()
        let sameApp = model.app?.processIdentifier == app.processIdentifier && panel?.isVisible == true
        model.app = app
        model.windows = windows
        model.thumbHeight = CGFloat(settings.previewThumbHeight)
        var thumbs: [CGWindowID: NSImage] = sameApp ? model.thumbs : [:]
        for w in windows { if let t = ThumbnailService.shared.cached(w.id) { thumbs[w.id] = t } }
        model.thumbs = thumbs

        let panel = self.panel ?? makePanel()
        let frame = panelFrame(for: windows)
        if panel.isVisible {
            panel.setFrame(frame, animated: !sameApp, duration: 0.14)
            if panel.alphaValue < 1 {
                // Caught mid fade-out: bring it back instead of letting it vanish.
                NSAnimationContext.runAnimationGroup { $0.duration = 0.1; panel.animator().alphaValue = 1 }
            }
        } else {
            panel.setFrame(frame.offsetBy(dx: 0, dy: -6), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                panel.animator().alphaValue = 1
                panel.animator().setFrame(frame, display: true)
            }
        }
        startTracking()
        ThumbnailService.shared.capture(windows, maxHeight: model.thumbHeight) { [weak self] id, img in
            guard let self, self.model.windows.contains(where: { $0.id == id }) else { return }
            self.model.thumbs[id] = img
        }
    }

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel(level: PanelLevel.drawers)
        p.host(DockPreviewView(model: model, onSelect: { [weak self] w in
            WindowService.focus(w)
            self?.hide(immediately: true)
        }, onClose: { [weak self] w in
            WindowService.close(w)
            self?.refreshSoon()
        }, onMinimize: { [weak self] w in
            WindowService.minimize(w)
            self?.refreshSoon()
        }))
        panel = p
        return p
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let app = self.model.app else { return }
            let generation = self.hoverGeneration
            WindowService.windows(for: app.processIdentifier) { [weak self] windows in
                guard let self, generation == self.hoverGeneration else { return }
                if windows.isEmpty { self.hide(immediately: true) } else { self.show(app: app, windows: windows) }
            }
        }
    }

    static func cardWidth(for w: WindowInfo, height: CGFloat) -> CGFloat {
        let aspect = min(max(w.frame.width / max(w.frame.height, 1), 0.65), 2.1)
        return max(150, height * aspect)
    }

    private func panelFrame(for windows: [WindowInfo]) -> NSRect {
        let dock = DockMonitor.shared.state
        let screen = dock.screenFrame.isEmpty ? (NSScreen.main?.frame ?? .zero) : dock.screenFrame
        let h = model.thumbHeight
        let spacing: CGFloat = 14, pad: CGFloat = 16
        let content = windows.reduce(CGFloat(0)) { $0 + Self.cardWidth(for: $1, height: h) } + spacing * CGFloat(windows.count - 1)
        let width = min(content + pad * 2, screen.width - 40)
        let height = h + 36 + pad * 2 + 6
        var x = currentItemFrame.midX - width / 2
        x = min(max(x, screen.minX + 12), screen.maxX - width - 12)
        let y = max(dock.frame.maxY, min(currentItemFrame.maxY, dock.frame.maxY + 40)) + 10
        return NSRect(x: round(x), y: round(y), width: round(width), height: round(height))
    }

    // MARK: - Hiding

    private func startTracking() {
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.hide(immediately: true) }
            }
        }
        guard trackTimer == nil else { return }
        trackTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPointer() }
        }
    }

    private func checkPointer() {
        guard let panel, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        // Include room the Dock takes up while magnified.
        let state = DockMonitor.shared.state
        let grow = state.model.maxGrowth
        let dock = state.frame.insetBy(dx: -8, dy: -8)
            .union(CGRect(x: state.frame.minX - grow.left - 8, y: state.frame.minY, width: state.frame.width + grow.left + grow.right + 16,
                          height: state.frame.height + state.largeSize - state.tileSize))
        let dockZone = CGRect(x: dock.minX, y: dock.minY - 10, width: dock.width, height: max(dock.height, currentItemFrame.maxY - dock.minY) + 12)
        // Bridge the gap between the icon and the panel so the pointer can travel up.
        let bridge = CGRect(x: min(currentItemFrame.minX, panel.frame.minX), y: dock.maxY - 4,
                            width: max(currentItemFrame.width, 1), height: panel.frame.minY - dock.maxY + 8)
            .union(CGRect(x: currentItemFrame.minX - 20, y: dock.maxY - 4, width: currentItemFrame.width + 40, height: panel.frame.minY - dock.maxY + 8))
        if panel.frame.insetBy(dx: -4, dy: -4).contains(mouse) || dockZone.contains(mouse) || bridge.contains(mouse) {
            hideTask?.cancel()
        } else {
            scheduleHide(delay: 0.12)
        }
    }

    private func scheduleHide(delay: Double = 0.25) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let mouse = NSEvent.mouseLocation
            if let panel, panel.isVisible, panel.frame.insetBy(dx: -4, dy: -4).contains(mouse) { return }
            hide(immediately: false)
        }
    }

    private func hide(immediately: Bool) {
        hideTask?.cancel()
        trackTimer?.invalidate()
        trackTimer = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        guard let panel, panel.isVisible else { return }
        if immediately {
            panel.orderOut(nil)
        } else {
            panel.fadeOut(duration: 0.12)
        }
        model.hovered = nil
    }
}

struct DockPreviewView: View {
    @ObservedObject var model: PreviewModel
    var onSelect: (WindowInfo) -> Void
    var onClose: (WindowInfo) -> Void
    var onMinimize: (WindowInfo) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(model.windows) { w in
                    WindowCard(window: w, appIcon: model.app?.icon, appName: model.app?.localizedName ?? "",
                               thumb: model.thumbs[w.id], height: model.thumbHeight,
                               width: DockPreviewController.cardWidth(for: w, height: model.thumbHeight),
                               highlighted: model.hovered == w.id,
                               onSelect: { onSelect(w) }, onClose: { onClose(w) }, onMinimize: { onMinimize(w) })
                        .onHover { inside in
                            if inside { model.hovered = w.id } else if model.hovered == w.id { model.hovered = nil }
                        }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlassBackground(radius: 24, emphasized: true))
        .environment(\.colorScheme, .dark)
    }
}

struct WindowCard: View {
    var window: WindowInfo
    var appIcon: NSImage?
    var appName: String
    var thumb: NSImage?
    var height: CGFloat
    var width: CGFloat
    var highlighted: Bool
    var showControls = true
    var onSelect: () -> Void
    var onClose: () -> Void = {}
    var onMinimize: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().frame(width: 22, height: 22)
                }
                Text(window.title.isEmpty ? appName : window.title)
                    .font(Theme.font(14, .bold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if window.isMinimized {
                    Image(systemName: "minus.circle").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.tertiary)
                } else if !window.isOnScreen {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, height: 26)

            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumb {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06))
                            if let appIcon {
                                Image(nsImage: appIcon).resizable().frame(width: 56, height: 56).opacity(0.85)
                            }
                        }
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(window.isMinimized ? 0.6 : 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(highlighted ? 0.55 : 0.12), lineWidth: highlighted ? 2 : 1)
                )
                if highlighted && showControls && window.ax != nil {
                    HStack(spacing: 6) {
                        controlButton("minus", onMinimize)
                        controlButton("xmark", onClose)
                    }
                    .padding(8)
                    .transition(.opacity)
                }
            }
        }
        .scaleEffect(highlighted ? 1.015 : 1)
        .animation(.easeOut(duration: 0.12), value: highlighted)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private func controlButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
