import Foundation

/// Follows the output of scripts/build-app.sh --test line by line, so the update
/// window can say what is happening ("测试：已通过 52 / 117 项") and how far along it is.
public struct BuildLogProgress: Equatable, Sendable {
    public enum Stage: Int, Comparable, Sendable {
        case starting, buildingTests, runningTests, compiling, packaging, finished
        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    public private(set) var stage = Stage.starting
    /// Progress within the stage, 0…1, when known.
    public private(set) var fraction: Double = 0
    public private(set) var detail = "准备中…"
    public private(set) var testsRun = 0
    public private(set) var failedTests: [String] = []
    /// The largest "Executed N tests" (the total), for the next run's estimate.
    public private(set) var executedTests: Int?
    /// Tests expected (the previous run's count) until the real count is printed.
    public var expectedTests: Int

    public init(expectedTests: Int = 120) {
        self.expectedTests = max(1, expectedTests)
    }

    /// Progress over the whole build, 0…1 (stages weighted by how long they take).
    public var overall: Double {
        let spans: [Stage: (Double, Double)] = [
            .starting: (0, 0.02), .buildingTests: (0.02, 0.35), .runningTests: (0.35, 0.55),
            .compiling: (0.55, 0.92), .packaging: (0.92, 1), .finished: (1, 1),
        ]
        let (start, end) = spans[stage]!
        return start + (end - start) * min(1, max(0, fraction))
    }

    /// swift build may separate its "[3/20]" updates with carriage returns; pass
    /// each piece between \r or \n as a line.
    public mutating func consume(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        if line.hasPrefix("== tests ==") {
            advance(to: .buildingTests, "正在编译测试…")
        } else if line.hasPrefix("Test Suite 'All tests' started") {
            advance(to: .runningTests, "正在运行测试…")
        } else if line.hasPrefix("Test Case '"), line.contains("' passed") || line.contains("' failed") {
            if stage < .runningTests { advance(to: .runningTests, "") }
            testsRun += 1
            if line.contains("' failed"), let name = Self.testName(line), !failedTests.contains(name) { failedTests.append(name) }
            fraction = min(0.99, Double(testsRun) / Double(max(expectedTests, testsRun)))
            detail = "测试：已通过 \(testsRun - failedTests.count) / \(max(expectedTests, testsRun)) 项" + (failedTests.isEmpty ? "" : "，\(failedTests.count) 项未通过")
        } else if line.contains("Executed "), line.contains(" test"), let count = Self.executedCount(line) {
            // Each suite prints its own count; the last and largest is the total.
            executedTests = max(executedTests ?? 0, count)
        } else if line.hasPrefix("== compile ==") {
            advance(to: .compiling, "正在编译新版本…")
        } else if line.hasPrefix("== icon ==") || line.hasPrefix("== sign ==") {
            advance(to: .packaging, line.hasPrefix("== sign ==") ? "正在签名…" : "正在打包…")
        } else if line.hasPrefix("Built: ") {
            advance(to: .finished, "编译完成")
        } else if let (done, total) = Self.stepCounter(line), stage == .buildingTests || stage == .compiling {
            fraction = Double(done) / Double(max(1, total))
            detail = (stage == .buildingTests ? "正在编译测试" : "正在编译新版本") + "（\(done) / \(total)）"
        }
    }

    private mutating func advance(to next: Stage, _ text: String) {
        guard next >= stage else { return }
        if next > stage { fraction = 0 }
        stage = next
        if !text.isEmpty { detail = text }
    }

    /// "[12 / 40] Compiling …" or "[12/40] …"
    static func stepCounter(_ line: String) -> (Int, Int)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let parts = line[line.index(after: line.startIndex)..<close].split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]), total > 0, done <= total else { return nil }
        return (done, total)
    }

    /// "Executed 117 tests, with 1 failure …" → 117
    static func executedCount(_ line: String) -> Int? {
        guard let range = line.range(of: "Executed ") else { return nil }
        return Int(line[range.upperBound...].prefix { $0.isNumber })
    }

    /// "Test Case '-[Module.SuiteTests testName]' failed (…)" → "SuiteTests testName"
    static func testName(_ line: String) -> String? {
        guard let open = line.range(of: "-["), let close = line.range(of: "]'", range: open.upperBound..<line.endIndex) else { return nil }
        let full = line[open.upperBound..<close.lowerBound]
        return String(full.split(separator: ".").last ?? full)
    }
}
