import Foundation

/// The text of e-books Spotlight does not read (0.37): EPUB (its XHTML files in reading
/// order) and Mobipocket / Kindle files without DRM (.mobi, .azw, .azw3, PalmDOC
/// compression), after the adapters of ripgrep-all and the e-book extraction of sist2.
public enum EbookText {
    public enum Failure: Error, Equatable {
        case unreadable
        /// DRM-protected, or compressed in a way not supported (HUFF/CDIC).
        case unsupported(String)
    }

    public static let extensions: Set<String> = ["epub", "mobi", "azw", "azw3", "prc"]

    public static func supports(_ ext: String) -> Bool { extensions.contains(ext.lowercased()) }

    /// The text, one entry per EPUB content file (empty ones left out), or one entry for a Mobipocket file.
    public static func read(_ url: URL) throws -> [String] {
        if url.pathExtension.lowercased() == "epub" { return try epub(url) }
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { throw Failure.unreadable }
        let text = try mobi(data)
        return text.isEmpty ? [] : [text]
    }

    // MARK: EPUB

    static func epub(_ url: URL) throws -> [String] {
        guard let entries = try? ZipReader.entries(at: url, limit: 50_000) else { throw Failure.unreadable }
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = []
        if let container = byName["META-INF/container.xml"],
           let containerData = try? ZipReader.data(container, from: url, maximumSize: 1_000_000),
           let opfPath = EpubMetadata.rootfile(inContainer: containerData),
           let opf = byName[opfPath],
           let opfData = try? ZipReader.data(opf, from: url, maximumSize: 20_000_000),
           let opfText = String(data: opfData, encoding: .utf8) {
            let base = (opfPath as NSString).deletingLastPathComponent
            order = spine(opf: opfText).map { href in
                let decoded = href.removingPercentEncoding ?? href
                return resolve(decoded, relativeTo: base)
            }
        }
        if order.isEmpty {
            // No usable package document: the HTML files in name order.
            order = entries.map(\.name).filter { ["html", "htm", "xhtml"].contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
        }
        if entries.contains(where: { $0.name == "META-INF/encryption.xml" }), order.allSatisfy({ byName[$0]?.isEncrypted ?? true }) {
            throw Failure.unsupported("encrypted")
        }
        var pages: [String] = []
        var seen = Set<String>()
        for name in order where seen.insert(name).inserted {
            guard let entry = byName[name], !entry.isEncrypted,
                  let data = try? ZipReader.data(entry, from: url, maximumSize: 50_000_000) else { continue }
            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let text = plainText(html: html)
            if !text.isEmpty { pages.append(text) }
        }
        return pages
    }

    /// The hrefs of the spine's content documents, in reading order.
    static func spine(opf: String) -> [String] {
        var hrefByID: [String: String] = [:]
        for tag in tags(named: "item", in: opf) {
            guard let id = attribute("id", in: tag), let href = attribute("href", in: tag) else { continue }
            let type = attribute("media-type", in: tag) ?? ""
            if type.isEmpty || type.contains("html") { hrefByID[id] = href }
        }
        return tags(named: "itemref", in: opf).compactMap { tag in attribute("idref", in: tag).flatMap { hrefByID[$0] } }
    }

    static func tags(named name: String, in xml: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<(?:[A-Za-z0-9_]+:)?" + name + "\\b[^>]*>", options: [.caseInsensitive]) else { return [] }
        let text = xml as NSString
        return regex.matches(in: xml, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range) }
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\s" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        let text = tag as NSString
        for group in [2, 3] where match.range(at: group).location != NSNotFound {
            return decodeEntities(text.substring(with: match.range(at: group)))
        }
        return nil
    }

