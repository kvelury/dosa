import SwiftUI
import AppKit

/// Menu bar icons, drawn rather than rasterized because the recording animation
/// needs each ring rotated independently — a flat raster can't give that.
/// Geometry mirrors Resources/Branding/dosa-menubarTemplate.svg exactly; the raw
/// numbers below are that file's, so keep them in sync if the SVG changes.
enum MenuBarIcon {
    static let frameCount = 24

    private static let canvas: CGFloat = 18
    /// The SVG's <g transform="translate(11,11) scale(0.1333)"> against its 22-unit viewBox.
    private static let unit = (canvas / 22.0) * 0.1333

    static let idle = frame(angle: 0, filledCore: false)
    static let recordingStill = frame(angle: 0, filledCore: true)
    /// 24 frames × 15° = one full revolution.
    static let recordingFrames: [NSImage] =
        (0..<frameCount).map {
            frame(angle: Double($0) * 360.0 / Double(frameCount), filledCore: true)
        }

    static func current(recording: Bool, phase: Int) -> NSImage {
        guard recording else { return idle }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return recordingStill
        }
        return recordingFrames[phase % frameCount]
    }

    private static func frame(angle: Double, filledCore: Bool) -> NSImage {
        let image = NSImage(
            size: NSSize(width: canvas, height: canvas),
            flipped: false
        ) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.translateBy(x: canvas / 2, y: canvas / 2)
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // outer: r=68, stroke-width=14, dash 409/18 — rotates one way…
            ring(ctx, r: 68, width: 14, dash: [409, 18], degrees: angle)
            // inner: r=42, stroke-width=14, dash 246/18, base rotate(-30) — …the other.
            ring(ctx, r: 42, width: 14, dash: [246, 18], degrees: -30 - angle)

            if filledCore {
                fillCircle(ctx, r: 18)
            } else {
                ring(ctx, r: 13, width: 9, dash: [], degrees: 0)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func ring(
        _ ctx: CGContext,
        r: CGFloat,
        width: CGFloat,
        dash: [CGFloat],
        degrees: Double
    ) {
        ctx.saveGState()
        ctx.rotate(by: CGFloat(degrees * .pi / 180))
        ctx.setLineWidth(width * unit)
        ctx.setLineDash(phase: 0, lengths: dash.map { $0 * unit })
        let radius = r * unit
        ctx.addEllipse(in: CGRect(
            x: -radius,
            y: -radius,
            width: radius * 2,
            height: radius * 2
        ))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func fillCircle(_ ctx: CGContext, r: CGFloat) {
        let radius = r * unit
        ctx.fillEllipse(in: CGRect(
            x: -radius,
            y: -radius,
            width: radius * 2,
            height: radius * 2
        ))
    }
}

/// Dosa's brand mark, tinted per appearance (brown on light, amber on dark —
/// true across every UI theme preset, since each one's editor background is a
/// near-white/near-black neutral regardless of accent). Loads the two PNGs
/// `build.sh` bakes from Resources/Branding/dosa-mark-currentcolor.svg via
/// Scripts/make_icon.swift, so the shipped mark always matches that source.
struct DosaMark: View {
    @Environment(\.colorScheme) private var colorScheme

    private static let light = loadMark("dosa-mark-light")
    private static let dark = loadMark("dosa-mark-dark")

    private static func loadMark(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        let image = colorScheme == .dark ? Self.dark : Self.light
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}

/// Oversized, translucent brand mark for the welcome-screen backdrop.
/// Geometry is the same rings as `dosa-mark-currentcolor.svg` (r = 70 / 52 / 34,
/// dash gaps, rotations, filled core), drawn in a `Canvas` so it stays sharp at
/// any window size. Tinted from the active theme's highlight, not the
/// brown/amber of `DosaMark`, so Crepe/Masala/Chutney/Slate each get their own wash.
struct DosaWatermark: View {
    @Environment(\.colorScheme) private var colorScheme
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let diameter = Self.diameter(in: geo.size)
            DosaMarkRings(color: color)
                .frame(width: diameter, height: diameter)
                .opacity(colorScheme == .dark ? 0.20 : 0.13)
                // Center sits on the top edge so the rings sweep down over the
                // upper half of the pane — the rest clips away.
                .position(x: geo.size.width / 2, y: 0)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Outer ring is at r = 70 in a 200-unit viewBox (0.35 of the frame). Size
    /// so that ring covers about half the pane and spans the width, without
    /// flooding a short window past ~68% of its height.
    private static func diameter(in size: CGSize) -> CGFloat {
        let outerRingRatio: CGFloat = 70 / 200
        let targetRadius = min(
            max(size.width * 0.52, size.height * 0.50),
            size.height * 0.68
        )
        return targetRadius / outerRingRatio
    }
}

/// Vector rings matching `Resources/Branding/dosa-mark-currentcolor.svg`.
private struct DosaMarkRings: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 200
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: scale, y: scale)

            strokeRing(context, radius: 70, dash: [426, 14], degrees: 0)
            strokeRing(context, radius: 52, dash: [313, 14], degrees: -20)
            strokeRing(context, radius: 34, dash: [200, 14], degrees: -40)

            context.fill(
                Path(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28)),
                with: .color(color)
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func strokeRing(
        _ context: GraphicsContext,
        radius: CGFloat,
        dash: [CGFloat],
        degrees: Double
    ) {
        var ctx = context
        ctx.rotate(by: .degrees(degrees))
        ctx.stroke(
            Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)),
            with: .color(color),
            style: StrokeStyle(lineWidth: 10, lineCap: .butt, dash: dash)
        )
    }
}
