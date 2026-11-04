import SwiftUI

private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

struct BatteryBarView: View {
    var compact: Bool
    var height: CGFloat
    @ObservedObject private var service = BatteryService.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let s = height / 60
        let devices = service.visibleDevices
        Group {
            if devices.isEmpty {
                Image(systemName: "battery.0percent")
                    .font(.system(size: 18 * s, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            } else if compact {
                compactBody(devices[0], s)
            } else {
                wideBody(devices, s)
            }
        }
        .foregroundStyle(Theme.primary)
    }

    private func compactBody(_ d: DeviceBattery, _ s: CGFloat) -> some View {
        VStack(spacing: 3 * s) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: d.symbol)
                    .font(.system(size: 17 * s, weight: .semibold))
                    .foregroundStyle(Theme.batteryColor(d.level))
                if d.charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8 * s, weight: .black))
                        .foregroundStyle(Theme.mint)
                        .offset(x: 6 * s, y: 2 * s)
                }
            }
            .frame(height: 20 * s)
            Text(percent(d.level)).font(Theme.font(12 * s, .bold)).rollingNumber(d.level)
        }
    }

    private func wideBody(_ devices: [DeviceBattery], _ s: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(devices.enumerated()), id: \.element.id) { i, d in
                if i > 0 {
                    Rectangle().fill(Theme.separator).frame(width: 1, height: 30 * s)
                        .padding(.horizontal, 10 * s)
                }
                if i == 0 && !d.components.isEmpty {
                    primarySegment(d, s)
                } else {
                    simpleSegment(d, s, showName: devices.count == 1)
                }
            }
        }
        .padding(.horizontal, 14 * s)
    }

    private func primarySegment(_ d: DeviceBattery, _ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3 * s) {
            HStack(spacing: 5 * s) {
                Image(systemName: d.symbol).font(.system(size: 13 * s, weight: .semibold)).foregroundStyle(Theme.secondary)
                Text(d.name).font(Theme.font(15 * s, .bold)).foregroundStyle(Theme.secondary).lineLimit(1)
                Text(percent(d.level)).font(Theme.font(15 * s, .bold)).rollingNumber(d.level)
            }
            HStack(spacing: 7 * s) {
                ForEach(d.components, id: \.self) { c in
                    HStack(spacing: 1) {
                        Text(c.short).foregroundStyle(Theme.secondary)
                        Text(percent(c.level)).foregroundStyle(Theme.batteryColor(c.level))
                    }
                }
            }
            .font(Theme.font(10.5 * s, .bold))
        }
        .fixedSize()
    }

    private func simpleSegment(_ d: DeviceBattery, _ s: CGFloat, showName: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5 * s) {
            HStack(spacing: 6 * s) {
                ZStack {
                    Image(systemName: d.symbol).font(.system(size: 14 * s, weight: .semibold)).foregroundStyle(Theme.secondary)
                    if d.charging {
                        Image(systemName: "bolt.fill").font(.system(size: 9 * s, weight: .black)).foregroundStyle(Theme.mint)
                    }
                }
                if showName {
                    Text(d.name).font(Theme.font(14 * s, .bold)).foregroundStyle(Theme.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                }
                Text(percent(d.level)).font(Theme.font(15 * s, .bold)).rollingNumber(d.level)
            }
            ProgressTrack(value: d.level, color: Theme.batteryColor(d.level), height: 3.5 * s)
        }
        .frame(minWidth: 70 * s)
    }
}

struct BatteryDrawer: View {
    @ObservedObject private var service = BatteryService.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let devices = service.visibleDevices
        if devices.isEmpty {
            EmptyStateView(symbol: "battery.100percent.bolt", title: "No batteries found",
                           message: "Connect AirPods, a Magic Mouse, Keyboard or Trackpad.")
        } else {
            VStack(spacing: 6) {
                ForEach(devices) { d in
                    row(d)
                        .contextMenu {
                            Button(settings.pinnedDevice == d.name ? "Unpin" : "Pin to Bar") {
                                settings.pinnedDevice = settings.pinnedDevice == d.name ? nil : d.name
                            }
                            Button("Hide \(d.name)") { settings.hiddenDevices.append(d.name) }
                        }
                }
            }
            .padding(.top, 2)
        }
    }

    private func row(_ d: DeviceBattery) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: d.symbol)
                .font(.system(size: 24, weight: .regular))
                .frame(width: 40, height: 34)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(d.name).font(Theme.font(15, .bold))
                    if settings.pinnedDevice == d.name {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                    }
                    Spacer()
                    if d.charging {
                        Image(systemName: "bolt.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.mint)
                    }
                    Text(percent(d.level)).font(Theme.font(18, .bold))
                }
                ProgressTrack(value: d.level, color: Theme.batteryColor(d.level), height: 5)
                if !d.components.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(d.components, id: \.self) { c in
                            Text("\(c.label) \(percent(c.level))")
                        }
                    }
                    .font(Theme.font(13, .semibold))
                    .foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
