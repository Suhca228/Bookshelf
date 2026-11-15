// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bookshelf",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Bookshelf",
            path: "Sources/Bookshelf"
        )
    ]
)
