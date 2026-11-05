import AppKit

/// Counts minimized windows, which each add a tile to the Dock, so the Dock's
/// width can be estimated without Accessibility.
///
/// There is no public "minimized" flag. A minimized window is off screen yet
/// still attached to the Space it was minimized from, on whichever display;
/// windows on other Spaces sit on a Space that isn't showing, and ordered-out
/// helper windows have no Space at all.
final class MinimizedWindowCounter: @unchecked Sendable {
    static let shared = MinimizedWindowCounter()

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias DisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private let connection: Int32?
    private let spacesForWindows: SpacesFn?
    private let managedDisplaySpaces: DisplaySpacesFn?
    private let queue = DispatchQueue(label: "dock.minimized-count", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var _count = 0

    /// Called on the main queue when the count changes.
    var onChange: (@Sendable () -> Void)?

    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }

    private init() {
        let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let conn = h.flatMap { dlsym($0, "SLSMainConnectionID") }.map { unsafeBitCast($0, to: ConnectionFn.self) }
        connection = conn?()
        spacesForWindows = h.flatMap { dlsym($0, "SLSCopySpacesForWindows") }.map { unsafeBitCast($0, to: SpacesFn.self) }
        managedDisplaySpaces = h.flatMap { dlsym($0, "SLSCopyManagedDisplaySpaces") }.map { unsafeBitCast($0, to: DisplaySpacesFn.self) }
    }

    /// The Space currently showing on each display, whether or not it has any
    /// windows (a display whose last window was just minimized still counts).
    private func currentSpaces() -> Set<Int> {
        guard let conn = connection, let fn = managedDisplaySpaces,
              let displays = fn(conn)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var ids = Set<Int>()
        for display in displays {
            if let current = display["Current Space"] as? [String: Any],
               let id = (current["ManagedSpaceID"] as? NSNumber)?.intValue ?? (current["id64"] as? NSNumber)?.intValue {
                ids.insert(id)
            }
        }
        return ids
    }

    func start() {
        guard timer == nil, connection != nil, spacesForWindows != nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.25)
        t.setEventHandler { [weak self] in self?.recount() }
        t.resume()
        timer = t
    }

    private func spaces(of window: CGWindowID) -> [Int] {
        guard let conn = connection, let fn = spacesForWindows,
              let ids = fn(conn, 0x7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return ids.map(\.intValue)
    }

    private func recount() {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let visibleApps = Set(apps.filter { !$0.isHidden }.map(\.processIdentifier))

        var visibleSpaces = currentSpaces()
        var candidates: [CGWindowID] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, visibleApps.contains(pid),
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 80, bounds.height >= 60 else { continue }
            if (w[kCGWindowIsOnscreen as String] as? Bool) ?? false {
                visibleSpaces.formUnion(spaces(of: id))
            } else {
                candidates.append(id)
            }
        }
        let minimized = candidates.filter { !Set(spaces(of: $0)).isDisjoint(with: visibleSpaces) }.count

        lock.lock()
        let changed = minimized != _count
        _count = minimized
        lock.unlock()
        if changed, let onChange { DispatchQueue.main.async(execute: onChange) }
    }
}
