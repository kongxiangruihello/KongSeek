import Foundation
import KongSeekCore

// ks: search KongSeek's name index from the terminal.
//
// Reads the index file the app keeps (~/Library/Application Support/KongSeek/
// name-index.ksidx), so it needs no running app and starts in well under a
// second. The app writes that file about 20 seconds after files change; items
// that no longer exist are left out of the output.

let usage = """
用法：ks [选项] 查询…

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

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("ks: " + message + "\n").utf8))
    exit(2)
}

var limit = 50
var countOnly = false
var nullSeparated = false
var json = false
var openFirst = false
var revealFirst = false
var info = false
let appDefaults = UserDefaults(suiteName: "com.kongxiangrui.KongSeek")
var precision: MatchPrecision = appDefaults?.bool(forKey: "matchFolderPath") == true ? .withPath : .fuzzyName
var indexURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("KongSeek/name-index.ksidx")
var terms: [String] = []

var arguments = Array(CommandLine.arguments.dropFirst())
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
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

// Highest score first; ties: shorter name, then path (dupe: keeps its grouping).
var hits = index.search(query, precision: precision)
if !query.advanced.dupe {
    hits.sort { a, b in
        if a.score != b.score { return a.score > b.score }
        let la = index.name(of: a.id).count, lb = index.name(of: b.id).count
        return la != lb ? la < lb : index.path(of: a.id) < index.path(of: b.id)
    }
}

struct Row {
    let path: String
    let name: String
    let kind: String
    let score: Int
}

var rows: [Row] = []
let fileManager = FileManager.default
for hit in hits {
    if limit > 0 && rows.count >= limit && !countOnly { break }
    let path = index.path(of: hit.id)
    guard fileManager.fileExists(atPath: path) else { continue }
    if query.needsMetadata && !query.acceptsMetadata(EntryMetadata.read(path: path)) { continue }
    let flags = index.flags(of: hit.id)
    let kind = flags.contains(.package) ? (path.lowercased().hasSuffix(".app") ? "app" : "package")
        : (flags.contains(.directory) ? "folder" : (flags.contains(.symlink) ? "symlink" : "file"))
    rows.append(Row(path: path, name: index.name(of: hit.id), kind: kind, score: hit.score))
}

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
