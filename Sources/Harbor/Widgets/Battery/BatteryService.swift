import AppKit
import IOKit
import IOKit.ps

struct DeviceBattery: Identifiable, Equatable {
    enum Kind: String { case mac, airpods, headphones, mouse, keyboard, trackpad, other }
    struct Component: Hashable { var label: String; var short: String; var level: Double }

    var name: String
    var kind: Kind
    var level: Double
    var charging: Bool
    var components: [Component] = []
    var id: String { name }

    var symbol: String {
        switch kind {
        case .mac: return DeviceBattery.isLaptop ? "laptopcomputer" : "desktopcomputer"
        case .airpods: return name.localizedCaseInsensitiveContains("max") ? "airpodsmax" : "airpodspro"
        case .headphones: return "headphones"
        case .mouse: return "magicmouse"
        case .keyboard: return "keyboard"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .other: return "battery.75percent"
        }
    }

    static let isLaptop: Bool = {
        let model = Sysctl.string("hw.model") ?? ""
        return model.hasPrefix("MacBook")
    }()

    static func kind(forName name: String, minorType: String? = nil) -> Kind {
        let n = name.lowercased()
        if n.contains("airpods") { return .airpods }
        if n.contains("mouse") { return .mouse }
        if n.contains("trackpad") { return .trackpad }
        if n.contains("keyboard") { return .keyboard }
        if let m = minorType?.lowercased() {
            if m.contains("headphone") || m.contains("headset") { return .headphones }
            if m.contains("mouse") { return .mouse }
            if m.contains("keyboard") { return .keyboard }
            if m.contains("trackpad") { return .trackpad }
        }
        if n.contains("beats") || n.contains("buds") || n.contains("headphone") { return .headphones }
        return .other
    }
}

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

/// Mac battery via IOPowerSources, Apple HID peripherals via IORegistry,
/// AirPods and other Bluetooth audio via system_profiler — all local.
@MainActor
final class BatteryService: ObservableObject {
    static let shared = BatteryService()

    @Published private(set) var devices: [DeviceBattery] = []
    private var timer: Timer?
    private var bluetoothTimer: Timer?
    private var bluetoothDevices: [DeviceBattery] = []
    private var runLoopSource: CFRunLoopSource?
    private let settings = AppSettings.shared

    private init() {}

    var visibleDevices: [DeviceBattery] {
        let hidden = Set(settings.hiddenDevices)
        let order = settings.deviceOrder
        let visible = devices.filter { !hidden.contains($0.name) }
        return visible.sorted { a, b in
            if a.name == settings.pinnedDevice { return true }
            if b.name == settings.pinnedDevice { return false }
            let ia = order.firstIndex(of: a.name) ?? Int.max
            let ib = order.firstIndex(of: b.name) ?? Int.max
            if ia != ib { return ia < ib }
            return rank(a.kind) < rank(b.kind)
        }
    }

    var primary: DeviceBattery? { visibleDevices.first }

    private func rank(_ k: DeviceBattery.Kind) -> Int {
        switch k {
        case .airpods, .headphones: return 0
        case .mouse, .trackpad, .keyboard: return 1
        case .other: return 2
        case .mac: return 3
        }
    }

    func setActive(_ active: Bool) {
        if active, timer == nil {
            refresh()
            refreshBluetooth()
            timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            bluetoothTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshBluetooth() }
            }
            installPowerNotification()
        } else if !active {
            timer?.invalidate(); timer = nil
            bluetoothTimer?.invalidate(); bluetoothTimer = nil
            if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode) }
            runLoopSource = nil
        }
    }

    private func installPowerNotification() {
        guard runLoopSource == nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<BatteryService>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in me.refresh() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            runLoopSource = src
        }
    }

    func refresh() {
        var list: [DeviceBattery] = []
        list.append(contentsOf: Self.powerSources())
        for d in Self.hidDevices() where !list.contains(where: { $0.name == d.name }) { list.append(d) }
        for d in bluetoothDevices where !list.contains(where: { $0.name == d.name }) { list.append(d) }
        if list != devices { devices = list }
    }

    func refreshBluetooth() {
        DispatchQueue.global(qos: .utility).async {
            let found = Self.systemProfilerBluetooth()
            Task { @MainActor in
                self.bluetoothDevices = found
                self.refresh()
            }
        }
    }

    // MARK: - Sources

    nonisolated static func powerSources() -> [DeviceBattery] {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        var result: [DeviceBattery] = []
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard (desc[kIOPSIsPresentKey] as? Bool) ?? true else { continue }
            let cur = Double(desc[kIOPSCurrentCapacityKey] as? Int ?? 0)
            let max = Double(desc[kIOPSMaxCapacityKey] as? Int ?? 100)
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let type = desc[kIOPSTypeKey] as? String ?? ""
            if type == kIOPSInternalBatteryType {
                result.append(DeviceBattery(name: macName, kind: .mac, level: cur / Swift.max(max, 1), charging: charging))
            } else if let name = desc[kIOPSNameKey] as? String {
                result.append(DeviceBattery(name: name, kind: DeviceBattery.kind(forName: name),
                                            level: cur / Swift.max(max, 1), charging: charging))
            }
        }
        return result
    }

    nonisolated static var macName: String {
        let model = Sysctl.string("hw.model") ?? ""
        if model.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if model.hasPrefix("MacBookAir") { return "MacBook Air" }
        if model.hasPrefix("MacBook") { return "MacBook" }
        return "Mac"
    }

    nonisolated static func hidDevices() -> [DeviceBattery] {
        var result: [DeviceBattery] = []
        for cls in ["AppleDeviceManagementHIDEventService", "AppleBluetoothHIDKeyboard", "BNBMouseDevice", "BNBTrackpadDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iterator) == KERN_SUCCESS else { continue }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = props?.takeRetainedValue() as? [String: Any],
                   let percent = dict["BatteryPercent"] as? Int,
                   let name = dict["Product"] as? String,
                   !result.contains(where: { $0.name == name }) {
                    let flags = dict["BatteryStatusFlags"] as? Int ?? 0
                    result.append(DeviceBattery(name: name, kind: DeviceBattery.kind(forName: name),
                                                level: Double(percent) / 100, charging: flags & 0x3 != 0 && flags != 0x0))
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
        return result
    }

    nonisolated static func systemProfilerBluetooth() -> [DeviceBattery] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        func pct(_ v: Any?) -> Double? {
            guard let s = v as? String else { return nil }
            return Double(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)).map { $0 / 100 }
        }

        var result: [DeviceBattery] = []
        for item in items {
            guard let connected = item["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let left = pct(info["device_batteryLevelLeft"])
                    let right = pct(info["device_batteryLevelRight"])
                    let caseLevel = pct(info["device_batteryLevelCase"])
                    let main = pct(info["device_batteryLevelMain"]) ?? pct(info["device_batteryLevel"])
                    var comps: [DeviceBattery.Component] = []
                    if let left { comps.append(.init(label: "L", short: "L", level: left)) }
                    if let right { comps.append(.init(label: "R", short: "R", level: right)) }
                    if let caseLevel { comps.append(.init(label: "Case", short: "C", level: caseLevel)) }
                    let level: Double? = main ?? [left, right].compactMap { $0 }.min() ?? caseLevel
                    guard let level else { continue }
                    let kind = DeviceBattery.kind(forName: name, minorType: info["device_minorType"] as? String)
                    result.append(DeviceBattery(name: name, kind: kind, level: level, charging: false, components: comps))
                }
            }
        }
        return result
    }
}
