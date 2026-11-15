import AppKit

final class LibrarySettingsOverlayView: FlippedView {
    var onChoose: (() -> Void)?
    var onScan: (() -> Void)?
    var onClose: (() -> Void)?

    private let rootURL: URL?
    private let bookCount: Int
    private let categoryCount: Int
    private let isOnboarding: Bool

    private let sheet: LibrarySettingsSheetView
    private let chooseButton = NSButton()
    private let scanButton = NSButton()
    private let closeButton = NSButton()
    private var keyMonitor: Any?

    private static let sheetSize = CGSize(width: 760, height: 430)

    init(
        frame frameRect: NSRect,
        rootURL: URL?,
        bookCount: Int,
        categoryCount: Int,
        onboarding: Bool
    ) {
        self.rootURL = rootURL
        self.bookCount = bookCount
        self.categoryCount = categoryCount
        self.isOnboarding = onboarding
        sheet = LibrarySettingsSheetView(
            frame: CGRect(origin: .zero, size: Self.sheetSize),
            rootURL: rootURL,
            bookCount: bookCount,
            categoryCount: categoryCount,
            onboarding: onboarding
        )
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor

        sheet.frame = CGRect(
            x: (frameRect.width - Self.sheetSize.width) / 2,
            y: (frameRect.height - Self.sheetSize.height) / 2,
            width: Self.sheetSize.width,
            height: Self.sheetSize.height
        )
        sheet.wantsLayer = true
        sheet.layer?.shadowColor = NSColor.black.cgColor
        sheet.layer?.shadowOpacity = 0.55
        sheet.layer?.shadowRadius = 28
        sheet.layer?.shadowOffset = CGSize(width: 0, height: 12)
        sheet.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(sheet)

        configure(chooseButton, title: "Обрати папку…", action: #selector(chooseTapped),
                  frame: CGRect(x: 40, y: 292, width: 190, height: 32), selected: true)
        if rootURL != nil {
            configure(scanButton, title: "Оновити зараз", action: #selector(scanTapped),
                      frame: CGRect(x: 244, y: 292, width: 170, height: 32), selected: false)
            sheet.addSubview(scanButton)
        }
        configure(closeButton, title: isOnboarding ? "Пізніше" : "Закрити", action: #selector(closeTapped),
                  frame: CGRect(x: Self.sheetSize.width - 130, y: 292, width: 90, height: 32), selected: false)
        sheet.addSubview(chooseButton)
        sheet.addSubview(closeButton)

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

    private func configure(_ button: NSButton, title: String, action: Selector, frame: CGRect, selected: Bool) {
        button.isBordered = false
        button.frame = frame
        button.target = self
        button.action = action
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: Theme.serif(13, weight: .medium),
                .foregroundColor: selected
                    ? NSColor(calibratedRed: 0.18, green: 0.11, blue: 0.05, alpha: 1)
                    : Theme.cream.withAlphaComponent(0.85)
            ]
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !sheet.frame.contains(point) {
            dismiss()
        }
    }

    @objc private func chooseTapped() { onChoose?() }
    @objc private func scanTapped() { onScan?() }
    @objc private func closeTapped() { dismiss() }

    private func dismiss() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        onClose?()
    }
}

private final class LibrarySettingsSheetView: FlippedView {
    private let rootURL: URL?
    private let bookCount: Int
    private let categoryCount: Int
    private let isOnboarding: Bool
    private var parchment: CGImage?
    private var parchmentSize: CGSize = .zero

    private let ink = NSColor(calibratedRed: 0.23, green: 0.17, blue: 0.11, alpha: 1)
    private let fadedInk = NSColor(calibratedRed: 0.38, green: 0.30, blue: 0.20, alpha: 0.66)

