// Draws the MacMerge app icon and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift  (needs iconutil, which comes with macOS)
import AppKit

let size: CGFloat = 1024

func draw(in ctx: CGContext) {
    let s = size
    // macOS icon grid: the shape fills about 80% of the canvas.
    let inset = s * 0.1
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225

    // Shadow under the shape.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient: deep indigo to teal.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.16, green: 0.20, blue: 0.48, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.10, green: 0.55, blue: 0.62, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    ctx.restoreGState()

    // Two documents side by side.
    let docW = body.width * 0.30, docH = body.height * 0.52
    let docY = body.minY + body.height * 0.25
    let gap = body.width * 0.07
    let leftX = body.midX - gap / 2 - docW
    let rightX = body.midX + gap / 2
    for (i, x) in [leftX, rightX].enumerated() {
        let rect = CGRect(x: x, y: docY, width: docW, height: docH)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.015, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: s * 0.025, cornerHeight: s * 0.025, transform: nil))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Text lines; the middle ones are highlighted as a difference.
        let lineH = docH * 0.065
        let pad = docW * 0.14
        for row in 0..<8 {
            let y = rect.maxY - docH * 0.13 - CGFloat(row) * docH * 0.105
            let changed = row == 3 || row == 4
            if changed {
                let band = CGRect(x: rect.minX, y: y - lineH * 0.55, width: rect.width, height: docH * 0.105 * 2 * 0.93)
                ctx.setFillColor((i == 0 ? NSColor(srgbRed: 0.94, green: 0.80, blue: 0.10, alpha: 1)
                                         : NSColor(srgbRed: 0.94, green: 0.47, blue: 0.45, alpha: 1)).cgColor)
                ctx.fill(band.offsetBy(dx: 0, dy: -docH * 0.105 * (row == 3 ? 1 : 0)).intersection(rect))
            }
        }
        for row in 0..<8 {
            let y = rect.maxY - docH * 0.13 - CGFloat(row) * docH * 0.105
            let widths: [CGFloat] = [0.72, 0.55, 0.64, 0.70, 0.48, 0.66, 0.58, 0.40]
            let w = (rect.width - pad * 2) * widths[(row + i * 3) % widths.count]
            let line = CGRect(x: rect.minX + pad, y: y, width: w, height: lineH)
            ctx.addPath(CGPath(roundedRect: line, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
            ctx.setFillColor(NSColor(srgbRed: 0.35, green: 0.38, blue: 0.45, alpha: 0.55).cgColor)
            ctx.fillPath()
        }
    }

    // A merge arrow from the left document into the right one.
    let arrowY = docY + docH * 0.5
    let shaft = CGRect(x: leftX + docW * 0.62, y: arrowY - s * 0.022, width: (rightX - leftX) - docW * 0.62 + docW * 0.12, height: s * 0.044)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.004), blur: s * 0.012, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.setFillColor(NSColor(srgbRed: 0.18, green: 0.47, blue: 0.95, alpha: 1).cgColor)
    ctx.addPath(CGPath(roundedRect: shaft, cornerWidth: shaft.height / 2, cornerHeight: shaft.height / 2, transform: nil))
    ctx.fillPath()
    let tip = CGMutablePath()
    let tipX = shaft.maxX + s * 0.05
    tip.move(to: CGPoint(x: tipX, y: arrowY))
    tip.addLine(to: CGPoint(x: shaft.maxX - s * 0.02, y: arrowY + s * 0.065))
    tip.addLine(to: CGPoint(x: shaft.maxX - s * 0.02, y: arrowY - s * 0.065))
    tip.closeSubpath()
    ctx.addPath(tip)
    ctx.fillPath()
    ctx.restoreGState()
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
draw(in: NSGraphicsContext.current!.cgContext)
NSGraphicsContext.restoreGraphicsState()

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let master = root.appending(path: "Resources/Icon/AppIcon-1024.png")
try! rep.representation(using: .png, properties: [:])!.write(to: master)

// Build the .iconset with every size macOS wants, then pack it.
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/sips")
        p.arguments = ["-z", "\(px)", "\(px)", master.path, "--out", iconset.appending(path: name).path]
        p.standardOutput = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
    }
}
let pack = Process()
pack.executableURL = URL(filePath: "/usr/bin/iconutil")
pack.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path]
try! pack.run(); pack.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote Resources/AppIcon.icns")
