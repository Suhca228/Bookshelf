import AppKit

enum CoverRenderer {
    static func cover(for book: Book, size: CGSize, scale: CGFloat) -> CGImage? {
        renderImage(size: size, scale: scale) { rect in
            let width = rect.width
            let height = rect.height
            let base = book.baseColor
            let lighter = base.blended(withFraction: 0.07, of: .white) ?? base
            let darker = base.blended(withFraction: 0.55, of: .black) ?? base

            NSGradient(colors: [lighter, base, darker])?.draw(in: rect, angle: -90)

            // Book cloth weave.
            var random = SeededRandom(seed: book.visualSeed &+ 5)
            for x in stride(from: 0.0, to: width, by: 3.0) {
                NSColor.white.withAlphaComponent(random.range(0.008, 0.028)).setFill()
                CGRect(x: x, y: 0, width: 1, height: height).fill()
            }
            for y in stride(from: 0.0, to: height, by: 3.0) {
                NSColor.black.withAlphaComponent(random.range(0.008, 0.03)).setFill()
                CGRect(x: 0, y: y, width: width, height: 1).fill()
            }

            // Gentle ageing: darker edges and a few light stains.
            for _ in 0..<7 {
                let stain = NSBezierPath(ovalIn: CGRect(
                    x: random.range(0, Double(width)) - width * 0.2,
                    y: random.range(0, Double(height)) - height * 0.1,
                    width: width * random.range(0.2, 0.55),
                    height: height * random.range(0.05, 0.14)
                ))
                NSColor.black.withAlphaComponent(random.range(0.012, 0.035)).setFill()
                stain.fill()
            }

            let gold = Theme.goldBright
            let goldDim = gold.withAlphaComponent(0.62)

            // Double gilt frame.
            let inset = width * 0.055
            let frameRect = CGRect(x: inset, y: inset, width: width - inset * 2, height: height - inset * 2)
            goldDim.setStroke()
            let outer = NSBezierPath(rect: frameRect)
            outer.lineWidth = max(0.9, width * 0.006)
            outer.stroke()

            let innerInset = inset + width * 0.022
            let innerRect = CGRect(x: innerInset, y: innerInset, width: width - innerInset * 2, height: height - innerInset * 2)
            gold.withAlphaComponent(0.38).setStroke()
            let inner = NSBezierPath(rect: innerRect)
            inner.lineWidth = 0.7
            inner.stroke()

            // Spine: darker leather strip with raised bands.
            let spineWidth = width * 0.075
            let spineRect = CGRect(x: 0, y: 0, width: spineWidth, height: height)
            NSGradient(colors: [
                NSColor.black.withAlphaComponent(0.42),
                NSColor.black.withAlphaComponent(0.05),
                NSColor.black.withAlphaComponent(0.45)
            ])?.draw(in: spineRect, angle: 0)
            goldDim.setFill()
            for fraction in [0.09, 0.91] {
                CGRect(x: 0, y: height * fraction - 2, width: spineWidth, height: 2.5).fill()
            }
            NSColor.white.withAlphaComponent(0.10).setFill()
            CGRect(x: spineWidth, y: 0, width: 1, height: height).fill()

            // Content is optically centred to the right of the spine.
            let contentCenter = spineWidth + (width - spineWidth) * 0.5
            let contentWidth = (width - spineWidth) * 0.80

            // Top ornament.
            let ornamentY = height * 0.155
            gold.setFill()
            let diamondSize = width * 0.035
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: contentCenter, y: ornamentY - diamondSize))
            diamond.line(to: NSPoint(x: contentCenter + diamondSize, y: ornamentY))
            diamond.line(to: NSPoint(x: contentCenter, y: ornamentY + diamondSize))
            diamond.line(to: NSPoint(x: contentCenter - diamondSize, y: ornamentY))
            diamond.close()
            diamond.fill()

