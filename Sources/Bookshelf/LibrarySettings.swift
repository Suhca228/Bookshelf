import Foundation

enum LibrarySettings {
    private static let rootPathKey = "libraryRootPath"

    static var environmentRoot: URL? {
        guard let value = ProcessInfo.processInfo.environment["BOOKSHELF_LIBRARY_ROOT"],
              !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    static var rootURL: URL? {
        if let environmentRoot { return environmentRoot }
        guard let path = UserDefaults.standard.string(forKey: rootPathKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var isEnvironmentOverride: Bool {
        environmentRoot != nil
    }

    static func setRoot(_ url: URL?) {
        guard let url else {
            UserDefaults.standard.removeObject(forKey: rootPathKey)
            return
        }
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: rootPathKey)
    }
}
