import AppKit
import CoreGraphics

/// Counts only the time the reader is actually in front of the user:
/// app active, window key, screen awake and the user not idle.
final class ReadingSessionTracker {
    private let store: LibraryStore
    private let sessionID = UUID().uuidString.lowercased()
    private let bookID: String
    private weak var window: NSWindow?

    private var lastPage: Int
    private var pagesTurned = 0
    private var accumulated: TimeInterval = 0
    private var activeSince: TimeInterval?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private var isStarted = false
    private var isFinished = false
    private var appActive = true
    private var windowKey = true
    private var idlePaused = false

    private var lastCheckpointAt: TimeInterval = 0
    private var lastCheckpointDuration: TimeInterval = -1
    private let idleThreshold: TimeInterval = 300

    init(store: LibraryStore, bookID: String, startPage: Int, window: NSWindow?) {
        self.store = store
        self.bookID = bookID
        self.lastPage = startPage
        self.window = window
    }

    deinit {
        finish()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        appActive = NSApp.isActive
        windowKey = window?.isKeyWindow ?? true
        lastCheckpointAt = now

        store.startReadingSession(
            id: sessionID,
            bookID: bookID,
            startPage: lastPage,
            startedAt: Date(),
            localDay: ReadingStatsBuilder.dayKey(Date())
        )

        registerObservers()

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        resumeIfPossible()
    }

    func pageChanged(to page: Int) {
        guard !isFinished, page != lastPage else { return }
        lastPage = page
        pagesTurned += 1
        checkpoint(force: true)
    }

    func finish() {
        guard isStarted, !isFinished else { return }
        isFinished = true
        timer?.invalidate()
        timer = nil
        pause()
        removeObservers()

        let duration = accumulated
        store.updateReadingSession(
            id: sessionID,
            duration: duration,
            endPage: lastPage,
            pagesTurned: pagesTurned,
            endedAt: Date()
        )
    }

    // MARK: - Active time

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var currentDuration: TimeInterval {
        guard let activeSince else { return accumulated }
        return accumulated + (now - activeSince)
    }

    private func resumeIfPossible() {
        guard !isFinished, activeSince == nil, appActive, windowKey, !idlePaused else { return }
        activeSince = now
    }

    private func pause() {
        guard let since = activeSince else { return }
        accumulated += max(0, now - since)
        activeSince = nil
    }

    private func tick() {
        guard !isFinished else { return }

        let idle = systemIdleSeconds()
        if idle > idleThreshold {
            if !idlePaused {
                idlePaused = true
                pause()
            }
        } else if idlePaused {
            idlePaused = false
            resumeIfPossible()
        }

        let duration = currentDuration
        if duration > 0, now - lastCheckpointAt >= 30, duration - lastCheckpointDuration >= 1 {
            checkpoint(force: false)
        }
    }

    private func checkpoint(force: Bool) {
        let duration = currentDuration
        guard duration > 0 else { return }
        if !force, duration - lastCheckpointDuration < 1 { return }
        lastCheckpointAt = now
        lastCheckpointDuration = duration
        store.updateReadingSession(
            id: sessionID,
            duration: duration,
            endPage: lastPage,
            pagesTurned: pagesTurned,
            endedAt: nil
        )
    }

    private func systemIdleSeconds() -> TimeInterval {
        let anyEvent = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    // MARK: - Notifications

    private func registerObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appActive = false
            self?.pause()
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appActive = true
            self?.resumeIfPossible()
        })
        if let window {
            observers.append(center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.windowKey = false
                self?.pause()
            })
            observers.append(center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.windowKey = true
                self?.resumeIfPossible()
            })
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appActive = false
            self?.pause()
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appActive = NSApp.isActive
            self?.resumeIfPossible()
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pause()
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resumeIfPossible()
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspace.removeObserver($0) }
        workspaceObservers.removeAll()
    }
}
