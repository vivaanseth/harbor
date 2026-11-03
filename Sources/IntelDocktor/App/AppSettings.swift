import Foundation
import Combine

enum WidgetKind: String, CaseIterable, Codable, Identifiable {
    case battery, stats, weather, music, calendar, timer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .battery: return "Device Batteries"
        case .stats: return "System Stats"
        case .weather: return "Weather"
        case .music: return "Music"
        case .calendar: return "Calendar"
        case .timer: return "Focus Timer"
        }
    }

    var symbol: String {
        switch self {
        case .battery: return "airpodspro"
        case .stats: return "cpu"
        case .weather: return "cloud.sun"
        case .music: return "music.note"
        case .calendar: return "calendar"
        case .timer: return "timer"
        }
    }
}

enum WidgetSide: String, Codable, CaseIterable { case left, right }

/// How widget drawers open.
enum DrawerMode: String, CaseIterable, Identifiable {
    case hover, click, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hover: return "Hover or click"
        case .click: return "Click only"
        case .never: return "Never"
        }
    }
}

enum WidgetStyle: String, Codable, CaseIterable {
    case compact, wide, auto
    var title: String {
        switch self {
        case .compact: return "Glance"
        case .wide: return "Full"
        case .auto: return "Automatic"
        }
    }
}

struct WidgetConfig: Codable, Identifiable, Equatable {
    var kind: WidgetKind
    var enabled: Bool
    var side: WidgetSide
    var style: WidgetStyle
    /// Width multiplier: 0.8 small … 1.25 large.
    var size: Double = 1
    var id: WidgetKind { kind }

    init(kind: WidgetKind, enabled: Bool, side: WidgetSide, style: WidgetStyle, size: Double = 1) {
        self.kind = kind
        self.enabled = enabled
        self.side = side
        self.style = style
        self.size = size
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(WidgetKind.self, forKey: .kind)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        side = try c.decode(WidgetSide.self, forKey: .side)
        style = try c.decode(WidgetStyle.self, forKey: .style)
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1
    }
}

struct SavedLocation: Codable, Identifiable, Equatable, Hashable {
    var name: String
    var detail: String
    var latitude: Double
    var longitude: Double
    var id: String { "\(name)|\(latitude)|\(longitude)" }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    // General
    @Published var hasLaunchedBefore: Bool { didSet { save("hasLaunchedBefore", hasLaunchedBefore) } }
    @Published var showMenuBarIcon: Bool { didSet { save("showMenuBarIcon", showMenuBarIcon) } }
    @Published var widgetsHidden: Bool { didSet { save("widgetsHidden", widgetsHidden) } }
    @Published var drawerMode: DrawerMode { didSet { save("drawerMode", drawerMode.rawValue) } }
    @Published var glassTint: Double { didSet { save("glassTint", glassTint) } }
    @Published var widgetGap: Double { didSet { save("widgetGap", widgetGap) } }
    /// Widget height as a fraction of the Dock's.
    @Published var widgetHeight: Double { didSet { save("widgetHeight", widgetHeight) } }
    @Published var askedForAccessibility: Bool { didSet { save("askedForAccessibility", askedForAccessibility) } }

    // Widgets
    @Published var widgets: [WidgetConfig] { didSet { saveCodable("widgets", widgets) } }

    // Previews & switcher
    @Published var dockPreviewsEnabled: Bool { didSet { save("dockPreviewsEnabled", dockPreviewsEnabled) } }
    @Published var previewThumbHeight: Double { didSet { save("previewThumbHeight", previewThumbHeight) } }
    @Published var switcherEnabled: Bool { didSet { save("switcherEnabled", switcherEnabled) } }
    @Published var switcherShowsWindows: Bool { didSet { save("switcherShowsWindows", switcherShowsWindows) } }
    @Published var tilingEnabled: Bool { didSet { save("tilingEnabled", tilingEnabled) } }

    // Weather
    @Published var useFahrenheit: Bool { didSet { save("useFahrenheit", useFahrenheit) } }
    @Published var useMph: Bool { didSet { save("useMph", useMph) } }
    @Published var followCurrentLocation: Bool { didSet { save("followCurrentLocation", followCurrentLocation) } }
    @Published var savedLocations: [SavedLocation] { didSet { saveCodable("savedLocations", savedLocations) } }
    @Published var selectedLocationID: String? { didSet { save("selectedLocationID", selectedLocationID) } }

    // Calendar
    @Published var calendarIDs: [String]? { didSet { saveCodable("calendarIDs", calendarIDs) } }
    @Published var calendarLeadMinutes: Int { didSet { save("calendarLeadMinutes", calendarLeadMinutes) } }
    @Published var autoOpenMeetings: Bool { didSet { save("autoOpenMeetings", autoOpenMeetings) } }

