import AppKit

enum Paper {
    static func parchment(size: CGSize, scale: CGFloat) -> CGImage? {
        renderImage(size: size, scale: scale) { rect in
            NSGradient(colors: [
                NSColor(calibratedRed: 0.955, green: 0.915, blue: 0.820, alpha: 1),
                NSColor(calibratedRed: 0.885, green: 0.825, blue: 0.685, alpha: 1)
            ])?.draw(in: rect, angle: -90)

            var random = SeededRandom(seed: 71)
            for _ in 0..<420 {
                let alpha = random.range(0.015, 0.05)
                (random.next() > 0.4 ? NSColor(calibratedRed: 0.45, green: 0.33, blue: 0.16, alpha: 1)
                                     : NSColor.white)
                    .withAlphaComponent(alpha).setFill()
                CGRect(
                    x: random.range(0, Double(rect.width)),
                    y: random.range(0, Double(rect.height)),
                    width: random.range(6, 60),
                    height: random.range(0.5, 1.2)
                ).fill()
            }
            for _ in 0..<40 {
                let radius = random.range(24, 78)
                NSColor(calibratedRed: 0.55, green: 0.40, blue: 0.20, alpha: 1)
                    .withAlphaComponent(random.range(0.006, 0.018)).setFill()
                NSBezierPath(ovalIn: CGRect(
                    x: random.range(0, Double(rect.width)) - radius,
                    y: random.range(0, Double(rect.height)) - radius,
                    width: radius * 2,
                    height: radius * 1.3
                )).fill()
            }
            for _ in 0..<1800 {
                let alpha = random.range(0.008, 0.03)
                (random.next() > 0.35 ? NSColor(calibratedRed: 0.42, green: 0.31, blue: 0.15, alpha: 1)
                                      : NSColor.white)
                    .withAlphaComponent(alpha).setFill()
                CGRect(
                    x: random.range(0, Double(rect.width)),
                    y: random.range(0, Double(rect.height)),
                    width: random.range(0.5, 1.4),
                    height: random.range(0.5, 1.4)
                ).fill()
            }

            let edge: CGFloat = 26
            NSGradient(colors: [NSColor.black.withAlphaComponent(0.18), NSColor.black.withAlphaComponent(0)])?
                .draw(in: CGRect(x: 0, y: 0, width: edge, height: rect.height), angle: 0)
            NSGradient(colors: [NSColor.black.withAlphaComponent(0.18), NSColor.black.withAlphaComponent(0)])?
                .draw(in: CGRect(x: rect.width - edge, y: 0, width: edge, height: rect.height), angle: 180)
            NSGradient(colors: [NSColor.black.withAlphaComponent(0.12), NSColor.black.withAlphaComponent(0)])?
                .draw(in: CGRect(x: 0, y: rect.height - edge, width: rect.width, height: edge), angle: 90)

            NSGradient(colors: [
                NSColor.black.withAlphaComponent(0),
                NSColor.black.withAlphaComponent(0.12)
            ])?.draw(in: rect, relativeCenterPosition: .zero)
        }
    }
}

final class StatsOverlayView: FlippedView {
    var onClose: (() -> Void)?

    private let sheet: StatsSheetView
    private var keyMonitor: Any?

    init(frame frameRect: NSRect, store: LibraryStore, books: [Book]) {
        let stats = ReadingStatsBuilder.build(store: store, books: books)
        let size = CGSize(
            width: min(900, frameRect.width - 80),
            height: min(560, frameRect.height - 60)
        )
        sheet = StatsSheetView(frame: CGRect(origin: .zero, size: size), stats: stats)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor

        sheet.frame = CGRect(
            x: (frameRect.width - size.width) / 2,
            y: (frameRect.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        sheet.wantsLayer = true
        sheet.layer?.shadowColor = NSColor.black.cgColor
        sheet.layer?.shadowOpacity = 0.55
        sheet.layer?.shadowRadius = 30
        sheet.layer?.shadowOffset = CGSize(width: 0, height: 14)
        sheet.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(sheet)

        let close = NSButton(title: "×", target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.attributedTitle = NSAttributedString(
            string: "×",
            attributes: [
                .font: Theme.serif(22, weight: .medium),
                .foregroundColor: NSColor(calibratedRed: 0.30, green: 0.22, blue: 0.12, alpha: 1)
            ]
        )
        close.frame = CGRect(x: size.width - 48, y: 16, width: 28, height: 28)
        close.autoresizingMask = [.minXMargin]
        sheet.addSubview(close)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dismiss()
                return nil
            }
            return event
        }

        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !sheet.frame.contains(point) {
            dismiss()
        }
    }

    @objc private func closeTapped() {
        dismiss()
    }

    private func dismiss() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        onClose?()
    }
}

final class StatsSheetView: FlippedView {
    private let stats: ReadingStats
    private var parchment: CGImage?
    private var parchmentSize: CGSize = .zero

