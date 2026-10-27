import Foundation
import SwiftData

// 卷中洞见卡、问道灵枢“长期趋势与洞察”、快照共用的长期摘要（AIDigest）与问道灵枢“隐去姓名”的运行时自检。
// 统计本身（逐月趋势、洞见门槛、隐去姓名的替换规则）在 Tools/CoreCheck 里测。

extension SelfTest {
    /// AIDigest：一条记录都没有时摘要不出这两段；有一年多的记录时带上 12 个月逐月趋势与洞见；
    /// 数据没变时第二次只是查表，保存后重算；问道灵枢那条路（build → 长期摘要 → 隐去姓名）出来的 Markdown 与 JSON
    /// 都不含档案里的名字，不隐去时含；快照照常保留名字、也带上逐月趋势
    static func insightChecks(_ check: (Bool, String) -> Void) throws {
        let c = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: c)
        let profile = DataStore.profile(in: c)
        DataStore.save(c)
        let today = LocalDay.today()

        // 一条记录都没有：长期摘要为空，摘要里不多出 longTerm、不出两段标题
        let empty = AIDigest.digest(context: c, today: today)
        var bare = SummaryCollector.build(context: c, options: .init(), today: today)
        AIDigest.attach(&bare, context: c, today: today)
        check(empty.isEmpty && bare.longTerm == nil && !SummaryRenderer.json(bare).contains("longTerm")
              && !SummaryRenderer.markdown(bare, preamble: "").contains("逐月趋势"),
              "长期摘要：一条记录都没有时为空，摘要里不出“长期趋势与洞察”")

        // 一年多的记录：近 120 天每天一篇日记，心境晴雨相间；晴的日子功课打了、雨的日子没打；更早的每 5 天一篇
        let habit = Habit(title: "洞见自检晨读")
        habit.startDate = today.adding(days: -420).key
        // 早就建好的功课（建功课之前没补卡的日子不计入完成率，所以创建日也要往前放）
        habit.createdAt = today.adding(days: -420).date()
        c.insert(habit)
        for offset in 1...420 where offset <= 120 || offset % 5 == 0 {
            let bright = offset % 2 == 0
            let entry = JournalEntry(kind: .diary, title: "", body: offset == 1 ? "测试修士今天读完了一章。" : "洞见自检 \(offset)",
                                     dateKey: today.adding(days: -offset).key)
            entry.mood = bright ? 5 : 1
            c.insert(entry)
            if bright {
                let log = HabitLog(dateKey: today.adding(days: -offset).key)
                c.insert(log)
                log.habit = habit
            }
        }
        profile["name"] = "测试修士"
        profile["nickname"] = "Testo"
        DataStore.save(c)

        let before = AIDigest.computeCount
        let started = Date()
        let digest = AIDigest.digest(context: c, today: today)
        let firstMs = Date().timeIntervalSince(started) * 1000
        let hitStart = Date()
        let again = AIDigest.digest(context: c, today: today)
        let hitMs = Date().timeIntervalSince(hitStart) * 1000
        check(AIDigest.computeCount == before + 1 && again == digest && AIDigest.latest(today: today) == digest,
              String(format: "长期摘要：数据没变时第二次只是查表（首算 %.1f ms，查表 %.1f ms）", firstMs, hitMs))
        let kinds = Set(digest.insights.map(\.kind))
        check(digest.trends.count == LongTermDigest.months && digest.trends.last?.ongoing == true
              && kinds.contains(.moodHabits) && kinds.contains(.writingStreak) && digest.cardInsights.count <= LongTermDigest.cardLimit,
              "长期摘要：12 个月逐月趋势、近 90 天洞见 \(digest.insights.count) 条（含心境与功课、连续落笔），卡片最多 \(LongTermDigest.cardLimit) 条")

        // 借修为模型读好的习惯与打卡（主窗口的路）与镜像自己读的（自检、命令行的路）逐项相同，算出的长期摘要也相同。
        // 这里直接建一份不登记的模型；另造一个已归档、一个同一天两条打卡的习惯，看排法也一致
        let archived = Habit(title: "洞见自检旧功课")
        archived.startDate = today.adding(days: -300).key
        archived.archived = true
        archived.archivedAt = today.adding(days: -40).key
        archived.sortOrder = 1
        c.insert(archived)
        for (offset, completed) in [(60, true), (61, false), (61, true), (62, true)] {
            let log = HabitLog(dateKey: today.adding(days: -offset).key, completed: completed, quantity: completed ? nil : 1)
            c.insert(log)
            log.habit = archived
        }
        DataStore.save(c)
        let model = CultivationModel(context: c)
        func lines(_ habits: [RecordHabit]) -> [String] {
            habits.map { h in "\(h.title)|\(h.symbol)|\(h.archived)|\(h.spec)|" + h.logs.map { "\($0.day.key),\($0.completed),\($0.quantity ?? -1),\($0.target ?? -1)" }.joined(separator: ";") }
        }
        let viaMirror = AIDigest.input(context: c, today: today, habits: nil)
        let borrowed = model.recordHabits
        let viaModel = AIDigest.input(context: c, today: today, habits: borrowed)
        check(borrowed != nil && lines(viaModel.habits) == lines(viaMirror.habits) && viaModel.habits.count == 2
              && LongTermDigest.make(viaModel, today: today) == LongTermDigest.make(viaMirror, today: today),
              "长期摘要：借修为模型读好的习惯与打卡，与自己读的逐项相同（含已归档、同一天两条），算出的结果也相同")

