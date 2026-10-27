import XCTest
@testable import KongSeekCore

final class PathDisplayTests: XCTestCase {
    func testPathDisplay() {
        let home = "/Users/k"
        XCTAssertEqual(PathDisplay.pretty("/Users/k/Library/Mobile Documents/com~apple~CloudDocs/ebook", home: home), "iCloud 云盘/ebook")
        XCTAssertEqual(PathDisplay.pretty("/Users/k/Library/Mobile Documents/com~apple~CloudDocs", home: home), "iCloud 云盘")
        XCTAssertEqual(PathDisplay.pretty("/Users/k/Library/Mobile Documents/iCloud~com~xmind~brownieapp/Documents/课", home: home), "iCloud 云盘（brownieapp）/课")
        XCTAssertEqual(PathDisplay.pretty("/Users/k/Library/CloudStorage/GoogleDrive-a@b.com/My Drive", home: home), "GoogleDrive/My Drive")
        XCTAssertEqual(PathDisplay.pretty("/Users/k/Documents/GitHub", home: home), "~/Documents/GitHub")
        XCTAssertEqual(PathDisplay.pretty("/Applications", home: home), "/Applications")
    }
}
