import XCTest
@testable import KongSeekCore

/// 导出 Excel and 课程材料打包 (0.22).
final class ZipWriterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testCRC() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testArchiveReadsBack() throws {
        let source = folder.appendingPathComponent("第一讲.txt")
        try Data(String(repeating: "学而时习之", count: 2000).utf8).write(to: source)
        let url = folder.appendingPathComponent("课程.zip")
        let zip = try ZipWriter(url: url)
        try zip.addFile(source, as: "论语导读/第一讲.txt")
        try zip.add(Data("hello".utf8), as: "说明.txt")
        try zip.finish()
        let entries = try ZipReader.entries(at: url)
        XCTAssertEqual(entries.map(\.name), ["论语导读/第一讲.txt", "说明.txt"])
        XCTAssertEqual(try ZipReader.data(entries[0], from: url), try Data(contentsOf: source))
        XCTAssertEqual(String(data: try ZipReader.data(entries[1], from: url), encoding: .utf8), "hello")
        // macOS's own unzip agrees.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-tq", url.path]
        unzip.standardOutput = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
    }

    func testWorkbook() throws {
        let url = folder.appendingPathComponent("书单.xlsx")
        try XLSXWriter.write(rows: [[.text("书名"), .text("大小（MB）")], [.text("论语译注 <精> & 注"), .number(12.5)]], columnWidths: [40, 12], to: url)
        let entries = try ZipReader.entries(at: url)
        XCTAssertTrue(entries.contains { $0.name == "[Content_Types].xml" })
        let sheet = try XCTUnwrap(entries.first { $0.name == "xl/worksheets/sheet1.xml" })
        let xml = String(data: try ZipReader.data(sheet, from: url), encoding: .utf8) ?? ""
        XCTAssertTrue(xml.contains("论语译注 &lt;精&gt; &amp; 注"), xml)
        XCTAssertTrue(xml.contains(#"<c r="B2"><v>12.5</v></c>"#), xml)
        XCTAssertTrue(xml.contains(#"<c r="A1" t="inlineStr" s="1">"#), xml)
        XCTAssertNotNil(try? XMLDocument(data: try ZipReader.data(sheet, from: url)))
        XCTAssertEqual(XLSXWriter.column(0), "A")
        XCTAssertEqual(XLSXWriter.column(25), "Z")
        XCTAssertEqual(XLSXWriter.column(26), "AA")
    }

    func testPackageNames() {
        let names = PackageNames.unique(["/a/讲义.pptx", "/b/讲义.pptx", "/c/讲义.PPTX", "/c/书单.pdf"]).map(\.name)
        XCTAssertEqual(names, ["讲义.pptx", "讲义 (2).pptx", "讲义 (3).PPTX", "书单.pdf"])
    }
}
