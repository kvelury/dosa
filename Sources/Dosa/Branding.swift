import SwiftUI
import AppKit

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
