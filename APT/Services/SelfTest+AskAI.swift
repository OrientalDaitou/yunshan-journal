import Foundation
import SwiftData

// #10 技能与教学（R2-C）的运行时自检：
// 1. apt-record 技能里那“一条命令”靠 --add 的输出认出投进收件箱的文件（`grep -o '/.*/cli-[^/]*\.json$'`），
//    再按“收录时间-原名.result.txt”找回执、读首行。这里照同一个式子从 --add 的真实输出里取路径（数据目录含空格与“②”时也取得到），
//    让应用收录一轮，确认回执名对得上、首行以“已收录”开头；
// 2. 修行录“飞剑传书”卡的“可以这样跟 AI 说”：六句例句、标题与脚注不走样。
// 技能里示例 JSON 能否被解析在 Tools/CoreCheck 里测。

extension SelfTest {
    static func askAIChecks(_ check: (Bool, String) -> Void) throws {
        try askAISkillCommandChecks(check)
        askAIHintChecks(check)
    }

    /// 技能里取路径用的式子（与 SKILL.md 的 grep 一致：从第一个“/”到行尾的 cli-….json）
    static let askAISkillPathPattern = #"/.*/cli-[^/]*\.json$"#

    private static func askAISkillCommandChecks(_ check: (Bool, String) -> Void) throws {
        let fm = FileManager.default
        let c = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: c)
        DataStore.save(c)
        CourierService.prepareFolders()
        // 小抄换成没有习惯、没有目标的一份：这封只有日记与记账，不该被预检拦下（用完恢复原样）
        let stateURL = CourierService.stateURL
        let savedState = fm.contents(atPath: stateURL.path)
        defer {
            if let savedState { try? savedState.write(to: stateURL) } else { try? fm.removeItem(at: stateURL) }
        }
        try JSONSerialization.data(withJSONObject: ["habits": [String](), "timeZone": CourierService.timeZone.identifier]).write(to: stateURL)

        // 与技能示例同样的写法：日期写 today，记账没说支付方式时 note 写“未说明支付方式”
        let json = #"{"from": "Claude", "items": [{"type": "expense", "date": "today", "amount": 18, "category": "餐饮与外卖", "description": "自检·午饭", "note": "未说明支付方式"}, {"type": "diary", "date": "today", "body": "自检·技能一条命令"}]}"#
        // 跑一次 --add，把它打印的内容收进临时文件（不混进自检输出）
        let log = DataStore.directory.appendingPathComponent("askai-add-\(UUID().uuidString.prefix(6)).txt")
        fm.createFile(atPath: log.path, contents: nil)
        defer { try? fm.removeItem(at: log) }
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        if let handle = try? FileHandle(forWritingTo: log) {
            dup2(handle.fileDescriptor, STDOUT_FILENO)
            let code = CourierService.commandLineAdd(json)
            fflush(stdout)
            if saved >= 0 { dup2(saved, STDOUT_FILENO); close(saved) }
            try? handle.close()
            check(code == 0, "技能命令：--add 投递日记 + 记账（today、未说明支付方式），退出码 0（\(code)）")
        } else {
            if saved >= 0 { close(saved) }
            check(false, "技能命令：建不了临时输出文件")
            return
        }
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let regex = try NSRegularExpression(pattern: askAISkillPathPattern, options: [.anchorsMatchLines])
        let path = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output))
            .flatMap { Range($0.range, in: output) }.map { String(output[$0]) } ?? ""
        let file = URL(fileURLWithPath: path)
        let name = file.deletingPathExtension().lastPathComponent
        let aiFolder = file.deletingLastPathComponent().deletingLastPathComponent()
        check(!path.isEmpty && fm.fileExists(atPath: path) && name.hasPrefix("cli-")
              && aiFolder.standardizedFileURL.path == CourierService.root.standardizedFileURL.path,
              "技能命令：按技能里的式子从 --add 输出取到收件箱里的文件，往上两级正是 AI 目录（\(name)；目录含空格 / 中文：\(aiFolder.path.contains(" ") || aiFolder.path.unicodeScalars.contains { $0.value > 127 })）")

        // 让文件“写入已过 5 秒”，收录一轮；回执名形如“收录时间-<原名>.result.txt”，技能用“-<原名>.”去找
        for entry in (try? fm.contentsOfDirectory(atPath: CourierService.inbox.path)) ?? [] where entry.hasSuffix(".json") {
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-5)], ofItemAtPath: CourierService.inbox.appendingPathComponent(entry).path)
        }
        let collected = CourierService.processInbox(context: c, effects: nil)
        let receipts = ((try? fm.contentsOfDirectory(atPath: CourierService.processed.path)) ?? []) + ((try? fm.contentsOfDirectory(atPath: CourierService.failed.path)) ?? [])
        let receipt = receipts.first { $0.contains("-\(name).") && ($0.hasSuffix(".result.txt") || $0.hasSuffix(".error.txt")) }
        let text = receipt.flatMap { r in
            [CourierService.processed, CourierService.failed].lazy.compactMap { try? String(contentsOf: $0.appendingPathComponent(r), encoding: .utf8) }.first
        } ?? ""
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        check(collected == 1 && receipt?.hasSuffix(".result.txt") == true && firstLine.hasPrefix("已收录 2 条")
              && c.all(JournalEntry.self).contains { $0.body == "自检·技能一条命令" && $0.dateKey == LocalDay.today(in: CourierService.timeZone).key },
              "技能命令：应用收录后按“-原名.”找到回执，首行以“已收录”开头（\(firstLine)），日记记在今天")
        // 收件箱留下的文件清掉，不影响后面的检查
        for entry in (try? fm.contentsOfDirectory(atPath: CourierService.inbox.path)) ?? [] where entry.contains(name) {
            try? fm.removeItem(at: CourierService.inbox.appendingPathComponent(entry))
        }
    }

    private static func askAIHintChecks(_ check: (Bool, String) -> Void) {
        let phrases = AskAIHint.phrases
        check(AskAIHint.title == "可以这样跟 AI 说" && phrases.count == 6 && Set(phrases).count == 6
              && phrases.contains("陪我复盘今天") && phrases.allSatisfy { !$0.isEmpty && $0.count <= 16 },
              "可以这样跟 AI 说：六句不重复、每句不超过 16 个字（窄栏里一行放得下）、含“陪我复盘今天”")
        check(AskAIHint.lead.contains("Claude Code") && AskAIHint.lead.contains("「yunshan-journal」")
              && AskAIHint.footnote.contains("撤销"),
              "可以这样跟 AI 说：写明在哪儿说（Claude Code 里打开「yunshan-journal」）、脚注说可整批撤销")
        // 卡里显示的文件夹名用不换行空格：窄栏里不会从中间折开；换回普通空格后与磁盘上的名字一字不差
        let shown = AskAIHint.folderUnbroken
        check(AskAIHint.folder == "yunshan-journal" && !shown.contains(" ")
              && shown.replacingOccurrences(of: "\u{00A0}", with: " ") == AskAIHint.folder,
              "可以这样跟 AI 说：文件夹名里若有空格会换成不换行空格（整名不折行），换回后仍是「yunshan-journal」")
    }
}
