import AppKit

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

enum Theme {
    static let cream = NSColor(calibratedRed: 0.94, green: 0.89, blue: 0.79, alpha: 1)
    static let parchment = NSColor(calibratedRed: 0.93, green: 0.88, blue: 0.76, alpha: 1)
    static let gold = NSColor(calibratedRed: 0.80, green: 0.64, blue: 0.34, alpha: 1)
    static let goldBright = NSColor(calibratedRed: 0.93, green: 0.80, blue: 0.52, alpha: 1)
    static let ink = NSColor(calibratedRed: 0.20, green: 0.15, blue: 0.11, alpha: 1)
    static let deepBrown = NSColor(calibratedRed: 0.16, green: 0.10, blue: 0.06, alpha: 1)

    static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.serif),
           let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return base
    }

    static func italicSerif(_ size: CGFloat) -> NSFont {
        let base = serif(size)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

// MARK: - Image rendering

func renderImage(size: CGSize, scale: CGFloat, flipped: Bool = true, draw: (CGRect) -> Void) -> CGImage? {
    let pixelWidth = Int((size.width * scale).rounded())
    let pixelHeight = Int((size.height * scale).rounded())
    guard pixelWidth > 0, pixelHeight > 0 else { return nil }
    guard let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high
    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: flipped)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    draw(CGRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()

    guard let rendered = context.makeImage() else { return nil }
    guard flipped else { return rendered }

    // A flipped NSGraphicsContext writes the bitmap mirrored relative to CGImage's
    // row order; flip it back once so layer.contents and CGContext.draw display it upright.
    guard let flipContext = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return rendered }
    flipContext.translateBy(x: 0, y: CGFloat(pixelHeight))
    flipContext.scaleBy(x: 1, y: -1)
    flipContext.draw(rendered, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    return flipContext.makeImage() ?? rendered
}

extension NSImage {
    var cgImageRepresentation: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

// MARK: - Text helpers

func drawText(
    _ string: String,
    in rect: CGRect,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment = .center,
    lineHeight: CGFloat? = nil,
    kern: CGFloat = 0
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byWordWrapping
    if let lineHeight {
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
    }
    var attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    if kern != 0 { attributes[.kern] = kern }
    (string as NSString).draw(
        with: rect,
        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
        attributes: attributes
    )
}

func measuredHeight(
    _ string: String,
    width: CGFloat,
    font: NSFont,
    lineHeight: CGFloat? = nil,
    kern: CGFloat = 0
) -> CGFloat {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    if let lineHeight {
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
    }
    var attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .paragraphStyle: paragraph
    ]
    if kern != 0 { attributes[.kern] = kern }
    let bounds = (string as NSString).boundingRect(
        with: CGSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin],
        attributes: attributes
    )
    return ceil(bounds.height)
}

func fittingSerifFont(
    _ text: String,
    maxWidth: CGFloat,
    maxHeight: CGFloat,
    start: CGFloat,
    minimum: CGFloat,
    weight: NSFont.Weight = .semibold,
    lineHeightFactor: CGFloat = 1.12
) -> NSFont {
    var size = start
    while size > minimum {
        let font = Theme.serif(size, weight: weight)
        let longestWord = text
            .split(separator: " ")
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let height = measuredHeight(text, width: maxWidth, font: font, lineHeight: size * lineHeightFactor)
        if longestWord <= maxWidth, height <= maxHeight { return font }
        size -= 0.5
    }
    return Theme.serif(minimum, weight: weight)
}

func fittingSingleLineFont(
    _ text: String,
    maxWidth: CGFloat,
    start: CGFloat,
    minimum: CGFloat,
    weight: NSFont.Weight = .regular,
    kern: CGFloat = 0
) -> NSFont {
    var size = start
    while size > minimum {
        let font = Theme.serif(size, weight: weight)
        let width = (text as NSString).size(withAttributes: [.font: font, .kern: kern]).width
        if width <= maxWidth { return font }
        size -= 0.5
    }
    return Theme.serif(minimum, weight: weight)
}

// MARK: - Deterministic randomness

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6364136223846793005 &+ 1442695040888963407
        if state == 0 { state = 0x9E3779B97F4A7C15 }
    }

    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000.0
    }

    mutating func range(_ lower: Double, _ upper: Double) -> Double {
        lower + (upper - lower) * next()
    }
}
