import AppKit
import EventKit
import SwiftUI
import UserNotifications

struct Attendee: Hashable {
    var name: String
    var initials: String
    var hue: Double
}

struct CalendarEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var calendarTitle: String
    var calendarColor: NSColor
    var meetingURL: URL?
    var attendees: [Attendee]

    var meetingService: String? {
        guard let host = meetingURL?.host?.lowercased() else { return nil }
        if host.contains("zoom") { return "Zoom" }
        if host.contains("meet.google") { return "Meet" }
        if host.contains("teams") { return "Teams" }
        if host.contains("webex") { return "Webex" }
        if host.contains("facetime") { return "FaceTime" }
        return "Call"
    }

    func isOngoing(at now: Date) -> Bool { start <= now && end > now }
}

@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var allDay: [CalendarEvent] = []
    @Published private(set) var authorized = false
    @Published private(set) var now = Date()
    @Published private(set) var shouldExpand = false
    @Published private(set) var calendars: [EKCalendar] = []

    let store = EKEventStore()
    private var timer: Timer?
    private var reloadTimer: Timer?
    private var observer: NSObjectProtocol?
    private var openedMeetings = Set<String>()
    private let settings = AppSettings.shared

    private init() {
        authorized = Self.hasAccess
    }

    static var hasAccess: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        return s == .fullAccess
    }

    func setActive(_ active: Bool) {
        if active, timer == nil {
            authorized = Self.hasAccess
            reload()
            timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            reloadTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            }
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            }
        } else if !active {
            timer?.invalidate(); timer = nil
            reloadTimer?.invalidate(); reloadTimer = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { granted, _ in
            Task { @MainActor in
                self.authorized = granted
                self.store.reset()
                self.reload()
                Permissions.shared.refresh()
            }
        }
    }

    /// Calendars that are on by default: everything except Birthdays and Holidays.
    func defaultCalendarIDs() -> [String] {
        store.calendars(for: .event).filter { c in
            c.type != .birthday && !c.title.localizedCaseInsensitiveContains("holiday")
        }.map(\.calendarIdentifier)
    }

    func reload() {
        authorized = Self.hasAccess
        guard authorized else { events = []; allDay = []; tick(); return }
        calendars = store.calendars(for: .event).sorted { $0.title < $1.title }
        let ids = Set(settings.calendarIDs ?? defaultCalendarIDs())
        let selected = calendars.filter { ids.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { events = []; allDay = []; tick(); return }

        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 2, to: startOfDay)!
        let predicate = store.predicateForEvents(withStart: startOfDay, end: end, calendars: selected)
        let ek = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        let mapped = ek.map(Self.map)
        events = mapped.filter { !$0.isAllDay }
        allDay = mapped.filter { $0.isAllDay && cal.isDateInToday($0.start) }
        tick()
    }

    private static func map(_ e: EKEvent) -> CalendarEvent {
        let attendees: [Attendee] = (e.attendees ?? []).compactMap { p in
            guard let name = p.name, !name.isEmpty else { return nil }
            let parts = name.split(separator: " ")
            let initials = parts.prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
            let hue = Double(abs(name.hashValue % 360)) / 360
            return Attendee(name: name, initials: initials.isEmpty ? "?" : initials, hue: hue)
        }
        return CalendarEvent(
            id: (e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)",
            title: e.title ?? "Untitled",
            start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
            location: e.location?.isEmpty == false ? e.location : nil,
            calendarTitle: e.calendar?.title ?? "",
            calendarColor: e.calendar?.color ?? .systemBlue,
            meetingURL: meetingLink(e),
            attendees: attendees)
    }

    private static let meetingPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s<>"']*(zoom\.us/(j|w|my)/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join|teams\.live\.com/meet|webex\.com/|whereby\.com/|facetime\.apple\.com/join|chime\.aws/|around\.co/)[^\s<>"']*"#,
        options: [.caseInsensitive])

    private static func meetingLink(_ e: EKEvent) -> URL? {
        let haystacks = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }
        for h in haystacks {
            let range = NSRange(h.startIndex..., in: h)
            if let m = meetingPattern.firstMatch(in: h, range: range), let r = Range(m.range, in: h) {
                return URL(string: String(h[r]))
            }
        }
        return nil
    }

    // MARK: - What matters right now

    /// The next event when it's about to start, or a short meeting until it ends.
    var focusEvent: CalendarEvent? {
        let upcoming = events.filter { $0.end > now }
        if let ongoing = upcoming.first(where: { $0.isOngoing(at: now) }) {
            let next = upcoming.first(where: { $0.start > now })
            let short = ongoing.end.timeIntervalSince(ongoing.start) <= 45 * 60
            if short || next == nil || next!.start.timeIntervalSince(now) > 10 * 60 { return ongoing }
            return next
        }
        return upcoming.first
    }

    func upcoming(after event: CalendarEvent) -> CalendarEvent? {
        events.first(where: { $0.start > event.start && $0.id != event.id })
    }

    var todayEvents: [CalendarEvent] {
        events.filter { Calendar.current.isDateInToday($0.start) }
    }

    private func tick() {
        now = Date()
        var expand = false
        if let e = focusEvent {
            expand = e.isOngoing(at: now) || e.start.timeIntervalSince(now) <= Double(settings.calendarLeadMinutes) * 60
            if settings.autoOpenMeetings, let url = e.meetingURL, !openedMeetings.contains(e.id),
               e.start <= now, now.timeIntervalSince(e.start) < 60 {
                openedMeetings.insert(e.id)
                NSWorkspace.shared.open(url)
            }
        }
        if expand != shouldExpand { shouldExpand = expand }
    }

    func join(_ e: CalendarEvent) {
        if let url = e.meetingURL { NSWorkspace.shared.open(url) }
    }

    func openInCalendar(_ e: CalendarEvent) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func remind(_ e: CalendarEvent, minutesBefore: Int = 5) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = e.title
            let f = DateFormatter()
            f.timeStyle = .short
            content.body = "Starts at \(f.string(from: e.start))" + (e.meetingService.map { " · \($0)" } ?? "")
            content.sound = .default
            if let link = e.meetingURL?.absoluteString { content.userInfo = ["link": link] }
            let fire = max(Date().addingTimeInterval(5), e.start.addingTimeInterval(-Double(minutesBefore) * 60))
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
            center.add(UNNotificationRequest(identifier: "remind-\(e.id)", content: content, trigger: trigger))
        }
    }

    // MARK: - Formatting

    static func countdown(_ e: CalendarEvent, now: Date) -> (String, Color) {
        if e.isOngoing(at: now) {
            let m = Int(ceil(e.end.timeIntervalSince(now) / 60))
            return ("\(m)m left", Theme.mint)
        }
        let secs = e.start.timeIntervalSince(now)
        let m = Int(ceil(secs / 60))
        let text: String
        if m < 60 { text = "in \(m)m" } else if m < 24 * 60 {
            text = m % 60 == 0 ? "in \(m / 60)h" : "in \(m / 60)h \(m % 60)m"
        } else { text = "tomorrow" }
        let color: Color = m <= 5 ? Theme.countdownPink : (m <= 15 ? Theme.warmOrange : Theme.secondary)
        return (text, color)
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: d)
    }
}
