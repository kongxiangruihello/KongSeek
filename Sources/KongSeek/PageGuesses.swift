import Foundation
import KongSeekCore
import KongSeekText

/// 推测书上页码 (0.31): guesses for PDFs that number neither their pages nor have been
/// told "PDF 第 N 页 = 书上第 M 页", from the page numbers in their running heads and feet.
/// Worked out once per file per session, in the background. Main thread only.
enum PageGuesses {
    private static var known: [String: PageNumberGuess.Guess?] = [:]

    /// The guess already worked out for `path`, if any.
    static func cached(_ path: String) -> PageNumberGuess.Guess? {
        known[path] ?? nil
    }

    /// Works out guesses for `paths` (at most 12 new ones at a time) and reports each found.
    static func guess(_ paths: [String], each: @escaping (String, PageNumberGuess.Guess) -> Void) {
        var pending: [String] = []
        for path in paths {
            if let earlier = known[path] {
                if let earlier { each(path, earlier) }
            } else if pending.count < 12 {
                pending.append(path)
            }
        }
        guard !pending.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for path in pending {
                let guess = compute(path)
                DispatchQueue.main.async {
                    known[path] = .some(guess)
                    if let guess { each(path, guess) }
                }
            }
        }
    }

    /// Reads the file's text (from the text cache when it has it) and looks at a sample of pages.
    static func compute(_ path: String) -> PageNumberGuess.Guess? {
        guard path.lowercased().hasSuffix(".pdf"), let store = ReaderWindowController.ocrStore,
              let pages = QuoteLookup.readCached(URL(fileURLWithPath: path), ocr: store),
              pages.isPaged, pages.pageLabels.isEmpty else { return nil }
        let sample = PageNumberGuess.samplePages(total: pages.totalPages).compactMap { number -> (pdfPage: Int, text: String)? in
            let index = number - pages.firstPage
            guard pages.pages.indices.contains(index) else { return nil }
            return (number, pages.pages[index])
        }
        guard let guess = PageNumberGuess.guess(sample), guess.offset != 0 else { return nil }
        return guess
    }
}
