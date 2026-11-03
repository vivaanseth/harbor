import AppKit
import ApplicationServices
import ScreenCaptureKit

/// SkyLight functions resolved at runtime (no private framework linking).
enum PrivateAPI {
    typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    typealias PostEventFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    typealias SymbolicHotKeyFn = @convention(c) (Int32, Bool) -> Int32
    typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    nonisolated(unsafe) private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ names: [String]) -> T? {
        for name in names {
            if let h = skylight, let p = dlsym(h, name) { return unsafeBitCast(p, to: T.self) }
            if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { return unsafeBitCast(p, to: T.self) }
        }
        return nil
    }

    static let setFrontProcess: SetFrontFn? = symbol(["_SLPSSetFrontProcessWithOptions"])
    static let postEventRecord: PostEventFn? = symbol(["SLPSPostEventRecordTo"])
    static let setSymbolicHotKeyEnabled: SymbolicHotKeyFn? =
        symbol(["CGSSetSymbolicHotKeyEnabled", "SLSSetSymbolicHotKeyEnabled"])
    /// GetProcessForPID is deprecated (and hidden from Swift) but still the
    /// only way to get a PSN for the window-server calls above.
    static let getProcessForPID: GetPSNFn? = symbol(["GetProcessForPID"])
}

enum SymbolicHotKeys {
    /// 1 = Cmd+Tab, 2 = Cmd+Shift+Tab.
    static func setNativeSwitcherEnabled(_ enabled: Bool) {
        guard let fn = PrivateAPI.setSymbolicHotKeyEnabled else { return }
        _ = fn(1, enabled)
        _ = fn(2, enabled)
    }
}

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    var title: String
    var frame: CGRect
    var isMinimized: Bool
    var isOnScreen: Bool
    var ax: AXUIElement?

    static func == (a: WindowInfo, b: WindowInfo) -> Bool {
        a.id == b.id && a.title == b.title && a.isMinimized == b.isMinimized
    }
}

// AX elements are safe to hand between threads; window lists are built off-main.
extension WindowInfo: @unchecked Sendable {}

@MainActor
enum WindowService {
    /// Serial queue for window enumeration: AX calls into other apps can
    /// block, so they never run on the main thread.
    nonisolated static let queue = DispatchQueue(label: "windows.enumerate", qos: .userInteractive)