        c.insert(JournalEntry(kind: .note, body: "洞见自检：新写一篇", dateKey: today.key))
        DataStore.save(c)
        _ = AIDigest.digest(context: c, today: today)
        check(AIDigest.computeCount == before + 2, "长期摘要：插入一篇并保存后不再命中缓存，重算一次")

        // 问道灵枢的路：SummaryCollector.build → AIDigest.prepare（长期摘要 + 隐去姓名），与 AIOptimizeView.regenerate 同一条
        let sections = AskPreset.week.sections
        var options = SummaryCollector.Options(sections: sections, hideIdentity: true, focusQuestion: "测试修士这周该先做什么？")
        options.journalDays = 7
        options.pastDays = 7
        let built = SummaryCollector.build(context: c, options: options, today: today)
        let preamble = "我是测试修士（Testo），请帮我复盘。"
        let hidden = AIDigest.prepare(built, preamble: preamble, sections: sections, hideIdentity: true, context: c, today: today)
        let hiddenMarkdown = SummaryRenderer.markdown(hidden.summary, preamble: hidden.preamble)
        let hiddenJSON = SummaryRenderer.json(hidden.summary)
        check(AskPreset.allCases.allSatisfy { $0.sections.contains(.trends) }
              && hiddenMarkdown.contains("## 近 12 个月逐月趋势") && hiddenMarkdown.contains("## 统计洞察") && hiddenJSON.contains("\"trends\""),
              "问道灵枢：六种问法都带“长期趋势与洞察”，Markdown 与 JSON 里都有逐月趋势与统计洞察")
        check(Set(AIDigest.identityNames(context: c)) == ["测试修士", "Testo"], "问道灵枢：档案里的姓名与昵称都认作要隐去的称呼")
        check(!hiddenMarkdown.contains("测试修士") && !hiddenJSON.contains("测试修士") && !hiddenMarkdown.contains("Testo")
              && hiddenMarkdown.contains(IdentityRedactor.placeholder) && hiddenJSON.contains(IdentityRedactor.placeholder)
              && hidden.summary.journal.count == built.journal.count && hidden.summary.journal.contains { $0.body.hasPrefix(IdentityRedactor.placeholder) }
              && hidden.summary.focusQuestion.hasPrefix(IdentityRedactor.placeholder),
              "问道灵枢：隐去姓名时，日记正文、焦点问题、提示语里的档案称呼在 Markdown 与 JSON 里都换成〔姓名〕（篇目一篇不少）")

        var shownOptions = options
        shownOptions.hideIdentity = false
        let plain = AIDigest.prepare(SummaryCollector.build(context: c, options: shownOptions, today: today), preamble: preamble,
                                     sections: sections, hideIdentity: false, context: c, today: today)
        let plainMarkdown = SummaryRenderer.markdown(plain.summary, preamble: plain.preamble)
        check(plainMarkdown.contains("测试修士今天") && SummaryRenderer.json(plain.summary).contains("测试修士") && plain.preamble == preamble,
              "问道灵枢：不隐去姓名时日记与提示语原样保留称呼")

        // 快照：保留称呼（只给用户自己的 apt-record 读），也带上逐月趋势
        CourierService.refreshSnapshot(context: c)
        let snapshot = (try? String(contentsOf: CourierService.snapshotURL, encoding: .utf8)) ?? ""
        check(snapshot.contains("测试修士") && snapshot.contains("逐月趋势") && snapshot.contains("统计洞察"),
              "快照：带上近 12 个月逐月趋势与统计洞察，称呼照常保留")

        // 卡片“新浮现”的判断：看过的不闪，文字变了、新出现的才闪
        let shown = digest.cardInsights
        let token = LongTermDigest.seenToken(shown)
        var changed = shown
        if !changed.isEmpty { changed[0].text += "（变）" }
        check(LongTermDigest.freshKinds(seen: token, shown: shown).isEmpty
              && LongTermDigest.freshKinds(seen: "", shown: shown) == Set(shown.map(\.kind))
              && (changed.isEmpty || LongTermDigest.freshKinds(seen: token, shown: changed) == [changed[0].kind]),
              "卷中洞见：看过的几条不再闪，新出现或文字变了的那条才闪")
    }
}
