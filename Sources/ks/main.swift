import Foundation
import KongSeekCore
import KongSeekText

// ks: search KongSeek's name index from the terminal, or (`ks mcp`) serve it to
// Claude and other MCP clients over stdio.
//
// Reads the index file the app keeps (~/Library/Application Support/KongSeek/
// name-index.ksidx), so it needs no running app. The app writes that file about
// 20 seconds after files change; items that no longer exist are left out.

let usage = """
用法：ks [选项] 查询…
      ks mcp              作为 MCP 服务运行（供 Claude 桌面版等调用，见 设置 › 通用）

按文件名（含拼音、首字母）在 KongSeek 的索引中搜索，每行输出一个路径。查询语法与搜索窗口相同：
  合同 2024          每个词都要出现（hetong、ht 也可）
  "年度 合同"  -草稿   短语 / 排除
  ext:pdf,docx       扩展名            pdf 文档 图片 文件夹 …  开头写类型
  path:讲义          路径中含有         in:~/Documents  in:论语   在某文件夹（及子文件夹）中
  parent:~/Desktop   直接在某文件夹中   file:  folder:            只要文件 / 只要文件夹
  size:>10mb  size:1mb..20mb  size:empty        dm:today  dm:7d  dm:2024-10  dm:>=2024-01-01
  regex:^第.+讲\\.pdf$                         dupe:   同名文件
  最近一周  大于100MB  标签:工作

选项：
  -n, --limit N      最多输出 N 条（默认 50；0 为不限）
  -c, --count        只输出匹配数量
  -0, --null         以 NUL 分隔（配合 xargs -0）
      --json         输出 JSON（path、name、kind、score）
  -o, --open         用默认应用打开第一条结果
  -r, --reveal       在访达中显示第一条结果
  -p, --path-match   关键词也匹配所在文件夹的路径（默认跟随 KongSeek 设置）
      --index FILE   使用指定的索引文件
      --info         显示索引的位置、条目数和更新时间
  -h, --help         显示本说明
      --version      显示版本

退出码：0 有结果，1 没有结果，2 用法错误或无法读取索引。
"""

let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("ks: " + message + "\n").utf8))
    exit(2)
}

// MARK: - Index and search (shared by the command line and MCP)

/// The saved index, reloaded when the app has written a newer one.
final class IndexFile {
    let url: URL
    private var index: NameIndex?
    private var loadedStamp: Date?

    init(url: URL) { self.url = url }

    func current() throws -> NameIndex {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if let index, stamp == loadedStamp { return index }
        let loaded = try NameIndex.load(from: url)
        index = loaded
        loadedStamp = stamp
        return loaded
    }
}

struct Row {
    let path: String
    let name: String
    let kind: String
    let score: Int
}

/// Matches for `query`, best first (dupe: keeps same names together), skipping
/// items that no longer exist. `limit` 0 means all. `more` is true when matches
/// were left out by the limit.
func search(_ query: SearchQuery, in index: NameIndex, precision: MatchPrecision, limit: Int) -> (rows: [Row], more: Bool) {
    var hits = index.refined(index.search(query, precision: precision), query: query)
    if !query.advanced.dupe {
        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let la = index.name(of: a.id).count, lb = index.name(of: b.id).count
            return la != lb ? la < lb : index.path(of: a.id) < index.path(of: b.id)
        }
    }
    var rows: [Row] = []
    let fileManager = FileManager.default
    for (position, hit) in hits.enumerated() {
        if limit > 0 && rows.count >= limit { return (rows, position < hits.count) }
        let path = index.path(of: hit.id)
        guard fileManager.fileExists(atPath: path) else { continue }
        if query.needsMetadata && !query.acceptsMetadata(EntryMetadata.read(path: path)) { continue }
        let flags = index.flags(of: hit.id)
        let kind = flags.contains(.package) ? (path.lowercased().hasSuffix(".app") ? "app" : "package")
            : (flags.contains(.directory) ? "folder" : (flags.contains(.symlink) ? "symlink" : "file"))
        rows.append(Row(path: path, name: index.name(of: hit.id), kind: kind, score: hit.score))
    }
    return (rows, false)
}

