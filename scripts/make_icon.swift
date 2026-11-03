// Renders the app icon: a midnight squircle with a glass Dock and two widgets.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
    let inset: CGFloat = 100
    let body = rect.insetBy(dx: inset, dy: inset)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    squircle.fill()
    ctx.restoreGState()

    // Background gradient, deep indigo → electric blue.
    ctx.saveGState()
    squircle.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.33, green: 0.13, blue: 0.85, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.16, blue: 0.62, alpha: 1),
        NSColor(srgbRed: 0.03, green: 0.07, blue: 0.30, alpha: 1),
    ])!.draw(in: body, angle: -60)

    // Light sweep
    let sweep = NSBezierPath()
    sweep.move(to: CGPoint(x: body.minX, y: body.minY + 250))
    sweep.curve(to: CGPoint(x: body.maxX, y: body.maxY - 120),
                controlPoint1: CGPoint(x: body.minX + 330, y: body.minY + 300),
                controlPoint2: CGPoint(x: body.maxX - 320, y: body.maxY - 60))
    sweep.line(to: CGPoint(x: body.maxX, y: body.maxY))
    sweep.line(to: CGPoint(x: body.minX, y: body.maxY))
    sweep.close()
    NSColor.white.withAlphaComponent(0.07).setFill()
    sweep.fill()
    let edge = NSBezierPath()
    edge.move(to: CGPoint(x: body.minX, y: body.minY + 250))
    edge.curve(to: CGPoint(x: body.maxX, y: body.maxY - 120),
               controlPoint1: CGPoint(x: body.minX + 330, y: body.minY + 300),
               controlPoint2: CGPoint(x: body.maxX - 320, y: body.maxY - 60))
    edge.lineWidth = 6
    NSColor(srgbRed: 0.55, green: 0.70, blue: 1, alpha: 0.55).setStroke()
    edge.stroke()

    func glass(_ r: CGRect, radius: CGFloat) {
        let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        NSColor.white.withAlphaComponent(0.16).setFill()
        p.fill()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0.0)])!
            .draw(in: p, angle: -90)
        p.lineWidth = 4
        NSColor.white.withAlphaComponent(0.45).setStroke()
        p.stroke()
    }

    // Dock + widgets row
    let rowY = body.minY + 92
    let h: CGFloat = 132
    let widgetL = CGRect(x: body.minX + 62, y: rowY, width: 132, height: h)
    let dock = CGRect(x: widgetL.maxX + 22, y: rowY, width: 300, height: h)
    let widgetR = CGRect(x: dock.maxX + 22, y: rowY, width: 132, height: h)
    glass(widgetL, radius: 40)
    glass(dock, radius: 40)
    glass(widgetR, radius: 40)

    // Left widget: CPU curve
    let curve = NSBezierPath()
    curve.move(to: CGPoint(x: widgetL.minX + 18, y: widgetL.minY + 30))
    curve.curve(to: CGPoint(x: widgetL.maxX - 18, y: widgetL.minY + 44),
                controlPoint1: CGPoint(x: widgetL.minX + 50, y: widgetL.maxY - 10),
                controlPoint2: CGPoint(x: widgetL.maxX - 50, y: widgetL.maxY - 20))
    curve.lineWidth = 10
    curve.lineCapStyle = .round
    NSColor(srgbRed: 0.18, green: 0.91, blue: 0.56, alpha: 1).setStroke()
    curve.stroke()

    // Right widget: calendar tile
    let tile = widgetR.insetBy(dx: 14, dy: 14)
    NSColor(srgbRed: 0.93, green: 0.17, blue: 0.31, alpha: 1).setFill()
    NSBezierPath(roundedRect: tile, xRadius: 28, yRadius: 28).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: CGRect(x: tile.midX - 30, y: tile.midY - 28, width: 60, height: 14), xRadius: 7, yRadius: 7).fill()
    NSBezierPath(roundedRect: CGRect(x: tile.midX - 18, y: tile.midY + 6, width: 36, height: 10), xRadius: 5, yRadius: 5).fill()

    // Dock icons
    let colors: [NSColor] = [
        NSColor(srgbRed: 0.20, green: 0.62, blue: 1, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.62, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.35, green: 0.85, blue: 0.45, alpha: 1),
    ]
    for (i, c) in colors.enumerated() {
        let r = CGRect(x: dock.minX + 24 + CGFloat(i) * 88, y: dock.minY + 26, width: 76, height: 76)
        c.setFill()
        NSBezierPath(roundedRect: r, xRadius: 20, yRadius: 20).fill()
    }

    // Preview card floating above the middle icon
    let card = CGRect(x: dock.midX - 170, y: rowY + h + 70, width: 340, height: 250)
    glass(card, radius: 44)
    let thumb = card.insetBy(dx: 26, dy: 26).offsetBy(dx: 0, dy: -10)
    let t = CGRect(x: thumb.minX, y: thumb.minY, width: thumb.width, height: thumb.height - 30)
    NSColor.white.withAlphaComponent(0.88).setFill()
    NSBezierPath(roundedRect: t, xRadius: 20, yRadius: 20).fill()
    NSColor(srgbRed: 0.30, green: 0.40, blue: 0.95, alpha: 0.9).setFill()
    NSBezierPath(roundedRect: CGRect(x: t.minX, y: t.maxY - 34, width: t.width, height: 34), xRadius: 16, yRadius: 16).fill()
    NSColor.white.withAlphaComponent(0.9).setFill()
    NSBezierPath(roundedRect: CGRect(x: card.minX + 26, y: card.maxY - 40, width: 140, height: 14), xRadius: 7, yRadius: 7).fill()

    ctx.restoreGState()
    squircle.lineWidth = 3
    NSColor.white.withAlphaComponent(0.18).setStroke()
    squircle.stroke()
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
