import CoreGraphics
import Foundation

/// The Sweep mark, as geometry.
///
/// **The mark — "Lift".** A block of occupied space with a rounded notch taken out of one corner,
/// and a single element departing from it. The reclaimed space is genuine negative space, so the
/// silhouette itself carries the idea, and the departing dot supplies intent and motion. It
/// deliberately avoids the category's clichés — broom, bin, sparkle, shield, gauge.
///
/// This lives in `SweepCore` so the app and the icon generator draw from one definition rather
/// than from two drifting copies of the same numbers.
public enum SweepMark {

    // Proportions are fractions of the canvas, so every size renders identically.
    static let blockInsetX: CGFloat = 0.205
    static let blockInsetY: CGFloat = 0.235
    static let notchRadius: CGFloat = 0.200
    static let notchOffset: CGFloat = 0.045
    static let dotRadius: CGFloat = 0.076
    static let dotOffset: CGFloat = 0.040

    /// Optical centring. The departing dot adds visual mass up and to the right, so the group is
    /// nudged down-left; geometric centring would look off-balance.
    static let opticalShift = CGPoint(x: -0.012, y: -0.010)

    /// Continuous-curve superellipse. A circular-arc rounded rectangle visibly kinks where the
    /// arc meets the straight edge at icon sizes; a superellipse does not.
    public static func squircle(_ rect: CGRect, n: CGFloat = 5.0, steps: Int = 1440) -> CGPath {
        let path = CGMutablePath()
        let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
        for i in 0...steps {
            let t = Double(i) / Double(steps) * 2 * .pi
            let ct = cos(t), st = sin(t)
            let x = cx + a * CGFloat(copysign(pow(abs(ct), 2.0 / Double(n)), ct))
            let y = cy + b * CGFloat(copysign(pow(abs(st), 2.0 / Double(n)), st))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        return path
    }

    static func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
    }

    /// The two paths composing the mark: the notched block, and the departing dot.
    ///
    /// `small` selects a deliberately coarser cut for 16 and 32 pt. Measured on the proof sheet:
    /// at 16 pt the standard dot renders as a 1 px smudge and vanishes into antialiasing. The
    /// `.icns` format carries a separate drawing per size precisely so this can be corrected.
    public static func paths(in rect: CGRect, small: Bool = false) -> (block: CGPath, dot: CGPath) {
        let s = rect.width
        let insetX = small ? blockInsetX - 0.02 : blockInsetX
        let insetY = small ? blockInsetY - 0.03 : blockInsetY
        let nRadius = small ? notchRadius + 0.02 : notchRadius
        let dRadius = small ? 0.105 : dotRadius
        let dOffset = small ? 0.055 : dotOffset

        var shift = CGAffineTransform(translationX: opticalShift.x * s, y: opticalShift.y * s)
        let block = rect.insetBy(dx: s * insetX, dy: s * insetY)
        let notchCentre = CGPoint(x: block.maxX + s * notchOffset, y: block.maxY + s * notchOffset)
        // True boolean subtraction: an even-odd fill would leave a lens-shaped artifact where the
        // circle overlaps the block instead of removing a clean notch.
        let notched = squircle(block, n: 4.0).subtracting(circle(notchCentre, s * nRadius))
        let dot = circle(CGPoint(x: block.maxX + s * dOffset, y: block.maxY + s * dOffset), s * dRadius)
        return (notched.copy(using: &shift)!, dot.copy(using: &shift)!)
    }

    /// Brand colours. Indigo→violet: cool and premium, and deliberately clear of the greens and
    /// blues that saturate the utility category.
    public enum Colors {
        public static let lightTop = (r: 108.0, g: 104.0, b: 255.0)
        public static let lightBottom = (r: 58.0, g: 44.0, b: 178.0)
        public static let darkTop = (r: 78.0, g: 74.0, b: 205.0)
        public static let darkBottom = (r: 32.0, g: 24.0, b: 104.0)
    }
}
