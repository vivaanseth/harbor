import SwiftUI

private let cpuColors = [Theme.mint, Theme.teal, Theme.cyan]
private let ramColors = [Theme.warmOrange, Color(hex: 0xFF5A6E), Theme.memoryPink]
private let ssdColors = [Theme.memoryPink, Theme.storagePurple]
private let gpuColors = [Theme.mint, Theme.cyan]
private let readColors = [Theme.memoryPink, Theme.storagePurple, Theme.cyan]
private let writeColors = [Theme.warmOrange, Theme.memoryPink]
private let netInColors = [Theme.cyan, Theme.netBlue]
private let netOutColors = [Theme.sunYellow, Theme.mint]

private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))" }

struct StatsBarView: View {
    var compact: Bool
    var height: CGFloat
    var width: CGFloat = 400
    @ObservedObject private var stats = StatsService.shared

    var body: some View {
        let s = height / 60
        if compact {
            compactBody(s)
        } else {
            wideBody(s)
        }
    }

    private func compactBody(_ s: CGFloat) -> some View {
        // A calm hill rather than every jitter: average 30 s into 6 buckets.
        let recent = Array(stats.cpuHistory.suffix(30))
        let bucket = max(1, recent.count / 6)
        let smooth = stride(from: 0, to: recent.count, by: bucket).map { i in
            let slice = recent[i..<min(i + bucket, recent.count)]
            return slice.reduce(0, +) / Double(slice.count)
        }
        return ZStack {
            SparkChart(values: smooth.count > 1 ? smooth : [stats.cpu, stats.cpu], lo: 0,
                       hi: max(0.3, (smooth.max() ?? 0) * 1.45),
                       colors: cpuColors, lineWidth: 2.2 * s, fillOpacity: 0.32)
                .padding(.top, 10 * s)
                .clipShape(RoundedRectangle(cornerRadius: Theme.barRadius(height), style: .continuous))
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(pct(stats.cpu)).font(Theme.font(23 * s, .bold))
                Text("%").font(Theme.font(12 * s, .bold)).foregroundStyle(Theme.secondary)
            }
            .shadow(color: .black.opacity(0.35), radius: 3)
        }
        .foregroundStyle(Theme.primary)
    }

    private func wideBody(_ s: CGFloat) -> some View {
        let recent = Array(stats.cpuHistory.suffix(30))
        let values = recent.count > 1 ? recent : [stats.cpu, stats.cpu]
        let peakIndex = values.indices.max(by: { values[$0] < values[$1] }) ?? 0
        // Fit to the width we actually got: drop the badge, then the peak label,
        // then the chart, rather than squeezing the chart until labels wrap.
        let fixed = 26 * s + 84 * s + 14 * s
        let showBadge = width - fixed - 46 * s >= 96 * s
        let chartWidth = width - fixed - (showBadge ? 46 * s : 0)
        var markers: [SparkChart.Marker] = [.init(index: values.count - 1, label: "\(pct(values.last ?? 0))%")]
        if peakIndex < values.count - 4 && chartWidth >= 110 * s {
            markers.insert(.init(index: peakIndex, label: "\(pct(values[peakIndex]))%"), at: 0)
        }
        return HStack(spacing: 10 * s) {
            if showBadge {
            VStack(spacing: 1 * s) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 13 * s, weight: .semibold))
                    .foregroundStyle(Theme.mint)
                Text("CPU").font(Theme.font(6.5 * s, .heavy)).foregroundStyle(Theme.secondary)
            }
            .frame(width: 36 * s, height: 36 * s)
            .background(RoundedRectangle(cornerRadius: 10 * s, style: .continuous).fill(Theme.tile))
            }

            VStack(alignment: .leading, spacing: 1 * s) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(pct(stats.cpu)).font(Theme.font(22 * s, .bold))
                    Text("%").font(Theme.font(11 * s, .bold)).foregroundStyle(Theme.secondary)
                }
                Text("RAM \(pct(stats.memFraction))% · SSD \(pct(stats.diskFraction))%")
                    .font(Theme.font(8.5 * s, .semibold))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            if chartWidth >= 56 * s {
                VStack(spacing: 0) {
                    SparkChart(values: values, lo: 0, hi: max(0.2, (values.max() ?? 0) * 1.2),
                               colors: cpuColors, lineWidth: 1.8 * s, fillOpacity: 0.22,
                               markers: markers, markerFont: Theme.font(8.5 * s, .bold), verticalInset: 4 * s)
                    HStack {
                        Text("30s").fixedSize(); Spacer(minLength: 2); Text("Now").fixedSize()
                    }
                    .font(Theme.font(7.5 * s, .bold))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                }
                .frame(width: min(190 * s, chartWidth))
                .padding(.vertical, 8 * s)
            }
        }
        .padding(.leading, 12 * s)
        .padding(.trailing, 14 * s)
        .foregroundStyle(Theme.primary)
    }
}