    private let ink = NSColor(calibratedRed: 0.23, green: 0.17, blue: 0.11, alpha: 1)
    private let fadedInk = NSColor(calibratedRed: 0.38, green: 0.30, blue: 0.20, alpha: 0.65)
    private let accent = NSColor(calibratedRed: 0.53, green: 0.38, blue: 0.14, alpha: 1)

    init(frame frameRect: NSRect, stats: ReadingStats) {
        self.stats = stats
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let scale = window?.backingScaleFactor ?? 2

        if parchment == nil || parchmentSize != rect.size {
            parchment = Paper.parchment(size: rect.size, scale: scale)
            parchmentSize = rect.size
        }
        if let parchment {
            context.draw(parchment, in: rect)
        } else {
            NSColor(calibratedRed: 0.94, green: 0.90, blue: 0.80, alpha: 1).setFill()
            rect.fill()
        }

        NSColor(calibratedRed: 0.46, green: 0.34, blue: 0.16, alpha: 0.55).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 16, dy: 16))
        border.lineWidth = 1.2
        border.stroke()
        NSColor(calibratedRed: 0.46, green: 0.34, blue: 0.16, alpha: 0.28).setStroke()
        let innerBorder = NSBezierPath(rect: rect.insetBy(dx: 21, dy: 21))
        innerBorder.lineWidth = 0.6
        innerBorder.stroke()

        let margin: CGFloat = 42
        drawText(
            "Статистика читання",
            in: CGRect(x: margin, y: 24, width: rect.width - margin * 2 - 60, height: 38),
            font: Theme.serif(28, weight: .semibold),
            color: ink,
            alignment: .left
        )
        drawText(
            "Твій читацький щоденник",
            in: CGRect(x: margin, y: 62, width: 400, height: 18),
            font: Theme.italicSerif(12),
            color: fadedInk,
            alignment: .left
        )

        guard stats.hasAny else {
            drawText(
                "Ще немає даних для статистики",
                in: CGRect(x: margin, y: rect.height * 0.42, width: rect.width - margin * 2, height: 40),
                font: Theme.serif(24, weight: .medium),
                color: ink
            )
            drawText(
                "Відкрий книгу і почитай кілька хвилин — сесії з'являться тут.",
                in: CGRect(x: margin, y: rect.height * 0.42 + 48, width: rect.width - margin * 2, height: 22),
                font: Theme.serif(13),
                color: fadedInk
            )
            return
        }

        drawStatsRow(rect: rect, margin: margin)
        drawChart(rect: rect, margin: margin)
        drawTopBooks(rect: rect, margin: margin)
        drawRecent(rect: rect, margin: margin)

        drawText(
            "Час рахується лише тоді, коли вікно активне і ти не відійшов від книги.",
            in: CGRect(x: margin, y: rect.height - 44, width: rect.width - margin * 2, height: 16),
            font: Theme.italicSerif(10.5),
            color: fadedInk,
            alignment: .left
        )
    }

    private func drawStatsRow(rect: CGRect, margin: CGFloat) {
        let values: [(String, String)] = [
            ("УСЬОГО", formatReadingDuration(stats.total)),
            ("СЬОГОДНІ", formatReadingDuration(stats.today)),
            ("ТИЖДЕНЬ", formatReadingDuration(stats.week)),
            ("СЕРІЯ", streakText(stats.streak))
        ]
        let columnWidth = (rect.width - margin * 2) / CGFloat(values.count)
        let y: CGFloat = 98

        for (index, value) in values.enumerated() {
            let x = margin + columnWidth * CGFloat(index)
            if index > 0 {
                NSColor(calibratedRed: 0.42, green: 0.31, blue: 0.16, alpha: 0.22).setFill()
                CGRect(x: x - 10, y: y + 2, width: 0.7, height: 54).fill()
            }
            drawText(
                value.0,
                in: CGRect(x: x, y: y, width: columnWidth - 20, height: 14),
                font: Theme.serif(9.5, weight: .medium),
                color: fadedInk,
                alignment: .left,
                kern: 1.5
            )
            drawText(
                value.1,
                in: CGRect(x: x, y: y + 20, width: columnWidth - 20, height: 34),
                font: Theme.serif(24, weight: .semibold),
                color: ink,
                alignment: .left
            )
        }

        NSColor(calibratedRed: 0.42, green: 0.31, blue: 0.16, alpha: 0.28).setFill()
        CGRect(x: margin, y: y + 66, width: rect.width - margin * 2, height: 0.7).fill()
    }

    private func drawChart(rect: CGRect, margin: CGFloat) {
        let chartRect = CGRect(x: margin, y: 210, width: (rect.width - margin * 2) * 0.56, height: 118)
        drawText(
            "ОСТАННІ 14 ДНІ",
            in: CGRect(x: margin, y: 184, width: chartRect.width, height: 14),
            font: Theme.serif(9.5, weight: .medium),
            color: fadedInk,
            alignment: .left,
            kern: 1.5
        )

        let maxValue = max(stats.days.map(\.seconds).max() ?? 0, 60)
        let count = max(1, stats.days.count)
        let slot = chartRect.width / CGFloat(count)
        let barWidth = max(8, slot - 8)

        NSColor(calibratedRed: 0.42, green: 0.31, blue: 0.16, alpha: 0.25).setFill()
        CGRect(x: chartRect.minX, y: chartRect.maxY, width: chartRect.width, height: 0.7).fill()

        let labelFont = Theme.serif(9)
        for (index, day) in stats.days.enumerated() {
            let x = chartRect.minX + slot * CGFloat(index) + (slot - barWidth) / 2
            let fraction = CGFloat(day.seconds / maxValue)
            let height = max(day.seconds > 0 ? 2 : 0, chartRect.height * fraction)
            let barRect = CGRect(x: x, y: chartRect.maxY - height, width: barWidth, height: height)
            let isToday = index == stats.days.count - 1
            let color = isToday ? accent : ink.withAlphaComponent(0.55)
            color.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()

            if index % 2 == 0 || isToday {
                let dayNumber = Calendar.current.component(.day, from: day.date)
                drawText(
                    "\(dayNumber)",
                    in: CGRect(x: x - 4, y: chartRect.maxY + 5, width: barWidth + 8, height: 12),
                    font: labelFont,
                    color: fadedInk
                )
            }
        }
    }

    private func drawTopBooks(rect: CGRect, margin: CGFloat) {
        let x = margin + (rect.width - margin * 2) * 0.62
        let width = rect.width - margin - x
        drawText(
            "НАЙБІЛЬШЕ ЧИТАЄШ",
            in: CGRect(x: x, y: 184, width: width, height: 14),
            font: Theme.serif(9.5, weight: .medium),
            color: fadedInk,
            alignment: .left,
            kern: 1.5
        )

        let maxSeconds = max(stats.topBooks.first?.seconds ?? 0, 1)
        var y: CGFloat = 208
        for book in stats.topBooks.prefix(4) {
            drawSingleLine(
                book.title,
                in: CGRect(x: x, y: y, width: width - 74, height: 16),
                font: Theme.serif(12, weight: .medium),
                color: ink
            )
            drawText(
                formatReadingDuration(book.seconds, compact: true),
                in: CGRect(x: x + width - 70, y: y + 1, width: 70, height: 14),
                font: Theme.serif(10.5),
                color: fadedInk,
                alignment: .right
            )
            let fraction = CGFloat(book.seconds / maxSeconds)
            NSColor(calibratedRed: 0.55, green: 0.42, blue: 0.20, alpha: 0.18).setFill()
            CGRect(x: x, y: y + 19, width: width, height: 3).fill()
            NSColor(calibratedRed: 0.55, green: 0.42, blue: 0.20, alpha: 0.75).setFill()
            CGRect(x: x, y: y + 19, width: width * fraction, height: 3).fill()
            y += 38
        }
    }

    private func drawRecent(rect: CGRect, margin: CGFloat) {
        let y: CGFloat = 366
        NSColor(calibratedRed: 0.42, green: 0.31, blue: 0.16, alpha: 0.28).setFill()
        CGRect(x: margin, y: y, width: rect.width - margin * 2, height: 0.7).fill()

        drawText(
            "ОСТАННІ СЕСІЇ",
            in: CGRect(x: margin, y: y + 12, width: 300, height: 14),
            font: Theme.serif(9.5, weight: .medium),
            color: fadedInk,
            alignment: .left,
            kern: 1.5
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "uk_UA")
        formatter.dateFormat = "d MMM"

        var rowY = y + 34
        for session in stats.recent.prefix(4) {
            drawText(
                formatter.string(from: session.startedAt),
                in: CGRect(x: margin, y: rowY + 1, width: 78, height: 14),
                font: Theme.serif(10.5),
                color: fadedInk,
                alignment: .left
            )
            drawSingleLine(
                session.bookTitle,
                in: CGRect(x: margin + 88, y: rowY, width: rect.width - margin * 2 - 250, height: 16),
                font: Theme.serif(12),
                color: ink
            )
            let pagesText = session.pagesTurned > 0 ? "\(session.pagesTurned) стор." : ""
            drawText(
                pagesText,
                in: CGRect(x: rect.width - margin - 190, y: rowY + 1, width: 90, height: 14),
                font: Theme.serif(10),
                color: fadedInk,
                alignment: .right
            )
            drawText(
                formatReadingDuration(session.duration, compact: true),
                in: CGRect(x: rect.width - margin - 94, y: rowY + 1, width: 94, height: 14),
                font: Theme.serif(10.5, weight: .medium),
                color: ink,
                alignment: .right
            )
            rowY += 27
        }
    }

    private func drawSingleLine(_ text: String, in rect: CGRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .left
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    private func streakText(_ streak: Int) -> String {
        let mod10 = streak % 10
        let mod100 = streak % 100
        if mod10 == 1 && mod100 != 11 { return "\(streak) день" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(streak) дні" }
        return "\(streak) днів"
    }
}
