import SwiftUI

private let weekday: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE"
    return f
}()

private let dayNumber: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "d"
    return f
}()

struct DateTile: View {
    var date: Date
    var size: CGFloat

    var body: some View {
        VStack(spacing: -size * 0.04) {
            Text(weekday.string(from: date).uppercased())
                .font(Theme.font(size * 0.19, .heavy))
                .foregroundStyle(.white.opacity(0.9))
            Text(dayNumber.string(from: date))
                .font(Theme.font(size * 0.47, .bold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xF0304F), Theme.calendarRed],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.75)
        )
    }
}

struct CalendarBarView: View {
    var compact: Bool
    var height: CGFloat
    @ObservedObject private var service = CalendarService.shared

    var body: some View {
        let s = height / 60
        if compact {
            DateTile(date: service.now, size: height - 10 * s)
        } else {
            wideBody(s)
        }
    }

    @ViewBuilder private func wideBody(_ s: CGFloat) -> some View {
        HStack(spacing: 11 * s) {
            DateTile(date: service.now, size: 40 * s)
            if let e = service.focusEvent {
                let cd = CalendarService.countdown(e, now: service.now)
                VStack(alignment: .leading, spacing: 2 * s) {
                    Text(e.title).font(Theme.font(15 * s, .bold)).lineLimit(1)
                    HStack(spacing: 6 * s) {
                        Text(CalendarService.time(e.start)).foregroundStyle(Theme.secondary)
                        Text(cd.0).foregroundStyle(cd.1)
                    }
                    .font(Theme.font(12.5 * s, .semibold))
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                if e.meetingURL != nil {
                    Button { service.join(e) } label: {
                        Image(systemName: "video.fill")
                            .font(.system(size: 16 * s, weight: .semibold))
                            .foregroundStyle(Theme.countdownPink)
                            .frame(width: 32 * s, height: 32 * s)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Join \(e.meetingService ?? "meeting")")
                }
            } else {
                VStack(alignment: .leading, spacing: 2 * s) {
                    Text(service.authorized ? "No more events" : "Calendar").font(Theme.font(14 * s, .bold))
                    Text(service.authorized ? "Enjoy the rest of your day" : "Click to connect")
                        .font(Theme.font(11.5 * s, .semibold)).foregroundStyle(Theme.secondary)
                }
                Spacer()
            }
        }
        .padding(.leading, 9 * s)
        .padding(.trailing, 12 * s)
        .foregroundStyle(Theme.primary)
    }
}

struct CalendarDrawer: View {
    @ObservedObject private var service = CalendarService.shared
    @State private var offset = 0
    @State private var showSchedule = false

    var body: some View {
        Group {
            if !service.authorized {
                EmptyStateView(symbol: "calendar.badge.plus", title: "Connect Apple Calendar",
                               message: "Events are read locally through EventKit.",
                               buttonTitle: "Allow Calendar Access") { service.requestAccess() }
            } else if showSchedule {
                schedule
            } else if let e = selectedEvent {
                card(e)
            } else {
                VStack {
                    header(nil)
                    EmptyStateView(symbol: "calendar", title: "Nothing else today",
                                   message: service.allDay.isEmpty ? nil : service.allDay.map(\.title).joined(separator: " · "))
                }
            }
        }
    }

    private var selectedEvent: CalendarEvent? {
        guard var e = service.focusEvent else { return nil }
        for _ in 0..<offset {
            guard let n = service.upcoming(after: e) else { break }
            e = n
        }
        return e
    }

    private func header(_ e: CalendarEvent?) -> some View {
        HStack {
            if let e, let next = service.upcoming(after: e) {
                Text("then \(CalendarService.time(next.start)) · \(next.title)")
                    .font(Theme.mono(12.5, .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            } else {
                Text(e == nil ? "Today" : "Last event today")
                    .font(Theme.mono(12.5, .medium))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            IconButton(symbol: showSchedule ? "rectangle.portrait" : "list.bullet", size: 13) {
                withAnimation(Motion.smooth) { showSchedule.toggle() }
            }
        }
    }

    private func card(_ e: CalendarEvent) -> some View {
        let tint = Color(nsColor: e.calendarColor)
        return VStack(alignment: .leading, spacing: 14) {
            header(e)
            HStack(spacing: 14) {
                Text(String(e.calendarTitle.prefix(1)).uppercased())
                    .font(Theme.font(24, .bold))
                    .foregroundStyle(tint.opacity(0.9))
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(tint.opacity(0.28)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(e.title).font(Theme.font(19, .bold)).lineLimit(1)
                    Text("\(CalendarService.time(e.start)) — \(CalendarService.time(e.end))" +
                         ((e.meetingService ?? e.location).map { " · \($0)" } ?? ""))
                        .font(Theme.mono(13.5, .medium))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if e.meetingURL != nil {
                    Button { service.join(e) } label: {
                        Image(systemName: "video.fill").font(.system(size: 20, weight: .semibold))
                            .frame(width: 40, height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Join \(e.meetingService ?? "meeting")")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { service.openInCalendar(e) }
            HStack(spacing: 8) {
                if !e.attendees.isEmpty {
                    HStack(spacing: -7) {
                        ForEach(Array(e.attendees.prefix(4).enumerated()), id: \.offset) { _, a in
                            Text(a.initials)
                                .font(Theme.font(10, .bold))
                                .frame(width: 27, height: 27)
                                .background(Circle().fill(Color(hue: a.hue, saturation: 0.55, brightness: 0.45)))
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                        }
                    }
                    Text("\(e.attendees.count) going").font(Theme.font(13, .semibold)).foregroundStyle(Theme.secondary)
                } else {
                    let cd = CalendarService.countdown(e, now: service.now)
                    Text(cd.0).font(Theme.font(13, .bold)).foregroundStyle(cd.1)
                }
                Spacer()
                if service.upcoming(after: e) != nil || offset > 0 {
                    PillButton(title: service.upcoming(after: e) == nil ? "First" : "Next") {
                        withAnimation(Motion.smooth) {
                            offset = service.upcoming(after: e) == nil ? 0 : offset + 1
                        }
                    }
                }
                if e.start > service.now {
                    PillButton(title: "Remind 5m", prominent: true) { service.remind(e) }
                }
            }
        }
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(nil)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(service.allDay) { e in
                        Text(e.title).font(Theme.font(12, .bold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color(nsColor: e.calendarColor).opacity(0.3)))
                    }
                    if service.todayEvents.isEmpty {
                        Text("No timed events today").font(Theme.font(12, .medium)).foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity).padding(.top, 20)
                    }
                    ForEach(service.todayEvents) { e in
                        let past = e.end < service.now
                        HStack(spacing: 10) {
                            Text(CalendarService.time(e.start)).font(Theme.mono(12, .medium))
                                .foregroundStyle(Theme.secondary).frame(width: 70, alignment: .leading)
                            Capsule().fill(Color(nsColor: e.calendarColor)).frame(width: 3, height: 26)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(e.title).font(Theme.font(13.5, .bold)).lineLimit(1)
                                if let sub = e.meetingService ?? e.location {
                                    Text(sub).font(Theme.font(11, .medium)).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if e.meetingURL != nil && !past {
                                IconButton(symbol: "video.fill", size: 12, tint: Theme.countdownPink) { service.join(e) }
                            }
                        }
                        .opacity(past ? 0.45 : 1)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}
