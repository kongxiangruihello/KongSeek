import Foundation

/// The examples shown when "?" is typed (or the ? button clicked) in the search window.
/// Choosing one adds it to the query, with its sample value selected to type over.
enum SyntaxHelp {
    struct Entry {
        var example: String
        var explanation: String
        var section: String
        /// Replace the query instead of adding to it.
        var replace = false
        /// The sample value inside `example` to select.
        var select: String? = nil
    }

    static let entries: [Entry] = [
        Entry(example: "合同 2024", explanation: "每个词都要出现在名称里，顺序不限", section: "基本", replace: true),
        Entry(example: "hetong", explanation: "拼音全拼；首字母也行，如 ht、ly（论语）", section: "基本", replace: true),
        Entry(example: "\"年度 合同\"", explanation: "引号内按短语整体匹配", section: "基本", select: "年度 合同"),
        Entry(example: "-草稿", explanation: "排除名称含“草稿”的", section: "基本", select: "草稿"),
        Entry(example: "ext:pdf,docx", explanation: "只要这些扩展名；-ext:png 排除", section: "类型", select: "pdf,docx"),
        Entry(example: "pdf", explanation: "开头写类型：pdf、文档、图片、音频、视频、文件夹", section: "类型", replace: true),
        Entry(example: "file:", explanation: "只要文件；folder: 只要文件夹", section: "类型"),
        Entry(example: "in:~/Documents", explanation: "在某文件夹及其子文件夹中（写路径）", section: "位置", select: "~/Documents"),
        Entry(example: "in:讲义", explanation: "在名为“讲义”的文件夹中（写文件夹名）；-in: 排除", section: "位置", select: "讲义"),
        Entry(example: "parent:~/Desktop", explanation: "只要直接放在该文件夹里的（不含子文件夹）", section: "位置", select: "~/Desktop"),
        Entry(example: "path:论语", explanation: "完整路径中含有（文件夹名也算）；-path: 排除", section: "位置", select: "论语"),
        Entry(example: "dm:today", explanation: "今天修改的；也可 yesterday、thisweek、lastmonth、thisyear", section: "时间与大小", select: "today"),
        Entry(example: "dm:7d", explanation: "最近 7 天内修改的（也可 30d、2w、6m）", section: "时间与大小", select: "7d"),
        Entry(example: "dm:2024-10", explanation: "某年、某月或某天修改的；dm:>=2024-01-01、dm:2024-01..2024-03", section: "时间与大小", select: "2024-10"),
        Entry(example: "dc:7d", explanation: "最近 7 天内创建的；下载的文件即下载时间，如 dc:7d ext:pdf 找最近下载的 PDF", section: "时间与大小", select: "7d"),
        Entry(example: "最近一周", explanation: "也可：今天、昨天、近 3 天", section: "时间与大小"),
        Entry(example: "size:>10mb", explanation: "按大小；size:1mb..20mb、size:<500kb、size:empty", section: "时间与大小", select: ">10mb"),
        Entry(example: "标签:工作", explanation: "带某个访达标签（也可写 #工作）", section: "时间与大小", select: "工作"),
        Entry(example: "regex:^第.+讲", explanation: "名称匹配正则表达式（含 / 时匹配路径）", section: "高级", select: "^第.+讲"),
        Entry(example: "dupe:", explanation: "只列出同名文件，同名的排在一起", section: "高级"),
        Entry(example: "hd 仁", explanation: "网页搜索：hd 汉典、ct 中国哲学书、zw 知网、db 豆瓣、gs Google 学术（设置 › 网页搜索）", section: "其他", replace: true, select: "仁"),
        Entry(example: "cd 仁", explanation: "查系统词典（任何应用中选中字词按 ⌃⌥D 也可）", section: "其他", replace: true, select: "仁"),
    ]

    static var rows: [ResultItem] {
        entries.map { entry in
            ResultItem(path: "help:" + entry.example, name: entry.example, isFolder: false, score: 0,
                       fill: QueryFill(text: entry.example, replace: entry.replace, select: entry.select,
                                       explanation: entry.section + " · " + entry.explanation))
        }
    }
}
