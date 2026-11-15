import AppKit

enum BookLayers {
    static func make(book: Book, size: CGSize, scale: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.anchorPoint = CGPoint(x: 0.5, y: 1.0)
        layer.contentsGravity = .resize
        layer.contentsScale = scale
        layer.contents = BookCover.image(for: book, size: size, scale: scale)
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.32
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 1, height: 2)
        layer.zPosition = 1
        layer.masksToBounds = false

        // Slivers of the page block peeking out from behind the cover.
        let pages = CALayer()
        pages.frame = CGRect(x: size.width - 1, y: 1.5, width: 2.6, height: size.height - 2)
        pages.backgroundColor = NSColor(calibratedRed: 0.86, green: 0.81, blue: 0.69, alpha: 1).cgColor
        pages.zPosition = -1
        layer.addSublayer(pages)

        let pageEdgeShadow = CALayer()
        pageEdgeShadow.frame = CGRect(x: size.width + 1.6, y: 1.5, width: 1, height: size.height - 2)
        pageEdgeShadow.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        pageEdgeShadow.zPosition = -1
        layer.addSublayer(pageEdgeShadow)

        let bottomPages = CALayer()
        bottomPages.frame = CGRect(x: 1, y: size.height - 1, width: size.width - 1.5, height: 2)
        bottomPages.backgroundColor = NSColor(calibratedRed: 0.80, green: 0.75, blue: 0.63, alpha: 1).cgColor
        bottomPages.zPosition = -1
        layer.addSublayer(bottomPages)

        return layer
    }

    static func applyHover(_ hovered: Bool, to layer: CALayer, lean: CGFloat) {
        var transform = CATransform3DMakeScale(hovered ? 1.035 : 1.0, hovered ? 1.035 : 1.0, 1)
        if lean != 0 {
            transform = CATransform3DConcat(transform, CATransform3DMakeRotation(lean, 0, 0, 1))
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer.transform = transform
        layer.zPosition = hovered ? 40 : 1
        layer.shadowOpacity = hovered ? 0.5 : 0.32
        layer.shadowRadius = hovered ? 13 : 6
        layer.shadowOffset = CGSize(width: hovered ? 4 : 1, height: hovered ? 6 : 2)
        CATransaction.commit()
    }
}