// MARK: - Drawer

struct StatsDrawer: View {
    @ObservedObject private var stats = StatsService.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var drawer = DrawerController.shared
    @State private var glance = false

    private let tabs = [
        DrawerTab(id: "overview", symbol: "info.circle", label: "Overview"),
        DrawerTab(id: "cpu", symbol: "cpu", label: "CPU"),
        DrawerTab(id: "memory", symbol: "memorychip", label: "Memory"),
        DrawerTab(id: "storage", symbol: "internaldrive", label: "Storage"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DrawerTabBar(tabs: tabs, selection: $settings.statsDrawerPage) {
                if drawer.searchVisible {
                    IconButton(symbol: "xmark", size: 15) { drawer.searchVisible = false; drawer.searchText = "" }
                } else {
                    IconButton(symbol: "magnifyingglass", size: 14) { drawer.searchVisible = true }
                    IconButton(symbol: glance ? "list.bullet" : "waveform.path.ecg", size: 14) {
                        withAnimation(.easeInOut(duration: 0.2)) { glance.toggle() }
                    }
                }
            }
            Group {
                if drawer.searchVisible {
                    ProcessList(sortByMemory: settings.statsDrawerPage == "memory", filter: drawer.searchText, limit: 40)
                } else if glance {
                    StatsGlanceGrid()
                } else {
                    switch settings.statsDrawerPage {
                    case "cpu": CPUPage()
                    case "memory": MemoryPage()
                    case "storage": StoragePage()
                    default: OverviewPage()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { stats.sampleNow() }
    }
}

private struct OverviewPage: View {
    @ObservedObject private var stats = StatsService.shared

    var body: some View {
        VStack(spacing: 12) {
            row(label: "CPU", value: pct(stats.cpu), unit: "%", sub: "\(stats.cores) cores",
                values: stats.cpuHistory, colors: cpuColors, format: { "\(pct($0))%" })
            row(label: "RAM", value: ByteFormat.gb(Double(stats.memUsed)), unit: "GB",
                sub: "of \(ByteFormat.gb(Double(stats.memTotal))) GB",
                values: stats.memHistory, colors: ramColors, format: { "\(ByteFormat.gb($0))GB" })
            row(label: "SSD", value: ByteFormat.gb(Double(stats.diskUsed)), unit: "GB",
                sub: "\(ByteFormat.gb(Double(stats.diskTotal - stats.diskUsed))) GB free",
                values: stats.diskHistory, colors: ssdColors, format: { "\(ByteFormat.gb($0))GB" })
        }
    }

    private func row(label: String, value: String, unit: String, sub: String,
                     values: [Double], colors: [Color], format: (Double) -> String) -> some View {
        let v = values.count > 1 ? values : [values.first ?? 0, values.first ?? 0]
        let peak = v.indices.max(by: { v[$0] < v[$1] }) ?? 0
        var markers: [SparkChart.Marker] = [.init(index: v.count - 1, label: format(v.last ?? 0))]
        if peak < v.count - 8 { markers.insert(.init(index: peak, label: format(v[peak])), at: 0) }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(Theme.font(11, .bold)).foregroundStyle(Theme.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value).font(Theme.font(19, .bold))
                    Text(unit).font(Theme.font(10, .bold)).foregroundStyle(Theme.secondary)
                }
                Text(sub).font(Theme.font(10, .semibold)).foregroundStyle(Theme.secondary)
            }
            .frame(width: 92, alignment: .leading)
            SparkChart(values: v, colors: colors, lineWidth: 1.8, fillOpacity: 0.18,
                       markers: markers, markerFont: Theme.font(9, .bold), verticalInset: 6)
                .padding(.bottom, 12)
        }
        .frame(height: 68)
    }
}

private struct StatsGlanceGrid: View {
    @ObservedObject private var stats = StatsService.shared

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        LazyVGrid(columns: cols, spacing: 8) {
            tile("cpu", "CPU", pct(stats.cpu), "%", stats.cpuHistory, cpuColors, highlighted: true)
            tile("memorychip", "RAM", ByteFormat.gb(Double(stats.memUsed)), "GB", stats.memHistory, ramColors)
            tile("internaldrive", "SSD", ByteFormat.gb(Double(stats.diskUsed)), "GB", stats.diskHistory, ssdColors)
            tile("gauge.with.dots.needle.33percent", "GPU", stats.gpu.map(pct) ?? "–", "%", stats.gpuHistory, gpuColors)
            let r = ByteFormat.rate(stats.diskRead), w = ByteFormat.rate(stats.diskWrite)
            let i = ByteFormat.rate(stats.netIn), o = ByteFormat.rate(stats.netOut)
            tile("internaldrive", "SSD↓", r.0, r.1, stats.readHistory, readColors)
            tile("internaldrive", "SSD↑", w.0, w.1, stats.writeHistory, writeColors)
            tile("network", "NET↓", i.0, i.1, stats.netInHistory, netInColors)
            tile("network", "NET↑", o.0, o.1, stats.netOutHistory, netOutColors)
        }
    }

