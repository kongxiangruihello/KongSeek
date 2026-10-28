import XCTest
@testable import KongSeekCore

/// 0.45: the faster byte search of the text index, and the index saved in two steps.
final class SearchSpeedTests: XCTestCase {
    /// The plain way: every position, non-overlapping.
    private func naiveCount(_ needle: [UInt8], in haystack: [UInt8], upTo maximum: Int) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        var count = 0
        var i = 0
        while i <= haystack.count - needle.count, count < maximum {
            if Array(haystack[i..<(i + needle.count)]) == needle {
                count += 1
                i += needle.count
            } else {
                i += 1
            }
        }
        return count
    }

    func testByteFinderMatchesPlainSearch() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            // A small alphabet so that matches and near-matches are frequent.
            let haystack = (0..<Int.random(in: 0...400, using: &generator)).map { _ in UInt8.random(in: 0...3, using: &generator) }
            let needle = (0..<Int.random(in: 1...6, using: &generator)).map { _ in UInt8.random(in: 0...3, using: &generator) }
            let maximum = Int.random(in: 1...100, using: &generator)
            let fast = haystack.withUnsafeBytes { ByteFinder(needle).count(in: $0, upTo: maximum) }
            XCTAssertEqual(fast, naiveCount(needle, in: haystack, upTo: maximum), "\(needle) in \(haystack)")
        }
    }

    func testByteFinderOnChineseText() {
        let text = Data("学而时习之，不亦说乎？有朋自远方来，不亦乐乎？人不知而不愠，不亦君子乎？".utf8)
        XCTAssertEqual(ByteFinder(Array("不亦".utf8)).count(in: text, upTo: 100), 3)
        XCTAssertEqual(ByteFinder(Array("不亦".utf8)).count(in: text, upTo: 2), 2, "stops at the maximum")
        XCTAssertEqual(ByteFinder(Array("君子".utf8)).count(in: text, upTo: 100), 1)
        XCTAssertEqual(ByteFinder(Array("小人".utf8)).count(in: text, upTo: 100), 0)
        XCTAssertEqual(ByteFinder(Array("乎？".utf8)).count(in: text, upTo: 100), 3, "the very end counts")
        XCTAssertEqual(ByteFinder(Array("学".utf8)).count(in: text, upTo: 100), 1, "the very start counts")
        XCTAssertEqual(ByteFinder([]).count(in: text, upTo: 100), 0)
        XCTAssertEqual(ByteFinder(Array("aa".utf8)).count(in: Data("aaaaa".utf8), upTo: 100), 2, "non-overlapping")
    }

    func testIndexEncodedThenWrittenLoadsBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("save-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("书", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["论语译注.pdf", "孟子正义.epub", "讲义.docx"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let index = NameIndex.build(roots: [root.path], rules: .standard(home: folder.path))
        let data = try index.encoded()
        let url = folder.appendingPathComponent("index/name-index.ksidx")
        try NameIndex.write(data, to: url)
        XCTAssertEqual(try Data(contentsOf: url), data)
        let loaded = try NameIndex.load(from: url)
        XCTAssertEqual(loaded.entryCount, index.entryCount)
        XCTAssertEqual(loaded.search(["论语"]).count, 1)
        XCTAssertEqual(loaded.search(["lunyu"]).count, index.search(["lunyu"]).count)
    }
}