            switch book.style {
            case 0:
                drawRule(center: contentCenter, y: ornamentY, width: contentWidth * 0.72, color: goldDim, thickness: 0.8)
            case 1:
                drawRule(center: contentCenter, y: ornamentY, width: contentWidth * 0.55, color: goldDim, thickness: 0.8)
                drawRule(center: contentCenter, y: ornamentY + 4, width: contentWidth * 0.55, color: goldDim.withAlphaComponent(0.3), thickness: 0.6)
            case 2:
                drawRule(center: contentCenter, y: ornamentY, width: contentWidth * 0.45, color: goldDim, thickness: 0.8)
                drawRule(center: contentCenter, y: height * 0.655, width: contentWidth * 0.45, color: goldDim, thickness: 0.8)
            default:
                drawRule(center: contentCenter, y: ornamentY, width: contentWidth * 0.30, color: goldDim, thickness: 0.8)
            }

            // Title.
            let titleTop = height * 0.205
            let titleRect = CGRect(
                x: contentCenter - contentWidth / 2,
                y: titleTop,
                width: contentWidth,
                height: height * 0.38
            )
            let titleFont = fittingSerifFont(
                book.title,
                maxWidth: contentWidth,
                maxHeight: titleRect.height,
                start: width * 0.135,
                minimum: width * 0.062,
                weight: .semibold,
                lineHeightFactor: 1.18
            )
            let titleShadow = NSShadow()
            titleShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            titleShadow.shadowBlurRadius = width * 0.012
            titleShadow.shadowOffset = CGSize(width: 0, height: width * 0.006)
            let titleParagraph = NSMutableParagraphStyle()
            titleParagraph.alignment = .center
            titleParagraph.lineBreakMode = .byWordWrapping
            titleParagraph.minimumLineHeight = titleFont.pointSize * 1.18
            titleParagraph.maximumLineHeight = titleFont.pointSize * 1.18
            (book.title as NSString).draw(
                with: titleRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [
                    .font: titleFont,
                    .foregroundColor: Theme.cream,
                    .paragraphStyle: titleParagraph,
                    .shadow: titleShadow
                ]
            )

            // Author.
            let authorY = height * 0.705
            let authorText = book.author.uppercased()
            let authorKern = width * 0.005
            let authorFont = fittingSingleLineFont(
                authorText,
                maxWidth: contentWidth,
                start: width * 0.058,
                minimum: width * 0.028,
                weight: .regular,
                kern: authorKern
            )
            drawText(
                authorText,
                in: CGRect(x: contentCenter - contentWidth / 2, y: authorY, width: contentWidth, height: height * 0.09),
                font: authorFont,
                color: gold.withAlphaComponent(0.95),
                kern: authorKern
            )

            // Publisher imprint.
            drawRule(center: contentCenter, y: height * 0.845, width: contentWidth * 0.22, color: goldDim.withAlphaComponent(0.7), thickness: 0.6)
            drawText(
                "BOOKSHELF",
                in: CGRect(x: contentCenter - contentWidth / 2, y: height * 0.868, width: contentWidth, height: height * 0.05),
                font: Theme.serif(width * 0.034, weight: .medium),
                color: gold.withAlphaComponent(0.55),
                kern: width * 0.012
            )

            // Glossy sheen across the cloth.
            NSGradient(colors: [
                NSColor.white.withAlphaComponent(0.07),
                NSColor.white.withAlphaComponent(0.0),
                NSColor.black.withAlphaComponent(0.22)
            ])?.draw(in: rect, angle: -62)

            // Inner shadow at the edges.
            let edge = width * 0.05
            NSGradient(colors: [NSColor.black.withAlphaComponent(0.35), NSColor.black.withAlphaComponent(0)])?
                .draw(in: CGRect(x: 0, y: 0, width: edge, height: height), angle: 0)
            NSGradient(colors: [NSColor.black.withAlphaComponent(0.28), NSColor.black.withAlphaComponent(0)])?
                .draw(in: CGRect(x: width - edge, y: 0, width: edge, height: height), angle: 180)
            NSGradient(colors: [NSColor.black.withAlphaComponent(0.22), NSColor.black.withAlphaComponent(0)])?
                .draw(in: CGRect(x: 0, y: height - edge, width: width, height: edge), angle: 90)

            NSColor.white.withAlphaComponent(0.12).setFill()
            CGRect(x: width - 1, y: 0, width: 1, height: height).fill()
        }
    }

    private static func drawRule(center: CGFloat, y: CGFloat, width: CGFloat, color: NSColor, thickness: CGFloat) {
        color.setFill()
        CGRect(x: center - width / 2, y: y, width: width, height: thickness).fill()
    }
}
