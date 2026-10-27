// swift-tools-version:5.9
import PackageDescription

// KongSeek: a macOS menu-bar file finder.
// - KongSeekCore: the search engine (name index, matching, query syntax,
//   persistence, FSEvents). No AppKit; covered by unit tests.
// - KongSeek: the menu-bar app (panel, hot key, preview).
// - KongSeekLegacy32: verbatim KongFetch 3.2 matching/query code, used only as
//   the reference that the tests and ksbench compare against.
// - KongSeekTestSupport: synthetic file trees for tests and ksbench.
let package = Package(
    name: "KongSeek",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "KongSeek", targets: ["KongSeek"]),
        .executable(name: "ksbench", targets: ["ksbench"]),
    ],
    targets: [
        .target(name: "KongSeekCore"),
        .executableTarget(name: "KongSeek", dependencies: ["KongSeekCore"]),
        .target(name: "KongSeekLegacy32"),
        .target(name: "KongSeekTestSupport"),
        .executableTarget(
            name: "ksbench",
            dependencies: ["KongSeekCore", "KongSeekLegacy32", "KongSeekTestSupport"]
        ),
        .testTarget(
            name: "KongSeekCoreTests",
            dependencies: ["KongSeekCore", "KongSeekLegacy32", "KongSeekTestSupport"]
        ),
    ]
)
