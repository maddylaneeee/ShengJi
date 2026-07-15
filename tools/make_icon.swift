import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else { fatalError("No graphics context") }
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 205, yRadius: 205)
NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.55, blue: 1.0, alpha: 1),
    NSColor(calibratedRed: 0.38, green: 0.22, blue: 0.95, alpha: 1)
])!.draw(in: tile, angle: -52)

let highlight = NSBezierPath(roundedRect: NSRect(x: 98, y: 510, width: 828, height: 408), xRadius: 170, yRadius: 170)
NSGradient(colors: [NSColor.white.withAlphaComponent(0.30), NSColor.white.withAlphaComponent(0.0)])!
    .draw(in: highlight, angle: -90)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -20), blur: 42, color: NSColor.black.withAlphaComponent(0.22).cgColor)
let configuration = NSImage.SymbolConfiguration(pointSize: 410, weight: .medium)
if let symbol = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
    symbol.isTemplate = true
    let symbolRect = NSRect(x: 229, y: 286, width: 566, height: 452)
    NSColor.white.set()
    symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
}
context.restoreGState()
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon")
}
try png.write(to: URL(fileURLWithPath: output))