    private func tile(_ symbol: String, _ label: String, _ value: String, _ unit: String,
                      _ history: [Double], _ colors: [Color], highlighted: Bool = false) -> some View {
        let h = Array(history.suffix(40))
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                Text(label).font(Theme.font(9.5, .heavy))
            }
            .foregroundStyle(highlighted ? Theme.mint : Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(Theme.font(15, .bold)).lineLimit(1).minimumScaleFactor(0.6)
                Text(unit).font(Theme.font(8, .bold)).foregroundStyle(Theme.secondary)
            }
            SparkChart(values: h.count > 1 ? h : [0, 0], colors: colors, lineWidth: 1.6, fillOpacity: 0.2)
                .frame(height: 30)
        }
        .padding(7)
        .frame(height: 104)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(highlighted ? Theme.tileHover : Theme.tile))
    }
}

private struct LegendItem: View {
    var color: Color
    var label: String
    var value: String
    var mono = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(Theme.font(11, .semibold)).foregroundStyle(Theme.secondary)
            }
            Text(value).font(mono ? Theme.mono(12.5, .semibold) : Theme.font(13, .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HeadlineRow: View {
    var value: String
    var detail: String
    var trailing: AnyView

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(Theme.font(19, .bold))
            Text(detail).font(Theme.font(12, .semibold)).foregroundStyle(Theme.secondary)
            Spacer()
            trailing
        }
    }
}

private struct CPUPage: View {
    @ObservedObject private var stats = StatsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HeadlineRow(value: "\(pct(stats.cpu))%", detail: "load",
                        trailing: AnyView(Text("\(stats.cores) cores").font(Theme.font(12, .semibold)).foregroundStyle(Theme.secondary)))
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Capsule().fill(Theme.cyan).frame(width: geo.size.width * stats.cpuUser)
                    Capsule().fill(Theme.warmOrange).frame(width: geo.size.width * stats.cpuSystem)
                    Spacer(minLength: 0)
                }
                .background(Capsule().fill(Theme.track))
            }
            .frame(height: 4)
            HStack {
                LegendItem(color: Theme.cyan, label: "User", value: "\(pct(stats.cpuUser))%")
                LegendItem(color: Theme.warmOrange, label: "System", value: "\(pct(stats.cpuSystem))%")
                LegendItem(color: Theme.tertiary, label: "Idle", value: "\(pct(stats.cpuIdle))%")
            }
            ProcessList(sortByMemory: false, filter: "", limit: 6)
        }
    }
}

private struct MemoryPage: View {
    @ObservedObject private var stats = StatsService.shared

    private var pressure: (String, Color) {
        switch stats.memPressure {
        case 4: return ("Critical", Color(hex: 0xFF4757))
        case 2: return ("Warning", Theme.sunYellow)
        default: return ("Normal", Theme.mint)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HeadlineRow(value: ByteFormat.memory(stats.memUsed),
                        detail: "of \(String(format: "%.1f", Double(stats.memTotal) / 1_073_741_824)) GB",
                        trailing: AnyView(HStack(spacing: 4) {
                            Circle().fill(pressure.1).frame(width: 6, height: 6)
                            Text(pressure.0).font(Theme.font(12, .semibold)).foregroundStyle(Theme.secondary)
                        }))
            ProgressTrack(value: stats.memFraction, gradient: [Theme.memoryPink, Color(hex: 0xC34BFF)], height: 4)
            HStack {
                LegendItem(color: Theme.memoryPink, label: "Used", value: ByteFormat.memory(stats.memUsed), mono: true)
                LegendItem(color: Theme.cyan, label: "Cached", value: ByteFormat.memory(stats.memCached), mono: true)
                LegendItem(color: Theme.mint, label: "Free", value: ByteFormat.memory(stats.memFree), mono: true)
            }
            ProcessList(sortByMemory: true, filter: "", limit: 6)
        }
    }
}

