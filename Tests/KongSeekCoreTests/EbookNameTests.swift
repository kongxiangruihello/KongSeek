import XCTest
@testable import KongSeekCore

/// Real names from the user's ebook folder.
final class EbookNameTests: XCTestCase {
    private func short(_ stem: String, _ style: EbookName.Style = .full) -> String? {
        EbookName.parse(stem)?.formatted(style)
    }

    func testAnnasArchive() {
        XCTAssertEqual(short("孔子与《论语》 Kong zi yu _ lun yu _ -- 成积春,宋立林主编; 成积春; 宋立林 -- Di 1 ban, 北京 Beijing, 2018 -- 北京_高等教育出版社 -- 9787040500288 -- 5ba8e6b83786f540ddc4ddbcd7cf8a88 -- Anna’s Archive"),
                       "孔子与《论语》（成积春、宋立林主编，高等教育出版社，2018）")
        XCTAssertEqual(short("儒家文献研究 -- 黄怀信, 李景明主编; 黄怀信; 李景明; 曲阜师范大学 -- Kongzi wen hua lun yuan, Di 1 ban, Jinan, China, 2004 -- 济南_齐鲁书社 -- 9787533314286 -- 89b4e63c6fcabe2b4dc91003462ac0b7 -- Anna’s Arch"),
                       "儒家文献研究（黄怀信、李景明主编，齐鲁书社，2004）")
        XCTAssertEqual(short("流金集 -- 程应鏐 -- 8b48754b5debd66466cff2b95a574938 -- Anna’s Archive"), "流金集（程应鏐）")
        XCTAssertEqual(short("全科医学概论 -- 68506ba449772c5953f4b1f33f3ccd8a -- Anna’s Archive"), "全科医学概论")
        XCTAssertEqual(short("盗火者 严复传 -- 马勇 -- 9b87ffb3c37e9d7b5684a6b06238bc24 -- Anna’s Archive"), "盗火者 严复传（马勇）")
        XCTAssertEqual(short("论语译注（带完整书签） -- 孔祥瑞译注 -- 2020 -- 上海社会科学院出版社 -- 9787552033106"),
                       "论语译注（带完整书签）（孔祥瑞译注，上海社会科学院出版社，2020）")
        // "isbn13 …" and a trailing " -- " (0.19).
        let pinyin = EbookName.parse("Zhongguo She Hui Si Xiang Shi Zi Liao Xuan Ji_ Xian Qin Juan -- 陆学艺, 王处辉主编 ; 王处辉, 周一骑, 胡翼鹏选编; 陆学艺; 王处辉; 周一骑; 胡翼鹏 -- Di 1 ban, Nanning Shi, China, 2005 -- isbn13 9787219048849 -- ")
        XCTAssertEqual(pinyin?.isbn, "9787219048849")
        XCTAssertEqual(pinyin?.authors, "陆学艺、王处辉主编")
        XCTAssertEqual(pinyin?.year, "2005")
        XCTAssertEqual(pinyin?.title, "Zhongguo She Hui Si Xiang Shi Zi Liao Xuan Ji_ Xian Qin Juan")
        let parsed = EbookName.parse("孔子与《论语》 Kong zi yu _ lun yu _ -- 成积春,宋立林主编 -- 9787040500288 -- 5ba8e6b83786f540ddc4ddbcd7cf8a88 -- Anna’s Archive")
        XCTAssertEqual(parsed?.isbn, "9787040500288")
    }

    func testZLibrary() {
        XCTAssertEqual(short("被遗忘的战争 --咸丰同治年间广东土客大械斗研究 by 刘平 (z-lib.org)"), "被遗忘的战争：咸丰同治年间广东土客大械斗研究（刘平）")
        XCTAssertEqual(short("華夏邊緣--歷史記憶與族群認同 by 王明珂 (z-lib.org)"), "華夏邊緣：歷史記憶與族群認同（王明珂）")
        XCTAssertEqual(short("道教炼丹术与中外文化交流--国家社科基金后期资助项目 by 韩吉绍著 (z-lib.org)"), "道教炼丹术与中外文化交流（韩吉绍著）", "series name dropped")
        XCTAssertEqual(short("古代五岳祭祀演变考论--国家社科基金后期资助项目 (中华书局) by 牛敬飞 (z-lib.org)"), "古代五岳祭祀演变考论（牛敬飞，中华书局）")
        XCTAssertEqual(short("红楼风俗谭（精）--邓云乡集 (中华书局出品) by 邓云乡著 (z-lib.org)"), "红楼风俗谭（精）：邓云乡集（邓云乡著，中华书局）")
        XCTAssertEqual(short("正统与华夷：中国传统政治文化研究--北京大学中国古代史研究中心丛刊 (刘浦江  ePUBw.COM) (Z-Library)"), "正统与华夷：中国传统政治文化研究（刘浦江）")
        XCTAssertEqual(short("靜靜的思想之河－－戰國時期國家思想研究 (池楨) (z-lib.org)"), "靜靜的思想之河：戰國時期國家思想研究（池楨）")
        XCTAssertEqual(short("风俗通义（精）--中华经典名著全本全注全译丛书 (中华书局) by 孙雪霞, 陈桐生译注 (z-lib.org)"), "风俗通义（精）（孙雪霞、陈桐生译注，中华书局）")
    }

