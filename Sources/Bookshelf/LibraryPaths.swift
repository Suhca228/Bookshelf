import Foundation

struct LibraryPaths {
    let root: URL

    init() {
        if let override = ProcessInfo.processInfo.environment["BOOKSHELF_DATA_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            root = support.appendingPathComponent("Bookshelf", isDirectory: true)
        }
    }

    var booksDirectory: URL { root.appendingPathComponent("Books", isDirectory: true) }
    var derivedDirectory: URL { root.appendingPathComponent("Derived", isDirectory: true) }
    var coversDirectory: URL { root.appendingPathComponent("Covers", isDirectory: true) }
    var databaseURL: URL { root.appendingPathComponent("library.sqlite") }

    func ensureDirectories() throws {
        let manager = FileManager.default
        for directory in [root, booksDirectory, derivedDirectory, coversDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
