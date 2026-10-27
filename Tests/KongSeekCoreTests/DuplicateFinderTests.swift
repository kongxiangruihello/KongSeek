import XCTest
@testable import KongSeekCore

final class DuplicateFinderTests: XCTestCase {
    private var folder: String!

    override func setUpWithError() throws {
        folder = Paths.canonical(FileManager.default.temporaryDirectory.appendingPathComponent("dupes-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func write(_ name: String, _ data: Data, modified: Date? = nil) throws -> FileEntry {
        let path = folder + "/" + name
        try FileManager.default.createDirectory(atPath: Paths.parent(path), withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path) }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return FileEntry(path: path, size: Int64(data.count), modified: attributes[.modificationDate] as! Date)
    }

    func testVersionKeys() {
        for name in ["中华文明史.pptx", "中华文明史 (1).pptx", "中华文明史副本.pptx", "中华文明史 副本 2.pptx", "中华文明史_v2.pptx",
                     "中华文明史-2024-10-01.pptx", "中华文明史 [自动保存].pptx", "中华文明史（最终版）.pptx", "中华文明史 final.pptx"] {
            XCTAssertEqual(DuplicateFinder.versionKey(name), "中华文明史", name)
        }
        XCTAssertEqual(DuplicateFinder.versionKey("原典导读 [自动保存].pptx"), "原典导读")
        XCTAssertEqual(DuplicateFinder.versionKey("%E7%99%BE%E5%AE%B6%E4%BA%89%E9%B8%A3.pptx"), "百家争鸣", "URL-encoded download names")
        XCTAssertEqual(DuplicateFinder.versionKey("百家争鸣 (1).pptx"), "百家争鸣")
        XCTAssertEqual(DuplicateFinder.versionKey("《论语》导读.pptx"), "论语导读")
        XCTAssertNotEqual(DuplicateFinder.versionKey("新《论语》导读教案.pptx"), DuplicateFinder.versionKey("《论语》导读.pptx"))
        XCTAssertNotEqual(DuplicateFinder.versionKey("讲义 1.docx"), DuplicateFinder.versionKey("讲义 2.docx"), "chapter numbers are not versions")
        XCTAssertEqual(DuplicateFinder.versionKey("Report v1.3.docx"), "report")
    }

    func testIdenticalFiles() throws {
        var bytes = [UInt8](repeating: 0, count: 300_000)
        for i in bytes.indices { bytes[i] = UInt8((i * 31 + i / 7) & 0xFF) }
        let a = try write("讲义/a.pptx", Data(bytes), modified: Date(timeIntervalSince1970: 1_000))
        let b = try write("备份/a.pptx", Data(bytes), modified: Date(timeIntervalSince1970: 2_000))
        var changed = bytes
        changed[150_000] ^= 1 // same size, same first and last 64 KB, different middle
        let c = try write("备份/a-改.pptx", Data(changed))
        let d = try write("x.txt", Data("学而时习之".utf8))
        let e = try write("y.txt", Data("学而时习之".utf8))
        let f = try write("z.txt", Data("不亦说乎?".utf8))
        let cloud = FileEntry(path: folder + "/cloud.pptx", size: 300_000, modified: Date(), isLocal: false)

        let groups = DuplicateFinder.identical([a, b, c, d, e, f, cloud])
        XCTAssertEqual(groups.count, 2)
        guard groups.count == 2 else { return }
        XCTAssertEqual(groups[0].files.map(\.name), ["a.pptx", "a.pptx"])
        XCTAssertEqual(groups[0].files.first?.path, b.path, "newest first")
        XCTAssertEqual(groups[0].reclaimable, 300_000)
        XCTAssertEqual(Set(groups[1].files.map(\.name)), ["x.txt", "y.txt"])
        XCTAssertTrue(DuplicateFinder.identical([a, b, c], minimumSize: 1_000_000).isEmpty, "minimum size")
    }

    func testVersionsWithSimilarity() throws {
        let lecture = (1...200).map { "第\($0)节 子曰学而时习之不亦说乎有朋自远方来不亦乐乎 编号\($0)" }.joined(separator: "\n")
        let older = String(lecture.prefix(lecture.count * 3 / 4))
        let newest = try write("中华文明史.txt", Data(lecture.utf8), modified: Date(timeIntervalSince1970: 3_000))
        let previous = try write("备份/中华文明史 (1).txt", Data(older.utf8), modified: Date(timeIntervalSince1970: 2_000))
        let unrelated = try write("中华文明史副本.txt", Data("完全不同的另一份文字材料".utf8), modified: Date(timeIntervalSince1970: 1_000))
        let other = try write("论语.txt", Data(lecture.utf8))
        let groups = DuplicateFinder.versions([newest, previous, unrelated, other]) { path in
            try? String(contentsOfFile: path, encoding: .utf8)
        }
        XCTAssertEqual(groups.count, 1)
        guard groups.count == 1 else { return }
        XCTAssertEqual(groups[0].kind, .versions)
        XCTAssertEqual(groups[0].files.map(\.path), [newest.path, previous.path, unrelated.path])
        XCTAssertEqual(groups[0].similarity[previous.path] ?? 0, 1, accuracy: 0.01, "an older, shorter version is contained in the newest")
        XCTAssertLessThan(groups[0].similarity[unrelated.path] ?? 1, 0.2)

        // An identical copy only takes part once.
        let copy = try write("又一份/中华文明史.txt", Data(lecture.utf8), modified: Date(timeIntervalSince1970: 100))
        let identical = DuplicateFinder.identical([newest, copy])
        let withCopy = DuplicateFinder.versions([newest, previous, copy], identical: identical)
        XCTAssertEqual(withCopy.first?.files.map(\.path), [newest.path, previous.path])
    }

    func testHashesReadToTheEnd() throws {
        let big = try write("big.bin", Data((0..<9_000_000).map { UInt8($0 % 251) }))
        let same = try write("same.bin", Data((0..<9_000_000).map { UInt8($0 % 251) }))
        XCTAssertNotNil(DuplicateFinder.fullHash(big.path), "a file larger than one read")
        XCTAssertEqual(DuplicateFinder.fullHash(big.path), DuplicateFinder.fullHash(same.path))
        XCTAssertNotNil(DuplicateFinder.fullHash(try write("empty.bin", Data()).path))
    }

    func testSimilarity() {
        XCTAssertEqual(DuplicateFinder.similarity("学而时习之不亦说乎", "学而时习之 不亦说乎"), 1, accuracy: 0.001)
        XCTAssertEqual(DuplicateFinder.similarity("学而时习之不亦说乎", "天下有道则见无道则隐"), 0, accuracy: 0.001)
    }

    func testFileEntriesFromIndex() throws {
        _ = try write("a/1.pdf", Data(count: 10))
        _ = try write("a/b/2.pdf", Data(count: 5_000))
        _ = try write("c/3.pdf", Data(count: 5_000))
        let index = NameIndex.build(roots: [folder], rules: .standard(home: folder))
        XCTAssertEqual(Set(index.fileEntries().map(\.name)), ["1.pdf", "2.pdf", "3.pdf"])
        XCTAssertEqual(index.fileEntries(minimumSize: 1_000).map(\.name).sorted(), ["2.pdf", "3.pdf"])
        XCTAssertEqual(index.fileEntries(under: folder + "/a").map(\.name).sorted(), ["1.pdf", "2.pdf"])
        XCTAssertTrue(index.fileEntries().allSatisfy(\.isLocal))
    }

    // MARK: One book, several files (0.17)

    func testBookKeys() {
        let key = "华夏边缘历史记忆与族群认同"
        for name in ["华夏边缘：历史记忆与族群认同 (王明珂) (Z-Library).pdf",
                     "華夏邊緣--歷史記憶與族群認同 by 王明珂 (z-lib.org).pdf",
                     "华夏边缘：历史记忆与族群认同 【著名历史人类学家王明珂成名作，人文社科必读经典，全新修订再版】 .epub",
                     "华夏边缘：历史记忆与族群认同_已读.pdf"] {
            XCTAssertEqual(DuplicateFinder.bookKey(name), key, name)
        }
        XCTAssertNotEqual(DuplicateFinder.bookKey("羌在漢藏之間——一個華夏邊緣的歷史人類學研究 (王明珂) (z-lib.org).pdf"), key)
        XCTAssertEqual(DuplicateFinder.bookKey("孔子与《论语》 Kong zi yu _ lun yu _ -- 成积春,宋立林主编 -- 9787040500288 -- 5ba8e6b83786f540ddc4ddbcd7cf8a88 -- Anna’s Archive.pdf"), "孔子与论语")
        XCTAssertEqual(DuplicateFinder.bookKey("论语译注（带完整书签）.pdf"), "论语译注")
        XCTAssertNil(DuplicateFinder.bookKey("1.pdf"))
        XCTAssertNil(DuplicateFinder.bookKey("2024.pdf"))
        XCTAssertNil(DuplicateFinder.bookKey("scan.pdf"), "short Latin names say nothing")
    }

    func testSameBooks() {
        let now = Date()
        let files = [
            FileEntry(path: "/e/华夏边缘：历史记忆与族群认同 (王明珂) (Z-Library).pdf", size: 16_400_000, modified: now),
            FileEntry(path: "/e/華夏邊緣--歷史記憶與族群認同 by 王明珂 (z-lib.org).pdf", size: 9_000_000, modified: now, isLocal: false),
            FileEntry(path: "/e/华夏边缘：历史记忆与族群认同 【修订再版】 .epub", size: 1_100_000, modified: now),
            FileEntry(path: "/e/羌在漢藏之間 (王明珂) (z-lib.org).pdf", size: 277_000_000, modified: now),
            FileEntry(path: "/a/讲义.pdf", size: 2_000_000, modified: now),
            FileEntry(path: "/b/讲义.pdf", size: 2_000_000, modified: now),
            FileEntry(path: "/c/论语.docx", size: 2_000_000, modified: now),
            FileEntry(path: "/c/论语.pdf", size: 2_000_000, modified: now),
        ]
        let groups = DuplicateFinder.sameBooks(files)
        XCTAssertEqual(groups.count, 1, "same names in two folders and non-book formats do not count")
        XCTAssertEqual(groups[0].kind, .sameBook)
        XCTAssertEqual(groups[0].files.map(\.size), [16_400_000, 9_000_000, 1_100_000], "largest first")
        let identical = DuplicateGroup(kind: .identical, files: [files[0], FileEntry(path: "/x/华夏边缘：历史记忆与族群认同 (王明珂) (Z-Library).pdf", size: 16_400_000, modified: now)])
        XCTAssertEqual(DuplicateFinder.sameBooks(files + [identical.files[1]], identical: [identical])[0].files.count, 3, "extra identical copies left out")
    }
}
