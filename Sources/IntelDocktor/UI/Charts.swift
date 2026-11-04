import SwiftUI

enum ChartMath {
    static func points(_ values: [Double], lo: Double, hi: Double, in rect: CGRect) -> [CGPoint] {
        guard values.count > 1 else {
            let y = rect.midY
            return [CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)]
        }
        let span = max(hi - lo, 0.0001)
        return values.enumerated().map { i, v in
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1)
            let t = (min(max(v, lo), hi) - lo) / span
            return CGPoint(x: x, y: rect.maxY - rect.height * CGFloat(t))
        }
    }

    /// Catmull-Rom spline through the points, as cubic Béziers.
    static func smooth(_ pts: [CGPoint], into path: inout Path, moveToFirst: Bool = true) {
        guard let first = pts.first else { return }
        if moveToFirst { path.move(to: first) } else { path.addLine(to: first) }
        guard pts.count > 1 else { return }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    static func range(_ values: [Double], minSpan: Double = 1, pad: Double = 0.12) -> (Double, Double) {
        guard let lo = values.min(), let hi = values.max() else { return (0, 1) }
        var l = lo, h = hi
        if h - l < minSpan {
            let mid = (h + l) / 2
            l = mid - minSpan / 2
            h = mid + minSpan / 2
        }
        let p = (h - l) * pad
        return (l - p, h + p)
    }
}

/// Chart readings SwiftUI can interpolate, so a line glides to new values
/// instead of jumping. A series that grew is padded with its last value, so
/// new points slide in from the end rather than from zero.
struct AnimatableValues: VectorArithmetic {
    var values: [Double]

    static var zero: AnimatableValues { .init(values: []) }
    static func + (a: Self, b: Self) -> Self { combine(a, b, +) }
    static func - (a: Self, b: Self) -> Self { combine(a, b, -) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    private static func combine(_ a: Self, _ b: Self, _ op: (Double, Double) -> Double) -> Self {
        let n = max(a.values.count, b.values.count)
        func at(_ v: [Double], _ i: Int) -> Double { i < v.count ? v[i] : (v.last ?? 0) }
        return .init(values: (0..<n).map { op(at(a.values, $0), at(b.values, $0)) })
    }
}

/// The plot area inside a chart's bounds.
struct ChartInsets: Equatable {
    var horizontal: CGFloat = 0
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    func rect(in r: CGRect) -> CGRect {
        CGRect(x: r.minX + horizontal, y: r.minY + top,
               width: max(1, r.width - horizontal * 2), height: max(1, r.height - top - bottom))
    }
}

struct SparkLineShape: Shape {
    var values: [Double]
    var lo: Double
    var hi: Double
    var insets = ChartInsets()

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatableValues> {
        get { .init(.init(lo, hi), .init(values: values)) }
        set { lo = newValue.first.first; hi = newValue.first.second; values = newValue.second.values }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        ChartMath.smooth(ChartMath.points(values, lo: lo, hi: hi, in: insets.rect(in: rect)), into: &p)
        return p
    }
}

struct SparkAreaShape: Shape {
    var values: [Double]
    var lo: Double
    var hi: Double
    var insets = ChartInsets()

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatableValues> {
        get { .init(.init(lo, hi), .init(values: values)) }
        set { lo = newValue.first.first; hi = newValue.first.second; values = newValue.second.values }
    }

