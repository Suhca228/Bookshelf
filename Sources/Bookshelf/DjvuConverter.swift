import Foundation

enum DjvuConverter {
    enum ConvertError: LocalizedError {
        case helperMissing
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                return "Не знайдено помічник ddjvu для конвертації DJVU"
            case .failed(let message):
                return "ddjvu не зміг конвертувати файл: \(message)"
            }
        }
    }

    static func convert(source: URL, destination: URL) throws {
        guard let helper = helperURL else { throw ConvertError.helperMissing }

        let logURL = destination.deletingLastPathComponent().appendingPathComponent("ddjvu.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = helper
        process.arguments = ["-format=pdf", source.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logHandle

        do {
            try process.run()
            process.waitUntilExit()
            try? logHandle.close()
        } catch {
            try? logHandle.close()
            throw ConvertError.failed(error.localizedDescription)
        }

        let fileSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let succeeded = process.terminationStatus == 0
            && FileManager.default.fileExists(atPath: destination.path)
            && fileSize > 0

        if !succeeded {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let tail = log.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConvertError.failed(tail.isEmpty ? "код \(process.terminationStatus)" : String(tail.suffix(600)))
        }

        try? FileManager.default.removeItem(at: logURL)
    }

    private static var helperURL: URL? {
        var candidates: [URL] = []
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ddjvu"))
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Helpers/ddjvu"))
            candidates.append(resources.deletingLastPathComponent().appendingPathComponent("Helpers/ddjvu"))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Vendor/ddjvu")
        )
        // Source checkout fallback for `swift run` from any directory.
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(projectRoot.appendingPathComponent("Vendor/ddjvu"))

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
