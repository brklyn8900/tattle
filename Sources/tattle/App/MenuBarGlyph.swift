import AppKit

/// The menu bar eye. It is drawn here, not loaded from a file, so that it is sharp on any
/// display and takes the menu bar's colour as a template image. Its shapes are the eye of
/// `Resources/AppIcon.svg` in one colour, in the same 1024-unit square.
@MainActor
enum MenuBarGlyph {
    static let eye = image(slashed: false)
    /// Struck through, for a Tattle that failed to start.
    static let slashedEye = image(slashed: true)

    private static func image(slashed: Bool) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: rect.width / 1024, y: rect.height / 1024)
            context.setFillColor(.black)
            context.setStrokeColor(.black)

            // The even-odd fill leaves the iris as a ring-shaped hole around the pupil.
            let outline = CGMutablePath()
            outline.move(to: CGPoint(x: 60, y: 512))
            outline.addQuadCurve(to: CGPoint(x: 964, y: 512), control: CGPoint(x: 512, y: 132))
            outline.addQuadCurve(to: CGPoint(x: 60, y: 512), control: CGPoint(x: 512, y: 892))
            outline.closeSubpath()
            outline.addEllipse(in: CGRect(x: 352, y: 352, width: 320, height: 320))
            context.addPath(outline)
            context.fillPath(using: .evenOdd)
            context.fillEllipse(in: CGRect(x: 432, y: 432, width: 160, height: 160))

            if slashed {
                let slash = CGMutablePath()
                slash.move(to: CGPoint(x: 150, y: 110))
                slash.addLine(to: CGPoint(x: 914, y: 874))
                context.setLineCap(.round)
                // A wider clear stroke first, so a gap separates the slash from the eye.
                context.setBlendMode(.clear)
                context.setLineWidth(130)
                context.addPath(slash)
                context.strokePath()
                context.setBlendMode(.normal)
                context.setLineWidth(72)
                context.addPath(slash)
                context.strokePath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
