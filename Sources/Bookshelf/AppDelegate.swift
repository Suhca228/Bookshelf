import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var libraryViewController: LibraryViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--set-root"), index + 1 < arguments.count {
            LibrarySettings.setRoot(URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        }

        buildMainMenu()

        let contentRect = NSRect(x: 0, y: 0, width: 1280, height: 860)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Bookshelf"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
        window.minSize = NSSize(width: 980, height: 640)
        window.acceptsMouseMovedEvents = true

        libraryViewController = LibraryViewController()
        window.contentViewController = libraryViewController
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        handleLaunchArguments()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        libraryViewController?.finalizeTracking()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showStatistics(_:)) {
            return libraryViewController?.canShowStatistics ?? false
        }
        return true
    }

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Про Bookshelf",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Сховати Bookshelf",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = NSMenuItem(
            title: "Сховати інші",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Вийти з Bookshelf",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "Файл")
        let refreshItem = NSMenuItem(
            title: "Оновити бібліотеку",
            action: #selector(refreshLibrary(_:)),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        fileMenu.addItem(refreshItem)

        let settingsItem = NSMenuItem(
            title: "Налаштування…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        fileMenu.addItem(settingsItem)
        fileMenu.addItem(.separator())

        let statsItem = NSMenuItem(
            title: "Статистика читання…",
            action: #selector(showStatistics(_:)),
            keyEquivalent: "s"
        )
        statsItem.keyEquivalentModifierMask = [.command, .shift]
        statsItem.target = self
        fileMenu.addItem(statsItem)
        fileMenu.addItem(.separator())
        let closeItem = NSMenuItem(
            title: "Закрити вікно",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Вікно")
        windowMenu.addItem(
            withTitle: "Згорнути",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Закрити",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func refreshLibrary(_ sender: Any?) {
        libraryViewController.rescanLibrary()
    }

    @objc private func openSettings(_ sender: Any?) {
        libraryViewController.showSettings()
    }

    @objc private func showStatistics(_ sender: Any?) {
        libraryViewController.showStatistics()
    }

    // MARK: - Demo / screenshot helpers

    private func handleLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments

        if let index = arguments.firstIndex(of: "--collection"), index + 1 < arguments.count {
            let name = arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.libraryViewController.selectCollection(named: name)
            }
        }

        if arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.libraryViewController.showSettings()
            }
        }

        if let index = arguments.firstIndex(of: "--zoom"), index + 1 < arguments.count,
           let factor = Double(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                self?.libraryViewController.debugZoom(CGFloat(factor))
            }
        }

        if arguments.contains("--turn-next") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                self?.libraryViewController.debugTurnNext()
            }
        }

        if arguments.contains("--turn-burst") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                self?.libraryViewController.debugTurnBurst(5)
            }
        }

        if let index = arguments.firstIndex(of: "--goto-page"), index + 1 < arguments.count,
           let page = Int(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                self?.libraryViewController.debugGoToPage(page)
            }
        }

        if arguments.contains("--scroll-bottom") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.libraryViewController.debugScrollToBottom()
            }
        }

        if arguments.contains("--stats") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.libraryViewController.showStatistics()
            }
        }

        if let index = arguments.firstIndex(of: "--open-index"), index + 1 < arguments.count,
           let bookIndex = Int(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.libraryViewController.openBook(at: bookIndex)
            }
        }

        if arguments.contains("--open-first") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.libraryViewController.openBook(at: 0)
            }
        }

        if arguments.contains("--auto-close") {
            var delay: TimeInterval = 3.1
            if let index = arguments.firstIndex(of: "--auto-close-delay"), index + 1 < arguments.count {
                delay = Double(arguments[index + 1]) ?? delay
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.libraryViewController.closeForDemo()
            }
        }

        if let index = arguments.firstIndex(of: "--shot"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            let delay: TimeInterval
            if let delayIndex = arguments.firstIndex(of: "--shot-delay"), delayIndex + 1 < arguments.count {
                delay = Double(arguments[delayIndex + 1]) ?? 2.2
            } else {
                delay = 2.2
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.captureWindow(to: path)
            }
        }

        if let index = arguments.firstIndex(of: "--freeze"), index + 1 < arguments.count {
            let freezeAt = Double(arguments[index + 1]) ?? 0.45
            if let index = arguments.firstIndex(of: "--collection"), index + 1 < arguments.count {
            let name = arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.libraryViewController.selectCollection(named: name)
            }
        }

        if arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.libraryViewController.showSettings()
            }
        }

        if let index = arguments.firstIndex(of: "--zoom"), index + 1 < arguments.count,
           let factor = Double(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                self?.libraryViewController.debugZoom(CGFloat(factor))
            }
        }

        if arguments.contains("--turn-next") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                self?.libraryViewController.debugTurnNext()
            }
        }

        if arguments.contains("--turn-burst") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                self?.libraryViewController.debugTurnBurst(5)
            }
        }

        if let index = arguments.firstIndex(of: "--goto-page"), index + 1 < arguments.count,
           let page = Int(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                self?.libraryViewController.debugGoToPage(page)
            }
        }

        if arguments.contains("--scroll-bottom") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.libraryViewController.debugScrollToBottom()
            }
        }

        if arguments.contains("--stats") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.libraryViewController.showStatistics()
            }
        }

        if let index = arguments.firstIndex(of: "--open-index"), index + 1 < arguments.count,
           let bookIndex = Int(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.libraryViewController.openBook(at: bookIndex)
            }
        }

        if arguments.contains("--open-first") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9 + freezeAt) { [weak self] in
                    self?.window.contentView?.layer?.speed = 0
                }
            }
        }
    }

    private func captureWindow(to path: String) {
        guard let window, window.windowNumber > 0 else { return }
        let windowID = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            FileHandle.standardError.write(Data("screenshot failed\n".utf8))
            NSApp.terminate(nil)
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        NSApp.terminate(nil)
    }
}
