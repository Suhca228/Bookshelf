import AppKit
import PDFKit
import CoreImage
import Metal

final class ReaderBackgroundView: FlippedView {
    private var backgroundImage: CGImage?
    private var backgroundSize: CGSize = .zero

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let scale = window?.backingScaleFactor ?? 2

        if backgroundImage == nil || backgroundSize != rect.size {
            backgroundImage = renderImage(size: rect.size, scale: scale) { rect in
                NSGradient(colors: [
                    NSColor(calibratedRed: 0.20, green: 0.13, blue: 0.08, alpha: 1),
                    NSColor(calibratedRed: 0.07, green: 0.045, blue: 0.025, alpha: 1)
                ])?.draw(in: rect, angle: -90)

                // Warm pool of light where the page sits.
                NSGradient(colors: [
                    NSColor(calibratedRed: 0.55, green: 0.38, blue: 0.20, alpha: 0.35),
                    NSColor(calibratedRed: 0.55, green: 0.38, blue: 0.20, alpha: 0.0)
                ])?.draw(
                    in: CGRect(x: rect.width * 0.18, y: rect.height * 0.10, width: rect.width * 0.64, height: rect.height * 0.85),
                    relativeCenterPosition: .zero
                )

                var random = SeededRandom(seed: 23)
                for _ in 0..<500 {
                    let alpha = random.range(0.01, 0.03)
                    NSColor.white.withAlphaComponent(alpha).setFill()
                    CGRect(
                        x: random.range(0, Double(rect.width)),
                        y: random.range(0, Double(rect.height)),
                        width: 1,
                        height: 1
                    ).fill()
                }

                NSGradient(colors: [
                    NSColor.black.withAlphaComponent(0),
                    NSColor.black.withAlphaComponent(0.55)
                ])?.draw(in: rect, relativeCenterPosition: .zero)
            }
            backgroundSize = rect.size
        }

        if let backgroundImage {
            context.draw(backgroundImage, in: rect)
        } else {
            NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
            rect.fill()
        }
    }
}

final class ReaderChromeView: FlippedView {
    var title: String = "" { didSet { needsDisplay = true } }
    var subtitle: String = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        NSGradient(colors: [
            NSColor(calibratedRed: 0.13, green: 0.085, blue: 0.05, alpha: 0.96),
            NSColor(calibratedRed: 0.06, green: 0.04, blue: 0.025, alpha: 0.96)
        ])?.draw(in: rect, angle: -90)

        Theme.gold.withAlphaComponent(0.28).setFill()
        CGRect(x: 0, y: rect.height - 1, width: rect.width, height: 1).fill()

        let titleWidth = max(220, rect.width - 560)
        drawText(
            title,
            in: CGRect(x: 180, y: 15, width: titleWidth, height: 22),
            font: Theme.serif(15, weight: .semibold),
            color: Theme.cream
        )
        drawText(
            subtitle.uppercased(),
            in: CGRect(x: 180, y: 37, width: titleWidth, height: 13),
            font: Theme.serif(8, weight: .medium),
            color: Theme.gold.withAlphaComponent(0.6),
            kern: 1.6
        )
    }
}

final class PageNumberPlateView: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        NSColor.black.withAlphaComponent(0.30).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        Theme.gold.withAlphaComponent(0.28).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        border.lineWidth = 0.8
        border.stroke()
    }
}

