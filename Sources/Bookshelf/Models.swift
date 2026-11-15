import AppKit

struct Book: Identifiable {
    let id: String
    let title: String
    let author: String
    let format: String
    let fileURL: URL
    let sourceURL: URL
    let coverURL: URL?
    let pageCount: Int
    let coverAspect: CGFloat
    var lastPageIndex: Int
    let addedAt: Date
    let fileSize: Int64
    let fileMTime: TimeInterval
    let isMissing: Bool
    let contentHash: String?

    init(
        id: String,
        title: String,
        author: String,
        format: String,
        fileURL: URL,
        sourceURL: URL? = nil,
        coverURL: URL?,
        pageCount: Int,
        coverAspect: CGFloat,
        lastPageIndex: Int,
        addedAt: Date,
        fileSize: Int64 = 0,
        fileMTime: TimeInterval = 0,
        isMissing: Bool = false,
        contentHash: String? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.format = format
        self.fileURL = fileURL
        self.sourceURL = sourceURL ?? fileURL
        self.coverURL = coverURL
        self.pageCount = pageCount
        self.coverAspect = coverAspect
        self.lastPageIndex = lastPageIndex
        self.addedAt = addedAt
        self.fileSize = fileSize
        self.fileMTime = fileMTime
        self.isMissing = isMissing
        self.contentHash = contentHash
    }

    var displayAuthor: String {
        author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Невідомий автор" : author
    }

    // Stable pseudo-random visual identity, independent of the process hash seed.
    var visualSeed: UInt64 { stableHash(id) }

    var heightFactor: CGFloat {
        0.78 + CGFloat(visualSeed % 7) * 0.025
    }

    var lean: CGFloat {
        let bucket = visualSeed / 7 % 17
        if bucket == 0 { return 0.06 }
        if bucket == 4 { return -0.008 }
        return 0
    }

    var hue: CGFloat { CGFloat(visualSeed % 360) / 360.0 }
    var saturation: CGFloat { 0.46 + CGFloat(visualSeed / 11 % 3) * 0.07 }
    var brightness: CGFloat { 0.31 + CGFloat(visualSeed / 13 % 3) * 0.04 }
    var style: Int { Int(visualSeed / 17 % 4) }

    var baseColor: NSColor {
        NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }
}

func stableHash(_ string: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    return hash
}