    func path(in bounds: CGRect) -> Path {
        let rect = insets.rect(in: bounds)
        let pts = ChartMath.points(values, lo: lo, hi: hi, in: rect)
        var p = Path()
        guard let first = pts.first, let last = pts.last else { return p }
        p.move(to: CGPoint(x: first.x, y: rect.maxY))
        ChartMath.smooth(pts, into: &p, moveToFirst: false)
        p.addLine(to: CGPoint(x: last.x, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// A smooth line chart with a gradient stroke, soft fill, and optional point labels.
struct SparkChart: View {
    struct Marker: Hashable {
        var index: Int
        var label: String
        var color: Color? = nil
    }

    var values: [Double]
    var lo: Double? = nil
    var hi: Double? = nil
    var colors: [Color] = [Theme.mint, Theme.teal]
    var lineWidth: CGFloat = 2
    var fillOpacity: Double = 0.28
    var markers: [Marker] = []
    var markerFont: Font = Theme.font(10, .bold)
    var verticalInset: CGFloat = 0

    var body: some View {
        let range = ChartMath.range(values)
        let l = lo ?? range.0
        let h = hi ?? range.1
        GeometryReader { geo in
            let rect = CGRect(x: lineWidth, y: verticalInset, width: max(1, geo.size.width - lineWidth * 2),
                              height: max(1, geo.size.height - verticalInset - lineWidth))
            let pts = ChartMath.points(values, lo: l, hi: h, in: rect)
            let insets = ChartInsets(horizontal: lineWidth, top: verticalInset, bottom: lineWidth)
            ZStack(alignment: .topLeading) {
                // The fill fades out at both ends instead of stopping at a hard
                // edge, and the line fades in from the oldest reading.
                SparkAreaShape(values: values, lo: l, hi: h, insets: insets)
                    .fill(LinearGradient(colors: [(colors.first ?? .white).opacity(fillOpacity), .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3),
                                                 .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                SparkLineShape(values: values, lo: l, hi: h, insets: insets)
                    .stroke(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    .mask(LinearGradient(stops: [.init(color: .black.opacity(0.15), location: 0), .init(color: .black, location: 0.2)],
                                         startPoint: .leading, endPoint: .trailing))
                ForEach(markers, id: \.self) { m in
                    if m.index >= 0, m.index < pts.count {
                        let pt = pts[m.index]
                        let dotColor = m.color ?? gradientColor(at: pt.x / max(geo.size.width, 1))
                        Circle().fill(dotColor)
                            .frame(width: lineWidth * 2.4, height: lineWidth * 2.4)
                            .position(pt)
                        if !m.label.isEmpty {
                            Text(m.label)
                                .font(markerFont)
                                .foregroundStyle(.white)
                                .fixedSize()
                                .position(x: labelX(pt.x, width: geo.size.width), y: pt.y + 11)
                        }
                    }
                }
            }
            // Glide to each new reading rather than jumping.
            .animation(Motion.smooth, value: values)
        }
    }

    private func labelX(_ x: CGFloat, width: CGFloat) -> CGFloat {
        min(max(x, 14), width - 14)
    }

    private func gradientColor(at t: CGFloat) -> Color {
        guard !colors.isEmpty else { return .white }
        let i = Int((t * CGFloat(colors.count - 1)).rounded())
        return colors[min(max(i, 0), colors.count - 1)]
    }
}

/// Thin capsule progress bar.
struct ProgressTrack: View {
    var value: Double
    var color: Color = Theme.mint
    var gradient: [Color]? = nil
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(gradient.map { AnyShapeStyle(LinearGradient(colors: $0, startPoint: .leading, endPoint: .trailing)) }
                          ?? AnyShapeStyle(color))
                    .frame(width: max(height, geo.size.width * CGFloat(min(max(value, 0), 1))))
            }
            .animation(Motion.smooth, value: value)
        }
        .frame(height: height)
    }
}

/// Low→high range bar (weather "Today L 51 ━━━ H 85").
struct RangeBar: View {
    var lo: Double
    var hi: Double
    var totalLo: Double
    var totalHi: Double
    var current: Double? = nil
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let span = max(totalHi - totalLo, 1)
            let x0 = geo.size.width * CGFloat((lo - totalLo) / span)
            let x1 = geo.size.width * CGFloat((hi - totalLo) / span)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(LinearGradient(colors: TemperatureColors.gradient(lo: lo, hi: hi),
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, x1 - x0))
                    .offset(x: x0)
                if let current {
                    Circle().fill(.white)
                        .frame(width: height + 3, height: height + 3)
                        .shadow(color: .black.opacity(0.4), radius: 1)
                        .offset(x: geo.size.width * CGFloat((current - totalLo) / span) - (height + 3) / 2)
                }
            }
        }
        .frame(height: height)
    }
}

enum TemperatureColors {
    /// Celsius-ish anchor palette; converted from °F by the caller if needed.
    static func color(forCelsius c: Double) -> Color {
        switch c {
        case ..<0: return Color(red: 0.45, green: 0.65, blue: 1.0)
        case ..<10: return Theme.cyan
        case ..<18: return Theme.mint
        case ..<25: return Theme.sunYellow
        case ..<31: return Theme.warmOrange
        default: return Color(red: 1.0, green: 0.33, blue: 0.25)
        }
    }

    @MainActor
    static func gradient(lo: Double, hi: Double) -> [Color] {
        let f = AppSettings.shared.useFahrenheit
        let toC: (Double) -> Double = { f ? ($0 - 32) * 5 / 9 : $0 }
        let a = toC(lo), b = toC(hi)
        let steps = 4
        return (0...steps).map { i in color(forCelsius: a + (b - a) * Double(i) / Double(steps)) }
    }
}