    /// "../Text/ch1.xhtml" from "OEBPS/Content" → "OEBPS/Text/ch1.xhtml".
    static func resolve(_ href: String, relativeTo base: String) -> String {
        let withoutFragment = href.components(separatedBy: "#")[0]
        var parts = base.isEmpty ? [] : base.components(separatedBy: "/")
        for part in withoutFragment.components(separatedBy: "/") {
            switch part {
            case "", ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    /// Text of an HTML document: scripts, styles and the head left out, a line break
    /// after each block, entities decoded.
    public static func plainText(html: String) -> String {
        var text = html
        for pattern in ["(?is)<head\\b.*?</head>", "(?is)<script\\b.*?</script>", "(?is)<style\\b.*?</style>", "(?s)<!--.*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</(p|div|h[1-6]|li|tr|blockquote|section|pre|dd|dt|table)\\s*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "[ \t\u{00A0}]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " *\\n[ \\n]*", with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&ldquo;": "“", "&rdquo;": "”",
                     "&lsquo;": "‘", "&rsquo;": "’", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&middot;": "·", "&emsp;": " ", "&ensp;": " "]
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9A-Fa-f]+|[0-9]+);") {
            let source = result as NSString
            var output = ""
            var last = 0
            for match in regex.matches(in: result, range: NSRange(location: 0, length: source.length)) {
                output += source.substring(with: NSRange(location: last, length: match.range.location - last))
                let code = source.substring(with: match.range(at: 1))
                let value = code.hasPrefix("x") || code.hasPrefix("X") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                if let value, let scalar = Unicode.Scalar(value) { output.unicodeScalars.append(scalar) } else { output += source.substring(with: match.range) }
                last = match.range.location + match.range.length
            }
            output += source.substring(from: last)
            result = output
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Mobipocket

    /// The text of a PalmDB e-book: its text records, PalmDOC-decompressed, as HTML turned to text.
    public static func mobi(_ data: Data) throws -> String {
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int { offset + 2 <= bytes.count ? Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) : 0 }
        func u32(_ offset: Int) -> Int {
            offset + 4 <= bytes.count ? Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]) : 0
        }
        guard bytes.count > 78 else { throw Failure.unreadable }
        let type = String(decoding: bytes[60..<68], as: UTF8.self)
        guard type == "BOOKMOBI" || type == "TEXtREAd" else { throw Failure.unreadable }
        let recordCount = u16(76)
        guard recordCount > 1, 78 + recordCount * 8 <= bytes.count else { throw Failure.unreadable }
        let offsets = (0..<recordCount).map { u32(78 + $0 * 8) } + [bytes.count]
        func record(_ index: Int) -> ArraySlice<UInt8> {
            guard index + 1 < offsets.count else { return [] }
            let start = offsets[index], end = offsets[index + 1]
            guard start < end, end <= bytes.count else { return [] }
            return bytes[start..<end]
        }
        let header = Array(record(0))
        guard header.count >= 16 else { throw Failure.unreadable }
        func h16(_ offset: Int) -> Int { offset + 2 <= header.count ? Int(header[offset]) << 8 | Int(header[offset + 1]) : 0 }
        func h32(_ offset: Int) -> Int {
            offset + 4 <= header.count ? Int(header[offset]) << 24 | Int(header[offset + 1]) << 16 | Int(header[offset + 2]) << 8 | Int(header[offset + 3]) : 0
        }
        let compression = h16(0)
        let textRecords = h16(8)
        let encryption = h16(12)
        guard encryption == 0 else { throw Failure.unsupported("DRM") }
        guard compression == 1 || compression == 2 else { throw Failure.unsupported("compression \(compression)") }
        var utf8 = false
        var extraFlags = 0
        if header.count >= 20, String(decoding: header[16..<20], as: UTF8.self) == "MOBI" {
            let mobiLength = h32(20)
            utf8 = h32(28) == 65001
            if mobiLength >= 0xE4, header.count >= 0xF4 { extraFlags = h16(0xF2) }
        }
        var output: [UInt8] = []
        for index in 1...max(1, min(textRecords, recordCount - 1)) {
            var chunk = Array(record(index))
            let trailing = trailingSize(chunk, flags: extraFlags)
            if trailing > 0 && trailing <= chunk.count { chunk.removeLast(trailing) }
            output += compression == 2 ? palmDOC(chunk) : chunk
        }
        let html = utf8 ? String(decoding: output, as: UTF8.self) : (String(bytes: output, encoding: .windowsCP1252) ?? String(decoding: output, as: UTF8.self))
        return plainText(html: html)
    }

    /// Bytes at the end of a text record that are not text (extra data flags).
    static func trailingSize(_ record: [UInt8], flags: Int) -> Int {
        var size = 0
        var test = flags >> 1
        while test != 0 {
            if test & 1 != 0 {
                // A backward-encoded variable-width size at the end of what is left.
                let end = record.count - size
                guard end > 0 else { return size }
                var value = 0
                for byte in record[max(0, end - 4)..<end] {
                    if byte & 0x80 != 0 { value = 0 }
                    value = (value << 7) | Int(byte & 0x7F)
                }
                size += value
            }
            test >>= 1
        }
        if flags & 1 != 0, record.count - size - 1 >= 0 {
            size += Int(record[record.count - size - 1] & 0x3) + 1
        }
        return size
    }

    /// PalmDOC (LZ77) decompression.
    static func palmDOC(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 2)
        var index = 0
        while index < input.count {
            let byte = input[index]
            index += 1
            switch byte {
            case 0x01...0x08:
                let end = min(input.count, index + Int(byte))
                output += input[index..<end]
                index = end
            case 0x80...0xBF:
                guard index < input.count else { break }
                let pair = Int(byte) << 8 | Int(input[index])
                index += 1
                let distance = (pair >> 3) & 0x7FF
                let length = (pair & 0x7) + 3
                guard distance > 0, distance <= output.count else { continue }
                let start = output.count - distance
                for offset in 0..<length { output.append(output[start + offset]) }
            case 0xC0...0xFF:
                output.append(0x20)
                output.append(byte ^ 0x80)
            default:
                output.append(byte)
            }
        }
        return output
    }
}
