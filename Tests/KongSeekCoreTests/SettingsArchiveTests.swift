import XCTest
@testable import KongSeekCore

final class SettingsArchiveTests: XCTestCase {
    func testRoundTripKeepsOnlyChoicesAndMovesHomePaths() throws {
        let defaults: [String: Any] = [
            "autoPaste": true,
            "roots": ["/Users/kong", "/Users/kong/Library/Mobile Documents/com~apple~CloudDocs", "/Applications"],
            "ocrFolders": ["/Users/kong/Documents/扫描"],
            "searchShortcut": Data([1, 2, 3]),
            "clipboardRetentionDays": 30,
            "hasLaunchedBefore": true,
            "openCounts": ["/Users/kong/a.pdf": 3],
            "NSWindow Frame Settings": "0 0 100 100",
            "AppleLanguages": ["zh-Hans"],
        ]
        let snippet = TextSnippet(name: "落款", keyword: ";lk", content: "此致\n敬礼")
        let archive = SettingsArchive(defaults: defaults, snippets: [snippet], appVersion: "0.9.0", home: "/Users/kong")
        XCTAssertEqual(Set(archive.defaults.keys), ["autoPaste", "roots", "ocrFolders", "searchShortcut", "clipboardRetentionDays"])
        XCTAssertEqual(archive.defaults["roots"] as? [String], ["~", "~/Library/Mobile Documents/com~apple~CloudDocs", "/Applications"])

        let decoded = try SettingsArchive.decode(archive.encoded())
        XCTAssertEqual(Set(decoded.defaults.keys), Set(archive.defaults.keys))
        XCTAssertEqual(decoded.snippets.map(\.content), ["此致\n敬礼"])
        XCTAssertEqual(decoded.appVersion, "0.9.0")

        let restored = decoded.restoredDefaults(home: "/Users/xiangrui")
        XCTAssertEqual(restored["roots"] as? [String], ["/Users/xiangrui", "/Users/xiangrui/Library/Mobile Documents/com~apple~CloudDocs", "/Applications"])
        XCTAssertEqual(restored["ocrFolders"] as? [String], ["/Users/xiangrui/Documents/扫描"])
        XCTAssertEqual(restored["searchShortcut"] as? Data, Data([1, 2, 3]))
        XCTAssertEqual(restored["autoPaste"] as? Bool, true)
        XCTAssertEqual(restored["clipboardRetentionDays"] as? Int, 30)
    }

    func testRejectsOtherFiles() {
        XCTAssertThrowsError(try SettingsArchive.decode(Data("hello".utf8)))
        let other = try! PropertyListSerialization.data(fromPropertyList: ["format": "KongFetch settings", "defaults": [:]], format: .xml, options: 0)
        XCTAssertThrowsError(try SettingsArchive.decode(other)) { error in
            XCTAssertEqual(error.localizedDescription, "这不是 KongSeek 导出的设置文件。")
        }
    }

    func testVersionsAndReleaseNotes() {
        XCTAssertTrue(ReleaseNotes.isNewer("0.10.0", than: "0.9.1"))
        XCTAssertTrue(ReleaseNotes.isNewer("1.0", than: "0.99.9"))
        XCTAssertFalse(ReleaseNotes.isNewer("0.9.0", than: "0.9"))
        XCTAssertFalse(ReleaseNotes.isNewer("0.8.0", than: "0.9.0"))

        let log = """
        # 更新记录

        ## 0.10.0 — 2026-11-01

        - 新功能 B

        ## 0.9.0 — 2026-10-27

        - 新功能 A
          第二行

        ## 0.8.0 — 2026-10-27

        - 旧功能
        """
        let sections = ReleaseNotes.sections(in: log, newerThan: "0.8.0")
        XCTAssertEqual(sections.map(\.version), ["0.10.0", "0.9.0"])
        XCTAssertEqual(sections[1].body, "- 新功能 A\n  第二行")
        XCTAssertTrue(ReleaseNotes.sections(in: log, newerThan: "0.10.0").isEmpty)

        let plist = try! PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.9.0"], format: .xml, options: 0)
        XCTAssertEqual(ReleaseNotes.version(inInfoPlist: plist), "0.9.0")
    }
}
