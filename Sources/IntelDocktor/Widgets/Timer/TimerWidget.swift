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
        save()
    }

    func skip() { advance(notify: false) }

    private func tick() {
        now = Date()
        if let endDate, endDate <= now { advance(notify: true) }
    }

    private func advance(notify: Bool) {
        let finished = label
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
                HStack(spacing: 10 * s) {
                    TimerRing(progress: timer.progress, color: phaseColor(timer.phase), lineWidth: 3.5 * s)
                        .frame(width: 34 * s, height: 34 * s)
                    VStack(alignment: .leading, spacing: 1 * s) {
                        Text(timer.label).font(Theme.font(11.5 * s, .semibold)).foregroundStyle(Theme.secondary)
                        Text(timer.clock).font(Theme.font(19 * s, .bold)).monospacedDigit()
                    }
                    Spacer(minLength: 4)
                    IconButton(symbol: timer.isRunning ? "pause.fill" : "play.fill", size: 15 * s, tint: Theme.primary) {
                        timer.toggle()
                    }
                }
                .padding(.horizontal, 12 * s)
            }
        }
        .foregroundStyle(Theme.primary)
    }
}

struct TimerDrawer: View {
    @ObservedObject private var timer = FocusTimer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                ZStack {
                    TimerRing(progress: timer.progress, color: phaseColor(timer.phase), lineWidth: 6)
                    Image(systemName: timer.phase == .focus ? "brain.head.profile" : "cup.and.saucer.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(phaseColor(timer.phase))
                }
                .frame(width: 66, height: 66)
                VStack(alignment: .leading, spacing: 2) {
                    Text(timer.label).font(Theme.font(14, .semibold)).foregroundStyle(Theme.secondary)
                    Text(timer.clock).font(Theme.font(32, .bold)).monospacedDigit()
                }
                Spacer()
            }
            HStack(spacing: 8) {
                PillButton(title: timer.isRunning ? "Pause" : (timer.isIdle ? "Start" : "Resume"), prominent: true) { timer.toggle() }
                PillButton(title: "Skip") { timer.skip() }
                PillButton(title: "Reset") { timer.reset() }
            }
            HStack(spacing: 18) {
                Stepper("Focus \(timer.focusMinutes) min", value: $timer.focusMinutes, in: 5...120, step: 5)
                Stepper("Break \(timer.restMinutes) min", value: $timer.restMinutes, in: 1...60)
            }
            .font(Theme.font(12.5, .semibold))
            .foregroundStyle(Theme.secondary)
        }
    }
}
