import AppKit
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let settings = AppSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashSafety.install()
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared

        DockMonitor.shared.start()
        WidgetBarController.shared.start()
        DockPreviewController.shared.start()
        SwitcherController.shared.start()

        settings.$showMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] show in self?.updateStatusItem(show) }
            .store(in: &cancellables)

        askForAccessibilityIfNeeded()

        if !settings.hasLaunchedBefore {
            settings.hasLaunchedBefore = true
            SettingsWindowController.shared.show(tab: .welcome)
        }
    }

    /// Dock tracking, previews and the switcher all depend on Accessibility, and
    /// without it the app can only react to the Dock after it changes. Ask once.
    private func askForAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted(), !settings.askedForAccessibility else { return }
        settings.askedForAccessibility = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Permissions.shared.request(.accessibility)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SwitcherController.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    // MARK: - Menu bar

    private func updateStatusItem(_ show: Bool) {
        if !show {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Intel Docktor")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func openPermissions() { SettingsWindowController.shared.show(tab: .permissions) }
    @objc private func requestAccessibility() {
        // An entry left over from an earlier build stays listed (and switched
        // on) but no longer applies; switching it off and on doesn't fix that.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Turn On Accessibility"
        alert.informativeText = "If Intel Docktor is already listed and switched on, that entry belongs to an earlier build and no longer applies. Select it, remove it with the − button, then choose Turn On Accessibility… again and switch on the new entry."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Permissions.shared.request(.accessibility)
    }
    @objc private func toggleWidgets() { settings.widgetsHidden.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Intel Docktor", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if !PermissionCache.shared.accessibility {
            // Without it, widgets only make way after the Dock has grown into them.
            let item = NSMenuItem(title: "Turn On Accessibility…", action: #selector(requestAccessibility), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            item.toolTip = "Lets widgets move out of the Dock's way the moment a window is minimized."
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: settings.widgetsHidden ? "Show Widgets" : "Hide Widgets",
                     action: #selector(toggleWidgets), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Permissions…", action: #selector(openPermissions), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Intel Docktor", action: #selector(quit), keyEquivalent: "q").target = self
    }
}

/// Routes notification taps (calendar reminders) back into the app.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let link = response.notification.request.content.userInfo["link"] as? String,
           let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}

/// The Cmd+Tab switcher disables the system's symbolic hotkey while it runs.
/// Make sure it is always re-enabled, even if the process is killed.
enum CrashSafety {
    static func install() {
        atexit { SymbolicHotKeys.setNativeSwitcherEnabled(true) }
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP] {
            signal(sig) { s in
                SymbolicHotKeys.setNativeSwitcherEnabled(true)
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}
