import AppKit
import Foundation

// Renders Dosa's brand assets from the source SVGs in Resources/Branding/:
//   - the macOS app icon (.icns), from dosa-icon-1024.svg (brown tile, amber mark)
//   - the in-app mark, tinted for each appearance from dosa-mark-currentcolor.svg
//     (a template shape — solid black, transparent elsewhere) into two flat PNGs
// All of it is regenerated on every build, so the shipped assets can never drift
// from the source SVGs.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let brandingDir = "Resources/Branding"

func loadSVG(_ name: String) -> NSImage {
    let path = "\(brandingDir)/\(name)"
    guard let image = NSImage(contentsOfFile: path) else {
        FileHandle.standardError.write(Data("Failed to load \(path)\n".utf8))
        exit(1)
    }
    return image
}

func rasterize(_ image: NSImage, size: CGFloat) -> NSImage {
    let canvas = NSImage(size: NSSize(width: size, height: size))
    canvas.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1.0)
    canvas.unlockFocus()
    return canvas
}

/// Tints a template image (solid black shape, transparent elsewhere) to
/// `color`, preserving its anti-aliased edges — the same technique AppKit
/// uses internally for `.isTemplate` images.
func tinted(_ image: NSImage, color: NSColor, size: CGFloat) -> NSImage {
    let output = NSImage(size: NSSize(width: size, height: size))
    output.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1.0)
    color.set()
    NSRect(x: 0, y: 0, width: size, height: size).fill(using: .sourceIn)
    output.unlockFocus()
    return output
}

func writePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("Failed to encode PNG for \(path)\n".utf8))
        exit(1)
    }
    try! png.write(to: URL(fileURLWithPath: path))
}

func run(_ launchPath: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    try! process.run()
    process.waitUntilExit()
}

// MARK: - App icon (.icns)

let iconSize: CGFloat = 1024
let iconImage = rasterize(loadSVG("dosa-icon-1024.svg"), size: iconSize)
let master = FileManager.default.temporaryDirectory.appendingPathComponent("dosa-icon-master.png")
writePNG(iconImage, to: master.path)

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
    (512, "512x512"), (1024, "512x512@2x"),
]
for (pixels, name) in variants {
    run("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)", master.path,
                          "--out", iconset.appendingPathComponent("icon_\(name).png").path])
}
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", "\(outDir)/AppIcon.icns"])
print("Icon written to \(outDir)/AppIcon.icns")

// MARK: - In-app mark (theme-tinted PNGs)

let markSize: CGFloat = 512
let markTemplate = rasterize(loadSVG("dosa-mark-currentcolor.svg"), size: markSize)

// Same brand pair the source dosa-mark-adaptive.svg encodes: brown reads on
// light backgrounds, amber reads on dark — true across every UI theme preset,
// since every preset's editor background is a near-white/near-black neutral.
let brown = NSColor(red: 0x7A / 255.0, green: 0x45 / 255.0, blue: 0x12 / 255.0, alpha: 1)
let amber = NSColor(red: 0xE0 / 255.0, green: 0xA4 / 255.0, blue: 0x4E / 255.0, alpha: 1)

writePNG(tinted(markTemplate, color: brown, size: markSize), to: "\(outDir)/dosa-mark-light.png")
writePNG(tinted(markTemplate, color: amber, size: markSize), to: "\(outDir)/dosa-mark-dark.png")
print("Mark written to \(outDir)/dosa-mark-light.png and \(outDir)/dosa-mark-dark.png")
