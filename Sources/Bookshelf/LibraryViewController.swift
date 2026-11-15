import AppKit
import PDFKit
import UniformTypeIdentifiers

final class LibraryViewController: NSViewController {
    private let header = HeaderBarView()
    private let collectionBar = CollectionBarView()
    private let shelfScrollView = NSScrollView()
    private let shelfView = ShelfView()
    private let paths = LibraryPaths()
    private var store: LibraryStore?
    private var books: [Book] = []
    private var collections: [BookCollection] = []
    private var memberships: [String: Set<String>] = [:]
    private var selectedCollectionID: String?

    private var reader: ReaderViewController?
    private var overlay: NSView?
    private var overlayLayers: OverlayLayers?
    private var isTransitioning = false
    private var currentBook: Book?
    private var tracker: ReadingSessionTracker?

    private var isScanning = false
    private var scanOverlay: NSView?
    private var scanLabel: NSTextField?
    private var settingsOverlay: LibrarySettingsOverlayView?
    private var statsOverlay: StatsOverlayView?

    private struct OverlayLayers {
        let scrim: CALayer
        let shadow: CALayer
        let page: CALayer
        let cover: CALayer
    }

    override func loadView() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 1280, height: 860))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        do {
            try paths.ensureDirectories()
            let store = try LibraryStore(url: paths.databaseURL)
            self.store = store
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.showAlert(title: "Не вдалося відкрити бібліотеку", message: error.localizedDescription)
            }
        }

        header.bookCount = 0
        header.onSettings = { [weak self] in self?.showSettings() }
        header.onRefresh = { [weak self] in self?.rescanLibrary() }
        header.onStats = { [weak self] in self?.showStatistics() }
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        collectionBar.translatesAutoresizingMaskIntoConstraints = false
        collectionBar.onSelect = { [weak self] id in
            self?.selectCollection(id)
        }
        collectionBar.onCreate = { [weak self] in
            self?.createCollection()
        }
        collectionBar.onRename = { [weak self] collection in
            self?.renameCollection(collection)
        }
        collectionBar.onDelete = { [weak self] collection in
            self?.deleteCollection(collection)
        }
        view.addSubview(collectionBar)

        shelfView.books = []
        shelfView.onOpenBook = { [weak self] book, rect in
            self?.present(book: book, slotInShelf: rect)
        }
        shelfView.onBookMenu = { [weak self] book in
            self?.menu(for: book)
        }

        shelfScrollView.drawsBackground = false
        shelfScrollView.borderType = .noBorder
        shelfScrollView.hasVerticalScroller = false
        shelfScrollView.hasHorizontalScroller = false
        shelfScrollView.autohidesScrollers = true
        shelfScrollView.scrollerStyle = .overlay
        shelfScrollView.verticalScrollElasticity = .allowed
        shelfScrollView.horizontalScrollElasticity = .none
        shelfScrollView.documentView = shelfView
        shelfScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shelfScrollView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 68),

            collectionBar.topAnchor.constraint(equalTo: header.bottomAnchor),
            collectionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionBar.heightAnchor.constraint(equalToConstant: 42),

            shelfScrollView.topAnchor.constraint(equalTo: collectionBar.bottomAnchor),
            shelfScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shelfScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shelfScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        reloadLibrary()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if LibrarySettings.rootURL == nil {
                self.showSettings(onboarding: true)
            } else {
                self.rescanLibrary()
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateShelfDocumentFrame()
    }

    private func updateShelfDocumentFrame() {
        let size = shelfScrollView.contentSize
        guard size.width > 10, size.height > 10 else { return }
        shelfView.viewportHeight = size.height
        let height = shelfView.contentHeight(forWidth: size.width, viewportHeight: size.height)
        if abs(shelfView.frame.width - size.width) > 0.5 || abs(shelfView.frame.height - height) > 0.5 {
            shelfView.frame = CGRect(x: 0, y: 0, width: size.width, height: height)
            shelfView.needsLayout = true
        }

        // When every shelf fits on screen, wheel/trackpad must not move the page at all.
        let scrollable = height > size.height + 0.5
        shelfScrollView.verticalScrollElasticity = scrollable ? .allowed : .none
        if !scrollable, shelfScrollView.contentView.bounds.origin != .zero {
            shelfScrollView.contentView.scroll(to: .zero)
            shelfScrollView.reflectScrolledClipView(shelfScrollView.contentView)
        }
    }

    // MARK: - Library

    private func reloadLibrary() {
        guard let store else { return }
        books = store.allBooks()
        collections = store.allCollections()
        memberships = store.memberships()

        if let selectedCollectionID, !collections.contains(where: { $0.id == selectedCollectionID }) {
            self.selectedCollectionID = nil
        }

        collectionBar.collections = collections
        collectionBar.selectedID = selectedCollectionID
        applyFilter()
    }

    private func applyFilter() {
        let visible: [Book]
        if let selectedCollectionID,
           let collection = collections.first(where: { $0.id == selectedCollectionID }) {
            visible = books.filter { memberships[$0.id]?.contains(selectedCollectionID) == true }
            if collection.isFolderBacked {
                shelfView.emptyTitle = "У цій папці немає книг"
                shelfView.emptyHint = "Додайте PDF або DJVU у папку «\(collection.name)» і натисніть ⟳"
            } else {
                shelfView.emptyTitle = "У цій колекції порожньо"
                shelfView.emptyHint = "Клацніть правою кнопкою на книзі → «Колекції», щоб додати її сюди"
            }
        } else {
            visible = books
            if LibrarySettings.rootURL == nil {
                shelfView.emptyTitle = "Бібліотека не підключена"
                shelfView.emptyHint = "Натисніть «Налаштування», щоб обрати папку з книгами"
            } else {
                shelfView.emptyTitle = "Полиця порожня"
                shelfView.emptyHint = "Додайте PDF або DJVU у папку бібліотеки й натисніть ⟳"
            }
        }
        shelfView.books = visible
        header.bookCount = visible.count
        updateShelfDocumentFrame()
    }

    func selectCollection(named name: String) {
        if ProcessInfo.processInfo.arguments.contains("--verbose") {
            print("selectCollection(named:) '\(name)' from \(collections.map(\.name))")
        }
        guard let collection = collections.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        selectCollection(collection.id)
    }

    private func selectCollection(_ id: String?) {
        selectedCollectionID = id
        collectionBar.selectedID = id
        applyFilter()
        shelfScrollView.contentView.scroll(to: .zero)
        shelfScrollView.reflectScrolledClipView(shelfScrollView.contentView)
    }

    // MARK: - Collections

    private func createCollection(adding book: Book? = nil) {
        guard let store else { return }
        let alert = NSAlert()
        alert.messageText = "Нова колекція"
        alert.informativeText = "Назва колекції на полиці."
        alert.addButton(withTitle: "Створити")
        alert.addButton(withTitle: "Скасувати")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Наприклад, Електроніка"
        field.font = Theme.serif(13)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            if self.collections.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                self.showAlert(title: "Така колекція вже є", message: "Обери іншу назву.")
                return
            }
            do {
                let collection = try store.createCollection(name: name)
                if let book {
                    store.addBook(book.id, toCollection: collection.id)
                }
                self.selectedCollectionID = collection.id
                self.reloadLibrary()
            } catch {
                self.showAlert(title: "Не вдалося створити колекцію", message: error.localizedDescription)
            }
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func renameCollection(_ collection: BookCollection) {
        guard !collection.isFolderBacked, let store else { return }
        let alert = NSAlert()
        alert.messageText = "Перейменувати колекцію"
        alert.addButton(withTitle: "Зберегти")
        alert.addButton(withTitle: "Скасувати")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = collection.name
        field.font = Theme.serif(13)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            if self.collections.contains(where: {
                $0.id != collection.id && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                self.showAlert(title: "Така колекція вже є", message: "Обери іншу назву.")
                return
            }
            do {
                try store.renameCollection(id: collection.id, name: name)
                self.reloadLibrary()
            } catch {
                self.showAlert(title: "Не вдалося перейменувати", message: error.localizedDescription)
            }
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func deleteCollection(_ collection: BookCollection) {
        guard !collection.isFolderBacked, let store else { return }
        let alert = NSAlert()
        alert.messageText = "Видалити «\(collection.name)»?"
        alert.informativeText = "Книги залишаться на полиці, але колекція зникне."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Видалити")
        alert.addButton(withTitle: "Скасувати")

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            store.deleteCollection(id: collection.id)
            if self.selectedCollectionID == collection.id {
                self.selectedCollectionID = nil
            }
            self.reloadLibrary()
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func menu(for book: Book) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Відкрити") { [weak self] in
            self?.present(book: book, slotInShelf: nil)
        })

        let openWithItem = NSMenuItem(title: "Відкрити за допомогою", action: nil, keyEquivalent: "")
        openWithItem.submenu = openWithMenu(for: book)
        menu.addItem(openWithItem)

        menu.addItem(ClosureMenuItem(title: "Показати у Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([book.sourceURL])
        })
        menu.addItem(.separator())

        let collectionsItem = NSMenuItem(title: "Колекції", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if collections.isEmpty {
            let empty = NSMenuItem(title: "Колекцій ще немає", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for collection in collections {
                let isMember = memberships[book.id]?.contains(collection.id) == true
                if collection.isFolderBacked {
                    let item = NSMenuItem(title: "\(collection.name) — з папки", action: nil, keyEquivalent: "")
                    item.state = isMember ? .on : .off
                    item.isEnabled = false
                    submenu.addItem(item)
                } else {
                    let item = ClosureMenuItem(title: collection.name) { [weak self] in
                        self?.toggleMembership(book: book, collection: collection)
                    }
                    item.state = isMember ? .on : .off
                    submenu.addItem(item)
                }
            }
            submenu.addItem(.separator())
        }
        submenu.addItem(ClosureMenuItem(title: "Нова колекція…") { [weak self] in
            DispatchQueue.main.async {
                self?.createCollection(adding: book)
            }
        })
        collectionsItem.submenu = submenu
        menu.addItem(collectionsItem)
        return menu
    }

    private static let preferredOpenWithBundleIDs: Set<String> = [
        "com.apple.iBooksX",   // Books
        "com.google.Chrome",   // Google Chrome
        "com.apple.Preview",   // Preview
        "com.apple.Safari"     // Safari
    ]

    private func openWithMenu(for book: Book) -> NSMenu {
        let submenu = NSMenu()
        let ownBundle = Bundle.main.bundleURL.standardizedFileURL
        let compatible = NSWorkspace.shared
            .urlsForApplications(toOpen: book.sourceURL)
            .filter { $0.standardizedFileURL != ownBundle }

        // Keep the PDF list short and familiar; DJVU keeps its compatible readers.
        let applications: [URL]
        if book.format == "pdf" {
            applications = compatible.filter { application in
                guard let bundleID = Bundle(url: application)?.bundleIdentifier else { return false }
                return Self.preferredOpenWithBundleIDs.contains(bundleID)
            }
        } else {
            applications = compatible
        }
        let sortedApplications = applications.sorted {
            applicationName($0).localizedStandardCompare(applicationName($1)) == .orderedAscending
        }

        if sortedApplications.isEmpty {
            let empty = NSMenuItem(title: "Немає доступних програм", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for application in sortedApplications {
                let item = ClosureMenuItem(title: applicationName(application)) { [weak self] in
                    self?.open(book.sourceURL, with: application)
                }
                item.image = NSWorkspace.shared.icon(forFile: application.path)
                submenu.addItem(item)
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(ClosureMenuItem(title: "Інша програма…") { [weak self] in
            self?.chooseApplication(for: book.sourceURL)
        })
        return submenu
    }

    private func applicationName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private func open(_ fileURL: URL, with applicationURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.showAlert(
                    title: "Не вдалося відкрити файл",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func chooseApplication(for fileURL: URL) {
        let panel = NSOpenPanel()
        panel.title = "Відкрити за допомогою"
        panel.prompt = "Відкрити"
        panel.message = "Оберіть програму для «\(fileURL.lastPathComponent)»."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let applicationURL = panel.url else { return }
            self?.open(fileURL, with: applicationURL)
        }

        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func toggleMembership(book: Book, collection: BookCollection) {
        guard let store else { return }
        let isMember = memberships[book.id]?.contains(collection.id) == true
        if isMember {
            store.removeBook(book.id, fromCollection: collection.id)
        } else {
            store.addBook(book.id, toCollection: collection.id)
        }
        reloadLibrary()
    }

    func debugScrollToBottom() {
        let maxY = max(0, shelfView.bounds.height - shelfScrollView.contentSize.height)
        shelfScrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        shelfScrollView.reflectScrolledClipView(shelfScrollView.contentView)
    }

    func debugZoom(_ factor: CGFloat) {
        reader?.debugSetZoom(factor)
    }

    func debugTurnNext() {
        reader?.debugTurnNext()
    }

    func debugTurnBurst(_ count: Int) {
        for _ in 0..<count {
            reader?.debugTurnNext()
        }
    }

    func debugGoToPage(_ number: Int) {
        reader?.debugGoToPage(number - 1)
    }

    func openBook(at index: Int) {
        guard books.indices.contains(index) else { return }
        present(book: books[index], slotInShelf: nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Гаразд")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Settings and scanning

    func showSettings(onboarding: Bool = false) {
        guard settingsOverlay == nil, !isScanning, reader == nil, statsOverlay == nil else { return }
        let overlay = LibrarySettingsOverlayView(
            frame: view.bounds,
            rootURL: LibrarySettings.rootURL,
            bookCount: books.count,
            categoryCount: collections.filter(\.isFolderBacked).count,
            onboarding: onboarding
        )
        overlay.autoresizingMask = [.width, .height]
        overlay.onChoose = { [weak self] in self?.chooseRootFolder() }
        overlay.onScan = { [weak self] in
            self?.settingsOverlay?.removeFromSuperview()
            self?.settingsOverlay = nil
            self?.rescanLibrary()
        }
        overlay.onClose = { [weak self] in
            self?.settingsOverlay?.removeFromSuperview()
            self?.settingsOverlay = nil
        }
        view.addSubview(overlay)
        settingsOverlay = overlay
    }

    private func chooseRootFolder() {
        let panel = NSOpenPanel()
        panel.title = "Папка бібліотеки"
        panel.message = "Оберіть папку з книгами. Кожна вкладена папка стане колекцією."
        panel.prompt = "Обрати"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            LibrarySettings.setRoot(url)
            self?.settingsOverlay?.removeFromSuperview()
            self?.settingsOverlay = nil
            self?.rescanLibrary()
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    func rescanLibrary() {
        guard !isScanning, !isTransitioning, reader == nil, let store else { return }
        guard let root = LibrarySettings.rootURL else {
            showSettings(onboarding: true)
            return
        }

        isScanning = true
        showScanOverlay(message: "Оновлення бібліотеки…")

        let scanner = LibraryScanner(store: store, paths: paths) { [weak self] message in
            DispatchQueue.main.async {
                self?.scanLabel?.stringValue = message
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let outcome = try scanner.scan(root: root)
                DispatchQueue.main.async { [weak self] in
                    self?.finishScan(outcome)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.finishScan(error)
                }
            }
        }
    }

    private func finishScan(_ outcome: LibraryScanner.Outcome) {
        hideScanOverlay()
        isScanning = false
        BookCover.clearCache()
        reloadLibrary()

        if !outcome.errors.isEmpty,
           !ProcessInfo.processInfo.arguments.contains("--quiet-scan") {
            showAlert(
                title: "Частину файлів не вдалося проіндексувати",
                message: outcome.errors.prefix(5).joined(separator: "\n")
            )
        }
    }

    private func finishScan(_ error: Error) {
        hideScanOverlay()
        isScanning = false
        showAlert(title: "Не вдалося оновити бібліотеку", message: error.localizedDescription)
    }

    private func showScanOverlay(message: String) {
        let overlay = FlippedView(frame: view.bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        overlay.autoresizingMask = [.width, .height]

        let spinner = NSProgressIndicator(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(spinner)

        let label = NSTextField(labelWithString: message)
        label.font = Theme.serif(15, weight: .medium)
        label.textColor = Theme.cream
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(label)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 10),
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, constant: -80)
        ])

        view.addSubview(overlay)
        scanOverlay = overlay
        scanLabel = label
    }

    private func hideScanOverlay() {
        scanOverlay?.removeFromSuperview()
        scanOverlay = nil
        scanLabel = nil
    }

    // MARK: - Statistics

    var canShowStatistics: Bool {
        reader == nil && statsOverlay == nil && settingsOverlay == nil && !isScanning && !isTransitioning
    }

    func showStatistics() {
        guard canShowStatistics, let store else { return }
        let overlay = StatsOverlayView(frame: view.bounds, store: store, books: books)
        overlay.autoresizingMask = [.width, .height]
        overlay.onClose = { [weak self] in
            self?.statsOverlay?.removeFromSuperview()
            self?.statsOverlay = nil
        }
        view.addSubview(overlay)
        statsOverlay = overlay
    }

    // MARK: - Presentation

    private func present(book: Book, slotInShelf: CGRect?) {
        guard !isTransitioning, reader == nil else { return }
        let prepareStart = CFAbsoluteTimeGetCurrent()
        guard let document = PDFDocument(url: book.fileURL) else {
            showAlert(title: "Не вдалося відкрити книгу", message: "Файл пошкоджено або переміщено.")
            return
        }
        guard let slot = slotInShelf.map({ shelfView.convert($0, to: view) }) ?? currentSlot(for: book) else {
            return
        }

        let startPage = max(0, min(book.lastPageIndex, document.pageCount - 1))
        let reader = ReaderViewController(book: book, document: document, startPage: startPage)
        let pageStart = pageRectInSlot(slot, aspect: reader.pageAspect)

        guard let coverImage = BookCover.image(for: book, size: slot.size, scale: 2),
              let firstPageImage = pageImage(document: document, page: startPage, size: pageStart.size) else {
            return
        }

        if ProcessInfo.processInfo.arguments.contains("--verbose") {
            print(String(format: "open prepare: %.3fs", CFAbsoluteTimeGetCurrent() - prepareStart))
        }
        isTransitioning = true
        currentBook = book
        shelfView.setBookHidden(book.id, hidden: true)
        store?.touchOpened(bookID: book.id)

        reader.onClose = { [weak self] in self?.beginClose() }
        reader.onPageChanged = { [weak self] pageIndex in
            guard let self else { return }
            self.store?.updateProgress(bookID: book.id, pageIndex: pageIndex)
            self.tracker?.pageChanged(to: pageIndex)
            if let index = self.books.firstIndex(where: { $0.id == book.id }) {
                self.books[index].lastPageIndex = pageIndex
            }
        }
        reader.view.frame = view.bounds
        reader.view.autoresizingMask = [.width, .height]
        reader.view.wantsLayer = true
        reader.view.layer?.opacity = 0
        reader.setPDFVisible(false)
        reader.setChromeVisible(false)
        view.addSubview(reader.view)
        self.reader = reader
        if let store {
            tracker = ReadingSessionTracker(
                store: store,
                bookID: book.id,
                startPage: startPage,
                window: view.window
            )
        }

        let pageRect = reader.pageRect(for: view.bounds)
        let layers = installOverlay()
        overlayLayers = layers

        layers.page.bounds = CGRect(origin: .zero, size: pageStart.size)
        layers.page.position = CGPoint(x: pageStart.midX, y: pageStart.midY)
        layers.page.contents = firstPageImage
        layers.cover.bounds = CGRect(origin: .zero, size: slot.size)
        layers.cover.anchorPoint = CGPoint(x: 0, y: 0.5)
        layers.cover.position = CGPoint(x: slot.minX, y: slot.midY)
        layers.cover.contents = coverImage
        layers.shadow.frame = CGRect(x: slot.midX - slot.width * 0.72, y: slot.maxY - 12, width: slot.width * 1.44, height: 42)

        animateOpen(slot: slot, pageRect: pageRect, pageAspect: reader.pageAspect, reader: reader)
    }

    private func currentSlot(for book: Book) -> CGRect? {
        guard let frame = shelfView.frame(for: book.id) else { return nil }
        return shelfView.convert(frame, to: view)
    }

    private func pageRectInSlot(_ slot: CGRect, aspect: CGFloat, inset: CGFloat = 2.5) -> CGRect {
        let availableWidth = max(10, slot.width - inset * 2)
        let availableHeight = max(10, slot.height - inset * 2)
        var height = availableHeight
        var width = height * aspect
        if width > availableWidth {
            width = availableWidth
            height = width / aspect
        }
        return CGRect(
            x: slot.minX + inset,
            y: slot.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func pageImage(document: PDFDocument, page index: Int, size: CGSize) -> CGImage? {
        guard let page = document.page(at: index) else { return nil }
        return page.thumbnail(of: NSSize(width: size.width * 2, height: size.height * 2), for: .mediaBox).cgImageRepresentation
    }

    // MARK: - Overlay

    private func installOverlay() -> OverlayLayers {
        let overlay = FlippedView(frame: view.bounds)
        overlay.wantsLayer = true
        overlay.autoresizingMask = [.width, .height]
        overlay.layer?.masksToBounds = true
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 1600.0
        overlay.layer?.sublayerTransform = perspective

        let scrim = CALayer()
        scrim.frame = overlay.bounds
        scrim.backgroundColor = NSColor.black.cgColor
        scrim.opacity = 0
        scrim.zPosition = 1
        overlay.layer?.addSublayer(scrim)

        let shadow = CALayer()
        shadow.contents = shadowImage()
        shadow.contentsGravity = .resize
        shadow.opacity = 0
        shadow.zPosition = 2
        overlay.layer?.addSublayer(shadow)

        let page = CALayer()
        page.backgroundColor = NSColor.white.cgColor
        page.contentsGravity = .resize
        page.contentsScale = 2
        page.shadowColor = NSColor.black.cgColor
        page.shadowOpacity = 0.55
        page.shadowRadius = 16
        page.shadowOffset = CGSize(width: 0, height: 6)
        page.zPosition = 3
        overlay.layer?.addSublayer(page)

        let cover = CALayer()
        cover.contentsGravity = .resize
        cover.contentsScale = 2
        cover.isDoubleSided = false
        cover.shadowColor = NSColor.black.cgColor
        cover.shadowOpacity = 0.45
        cover.shadowRadius = 10
        cover.shadowOffset = CGSize(width: 0, height: 4)
        cover.zPosition = 4
        overlay.layer?.addSublayer(cover)

        let back = CALayer()
        back.frame = CGRect(origin: .zero, size: CGSize(width: 200, height: 300))
        back.contentsGravity = .resize
        back.contentsScale = 2
        back.backgroundColor = NSColor(calibratedRed: 0.88, green: 0.83, blue: 0.72, alpha: 1).cgColor
        back.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
        back.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        back.isDoubleSided = false
        cover.addSublayer(back)

        self.overlay = overlay
        view.addSubview(overlay)
        return OverlayLayers(scrim: scrim, shadow: shadow, page: page, cover: cover)
    }

    private func shadowImage() -> CGImage? {
        renderImage(size: CGSize(width: 260, height: 60), scale: 2) { rect in
            let colors = [
                NSColor.black.withAlphaComponent(0.6).cgColor,
                NSColor.black.withAlphaComponent(0.25).cgColor,
                NSColor.black.withAlphaComponent(0).cgColor
            ] as CFArray
            guard let context = NSGraphicsContext.current?.cgContext,
                  let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: colors,
                    locations: [0, 0.55, 1]
                  ) else { return }
            context.addEllipse(in: rect)
            context.clip()
            context.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: rect.midX, y: rect.midY),
                startRadius: 0,
                endCenter: CGPoint(x: rect.midX, y: rect.midY),
                endRadius: rect.width * 0.5,
                options: []
            )
        }
    }

    // MARK: - Open animation

    private func animateOpen(slot: CGRect, pageRect: CGRect, pageAspect: CGFloat, reader: ReaderViewController) {
        guard let layers = overlayLayers else { return }
        let now = CACurrentMediaTime()
        let lift: CGFloat = 18
        let pageStart = pageRectInSlot(slot, aspect: pageAspect)

        addBasic(layers.scrim, keyPath: "opacity", from: 0, to: 0.56, begin: now, duration: 0.3, timing: .easeOut)
        addBasic(layers.shadow, keyPath: "opacity", from: 0, to: 0.85, begin: now + 0.02, duration: 0.25, timing: .easeOut)

        let pagePosition = CAKeyframeAnimation(keyPath: "position")
        pagePosition.values = [
            NSValue(point: CGPoint(x: pageStart.midX, y: pageStart.midY)),
            NSValue(point: CGPoint(x: pageStart.midX, y: pageStart.midY - lift)),
            NSValue(point: CGPoint(x: pageStart.midX, y: pageStart.midY - lift)),
            NSValue(point: CGPoint(x: pageRect.midX, y: pageRect.midY))
        ]
        pagePosition.keyTimes = [0, 0.24, 0.60, 1]
        pagePosition.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        pagePosition.beginTime = now
        pagePosition.duration = 0.98
        pagePosition.fillMode = .forwards
        pagePosition.isRemovedOnCompletion = false
        layers.page.add(pagePosition, forKey: "open-position")

        let pageBounds = CAKeyframeAnimation(keyPath: "bounds")
        pageBounds.values = [
            NSValue(rect: CGRect(origin: .zero, size: pageStart.size)),
            NSValue(rect: CGRect(origin: .zero, size: pageStart.size)),
            NSValue(rect: CGRect(origin: .zero, size: pageRect.size))
        ]
        pageBounds.keyTimes = [0, 0.64, 1]
        pageBounds.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        pageBounds.beginTime = now
        pageBounds.duration = 0.98
        pageBounds.fillMode = .forwards
        pageBounds.isRemovedOnCompletion = false
        layers.page.add(pageBounds, forKey: "open-bounds")

        let coverPosition = CAKeyframeAnimation(keyPath: "position")
        coverPosition.values = [
            NSValue(point: CGPoint(x: slot.minX, y: slot.midY)),
            NSValue(point: CGPoint(x: slot.minX, y: slot.midY - lift)),
            NSValue(point: CGPoint(x: slot.minX, y: slot.midY - lift))
        ]
        coverPosition.keyTimes = [0, 0.28, 1]
        coverPosition.beginTime = now
        coverPosition.duration = 0.98
        coverPosition.fillMode = .forwards
        coverPosition.isRemovedOnCompletion = false
        layers.cover.add(coverPosition, forKey: "open-cover-position")

        addBasic(
            layers.cover,
            keyPath: "transform",
            from: NSValue(caTransform3D: CATransform3DIdentity),
            to: NSValue(caTransform3D: CATransform3DMakeRotation(-1.05, 0, 1, 0)),
            begin: now + 0.28,
            duration: 0.40,
            timing: .easeInEaseOut
        )
        addBasic(layers.cover, keyPath: "opacity", from: 1, to: 0, begin: now + 0.64, duration: 0.16, timing: .easeIn)

        reader.view.layer?.add(CABasicAnimation.opacity(from: 0, to: 1, begin: now + 0.56, duration: 0.32), forKey: "reader-in")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.overlay?.removeFromSuperview()
            self.overlay = nil
            self.overlayLayers = nil
            self.reader?.view.layer?.removeAnimation(forKey: "reader-in")
            self.reader?.view.layer?.opacity = 1
            self.reader?.setPDFVisible(true)
            self.reader?.setChromeVisible(true)
            self.shelfScrollView.isHidden = true
            self.isTransitioning = false
            self.tracker?.start()
        }
    }

    // MARK: - Close animation

    func finalizeTracking() {
        tracker?.finish()
        tracker = nil
        if let reader, let book = currentBook {
            store?.updateProgress(bookID: book.id, pageIndex: reader.currentPageIndex)
        }
    }

    func closeForDemo() {
        beginClose()
    }

    private func beginClose() {
        guard !isTransitioning, let reader, let book = currentBook else { return }
        reader.prepareForClose()
        guard let pageImage = reader.currentPageImage() else { return }

        store?.updateProgress(bookID: book.id, pageIndex: reader.currentPageIndex)
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            books[index].lastPageIndex = reader.currentPageIndex
        }

        isTransitioning = true
        shelfScrollView.isHidden = false

        guard let slot = currentSlot(for: book),
              let coverImage = BookCover.image(for: book, size: slot.size, scale: 2) else {
            isTransitioning = false
            return
        }

        tracker?.finish()
        tracker = nil

        let layers = installOverlay()
        overlayLayers = layers

        let pageRect = reader.pageRect(for: view.bounds)
        let pageTarget = pageRectInSlot(slot, aspect: reader.pageAspect)

        layers.page.bounds = CGRect(origin: .zero, size: pageRect.size)
        layers.page.position = CGPoint(x: pageRect.midX, y: pageRect.midY)
        layers.page.contents = pageImage

        layers.cover.bounds = CGRect(origin: .zero, size: slot.size)
        layers.cover.anchorPoint = CGPoint(x: 0, y: 0.5)
        layers.cover.position = CGPoint(x: slot.minX, y: slot.midY)
        layers.cover.contents = coverImage
        layers.cover.transform = CATransform3DMakeRotation(-1.05, 0, 1, 0)
        layers.cover.opacity = 0

        layers.shadow.frame = CGRect(x: slot.midX - slot.width * 0.72, y: slot.maxY - 12, width: slot.width * 1.44, height: 42)
        layers.shadow.opacity = 0

        let now = CACurrentMediaTime()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers.scrim.opacity = 0.56
        reader.view.layer?.removeAnimation(forKey: "reader-in")
        reader.view.layer?.opacity = 0
        CATransaction.commit()

        addBasic(layers.scrim, keyPath: "opacity", from: 0.56, to: 0, begin: now + 0.55, duration: 0.35, timing: .easeOut)

        let pagePosition = CAKeyframeAnimation(keyPath: "position")
        pagePosition.values = [
            NSValue(point: CGPoint(x: pageRect.midX, y: pageRect.midY)),
            NSValue(point: CGPoint(x: pageTarget.midX, y: pageTarget.midY - 18)),
            NSValue(point: CGPoint(x: pageTarget.midX, y: pageTarget.midY))
        ]
        pagePosition.keyTimes = [0, 0.75, 1]
        pagePosition.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        pagePosition.beginTime = now + 0.05
        pagePosition.duration = 0.55
        pagePosition.fillMode = .forwards
        pagePosition.isRemovedOnCompletion = false
        layers.page.add(pagePosition, forKey: "close-position")

        let pageBounds = CAKeyframeAnimation(keyPath: "bounds")
        pageBounds.values = [
            NSValue(rect: CGRect(origin: .zero, size: pageRect.size)),
            NSValue(rect: CGRect(origin: .zero, size: pageTarget.size)),
            NSValue(rect: CGRect(origin: .zero, size: pageTarget.size))
        ]
        pageBounds.keyTimes = [0, 0.92, 1]
        pageBounds.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear)
        ]
        pageBounds.beginTime = now + 0.05
        pageBounds.duration = 0.55
        pageBounds.fillMode = .forwards
        pageBounds.isRemovedOnCompletion = false
        layers.page.add(pageBounds, forKey: "close-bounds")

        addBasic(layers.cover, keyPath: "opacity", from: 0, to: 1, begin: now + 0.45, duration: 0.10, timing: .linear)
        addBasic(
            layers.cover,
            keyPath: "transform",
            from: NSValue(caTransform3D: CATransform3DMakeRotation(-1.05, 0, 1, 0)),
            to: NSValue(caTransform3D: CATransform3DIdentity),
            begin: now + 0.50,
            duration: 0.45,
            timing: .easeInEaseOut
        )
        addBasic(layers.page, keyPath: "opacity", from: 1, to: 0, begin: now + 0.82, duration: 0.16, timing: .linear)
        addBasic(layers.shadow, keyPath: "opacity", from: 0, to: 0.85, begin: now + 0.5, duration: 0.2, timing: .easeOut)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in
            guard let self else { return }
            self.overlay?.removeFromSuperview()
            self.overlay = nil
            self.overlayLayers = nil
            self.shelfView.setBookHidden(book.id, hidden: false)
            self.reader?.view.removeFromSuperview()
            self.reader = nil
            self.currentBook = nil
            self.shelfScrollView.isHidden = false
            self.isTransitioning = false
        }
    }

    // MARK: - Animation helpers

    private func addBasic(
        _ layer: CALayer,
        keyPath: String,
        from: Any?,
        to: Any?,
        begin: CFTimeInterval,
        duration: CFTimeInterval,
        timing: CAMediaTimingFunctionName
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.beginTime = begin
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: keyPath + "-" + UUID().uuidString)
    }
}

private extension CABasicAnimation {
    static func opacity(from: CGFloat, to: CGFloat, begin: CFTimeInterval, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.beginTime = begin
        animation.duration = duration
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }
}
