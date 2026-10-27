import Foundation

/// Writes .zip files with stored (uncompressed) entries, streaming from disk so
/// large slide decks need not fit in memory (0.22). Archives up to 4 GB (no Zip64);
/// names are UTF-8 (flag bit 11), which macOS and recent Windows read correctly.
public final class ZipWriter {
    public enum Failure: Error, Equatable {
        case cannotCreate, tooLarge, unreadable(String)
    }

    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var central = Data()
    private var count = 0

    public init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else {
            throw Failure.cannotCreate
        }
        self.handle = handle
    }

    /// Adds data under `name`.
    public func add(_ data: Data, as name: String) throws {
        try add(name: name, size: UInt64(data.count), crc: CRC32.checksum(data)) { write in try write(data) }
    }

    /// Adds a file's contents under `name`, read in pieces.
    public func addFile(_ url: URL, as name: String) throws {
        guard let input = try? FileHandle(forReadingFrom: url) else { throw Failure.unreadable(url.lastPathComponent) }
        defer { try? input.close() }
        // First pass: size and checksum; second pass: copy.
        var crc = CRC32()
        var size: UInt64 = 0
        while let piece = try input.read(upToCount: 4 << 20), !piece.isEmpty {
            crc.update(piece)
            size += UInt64(piece.count)
        }
        try input.seek(toOffset: 0)
        try add(name: name, size: size, crc: crc.value) { write in
            while let piece = try input.read(upToCount: 4 << 20), !piece.isEmpty { try write(piece) }
        }
    }

    private func add(name: String, size: UInt64, crc: UInt32, body: ((Data) throws -> Void) throws -> Void) throws {
        let nameData = Data(name.utf8)
        guard size < 0xFFFF_FFFF, offset + size + UInt64(nameData.count) + 30 < 0xFFFF_FFFF else { throw Failure.tooLarge }
        let (time, date) = Self.dosTime(Date())
        var local = Data()
        local.append(le32: 0x0403_4b50)
        local.append(le16: 20)          // version needed
        local.append(le16: 0x0800)      // UTF-8 names
        local.append(le16: 0)           // stored
        local.append(le16: time)
        local.append(le16: date)
        local.append(le32: crc)
        local.append(le32: UInt32(size))
        local.append(le32: UInt32(size))
        local.append(le16: UInt16(nameData.count))
        local.append(le16: 0)
        local.append(nameData)
        let headerOffset = offset
        try write(local)
        try body { try self.write($0) }

        var entry = Data()
        entry.append(le32: 0x0201_4b50)
        entry.append(le16: 20)          // made by
        entry.append(le16: 20)
        entry.append(le16: 0x0800)
        entry.append(le16: 0)
        entry.append(le16: time)
        entry.append(le16: date)
        entry.append(le32: crc)
        entry.append(le32: UInt32(size))
        entry.append(le32: UInt32(size))
        entry.append(le16: UInt16(nameData.count))
        entry.append(le16: 0)           // extra
        entry.append(le16: 0)           // comment
        entry.append(le16: 0)           // disk
        entry.append(le16: 0)           // internal attributes
        entry.append(le32: 0)           // external attributes
        entry.append(le32: UInt32(headerOffset))
        entry.append(nameData)
        central.append(entry)
        count += 1
    }

    /// Writes the central directory and closes the file.
    public func finish() throws {
        let start = offset
        try write(central)
        var end = Data()
        end.append(le32: 0x0605_4b50)
        end.append(le16: 0)
        end.append(le16: 0)
        end.append(le16: UInt16(count))
        end.append(le16: UInt16(count))
        end.append(le32: UInt32(central.count))
        end.append(le32: UInt32(start))
        end.append(le16: 0)
        try write(end)
        try handle.close()
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    static func dosTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

/// CRC-32 (IEEE), as zip files use.
public struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private var crc: UInt32 = 0xFFFF_FFFF
    public init() {}

    public mutating func update(_ data: Data) {
        var c = crc
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes { c = Self.table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        crc = c
    }

    public var value: UInt32 { crc ^ 0xFFFF_FFFF }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.value
    }
}

extension Data {
    mutating func append(le16 value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}

/// A one-sheet Excel workbook (.xlsx) of text and numbers, with a bold, frozen
/// header row and column widths (0.22).
public enum XLSXWriter {
    public enum Cell: Equatable {
        case text(String)
        case number(Double)
    }

    public static func write(rows: [[Cell]], columnWidths: [Double] = [], sheetName: String = "Sheet1", to url: URL) throws {
        let zip = try ZipWriter(url: url)
        try zip.add(Data(contentTypes.utf8), as: "[Content_Types].xml")
        try zip.add(Data(rootRels.utf8), as: "_rels/.rels")
        try zip.add(Data(workbook(sheetName).utf8), as: "xl/workbook.xml")
        try zip.add(Data(workbookRels.utf8), as: "xl/_rels/workbook.xml.rels")
        try zip.add(Data(styles.utf8), as: "xl/styles.xml")
        try zip.add(Data(sheet(rows: rows, widths: columnWidths).utf8), as: "xl/worksheets/sheet1.xml")
        try zip.finish()
    }

    static func escape(_ text: String) -> String {
        // Characters XML 1.0 does not allow are dropped.
        var clean = ""
        for scalar in text.unicodeScalars where scalar.value == 0x9 || scalar.value == 0xA || scalar.value == 0xD || scalar.value >= 0x20 {
            clean.unicodeScalars.append(scalar)
        }
        return clean
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// "A", "B", … "Z", "AA" …
    static func column(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(65 + r)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    static func sheet(rows: [[Cell]], widths: [Double]) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        xml += #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        xml += #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
        if !widths.isEmpty {
            xml += "<cols>" + widths.enumerated().map { #"<col min="\#($0.offset + 1)" max="\#($0.offset + 1)" width="\#($0.element)" customWidth="1"/>"# }.joined() + "</cols>"
        }
        xml += "<sheetData>"
        for (r, row) in rows.enumerated() {
            xml += #"<row r="\#(r + 1)">"#
            for (c, cell) in row.enumerated() {
                let reference = column(c) + String(r + 1)
                let style = r == 0 ? #" s="1""# : ""
                switch cell {
                case .text(let text):
                    xml += #"<c r="\#(reference)" t="inlineStr"\#(style)><is><t xml:space="preserve">\#(escape(text))</t></is></c>"#
                case .number(let value):
                    xml += #"<c r="\#(reference)"\#(style)><v>\#(value)</v></c>"#
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    static let contentTypes = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>"#

    static let rootRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#

    static func workbook(_ name: String) -> String {
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\#(escape(String(name.prefix(31))))" sheetId="1" r:id="rId1"/></sheets></workbook>"#
    }

    static let workbookRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#

    static let styles = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="12"/><name val="PingFang SC"/></font><font><b/><sz val="12"/><name val="PingFang SC"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>"#
}

/// Names for copying many files into one folder or archive (课程材料打包, 0.22):
/// each file keeps its name; a name used twice gets " (2)", " (3)" ….
public enum PackageNames {
    public static func unique(_ paths: [String]) -> [(path: String, name: String)] {
        var taken = Set<String>()
        return paths.map { path in
            let name = (path as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            var candidate = name
            var number = 2
            while taken.contains(candidate.lowercased()) {
                candidate = "\(stem) (\(number))" + (ext.isEmpty ? "" : "." + ext)
                number += 1
            }
            taken.insert(candidate.lowercased())
            return (path, candidate)
        }
    }
}
