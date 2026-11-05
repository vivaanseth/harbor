import SwiftUI

private func deg(_ v: Double) -> String { "\(Int(v.rounded()))" }

private func hourLabel(_ d: Date, _ tz: TimeZone) -> String {
    let f = DateFormatter()
    f.timeZone = tz
    f.dateFormat = "h a"
    return f.string(from: d).lowercased()
}

private func timeLabel(_ d: Date, _ tz: TimeZone) -> String {
    let f = DateFormatter()
    f.timeZone = tz
    f.dateFormat = "h:mm a"
    return f.string(from: d)
}

struct WeatherBarView: View {
    var compact: Bool
    var height: CGFloat
    var width: CGFloat = 400
    @ObservedObject private var weather = WeatherService.shared

    var body: some View {
        let s = height / 60
        Group {
            if let data = weather.data {
                if compact { compactBody(data, s) } else { wideBody(data, s) }
            } else {
                Image(systemName: weather.loading ? "cloud.sun" : "location.slash")
                    .font(.system(size: 18 * s, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .foregroundStyle(Theme.primary)
    }

    private func compactBody(_ data: WeatherData, _ s: CGFloat) -> some View {
        // Like Apple's Weather widget: a full-color symbol over the temperature.
        VStack(spacing: 1 * s) {
            Image(systemName: data.current.condition.symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 19 * s, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 22 * s)
            Text("\(deg(data.current.temperature))°").font(Theme.font(16 * s, .medium))
                .rollingNumber(data.current.temperature)
        }
    }

    private func wideBody(_ data: WeatherData, _ s: CGFloat) -> some View {
        let hours = Array(data.hours.prefix(13))
        let temps = hours.map(\.temperature)
        let peak = temps.indices.max(by: { temps[$0] < temps[$1] }) ?? 0
        // Room left for the forecast curve once icon and text are laid out.
        let chartWidth = width - 26 * s - 46 * s - 120 * s - 4
        var markers: [SparkChart.Marker] = [.init(index: 0, label: "\(deg(temps.first ?? 0))°")]
        if peak > 1 && peak < temps.count - 1 && chartWidth >= 100 * s {
            markers.append(.init(index: peak, label: "\(deg(temps[peak]))°"))
        }
        let lo = temps.min() ?? 0, hi = temps.max() ?? 1
        return HStack(spacing: 10 * s) {
            Image(systemName: data.current.condition.symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 24 * s, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36 * s, height: 36 * s)
            VStack(alignment: .leading, spacing: 1 * s) {
                HStack(alignment: .firstTextBaseline, spacing: 5 * s) {
                    Text("\(deg(data.current.temperature))°").font(Theme.font(21 * s, .medium))
                        .rollingNumber(data.current.temperature)
                    Text(data.current.condition.description).font(Theme.font(12 * s, .medium))
                        .foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Text(weather.placeName).font(Theme.font(11 * s, .medium)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .fixedSize()
            Spacer(minLength: 4)
            if temps.count > 2 && chartWidth >= 56 * s {
                VStack(spacing: 0) {
                    SparkChart(values: temps, lo: lo - (hi - lo) * 0.3 - 1, hi: hi + (hi - lo) * 0.15 + 1,
                               colors: TemperatureColors.gradient(lo: lo, hi: hi), lineWidth: 1.8 * s,
                               fillOpacity: 0.22, markers: markers, markerFont: Theme.font(8.5 * s, .bold),
                               verticalInset: 6 * s)
                    HStack {
                        Text("Now").fixedSize(); Spacer(minLength: 2); Text(hourLabel(hours.last!.time, data.timeZone)).fixedSize()
                    }
                    .font(Theme.font(8 * s, .semibold))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                }
                .frame(width: min(170 * s, chartWidth))
                .padding(.vertical, 8 * s)
            }
        }
        .padding(.leading, 12 * s)
        .padding(.trailing, 14 * s)
    }
}

struct WeatherDrawer: View {
    @ObservedObject private var weather = WeatherService.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var page = "now"

    private let tabs = [
        DrawerTab(id: "now", symbol: "thermometer.medium", label: "Now"),
        DrawerTab(id: "hourly", symbol: "clock", label: "Hourly"),
        DrawerTab(id: "daily", symbol: "calendar", label: "Daily"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DrawerTabBar(tabs: tabs, selection: $page) {
                locationMenu
                if let data = weather.data {
                    Image(systemName: data.current.condition.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 30)
                }
            }
            if let data = weather.data {
                switch page {
                case "hourly": HourlyPage(data: data)
                case "daily": DailyPage(data: data)
                default: NowPage(data: data)
                }
            } else {
                EmptyStateView(symbol: "cloud.sun", title: weather.loading ? "Loading weather…" : (weather.errorMessage ?? "No weather yet"),
                               buttonTitle: "Choose Location") {
                    SettingsWindowController.shared.show(tab: .weather)
                }
            }
        }
    }

    private var locationMenu: some View {
        Menu {
            Button {
                settings.followCurrentLocation = true
                if !LocationService.shared.isAuthorized { LocationService.shared.requestAuthorization() }
            } label: {
                Label("Current Location", systemImage: settings.followCurrentLocation ? "checkmark" : "location")
            }
            if !settings.savedLocations.isEmpty { Divider() }
            ForEach(settings.savedLocations) { loc in
                Button {
                    settings.followCurrentLocation = false
                    settings.selectedLocationID = loc.id
                } label: {
                    if !settings.followCurrentLocation && settings.selectedLocation?.id == loc.id {
                        Label(loc.name, systemImage: "checkmark")
                    } else {
                        Text(loc.name)
                    }
                }
            }
            Divider()
            Button("Edit Locations…") { SettingsWindowController.shared.show(tab: .weather) }
        } label: {
            Image(systemName: settings.followCurrentLocation ? "location" : "location.slash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 30)
        .help(weather.placeName)
    }
}

private struct NowPage: View {
    var data: WeatherData
    @ObservedObject private var weather = WeatherService.shared

    var body: some View {
        let c = data.current
        let today = data.days.first
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SymbolTile(symbol: c.condition.symbol, size: 46, symbolSize: 21)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.condition.description).font(Theme.font(18, .bold))
                    Text("Feels \(deg(c.feelsLike))\(weather.unitSymbol)").font(Theme.font(14, .medium)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(deg(c.temperature)).font(Theme.font(30, .bold))
                    Text(weather.unitSymbol).font(Theme.font(12, .bold)).foregroundStyle(Theme.secondary)
                }
            }
            if let today {
                HStack(spacing: 12) {
                    Text("Today").font(Theme.font(14, .semibold)).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 8)
                    Text("L \(deg(today.low))").font(Theme.font(14, .semibold)).foregroundStyle(Theme.secondary)
                    RangeBar(lo: today.low, hi: today.high, totalLo: today.low, totalHi: today.high, height: 4)
                        .frame(width: 130)
                    Text("H \(deg(today.high))").font(Theme.font(14, .bold))
                }
            }
            let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
            LazyVGrid(columns: cols, spacing: 8) {
                tile("humidity", "\(deg(c.humidity))%", "Humidity")
                tile("wind", "\(deg(c.windSpeed)) \(weather.windUnit)", "Wind")
                tile("safari", compass(c.windDirection), "Direction")
                tile("sun.max", "\(deg(c.uv))", "UV")
                tile("gauge.with.dots.needle.50percent", "\(deg(c.pressure))", "Pressure")
                if let today {
                    let sunUp = Date() < today.sunrise || Date() > today.sunset
                    tile(sunUp ? "sunrise" : "sunset", timeLabel(sunUp ? nextSunrise : today.sunset, data.timeZone),
                         sunUp ? "Sunrise" : "Sunset")
                }
            }
        }
    }

    private var nextSunrise: Date {
        let now = Date()
        return data.days.first(where: { $0.sunrise > now })?.sunrise ?? data.days.first?.sunrise ?? now
    }

    private func compass(_ deg: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return dirs[Int((deg + 22.5).truncatingRemainder(dividingBy: 360) / 45) % 8]
    }

    private func tile(_ symbol: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(Theme.font(14, .bold)).lineLimit(1).minimumScaleFactor(0.7)
                Text(label).font(Theme.font(11.5, .medium)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.tile))
    }
}

private struct HourlyPage: View {
    var data: WeatherData

    var body: some View {
        let hours = Array(data.hours.prefix(12))
        let temps = hours.map(\.temperature)
        let lo = temps.min() ?? 0, hi = temps.max() ?? 1
        VStack(spacing: 6) {
            SparkChart(values: temps, lo: lo - (hi - lo) * 0.25 - 1, hi: hi + (hi - lo) * 0.1 + 1,
                       colors: TemperatureColors.gradient(lo: lo, hi: hi), lineWidth: 2, fillOpacity: 0.2)
                .frame(height: 54)
                .padding(.horizontal, 12)
            HStack(spacing: 0) {
                ForEach(Array(hours.enumerated()), id: \.element.id) { i, h in
                    if i % 2 == 0 {
                        VStack(spacing: 6) {
                            Text(i == 0 ? "Now" : hourLabel(h.time, data.timeZone))
                                .font(Theme.font(11, .semibold)).foregroundStyle(Theme.secondary)
                            Image(systemName: h.condition.symbol)
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: 17, weight: .semibold))
                                .frame(height: 22)
                            Text("\(deg(h.temperature))°").font(Theme.font(15, .bold))
                            HStack(spacing: 2) {
                                Image(systemName: "drop.fill").font(.system(size: 8))
                                Text("\(deg(h.precipitation))%")
                            }
                            .font(Theme.font(10, .bold))
                            .foregroundStyle(h.precipitation >= 30 ? Theme.cyan : Theme.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(i == 0 ? Theme.tile : .clear))
                    }
                }
            }
        }
    }
}

private struct DailyPage: View {
    var data: WeatherData

    var body: some View {
        let lo = data.days.map(\.low).min() ?? 0
        let hi = data.days.map(\.high).max() ?? 1
        VStack(spacing: 3) {
            ForEach(Array(data.days.enumerated()), id: \.element.id) { i, d in
                HStack(spacing: 10) {
                    Text(dayName(d.date, index: i)).font(Theme.font(13, .semibold)).frame(width: 44, alignment: .leading)
                    Image(systemName: d.condition.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 22)
                    Text(d.precipitation >= 20 ? "\(deg(d.precipitation))%" : "")
                        .font(Theme.font(10.5, .bold)).foregroundStyle(Theme.cyan)
                        .frame(width: 30, alignment: .leading)
                    Text("\(deg(d.low))°").font(Theme.font(13, .semibold)).foregroundStyle(Theme.secondary)
                        .frame(width: 32, alignment: .trailing)
                    RangeBar(lo: d.low, hi: d.high, totalLo: lo, totalHi: hi,
                             current: i == 0 ? data.current.temperature : nil, height: 4)
                    Text("\(deg(d.high))°").font(Theme.font(13, .bold)).frame(width: 32, alignment: .trailing)
                }
                .frame(height: 29)
            }
        }
    }

    private func dayName(_ d: Date, index: Int) -> String {
        if index == 0 { return "Today" }
        let f = DateFormatter()
        f.timeZone = data.timeZone
        f.dateFormat = "EEE"
        return f.string(from: d)
    }
}
