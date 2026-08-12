// Generates the Sweep app icon in every size and appearance, then builds Sweep.icns.
//
// Geometry comes from `SweepMark` in SweepCore, so the icon and the in-app logo cannot drift
// apart. Run: swift run MakeIcon Resources
import AppKit
import CoreGraphics
import Foundation
import SweepCore

// MARK: - Appearance

enum Appearance: String, CaseIterable {
    /// The app icon.
    case light
    /// Dark-appearance app icon.
    case dark
    /// Solid mark on a light plate — documentation and print.
    case mono
    /// Black-on-transparent template art, which is what AppKit and the menu bar expect to tint.
    /// (Drawing it white on transparent — the earlier attempt — is invisible on a light ground.)
    case template
}

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a).cgColor
}

func draw(_ appearance: Appearance, size: CGFloat) -> CGImage {
    let px = Int(size)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Background: full-bleed squircle, matching the macOS 26 convention observed in the Dock.
    let ink: CGColor
    switch appearance {
    case .light, .dark:
        ctx.saveGState()
        ctx.addPath(SweepMark.squircle(rect)); ctx.clip()
        let stops: [CGColor] = appearance == .light
            ? [rgb(108, 104, 255), rgb(58, 44, 178)]
            : [rgb(78, 74, 205), rgb(32, 24, 104)]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: stops as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        ctx.restoreGState()
        ink = rgb(255, 255, 255)
    case .mono:
        ctx.addPath(SweepMark.squircle(rect)); ctx.setFillColor(rgb(255, 255, 255)); ctx.fillPath()
        ink = rgb(0, 0, 0)
    case .template:
        // Template art: opaque black plus alpha. The system replaces the colour; supplying white
        // here renders invisibly against a light background.
        ink = rgb(0, 0, 0)
    }

    let (block, dot) = SweepMark.paths(in: rect, small: size <= 32)
    ctx.setFillColor(ink)
    ctx.addPath(block); ctx.fillPath()
    ctx.addPath(dot); ctx.fillPath()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - Output

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// .iconset for iconutil — the standard macOS raster ladder.
let iconset = out.appendingPathComponent("Sweep.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    writePNG(draw(.light, size: CGFloat(pt)), to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    writePNG(draw(.light, size: CGFloat(pt * 2)), to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}

// Variants kept for real uses: marketing/master art, dark, monochrome (docs and menu-bar use),
// and the tinted mark. Nothing is generated "just in case".
for appearance in Appearance.allCases {
    writePNG(draw(appearance, size: 1024), to: out.appendingPathComponent("sweep-\(appearance.rawValue)-1024.png"))
}

// Proof sheet: each size rendered *natively* (not downscaled), because a 16 px icon that was
// resampled from 128 px tells you nothing about how the real 16 px asset will look.
let ladder: [CGFloat] = [256, 128, 64, 32, 16]
let rowH: CGFloat = 300
let sheetW: CGFloat = 1080
let sheetH: CGFloat = rowH * CGFloat(Appearance.allCases.count)
let sheet = CGContext(data: nil, width: Int(sheetW), height: Int(sheetH), bitsPerComponent: 8,
                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for (row, appearance) in Appearance.allCases.enumerated() {
    let top = sheetH - CGFloat(row + 1) * rowH
    // Mono and tinted are judged on a light ground, which is where they get used.
    let ground: CGColor = (appearance == .mono || appearance == .template)
        ? rgb(244, 244, 246) : rgb(26, 26, 30)
    sheet.setFillColor(ground)
    sheet.fill(CGRect(x: 0, y: top, width: sheetW, height: rowH))
    var x: CGFloat = 30
    for size in ladder {
        let image = draw(appearance, size: size)     // native render at this exact size
        sheet.draw(image, in: CGRect(x: x, y: top + (rowH - size) / 2, width: size, height: size))
        x += size + 40
    }
    // Repeat the two smallest at 4x magnification so pixel-level behaviour is visible.
    for size in [CGFloat(32), CGFloat(16)] {
        let image = draw(appearance, size: size)
        sheet.interpolationQuality = .none
        sheet.draw(image, in: CGRect(x: x, y: top + (rowH - size * 4) / 2, width: size * 4, height: size * 4))
        sheet.interpolationQuality = .high
        x += size * 4 + 40
    }
}
writePNG(sheet.makeImage()!, to: out.appendingPathComponent("proof-sheet.png"))

// Build the .icns
let icns = out.appendingPathComponent("Sweep.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! task.run(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote \(icns.path)" : "iconutil failed (\(task.terminationStatus))")
print("proof sheet: \(out.appendingPathComponent("proof-sheet.png").path)")
