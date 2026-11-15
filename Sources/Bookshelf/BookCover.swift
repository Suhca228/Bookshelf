import AppKit

enum BookCover {
    private static var cache: [String: CGImage] = [:]

    /// Loads the real cover rendered at import time, falling back to a drawn placeholder.
    static func image(for book: Book, size: CGSize, scale: CGFloat) -> CGImage? {
        if let coverURL = book.coverURL {
            if let cached = cache[book.id] { return cached }
            if let image = NSImage(contentsOf: coverURL)?.cgImageRepresentation {
                cache[book.id] = image
                return image
            }
        }
        return CoverRenderer.cover(for: book, size: size, scale: scale)
    }

    static func clearCache() {
        cache.removeAll()
    }
}
