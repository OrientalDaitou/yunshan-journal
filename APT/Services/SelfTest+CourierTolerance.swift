import Foundation
import SwiftData

// r2-courier（#9 飞剑传书容错）的运行时自检：同类说法对上（跑步 → 运动）、打卡对不上只退这一条（找不到习惯 / 单位对不上）、
// 单位换算（1 小时 → 60 分钟）；撤销只撤收下的；回执首行“已收录 N 条，另有 M 条没有收录（见下）”；整封全是对不上的打卡才进 failed/；
// --add 照投并提醒“第 N 条不会收录”、全都不能收时退出码 2；去重指纹带上单位；投递说明多了“也能对上的说法”与按条退回的说明。
// 解析、换算、预检的原文在 Tools/CoreCheck（// MARK: r2-courier）里测。

extension SelfTest {
    static func courierToleranceChecks(_ check: (Bool, String) -> Void) throws {
        let c = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: c)
        DataStore.profile(in: c)
        let sport = Habit(title: "运动")
        let steps = Habit(title: "步数")
        steps.targetValue = 8000
        steps.unit = "步"
        let zen = Habit(title: "冥想")
        zen.targetValue = 10
        zen.unit = "分钟"
        for (i, h) in [sport, steps, zen].enumerated() {
            h.sortOrder = i
            c.insert(h)
        }
        DataStore.save(c)
        let today = LocalDay.today(in: CourierService.timeZone)
        func payload(_ items: String) throws -> CourierPayload {
            try CourierParser.parse(Data(#"{"from":"自检","items":[\#(items)]}"#.utf8))
        }
        func tolerant(_ items: String) throws -> (delivery: CourierDelivery, notices: [String], skipped: [(index: Int, skip: CourierRoster.Skip)]) {
            try CourierService.applyCore(try payload(items), fileName: "tolerance.json", context: c, partial: true)
        }
        func ledgerCount() -> Int { (try? FinanceService.load(c).transactions.count) ?? -1 }

        // 1. 午饭 + 跑步：跑步按同类说法记到“运动”，两条都收
        let ledger0 = ledgerCount()
        let a = try tolerant(#"{"type":"expense","amount":18,"description":"容错自检午饭"},{"type":"checkin","habit":"跑步"}"#)
        check(a.delivery.itemCount == 2 && a.skipped.isEmpty && sport.log(on: today)?.completed == true && ledgerCount() == ledger0 + 1
              && a.notices.contains("第 2 条：按「运动」打卡（你写的是「跑步」，属于同类说法）")
              && a.delivery.summary.contains("打卡 · \(today.shortLabel) · 运动"),
              "传书“午饭 + 跑步”：跑步对上“运动”，两条都收并提醒（\(a.notices)）")

        // 2. 日记 + 步数 5 公里 + 冥想 1 小时：步数这条退回，冥想记 60 分钟，日记照收
        let b = try tolerant(#"{"type":"diary","body":"容错自检日记"},{"type":"checkin","habit":"步数","quantity":5,"unit":"公里"},"#
                             + #"{"type":"checkin","habit":"冥想","quantity":1,"unit":"小时"}"#)
        let lines = b.delivery.summary.split(separator: "\n").map(String.init)
        check(b.delivery.itemCount == 2 && b.skipped.map(\.index) == [1] && steps.log(on: today) == nil && zen.log(on: today)?.quantity == 60
              && c.all(JournalEntry.self).contains { $0.body == "容错自检日记" }
              && b.notices.contains("第 3 条：1 小时按 60 分钟记")
              && lines.last == "未收 · 打卡「步数」：单位对不上（写的是“公里”）" && lines.contains("打卡 · \(today.shortLabel) · 冥想（60分钟）"),
              "“步数 5 公里”退回、“冥想 1 小时”记 60 分钟、日记照收；摘要末尾一行“未收 ·”（\(lines)）")
        // 撤销只撤收下的：日记与冥想那条
        let undoB = CourierService.undo(b.delivery, context: c, refresh: false)
        check(undoB.removed == 2 && zen.log(on: today) == nil && !c.all(JournalEntry.self).contains { $0.body == "容错自检日记" } && steps.log(on: today) == nil,
              "撤销部分收录的传书：只撤收下的 2 条（removed \(undoB.removed)）")

        // 3. 找不到习惯：这一条退回，回执写明；直接调用 apply（老路子）仍整封拒收
        let c1 = try tolerant(#"{"type":"note","body":"容错自检灵感"},{"type":"checkin","habit":"弹琴"}"#)
        check(c1.delivery.itemCount == 1 && c1.skipped.first?.skip.short == "打卡「弹琴」：没有这项功课"
              && c1.skipped.first?.skip.receipt == "找不到习惯「弹琴」。现有习惯：运动、步数、冥想。请向用户确认是哪项功课，再只重投这一条。",
              "找不到习惯「弹琴」：只退这一条，灵感照收")
        do {
            _ = try CourierService.apply(try payload(#"{"type":"note","body":"容错自检整封"},{"type":"checkin","habit":"弹琴"}"#), fileName: "strict.json", context: c)
            check(false, "直接调用 apply 时找不到习惯应整封拒收")
        } catch {
            check(error.localizedDescription == "第 2 条：找不到习惯「弹琴」。现有习惯：运动、步数、冥想"
                  && !c.all(JournalEntry.self).contains { $0.body == "容错自检整封" }, "直接调用 apply：仍整封拒收、原文不变")
        }
        // 整封全是对不上的打卡：整封拒收，一条都不写
        let deliveries = c.all(CourierDelivery.self).count
        do {
            _ = try tolerant(#"{"type":"checkin","habit":"弹琴"},{"type":"checkin","habit":"步数","quantity":3,"unit":"公里"}"#)
            check(false, "整封全是对不上的打卡应整封拒收")
        } catch {
            check(error.localizedDescription.split(separator: "\n").count == 2 && c.all(CourierDelivery.self).count == deliveries,
                  "整封全是对不上的打卡：整封拒收，两条原因逐行列出")
        }

        // 4. 去重指纹：写了单位的把单位算进去（冥想 1 小时 ≠ 冥想 1 分钟）；没写单位的与原来的指纹相同
        let hourHash = CourierService.contentHash(try payload(#"{"type":"checkin","habit":"冥想","quantity":1,"unit":"小时"}"#))
        let minuteHash = CourierService.contentHash(try payload(#"{"type":"checkin","habit":"冥想","quantity":1,"unit":"分钟"}"#))
        let plain = try payload(#"{"type":"checkin","habit":"冥想","quantity":1},{"type":"note","body":"x"}"#)
        check(hourHash != minuteHash && CourierService.contentHash(plain) == FinanceEngine.sha256(plain.items.map(\.canonical).sorted().joined(separator: "\u{1E}")),
              "去重指纹：单位不同不算同一封；没写单位的指纹与原来一样")

        // 5. 投递说明：习惯表多一列“也能对上的说法”，打卡一节写明 unit 与按条退回
        let readme = CourierService.readme(context: c)
        check(readme.contains("| 习惯 | 频率 | 每次目标 | quantity 单位 | 也能对上的说法 |") && readme.contains("| 运动 | 每天 | 无数量目标（打卡即完成） | 可不写 | 锻炼、健身、跑步")
              && readme.contains("**打卡对不上只退这一条**") && readme.contains("| `unit` | 写了 quantity 时请写 |")
              && readme.contains("不必追问现金还是刷卡") && readme.contains("“未说明支付方式”"),
              "投递说明：同类说法一列、unit、按条退回、不追问支付方式")
        check(readme.contains("| 步数 | 每天 | 8000 步 | 步 | 走路、散步、步行、万步（需写数量） |") && readme.contains("“需写数量”"),
              "投递说明：只是相关的说法（散步之于步数）注明“需写数量”")

        // 6. 只是相关的同类说法没写数量：不替他记满 8000 步，这一条退回；写了数量照记
        let walk = try tolerant(#"{"type":"note","body":"容错自检散步"},{"type":"checkin","habit":"散步"}"#)
        check(walk.delivery.itemCount == 1 && walk.skipped.map(\.index) == [1] && steps.log(on: today) == nil
              && walk.skipped.first?.skip.receipt == "「散步」和「步数」相关但不是一回事：请写 quantity（单位“步”）后只重投这一条。"
              && walk.delivery.summary.contains("未收 · 打卡「散步」：要写数量才记到「步数」"),
              "“散步”没写数量：不替他记满 8000 步，这一条退回（\(walk.skipped.first?.skip.receipt ?? "nil")）")
        let walk2 = try tolerant(#"{"type":"checkin","habit":"散步","quantity":3000,"unit":"步"}"#)
        check(walk2.skipped.isEmpty && steps.log(on: today)?.quantity == 3000 && walk2.delivery.summary.contains("步数（3000步）"),
              "“散步 3000 步”记到「步数」3000 步")
        _ = CourierService.undo(walk2.delivery, context: c, refresh: false)

        // 7. quantity 自带单位又另写了不同的 unit：按 quantity 自带的单位记并提醒（“1小时”配 unit“分钟”是 60 分钟，不是 1 分钟）
        let hourPayload = try payload(#"{"type":"checkin","habit":"冥想","quantity":"1小时","unit":"分钟"}"#)
        let hour = try CourierService.applyCore(hourPayload, fileName: "tolerance-hour.json", context: c, partial: true)
        check(zen.log(on: today)?.quantity == 60 && hour.notices.contains("第 1 条：1 小时按 60 分钟记")
              && hourPayload.warnings.contains("第 1 条：quantity「1小时」里的单位“小时”和 unit“分钟”不同，已按“小时”记（下次请分开写：quantity 只写数，单位写在 unit）"),
              "“1小时”配 unit“分钟”：按 60 分钟记并提醒（\(hourPayload.warnings)）")
        _ = CourierService.undo(hour.delivery, context: c, refresh: false)

        // 8. 部分收录后原样重投被当作重复：补救建议说清哪条没收，不说“已为这一天打过卡”
        let again = try payload(#"{"type":"note","body":"容错自检灵感"},{"type":"checkin","habit":"弹琴"}"#)
        let advice = CourierService.duplicateAdvice(again, earlier: c1.delivery, context: c)
        check(advice.contains("上次那封第 2 条没有收录（未收 · 打卡「弹琴」：没有这项功课），其余已记好") && !advice.contains("已为这一天打过卡"),
              "部分收录后原样重投：建议里写明第 2 条没收，不说已打过卡（\(advice)）")
        check(c1.delivery.itemCount == 1 && CourierService.refs(of: c1.delivery).filter { $0.t == "skip" }.map(\.r) == ["2"],
              "退回的条号记进 refs（不算收录条数）")

        // 9. 功法谱「背单词」按“个”计：写“个单词”“单词”“words”都记得上
        let words = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: words)
        let vocab = Habit(title: "背单词")
        vocab.targetValue = 30
        vocab.unit = "个"
        words.insert(vocab)
        DataStore.save(words)
        let vocabLetter = try CourierService.applyCore(try payload(#"{"type":"checkin","habit":"背单词","quantity":50,"unit":"个单词"}"#),
                                                       fileName: "tolerance-words.json", context: words, partial: true)
        check(vocabLetter.skipped.isEmpty && vocab.log(on: today)?.quantity == 50, "「背单词」（个）写“50 个单词”记 50")

        guard DataStore.customDirectory != nil else { return }
        try courierToleranceInboxChecks(check, context: c, today: today)
    }

    /// 收件箱与 --add（只在临时数据目录里）：回执首行、退回的原因、整封进 failed/、--add 的提醒与退出码
    private static func courierToleranceInboxChecks(_ check: (Bool, String) -> Void, context c: ModelContext, today: LocalDay) throws {
        let fm = FileManager.default
        CourierService.prepareFolders()
        let stateURL = CourierService.stateURL
        let savedState = fm.contents(atPath: stateURL.path)
        defer {
            if let savedState { try? savedState.write(to: stateURL) } else { try? fm.removeItem(at: stateURL) }
        }
        func names(_ folder: URL) -> Set<String> { Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []) }
        /// 放进收件箱、让它“写入已过 5 秒”，收录一轮；返回这封在 processed/、failed/ 里的说明文字
        func deliver(_ json: String) -> (processed: String, failed: String) {
            let name = "tolerance-\(UUID().uuidString.prefix(8)).json"
            let url = CourierService.inbox.appendingPathComponent(name)
            try? Data(json.utf8).write(to: url)
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-5)], ofItemAtPath: url.path)
            CourierService.processInbox(context: c, effects: nil)
            func note(_ folder: URL, _ ext: String) -> String {
                let suffix = "-" + (name as NSString).deletingPathExtension + "." + ext
                return names(folder).first { $0.hasSuffix(suffix) }.flatMap { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) } ?? ""
            }
            return (note(CourierService.processed, "result.txt"), note(CourierService.failed, "error.txt"))
        }

        // 收件箱：午饭照收、“弹琴”退回；回执首行与末尾的原因
        let partial = deliver(#"{"from":"自检","items":[{"type":"expense","amount":21,"description":"容错自检晚饭"},{"type":"checkin","habit":"弹琴"}]}"#)
        let first = partial.processed.split(separator: "\n").first.map(String.init) ?? ""
        check(first == "已收录 1 条，另有 1 条没有收录（见下）" && partial.failed.isEmpty
              && partial.processed.contains("- 未收录 · 第 2 条：找不到习惯「弹琴」。现有习惯：运动、步数、冥想。请向用户确认是哪项功课，再只重投这一条。")
              && partial.processed.contains("不要整封重投") && !partial.processed.contains("\n未收 · "),
              "收件箱部分收录：回执首行“\(first)”，末尾写明未收录的原因")
        // 原样重投：当作重复跳过，回执说清第 2 条其实没收，不说“已为这一天打过卡”
        let resent = deliver(#"{"from":"自检","items":[{"type":"expense","amount":21,"description":"容错自检晚饭"},{"type":"checkin","habit":"弹琴"}]}"#)
        check(resent.processed.hasPrefix("重复投递，已跳过") && resent.processed.contains("上次那封第 2 条没有收录（未收 · 打卡「弹琴」：没有这项功课）")
              && !resent.processed.contains("已为这一天打过卡"),
              "部分收录后原样重投：回执写明第 2 条没收，不说已打过卡")
        let whole = deliver(#"{"from":"自检","items":[{"type":"checkin","habit":"弹琴"}]}"#)
        check(whole.processed.isEmpty && whole.failed == "第 1 条：找不到习惯「弹琴」。现有习惯：运动、步数、冥想",
              "收件箱整封都是对不上的打卡：进 failed/，原文不变（\(whole.failed)）")

        // --add：小抄带单位；对不上的打卡照投并提醒，全都不能收时退出码 2、不投
        var object: [String: Any] = ["habits": ["运动", "步数", "冥想"], "habitUnits": ["", "步", "分钟"], "habitTargets": [0, 8000, 10],
                                     "timeZone": CourierService.timeZone.identifier]
        try JSONSerialization.data(withJSONObject: object).write(to: stateURL)
        check(CourierService.cliRoster()?.habitUnits == ["", "步", "分钟"] && CourierService.cliRoster()?.habitTargets == [0, 8000, 10],
              "命令行小抄读到各习惯的单位与数量目标")
        /// 跑一次 --add，把它打印的说明收进一个临时文件再读出来
        func add(_ json: String) -> (code: Int32, output: String, file: String?) {
            let before = names(CourierService.inbox)
            let log = fm.temporaryDirectory.appendingPathComponent("apt-tolerance-\(UUID().uuidString).txt")
            fm.createFile(atPath: log.path, contents: nil)
            defer { try? fm.removeItem(at: log) }
            fflush(stdout)
            let saved = dup(STDOUT_FILENO)
            let out = open(log.path, O_WRONLY)
            if out >= 0 { dup2(out, STDOUT_FILENO); close(out) }
            let code = CourierService.commandLineAdd(json)
            fflush(stdout)
            if saved >= 0 { dup2(saved, STDOUT_FILENO); close(saved) }
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return (code, text, names(CourierService.inbox).subtracting(before).first)
        }
        let cli = add(#"{"from":"自检","items":[{"type":"note","body":"容错自检命令行"},{"type":"checkin","habit":"步数","quantity":5,"unit":"公里"}]}"#)
        check(cli.code == 0 && cli.file != nil && cli.output.contains("提醒：第 2 条不会收录：单位对不上：「步数」按“步”计"),
              "--add 部分不能收：照投、退出码 0，提醒“第 2 条不会收录”")
        let cliWalk = add(#"{"from":"自检","items":[{"type":"note","body":"容错自检命令行散步"},{"type":"checkin","habit":"散步"}]}"#)
        check(cliWalk.code == 0 && cliWalk.output.contains("提醒：第 2 条不会收录：「散步」和「步数」相关但不是一回事"),
              "--add “散步”没写数量：提醒第 2 条不会收录")
        if let file = cliWalk.file { try? fm.removeItem(at: CourierService.inbox.appendingPathComponent(file)) }
        let cliAll = add(#"{"type":"checkin","habit":"步数","quantity":5,"unit":"公里"}"#)
        check(cliAll.code == 2 && cliAll.file == nil && cliAll.output.contains("投递失败：第 1 条：单位对不上"),
              "--add 整封都是对不上的打卡：退出码 2、不投")
        // 投进去的那封照常按条收录，再清掉收件箱
        if cli.file != nil {
            for name in names(CourierService.inbox) where name.hasSuffix(".json") {
                try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-5)], ofItemAtPath: CourierService.inbox.appendingPathComponent(name).path)
            }
            check(CourierService.processInbox(context: c, effects: nil) == 1 && c.all(JournalEntry.self).contains { $0.body == "容错自检命令行" },
                  "--add 投进去的那封：日记收下，步数那条退回")
        }
        object["habitUnits"] = nil
        try JSONSerialization.data(withJSONObject: object).write(to: stateURL)
        check(CourierService.cliRoster()?.habitUnits == nil && add(#"{"type":"checkin","habit":"步数","quantity":5,"unit":"公里"}"#).code == 0,
              "旧版小抄没有单位：--add 不核对单位，照投（由应用收录时再查）")
        for name in names(CourierService.inbox) where name.hasSuffix(".json") {
            try? fm.removeItem(at: CourierService.inbox.appendingPathComponent(name))
        }
        check(!names(CourierService.inbox).contains { $0.hasSuffix(".json") }, "容错自检用完收件箱已清空")
    }
}
