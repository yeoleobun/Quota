import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("Usage: swift generate-icons.swift <source-jpg> <assets-dir>\n", stderr)
    exit(1)
}

let sourcePath = args[1]
let assetsDir = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

guard let srcImage = NSImage(contentsOfFile: sourcePath) else {
    fputs("Failed to load source image at \(sourcePath)\n", stderr)
    exit(1)
}

func renderMasterIcon1024(from source: NSImage) -> NSBitmapImageRep {
    let px = 1024
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: px, height: px).fill()

    // Apple macOS Big Sur / Sequoia icon grid: 824x824 body inside 1024x1024 canvas
    let inset: CGFloat = 100
    let cardRect = NSRect(x: inset, y: inset, width: 824, height: 824)
    let cornerRadius: CGFloat = 185

    // Subtle macOS drop shadow
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.38)
    shadow.set()

    let shadowPath = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor.black.setFill()
    shadowPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Clip to squircle and draw artwork slightly zoomed to keep the beer mug bold & centered
    NSGraphicsContext.saveGraphicsState()
    let clipPath = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)
    clipPath.addClip()

    let srcSize = source.size
    let cropInset = min(srcSize.width, srcSize.height) * 0.06
    let fromRect = NSRect(
        x: cropInset,
        y: cropInset,
        width: srcSize.width - cropInset * 2,
        height: srcSize.height - cropInset * 2
    )
    source.draw(in: cardRect, from: fromRect, operation: .sourceOver, fraction: 1.0)

    // Subtle hairline border so a light squircle stands out cleanly on light & dark desktops
    let borderPath = NSBezierPath(roundedRect: cardRect.insetBy(dx: 1.5, dy: 1.5), xRadius: cornerRadius - 1.5, yRadius: cornerRadius - 1.5)
    borderPath.lineWidth = 2.5
    NSColor(calibratedWhite: 0.0, alpha: 0.09).setStroke()
    borderPath.stroke()

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func resizePNG(master: NSImage, pixelSize: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    master.draw(
        in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 1)
    }
    try data.write(to: url)
}

let masterRep = renderMasterIcon1024(from: srcImage)
let masterPNG = masterRep.representation(using: .png, properties: [:])!
let masterURL = assetsDir.appendingPathComponent("AppIcon.png")
try masterPNG.write(to: masterURL)

let masterImage = NSImage(size: NSSize(width: 1024, height: 1024))
masterImage.addRepresentation(masterRep)

let iconsetDir = assetsDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in specs {
    try resizePNG(master: masterImage, pixelSize: px, to: iconsetDir.appendingPathComponent(filename))
}

let icnsURL = assetsDir.appendingPathComponent("AppIcon.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]
try proc.run()
proc.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetDir)

if proc.terminationStatus != 0 {
    fputs("iconutil failed with exit code \(proc.terminationStatus)\n", stderr)
    exit(proc.terminationStatus)
}

print("Generated \(masterURL.path) and \(icnsURL.path)")
