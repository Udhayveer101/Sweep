import SwiftUI
import SweepCore

/// The Sweep mark as a SwiftUI shape, drawn from the same `SweepMark` geometry that generates
/// the app icon. So the in-app logo and the Dock icon are the same mark by construction.
struct SweepMarkShape: Shape {
    /// Uses the coarser small-size cut, matching what the icon does below 32 pt.
    var small = false

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let (block, dot) = SweepMark.paths(in: square, small: small)
        var path = Path(block)
        path.addPath(Path(dot))
        return path
    }
}

/// The full lockup: the mark on its brand plate. Used where the app introduces itself.
struct BrandMark: View {
    var size: CGFloat = 96

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [Color(.sRGB, red: SweepMark.Colors.lightTop.r / 255,
                           green: SweepMark.Colors.lightTop.g / 255,
                           blue: SweepMark.Colors.lightTop.b / 255, opacity: 1),
                     Color(.sRGB, red: SweepMark.Colors.lightBottom.r / 255,
                           green: SweepMark.Colors.lightBottom.g / 255,
                           blue: SweepMark.Colors.lightBottom.b / 255, opacity: 1)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        SweepPlate()
            .fill(gradient)
            .overlay { SweepMarkShape().fill(.white) }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The icon plate. The same superellipse the generated icon uses, so the in-app art matches the
/// Dock icon's silhouette exactly rather than approximating it with a rounded rectangle.
struct SweepPlate: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        return Path(SweepMark.squircle(square, n: 5.0, steps: 360))
    }
}
