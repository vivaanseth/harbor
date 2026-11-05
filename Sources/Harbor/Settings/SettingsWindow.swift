import AppKit
import SwiftUI
import EventKit
import ServiceManagement

enum SettingsTab: String, CaseIterable, Identifiable {
    case welcome, widgets, weather, calendar, previews, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .widgets: return "Widgets"
        case .weather: return "Weather"
        case .calendar: return "Calendar"
        case .previews: return "Windows"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: return "hand.wave.fill"
        case .widgets: return "square.grid.2x2.fill"
        case .weather: return "cloud.sun.fill"
        case .calendar: return "calendar"
        case .previews: return "rectangle.on.rectangle"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .welcome: return .orange
        case .widgets: return .blue
        case .weather: return .cyan
        case .calendar: return .red
        case .previews: return .purple
        case .permissions: return .green
        case .about: return .gray
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = SettingsWindowController()
    @Published var tab: SettingsTab = .widgets
    private var window: NSWindow?

    func show(tab: SettingsTab? = nil) {
        if let tab { self.tab = tab }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Harbor"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsRootView(controller: self))
            w.center()
            w.delegate = self
            window = w
        }
        Permissions.shared.startPolling()
        Permissions.shared.refreshNotifications()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Permissions.shared.stopPolling()
    }
}

struct SettingsRootView: View {
    @ObservedObject var controller: SettingsWindowController

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding(get: { controller.tab }, set: { if let t = $0 { controller.tab = t } })) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tab.tint.gradient))
                }
                .tag(tab)
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                switch controller.tab {
                case .welcome: ScrollView { WelcomePane().padding(28).frame(maxWidth: .infinity, alignment: .leading) }
                case .widgets: WidgetsPane()
                case .weather: WeatherPane()
                case .calendar: CalendarPane()
                case .previews: PreviewsPane()
                case .permissions: PermissionsPane()
                case .about: ScrollView { AboutPane().padding(28).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            .navigationTitle(controller.tab.title)
        }
        .frame(minWidth: 800, minHeight: 540)
    }
}

/// A rounded group for the free-form pages (Welcome, About).
private struct Card<Content: View>: View {
    var title: String
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 18)
    }
}

