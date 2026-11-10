// Draws the app icon: a paper plane on a blue gradient, and writes app/AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let dir = "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
func draw(_ s: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: s, pixelsHigh: s, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let f = CGFloat(s), inset = f * 0.09
    let rect = NSRect(x: inset, y: inset, width: f - 2 * inset, height: f - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.45, blue: 1.0, alpha: 1), NSColor(red: 0.45, green: 0.20, blue: 0.95, alpha: 1)])!
        .draw(in: path, angle: -60)
    let cfg = NSImage.SymbolConfiguration(pointSize: f * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = sym.size
        sym.draw(in: NSRect(x: (f - sz.width) / 2, y: (f - sz.height) / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for s in sizes where s <= 512 {
    try! draw(s).write(to: URL(fileURLWithPath: "\(dir)/icon_\(s)x\(s).png"))
    try! draw(s * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(s)x\(s)@2x.png"))
}
// Turn the iconset into the .icns that build.sh copies into the app.
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", dir, "-o", "app/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { print("iconutil failed"); exit(1) }
print("Wrote app/AppIcon.icns")
