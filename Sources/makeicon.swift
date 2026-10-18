// 1024x1024 uygulama ikonu üretir (squircle + anten sembolü).
// Kullanım: swift makeicon.swift <cikis.png>
import Cocoa

_ = NSApplication.shared

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S: CGFloat = 1024

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("bitmap oluşturulamadı")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS ikon gövdesi: 1024 tuvalde ~824 kenar, hafif yukarı kaydırma
let inset: CGFloat = 100
let body = NSRect(x: inset, y: inset + 8, width: S - inset * 2, height: S - inset * 2)
let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.235, yRadius: body.width * 0.235)

// Claude kil tonu gradyanı
let top = NSColor(srgbRed: 0.90, green: 0.53, blue: 0.40, alpha: 1)
let bot = NSColor(srgbRed: 0.78, green: 0.38, blue: 0.28, alpha: 1)
NSGradient(starting: top, ending: bot)?.draw(in: squircle, angle: -90)

// İnce iç kenar parlaklığı
NSColor(white: 1, alpha: 0.18).setStroke()
squircle.lineWidth = 3
squircle.stroke()

// Anten sembolü
let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
if let sym = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                     accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let sz = sym.size
    let r = NSRect(x: (S - sz.width) / 2, y: (S - sz.height) / 2 + 12, width: sz.width, height: sz.height)
    // Beyaz olarak boya
    let tinted = NSImage(size: sz)
    tinted.lockFocus()
    NSColor.white.set()
    let full = NSRect(origin: .zero, size: sz)
    sym.draw(in: full)
    full.fill(using: .sourceAtop)
    tinted.unlockFocus()
    // Hafif gölge
    let sh = NSShadow()
    sh.shadowColor = NSColor(white: 0, alpha: 0.25)
    sh.shadowBlurRadius = 18
    sh.shadowOffset = NSSize(width: 0, height: -8)
    sh.set()
    tinted.draw(in: r)
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png üretilemedi") }
try data.write(to: URL(fileURLWithPath: outPath))
print("yazıldı: \(outPath)")
