import XCTest
@testable import KongSeekCore

final class BuildLogProgressTests: XCTestCase {
    func testFollowsABuild() {
        var progress = BuildLogProgress(expectedTests: 4)
        XCTAssertEqual(progress.stage, .starting)
        progress.consume("== KongSeek build 2026-10-27 14:18:30 ==")
        progress.consume("== tests ==")
        XCTAssertEqual(progress.stage, .buildingTests)
        progress.consume("[5 / 20] Compiling KongSeekCore Query.swift")
        XCTAssertEqual(progress.fraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(progress.detail, "正在编译测试（5 / 20）")
        progress.consume("Test Suite 'All tests' started at 2026-10-27 14:18:31.051.")
        XCTAssertEqual(progress.stage, .runningTests)
        progress.consume("Test Case '-[KongSeekCoreTests.A testOne]' started.")
        progress.consume("Test Case '-[KongSeekCoreTests.A testOne]' passed (0.005 seconds).")
        progress.consume("Test Case '-[KongSeekCoreTests.A testTwo]' failed (0.005 seconds).")
        XCTAssertEqual(progress.testsRun, 2)
        XCTAssertEqual(progress.failedTests, ["A testTwo"])
        XCTAssertEqual(progress.detail, "测试：已通过 1 / 4 项，1 项未通过")
        XCTAssertEqual(progress.fraction, 0.5, accuracy: 0.001)
        progress.consume("\t Executed 117 tests, with 1 failure (0 unexpected) in 8.722 (8.853) seconds")
        XCTAssertEqual(progress.executedTests, 117)
        let beforeCompile = progress.overall
        progress.consume("== compile ==")
        XCTAssertEqual(progress.stage, .compiling)
        XCTAssertGreaterThanOrEqual(progress.overall, beforeCompile)
        progress.consume("[10/40] Compiling KongSeek AppDelegate.swift")
        XCTAssertEqual(progress.detail, "正在编译新版本（10 / 40）")
        progress.consume("== tests ==")
        XCTAssertEqual(progress.stage, .compiling, "stages never go back")
        progress.consume("== sign ==")
        XCTAssertEqual(progress.stage, .packaging)
        progress.consume("Built: /Users/x/kongseek/build/KongSeek.app")
        XCTAssertEqual(progress.stage, .finished)
        XCTAssertEqual(progress.overall, 1)
    }

    func testHelpers() {
        XCTAssertNil(BuildLogProgress.stepCounter("[x / 3]"))
        XCTAssertNil(BuildLogProgress.stepCounter("[4 / 3]"))
        XCTAssertNil(BuildLogProgress.stepCounter("Compiling"))
        XCTAssertEqual(BuildLogProgress.executedCount("Executed 9 tests"), 9)
        XCTAssertEqual(BuildLogProgress.testName("Test Case '-[KongSeekCoreTests.RelevanceTests testX]' failed (0.02 seconds)."), "RelevanceTests testX")
    }

    func testCompilerErrors() {
        // As swift build printed it on the Mac (colors and a documentation link).
        let line = "/Users/x/kongseek/Sources/KongSeek/Updater.swift:286:24: \u{1B}[1;31merror: \u{1B}[1;39moverlapping accesses to '$0.progress', but modification requires exclusive access; consider copying to a local variable\u{1B}[0;0m [#\u{1B}]8;;https://docs.swift.org/compiler/documentation/diagnostics/exclusivity-violation\u{1B}\\ExclusivityViolation\u{1B}]8;;\u{1B}\\]"
        var progress = BuildLogProgress()
        progress.consume("== tests ==")
        progress.consume(line)
        progress.consume(line)
        progress.consume("error: SwiftCompile normal arm64 /Users/x/Updater.swift failed with a nonzero exit code. Command line: cd /Users")
        XCTAssertEqual(progress.compileErrors, ["Updater.swift 第 286 行：overlapping accesses to '$0.progress', but modification requires exclusive access; consider copying to a local variable"])
        XCTAssertNil(BuildLogProgress.compileError("error: Build failed"))
    }
}