    static func windows(for pid: pid_t, completion: @escaping @MainActor ([WindowInfo]) -> Void) {
        queue.async {
            let list = windows(for: pid)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(list) } }
        }
    }

    /// All real windows of an app: visible, minimized, and on other Spaces.
    nonisolated static func windows(for pid: pid_t) -> [WindowInfo] {
        var axByID: [CGWindowID: (AXUIElement, String, Bool, String?)] = [:]
        let trusted = PermissionCache.shared.accessibility
        if trusted {
            for w in AX.windows(of: pid) {
                guard let id = AX.windowID(w) else { continue }
                let title = AX.title(w) ?? ""
                let minimized = AX.bool(w, kAXMinimizedAttribute) ?? false
                axByID[id] = (w, title, minimized, AX.subrole(w))
            }
        }
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [WindowInfo] = []
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 80, bounds.height >= 60 else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let cgTitle = info[kCGWindowName as String] as? String ?? ""
            if let ax = axByID[id] {
                let sub = ax.3 ?? ""
                guard sub == kAXStandardWindowSubrole as String || sub == kAXDialogSubrole as String || sub.isEmpty else { continue }
                result.append(WindowInfo(id: id, pid: pid, title: ax.1.isEmpty ? cgTitle : ax.1, frame: bounds,
                                         isMinimized: ax.2, isOnScreen: onScreen, ax: ax.0))
            } else if !onScreen && !cgTitle.isEmpty {
                // Probably on another Space (AX only reports the current one).
                result.append(WindowInfo(id: id, pid: pid, title: cgTitle, frame: bounds,
                                         isMinimized: false, isOnScreen: false, ax: nil))
            } else if onScreen && !trusted {
                result.append(WindowInfo(id: id, pid: pid, title: cgTitle, frame: bounds,
                                         isMinimized: false, isOnScreen: true, ax: nil))
            }
        }
        // Visible first (CG order is front-to-back), then other Spaces, then minimized.
        return result.sorted { rank($0) < rank($1) }
    }

    nonisolated private static func rank(_ w: WindowInfo) -> Int {
        if w.isMinimized { return 2 }
        return w.isOnScreen ? 0 : 1
    }

    // MARK: - Focus

    static func focus(_ w: WindowInfo) {
        if let ax = w.ax, w.isMinimized {
            AX.set(ax, kAXMinimizedAttribute, kCFBooleanFalse)
        }
        bringToFront(pid: w.pid, windowID: w.id)
        if let ax = w.ax {
            AX.set(ax, kAXMainAttribute, kCFBooleanTrue)
            AX.perform(ax, kAXRaiseAction)
        }
    }

    static func activate(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        if let front = windows(for: app.processIdentifier).first(where: { $0.isOnScreen || $0.isMinimized }) {
            focus(front)
        } else {
            bringToFront(pid: app.processIdentifier, windowID: 0)
            app.activate(options: [.activateAllWindows])
            // An app with no windows (Finder, Music…) opens a new one on reopen.
            if let url = app.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
        }
    }

    private static func bringToFront(pid: pid_t, windowID: CGWindowID) {
        var psn = ProcessSerialNumber()
        guard let getPSN = PrivateAPI.getProcessForPID, getPSN(pid, &psn) == noErr,
              let setFront = PrivateAPI.setFrontProcess else {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
            return
        }
        _ = setFront(&psn, windowID, windowID == 0 ? 0x100 : 0x200)
        if windowID != 0 { makeKeyWindow(&psn, windowID) }
    }

    /// Ported from the Hammerspoon/AltTab technique: posts the two event
    /// records the window server uses to make a window key.
    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ windowID: CGWindowID) {
        guard let post = PrivateAPI.postEventRecord else { return }
        var wid = windowID
        for kind: UInt8 in [0x01, 0x02] {
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xf8
            bytes[0x08] = kind
            bytes[0x3a] = 0x10
            withUnsafeBytes(of: &wid) { raw in
                for i in 0..<4 { bytes[0x3c + i] = raw[i] }
            }
            for i in 0x20..<0x30 { bytes[i] = 0xff }
            bytes.withUnsafeMutableBufferPointer { buf in
                _ = post(&psn, buf.baseAddress!)
            }
        }
    }

    static func close(_ w: WindowInfo) {
        guard let ax = w.ax, let button = AX.element(ax, kAXCloseButtonAttribute) else { return }
        AX.perform(button, kAXPressAction)
    }

    static func minimize(_ w: WindowInfo) {
        guard let ax = w.ax else { return }
        AX.set(ax, kAXMinimizedAttribute, (w.isMinimized ? kCFBooleanFalse : kCFBooleanTrue)!)
    }
}

/// ScreenCaptureKit thumbnails with a small cache.
@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()
    private var cache: [CGWindowID: NSImage] = [:]
    private var content: SCShareableContent?
    private var contentFetched = Date.distantPast

    private init() {}

    func cached(_ id: CGWindowID) -> NSImage? { cache[id] }

    func capture(_ windows: [WindowInfo], maxHeight: CGFloat, update: @escaping @MainActor (CGWindowID, NSImage) -> Void) {
        guard PermissionCache.shared.screenRecording, !windows.isEmpty else { return }
        Task {
            guard let content = await shareableContent() else { return }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for w in windows {
                    guard let scw = content.windows.first(where: { $0.windowID == w.id }) else { continue }
                    let aspect = max(scw.frame.width, 1) / max(scw.frame.height, 1)
                    let h = min(maxHeight * scale, scw.frame.height * scale)
                    group.addTask {
                        let filter = SCContentFilter(desktopIndependentWindow: scw)
                        let config = SCStreamConfiguration()
                        config.height = Int(h)
                        config.width = Int(h * aspect)
                        config.showsCursor = false
                        config.ignoreShadowsSingleWindow = true
                        config.capturesAudio = false
                        let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        return (w.id, img)
                    }
                }
                for await (id, img) in group {
                    guard let img else { continue }
                    let ns = NSImage(cgImage: img, size: NSSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale))
                    self.cache[id] = ns
                    update(id, ns)
                }
            }
            if cache.count > 200 { cache.removeAll() }
        }
    }

    private func shareableContent() async -> SCShareableContent? {
        if let content, Date().timeIntervalSince(contentFetched) < 1.5 { return content }
        let fresh = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        if let fresh {
            content = fresh
            contentFetched = Date()
        }
        return fresh ?? content
    }
}
