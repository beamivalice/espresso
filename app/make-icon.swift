//  Render SF Symbol cup.and.saucer.fill to a 1024 PNG for the app icon.
//  Usage: make-icon <out.png>

import AppKit

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: make-icon <out.png>\n", stderr)
    exit(1)
}
let out = CommandLine.arguments[1]
let canvasSize: CGFloat = 1024

guard let symbol = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil) else {
    fputs("cup.and.saucer.fill not available\n", stderr)
    exit(1)
}

let config = NSImage.SymbolConfiguration(pointSize: 680, weight: .medium)
    .applying(.init(paletteColors: [
        NSColor(calibratedRed: 0.98, green: 0.94, blue: 0.88, alpha: 1)
    ]))
guard let tinted = symbol.withSymbolConfiguration(config) else {
    fputs("symbol configuration failed\n", stderr)
    exit(1)
}

let canvas = NSImage(size: NSSize(width: canvasSize, height: canvasSize))
canvas.lockFocus()
NSColor(calibratedRed: 0.22, green: 0.13, blue: 0.08, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)).fill()

let s = tinted.size
let maxSide = canvasSize * 0.62
let scale = min(maxSide / max(s.width, 1), maxSide / max(s.height, 1))
let dw = s.width * scale
let dh = s.height * scale
let dest = NSRect(x: (canvasSize - dw) / 2,
                  y: (canvasSize - dh) / 2 - canvasSize * 0.03,
                  width: dw, height: dh)
tinted.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("png encode failed\n", stderr)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: out))
} catch {
    fputs("write failed: \(error)\n", stderr)
    exit(1)
}
