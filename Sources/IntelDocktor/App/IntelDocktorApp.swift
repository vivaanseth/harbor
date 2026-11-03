import AppKit

@main
enum IntelDocktorMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == HotKeyWatchdog.flag,
           let pid = pid_t(CommandLine.arguments[2]) {
            HotKeyWatchdog.run(watching: pid)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

/// Runs as a separate process: waits for the app to exit by any means
/// (including force quit) and turns the system Cmd+Tab back on.
enum HotKeyWatchdog {
    static let flag = "--hotkey-watchdog"

    static func run(watching pid: pid_t) -> Never {
        let kq = kqueue()
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: NOTE_EXIT, data: 0, udata: nil)
        // If the app is already gone, registration fails and we restore right away.
        if kevent(kq, &change, 1, nil, 0, nil) == 0 {
            var event = kevent()
            _ = kevent(kq, nil, 0, &event, 1, nil)
        }
        SymbolicHotKeys.setNativeSwitcherEnabled(true)
        exit(0)
    }
}
