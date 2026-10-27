import XCTest
@testable import KongSeekCore
import KongSeekLegacy32

final class ArchiveTests: XCTestCase {
    private func makeZip(stored: Bool) throws -> (zip: URL, dir: URL) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("讲义")
        try fm.createDirectory(at: source.appendingPathComponent("第一讲"), withIntermediateDirectories: true)
        try String(repeating: "学而时习之，不亦说乎？", count: 200).write(to: source.appendingPathComponent("第一讲/学而.txt"),
                                                                     atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: source.appendingPathComponent(".DS_Store"))
        let zip = dir.appendingPathComponent("讲义.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = dir
        process.arguments = (stored ? ["-0"] : []) + ["-r", "-q", zip.path, "讲义"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return (zip, dir)
    }

    func testListsAndExtractsDeflatedAndStoredEntries() throws {
        for stored in [false, true] {
            let (zip, dir) = try makeZip(stored: stored)
            defer { try? FileManager.default.removeItem(at: dir) }
            let entries = try ZipReader.entries(at: zip)
            let files = entries.filter(ZipReader.isListable).map(\.name)
            XCTAssertEqual(files, ["讲义/第一讲/学而.txt"])
            let entry = try XCTUnwrap(entries.first { $0.name == "讲义/第一讲/学而.txt" })
            XCTAssertEqual(entry.method, stored ? 0 : 8)
            let out = dir.appendingPathComponent("out/学而.txt")
            try ZipReader.extract(entry, from: zip, to: out)
            XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), String(repeating: "学而时习之，不亦说乎？", count: 200))
        }
    }

    func testRejectsNonZipAndDecodesGBKNames() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notzip-\(UUID().uuidString).zip")
        try Data(repeating: 7, count: 100).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try ZipReader.entries(at: file))

        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let data = try XCTUnwrap("论语/学而.pdf".data(using: gbk))
        XCTAssertEqual(ZipReader.decodeName(data, utf8Flag: false), "论语/学而.pdf")
        XCTAssertEqual(ZipReader.decodeName(Data("abc.txt".utf8), utf8Flag: true), "abc.txt")
    }

    func testIndexSearchAndPersistence() throws {
        let index = ArchiveIndex()
        index.update(.init(path: "/d/讲义.zip", size: 10, modified: 100, names: ["讲义/第一讲/学而.txt", "讲义/为政.pdf"]))
        index.update(.init(path: "/d/其他.zip", size: 10, modified: 100, names: ["学而篇注释.docx"]))
        let hits = index.search(["学而"])
        XCTAssertEqual(Set(hits.map(\.inner)), ["讲义/第一讲/学而.txt", "学而篇注释.docx"])
        XCTAssertTrue(index.search(["讲义"]).isEmpty) // folder names are not matched
        XCTAssertEqual(Set(index.search(["xueer"]).map(\.inner)), ["讲义/第一讲/学而.txt", "学而篇注释.docx"], "pinyin")
        XCTAssertEqual(index.search(["学而"], acceptName: { $0.hasSuffix(".docx") }).map(\.inner), ["学而篇注释.docx"])
        XCTAssertEqual(index.search(["学而"], accept: { $0 == "/d/其他.zip" }).map(\.inner), ["学而篇注释.docx"])
        XCTAssertTrue(index.isCurrent(path: "/d/讲义.zip", size: 10, modified: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(index.isCurrent(path: "/d/讲义.zip", size: 11, modified: Date(timeIntervalSince1970: 100)))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archives-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try index.save(to: url)
        let loaded = ArchiveIndex()
        loaded.load(from: url)
        XCTAssertEqual(loaded.archiveCount, 2)
        XCTAssertEqual(loaded.entryCount, 3)
        loaded.prune { $0 != "/d/其他.zip" }
        XCTAssertEqual(loaded.search(["学而"]).map(\.inner), ["讲义/第一讲/学而.txt"])
    }

    /// NameScorer must score exactly like 3.2's fuzzy-name mode.
    func testNameScorerMatches32() {
        let names = MatchingParityTests.edgeNames + ["论语讲义.pdf", "期末考试 2024.docx", "report-final.txt", "重庆火锅.jpg"]
        for words in MatchingParityTests.queries {
            for name in names {
                let expected = Legacy32Precision.fuzzyName.score(URL(fileURLWithPath: "/x/" + name), words: words)
                XCTAssertEqual(NameScorer.score(name, words: words), expected, "\(words) \(name)")
            }
        }
    }

    func testQueryAcceptsName() {
        XCTAssertTrue(SearchQuery("学而 ext:docx").acceptsName("学而篇注释.docx"))
        XCTAssertFalse(SearchQuery("学而 ext:docx").acceptsName("学而.txt"))
        XCTAssertFalse(SearchQuery("学而 -ext:txt").acceptsName("学而.TXT"))
        XCTAssertFalse(SearchQuery("学而 -注释").acceptsName("学而篇注释.docx"))
        XCTAssertTrue(SearchQuery("\"学而篇\"").acceptsName("学而篇注释.docx"))
        XCTAssertFalse(SearchQuery("\"学而 篇\"").acceptsName("学而篇注释.docx"))
        XCTAssertFalse(SearchQuery("ext:docx").acceptsName("docx"))
    }
}