    func testUserMarksAndOwnNames() {
        XCTAssertEqual(short("洪门·青帮·袍哥-----中国旧时民间黑社会习俗 by 王纯五_已读"), "洪门·青帮·袍哥：中国旧时民间黑社会习俗（王纯五）_已读")
        for own in ["李欧梵--上海摩登", "荀子--安小兰译注", "士大夫政治演生史稿 -- 阎步克", "习近平文化思想学习纲要(带目录) -- 中共中央宣传部 -- 2024",
                    "张竞生传 -- Yang, Qun, 杨群", "[思维导图---放射性思维].(英)托尼.扫描版", "论语稽"] {
            XCTAssertNil(EbookName.parse(own), own)
        }
    }

    func testStyles() {
        let name = EbookName(title: "流金集", authors: "程应鏐", publisher: "上海古籍出版社", year: "2008")
        XCTAssertEqual(name.formatted(.full), "流金集（程应鏐，上海古籍出版社，2008）")
        XCTAssertEqual(name.formatted(.titleAuthor), "流金集（程应鏐）")
        XCTAssertEqual(name.formatted(.titleOnly), "流金集")
        XCTAssertEqual(name.formatted(.authorTitle), "程应鏐《流金集》")
        XCTAssertEqual(EbookName(title: "A: B").formatted(.titleOnly), "A： B", "no colons in file names")
    }

    func testBatchRenamePlan() {
        var rule = BatchRename.Rule()
        rule.mode = .ebook
        let items = [
            BatchRename.Item(path: "/books/流金集 -- 程应鏐 -- 8b48754b5debd66466cff2b95a574938 -- Anna’s Archive.pdf"),
            BatchRename.Item(path: "/books/李欧梵--上海摩登.pdf"),
        ]
        let plan = BatchRename.plan(items, rule: rule) { _ in false }
        XCTAssertEqual(plan.map(\.newName), ["流金集（程应鏐）.pdf", "李欧梵--上海摩登.pdf"])
        XCTAssertEqual(plan.map(\.changed), [true, false])
        rule.ebookStyle = .titleOnly
        XCTAssertEqual(BatchRename.plan(items, rule: rule) { _ in false }.first?.newName, "流金集.pdf")
    }

    func testMarksBecomeTags() {
        XCTAssertEqual(EbookName.splitMark("洪门·青帮·袍哥 by 王纯五_已读").mark, "_已读")
        XCTAssertEqual(EbookName.splitMark("论语稽（精读）").stem, "论语稽")
        XCTAssertEqual(EbookName.tag(forMark: "_已读"), "已读")
        var rule = BatchRename.Rule()
        rule.mode = .ebook
        rule.marksToTags = true
        let items = [
            BatchRename.Item(path: "/books/洪门·青帮·袍哥-----中国旧时民间黑社会习俗 by 王纯五_已读.pdf"),
            BatchRename.Item(path: "/books/上海摩登_已读.pdf"),
            BatchRename.Item(path: "/books/论语稽.pdf"),
        ]
        let plan = BatchRename.plan(items, rule: rule) { _ in false }
        XCTAssertEqual(plan.map(\.newName), ["洪门·青帮·袍哥：中国旧时民间黑社会习俗（王纯五）.pdf", "上海摩登.pdf", "论语稽.pdf"])
        XCTAssertEqual(plan.map(\.tags), [["已读"], ["已读"], []])
        rule.marksToTags = false
        XCTAssertEqual(BatchRename.plan(items, rule: rule) { _ in false }.map(\.newName)[1], "上海摩登_已读.pdf")
    }

    func testMetadataTitleForPinyinName() {
        let path = "/books/Zhongguo She Hui Si Xiang Shi Zi Liao Xuan Ji_ Xian Qin Juan -- 陆学艺, 王处辉主编 ; 王处辉 -- Di 1 ban, Nanning Shi, China, 2005 -- isbn13 9787219048849 -- .pdf"
        var rule = BatchRename.Rule()
        rule.mode = .ebook
        rule.ebookStyle = .titleAuthor
        XCTAssertEqual(BatchRename.plan([BatchRename.Item(path: path)], rule: rule) { _ in false }.first?.newName,
                       "Zhongguo She Hui Si Xiang Shi Zi Liao Xuan Ji_ Xian Qin Juan（陆学艺、王处辉主编）.pdf")
        rule.ebookTitles = [path: "中国社会思想史资料选辑 先秦卷"]
        XCTAssertEqual(BatchRename.plan([BatchRename.Item(path: path)], rule: rule) { _ in false }.first?.newName,
                       "中国社会思想史资料选辑 先秦卷（陆学艺、王处辉主编）.pdf")
    }
}
