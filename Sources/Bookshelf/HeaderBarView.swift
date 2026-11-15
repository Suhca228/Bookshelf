import AppKit

final class HeaderBarView: FlippedView {
    var bookCount: Int = 0 {
        didSet { needsDisplay = true }
    }
    var onStats: (() -> Void)?
    var onSettings: (() -> Void)?
    var onRefresh: (() -> Void)?

    private let statsButton = NSButton()
    private let settingsButton = NSButton()
    private let refreshButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupButtons()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupButtons()
    }

    private func setupButtons() {
        configure(statsButton, title: "Статистика", action: #selector(statsTapped))
        configure(settingsButton, title: "Налаштування", action: #selector(settingsTapped))
        configure(refreshButton, title: "⟳", action: #selector(refreshTapped))
        addSubview(statsButton)
        addSubview(settingsButton)
        addSubview(refreshButton)
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.target = self
        button.action = action
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: Theme.serif(title == "⟳" ? 18 : 12.5, weight: .medium),
                .foregroundColor: Theme.goldBright.withAlphaComponent(0.9)
            ]
        )
        button.contentTintColor = Theme.goldBright
        if title == "⟳" {
            button.toolTip = "Оновити бібліотеку"
        } else if title == "Статистика" {
            button.toolTip = "Статистика читання"
        } else {
            button.toolTip = "Папка бібліотеки та оновлення"
        }
    }

    override func layout() {
        super.layout()
        settingsButton.frame = CGRect(x: bounds.width - 172, y: 12, width: 158, height: 26)
        statsButton.frame = CGRect(x: bounds.width - 300, y: 12, width: 120, height: 26)
        refreshButton.frame = CGRect(x: bounds.width - 336, y: 9, width: 30, height: 30)
    }

    @objc private func statsTapped() { onStats?() }
    @objc private func settingsTapped() { onSettings?() }
    @objc private func refreshTapped() { onRefresh?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds

        NSGradient(colors: [
            NSColor(calibratedRed: 0.30, green: 0.18, blue: 0.10, alpha: 1),
            NSColor(calibratedRed: 0.18, green: 0.10, blue: 0.05, alpha: 1)
        ])?.draw(in: rect, angle: -90)

        var random = SeededRandom(seed: 5)
        for _ in 0..<90 {
            let y = random.range(0, Double(rect.height))
            NSColor.white.withAlphaComponent(random.range(0.005, 0.02)).setFill()
            CGRect(x: 0, y: y, width: rect.width, height: 0.8).fill()
        }

        Theme.gold.withAlphaComponent(0.35).setFill()
        CGRect(x: 0, y: rect.height - 1.5, width: rect.width, height: 1.5).fill()
        NSColor.black.withAlphaComponent(0.55).setFill()
        CGRect(x: 0, y: rect.height, width: rect.width, height: 3).fill()

        drawText(
            "Бібліотека",
            in: CGRect(x: 0, y: 9, width: rect.width, height: 32),
            font: Theme.serif(23, weight: .semibold),
            color: Theme.cream
        )
        drawText(
            "B O O K S H E L F",
            in: CGRect(x: 0, y: 39, width: rect.width, height: 14),
            font: Theme.serif(8, weight: .medium),
            color: Theme.gold.withAlphaComponent(0.62),
            kern: 1.5
        )

        if bookCount > 0 {
            drawText(
                pluralBooks(bookCount),
                in: CGRect(x: rect.width - 250, y: 42, width: 220, height: 15),
                font: Theme.italicSerif(10.5),
                color: Theme.cream.withAlphaComponent(0.48),
                alignment: .right
            )
        }

        context.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        NSColor.clear.setFill()
    }

    private func pluralBooks(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        let word: String
        if mod10 == 1 && mod100 != 11 {
            word = "книга"
        } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            word = "книги"
        } else {
            word = "книг"
        }
        return "\(count) \(word)"
    }
}
