import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum LibraryError: LocalizedError {
    case sqlite(String)
    case duplicate(String)
    case unsupported(String)
    case invalidPDF(String)
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): return "Помилка бази даних: \(message)"
        case .duplicate(let title): return "«\(title)» уже є в бібліотеці"
        case .unsupported(let name): return "Формат не підтримується: \(name)"
        case .invalidPDF(let name): return "Не вдалося прочитати PDF: \(name)"
        case .fileSystem(let message): return "Помилка файлової системи: \(message)"
        }
    }
}

final class LibraryStore {
    private var database: OpaquePointer?
    private let lock = NSLock()

    init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "не вдалося відкрити файл"
            if let handle { sqlite3_close(handle) }
            throw LibraryError.sqlite(message)
        }
        database = handle
        sqlite3_busy_timeout(handle, 3000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try migrate()
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    // MARK: - Queries

    func allBooks() -> [Book] {
        queryBooks(includeMissing: false)
    }

    func allBooksIncludingMissing() -> [Book] {
        queryBooks(includeMissing: true)
    }

    private func queryBooks(includeMissing: Bool) -> [Book] {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return [] }

        let sql = """
            SELECT b.id, b.title, b.author, b.format, b.file_path, b.page_count,
                   b.cover_path, b.cover_aspect, b.added_at, COALESCE(p.page_index, 0),
                   b.source_path, b.file_size, b.file_mtime, b.missing, b.content_hash
            FROM book b
            LEFT JOIN progress p ON p.book_id = b.id
            \(includeMissing ? "" : "WHERE b.missing = 0")
            ORDER BY b.added_at ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var books: [Book] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let book = book(from: statement) {
                books.append(book)
            }
        }
        return books
    }

    private func book(from statement: OpaquePointer) -> Book? {
        let id = text(statement, 0)
        let filePath = text(statement, 4)
        guard !id.isEmpty, !filePath.isEmpty else { return nil }
        let coverPath = text(statement, 6)
        let sourcePath = text(statement, 10)
        return Book(
            id: id,
            title: text(statement, 1),
            author: text(statement, 2),
            format: text(statement, 3),
            fileURL: URL(fileURLWithPath: filePath),
            sourceURL: sourcePath.isEmpty ? URL(fileURLWithPath: filePath) : URL(fileURLWithPath: sourcePath),
            coverURL: coverPath.isEmpty ? nil : URL(fileURLWithPath: coverPath),
            pageCount: Int(sqlite3_column_int(statement, 5)),
            coverAspect: CGFloat(sqlite3_column_double(statement, 7)),
            lastPageIndex: Int(sqlite3_column_int(statement, 9)),
            addedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            fileSize: Int64(sqlite3_column_int64(statement, 11)),
            fileMTime: sqlite3_column_double(statement, 12),
            isMissing: sqlite3_column_int(statement, 13) != 0,
            contentHash: text(statement, 14).isEmpty ? nil : text(statement, 14)
        )
    }

    func book(sourcePath: String) -> Book? {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return nil }
        let sql = """
            SELECT b.id, b.title, b.author, b.format, b.file_path, b.page_count,
                   b.cover_path, b.cover_aspect, b.added_at, COALESCE(p.page_index, 0),
                   b.source_path, b.file_size, b.file_mtime, b.missing, b.content_hash
            FROM book b
            LEFT JOIN progress p ON p.book_id = b.id
            WHERE b.source_path = ?
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sourcePath, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return book(from: statement)
    }

    func bookCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM book;", -1, &statement, nil) == SQLITE_OK,
              let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    // MARK: - Reading sessions

    func startReadingSession(id: String, bookID: String, startPage: Int, startedAt: Date, localDay: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return }
        let sql = """
            INSERT INTO reading_session (id, book_id, started_at, duration, local_day, start_page, end_page)
            VALUES (?, ?, ?, 0, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, bookID, -1, sqliteTransient)
        sqlite3_bind_double(statement, 3, startedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 4, localDay, -1, sqliteTransient)
        sqlite3_bind_int(statement, 5, Int32(startPage))
        sqlite3_bind_int(statement, 6, Int32(startPage))
        sqlite3_step(statement)
    }

    func updateReadingSession(id: String, duration: TimeInterval, endPage: Int, pagesTurned: Int, endedAt: Date?) {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return }
        let sql = """
            UPDATE reading_session
            SET duration = ?, end_page = ?, pages_turned = ?, ended_at = ?
            WHERE id = ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, duration)
        sqlite3_bind_int(statement, 2, Int32(endPage))
        sqlite3_bind_int(statement, 3, Int32(pagesTurned))
        if let endedAt {
            sqlite3_bind_double(statement, 4, endedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_text(statement, 5, id, -1, sqliteTransient)
        sqlite3_step(statement)
    }

    func totalReadingDuration() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COALESCE(SUM(duration), 0) FROM reading_session;", -1, &statement, nil) == SQLITE_OK,
              let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_double(statement, 0)
    }

    func dailyReadingTotals() -> [String: TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return [:] }
        var statement: OpaquePointer?
        let sql = "SELECT local_day, SUM(duration) FROM reading_session GROUP BY local_day;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [:] }
        defer { sqlite3_finalize(statement) }
        var result: [String: TimeInterval] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            result[text(statement, 0)] = sqlite3_column_double(statement, 1)
        }
        return result
    }

    func readingTotalsByBook(limit: Int) -> [(bookID: String, seconds: TimeInterval)] {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return [] }
        let sql = """
            SELECT book_id, SUM(duration) AS total
            FROM reading_session
            GROUP BY book_id
            HAVING total > 0
            ORDER BY total DESC
            LIMIT ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var result: [(String, TimeInterval)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((text(statement, 0), sqlite3_column_double(statement, 1)))
        }
        return result
    }

    func recentReadingSessions(limit: Int) -> [ReadingSessionSummary] {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return [] }
        let sql = """
            SELECT b.title, s.started_at, s.duration, s.pages_turned
            FROM reading_session s
            JOIN book b ON b.id = s.book_id
            WHERE s.duration >= 1
            ORDER BY s.started_at DESC
            LIMIT ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var result: [ReadingSessionSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(ReadingSessionSummary(
                bookTitle: text(statement, 0),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                duration: sqlite3_column_double(statement, 2),
                pagesTurned: Int(sqlite3_column_int(statement, 3))
            ))
        }
        return result
    }

    // MARK: - Collections

    func allCollections() -> [BookCollection] {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return [] }
        let sql = "SELECT id, name, sort_order, source_folder FROM collection ORDER BY sort_order ASC, name COLLATE NOCASE ASC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        var result: [BookCollection] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let folder = text(statement, 3)
            result.append(BookCollection(
                id: text(statement, 0),
                name: text(statement, 1),
                sortOrder: Int(sqlite3_column_int(statement, 2)),
                sourceFolder: folder.isEmpty ? nil : folder
            ))
        }
        return result
    }

    func upsertFolderCollection(folderName: String, sortOrder: Int) throws -> BookCollection {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw LibraryError.sqlite("база не відкрита") }

        var existingID: String?
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id FROM collection WHERE source_folder = ? LIMIT 1;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw LibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        sqlite3_bind_text(statement, 1, folderName, -1, sqliteTransient)
        if sqlite3_step(statement) == SQLITE_ROW {
            existingID = text(statement, 0)
        }
        sqlite3_finalize(statement)

        if existingID == nil {
            var sameName: OpaquePointer?
            if sqlite3_prepare_v2(
                database,
                "SELECT id FROM collection WHERE source_folder IS NULL AND name = ? COLLATE NOCASE LIMIT 1;",
                -1,
                &sameName,
                nil
            ) == SQLITE_OK, let sameName {
                sqlite3_bind_text(sameName, 1, folderName, -1, sqliteTransient)
                if sqlite3_step(sameName) == SQLITE_ROW {
                    existingID = text(sameName, 0)
                }
                sqlite3_finalize(sameName)
            }
        }

        if let existingID {
            var update: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "UPDATE collection SET name = ?, source_folder = ?, sort_order = ? WHERE id = ?;",
                -1,
                &update,
                nil
            ) == SQLITE_OK, let update else {
                throw LibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            sqlite3_bind_text(update, 1, folderName, -1, sqliteTransient)
            sqlite3_bind_text(update, 2, folderName, -1, sqliteTransient)
            sqlite3_bind_int(update, 3, Int32(sortOrder))
            sqlite3_bind_text(update, 4, existingID, -1, sqliteTransient)
            sqlite3_step(update)
            sqlite3_finalize(update)
            return BookCollection(id: existingID, name: folderName, sortOrder: sortOrder, sourceFolder: folderName)
        }

        let id = UUID().uuidString.lowercased()
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO collection (id, name, sort_order, created_at, source_folder) VALUES (?, ?, ?, ?, ?);",
            -1,
            &insert,
            nil
        ) == SQLITE_OK, let insert else {
            throw LibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        sqlite3_bind_text(insert, 1, id, -1, sqliteTransient)
        sqlite3_bind_text(insert, 2, folderName, -1, sqliteTransient)
        sqlite3_bind_int(insert, 3, Int32(sortOrder))
        sqlite3_bind_double(insert, 4, Date().timeIntervalSince1970)
        sqlite3_bind_text(insert, 5, folderName, -1, sqliteTransient)
        guard sqlite3_step(insert) == SQLITE_DONE else {
            throw LibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        sqlite3_finalize(insert)
        return BookCollection(id: id, name: folderName, sortOrder: sortOrder, sourceFolder: folderName)
    }

    func deleteFolderCollections(notIn folderNames: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id, source_folder FROM collection WHERE source_folder IS NOT NULL;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return }
        var toDelete: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = text(statement, 0)
            let folder = text(statement, 1)
            if !folderNames.contains(folder) {
                toDelete.append(id)
            }
        }
        sqlite3_finalize(statement)

        for id in toDelete {
            var delete: OpaquePointer?
            guard sqlite3_prepare_v2(database, "DELETE FROM collection WHERE id = ?;", -1, &delete, nil) == SQLITE_OK,
                  let delete else { continue }
            sqlite3_bind_text(delete, 1, id, -1, sqliteTransient)
            sqlite3_step(delete)
            sqlite3_finalize(delete)
        }
    }

    func setFolderMembership(bookID: String, collectionID: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return }

        var delete: OpaquePointer?
        let deleteSQL = """
            DELETE FROM book_collection
            WHERE book_id = ?
              AND collection_id IN (SELECT id FROM collection WHERE source_folder IS NOT NULL);
            """
        if sqlite3_prepare_v2(database, deleteSQL, -1, &delete, nil) == SQLITE_OK, let delete {
            sqlite3_bind_text(delete, 1, bookID, -1, sqliteTransient)
            sqlite3_step(delete)
            sqlite3_finalize(delete)
        }

        guard let collectionID else { return }
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT OR IGNORE INTO book_collection (book_id, collection_id) VALUES (?, ?);",
            -1,
            &insert,
            nil
        ) == SQLITE_OK, let insert else { return }
        sqlite3_bind_text(insert, 1, bookID, -1, sqliteTransient)
        sqlite3_bind_text(insert, 2, collectionID, -1, sqliteTransient)
        sqlite3_step(insert)
        sqlite3_finalize(insert)
    }

    func createCollection(name: String) throws -> BookCollection {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw LibraryError.sqlite("база не відкрита") }

        let nextOrder = try scalarIntLocked("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM collection;")
        let id = UUID().uuidString.lowercased()
        var statement: OpaquePointer?
        let sql = "INSERT INTO collection (id, name, sort_order, created_at) VALUES (?, ?, ?, ?);"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, name, -1, sqliteTransient)
        sqlite3_bind_int(statement, 3, Int32(nextOrder))
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return BookCollection(id: id, name: name, sortOrder: nextOrder, sourceFolder: nil)
    }

    func renameCollection(id: String, name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw LibraryError.sqlite("база не відкрита") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE collection SET name = ? WHERE id = ?;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, id, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    func deleteCollection(id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM collection WHERE id = ?;", -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, sqliteTransient)
        sqlite3_step(statement)
    }

    func memberships() -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return [:] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT book_id, collection_id FROM book_collection;", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [:] }
        defer { sqlite3_finalize(statement) }
        var result: [String: Set<String>] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let bookID = text(statement, 0)
            let collectionID = text(statement, 1)
            result[bookID, default: []].insert(collectionID)
        }
        return result
    }

    func addBook(_ bookID: String, toCollection collectionID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT OR IGNORE INTO book_collection (book_id, collection_id) VALUES (?, ?);",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, bookID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, collectionID, -1, sqliteTransient)
        sqlite3_step(statement)
    }

    func removeBook(_ bookID: String, fromCollection collectionID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "DELETE FROM book_collection WHERE book_id = ? AND collection_id = ?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, bookID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, collectionID, -1, sqliteTransient)
        sqlite3_step(statement)
    }

    func hashExists(_ hash: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM book WHERE file_hash = ? LIMIT 1;", -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, hash, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    // MARK: - Mutations

    func insert(_ book: Book, hash: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw LibraryError.sqlite("база не відкрита") }

        let sql = """
            INSERT INTO book (id, title, author, format, file_path, file_hash, page_count,
                              cover_path, cover_aspect, added_at, source_path, file_size,
                              file_mtime, missing, content_hash)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, book.id, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, book.title, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, book.author, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, book.format, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, book.fileURL.path, -1, sqliteTransient)
        sqlite3_bind_text(statement, 6, hash, -1, sqliteTransient)
        sqlite3_bind_int(statement, 7, Int32(book.pageCount))
        if let coverURL = book.coverURL {
            sqlite3_bind_text(statement, 8, coverURL.path, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 8)
        }
        sqlite3_bind_double(statement, 9, Double(book.coverAspect))
        sqlite3_bind_double(statement, 10, book.addedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 11, book.sourceURL.path, -1, sqliteTransient)
        sqlite3_bind_int64(statement, 12, book.fileSize)
        sqlite3_bind_double(statement, 13, book.fileMTime)
        if let contentHash = book.contentHash {
            sqlite3_bind_text(statement, 14, contentHash, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 14)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    func book(contentHash: String) -> Book? {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return nil }
        let sql = """
            SELECT b.id, b.title, b.author, b.format, b.file_path, b.page_count,
                   b.cover_path, b.cover_aspect, b.added_at, COALESCE(p.page_index, 0),
                   b.source_path, b.file_size, b.file_mtime, b.missing, b.content_hash
            FROM book b
            LEFT JOIN progress p ON p.book_id = b.id
            WHERE b.content_hash = ? AND b.missing = 1
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, contentHash, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return book(from: statement)
    }

    func updateContentHash(bookID: String, contentHash: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE book SET content_hash = ? WHERE id = ?;", -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, contentHash, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, bookID, -1, sqliteTransient)
        sqlite3_step(statement)
    }

    func updateScanned(_ book: Book, hash: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw LibraryError.sqlite("база не відкрита") }

        let sql = """
            UPDATE book SET title = ?, author = ?, format = ?, file_path = ?, file_hash = ?,
                page_count = ?, cover_path = ?, cover_aspect = ?, source_path = ?,
                file_size = ?, file_mtime = ?, content_hash = ?, missing = 0
            WHERE id = ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, book.title, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, book.author, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, book.format, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, book.fileURL.path, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, hash, -1, sqliteTransient)
        sqlite3_bind_int(statement, 6, Int32(book.pageCount))
        if let coverURL = book.coverURL {
            sqlite3_bind_text(statement, 7, coverURL.path, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 7)
        }
        sqlite3_bind_double(statement, 8, Double(book.coverAspect))
        sqlite3_bind_text(statement, 9, book.sourceURL.path, -1, sqliteTransient)
        sqlite3_bind_int64(statement, 10, book.fileSize)
        sqlite3_bind_double(statement, 11, book.fileMTime)
        if let contentHash = book.contentHash {
            sqlite3_bind_text(statement, 12, contentHash, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 12)
        }
        sqlite3_bind_text(statement, 13, book.id, -1, sqliteTransient)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    func setMissing(bookID: String, missing: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE book SET missing = ? WHERE id = ?;", -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, missing ? 1 : 0)
        sqlite3_bind_text(statement, 2, bookID, -1, sqliteTransient)
        sqlite3_step(statement)
    }

    func clearCoverPath(bookID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE book SET cover_path = NULL WHERE id = ?;", -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, bookID, -1, sqliteTransient)
        sqlite3_step(statement)
    }

    func updateProgress(bookID: String, pageIndex: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return }
        let sql = """
            INSERT INTO progress (book_id, page_index, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET page_index = excluded.page_index,
                                               updated_at = excluded.updated_at;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, bookID, -1, sqliteTransient)
        sqlite3_bind_int(statement, 2, Int32(pageIndex))
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func touchOpened(bookID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE book SET last_opened_at = ? WHERE id = ?;", -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, bookID, -1, sqliteTransient)
        sqlite3_step(statement)
    }

    // MARK: - Migration

    private func migrate() throws {
        let version = try scalarInt("PRAGMA user_version;")

        if version < 1 {
            try execute("""
                CREATE TABLE IF NOT EXISTS book (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    author TEXT NOT NULL DEFAULT '',
                    format TEXT NOT NULL,
                    file_path TEXT NOT NULL,
                    file_hash TEXT NOT NULL UNIQUE,
                    page_count INTEGER NOT NULL,
                    cover_path TEXT,
                    cover_aspect REAL NOT NULL DEFAULT 0.75,
                    added_at REAL NOT NULL,
                    last_opened_at REAL
                );
                CREATE TABLE IF NOT EXISTS progress (
                    book_id TEXT PRIMARY KEY NOT NULL REFERENCES book(id) ON DELETE CASCADE,
                    page_index INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS collection (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    sort_order INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS book_collection (
                    book_id TEXT NOT NULL REFERENCES book(id) ON DELETE CASCADE,
                    collection_id TEXT NOT NULL REFERENCES collection(id) ON DELETE CASCADE,
                    PRIMARY KEY (book_id, collection_id)
                );
                CREATE INDEX IF NOT EXISTS idx_book_added ON book(added_at);
                """)
        }

        if version < 2 {
            try execute("""
                CREATE TABLE IF NOT EXISTS reading_session (
                    id TEXT PRIMARY KEY NOT NULL,
                    book_id TEXT NOT NULL REFERENCES book(id) ON DELETE CASCADE,
                    started_at REAL NOT NULL,
                    ended_at REAL,
                    duration REAL NOT NULL DEFAULT 0,
                    local_day TEXT NOT NULL,
                    start_page INTEGER NOT NULL DEFAULT 0,
                    end_page INTEGER NOT NULL DEFAULT 0,
                    pages_turned INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS idx_session_day ON reading_session(local_day);
                CREATE INDEX IF NOT EXISTS idx_session_book ON reading_session(book_id);
                CREATE INDEX IF NOT EXISTS idx_session_started ON reading_session(started_at);
                """)
        }

        if version < 3 {
            try? execute("ALTER TABLE book ADD COLUMN source_path TEXT;")
            try? execute("ALTER TABLE book ADD COLUMN file_size INTEGER NOT NULL DEFAULT 0;")
            try? execute("ALTER TABLE book ADD COLUMN file_mtime REAL NOT NULL DEFAULT 0;")
            try? execute("ALTER TABLE book ADD COLUMN missing INTEGER NOT NULL DEFAULT 0;")
            try? execute("ALTER TABLE collection ADD COLUMN source_folder TEXT;")
            try execute("""
                UPDATE book SET source_path = file_path WHERE source_path IS NULL;
                CREATE INDEX IF NOT EXISTS idx_book_source ON book(source_path);
                """)
        }

        if version < 4 {
            try? execute("ALTER TABLE book ADD COLUMN content_hash TEXT;")
            try? execute("CREATE INDEX IF NOT EXISTS idx_book_content_hash ON book(content_hash);")
        }

        try execute("PRAGMA user_version = 4;")
    }

    // MARK: - SQLite helpers

    private func execute(_ sql: String) throws {
        guard let database else { throw LibraryError.sqlite("база не відкрита") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(database, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            if let errorPointer { sqlite3_free(errorPointer) }
            throw LibraryError.sqlite(message)
        }
    }

    private func scalarIntLocked(_ sql: String) throws -> Int {
        guard let database else { throw LibraryError.sqlite("база не відкрита") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func scalarInt(_ sql: String) throws -> Int {
        guard let database else { throw LibraryError.sqlite("база не відкрита") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }
}
