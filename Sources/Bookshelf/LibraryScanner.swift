import AppKit
import PDFKit
import CryptoKit

final class LibraryScanner {
    struct Outcome {
        var books: Int
        var categories: Int
        var added: Int
        var updated: Int
        var missing: Int
        var errors: [String]
    }

    enum ScanError: LocalizedError {
        case invalidRoot(String)

        var errorDescription: String? {
            switch self {
            case .invalidRoot(let path):
                return "Папка бібліотеки недоступна: \(path)"
            }
        }
    }

    private struct Entry {
        let url: URL
        let categoryID: String?
    }

    private let store: LibraryStore
    private let paths: LibraryPaths
    private let progress: (String) -> Void

    init(store: LibraryStore, paths: LibraryPaths, progress: @escaping (String) -> Void) {
        self.store = store
        self.paths = paths
        self.progress = progress
    }

    func scan(root: URL) throws -> Outcome {
        let root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ScanError.invalidRoot(root.path)
        }

        do {
            _ = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            throw ScanError.invalidRoot("\(root.path): \(error.localizedDescription)")
        }

        try? FileManager.default.createDirectory(at: paths.derivedDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.coversDirectory, withIntermediateDirectories: true)

        progress("Сканування папки…")

        let categoryFolders = topLevelFolders(in: root)
        var categoryIDs: [String: String] = [:]
        for (index, folder) in categoryFolders.enumerated() {
            let collection = try store.upsertFolderCollection(
                folderName: folder.lastPathComponent,
                sortOrder: index
            )
            categoryIDs[folder.standardizedFileURL.path] = collection.id
        }
        store.deleteFolderCollections(notIn: Set(categoryFolders.map(\.lastPathComponent)))