final class PageCanvasView: FlippedView {
    var onScroll: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if let onScroll {
            onScroll(event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

final class ReaderViewController: NSViewController, NSTextFieldDelegate {
    let book: Book
    let document: PDFDocument
    let startPage: Int
    var onClose: (() -> Void)?
    var onPageChanged: ((Int) -> Void)?

    private let chrome = ReaderChromeView()
    private let pageCanvas = PageCanvasView()
    private let pageLayer = CALayer()
    private var backButton = NSButton()
    private var prevButton = NSButton()
    private var nextButton = NSButton()

    private(set) var currentPageIndex: Int
    private var pageCache: [Int: CGImage] = [:]
    private var cachedRectSize: CGSize = .zero
    private var renderedRectSize: CGSize = .zero
    private var baseCenter: CGPoint = .zero

    private var zoom: CGFloat = 1
    private var panOffset: CGPoint = .zero
    private var zoomAtGestureStart: CGFloat = 1
    private var panAtGestureStart: CGPoint = .zero
    private var isFlipping = false
    private var chromeVisible = true
    private var lastTurnRequest: CFTimeInterval = 0
    private var rapidTurnCount = 0
    private let rapidTurnWindow: CFTimeInterval = 0.7

    private let pagePlate = PageNumberPlateView()
    private let pageCaption = NSTextField(labelWithString: "СТОР.")
    private let pageField = NSTextField()
    private let totalLabel = NSTextField(labelWithString: "")

    private var curlLink: CADisplayLink?
    private var curlOverlay: FlippedView?
    private var curlLayer: CALayer?
    private var curlFilter: CIFilter?
    private var curlTargetIndex = 0
    private var curlForward = true
    private var curlStart: CFTimeInterval = 0
    private var curlExtent: CGRect = .zero
    private var curlDuration: CFTimeInterval = 0.72
    private var backsideImage: CIImage?
    private var backsideExtent: CGSize = .zero
    private lazy var ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext()
    }()

    private var keyMonitor: Any?

    /// Real page proportions, used both by the reader and by the hero animation.
    lazy var pageAspect: CGFloat = {
        guard let page = document.page(at: 0) else { return 612.0 / 792.0 }
        let box = page.bounds(for: .mediaBox)
        guard box.height > 0, box.width > 0 else { return 612.0 / 792.0 }
        let rotated = page.rotation % 180 != 0
        let width = rotated ? box.height : box.width
        let height = rotated ? box.width : box.height
        return width / height
    }()

    init(book: Book, document: PDFDocument, startPage: Int) {
        self.book = book
        self.document = document
        self.startPage = max(0, min(startPage, document.pageCount - 1))
        self.currentPageIndex = max(0, min(startPage, document.pageCount - 1))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = ReaderBackgroundView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        root.wantsLayer = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        chrome.title = book.title
        chrome.subtitle = book.displayAuthor

        pageCanvas.frame = view.bounds
        pageCanvas.autoresizingMask = [.width, .height]
        pageCanvas.wantsLayer = true
        pageCanvas.layer?.masksToBounds = true
        pageCanvas.onScroll = { [weak self] event in
            self?.handleScroll(event)
        }
        view.addSubview(pageCanvas)

        pageLayer.contentsGravity = .resize
        pageLayer.backgroundColor = NSColor.white.cgColor
        pageLayer.shadowColor = NSColor.black.cgColor
        pageLayer.shadowOpacity = 0.65
        pageLayer.shadowRadius = 24
        pageLayer.shadowOffset = CGSize(width: 0, height: 8)
        pageCanvas.layer?.addSublayer(pageLayer)

        view.addSubview(chrome)

        backButton = NSButton(title: "‹  Бібліотека", target: self, action: #selector(closeTapped))
        backButton.isBordered = false
        backButton.attributedTitle = NSAttributedString(
            string: "‹  Бібліотека",
            attributes: [
                .font: Theme.serif(13, weight: .medium),
                .foregroundColor: Theme.gold
            ]
        )
        backButton.contentTintColor = Theme.gold
        view.addSubview(backButton)

        view.addSubview(pagePlate)
        pagePlate.toolTip = "Ввести номер сторінки"
        let focusPage = NSClickGestureRecognizer(target: self, action: #selector(focusPageField))
        pagePlate.addGestureRecognizer(focusPage)
        pageCaption.font = Theme.serif(8, weight: .medium)
        pageCaption.textColor = Theme.gold.withAlphaComponent(0.55)
        pageCaption.alignment = .left
        pageCaption.isBordered = false
        pageCaption.drawsBackground = false
        view.addSubview(pageCaption)
        pageField.isBordered = false
        pageField.drawsBackground = false
        pageField.textColor = Theme.cream
        pageField.font = Theme.serif(13, weight: .medium)
        pageField.alignment = .right
        pageField.focusRingType = .none
        pageField.target = self
        pageField.action = #selector(commitPageField)
        pageField.delegate = self
        pageField.toolTip = "Номер сторінки — введи та натисни Return"
        view.addSubview(pageField)

        totalLabel.font = Theme.serif(11)
        totalLabel.textColor = Theme.cream.withAlphaComponent(0.62)
        totalLabel.alignment = .left
        totalLabel.isBordered = false
        totalLabel.drawsBackground = false
        view.addSubview(totalLabel)

        configureArrow(prevButton, title: "‹", action: #selector(previousTapped))
        configureArrow(nextButton, title: "›", action: #selector(nextTapped))
        prevButton.toolTip = "Попередня сторінка"
        nextButton.toolTip = "Наступна сторінка"
        view.addSubview(prevButton)
        view.addSubview(nextButton)

        let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
        pageCanvas.addGestureRecognizer(magnify)
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pageCanvas.addGestureRecognizer(pan)
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClickZoom))
        doubleClick.numberOfClicksRequired = 2
        pageCanvas.addGestureRecognizer(doubleClick)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if let editor = self.view.window?.firstResponder as? NSTextView, editor.isFieldEditor {
                return event
            }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                switch event.keyCode {
                case 53:
                    self.requestClose()
                    return nil
                case 123:
                    self.turnPage(-1)
                    return nil
                case 124, 49:
                    self.turnPage(1)
                    return nil
                case 29:
                    self.resetZoomAnimated()
                    return nil
                default:
                    break
                }
            }
            return event
        }

        updatePageLabel()
    }

    deinit {
        curlLink?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        if isFlipping {
            cancelCurl()
        }

        chrome.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 68)
        backButton.frame = CGRect(x: 88, y: 21, width: 150, height: 26)
        let plateRect = CGRect(x: view.bounds.width - 242, y: 18, width: 220, height: 30)
        pagePlate.frame = plateRect
        pageCaption.frame = CGRect(x: plateRect.minX + 12, y: 26, width: 38, height: 12)
        pageField.frame = CGRect(x: plateRect.minX + 54, y: 23, width: 50, height: 20)
        totalLabel.frame = CGRect(x: plateRect.minX + 108, y: 24, width: 100, height: 18)
        prevButton.frame = CGRect(x: 18, y: view.bounds.midY - 28, width: 34, height: 56)
        nextButton.frame = CGRect(x: view.bounds.width - 52, y: view.bounds.midY - 28, width: 34, height: 56)

        let rect = pageRect(for: view.bounds)
        if rect.size != renderedRectSize {
            renderedRectSize = rect.size
            pageCache.removeAll()
            cachedRectSize = .zero
            resetZoomInstant()
            pageLayer.bounds = CGRect(origin: .zero, size: rect.size)
            baseCenter = CGPoint(x: rect.midX, y: rect.midY)
            pageLayer.position = baseCenter
            displayCurrentPage()
        }
        updateArrowState()
    }

    // MARK: - Page geometry

    func pageRect(for bounds: CGRect) -> CGRect {
        let top: CGFloat = 92
        let bottom: CGFloat = 34
        let available = CGRect(
            x: 54,
            y: top,
            width: max(100, bounds.width - 108),
            height: max(120, bounds.height - top - bottom)
        )
        let aspect = pageAspect
        var height = available.height
        var width = height * aspect
        if width > available.width {
            width = available.width
            height = width / aspect
        }
        return CGRect(
            x: bounds.midX - width / 2,
            y: available.minY + (available.height - height) / 2,
            width: width,
            height: height
        )
    }

    func setPDFVisible(_ visible: Bool) {
        pageLayer.isHidden = !visible
    }

    func setChromeVisible(_ visible: Bool) {
        chromeVisible = visible
        chrome.alphaValue = visible ? 1 : 0
        backButton.alphaValue = visible ? 1 : 0
        updateArrowState()
    }

    func prepareForClose() {
        cancelCurl()
        resetZoomInstant()
    }

    func currentPageImage() -> CGImage? {
        ensureCacheSize()
        return pageImage(at: currentPageIndex)
    }

    // MARK: - Page rendering

    private func ensureCacheSize() {
        let size = pageRect(for: view.bounds).size
        if cachedRectSize != size {
            cachedRectSize = size
            pageCache.removeAll()
        }
    }

    private func pageImage(at index: Int) -> CGImage? {
        guard index >= 0, index < document.pageCount else { return nil }
        ensureCacheSize()
        if let cached = pageCache[index] { return cached }
        guard let page = document.page(at: index) else { return nil }
        let size = renderedRectSize == .zero ? pageRect(for: view.bounds).size : renderedRectSize
        let target = NSSize(width: size.width * 2.5, height: size.height * 2.5)
        let thumbnail = page.thumbnail(of: target, for: .mediaBox)
        guard let image = thumbnail.cgImageRepresentation else { return nil }
        if pageCache.count > 4 { pageCache.removeAll() }
        pageCache[index] = image
        return image
    }

    private func displayCurrentPage() {
        ensureCacheSize()
        guard let image = pageImage(at: currentPageIndex) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.contents = image
        pageLayer.bounds = CGRect(origin: .zero, size: renderedRectSize)
        pageLayer.position = CGPoint(
            x: baseCenter.x + panOffset.x,
            y: baseCenter.y + panOffset.y
        )
        pageLayer.transform = CATransform3DMakeScale(zoom, zoom, 1)
        CATransaction.commit()
    }

    // MARK: - Zoom and pan

    @objc private func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
        switch gesture.state {
        case .began:
            zoomAtGestureStart = zoom
        case .changed:
            let proposed = zoomAtGestureStart * (1 + gesture.magnification)
            applyZoom(min(max(proposed, 1), 3))
        case .ended, .cancelled:
            applyZoom(min(max(zoom, 1), 3))
            clampPan()
            applyPagePosition()
        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        guard zoom > 1.01 else { return }
        switch gesture.state {
        case .began:
            panAtGestureStart = panOffset
        case .changed:
            let translation = gesture.translation(in: view)
            panOffset = CGPoint(
                x: panAtGestureStart.x + translation.x,
                y: panAtGestureStart.y + translation.y
            )
            clampPan()
            applyPagePosition()
        case .ended, .cancelled:
            clampPan()
            applyPagePosition()
        default:
            break
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard zoom > 1.01 else { return }
        panOffset.x += event.scrollingDeltaX
        panOffset.y += event.scrollingDeltaY
        clampPan()
        applyPagePosition()
    }

    private func applyZoom(_ value: CGFloat) {
        zoom = value
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.transform = CATransform3DMakeScale(zoom, zoom, 1)
        CATransaction.commit()
        updatePageLabel()
    }

    private func applyPagePosition() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.position = CGPoint(
            x: baseCenter.x + panOffset.x,
            y: baseCenter.y + panOffset.y
        )
        CATransaction.commit()
    }

    private func clampPan() {
        let scaledWidth = pageLayer.bounds.width * zoom
        let scaledHeight = pageLayer.bounds.height * zoom
        let maxX = max(0, (scaledWidth - view.bounds.width) / 2 + 40)
        let maxY = max(0, (scaledHeight - view.bounds.height) / 2 + 40)
        panOffset.x = min(max(panOffset.x, -maxX), maxX)
        panOffset.y = min(max(panOffset.y, -maxY), maxY)
    }

    @objc private func doubleClickZoom() {
        resetZoomAnimated()
    }

    @objc private func resetZoomAnimated() {
        guard zoom > 1.01 || panOffset != .zero else { return }
        let fromTransform = pageLayer.transform
        let fromPosition = pageLayer.position
        zoom = 1
        panOffset = .zero
        pageLayer.transform = CATransform3DIdentity
        pageLayer.position = baseCenter

        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: fromTransform)
        transform.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: fromPosition)
        position.toValue = NSValue(point: baseCenter)
        for (index, animation) in [transform, position].enumerated() {
            animation.duration = 0.2
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pageLayer.add(animation, forKey: "zoom-reset-\(index)")
        }
        updatePageLabel()
    }

    private func resetZoomInstant() {
        zoom = 1
        panOffset = .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.transform = CATransform3DIdentity
        pageLayer.position = baseCenter
        CATransaction.commit()
        updatePageLabel()
    }

    private func animateZoomReset(completion: @escaping () -> Void) {
        let fromTransform = pageLayer.transform
        let fromPosition = pageLayer.position
        zoom = 1
        panOffset = .zero
        pageLayer.transform = CATransform3DIdentity
        pageLayer.position = baseCenter

        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: fromTransform)
        transform.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: fromPosition)
        position.toValue = NSValue(point: baseCenter)
        for (index, animation) in [transform, position].enumerated() {
            animation.duration = 0.2
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pageLayer.add(animation, forKey: "zoom-reset-\(index)")
        }
        updatePageLabel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: completion)
    }

    // MARK: - Page turning

    @objc private func previousTapped() { turnPage(-1) }
    @objc private func nextTapped() { turnPage(1) }

    func debugTurnNext() { turnPage(1) }

    func debugGoToPage(_ index: Int) {
        jumpToPage(index)
    }

    func debugSetZoom(_ value: CGFloat) {
        let rect = pageRect(for: view.bounds)
        baseCenter = CGPoint(x: rect.midX, y: rect.midY)
        applyZoom(min(max(value, 1), 3))
    }

    private func turnPage(_ delta: Int) {
        let now = CACurrentMediaTime()
        let interval = now - lastTurnRequest
        lastTurnRequest = now
        if interval < rapidTurnWindow {
            rapidTurnCount += 1
        } else {
            rapidTurnCount = 0
        }

        if isFlipping {
            if curlFilter != nil {
                finishCurlImmediately()
            } else {
                return
            }
        }

        let target = currentPageIndex + delta
        guard target >= 0, target < document.pageCount else { return }

        if rapidTurnCount >= 2 {
            jumpToPage(target)
            return
        }

        let duration: CFTimeInterval = rapidTurnCount == 1 ? 0.32 : 0.72
        isFlipping = true
        updateArrowState()
        if zoom > 1.01 || panOffset != .zero {
            animateZoomReset { [weak self] in
                guard let self, self.isFlipping else { return }
                self.performFlip(to: target, duration: duration)
            }
        } else {
            performFlip(to: target, duration: duration)
        }
    }

    private func jumpToPage(_ target: Int) {
        guard target >= 0, target < document.pageCount else { return }
        cancelCurl()
        currentPageIndex = target
        zoom = 1
        panOffset = .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.contents = pageImage(at: target)
        pageLayer.isHidden = false
        pageLayer.transform = CATransform3DIdentity
        pageLayer.position = baseCenter
        CATransaction.commit()
        updatePageLabel()
        updateArrowState()
    }

    private func performFlip(to target: Int, duration: CFTimeInterval) {
        curlDuration = duration
        guard target >= 0, target < document.pageCount else {
            isFlipping = false
            updateArrowState()
            return
        }
        ensureCacheSize()
        guard let currentImage = pageImage(at: currentPageIndex),
              let targetImage = pageImage(at: target) else {
            currentPageIndex = target
            pageLayer.contents = pageImage(at: target)
            isFlipping = false
            updatePageLabel()
            updateArrowState()
            return
        }

        let forward = target > currentPageIndex
        curlForward = forward
        curlTargetIndex = target

        let sourceImage = forward ? currentImage : targetImage
        let destinationImage = forward ? targetImage : currentImage
        let sourceCI = CIImage(cgImage: sourceImage)
        let targetCI = CIImage(cgImage: destinationImage)
        let extent = sourceCI.extent
        curlExtent = extent
        guard let backside = backside(for: extent.size) else {
            isFlipping = false
            updateArrowState()
            return
        }

        let filter = CIFilter(name: "CIPageCurlWithShadowTransition")!
        filter.setValue(sourceCI, forKey: kCIInputImageKey)
        filter.setValue(targetCI, forKey: kCIInputTargetImageKey)
        filter.setValue(backside, forKey: "inputBacksideImage")
        filter.setValue(CIVector(cgRect: extent), forKey: "inputExtent")
        filter.setValue(CIVector(cgRect: extent), forKey: "inputShadowExtent")
        filter.setValue(Double.pi, forKey: "inputAngle")
        filter.setValue(extent.width * 0.18, forKey: kCIInputRadiusKey)
        filter.setValue(0.72, forKey: "inputShadowAmount")
        filter.setValue(0.5, forKey: "inputShadowSize")
        curlFilter = filter

        let pageRect = pageRect(for: view.bounds)
        let overlay = FlippedView(frame: view.bounds)
        overlay.wantsLayer = true
        overlay.layer?.masksToBounds = true

        let curlLayer = CALayer()
        curlLayer.frame = pageRect
        curlLayer.contentsGravity = .resize
        curlLayer.backgroundColor = NSColor.white.cgColor
        overlay.layer?.addSublayer(curlLayer)

        view.addSubview(overlay, positioned: .below, relativeTo: chrome)
        curlOverlay = overlay
        self.curlLayer = curlLayer
        pageLayer.isHidden = true

        // Show the first frame immediately (source for forward, target for backward).
        renderCurlFrame(time: forward ? 0 : 1)
        curlStart = CACurrentMediaTime()

        let link = view.displayLink(target: self, selector: #selector(stepCurl(_:)))
        link.add(to: .main, forMode: .common)
        curlLink = link
    }

    private func backside(for size: CGSize) -> CIImage? {
        if backsideExtent == size, let backsideImage { return backsideImage }
        guard let cgImage = Paper.parchment(size: size, scale: 1) else { return nil }
        let image = CIImage(cgImage: cgImage)
        backsideExtent = size
        backsideImage = image
        return image
    }

    @objc private func stepCurl(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - curlStart
        let raw = min(1, max(0, elapsed / curlDuration))
        let eased = 0.5 - 0.5 * cos(Double.pi * raw)
        let time = curlForward ? eased : 1 - eased
        renderCurlFrame(time: time)
        if raw >= 1 {
            finishCurl()
        }
    }

    private func renderCurlFrame(time: Double) {
        guard let filter = curlFilter, let layer = curlLayer else { return }
        filter.setValue(time, forKey: "inputTime")
        guard let output = filter.outputImage else { return }
        guard let cgImage = ciContext.createCGImage(output, from: curlExtent) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = cgImage
        CATransaction.commit()
    }

    private func finishCurlImmediately() {
        curlLink?.invalidate()
        curlLink = nil
        currentPageIndex = curlTargetIndex
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.contents = pageImage(at: currentPageIndex)
        pageLayer.isHidden = false
        pageLayer.transform = CATransform3DIdentity
        pageLayer.position = baseCenter
        CATransaction.commit()
        zoom = 1
        panOffset = .zero
        curlOverlay?.removeFromSuperview()
        curlOverlay = nil
        curlLayer = nil
        curlFilter = nil
        isFlipping = false
        updatePageLabel()
        updateArrowState()
        setArrowsAlpha(chromeVisible ? 1 : 0)
    }

    private func finishCurl() {
        curlLink?.invalidate()
        curlLink = nil
        currentPageIndex = curlTargetIndex
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.contents = pageImage(at: currentPageIndex)
        pageLayer.isHidden = false
        pageLayer.transform = CATransform3DIdentity
        pageLayer.position = baseCenter
        CATransaction.commit()
        zoom = 1
        panOffset = .zero
        curlOverlay?.removeFromSuperview()
        curlOverlay = nil
        curlLayer = nil
        curlFilter = nil
        isFlipping = false
        updatePageLabel()
        updateArrowState()
        setArrowsAlpha(chromeVisible ? 1 : 0)
    }

    private func cancelCurl() {
        curlLink?.invalidate()
        curlLink = nil
        curlOverlay?.removeFromSuperview()
        curlOverlay = nil
        curlLayer = nil
        curlFilter = nil
        isFlipping = false
        pageLayer.isHidden = false
        updateArrowState()
    }

    // MARK: - Chrome

    private func configureArrow(_ button: NSButton, title: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.target = self
        button.action = action
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: Theme.serif(28, weight: .medium),
                .foregroundColor: Theme.goldBright
            ]
        )
        button.contentTintColor = Theme.goldBright
    }

    private func setArrowsAlpha(_ alpha: CGFloat) {
        prevButton.alphaValue = alpha * (currentPageIndex > 0 ? 1 : 0.3)
        nextButton.alphaValue = alpha * (currentPageIndex < document.pageCount - 1 ? 1 : 0.3)
    }

    private func updateArrowState() {
        prevButton.isEnabled = currentPageIndex > 0
        nextButton.isEnabled = currentPageIndex < document.pageCount - 1
        setArrowsAlpha(chromeVisible ? 1 : 0)
    }

    private func updatePageLabel() {
        if pageField.currentEditor() == nil {
            pageField.stringValue = "\(currentPageIndex + 1)"
        }
        var total = "/ \(document.pageCount)"
        if zoom > 1.01 {
            total += " · \(Int((zoom * 100).rounded()))%"
        }
        totalLabel.stringValue = total
        onPageChanged?(currentPageIndex)
    }

    // MARK: - Page number field

    @objc private func focusPageField() {
        view.window?.makeFirstResponder(pageField)
    }

    @objc private func commitPageField() {
        guard view.window != nil else { return }
        let text = pageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(text), number >= 1, number <= document.pageCount else {
            NSSound.beep()
            updatePageLabel()
            return
        }
        let target = number - 1
        if target == currentPageIndex {
            updatePageLabel()
            view.window?.makeFirstResponder(nil)
            return
        }
        jumpToPage(target)
        view.window?.makeFirstResponder(nil)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        if let editor = pageField.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: (pageField.stringValue as NSString).length)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitPageField()
    }

    @objc private func closeTapped() {
        requestClose()
    }

    private func requestClose() {
        onClose?()
    }
}
