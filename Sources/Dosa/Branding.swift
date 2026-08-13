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