    // Music
    @Published var musicSource: String { didSet { save("musicSource", musicSource) } } // auto | music | spotify
    @Published var musicDrawerPage: String { didSet { save("musicDrawerPage", musicDrawerPage) } }

    // Stats
    @Published var statsDrawerPage: String { didSet { save("statsDrawerPage", statsDrawerPage) } }

    // Batteries
    @Published var hiddenDevices: [String] { didSet { saveCodable("hiddenDevices", hiddenDevices) } }
    @Published var pinnedDevice: String? { didSet { save("pinnedDevice", pinnedDevice) } }
    @Published var deviceOrder: [String] { didSet { saveCodable("deviceOrder", deviceOrder) } }

    static let defaultWidgets: [WidgetConfig] = [
        WidgetConfig(kind: .battery, enabled: true, side: .left, style: .compact),
        WidgetConfig(kind: .stats, enabled: true, side: .left, style: .wide),
        WidgetConfig(kind: .weather, enabled: true, side: .left, style: .compact),
        WidgetConfig(kind: .music, enabled: true, side: .right, style: .wide),
        WidgetConfig(kind: .calendar, enabled: true, side: .right, style: .auto),
        WidgetConfig(kind: .timer, enabled: false, side: .right, style: .compact),
    ]

    private init() {
        let d = UserDefaults.standard
        let usesMetric = Locale.current.measurementSystem != .us
        hasLaunchedBefore = d.bool(forKey: "hasLaunchedBefore")
        showMenuBarIcon = d.object(forKey: "showMenuBarIcon") as? Bool ?? true
        widgetsHidden = d.bool(forKey: "widgetsHidden")
        drawerMode = DrawerMode(rawValue: d.string(forKey: "drawerMode") ?? "") ?? (d.bool(forKey: "hoverOpensDrawer") ? .hover : .click)
        glassTint = d.object(forKey: "glassTint") as? Double ?? 0.2
        widgetGap = d.object(forKey: "widgetGap") as? Double ?? 8
        widgetHeight = d.object(forKey: "widgetHeight") as? Double ?? 1
        askedForAccessibility = d.bool(forKey: "askedForAccessibility")
        widgets = Self.load("widgets", d) ?? Self.defaultWidgets
        dockPreviewsEnabled = d.object(forKey: "dockPreviewsEnabled") as? Bool ?? true
        previewThumbHeight = d.object(forKey: "previewThumbHeight") as? Double ?? 170
        switcherEnabled = d.object(forKey: "switcherEnabled") as? Bool ?? true
        switcherShowsWindows = d.object(forKey: "switcherShowsWindows") as? Bool ?? true
        tilingEnabled = d.bool(forKey: "tilingEnabled")
        useFahrenheit = d.object(forKey: "useFahrenheit") as? Bool ?? !usesMetric
        useMph = d.object(forKey: "useMph") as? Bool ?? false
        followCurrentLocation = d.object(forKey: "followCurrentLocation") as? Bool ?? true
        savedLocations = Self.load("savedLocations", d) ?? []
        selectedLocationID = d.string(forKey: "selectedLocationID")
        calendarIDs = Self.load("calendarIDs", d)
        calendarLeadMinutes = d.object(forKey: "calendarLeadMinutes") as? Int ?? 60
        autoOpenMeetings = d.bool(forKey: "autoOpenMeetings")
        musicSource = d.string(forKey: "musicSource") ?? "auto"
        musicDrawerPage = d.string(forKey: "musicDrawerPage") ?? "upNext"
        statsDrawerPage = d.string(forKey: "statsDrawerPage") ?? "overview"
        hiddenDevices = Self.load("hiddenDevices", d) ?? []
        pinnedDevice = d.string(forKey: "pinnedDevice")
        deviceOrder = Self.load("deviceOrder", d) ?? []

        // Make sure newly added widget kinds appear for existing installs.
        for kind in WidgetKind.allCases where !widgets.contains(where: { $0.kind == kind }) {
            if let def = Self.defaultWidgets.first(where: { $0.kind == kind }) { widgets.append(def) }
        }
    }

    func config(for kind: WidgetKind) -> WidgetConfig {
        widgets.first(where: { $0.kind == kind }) ?? WidgetConfig(kind: kind, enabled: false, side: .left, style: .compact)
    }

    func update(_ kind: WidgetKind, _ change: (inout WidgetConfig) -> Void) {
        guard let i = widgets.firstIndex(where: { $0.kind == kind }) else { return }
        var c = widgets[i]
        change(&c)
        widgets[i] = c
    }

    var selectedLocation: SavedLocation? {
        savedLocations.first(where: { $0.id == selectedLocationID }) ?? savedLocations.first
    }

    // MARK: persistence helpers

    private func save(_ key: String, _ value: Any?) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private func saveCodable<T: Encodable>(_ key: String, _ value: T?) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ key: String, _ d: UserDefaults) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
