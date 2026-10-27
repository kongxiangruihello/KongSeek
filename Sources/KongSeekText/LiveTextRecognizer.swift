import AppKit
import VisionKit
import KongSeekCore

/// Text recognition with VisionKit's ImageAnalyzer, the engine behind Live Text
/// (实况文本), for trying it on vertical classical Chinese (竖排古籍, 0.22). Apple
/// developer forums report that Vision's VNRecognizeTextRequest returns nothing for
/// vertical Chinese and Japanese while ImageAnalyzer reads it; whether that holds for
/// a given scan is what the trial in the reader window shows.
public enum LiveTextRecognizer {
    @MainActor public static var isSupported: Bool { ImageAnalyzer.isSupported }

    /// The recognized text of an image, in Live Text's reading order. Blocks the
    /// calling thread (never the main thread) until the analysis finishes.
    public static func recognize(_ image: CGImage, timeout: TimeInterval = 60) throws -> String {
        precondition(!Thread.isMainThread, "LiveTextRecognizer.recognize waits; call it off the main thread")
        let box = ResultBox()
        Task { @MainActor in
            do {
                let analyzer = ImageAnalyzer()
                let analysis = try await analyzer.analyze(image, orientation: .up, configuration: ImageAnalyzer.Configuration([.text]))
                box.set(.success(analysis.transcript))
            } catch {
                box.set(.failure(error))
            }
        }
        guard box.semaphore.wait(timeout: .now() + timeout) == .success else { throw CocoaError(.featureUnsupported) }
        return try box.get()
    }

    /// The outcome, handed from the analysis task to the waiting thread.
    private final class ResultBox: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Result<String, Error> = .success("")

        func set(_ value: Result<String, Error>) {
            lock.lock(); result = value; lock.unlock()
            semaphore.signal()
        }

        func get() throws -> String {
            lock.lock(); defer { lock.unlock() }
            return try result.get()
        }
    }
}
