import AppKit

struct BookCollection: Identifiable, Equatable {
    let id: String
    var name: String
    var sortOrder: Int
    var sourceFolder: String? = nil

    var isFolderBacked: Bool { sourceFolder != nil }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() {
        handler()
    }
}

final class CollectionBarView: FlippedView {
    var collections: [BookCollection] = [] {
        didSet { layoutTabs(); needsDisplay = true }
    }
    var selectedID: String? {
        didSet { layoutTabs(); needsDisplay = true }
    }

    var onSelect: ((String?) -> Void)?
    var onCreate: (() -> Void)?
    var onRename: ((BookCollection) -> Void)?
    var onDelete: ((BookCollection) -> Void)?

    fileprivate enum Tab {
        case all
        case collection(BookCollection)
        case add
    }

    private struct TabFrame {
        let rect: CGRect
        let tab: Tab
    }

    private var tabFrames: [TabFrame] = []
    private var scrollOffset: CGFloat = 0
    private var contentWidth: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        NSGradient(colors: [
            NSColor(calibratedRed: 0.26, green: 0.16, blue: 0.09, alpha: 1),
            NSColor(calibratedRed: 0.15, green: 0.09, blue: 0.05, alpha: 1)
        ])?.draw(in: rect, angle: -90)

        Theme.gold.withAlphaComponent(0.22).setFill()
        CGRect(x: 0, y: 0, width: rect.width, height: 1).fill()
        NSColor.black.withAlphaComponent(0.5).setFill()
        CGRect(x: 0, y: rect.height - 2, width: rect.width, height: 2).fill()

        if tabFrames.isEmpty { layoutTabs() }

        for frame in tabFrames {
            drawPlate(in: frame.rect, tab: frame.tab)
        }
    }

    private func layoutTabs() {
        let font = Theme.serif(11.5, weight: .medium)
        var x: CGFloat = 18 - scrollOffset
        var frames: [TabFrame] = []

        func width(for text: String) -> CGFloat {
            let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
            return max(58, ceil(textWidth) + 28)
        }

        let allWidth = width(for: "Усі книги")
        frames.append(TabFrame(rect: CGRect(x: x, y: 9, width: allWidth, height: 25), tab: .all))
        x += allWidth + 8

        for collection in collections {
            let itemWidth = width(for: collection.name)
            frames.append(TabFrame(
                rect: CGRect(x: x, y: 9, width: itemWidth, height: 25),
                tab: .collection(collection)
            ))
            x += itemWidth + 8
        }

        frames.append(TabFrame(rect: CGRect(x: x, y: 9, width: 32, height: 25), tab: .add))
        tabFrames = frames
        contentWidth = frames.last!.rect.maxX + scrollOffset + 18
    }

    override func scrollWheel(with event: NSEvent) {
        guard contentWidth > bounds.width else { return }
        let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        let maxOffset = max(0, contentWidth - bounds.width + 18)
        scrollOffset = min(max(0, scrollOffset - delta), maxOffset)
        layoutTabs()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutTabs()
    }

    private func drawPlate(in rect: CGRect, tab: Tab) {
        let isSelected: Bool
        switch tab {
        case .all:
            isSelected = selectedID == nil
        case .collection(let collection):
            isSelected = selectedID == collection.id
        case .add:
            isSelected = false
        }

        let plateRect = rect.offsetBy(dx: 0, dy: isSelected ? 1 : 0)
        let path = NSBezierPath(roundedRect: plateRect, xRadius: 4, yRadius: 4)

        if isSelected {
            NSGradient(colors: [
                NSColor(calibratedRed: 0.87, green: 0.73, blue: 0.45, alpha: 1),
                NSColor(calibratedRed: 0.68, green: 0.51, blue: 0.25, alpha: 1)
            ])?.draw(in: path, angle: -90)
        } else {
            NSGradient(colors: [
                NSColor(calibratedRed: 0.48, green: 0.34, blue: 0.19, alpha: 1),
                NSColor(calibratedRed: 0.33, green: 0.22, blue: 0.11, alpha: 1)
            ])?.draw(in: path, angle: -90)
        }

        if isSelected {
            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 0.8
            path.stroke()
        } else {
            NSColor.white.withAlphaComponent(0.12).setStroke()
            path.lineWidth = 0.6
            path.stroke()
        }

        // Two tiny screw heads make the plate read as brass hardware.
        if plateRect.width > 64 {
            NSColor.black.withAlphaComponent(0.35).setFill()
            for dx in [7.0, plateRect.width - 7.0] {
                NSBezierPath(ovalIn: CGRect(x: plateRect.minX + dx - 1.3, y: plateRect.midY - 1.3, width: 2.6, height: 2.6)).fill()
            }
            NSColor.white.withAlphaComponent(0.25).setFill()
            for dx in [7.0, plateRect.width - 7.0] {
                NSBezierPath(ovalIn: CGRect(x: plateRect.minX + dx - 0.8, y: plateRect.midY - 1.8, width: 1.2, height: 1.2)).fill()
            }
        }

        let text: String
        switch tab {
        case .all: text = "Усі книги"
        case .collection(let collection): text = collection.name
        case .add: text = "＋"
        }

        let font = Theme.serif(tab.isAdd ? 13 : 11.5, weight: .medium)
        let color: NSColor = isSelected
            ? NSColor(calibratedRed: 0.18, green: 0.11, blue: 0.05, alpha: 1)
            : Theme.cream.withAlphaComponent(0.72)
        drawText(
            text,
            in: CGRect(x: plateRect.minX + (tab.isAdd ? 0 : 8), y: plateRect.minY + 5, width: plateRect.width - (tab.isAdd ? 0 : 16), height: 16),
            font: font,
            color: color
        )
    }

    private func tab(at point: CGPoint) -> Tab? {
        layoutTabs()
        for frame in tabFrames where frame.rect.insetBy(dx: -2, dy: -3).contains(point) {
            return frame.tab
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let tab = tab(at: point) else { return }
        switch tab {
        case .all:
            onSelect?(nil)
        case .collection(let collection):
            onSelect?(collection.id)
        case .add:
            onCreate?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let tab = tab(at: point), case .collection(let collection) = tab else { return nil }
        let menu = NSMenu()
        if collection.isFolderBacked {
            let info = NSMenuItem(title: "Керується папкою «\(collection.name)»", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        } else {
            menu.addItem(ClosureMenuItem(title: "Перейменувати…") { [weak self] in
                self?.onRename?(collection)
            })
            menu.addItem(ClosureMenuItem(title: "Видалити…") { [weak self] in
                self?.onDelete?(collection)
            })
        }
        return menu
    }
}

extension CollectionBarView.Tab {
    var isAdd: Bool {
        if case .add = self { return true }
        return false
    }
}
