import AppKit
import PDFKit
import CoreText
import KongSeekCore

/// Makes a searchable copy of a scanned PDF (0.20): every page is drawn as it is,
/// and the text Apple Vision recognizes on it is laid over the picture in
/// invisible type, where it stands on the page. Preview, Acrobat and Spotlight can
/// then find, select and copy the words. The original file is not changed.
public enum SearchablePDF {
    public struct Outcome: Equatable {
        public var pages: Int
        /// Pages that got a text layer.
        public var recognized: Int
        /// Pages that already had text and were copied as they are.
        public var alreadyText: Int
        /// Pages whose rotation was applied (written upright, 0.21).
        public var rotated: Int
    }

    public enum Failure: Error, Equatable {
        case unreadable
        case cancelled
        case cannotWrite
    }

    /// "<name>（可搜索）.pdf" beside the original, numbered if taken.
    public static func destination(for source: URL) -> URL {
        let folder = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent(stem + "（可搜索）.pdf")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(stem + "（可搜索 \(number)）.pdf")
            number += 1
        }
        return candidate
    }

    public static func make(from source: URL, to destination: URL, progress: (Int, Int) -> Void = { _, _ in },
                            isCancelled: () -> Bool = { false }) throws -> Outcome {
        guard let document = PDFDocument(url: source) else { throw Failure.unreadable }
        if document.isLocked && !document.unlock(withPassword: "") { throw Failure.unreadable }
        var info: [CFString: Any] = [kCGPDFContextCreator: "KongSeek"]
        if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String { info[kCGPDFContextTitle] = title }
        if let author = document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String { info[kCGPDFContextAuthor] = author }
        // Written to a temporary file first, so a cancelled run leaves nothing half-made.
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        guard let context = CGContext(temporary as CFURL, mediaBox: nil, info as CFDictionary) else { throw Failure.cannotWrite }
        var outcome = Outcome(pages: document.pageCount, recognized: 0, alreadyText: 0, rotated: 0)
        for index in 0..<document.pageCount {
            if isCancelled() {
                context.closePDF()
                try? FileManager.default.removeItem(at: temporary)
                throw Failure.cancelled
            }
            progress(index + 1, document.pageCount)
            guard let page = document.page(at: index), let ref = page.pageRef else { continue }
            autoreleasepool {
                // Each page is written upright, as it is shown: a rotated page (a landscape
                // scan) gets a box the other way round, and the recognized text fits it (0.21).
                let rotated = abs(Int(ref.rotationAngle)) % 180 == 90
                if ref.rotationAngle % 360 != 0 { outcome.rotated += 1 }
                let media = ref.getBoxRect(.mediaBox)
                var box = CGRect(x: 0, y: 0, width: rotated ? media.height : media.width, height: rotated ? media.width : media.height)
                let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
                context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                context.saveGState()
                context.concatenate(ref.getDrawingTransform(.mediaBox, rect: box, rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(ref)
                context.restoreGState()
                let existing = page.string?.filter { !$0.isWhitespace } ?? ""
                if existing.count >= ScannedPDFs.minimumCharacters {
                    outcome.alreadyText += 1
                } else if let image = render(ref, box: box), let lines = try? TextRecognizer.recognizeLines(image), !lines.isEmpty {
                    overlay(lines, in: box, context: context)
                    outcome.recognized += 1
                }
                context.endPDFPage()
            }
        }
        context.closePDF()
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.cannotWrite
        }
        return outcome
    }

    /// The page as a picture about 2400 pixels on its long side, on white, upright.
    public static func render(_ page: CGPDFPage, box: CGRect) -> CGImage? {
        guard box.width > 1, box.height > 1 else { return nil }
        let scale = min(4, 2400 / max(box.width, box.height))
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: box, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// Invisible text over each recognized line, stretched to the line's width.
    static func overlay(_ lines: [(text: String, box: CGRect)], in page: CGRect, context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines where !line.text.isEmpty {
            let rect = CGRect(x: page.minX + line.box.minX * page.width, y: page.minY + line.box.minY * page.height,
                              width: line.box.width * page.width, height: line.box.height * page.height)
            guard rect.width > 1, rect.height > 1 else { continue }
            let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, rect.height * 0.85, nil)
            let attributed = NSAttributedString(string: line.text, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let natural = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard natural > 0 else { continue }
            context.textMatrix = CGAffineTransform(scaleX: rect.width / CGFloat(natural), y: 1)
            context.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.15)
            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }
}
