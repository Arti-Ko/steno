// Рисует иконку 1024×1024: системный скруглённый квадрат с волной SF Symbols.
// Использование: swift Scripts/make-icon.swift Assets/AppIcon-1024.png
import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let canvas = 1024
let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 186

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Не удалось создать холст")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let tile = NSBezierPath(roundedRect: tileRect, xRadius: cornerRadius, yRadius: cornerRadius)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.white.setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(
    starting: NSColor(srgbRed: 0.36, green: 0.58, blue: 1.0, alpha: 1),
    ending: NSColor(srgbRed: 0.22, green: 0.27, blue: 0.88, alpha: 1)
)?.draw(in: tile, angle: -90)

NSGradient(
    starting: NSColor.white.withAlphaComponent(0.30),
    ending: NSColor.white.withAlphaComponent(0.0)
)?.draw(in: NSBezierPath(roundedRect: tileRect.insetBy(dx: 0, dy: 0), xRadius: cornerRadius, yRadius: cornerRadius), angle: -90)

let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(symbolConfiguration) {
    let size = symbol.size
    let origin = NSPoint(x: (CGFloat(canvas) - size.width) / 2, y: (CGFloat(canvas) - size.height) / 2)
    symbol.draw(in: NSRect(origin: origin, size: size))
}

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Не удалось закодировать PNG")
}
try png.write(to: URL(filePath: outputPath))
print("иконка: \(outputPath)")
