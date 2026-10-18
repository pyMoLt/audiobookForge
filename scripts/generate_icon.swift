import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.10, blue: 0.45, alpha: 1.0),
    NSColor(calibratedRed: 0.05, green: 0.35, blue: 0.55, alpha: 1.0),
])
gradient?.draw(in: rect, angle: -60)

if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) {
    let sizeConfig = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .medium)
    let colorConfig = NSImage.SymbolConfiguration(paletteColors: [.white])
    let config = sizeConfig.applying(colorConfig)
    let tinted = symbol.withSymbolConfiguration(config) ?? symbol
    let symbolSize = tinted.size
    let origin = NSPoint(x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2)
    tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not render icon")
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
