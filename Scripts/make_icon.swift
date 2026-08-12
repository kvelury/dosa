import AppKit
import Foundation

// Renders the Dosa app icon (orange gradient tile + waveform/mic glyph) and
// packages it as an .icns via sips + iconutil.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset: CGFloat = 100
let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(
    starting: NSColor(red: 1.00, green: 0.66, blue: 0.24, alpha: 1),
    ending: NSColor(red: 0.83, green: 0.29, blue: 0.09, alpha: 1)
)!.draw(in: path, angle: -75)

let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .medium)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let origin = NSPoint(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2)
    symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Failed to render icon\n".utf8))
    exit(1)
}

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("dosa-icon-build")
let iconset = tmp.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: tmp)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = tmp.appendingPathComponent("master.png")
try! png.write(to: master)

func run(_ launchPath: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    try! process.run()
    process.waitUntilExit()
}

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
