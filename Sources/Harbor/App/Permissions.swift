import AppKit
import ApplicationServices
import EventKit
import CoreLocation
import UserNotifications

enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility, screenRecording, calendar, location, notifications, automation
    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .calendar: return "Calendar"
        case .location: return "Location"
        case .notifications: return "Notifications"
        case .automation: return "Automation"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility: return "Dock previews, the Cmd+Tab switcher and window focusing. Widgets work without it."
        case .screenRecording: return "Live window thumbnails via ScreenCaptureKit."
        case .calendar: return "Apple Calendar events via EventKit."
        case .location: return "Weather for where you are, via Open-Meteo."
        case .notifications: return "Calendar reminders."
        case .automation: return "Apple Music and Spotify playback via Apple Events."
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .calendar: return "calendar"
        case .location: return "location.fill"
        case .notifications: return "bell.badge.fill"
        case .automation: return "gearshape.2.fill"
        }
    }

    var settingsAnchor: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .calendar: return "Privacy_Calendars"
        case .location: return "Privacy_LocationServices"
        case .notifications: return "Notifications"
        case .automation: return "Privacy_Automation"
        }
    }
}

enum PermissionState { case granted, denied, notDetermined }

/// Accessibility and Screen Recording checks are synchronous XPC calls to tccd
/// (measured up to ~190 ms). Hot paths read this cache instead; it refreshes
/// itself off the main thread.
final class PermissionCache: @unchecked Sendable {
    static let shared = PermissionCache()

    private let lock = NSLock()
    private var _accessibility = false
    private var _screenRecording = false
    private let queue = DispatchQueue(label: "permissions.cache", qos: .utility)
    private var timer: DispatchSourceTimer?

    private init() {
        _accessibility = AXIsProcessTrusted()
        _screenRecording = CGPreflightScreenCaptureAccess()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    var accessibility: Bool { lock.lock(); defer { lock.unlock() }; return _accessibility }
    var screenRecording: Bool { lock.lock(); defer { lock.unlock() }; return _screenRecording }

    private func refresh() {
        let ax = AXIsProcessTrusted()
        let sr = CGPreflightScreenCaptureAccess()
        lock.lock()
        _accessibility = ax
        _screenRecording = sr
        lock.unlock()
    }
}

@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var states: [PermissionKind: PermissionState] = [:]
    private var timer: Timer?

    private init() { refresh() }

    static var accessibilityGranted: Bool { PermissionCache.shared.accessibility }
    static var screenRecordingGranted: Bool { PermissionCache.shared.screenRecording }

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        var s: [PermissionKind: PermissionState] = [:]
        s[.accessibility] = AXIsProcessTrusted() ? .granted : .notDetermined
        s[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: s[.calendar] = .granted
        case .denied, .restricted, .writeOnly: s[.calendar] = .denied
        default: s[.calendar] = .notDetermined
        }
        switch LocationService.shared.authorizationStatus {
        case .authorizedAlways, .authorized: s[.location] = .granted
        case .denied, .restricted: s[.location] = .denied
        default: s[.location] = .notDetermined
        }
        s[.notifications] = notificationState
        s[.automation] = MusicService.shared.automationState
        states = s
    }

    private var notificationState: PermissionState = .notDetermined

    func refreshNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: PermissionState
            switch settings.authorizationStatus {
            case .authorized, .provisional: state = .granted
            case .denied: state = .denied
            default: state = .notDetermined
            }
            Task { @MainActor in
                self.notificationState = state
                self.refresh()
            }
        }
    }

    func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { openSettings(kind) }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openSettings(kind) }
        case .calendar:
            CalendarService.shared.requestAccess()
        case .location:
            if states[.location] == .denied { openSettings(kind) } else { LocationService.shared.requestAuthorization() }
        case .notifications:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                Task { @MainActor in self.refreshNotifications() }
            }
        case .automation:
            MusicService.shared.requestAutomation()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    /// Clears this app's Accessibility entry, then asks again. An entry saved
    /// for an earlier build stays listed and switched on but no longer
    /// applies, and switching it off and on keeps the stale record.
    func resetAccessibility() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.vivaanseth.harbor"]
        task.terminationHandler = { _ in
            Task { @MainActor in self.request(.accessibility) }
        }
        do { try task.run() } catch { request(.accessibility) }
    }

    func openSettings(_ kind: PermissionKind) {
        let url = kind == .notifications
            ? URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
            : URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)")!
        NSWorkspace.shared.open(url)
    }
}
