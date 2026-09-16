import AppKit
import Foundation

// Package the supplied mascot unchanged into macOS icon resolutions.
guard CommandLine.arguments.count == 3 else { fatalError("Usage: swift scripts/create-icon.swift mascot.png output.iconset") }
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = NSImage(contentsOf: sourceURL) else { fatalError("Cannot read mascot") }
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let side = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let inset = CGFloat(side) * 0.055
        let available = CGFloat(side) - 2 * inset
        let factor = available / max(source.size.width, source.size.height)
        let width = source.size.width * factor, height = source.size.height * factor
        source.draw(in: NSRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2,
                               width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
