import AppKit

final class ShelfView: NSView {
    var books: [Book] = [] {
        didSet { needsLayout = true }
    }
    var onOpenBook: ((Book, CGRect) -> Void)?
    var onBookMenu: ((Book) -> NSMenu?)?
    var emptyTitle: String = "Полиця порожня" {
        didSet { needsDisplay = true }
    }
    var emptyHint: String = "Додайте PDF або DJVU у папку бібліотеки й натисніть ⟳" {
        didSet { needsDisplay = true }
    }

    private var bookLayers: [String: CALayer] = [:]
    private var bookFrames: [String: CGRect] = [:]
    private var effectiveLeans: [String: CGFloat] = [:]
    private var bookShelves: [String: Int] = [:]
    private var hoveredBookID: String?
    private var wallImage: CGImage?
    private var wallImageSize: CGSize = .zero
    private var trackingArea: NSTrackingArea?
    private var shelfCount = 3
    private var currentMetrics: Metrics?
    var viewportHeight: CGFloat = 0 {
        didSet {
            if abs(oldValue - viewportHeight) > 0.5 { needsLayout = true }
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Layout

    private struct Metrics {
        let openings: [CGRect]
        let boardThickness: CGFloat
        let boardInset: CGFloat
    }

    private let boardThickness: CGFloat = 24
    private let boardInset: CGFloat = 26
    private let topMargin: CGFloat = 6
    private let bottomMargin: CGFloat = 22

    private func metrics(width: CGFloat, openingHeight: CGFloat, shelfCount: Int) -> Metrics {
        var openings: [CGRect] = []
        var y = topMargin
        for _ in 0..<shelfCount {
            openings.append(CGRect(
                x: boardInset + 22,
                y: y,
                width: width - (boardInset + 22) * 2,
                height: openingHeight
            ))
            y += openingHeight + boardThickness
        }
        return Metrics(openings: openings, boardThickness: boardThickness, boardInset: boardInset)
    }

    private func openingHeight(for viewport: CGFloat) -> CGFloat {
        let usable = viewport - topMargin - bottomMargin - 3 * boardThickness
        return max(120, floor(usable / 3))
    }

    func contentHeight(forWidth width: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard width > 0, viewportHeight > 0 else { return viewportHeight }
        let opening = openingHeight(for: viewportHeight)
        let count = shelvesNeeded(width: width, opening: opening)
        return max(
            viewportHeight,
            topMargin + bottomMargin + CGFloat(count) * (opening + boardThickness)
        )
    }

    override func layout() {
        super.layout()
        rebuildBooks()
    }

    private func rebuildBooks() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let viewport = viewportHeight > 0 ? viewportHeight : max(bounds.height, 600)
        let opening = openingHeight(for: viewport)
        shelfCount = shelvesNeeded(width: bounds.width, opening: opening)
        let metrics = self.metrics(width: bounds.width, openingHeight: opening, shelfCount: shelfCount)
        currentMetrics = metrics

        for layer in bookLayers.values { layer.removeFromSuperlayer() }
        bookLayers.removeAll()
        bookFrames.removeAll()
        effectiveLeans.removeAll()
        bookShelves.removeAll()

        let limit = perShelfLimit(for: shelfCount)
        var shelfIndex = 0
        var onShelf = 0
        var x = metrics.openings[0].minX + 8
        var baseline = metrics.openings[0].maxY
        var maxRight = metrics.openings[0].maxX - 4

        for book in books {
            var opening = metrics.openings[min(shelfIndex, metrics.openings.count - 1)]
            var height = opening.height * book.heightFactor
            var width = height * book.coverAspect

            let limitReached = limit.map { onShelf >= $0 } ?? false
            if (limitReached || x + width > maxRight), shelfIndex < metrics.openings.count - 1 {
                shelfIndex += 1
                opening = metrics.openings[shelfIndex]
                height = opening.height * book.heightFactor
                width = height * book.coverAspect
                x = opening.minX + 8
                baseline = opening.maxY
                maxRight = opening.maxX - 4
                onShelf = 0
            }

            if x + width > maxRight {
                // Only reachable with an extreme number of books. Keep the book
                // inside the shelf and preserve its proportions instead of squashing it.
                let available = maxRight - x
                let scale = max(0.2, available / width)
                width *= scale
                height *= scale
            }

            let frame = CGRect(x: x, y: baseline - height, width: width, height: height)
            bookFrames[book.id] = frame
            bookShelves[book.id] = shelfIndex

            onShelf += 1
            if book.lean > 0.02 {
                // The tipped top edge must rest against the next book.
                x += width + sin(book.lean) * height + 2
            } else {
                x += width + 14 + (book.lean != 0 ? abs(sin(book.lean)) * height + 6 : 0)
            }
        }

        for book in books {
            guard let frame = bookFrames[book.id] else { continue }
            let lean = supportedLean(for: book)
            effectiveLeans[book.id] = lean

            let layer = BookLayers.make(book: book, size: frame.size, scale: scale)
            layer.position = CGPoint(x: frame.midX, y: frame.maxY)
            if lean != 0 {
                layer.transform = CATransform3DMakeRotation(lean, 0, 0, 1)
            }
            self.layer?.addSublayer(layer)
            bookLayers[book.id] = layer
        }

        needsDisplay = true
    }

    private func shelvesNeeded(width: CGFloat, opening: CGFloat) -> Int {
        guard !books.isEmpty else { return 3 }
        let maximumShelves = 64
        for count in 3...maximumShelves {
            if layoutFits(width: width, opening: opening, shelfCount: count) {
                return count
            }
        }
        return maximumShelves
    }

    private func layoutFits(width: CGFloat, opening: CGFloat, shelfCount: Int) -> Bool {
        let metrics = self.metrics(width: width, openingHeight: opening, shelfCount: shelfCount)
        let limit = perShelfLimit(for: shelfCount)
        var shelf = 0
        var onShelf = 0
        var x = metrics.openings[0].minX + 8
        var maxRight = metrics.openings[0].maxX - 4

        for book in books {
            var openingRect = metrics.openings[shelf]
            var height = openingRect.height * book.heightFactor
            var width = height * book.coverAspect
            let limitReached = limit.map { onShelf >= $0 } ?? false

            if limitReached || x + width > maxRight {
                shelf += 1
                if shelf >= shelfCount { return false }
                openingRect = metrics.openings[shelf]
                height = openingRect.height * book.heightFactor
                width = height * book.coverAspect
                x = openingRect.minX + 8
                maxRight = openingRect.maxX - 4
                onShelf = 0
            }

            if x + width > maxRight { return false }

            onShelf += 1
            if book.lean > 0.02 {
                x += width + sin(book.lean) * height + 2
            } else {
                x += width + 14 + (book.lean != 0 ? abs(sin(book.lean)) * height + 6 : 0)
            }
        }
        return true
    }

    /// For larger libraries, spread books evenly instead of filling the first
    /// shelves to the brim and leaving the last one almost empty.
    private func perShelfLimit(for shelfCount: Int) -> Int? {
        guard books.count >= 12, shelfCount > 0 else { return nil }
        return Int(ceil(Double(books.count) / Double(shelfCount)))
    }

    /// A leaning book may only lean if there is a neighbour to rest against.
    private func supportedLean(for book: Book) -> CGFloat {
        guard book.lean != 0, let frame = bookFrames[book.id], let shelf = bookShelves[book.id] else { return 0 }
        let neighbours = books.filter { other in
            other.id != book.id && bookShelves[other.id] == shelf
        }
        for other in neighbours {
            guard let otherFrame = bookFrames[other.id] else { continue }
            if book.lean > 0 {
                // Top tips to the right: needs a book on the right.
                if otherFrame.minX >= frame.maxX - 2, otherFrame.minX - frame.maxX < 42 {
                    return book.lean
                }
            } else {
                if otherFrame.maxX <= frame.minX + 2, frame.minX - otherFrame.maxX < 42 {
                    return book.lean
                }
            }
        }
        return 0
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let scale = window?.backingScaleFactor ?? 2

        if wallImage == nil || wallImageSize != rect.size {
            wallImage = Wood.wall(size: rect.size, scale: scale)
            wallImageSize = rect.size
        }
        if let wallImage {
            context.draw(wallImage, in: rect)
        } else {
            NSColor(calibratedRed: 0.5, green: 0.33, blue: 0.19, alpha: 1).setFill()
            rect.fill()
        }

        // Bookcase side panels frame the composition.
        let panelWidth: CGFloat = 14
        for isLeft in [true, false] {
            let panelRect = CGRect(
                x: isLeft ? 0 : rect.width - panelWidth,
                y: 0,
                width: panelWidth,
                height: rect.height
            )
            NSGradient(colors: [
                NSColor(calibratedRed: 0.26, green: 0.16, blue: 0.09, alpha: 1),
                NSColor(calibratedRed: 0.14, green: 0.08, blue: 0.04, alpha: 1)
            ])?.draw(in: panelRect, angle: isLeft ? 0 : 180)
            NSColor(calibratedRed: 0.72, green: 0.52, blue: 0.31, alpha: 0.32).setFill()
            CGRect(
                x: isLeft ? panelWidth - 1 : rect.width - panelWidth,
                y: 0,
                width: 1,
                height: rect.height
            ).fill()
            NSGradient(colors: [
                NSColor.black.withAlphaComponent(0.35),
                NSColor.black.withAlphaComponent(0)
            ])?.draw(
                in: CGRect(
                    x: isLeft ? panelWidth : rect.width - panelWidth - 16,
                    y: 0,
                    width: 16,
                    height: rect.height
                ),
                angle: isLeft ? 180 : 0
            )
        }

        // Baseboard along the bottom.
        let baseHeight: CGFloat = 16
        let baseRect = CGRect(x: 0, y: rect.height - baseHeight, width: rect.width, height: baseHeight)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.15, alpha: 1),
            NSColor(calibratedRed: 0.20, green: 0.12, blue: 0.06, alpha: 1)
        ])?.draw(in: baseRect, angle: -90)
        NSColor(calibratedRed: 0.72, green: 0.52, blue: 0.31, alpha: 0.5).setFill()
        CGRect(x: 0, y: baseRect.minY, width: rect.width, height: 1).fill()
        NSGradient(colors: [
            NSColor.black.withAlphaComponent(0.4),
            NSColor.black.withAlphaComponent(0)
        ])?.draw(in: CGRect(x: 0, y: baseRect.minY - 10, width: rect.width, height: 10), angle: -90)

        let metrics = currentMetrics ?? self.metrics(
            width: rect.width,
            openingHeight: openingHeight(for: viewportHeight > 0 ? viewportHeight : rect.height),
            shelfCount: shelfCount
        )

        // Shelves.
        for opening in metrics.openings {
            let boardRect = CGRect(
                x: metrics.boardInset,
                y: opening.maxY,
                width: rect.width - metrics.boardInset * 2,
                height: metrics.boardThickness
            )

            // Shadow cast by the shelf onto the wall below it.
            NSGradient(colors: [
                NSColor.black.withAlphaComponent(0.42),
                NSColor.black.withAlphaComponent(0.0)
            ])?.draw(
                in: CGRect(x: boardRect.minX + 6, y: boardRect.maxY, width: boardRect.width - 12, height: 20),
                angle: -90
            )

            // Board face.
            NSGradient(colors: [
                NSColor(calibratedRed: 0.64, green: 0.44, blue: 0.26, alpha: 1),
                NSColor(calibratedRed: 0.38, green: 0.24, blue: 0.13, alpha: 1)
            ])?.draw(in: boardRect, angle: -90)

            // Top edge highlight — this is what makes it read as a plank.
            NSColor(calibratedRed: 0.86, green: 0.66, blue: 0.43, alpha: 0.85).setFill()
            CGRect(x: boardRect.minX, y: boardRect.minY, width: boardRect.width, height: 2).fill()
            NSColor.white.withAlphaComponent(0.18).setFill()
            CGRect(x: boardRect.minX, y: boardRect.minY + 2, width: boardRect.width, height: 1).fill()

            // Bottom lip.
            NSColor(calibratedRed: 0.22, green: 0.13, blue: 0.07, alpha: 1).setFill()
            CGRect(x: boardRect.minX, y: boardRect.maxY - 2, width: boardRect.width, height: 2).fill()

            // Soft end caps.
            NSGradient(colors: [
                NSColor.black.withAlphaComponent(0.30),
                NSColor.black.withAlphaComponent(0)
            ])?.draw(in: CGRect(x: boardRect.minX, y: boardRect.minY, width: 14, height: boardRect.height), angle: 0)
            NSGradient(colors: [
                NSColor.black.withAlphaComponent(0.30),
                NSColor.black.withAlphaComponent(0)
            ])?.draw(in: CGRect(x: boardRect.maxX - 14, y: boardRect.minY, width: 14, height: boardRect.height), angle: 180)
        }

        // Contact shadows underneath the books.
        for (_, frame) in bookFrames {
            drawContactShadow(for: frame)
        }

        if books.isEmpty {
            let opening = metrics.openings[min(1, metrics.openings.count - 1)]
            let centerY = opening.midY
            Theme.gold.withAlphaComponent(0.55).setFill()
            CGRect(x: rect.midX - 34, y: centerY - 58, width: 68, height: 0.8).fill()
            drawText(
                emptyTitle,
                in: CGRect(x: 40, y: centerY - 44, width: rect.width - 80, height: 44),
                font: Theme.serif(30, weight: .semibold),
                color: Theme.cream.withAlphaComponent(0.86)
            )
            drawText(
                emptyHint,
                in: CGRect(x: 60, y: centerY + 8, width: rect.width - 120, height: 22),
                font: Theme.serif(13),
                color: Theme.cream.withAlphaComponent(0.58)
            )
        }

        // Inner shadow at the top of the shelf area, under the header.
        NSGradient(colors: [
            NSColor.black.withAlphaComponent(0.35),
            NSColor.black.withAlphaComponent(0)
        ])?.draw(in: CGRect(x: 0, y: 0, width: rect.width, height: 26), angle: -90)
    }

    private func drawContactShadow(for frame: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let shadowRect = CGRect(
            x: frame.minX - 6,
            y: frame.maxY - 7,
            width: frame.width + 16,
            height: 16
        )
        let colors = [
            NSColor.black.withAlphaComponent(0.55).cgColor,
            NSColor.black.withAlphaComponent(0.22).cgColor,
            NSColor.black.withAlphaComponent(0.0).cgColor
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0.0, 0.55, 1.0]
        ) else { return }

        context.saveGState()
        context.addEllipse(in: shadowRect)
        context.clip()
        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: shadowRect.midX, y: shadowRect.midY),
            startRadius: 0,
            endCenter: CGPoint(x: shadowRect.midX, y: shadowRect.midY),
            endRadius: shadowRect.width * 0.5,
            options: []
        )
        context.restoreGState()
    }

    // MARK: - Interaction

    func frame(for bookID: String) -> CGRect? {
        bookFrames[bookID]
    }

    func setBookHidden(_ bookID: String, hidden: Bool) {
        bookLayers[bookID]?.isHidden = hidden
    }

    private func book(at point: CGPoint) -> Book? {
        for book in books.reversed() {
            guard let frame = bookFrames[book.id] else { continue }
            if frame.insetBy(dx: -2, dy: -4).contains(point) {
                return book
            }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let book = book(at: point)
        if book?.id != hoveredBookID {
            if let hoveredBookID, let layer = bookLayers[hoveredBookID] {
                BookLayers.applyHover(false, to: layer, lean: effectiveLeans[hoveredBookID] ?? 0)
            }
            hoveredBookID = book?.id
            if let book, let layer = bookLayers[book.id] {
                BookLayers.applyHover(true, to: layer, lean: effectiveLeans[book.id] ?? 0)
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let hoveredBookID, let layer = bookLayers[hoveredBookID] {
            BookLayers.applyHover(false, to: layer, lean: effectiveLeans[hoveredBookID] ?? 0)
        }
        hoveredBookID = nil
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let book = book(at: point), let frame = bookFrames[book.id] else { return }
        onOpenBook?(book, frame)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let book = book(at: point) else { return nil }
        return onBookMenu?(book)
    }
}
