import AppKit
import SwiftUI
import KongSeekCore

/// "功能导览" (0.23): every feature with where to find it and its keys, searchable
/// (also by pinyin initials, e.g. ywcz for 引文查证), with a button that opens it.
enum FeatureGuide {
    enum Action: Equatable {
        case openSearch, search(String), clipboard, quoteFinder, manuscriptCheck, compare, fileList,
             batchRename, duplicates, space, libraryCheck, scannedPDFs, status, settings
    }

    struct Entry: Identifiable {
        var id: String { category + title }
        var category: String
        var title: String
        var detail: String
        /// Where it is: keys, menu path.
        var how: String
        var action: Action?
        var keywords = ""
    }

    static let categories = ["搜索", "阅读与引文", "整理", "书库", "剪贴板与片段", "设置与诊断"]

    static let entries: [Entry] = [
        // 搜索
        Entry(category: "搜索", title: "打开搜索", detail: "按文件名搜索整台 Mac，拼音全拼、首字母、繁简、异体字都能找到。",
              how: "⌥空格，或连按两次 Control；菜单栏图标 › 打开搜索", action: .openSearch, keywords: "唤起 快捷键 拼音 首字母 繁体 异体"),
        Entry(category: "搜索", title: "全文搜索", detail: "搜 PDF、Word、Pages、文本、幻灯片的正文；识别过的扫描件也能搜到。预览区上方显示命中处和页码。",
              how: "搜索窗口中按 ⇥ 切换", action: .openSearch, keywords: "内容 正文 spotlight"),
        Entry(category: "搜索", title: "打开到命中页", detail: "PDF 在内置阅读窗口打开到命中的那一页并标黄，左侧有目录；PowerPoint 跳到那一张。",
              how: "全文结果上 ⌥↩", action: .openSearch, keywords: "页码 阅读 定位"),
        Entry(category: "搜索", title: "搜索语法", detail: "path:、in:、parent:、size:、dm:、dc:、ext:、regex:、file:、folder:、dupe:、标签:、最近一周、大于100MB 等。",
              how: "搜索窗口底部“?”按钮", action: .openSearch, keywords: "高级 筛选 日期 大小 扩展名 正则"),
        Entry(category: "搜索", title: "最近下载", detail: "列出 7 天内从浏览器、邮件、隔空投送下载的文件。",
              how: "菜单栏图标 › 最近下载；或搜索 dc:7d", action: .search("dc:7d file: "), keywords: "下载"),
        Entry(category: "搜索", title: "收藏搜索（课程视图）", detail: "把常用搜索存起来并命名，如“《论语》导读”；清空搜索框时按名字列出。",
              how: "搜索窗口中 ⌘S", action: .openSearch, keywords: "收藏 课程 保存"),
        Entry(category: "搜索", title: "按文件夹分组", detail: "结果按所在文件夹分组显示。", how: "搜索窗口中 ⌘G", action: .openSearch),
        Entry(category: "搜索", title: "更多操作", detail: "打开方式、终端、拷贝名称、标签、阅读状态、批量重命名、生成可搜索 PDF、与另一版本比较等。",
              how: "结果上 ⌘K，或右键单击", action: .openSearch, keywords: "右键 菜单"),
        Entry(category: "搜索", title: "网页搜索与查词", detail: "输入“hd 仁”搜汉典、“ct 学而”搜中国哲学书电子化计划、“cd 仁”查词典；任何应用中选中字词按 ⌃⌥D 查词。",
              how: "搜索框输入关键词 + 空格；⌃⌥D 查词", action: .openSearch, keywords: "汉典 词典 知网 豆瓣 谷歌学术 百科"),
        Entry(category: "搜索", title: "压缩包内搜索", detail: ".zip 里的文件名也能搜到，不必解压；↩ 取出并打开。",
              how: "直接搜索；设置 › 索引 中开关", action: .openSearch, keywords: "zip 解压"),

        // 阅读与引文
        Entry(category: "阅读与引文", title: "引文查证", detail: "粘贴一句引文，找出它在哪本书、哪一页，标出“完全一致”或“近似”，可拷贝出处。",
              how: "菜单栏图标 › 写作与引文 › 引文查证；任何应用中选中文字按 ⌃⌥Q 直接查证", action: .quoteFinder, keywords: "出处 引用 核对 页码"),
        Entry(category: "阅读与引文", title: "稿件引文核对", detail: "选一篇稿件（Word、文本、PDF），把其中引号内的引文逐条到书库查证，列成表，可导出 Excel。",
              how: "菜单栏图标 › 写作与引文 › 稿件引文核对", action: .manuscriptCheck, keywords: "论文 稿子 引号 批量 核对"),
        Entry(category: "阅读与引文", title: "拷贝引文", detail: "全文命中后拷贝命中的整句和出处（电子书带页码的 GB/T 7714 参考文献）。",
              how: "全文结果上 ⌘K › 拷贝引文", action: .openSearch, keywords: "引用 出处"),
        Entry(category: "阅读与引文", title: "拷贝为参考文献", detail: "按文件名和 EPUB 书目信息生成参考文献（GB/T 7714 或脚注格式，设置中选择）。",
              how: "电子书上 ⌘K › 拷贝为参考文献", action: .openSearch, keywords: "文献 著录 脚注 gbt7714"),
        Entry(category: "阅读与引文", title: "两版讲义对比", detail: "逐张（页、段）列出新增、删除、修改。",
              how: "菜单栏图标 › 写作与引文 › 两版讲义对比；或 ⌘K › 与另一版本比较", action: .compare, keywords: "版本 差异 比较 幻灯片"),
        Entry(category: "阅读与引文", title: "文件清单（书单与参考文献）", detail: "把一个文件夹或一次搜索的结果列成表：书名、作者、出版社、年份、阅读状态；可拷贝参考文献表、导出 Excel。",
              how: "菜单栏图标 › 写作与引文 › 文件清单；或 ⌘K › 把全部结果放入文件清单", action: .fileList, keywords: "书单 列表 表格 导出 excel"),
        Entry(category: "阅读与引文", title: "送到 KongReview", detail: "把摘录（原文、出处、页码）送到 KongReview。",
              how: "引文查证结果旁按钮；剪贴板中 ⌘R；搜索框输入“kr 内容”", action: .quoteFinder, keywords: "摘录 卡片"),
        Entry(category: "阅读与引文", title: "阅读状态", detail: "待读 / 在读 / 精读 / 已读（访达标签），搜索“标签:在读”列出。",
              how: "⌘K › 阅读状态", action: .search("标签:在读"), keywords: "已读 待读 标签"),

        // 整理
        Entry(category: "整理", title: "批量重命名", detail: "查找替换（可用正则）、按模板编号、电子书名称整理；先预览，可撤销。",
              how: "菜单栏图标 › 整理文件 › 批量重命名；或 ⌘K › 批量重命名", action: .batchRename, keywords: "改名 编号"),
        Entry(category: "整理", title: "查找重复与相似文件", detail: "完全相同的副本、同一文件的不同版本、同一本书的多个文件。",
              how: "菜单栏图标 › 整理文件 › 查找重复与相似文件", action: .duplicates, keywords: "重复 副本 版本"),
        Entry(category: "整理", title: "空间分析", detail: "最大的文件、多年未修改的大文件、占用最多的文件夹。",
              how: "菜单栏图标 › 整理文件 › 空间分析", action: .space, keywords: "磁盘 容量 大文件"),
        Entry(category: "整理", title: "整理新下载的电子书", detail: "把下载文件夹中网站长文件名的电子书改成短书名并移到电子书文件夹。",
              how: "有新下载时出现在菜单栏图标菜单中", keywords: "下载 电子书 改名"),
        Entry(category: "整理", title: "课程材料打包", detail: "把一门课的材料复制到一个文件夹或打成 zip。",
              how: "收藏的搜索上 ⌘K › 打包课程材料；或文件清单中“打包…”", action: .openSearch, keywords: "zip 课程 复制"),
        Entry(category: "整理", title: "移到废纸篓 / 放回", detail: "只移到废纸篓，不会直接删除；⌘Z 放回。", how: "结果上 ⌘⌫ / ⌘Z", action: .openSearch, keywords: "删除 撤销"),

        // 书库
        Entry(category: "书库", title: "书库体检", detail: "打不开或加密的 PDF、损坏的 EPUB、0 字节文件、没下载完的临时文件、同一本书的多个文件。",
              how: "菜单栏图标 › 书库 › 书库体检", action: .libraryCheck, keywords: "损坏 检查"),
        Entry(category: "书库", title: "查找扫描版 PDF", detail: "找出没有文字层的 PDF，按文件夹列出页数和预计识别时间，可一键加入文字识别。",
              how: "菜单栏图标 › 书库 › 查找扫描版 PDF", action: .scannedPDFs, keywords: "扫描 ocr 识别"),
        Entry(category: "书库", title: "文字识别（OCR）", detail: "在本机用 Apple Vision 识别扫描件和图片中的文字（不上传），之后全文搜索能搜到。",
              how: "设置 › 文字识别", action: .settings, keywords: "ocr 扫描 vision 实况文本"),
        Entry(category: "书库", title: "生成可搜索的 PDF", detail: "另存一份带隐形文字层的 PDF，在“预览”等应用中可搜索、选中、拷贝；原文件不动。",
              how: "PDF 上 ⌘K › 生成可搜索的 PDF", action: .openSearch, keywords: "ocr 文字层"),
        Entry(category: "书库", title: "竖排古籍识别试验", detail: "用两种引擎识别当前页并排对比，选效果更好的做后台识别。",
              how: "阅读窗口工具栏 › 识别试验", keywords: "竖排 古籍 实况文本"),

        // 剪贴板与片段
        Entry(category: "剪贴板与片段", title: "剪贴板历史", detail: "记录复制过的文字、图片和文件（默认关闭），↩ 粘贴回原应用。",
              how: "⌃⌥V；菜单栏图标 › 剪贴板历史", action: .clipboard, keywords: "复制 粘贴 历史"),
        Entry(category: "剪贴板与片段", title: "文本片段", detail: "设关键词（如 ;lk），在任何应用中输入关键词自动替换为片段内容。",
              how: "剪贴板窗口中按 ⇥；设置 › 片段", action: .settings, keywords: "缩写 替换 模板"),
        Entry(category: "剪贴板与片段", title: "识别图片中的文字", detail: "拷贝剪贴板图片中识别出的文字。", how: "剪贴板窗口中 ⌘T", action: .clipboard, keywords: "ocr 截图"),

        // 设置与诊断
        Entry(category: "设置与诊断", title: "检查更新", detail: "从 GitHub 获取新版本，在本机测试、编译后安装；可回退到上一版。",
              how: "设置 › 通用 › 检查更新", action: .settings, keywords: "升级 版本"),
        Entry(category: "设置与诊断", title: "状态与诊断", detail: "索引、唤起、权限、文字识别、更新、Claude 工具一览，需要处理的项附有按钮。",
              how: "菜单栏图标 › 状态与诊断", action: .status, keywords: "权限 问题 故障"),
        Entry(category: "设置与诊断", title: "让 Claude 搜索文件", detail: "Claude 桌面版可按文件名、全文搜索，读取正文，查重复，生成参考文献（只读）。",
              how: "设置 › 通用 › 添加到 Claude 桌面版", action: .settings, keywords: "mcp ai"),
        Entry(category: "设置与诊断", title: "命令行工具 ks", detail: "在“终端”中输入 ks 合同 ext:pdf 搜索。", how: "设置 › 通用 › 安装命令行工具", action: .settings, keywords: "终端 terminal"),
        Entry(category: "设置与诊断", title: "导出 / 导入设置", detail: "设置和文本片段存为 .kssettings 文件，换机或备份用。", how: "设置 › 通用", action: .settings, keywords: "备份 迁移"),
    ]

