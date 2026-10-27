# KongSeek

macOS 菜单栏文件搜索工具：随时唤出，按文件名、拼音全拼或首字母找到文件、文件夹和应用，并即时预览。
需要 macOS 13 或更高版本。KongSeek 是新写的应用，与 KongFetch 3.x、4.x 互不影响，可以同时安装。

## 安装

1. 双击 `构建并安装.command`：先运行测试，再编译、签名，把 KongSeek 装进“应用程序”并启动。
2. 首次启动会弹出搜索窗口，并在后台建立索引（菜单栏放大镜图标里可以看到进度）。
   macOS 会询问是否允许访问“文稿”“桌面”“下载”等文件夹，请选“允许”，否则这些文件夹里的文件搜不到。
3. 如果钥匙串里有名为 `KongSeek Local Signing` 或 `KongFetch Local Signing` 的代码签名证书，构建时会自动使用，
   之后每次更新都不必重新授权。

## 使用

| 操作 | 按键 |
| --- | --- |
| 打开 / 关闭搜索窗口 | ⌥空格（被占用时改用 ⌃⌥空格，菜单里会显示实际的快捷键） |
| 选择结果 | ↑ ↓ |
| 打开所选 | ↩，或双击 |
| 在访达中显示 | ⌘↩ |
| 直接打开第 N 项 | ⌘1 … ⌘9 |
| 拷贝文件 / 拷贝路径 | ⌘C / ⌥⌘C |
| 清空输入 / 关闭窗口 | ⎋ |

搜索语法（与 KongFetch 3.2 相同）：

- `合同 2024`：每个词都要出现在文件名里；拼音全拼、首字母也算，如 `hetong`、`ht`、`lunyu`。
- `"年度 合同"`：短语；`-草稿`：排除；`ext:pdf,docx`、`-ext:png`：按扩展名。
- 开头写类型词：`pdf`、`文档`、`图片`、`音频`、`视频`、`文件夹`。
- 自然语言筛选：`最近一周`、`今天`、`昨天`、`大于100MB`、`标签:工作`（也可写 `#工作`）。

菜单栏图标里可以：重建索引、增减索引的文件夹、包含隐藏文件、让关键词也匹配所在文件夹、设置登录时启动。

## 索引

- 默认索引主目录、iCloud 云盘、“应用程序”和系统应用；跳过 `~/Library`、`node_modules`、`.git`、`DerivedData`、废纸篓、
  隐藏文件和应用包内部。名为 `build`、`Library` 的普通文件夹照常收录。
- 索引存放在 `~/Library/Application Support/KongSeek/name-index.ksidx`。启动时直接载入，并从上次退出的位置补上期间的文件改动，
  不需要整盘重扫；运行时由 FSEvents 实时更新。
- 搜索引擎的速度、与 3.2 结果的一致性等测试数据见 `docs/引擎实测.md`。

## 结构

```
Sources/KongSeekCore         搜索引擎（无 AppKit，有单元测试）：名称索引、匹配与拼音、查询语法、索引文件、FSEvents
Sources/KongSeek             应用：菜单栏、全局快捷键、搜索窗口、预览
Sources/KongSeekLegacy32     KongFetch 3.2 的匹配与查询代码原样副本，只作测试和基准的对照
Sources/KongSeekTestSupport  测试与基准用的合成目录树
Sources/ksbench              性能基准：swift run -c release ksbench synth|new|legacy <目录>
Tests/                       XCTest
scripts/build-app.sh         命令行构建；--test 先跑测试，--install 安装
scripts/mac-test.sh          开发检查：编译全部目标、跑测试、可选基准，输出写入 .logs/
```

## 暂未包含

全文搜索、剪贴板历史、文本片段、批量重命名、压缩包内搜索等，之后逐步加入。
