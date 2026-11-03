import SwiftUI
import UserNotifications

/// Pomodoro-style focus timer. State is stored as an end date, so it keeps
/// counting through sleep and relaunch.
@MainActor
final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()

    enum Phase: String { case focus, rest }

    @Published private(set) var phase: Phase
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var now = Date()
    /// Focus session within a set of four.
    @Published private(set) var session: Int
    @Published var focusMinutes: Int { didSet { defaults.set(focusMinutes, forKey: "timer.focus"); if isIdle { objectWillChange.send() } } }
    @Published var restMinutes: Int { didSet { defaults.set(restMinutes, forKey: "timer.rest") } }

    private let defaults = UserDefaults.standard
    private var ticker: Timer?

    private init() {
        phase = Phase(rawValue: defaults.string(forKey: "timer.phase") ?? "") ?? .focus
        endDate = defaults.object(forKey: "timer.end") as? Date
        pausedRemaining = defaults.object(forKey: "timer.paused") as? Double
        focusMinutes = defaults.object(forKey: "timer.focus") as? Int ?? 25
        restMinutes = defaults.object(forKey: "timer.rest") as? Int ?? 5
        session = max(1, defaults.integer(forKey: "timer.session"))
    }

    func setActive(_ on: Bool) {
        ticker?.invalidate()
        ticker = nil
        guard on else { return }
        tick()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    var length: TimeInterval { Double(phase == .focus ? focusMinutes : restMinutes) * 60 }
    var isRunning: Bool { endDate != nil }
    var isIdle: Bool { endDate == nil && pausedRemaining == nil }

    var remaining: TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return pausedRemaining ?? length
    }

    var progress: Double { length > 0 ? 1 - remaining / length : 0 }
    var label: String { phase == .focus ? "Focus" : "Break" }

    var clock: String {
        let s = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func toggle() { isRunning ? pause() : start() }

    func start() {
        endDate = Date().addingTimeInterval(pausedRemaining ?? length)
        pausedRemaining = nil
        save()
    }

    func pause() {
        pausedRemaining = remaining
        endDate = nil
        save()
    }

    func reset() {
        endDate = nil
        pausedRemaining = nil
        phase = .focus
        save()
    }

    func skip() { advance(notify: false) }

    private func tick() {
        now = Date()
        if let endDate, endDate <= now { advance(notify: true) }
    }

    /// "Ready", "Focusing", "On a break" or "Paused".
    var status: String {
        if isRunning { return phase == .focus ? "Focusing" : "On a break" }
        return isIdle ? "Ready" : "Paused"
    }

    private func advance(notify: Bool) {
        let finished = label
        if phase == .rest { session = session % 4 + 1 }
        phase = phase == .focus ? .rest : .focus
        // The next phase starts on its own, as a Pomodoro does.
        endDate = Date().addingTimeInterval(length)
        pausedRemaining = nil
        save()
        guard notify else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(finished) done"
        content.body = phase == .rest ? "Take \(restMinutes) minutes." : "Back to it: \(focusMinutes) minutes."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "focus-timer", content: content, trigger: nil))
    }

    private func save() {
        defaults.set(phase.rawValue, forKey: "timer.phase")
        defaults.set(endDate, forKey: "timer.end")
        defaults.set(pausedRemaining, forKey: "timer.paused")
        defaults.set(session, forKey: "timer.session")
        now = Date()
    }
}

private struct TimerRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private func phaseColor(_ phase: FocusTimer.Phase) -> Color {
    phase == .focus ? Color(hex: 0x6E9BF5) : Color(hex: 0xF0A07A)
}

struct TimerBarView: View {
    var compact: Bool
    var height: CGFloat
    @ObservedObject private var timer = FocusTimer.shared

    var body: some View {
        let s = height / 60
        Group {
            if compact {
                ZStack {
                    TimerRing(progress: timer.progress, color: phaseColor(timer.phase), lineWidth: 3.5 * s)
                        .frame(width: 42 * s, height: 42 * s)
                    Text(timer.clock).font(Theme.font(10.5 * s, .bold)).monospacedDigit()
                        .opacity(timer.isRunning ? 1 : 0.7)
                }
            } else {
                // "▶ 25:00": an orange play/pause glyph and the clock.
                HStack(spacing: 10 * s) {
                    Button { timer.toggle() } label: {
                        Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 15 * s, weight: .bold))
                            .foregroundStyle(timerOrange)
                            .frame(width: 26 * s, height: 26 * s)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text(timer.clock).font(Theme.font(19 * s, .bold)).monospacedDigit()
                }
                .padding(.horizontal, 12 * s)
            }
        }
        .foregroundStyle(Theme.primary)
    }
}

private let timerOrange = Color(hex: 0xF5A04A)

struct TimerDrawer: View {
    @ObservedObject private var timer = FocusTimer.shared

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(timerOrange).frame(width: 6, height: 6)
                Text(timer.status).font(Theme.font(11.5, .bold)).foregroundStyle(timerOrange)
            }
            Text(timer.clock).font(Theme.font(34, .bold)).monospacedDigit()
            Text("\(timer.label) · Session \(timer.session) of 4")
                .font(Theme.font(11, .semibold)).foregroundStyle(Theme.secondary)
            HStack(spacing: 10) {
                round(timer.isRunning ? "pause.fill" : "play.fill") { timer.toggle() }
                round("forward.end.fill") { timer.skip() }
                round("arrow.counterclockwise") { timer.reset() }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .contextMenu {
            Stepper("Focus \(timer.focusMinutes) min", value: Binding(get: { timer.focusMinutes }, set: { timer.focusMinutes = $0 }), in: 5...120, step: 5)
            Stepper("Break \(timer.restMinutes) min", value: Binding(get: { timer.restMinutes }, set: { timer.restMinutes = $0 }), in: 1...60)
            Button("Focus 25 · Break 5") { timer.focusMinutes = 25; timer.restMinutes = 5 }
            Button("Focus 50 · Break 10") { timer.focusMinutes = 50; timer.restMinutes = 10 }
        }
    }

    private func round(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