    /// Entries whose text contains every word of `query` (繁简、大小写不分), or whose
    /// title's pinyin (full or initials) starts with it.
    static func filter(_ query: String) -> [Entry] {
        let words = query.split(whereSeparator: \.isWhitespace).map { SearchText.fold(String($0)) }
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let text = SearchText.fold([entry.title, entry.detail, entry.how, entry.keywords, entry.category].joined(separator: " "))
            let pinyin = Pinyin.forms(entry.title).map { SearchText.fold($0.replacingOccurrences(of: " ", with: "")) }
            return words.allSatisfy { word in text.contains(word) || pinyin.contains { $0.hasPrefix(word) } }
        }
    }
}

final class FeatureGuideModel: ObservableObject {
    @Published var query = ""
    let run: (FeatureGuide.Action) -> Void

    init(run: @escaping (FeatureGuide.Action) -> Void) { self.run = run }

    struct Group: Identifiable {
        var category: String
        var entries: [FeatureGuide.Entry]
        var id: String { category }
    }

    var grouped: [Group] {
        let found = FeatureGuide.filter(query)
        return FeatureGuide.categories.compactMap { category -> Group? in
            let entries = found.filter { $0.category == category }
            return entries.isEmpty ? nil : Group(category: category, entries: entries)
        }
    }
}

struct FeatureGuideView: View {
    @ObservedObject var model: FeatureGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("搜索功能，如“引文”“重复”“ywcz”", text: $model.query)
                .textFieldStyle(.roundedBorder)
            let groups = model.grouped
            if groups.isEmpty {
                Text("没有找到。换个说法试试，如“页码”“改名”“扫描”。").foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(groups) { group in
                        Section(group.category) {
                            ForEach(group.entries) { entry in row(entry) }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 520)
    }

    private func title(for action: FeatureGuide.Action) -> String {
        action == .openSearch ? "打开搜索" : "打开"
    }

    private func row(_ entry: FeatureGuide.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.body.weight(.semibold))
                Text(entry.detail).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(entry.how).font(.caption).foregroundColor(.accentColor).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action = entry.action {
                Button(title(for: action)) { model.run(action) }.controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }
}

final class FeatureGuideWindowController: NSWindowController {
    let model: FeatureGuideModel

    init(run: @escaping (FeatureGuide.Action) -> Void) {
        model = FeatureGuideModel(run: run)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "KongSeek 功能导览"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: FeatureGuideView(model: model))
        window.setContentSize(NSSize(width: 720, height: 640))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
