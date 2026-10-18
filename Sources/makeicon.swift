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

let navyLight = color(0x2E4D60)
let navyDeep  = color(0x0F1C24)
let paper     = color(0xEAECF0)

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
dropShadow.shadowColor = NSColor(white: 0, alpha: 0.35)
dropShadow.shadowBlurRadius = 28
dropShadow.shadowOffset = NSSize(width: 0, height: -12)
dropShadow.set()
navyDeep.setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: navyLight, ending: navyDeep)?.draw(in: squircle, angle: -90)

let tip = NSPoint(x: 420, y: body.midY)

NSGraphicsContext.saveGraphicsState()
squircle.addClip()
NSGradient(colors: [color(0xFE7F2D, 0.30), color(0xFE7F2D, 0)])?
    .draw(fromCenter: NSPoint(x: tip.x + 150, y: tip.y), radius: 0,
          toCenter: NSPoint(x: tip.x + 150, y: tip.y), radius: 420, options: [])
NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0)])?
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

NSColor(white: 1, alpha: 0.14).setStroke()
squircle.lineWidth = 3
squircle.stroke()

let glyphShadow = NSShadow()
glyphShadow.shadowColor = NSColor(white: 0, alpha: 0.35)
glyphShadow.shadowBlurRadius = 16
glyphShadow.shadowOffset = NSSize(width: 0, height: -6)

NSGraphicsContext.saveGraphicsState()
glyphShadow.set()

let arm: CGFloat = 150
let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: tip.x - arm, y: tip.y + arm))
chevron.line(to: tip)
chevron.line(to: NSPoint(x: tip.x - arm, y: tip.y - arm))
chevron.lineWidth = 84
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
paper.setStroke()
chevron.stroke()

for (radius, hex) in [(CGFloat(150), UInt32(0xFE7F2D)), (245, 0xEC6A1E), (340, 0xD45A17)] {
    let arc = NSBezierPath()
    arc.appendArc(withCenter: tip, radius: radius, startAngle: -42, endAngle: 42)
    arc.lineWidth = 58
    arc.lineCapStyle = .round
    color(hex).setStroke()
    arc.stroke()
}
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png üretilemedi") }
try data.write(to: URL(fileURLWithPath: outPath))
print("yazıldı: \(outPath)")
