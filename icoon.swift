// Tekent het app-icoon (1024 px). Gebruik: swift icoon.swift <uitvoer.png>
// Zwart vlak, drie tekstregels die omhoog lopen, mint cue-lijn.
import AppKit

let s: CGFloat = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func kleur(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}

kleur(0x000000).setFill()
NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
kleur(0x1C1C1E).setFill()
NSBezierPath(roundedRect: NSRect(x: 190, y: 190, width: 644, height: 644), xRadius: 110, yRadius: 110).fill()

// Tekstregels, bovenste het zwakst
let regels: [(CGFloat, CGFloat, CGFloat)] = [(640, 420, 0.25), (530, 470, 1.0), (420, 360, 0.55), (310, 300, 0.3)]
for (y, w, a) in regels {
    kleur(0xFFFFFF, a).setFill()
    NSBezierPath(roundedRect: NSRect(x: 290, y: y, width: w, height: 54), xRadius: 27, yRadius: 27).fill()
}
// Cue-lijn
kleur(0x75FA9D).setFill()
NSBezierPath(roundedRect: NSRect(x: 230, y: 552, width: 30, height: 10), xRadius: 5, yRadius: 5).fill()
NSBezierPath(roundedRect: NSRect(x: 764, y: 552, width: 30, height: 10), xRadius: 5, yRadius: 5).fill()

NSGraphicsContext.current = nil
if let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icoon.png"))
}