private struct StoragePage: View {
    @ObservedObject private var stats = StatsService.shared

    var body: some View {
        let free = stats.diskTotal - stats.diskUsed
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                HeadlineRow(value: "\(ByteFormat.gb(Double(stats.diskUsed))) GB",
                            detail: "of \(String(format: "%.2f", Double(stats.diskTotal) / 1_073_741_824)) GB",
                            trailing: AnyView(Text("\(pct(stats.diskFraction))%").font(Theme.font(12, .bold)).foregroundStyle(Theme.secondary)))
                ProgressTrack(value: stats.diskFraction, gradient: [Theme.cyan, Theme.netBlue], height: 4)
                HStack {
                    LegendItem(color: Theme.cyan, label: "Used", value: "\(ByteFormat.gb(Double(stats.diskUsed))) GB", mono: true)
                    LegendItem(color: Theme.mint, label: "Free", value: "\(ByteFormat.gb(Double(free))) GB", mono: true)
                }
                HStack(alignment: .top) {
                    ioItem("arrow.down", "Read", stats.diskRead, stats.diskReadOps, Theme.cyan)
                    ioItem("arrow.up", "Write", stats.diskWrite, stats.diskWriteOps, Theme.warmOrange)
                }
                HStack {
                    Text("Large Files").font(Theme.font(13, .bold))
                    Spacer()
                    if stats.scanningLargeFiles {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        IconButton(symbol: "arrow.clockwise", size: 11) { stats.scanLargeFiles() }
                    }
                }
                if stats.largeFiles.isEmpty {
                    Text(stats.scanningLargeFiles ? "Scanning…" : "No large files found (over 100 MB)")
                        .font(Theme.font(11, .medium)).foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(stats.largeFiles) { f in
                        HoverRow(radius: 10, action: { NSWorkspace.shared.activateFileViewerSelecting([f.url]) }) {
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path))
                                    .resizable().frame(width: 18, height: 18)
                                Text(f.url.lastPathComponent).font(Theme.font(12, .semibold)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(ByteFormat.storage(f.size)).font(Theme.mono(11.5, .semibold)).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { if stats.largeFiles.isEmpty { stats.scanLargeFiles() } }
    }

    private func ioItem(_ symbol: String, _ label: String, _ rate: Double, _ ops: Double, _ color: Color) -> some View {
        let r = ByteFormat.rate(rate)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .heavy)).foregroundStyle(color)
                Text(label).font(Theme.font(11, .semibold)).foregroundStyle(Theme.secondary)
            }
            Text("\(r.0) \(r.1)").font(Theme.mono(12.5, .semibold))
            Text("\(Int(ops)) IOPS").font(Theme.mono(9.5, .medium)).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProcessList: View {
    var sortByMemory: Bool
    var filter: String
    var limit: Int
    @ObservedObject private var stats = StatsService.shared

    var body: some View {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let list = stats.processes
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }
            .sorted { sortByMemory ? $0.memory > $1.memory : $0.cpu > $1.cpu }
            .prefix(limit)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                if list.isEmpty {
                    Text(stats.processes.isEmpty ? "Sampling processes…" : "No matching processes")
                        .font(Theme.font(12, .medium)).foregroundStyle(Theme.tertiary)
                        .padding(.top, 20)
                }
                ForEach(Array(list)) { p in
                    ProcessRow(process: p, showMemory: sortByMemory)
                }
            }
        }
    }
}

private struct ProcessRow: View {
    var process: ProcessSample
    var showMemory: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Text(process.name).font(Theme.font(13, .semibold)).lineLimit(1)
            Spacer()
            Text(showMemory ? ByteFormat.memory(process.memory) : String(format: "%.1f%%", process.cpu))
                .font(Theme.mono(12.5, .semibold))
                .foregroundStyle(Theme.primary.opacity(0.9))
            Button {
                StatsService.shared.kill(process)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Theme.countdownPink)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quit \(process.name)")
        }
        .padding(.horizontal, 10)
        .frame(height: 27)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? Theme.tileHover : Theme.tile.opacity(0.0)))
        .onHover { hover = $0 }
    }
}
