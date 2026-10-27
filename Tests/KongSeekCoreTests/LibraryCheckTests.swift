import XCTest
import CoreGraphics
@testable import KongSeekCore
@testable import KongSeekText

/// 书库体检 (0.21).
final class LibraryCheckTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func pdf(_ name: String, password: String? = nil) -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        var info: [CFString: Any] = [:]
        if let password { info[kCGPDFContextUserPassword] = password; info[kCGPDFContextOwnerPassword] = password }
        let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    func testProblems() throws {
        XCTAssertNil(LibraryCheck.inspect(pdf("good.pdf")))
        XCTAssertEqual(LibraryCheck.inspect(pdf("locked.pdf", password: "secret")), .lockedPDF)
        let broken = folder.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.4 not really".utf8).write(to: broken)
        XCTAssertEqual(LibraryCheck.inspect(broken), .unreadablePDF)
        let epub = folder.appendingPathComponent("bad.epub")
        try Data("PK not a zip".utf8).write(to: epub)
        XCTAssertEqual(LibraryCheck.inspect(epub), .unreadableEPUB)
        XCTAssertEqual(LibraryCheck.quickProblem(path: "/d/书.pdf.crdownload", size: 1000), .partialDownload)
        XCTAssertEqual(LibraryCheck.quickProblem(path: "/d/书.pdf", size: 0), .empty)
        XCTAssertNil(LibraryCheck.quickProblem(path: "/d/空.swift", size: 0), "only documents count")
        XCTAssertNil(LibraryCheck.quickProblem(path: "/d/书.pdf", size: 10))
    }
}