let appDefaults = UserDefaults(suiteName: "com.kongxiangrui.KongSeek")
let defaultPrecision: MatchPrecision = appDefaults?.bool(forKey: "matchFolderPath") == true ? .withPath : .fuzzyName
let defaultIndexURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("KongSeek/name-index.ksidx")

// MARK: - MCP

func runMCP(indexURL: URL) -> Never {
    let file = IndexFile(url: indexURL)
    let kindNames = ["file": "文件", "folder": "文件夹", "app": "应用", "package": "包", "symlink": "替身"]
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

    let searchTool = MCPServer.Tool(
        name: "search_files",
        description: """
        Search the user's Mac for files, folders and apps by name with KongSeek's local index (instant; covers the \
        home folder, iCloud Drive and Applications). Matches name substrings, abbreviations and Chinese pinyin \
        (full spelling or initials, e.g. "lunyu" or "ly" finds 论语). Every word must match. Syntax: "exact phrase", \
        -exclude, ext:pdf,docx, path:text (anywhere in the path), in:~/Documents or in:FolderName (below a folder), \
        parent:~/Desktop (directly inside), size:>10mb, size:1mb..20mb, dm:today, dm:7d, dm:2024-10, dm:>=2024-01-01, \
        regex:^draft, file:, folder:, dupe: (only duplicated names). A query of only operators (e.g. "dm:today ext:pdf") \
        lists everything that passes them. Returns absolute paths with kind, size and modification time.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Search text using the syntax above, e.g. \"论语 讲义 ext:pdf dm:thisyear\"."] as [String: Any],
                "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Maximum results (default 30)."] as [String: Any],
            ] as [String: Any],
            "required": ["query"],
        ]
    ) { arguments in
        guard let text = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw MCPServer.ToolError("query is required")
        }
        let limit = min(200, max(1, (arguments["limit"] as? NSNumber)?.intValue ?? 30))
        let query = SearchQuery(text)
        guard query.valid else { throw MCPServer.ToolError("Invalid query: " + query.notes.joined(separator: "; ")) }
        let index: NameIndex
        do { index = try file.current() } catch {
            throw MCPServer.ToolError("KongSeek's index could not be read (\(error)). Open the KongSeek app once to build it.")
        }
        let found = search(query, in: index, precision: defaultPrecision, limit: limit)
        guard !found.rows.isEmpty else { return "No files match “\(text)”." }
        var lines = ["\(found.rows.count) result(s) for “\(text)”" + (found.more ? " (more exist; refine the query or raise limit)" : "") + ":"]
        for row in found.rows {
            var details = [kindNames[row.kind] ?? row.kind]
            var info = stat()
            if lstat(row.path, &info) == 0 {
                if row.kind != "folder" { details.append(ByteCountFormatter.string(fromByteCount: Int64(info.st_size), countStyle: .file)) }
                details.append(dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))))
            }
            lines.append("\(row.path)  [\(details.joined(separator: " · "))]")
        }
        return lines.joined(separator: "\n")
    }

    let infoTool = MCPServer.Tool(
        name: "index_info",
        description: "Report which folders KongSeek's index covers, how many items it holds and when it was last updated.",
        inputSchema: ["type": "object", "properties": [String: Any]()]
    ) { _ in
        let index: NameIndex
        do { index = try file.current() } catch { throw MCPServer.ToolError("KongSeek's index could not be read: \(error)") }
        return """
        Folders: \(index.roots.joined(separator: ", "))
        Items: \(index.entryCount) (\(index.directoryCount) folders)
        Updated: \(ISO8601DateFormatter().string(from: index.updated))\(index.isComplete ? "" : "\nThe index is still being built.")
        """
    }

    // MARK: Content (search_content, read_file)

    /// Whether the user lets MCP clients read file contents (设置 › 通用).
    func contentAllowed() throws {
        let allowed = UserDefaults(suiteName: "com.kongxiangrui.KongSeek")?.object(forKey: "mcpReadContent") as? Bool ?? true
        guard allowed else {
            throw MCPServer.ToolError("Reading file contents is turned off in KongSeek › 设置 › 通用 (“允许 Claude 读取文件正文”). Ask the user to turn it on, or use search_files for names only.")
        }
    }

    /// KongSeek's recognized text of scans, reloaded when the app has added some.
    let ocrDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KongSeek/OCR")
    let ocrStore = OCRStore(directory: ocrDirectory)
    var ocrStamp: Date?
    func currentOCR() -> OCRStore {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: ocrDirectory.path)[.modificationDate]) as? Date
        if stamp != ocrStamp {
            ocrStore.load()
            ocrStamp = stamp
        }
        return ocrStore
    }

    let contentTool = MCPServer.Tool(
        name: "search_content",
        description: """
        Full-text search inside the user's documents (PDF, Word, Pages, Keynote, text …) with macOS Spotlight, plus text KongSeek recognized from scanned PDFs and images. Every word must occur in the document. Supports "phrases", ext:pdf, in:~/Documents or in:FolderName, path:, size:, dm: (e.g. "克己复礼 ext:pdf,docx in:讲义"). Returns paths with the matching passage and its PDF page. Use read_file to read a result.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Words to find in the text, with optional filters."] as [String: Any],
                "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Maximum documents (default 10)."] as [String: Any],
            ] as [String: Any],
            "required": ["query"],
        ]
    ) { arguments in
        try contentAllowed()
        guard let text = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw MCPServer.ToolError("query is required")
        }
        let limit = min(50, max(1, (arguments["limit"] as? NSNumber)?.intValue ?? 10))
        let query = SearchQuery(text)
        guard query.valid else { throw MCPServer.ToolError("Invalid query: " + query.notes.joined(separator: "; ")) }
        guard let spotlight = SpotlightQuery.content(for: query) else { throw MCPServer.ToolError("Give at least one word to look for.") }
        let index: NameIndex
        do { index = try file.current() } catch {
            throw MCPServer.ToolError("KongSeek's index could not be read (\(error)). Open the KongSeek app once to build it.")
        }
        let roots = index.roots, rules = index.rules
        let excluded = query.excluded.map(SearchText.fold)
        func keep(_ path: String, isFolder: Bool) -> Bool {
            guard !rules.excludes(path: path, roots: roots), query.advanced.acceptsPath(path, isFolder: isFolder) else { return false }
            let name = SearchText.fold((path as NSString).lastPathComponent)
            return !excluded.contains { name.contains($0) }
        }
        let ocr = currentOCR()
        let needles = query.highlightWords
        let recognized = ocr.search(needles, limit: 100) { keep($0, isFolder: false) }
        guard let found = ContentSearch.runToEnd(spotlight, scopes: roots, maximumHits: 2000, timeout: 20) else {
            throw MCPServer.ToolError("Spotlight could not run this search.")
        }
        var seen = Set(recognized.map(\.path))
        // Documents (PDF, Word, slides, text) before code and data files such as .json or .swift,
        // which Spotlight ranks just as high; then Spotlight's relevance, then newest.
        let documentTypes: Set<String> = ["pdf", "doc", "docx", "pages", "ppt", "pptx", "key", "xls", "xlsx", "numbers",
                                          "rtf", "rtfd", "odt", "txt", "md", "markdown", "epub", "tex"]
        func isDocument(_ path: String) -> Bool { documentTypes.contains((path as NSString).pathExtension.lowercased()) }
        let spotlightPaths = found.filter { !$0.isFolder && keep($0.path, isFolder: false) }
            .sorted { a, b in
                let da = isDocument(a.path), db = isDocument(b.path)
                if da != db { return da }
                return a.relevance != b.relevance ? a.relevance > b.relevance : (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            }
            .map(\.path).filter { seen.insert($0).inserted }
        let total = recognized.count + spotlightPaths.count
        guard total > 0 else { return "No documents contain “\(text)”. (Spotlight must have indexed the files; scanned PDFs need KongSeek's text recognition.)" }
        var lines = ["\(min(total, limit)) of \(total) document(s) containing “\(text)”:"]
        for hit in recognized.prefix(limit) {
            lines.append("\(hit.path)  [" + (hit.page.map { "第 \($0) 页 · " } ?? "") + "识别文字]")
            lines.append("    " + hit.snippet.text)
        }
        for path in spotlightPaths.prefix(max(0, limit - recognized.count)) {
            switch ContentPreview.find(in: URL(fileURLWithPath: path), needles: needles, ocr: ocr) {
            case .found(let place):
                let unit = (path as NSString).pathExtension.lowercased() == "pptx" ? "张幻灯片" : "页"
                lines.append("\(path)" + (place.page.map { "  [第 \($0) \(unit)]" } ?? ""))
                lines.append("    " + place.snippet.text)
            case .notDownloaded:
                lines.append("\(path)  [only in iCloud, not downloaded]")
            default:
                lines.append(path)
            }
        }
        if total > limit { lines.append("(\(total - limit) more; refine the query or raise limit)") }
        return lines.joined(separator: "\n")
    }

    let readTool = MCPServer.Tool(
        name: "read_file",
        description: """
        Read the text of a document in the folders KongSeek indexes: PDF (by page; scanned pages use KongSeek's recognized text), PowerPoint .pptx (by slide, with speaker notes), Word, Excel .xlsx, RTF, OpenDocument, plain text and Markdown (UTF-8 or GB18030), and recognized images. Files kept only in iCloud are downloaded first. Long documents come in parts: the reply ends with the start_page (PDF) or offset (other files) to continue from.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Absolute path, as returned by search_files or search_content (~ allowed)."] as [String: Any],
                "start_page": ["type": "integer", "minimum": 1, "description": "PDF or .pptx: first page / slide to read (default 1)."] as [String: Any],
                "offset": ["type": "integer", "minimum": 0, "description": "Other files: character offset to start at (default 0)."] as [String: Any],
                "max_characters": ["type": "integer", "minimum": 1000, "maximum": 100000, "description": "Maximum characters returned (default 20000)."] as [String: Any],
            ] as [String: Any],
            "required": ["path"],
        ]
    ) { arguments in
        try contentAllowed()
        guard let raw = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw MCPServer.ToolError("path is required")
        }
        let index: NameIndex
        do { index = try file.current() } catch {
            throw MCPServer.ToolError("KongSeek's index could not be read (\(error)). Open the KongSeek app once to build it.")
        }
        let path = Paths.canonical(raw)
        // Only what KongSeek indexes: never ~/Library, hidden or excluded folders.
        guard !index.rules.excludes(path: path, roots: index.roots) else {
            throw MCPServer.ToolError("This file is outside the folders KongSeek indexes (or in an excluded folder), so it is not readable here.")
        }
        let maximum = min(100_000, max(1_000, (arguments["max_characters"] as? NSNumber)?.intValue ?? 20_000))
        let startPage = max(1, (arguments["start_page"] as? NSNumber)?.intValue ?? 1)
        let offset = max(0, (arguments["offset"] as? NSNumber)?.intValue ?? 0)
        let pages: DocumentText.Pages
        do {
            // Enough pages to fill the reply; excerpt() stops at the character limit.
            // Files kept only in iCloud are downloaded first (up to 200 MB, waiting up to a minute).
            pages = try DocumentText.read(URL(fileURLWithPath: path), firstPage: startPage, maximumPages: max(5, maximum / 400),
                                          ocr: currentOCR(), downloadWait: 60)
        } catch let failure as DocumentText.Failure {
            throw MCPServer.ToolError(failure.message)
        }
        let part = DocumentText.excerpt(pages, offset: offset, maximumCharacters: maximum)
        var header = path
        if pages.isPaged {
            let last = (part.nextPage ?? (pages.totalPages + 1)) - 1
            let kind = pages.unit == "页" ? "PDF, \(pages.totalPages) pages; showing pages" : "Presentation, \(pages.totalPages) slides; showing slides"
            header += "\n\(kind) \(pages.firstPage)–\(max(pages.firstPage, last))"
        } else {
            let length = pages.pages.first?.count ?? 0
            header += "\n\(length) characters; showing \(offset)–\(part.nextOffset ?? length)"
        }
        var footer = ""
        if let next = part.nextPage { footer = "\n[Continue with start_page=\(next)]" }
        if let next = part.nextOffset { footer = "\n[Continue with offset=\(next)]" }
        return header + "\n\n" + part.text + footer
    }

    let server = MCPServer(
        name: "kongseek", version: version,
        instructions: """
        KongSeek indexes the user's files. search_files finds files by name (Chinese pinyin works); search_content finds documents by the words inside them; read_file reads a document's text (PDF by page). The user's files are mostly Chinese; prefer Chinese search words when the user writes in Chinese.
        """,
        tools: [searchTool, contentTool, readTool, infoTool]
    )
    while let line = readLine(strippingNewline: true) {
        if let reply = server.handle(line) {
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }
    exit(0)
}

// MARK: - Command line

var limit = 50
var countOnly = false
var nullSeparated = false
var json = false
var openFirst = false
var revealFirst = false
var info = false
var precision = defaultPrecision
var indexURL = defaultIndexURL
var terms: [String] = []

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "mcp" {
    var url = defaultIndexURL
    if arguments.count >= 3, arguments[1] == "--index" { url = URL(fileURLWithPath: (arguments[2] as NSString).expandingTildeInPath) }
    runMCP(indexURL: url)
}

var position = 0
func nextValue(_ option: String) -> String {
    position += 1
    guard position < arguments.count else { fail("\(option) 需要一个值") }
    return arguments[position]
}
var onlyTerms = false
let shortOptions: Set<String> = ["-n", "-c", "-0", "-o", "-r", "-p", "-h"]
while position < arguments.count {
    let argument = arguments[position]
    if onlyTerms || !(argument.hasPrefix("--") || shortOptions.contains(argument)) {
        // Words such as "-草稿" or "-ext:png" are exclusions in the query, not options.
        terms.append(argument)
        position += 1
        continue
    }
    switch argument {
    case "--": onlyTerms = true
    case "-n", "--limit":
        guard let value = Int(nextValue(argument)), value >= 0 else { fail("--limit 需要非负整数") }
        limit = value
    case "-c", "--count": countOnly = true
    case "-0", "--null": nullSeparated = true
    case "--json": json = true
    case "-o", "--open": openFirst = true
    case "-r", "--reveal": revealFirst = true
    case "-p", "--path-match": precision = .withPath
    case "--index": indexURL = URL(fileURLWithPath: (nextValue(argument) as NSString).expandingTildeInPath)
    case "--info": info = true
    case "-h", "--help":
        print(usage)
        exit(0)
    case "--version":
        print("ks（KongSeek \(version)）")
        exit(0)
    default:
        fail("未知选项 \(argument)（ks --help 查看用法）")
    }
    position += 1
}

let index: NameIndex
do {
    index = try NameIndex.load(from: indexURL)
} catch {
    fail("无法读取索引 \(indexURL.path)：\(error)。请先打开 KongSeek 建立索引。")
}

if info {
    print("索引：\(indexURL.path)")
    print("条目：\(index.entryCount)（文件夹 \(index.directoryCount)）")
    print("更新：\(index.updated.formatted(date: .abbreviated, time: .standard))")
    print("范围：" + index.roots.joined(separator: "、"))
    if !index.isComplete { print("注意：索引尚未建完") }
    exit(0)
}

let text = terms.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
guard !text.isEmpty else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
let query = SearchQuery(text)
guard query.valid else { fail(query.notes.joined(separator: "；")) }

let rows = search(query, in: index, precision: precision, limit: countOnly ? 0 : limit).rows

if countOnly {
    print(rows.count)
    exit(rows.isEmpty ? 1 : 0)
}

if json {
    let objects = rows.map { ["path": $0.path, "name": $0.name, "kind": $0.kind, "score": $0.score] as [String: Any] }
    let data = (try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .withoutEscapingSlashes])) ?? Data("[]".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} else {
    let separator = nullSeparated ? "\0" : "\n"
    for row in rows {
        FileHandle.standardOutput.write(Data((row.path + separator).utf8))
    }
}

if let first = rows.first, openFirst || revealFirst {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = revealFirst ? ["-R", first.path] : [first.path]
    try? process.run()
    process.waitUntilExit()
}

exit(rows.isEmpty ? 1 : 0)