/// A System Settings group: header above, rounded box, footer below.
private struct Section<Content: View>: View {
    var title: String
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        SwiftUI.Section {
            content()
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Panes

private struct WelcomePane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("The dock you deserve.").font(.system(size: 26, weight: .bold))
                    Text("Music, calendar, weather, system stats and live window previews — right where your cursor already goes.")
                        .foregroundStyle(.secondary)
                }
            }
            Card(title: "How it works") {
                row("cursorarrow.motionlines", "Hover", "Hover an app in the Dock to preview every window before you switch.")
                row("eye", "Glance", "Widgets sit beside the Dock: music, meetings, weather, CPU and batteries.")
                row("hand.tap", "Act", "Click a preview, pause a track, open a drawer for more.")
                row("command", "Cmd+Tab", "The switcher shows the highlighted app's windows. Press ↑ to pick one.")
            }
            Card(title: "Nothing is asked up front",
                    footer: "Widgets work without any permission. Turn features on as you want them in Permissions.") {
                Button("Open Permissions") { SettingsWindowController.shared.tab = .permissions }
            }
        }
    }

    private func row(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 28).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct WidgetsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var spotify = SpotifyAPI.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section(title: "Widget bar", footer: "Widgets fill the space on either side of the Dock. When there isn't room for the full layout they switch to their compact glance style.") {
                Toggle("Show widgets beside the Dock", isOn: Binding(get: { !settings.widgetsHidden }, set: { settings.widgetsHidden = !$0 }))
                Picker("Open drawers", selection: $settings.drawerMode) {
                    ForEach(DrawerMode.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Glass tint") {
                    HStack {
                        Slider(value: $settings.glassTint, in: 0...1).frame(width: 200)
                    }
                }
                LabeledContent("Spacing") {
                    HStack {
                        Slider(value: $settings.widgetGap, in: 4...20, step: 1).frame(width: 200)
                        Text("\(Int(settings.widgetGap)) pt").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Height") {
                    HStack {
                        Slider(value: $settings.widgetHeight, in: 0.6...1, step: 0.05).frame(width: 200)
                        Text(settings.widgetHeight >= 0.999 ? "Match Dock" : "\(Int(settings.widgetHeight * 100))% of Dock")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Section(title: "Widgets", footer: "Choose what shows, which side of the Dock it sits on, its layout and its size. Drag to reorder: left widgets run from the screen edge toward the Dock, right widgets from the Dock outward.") {
                List {
                    ForEach($settings.widgets) { $config in
                        HStack(spacing: 12) {
                            Toggle("", isOn: $config.enabled).labelsHidden()
                            Image(systemName: config.kind.symbol).frame(width: 20).foregroundStyle(.tint)
                            Text(config.kind.title).frame(width: 118, alignment: .leading)
                            Spacer()
                            Picker("", selection: $config.side) {
                                Text("Left").tag(WidgetSide.left)
                                Text("Right").tag(WidgetSide.right)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 100)
                            Picker("", selection: $config.style) {
                                ForEach(WidgetStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 100)
                            Picker("", selection: $config.size) {
                                ForEach(WidgetConfig.sizes, id: \.1) { Text($0.0).tag($0.1) }
                            }
                            .labelsHidden()
                            .frame(width: 92)
                            .help("Width of the widget")
                        }
                        .opacity(config.enabled ? 1 : 0.55)
                        .padding(.vertical, 2)
                    }
                    .onMove { settings.widgets.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: 290)
                Button("Restore Defaults") { settings.widgets = AppSettings.defaultWidgets }
            }
            Section(title: "Smart Stack", footer: "Turn on Smart Stack above, then pick what it holds. Scroll over it to flip; it turns to a running timer, an upcoming event or playing music on its own unless you flipped it in the last minute.") {
                ForEach(WidgetKind.allCases.filter { $0 != .stack }) { kind in
                    Toggle(isOn: Binding(
                        get: { settings.stackKinds.contains(kind) },
                        set: { on in
                            if on { settings.stackKinds.append(kind) } else { settings.stackKinds.removeAll { $0 == kind } }
                        })) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
                Toggle("Turn to what matters automatically", isOn: $settings.stackSmartRotate)
            }
            Section(title: "Music") {
                Picker("Player", selection: $settings.musicSource) {
                    Text("Automatic").tag("auto")
                    Text("Apple Music").tag("music")
                    Text("Spotify").tag("spotify")
                }
            }
            Section(title: "Spotify", footer: "Any Spotify account works: what's playing, controls and synced lyrics through the Spotify app; what's next and the playlist it's playing from, read from Spotify's window (needs Accessibility); playlists you play or add as links; search opens in Spotify.") {
                LabeledContent("What's next") {
                    Text(PermissionCache.shared.accessibility ? "From the Spotify app" : "Needs Accessibility")
                        .foregroundStyle(.secondary)
                }
            }
            Section(title: "Spotify Premium (optional)", footer: spotify.connected
                    ? "Up Next shows the whole queue, Playlists your whole library, and search finds any song."
                    : "With Premium, Spotify's developer tools add the whole queue, your whole library and full search: create an app at the Spotify developer dashboard (any name), add the redirect URI below, tick Web API, then paste its Client ID here.") {
                if spotify.connected {
                    LabeledContent("Account") { Text(spotify.accountName ?? "Connected") }
                    HStack {
                        Spacer()
                        Button("Disconnect") { spotify.disconnect() }
                    }
                } else {
                    LabeledContent("Redirect URI") {
                        HStack(spacing: 8) {
                            Text(SpotifyAPI.redirectURI).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(SpotifyAPI.redirectURI, forType: .string)
                            }
                        }
                    }
                    TextField("Client ID", text: $spotify.clientID, prompt: Text("Paste from your Spotify app"))
                    HStack {
                        if let status = spotify.status { Text(status).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Open Developer Dashboard") { NSWorkspace.shared.open(SpotifyAPI.dashboardURL) }
                        Button("Connect") { spotify.connect() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(spotify.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            Section(title: "Device Batteries") {
                if settings.hiddenDevices.isEmpty {
                    Text("Right-click a device in the batteries drawer to pin or hide it.").foregroundStyle(.secondary)
                } else {
                    ForEach(settings.hiddenDevices, id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            Button("Show") { settings.hiddenDevices.removeAll { $0 == name } }
                        }
                    }
                }
            }
            Section(title: "General", footer: "With the menu bar icon hidden, open the app again from Finder to reach Settings.") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
            }
        }
        .formStyle(.grouped)
    }
}

private struct WeatherPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var location = LocationService.shared
    @State private var query = ""
    @State private var results: [GeocodeResult] = []
    @State private var searching = false

    var body: some View {
        Form {
            Section(title: "Units") {
                Picker("Temperature", selection: $settings.useFahrenheit) {
                    Text("°F").tag(true); Text("°C").tag(false)
                }
                .pickerStyle(.segmented)
                Picker("Wind", selection: $settings.useMph) {
                    Text("km/h").tag(false); Text("mph").tag(true)
                }
                .pickerStyle(.segmented)
            }
            Section(title: "Location", footer: "Weather data from Open-Meteo. Without a location, the city of your Mac's time zone is used.") {
                Toggle("Follow my current location", isOn: $settings.followCurrentLocation)
                if settings.followCurrentLocation && !location.isAuthorized {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("Location access is needed.")
                        Button("Allow") { Permissions.shared.request(.location) }
                    }
                }
                Divider()
                Text("Saved locations").font(.subheadline.weight(.semibold))
                ForEach(settings.savedLocations) { loc in
                    HStack {
                        Image(systemName: settings.selectedLocation?.id == loc.id && !settings.followCurrentLocation ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(.tint)
                            .onTapGesture { settings.selectedLocationID = loc.id; settings.followCurrentLocation = false }
                        VStack(alignment: .leading) {
                            Text(loc.name)
                            Text(loc.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            settings.savedLocations.removeAll { $0.id == loc.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add a city…", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(search)
                    Button("Search", action: search).disabled(query.isEmpty)
                    if searching { ProgressView().controlSize(.small) }
                }
                ForEach(results) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(r.name)
                            Text(r.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add") {
                            let loc = SavedLocation(name: r.name, detail: r.detail, latitude: r.latitude, longitude: r.longitude)
                            if !settings.savedLocations.contains(loc) { settings.savedLocations.append(loc) }
                            settings.selectedLocationID = loc.id
                            settings.followCurrentLocation = false
                            results = []
                            query = ""
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func search() {
        let q = query
        searching = true
        Task {
            results = (try? await Geocoder.search(q)) ?? []
            searching = false
        }
    }
}

private struct CalendarPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var service = CalendarService.shared

    var body: some View {
        Form {
            if !service.authorized {
                Section(title: "Apple Calendar") {
                    Text("Calendar events are read locally through EventKit — no Google account needed.")
                    Button("Allow Calendar Access") { service.requestAccess() }
                }
            } else {
                Section(title: "Calendars", footer: "Birthdays and Holidays are off until you choose them.") {
                    let selected = Set(settings.calendarIDs ?? service.defaultCalendarIDs())
                    ForEach(service.calendars, id: \.calendarIdentifier) { cal in
                        Toggle(isOn: Binding(
                            get: { selected.contains(cal.calendarIdentifier) },
                            set: { on in
                                var ids = Set(settings.calendarIDs ?? service.defaultCalendarIDs())
                                if on { ids.insert(cal.calendarIdentifier) } else { ids.remove(cal.calendarIdentifier) }
                                settings.calendarIDs = Array(ids)
                                service.reload()
                            })) {
                            HStack {
                                Circle().fill(Color(nsColor: cal.color)).frame(width: 9, height: 9)
                                Text(cal.title)
                                Text(cal.source?.title ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section(title: "Bar", footer: "In Automatic style, the calendar widget expands to show the next event when it's this close.") {
                Stepper("Show next event \(settings.calendarLeadMinutes) min before it starts",
                        value: $settings.calendarLeadMinutes, in: 5...240, step: 5)
                Toggle("Open the meeting link when the countdown ends", isOn: $settings.autoOpenMeetings)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PreviewsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        Form {
            if permissions.states[.accessibility] != .granted || permissions.states[.screenRecording] != .granted {
                Section(title: "Permissions needed") {
                    PermissionRow(kind: .accessibility)
                    PermissionRow(kind: .screenRecording)
                }
            }
            Section(title: "Dock previews", footer: "Hover an app in the Dock to see its windows — including minimized ones and windows on other Spaces.") {
                Toggle("Show window previews when hovering the Dock", isOn: $settings.dockPreviewsEnabled)
                LabeledContent("Preview size") {
                    HStack {
                        Slider(value: $settings.previewThumbHeight, in: 110...280, step: 10).frame(width: 220)
                        Text("\(Int(settings.previewThumbHeight)) pt").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Section(title: "Cmd+Tab switcher", footer: "Hold ⌘ and press Tab to cycle apps, ↑ to move into the windows row, ←/→ to pick, release ⌘ to switch. Q quits, H hides, W closes a window, Esc cancels.") {
                Toggle("Replace the Cmd+Tab switcher", isOn: $settings.switcherEnabled)
                Toggle("Show window thumbnails for the highlighted app", isOn: $settings.switcherShowsWindows)
            }
            Section(title: "Window tiling", footer: "⌃⌥← and ⌃⌥→ snap the front window to the left or right half; press again for a third, then a fourth. ⌃⌥↑ fills the screen, ⌃⌥↓ centres the window. Needs Accessibility.") {
                Toggle("Snap windows with ⌃⌥ and the arrow keys", isOn: $settings.tilingEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionsPane: View {
    var body: some View {
        Form {
            Section(title: "Every prompt has a job",
                    footer: "Permissions are only needed for the features that use them. Changes to Accessibility or Screen Recording may need the app to be relaunched.") {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(kind: kind)
                    if kind != PermissionKind.allCases.last { Divider() }
                }
            }
            Button("Relaunch Harbor") { Relauncher.relaunch() }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    var kind: PermissionKind
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        let state = permissions.states[kind] ?? .notDetermined
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .frame(width: 28, height: 28)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.gradient))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(kind.title).font(.body.weight(.semibold))
                    Text("Optional").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                Text(kind.purpose).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch state {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            case .denied:
                Button("Open Settings") { permissions.openSettings(kind) }
            case .notDetermined:
                Button("Allow") { permissions.request(kind) }
            }
        }
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading) {
                    Text("Harbor").font(.title.bold())
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") · macOS 14+ · Intel & Apple silicon")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Everything you need, moored to your Dock: Dock window previews, a Cmd+Tab window switcher, and glass widgets for music, calendar, weather, system stats and batteries.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Weather by Open-Meteo · Lyrics by LRCLIB · Everything else is read locally on your Mac.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

enum Relauncher {
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
