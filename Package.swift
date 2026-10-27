// swift-tools-version:5.9
import PackageDescription

// KongSeek: a macOS menu-bar file finder.
// - KongSeekCore: the search engine (name index, matching, query syntax,
//   persistence, FSEvents). No AppKit; covered by unit tests.
// - KongSeek: the menu-bar app (panel, hot key, preview).
// - ks: command-line search over the index the app saves.
// - KongSeekLegacy32: verbatim KongFetch 3.2 matching/query code, used only as
//   the reference that the tests and ksbench compare against.
// - KongSeekTestSupport: synthetic file trees for tests and ksbench.
let package = Package(
    name: "KongSeek",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "KongSeek", targets: ["KongSeek"]),
        .executable(name: "ksbench", targets: ["ksbench"]),
        .executable(name: "ks", targets: ["ks"]),
    ],
    targets: [
        .target(name: "KongSeekCore"),
        // KongSeekText: document text (PDFKit, AppKit rich text) and Spotlight full-text search,
        // shared by the app and ks.
        .target(name: "KongSeekText", dependencies: ["KongSeekCore"]),
        .executableTarget(name: "KongSeek", dependencies: ["KongSeekCore", "KongSeekText"]),
        // ks: command-line search over the app's saved index, and the MCP server.
        .executableTarget(name: "ks", dependencies: ["KongSeekCore", "KongSeekText"]),
        .target(name: "KongSeekLegacy32"),
        .target(name: "KongSeekTestSupport"),
        .executableTarget(
            name: "ksbench",
            dependencies: ["KongSeekCore", "KongSeekLegacy32", "KongSeekTestSupport"]
        ),
        .testTarget(
            name: "KongSeekCoreTests",
            dependencies: ["KongSeekCore", "KongSeekText", "KongSeekLegacy32", "KongSeekTestSupport"]
        ),
    ]
)
