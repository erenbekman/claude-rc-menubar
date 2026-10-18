import Cocoa

_ = NSApplication.shared

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let paperTop    = color(0xFFFFFF)
let paperBottom = color(0xE4E7EC)
let ink         = color(0x233D4D)
let signal      = color(0xFE7F2D)
let stroke: CGFloat = 28

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("bitmap oluşturulamadı")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = 100
let body = NSRect(x: inset, y: inset + 8, width: S - inset * 2, height: S - inset * 2)
let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.235, yRadius: body.width * 0.235)

NSGraphicsContext.saveGraphicsState()
let dropShadow = NSShadow()
dropShadow.shadowColor = NSColor(white: 0, alpha: 0.28)
dropShadow.shadowBlurRadius = 26
dropShadow.shadowOffset = NSSize(width: 0, height: -10)
dropShadow.set()
paperBottom.setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: paperTop, ending: paperBottom)?.draw(in: squircle, angle: -90)
NSColor(white: 0, alpha: 0.08).setStroke()
squircle.lineWidth = 2
squircle.stroke()

let center = NSPoint(x: body.midX - 34, y: body.midY)
let radius: CGFloat = 250

let ring = NSBezierPath()
ring.appendArc(withCenter: center, radius: radius, startAngle: 42, endAngle: 318)
ring.lineWidth = stroke
ring.lineCapStyle = .round
ink.setStroke()
ring.stroke()

let tip = NSPoint(x: center.x + 62, y: center.y)
let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: tip.x - 92, y: tip.y + 92))
chevron.line(to: tip)
chevron.line(to: NSPoint(x: tip.x - 92, y: tip.y - 92))
chevron.lineWidth = stroke
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
chevron.stroke()

let pulse = NSBezierPath()
pulse.appendArc(withCenter: center, radius: radius + 92, startAngle: -24, endAngle: 24)
pulse.lineWidth = stroke
pulse.lineCapStyle = .round
signal.setStroke()
pulse.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png üretilemedi") }
try data.write(to: URL(fileURLWithPath: outPath))
print("yazıldı: \(outPath)")
