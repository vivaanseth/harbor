import AppKit
import SwiftUI
import Combine

/// One Dock slot holding several widgets. Scroll over it to flip through them;
/// on its own it turns to whatever matters now (a running timer, an event about
/// to start, music playing) unless you flipped it in the last minute.
@MainActor
final class SmartStack: ObservableObject {
    static let shared = SmartStack()

    @Published private(set) var current: WidgetKind = .weather
    private var userPickedAt = Date.distantPast
    private var scrollMonitor: Any?
    private var timer: Timer?
    private var scrollAccumulator: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()
    private let settings = AppSettings.shared

    private init() {}

    var kinds: [WidgetKind] { settings.stackKinds.filter { $0 != .stack } }

    func setActive(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        guard on else { return }
        if !kinds.contains(current), let first = kinds.first { current = first }
        rotate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rotate() }
        }
        // Scroll events over our own widget windows arrive as local events.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let frame = WidgetBarController.shared.frame(for: .stack),
                  frame.contains(NSEvent.mouseLocation) else { return event }
            self.scrolled(event)
            return nil
        }
        settings.$stackKinds.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rotate() }
        }.store(in: &cancellables)
    }

    func step(_ delta: Int) {
        let list = kinds
        guard !list.isEmpty else { return }
        let i = list.firstIndex(of: current) ?? 0
        show(list[(i + delta + list.count) % list.count])
        userPickedAt = Date()
    }

    private func scrolled(_ event: NSEvent) {
        // Trackpads send many small deltas; flip once per deliberate swipe.
        if event.phase == .began || event.momentumPhase == .began { scrollAccumulator = 0 }
        guard event.momentumPhase == [] else { return }
        scrollAccumulator += event.scrollingDeltaY + event.scrollingDeltaX
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 28 : 1
        if abs(scrollAccumulator) >= threshold {
            step(scrollAccumulator < 0 ? 1 : -1)
            scrollAccumulator = 0
        }
    }

    /// The widget that matters most right now, if any.
    private var mostRelevant: WidgetKind? {
        let list = kinds
        if list.contains(.timer), FocusTimer.shared.isRunning { return .timer }
        if list.contains(.calendar), CalendarService.shared.shouldExpand { return .calendar }
        if list.contains(.music), MusicService.shared.nowPlaying?.isPlaying == true { return .music }
        return nil
    }

    private func rotate() {
        let list = kinds
        guard !list.isEmpty else { return }
        if !list.contains(current) { show(list[0]); return }
        guard settings.stackSmartRotate, Date().timeIntervalSince(userPickedAt) > 60,
              let best = mostRelevant, best != current else { return }
        show(best)
    }

    private func show(_ kind: WidgetKind) {
        guard kind != current else { return }
        withAnimation(Motion.smooth) { current = kind }
        if DrawerController.shared.openKind == .stack { DrawerController.shared.open(.stack) }
        WidgetBarController.shared.scheduleLayout()
    }
}

struct SmartStackBarView: View {
    var compact: Bool
    var height: CGFloat
    var width: CGFloat
    @ObservedObject private var stack = SmartStack.shared

    var body: some View {
        let s = height / 60
        ZStack(alignment: .trailing) {
            Group {
                switch stack.current {
                case .music: MusicBarView(compact: compact, height: height)
                case .calendar: CalendarBarView(compact: compact, height: height)
                case .weather: WeatherBarView(compact: compact, height: height, width: width)
                case .stats: StatsBarView(compact: compact, height: height, width: width)
                case .battery: BatteryBarView(compact: compact, height: height)
                case .timer: TimerBarView(compact: compact, height: height)
                case .stack: EmptyView()
                }
            }
            .id(stack.current)
            // Pages scroll up through the stack, as in Apple's Smart Stack.
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.94))))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // Page dots, like a Smart Stack on iPhone.
            VStack(spacing: 3 * s) {
                ForEach(stack.kinds, id: \.self) { kind in
                    Capsule()
                        .fill(Color.white.opacity(kind == stack.current ? 0.9 : 0.3))
                        .frame(width: 3 * s, height: (kind == stack.current ? 8 : 3) * s)
                        .animation(Motion.snappy, value: stack.current)
                }
            }
            .padding(.trailing, 4 * s)
            .opacity(stack.kinds.count > 1 ? 1 : 0)
        }
    }
}
