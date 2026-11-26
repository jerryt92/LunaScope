import CoreText
import UIKit

enum CameraAlbumRawBadge {
    static var accessibilityTitle: LocalizedStringResource { "album.badge.raw" }
    private static let title = "RAW"
    private static let cornerRadius: CGFloat = 4.5
    static let thumbnail = makeImage(
        width: 28,
        height: 14,
        fontSize: 9,
        backgroundColor: UIColor.black.withAlphaComponent(0.55)
    ).withRenderingMode(.alwaysOriginal)
    static let preview = makeImage(width: 32, height: 18, fontSize: 11)

    private static func makeImage(
        width: CGFloat,
        height: CGFloat,
        fontSize: CGFloat,
        backgroundColor: UIColor? = nil
    ) -> UIImage {
        let size = CGSize(width: width, height: height)
        let outline = UIBezierPath(
            roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: cornerRadius - 0.5
        )
        let text = NSAttributedString(string: title, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: UIColor.white
        ])
        let line = CTLineCreateWithAttributedString(text as CFAttributedString)
        let glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

        return UIGraphicsImageRenderer(size: size).image { renderer in
            if let backgroundColor {
                backgroundColor.setFill()
                outline.fill()
            }
            UIColor.white.setStroke()
            outline.lineWidth = 1
            outline.stroke()

            // Core Text 的坐标向上递增，基线位置按可见字形的中心计算。
            let context = renderer.cgContext
            context.translateBy(x: 0, y: height)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: width / 2 - glyphBounds.midX, y: height / 2 - glyphBounds.midY)
            CTLineDraw(line, context)
        }
    }
}