    init(frame frameRect: NSRect, rootURL: URL?, bookCount: Int, categoryCount: Int, onboarding: Bool) {
        self.rootURL = rootURL
        self.bookCount = bookCount
        self.categoryCount = categoryCount
        self.isOnboarding = onboarding
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

        drawText(
            isOnboarding ? "Підключити бібліотеку" : "Налаштування бібліотеки",
            in: CGRect(x: 40, y: 26, width: rect.width - 80, height: 38),
            font: Theme.serif(27, weight: .semibold),
            color: ink,
            alignment: .left
        )
        drawText(
            isOnboarding
                ? "Обери папку, у якій лежать твої книги."
                : "Папка-джерело, з якої застосунок бере книги.",
            in: CGRect(x: 40, y: 62, width: rect.width - 80, height: 18),
            font: Theme.italicSerif(12),
            color: fadedInk,
            alignment: .left
        )

        drawText(
            "ПАПКА БІБЛІОТЕКИ",
            in: CGRect(x: 40, y: 96, width: 300, height: 14),
            font: Theme.serif(9.5, weight: .medium),
            color: fadedInk,
            alignment: .left,
            kern: 1.5
        )

        let pathRect = CGRect(x: 40, y: 114, width: rect.width - 80, height: 38)
        NSColor(calibratedRed: 0.80, green: 0.73, blue: 0.57, alpha: 0.45).setFill()
        NSBezierPath(roundedRect: pathRect, xRadius: 4, yRadius: 4).fill()
        NSColor(calibratedRed: 0.46, green: 0.34, blue: 0.16, alpha: 0.40).setStroke()
        let pathBorder = NSBezierPath(roundedRect: pathRect, xRadius: 4, yRadius: 4)
        pathBorder.lineWidth = 0.8
        pathBorder.stroke()

        if let rootURL {
            drawSingleLineTruncatedMiddle(
                rootURL.path,
                in: CGRect(x: pathRect.minX + 12, y: pathRect.minY + 11, width: pathRect.width - 24, height: 16),
                font: Theme.serif(12),
                color: ink
            )
        } else {
            drawText(
                "Не вибрано",
                in: CGRect(x: pathRect.minX + 12, y: pathRect.minY + 11, width: pathRect.width - 24, height: 16),
                font: Theme.italicSerif(12),
                color: fadedInk,
                alignment: .left
            )
        }

        drawText(
            "Кожна папка першого рівня стане колекцією. PDF і DJVU всередині (рекурсивно)\nдодаються автоматично; файли не копіюються, а читаються з цієї папки.",
            in: CGRect(x: 40, y: 166, width: rect.width - 80, height: 42),
            font: Theme.serif(12),
            color: fadedInk,
            alignment: .left,
            lineHeight: 18
        )

        if rootURL != nil {
            drawText(
                "\(pluralBooks(bookCount)) · \(pluralCategories(categoryCount))",
                in: CGRect(x: 40, y: 222, width: rect.width - 80, height: 18),
                font: Theme.serif(12, weight: .medium),
                color: ink,
                alignment: .left
            )
        }

        // Brass plates under the borderless buttons.
        drawPlate(CGRect(x: 40, y: 292, width: 190, height: 32), selected: true)
        if rootURL != nil {
            drawPlate(CGRect(x: 244, y: 292, width: 170, height: 32), selected: false)
        }
        drawPlate(CGRect(x: rect.width - 130, y: 292, width: 90, height: 32), selected: false)

        drawText(
            "Зміни в папці підхоплюються кнопкою «Оновити» або при наступному запуску.",
            in: CGRect(x: 40, y: rect.height - 44, width: rect.width - 80, height: 16),
            font: Theme.italicSerif(10),
            color: fadedInk,
            alignment: .left
        )
    }

    private func drawPlate(_ rect: CGRect, selected: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        if selected {
            NSGradient(colors: [
                NSColor(calibratedRed: 0.87, green: 0.73, blue: 0.45, alpha: 1),
                NSColor(calibratedRed: 0.68, green: 0.51, blue: 0.25, alpha: 1)
            ])?.draw(in: path, angle: -90)
            NSColor.black.withAlphaComponent(0.35).setStroke()
        } else {
            NSGradient(colors: [
                NSColor(calibratedRed: 0.48, green: 0.34, blue: 0.19, alpha: 1),
                NSColor(calibratedRed: 0.33, green: 0.22, blue: 0.11, alpha: 1)
            ])?.draw(in: path, angle: -90)
            NSColor.white.withAlphaComponent(0.12).setStroke()
        }
        path.lineWidth = 0.8
        path.stroke()
    }

    private func drawSingleLineTruncatedMiddle(_ text: String, in rect: CGRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    private func pluralBooks(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return "\(count) книга" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(count) книги" }
        return "\(count) книг"
    }

    private func pluralCategories(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return "\(count) колекція" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(count) колекції" }
        return "\(count) колекцій"
    }
}