        var entries: [Entry] = []
        for file in rootFiles(in: root) {
            entries.append(Entry(url: file, categoryID: nil))
        }
        for folder in categoryFolders {
            let categoryID = categoryIDs[folder.standardizedFileURL.path]
            for file in recursiveFiles(in: folder) {
                entries.append(Entry(url: file, categoryID: categoryID))
            }
        }
        entries.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }

        let allPaths = Set(entries.map { $0.url.standardizedFileURL.path })
        var markedMissing: Set<String> = []
        for book in store.allBooksIncludingMissing() where !book.isMissing {
            if !allPaths.contains(book.sourceURL.standardizedFileURL.path) {
                store.setMissing(bookID: book.id, missing: true)
                markedMissing.insert(book.id)
            }
        }

        var seen = Set<String>()
        var added = 0
        var updated = 0
        var errors: [String] = []

        for entry in entries {
            let sourceURL = entry.url.standardizedFileURL
            let path = sourceURL.path
            seen.insert(path)

            let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0

            let existing = store.book(sourcePath: path)
            if let existing, isUnchanged(existing, size: size, mtime: mtime) {
                if existing.contentHash == nil, let hash = contentHash(of: sourceURL) {
                    store.updateContentHash(bookID: existing.id, contentHash: hash)
                }
                store.setMissing(bookID: existing.id, missing: false)
                store.setFolderMembership(bookID: existing.id, collectionID: entry.categoryID)
                continue
            }

            let fileContentHash = contentHash(of: sourceURL)
            var resolvedExisting = existing
            if resolvedExisting == nil, let fileContentHash {
                resolvedExisting = store.book(contentHash: fileContentHash)
            }

            let isNew = resolvedExisting == nil
            if !isNew {
                progress("Оновлення «\(sourceURL.lastPathComponent)»…")
            } else {
                progress("Індексація «\(sourceURL.lastPathComponent)»…")
            }

            do {
                let book = try buildBook(
                    sourceURL: sourceURL,
                    existing: resolvedExisting,
                    categoryID: entry.categoryID,
                    size: size,
                    mtime: mtime,
                    contentHash: fileContentHash
                )
                let hash = syntheticHash(path: path, size: size, mtime: mtime)
                if isNew {
                    try store.insert(book, hash: hash)
                    added += 1
                } else {
                    try store.updateScanned(book, hash: hash)
                    updated += 1
                }
                store.setFolderMembership(bookID: book.id, collectionID: entry.categoryID)
                if let resolvedExisting, book.pageCount > 0, resolvedExisting.lastPageIndex >= book.pageCount {
                    store.updateProgress(bookID: book.id, pageIndex: book.pageCount - 1)
                }
            } catch {
                errors.append("\(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let missing = markedMissing.count
        cleanupMissingFiles()

        let outcome = Outcome(
            books: store.allBooks().count,
            categories: categoryFolders.count,
            added: added,
            updated: updated,
            missing: missing,
            errors: errors
        )
        progress("Готово")
        return outcome
    }

    // MARK: - File discovery

    private func topLevelFolders(in root: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func rootFiles(in root: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { isSupported($0) }
    }

    private func recursiveFiles(in folder: URL) -> [URL] {
        var result: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return result }
        for case let file as URL in enumerator where isSupported(file) {
            result.append(file)
        }
        return result
    }

    private func isSupported(_ url: URL) -> Bool {
        guard ["pdf", "djvu", "djv"].contains(url.pathExtension.lowercased()) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func isUnchanged(_ book: Book, size: Int64, mtime: TimeInterval) -> Bool {
        guard !book.isMissing else { return false }
        guard book.fileSize == size, abs(book.fileMTime - mtime) < 1 else { return false }
        guard FileManager.default.fileExists(atPath: book.fileURL.path) else { return false }
        if let coverURL = book.coverURL {
            guard FileManager.default.fileExists(atPath: coverURL.path) else { return false }
        } else {
            return false
        }
        return true
    }

    // MARK: - Building a book

    private func buildBook(
        sourceURL: URL,
        existing: Book?,
        categoryID: String?,
        size: Int64,
        mtime: TimeInterval,
        contentHash: String?
    ) throws -> Book {
        let ext = sourceURL.pathExtension.lowercased()
        let isDjvu = ext == "djvu" || ext == "djv"
        let id = existing?.id ?? UUID().uuidString.lowercased()
        let format = isDjvu ? "djvu" : "pdf"
        var pdfURL = sourceURL

        if isDjvu {
            let bookDirectory = paths.derivedDirectory.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: bookDirectory, withIntermediateDirectories: true)
            let destination = bookDirectory.appendingPathComponent("book.pdf")
            let temporary = bookDirectory.appendingPathComponent("book.tmp.pdf")
            try? FileManager.default.removeItem(at: temporary)

            progress("Конвертація «\(sourceURL.lastPathComponent)»…")
            try DjvuConverter.convert(source: sourceURL, destination: temporary)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            pdfURL = destination
        }

        guard let document = PDFDocument(url: pdfURL), document.pageCount > 0 else {
            throw LibraryError.invalidPDF(sourceURL.lastPathComponent)
        }
        guard let coveredPage = coverPage(in: document, preferContent: isDjvu) else {
            throw LibraryError.invalidPDF(sourceURL.lastPathComponent)
        }

        let attributes = document.documentAttributes
        let metadataTitle = attributes?[PDFDocumentAttribute.titleAttribute] as? String
        let metadataAuthor = attributes?[PDFDocumentAttribute.authorAttribute] as? String
        let title = cleanedTitle(metadataTitle, fallback: sourceURL.deletingPathExtension().lastPathComponent)
        let author = (metadataAuthor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let box = coveredPage.bounds(for: .mediaBox)
        let aspect = box.height > 0 ? box.width / box.height : 0.75

        let coverURL = paths.coversDirectory.appendingPathComponent("\(id).jpg")
        if let coverData = coverJPEG(for: coveredPage) {
            try coverData.write(to: coverURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: coverURL)
        }

        return Book(
            id: id,
            title: title,
            author: author,
            format: format,
            fileURL: pdfURL,
            sourceURL: sourceURL,
            coverURL: FileManager.default.fileExists(atPath: coverURL.path) ? coverURL : nil,
            pageCount: document.pageCount,
            coverAspect: max(0.45, min(1.4, aspect)),
            lastPageIndex: existing?.lastPageIndex ?? 0,
            addedAt: existing?.addedAt ?? Date(),
            fileSize: size,
            fileMTime: mtime,
            isMissing: false,
            contentHash: contentHash
        )
    }

    private func coverPage(in document: PDFDocument, preferContent: Bool) -> PDFPage? {
        guard let firstPage = document.page(at: 0) else { return nil }
        guard preferContent else { return firstPage }

        for index in 0..<min(6, document.pageCount) {
            guard let page = document.page(at: index) else { continue }
            if inkCoverage(page) > 0.02 {
                return page
            }
        }
        return firstPage
    }

    private func inkCoverage(_ page: PDFPage) -> Double {
        let width = 120
        let height = 160
        let thumbnail = page.thumbnail(of: NSSize(width: width, height: height), for: .mediaBox)
        guard let cgImage = thumbnail.cgImageRepresentation else { return 0 }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        var dark = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let luminance = 0.299 * Double(pixels[index])
                + 0.587 * Double(pixels[index + 1])
                + 0.114 * Double(pixels[index + 2])
            if luminance < 200 { dark += 1 }
        }
        return Double(dark) / Double(width * height)
    }

    private func coverJPEG(for page: PDFPage) -> Data? {
        let thumbnail = page.thumbnail(of: NSSize(width: 620, height: 930), for: .mediaBox)
        guard let cgImage = thumbnail.cgImageRepresentation else { return nil }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        return representation.representation(using: .jpeg, properties: [.compressionFactor: 0.86])
    }

    private func cleanedTitle(_ title: String?, fallback: String) -> String {
        var candidate = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty || candidate.lowercased() == "untitled" || candidate.lowercased() == "без назви" {
            candidate = fallback
        }
        candidate = candidate.replacingOccurrences(of: "_", with: " ")
        candidate = candidate.replacingOccurrences(of: "  ", with: " ")
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func contentHash(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func syntheticHash(path: String, size: Int64, mtime: TimeInterval) -> String {
        let pathHash = stableHash(path)
        let stampHash = stableHash("\(size)|\(mtime)")
        return String(format: "%016llx%016llx", pathHash, stampHash)
    }

    // MARK: - Missing files

    private func cleanupMissingFiles() {
        for book in store.allBooksIncludingMissing() where book.isMissing {
            let filePath = book.fileURL.standardizedFileURL.path
            let legacyPrefix = paths.booksDirectory.standardizedFileURL.path + "/"
            let derivedPrefix = paths.derivedDirectory.standardizedFileURL.path + "/"
            if filePath.hasPrefix(legacyPrefix) || filePath.hasPrefix(derivedPrefix) {
                try? FileManager.default.removeItem(at: book.fileURL.deletingLastPathComponent())
            }
            if let coverURL = book.coverURL {
                try? FileManager.default.removeItem(at: coverURL)
                store.clearCoverPath(bookID: book.id)
            }
        }
    }
}
