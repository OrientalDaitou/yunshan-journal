import Foundation
import SwiftData

// #13 回看口径的运行时自检（r2-annals）：真库里取“最早一条修行录 / 打卡”定长卷默认时段（账目不算、日期写坏的跳过），
// 用户选过的时段照旧；卷首格的对比句写“与去年同期持平”、境界与小阶都没变的修为格才写“稳在”。
// 默认时段、对比句、洞见顺序与措辞本身在 Tools/CoreCheck 里测（// MARK: r2-annals）。

extension SelfTest {
    static func r2AnnalsChecks(_ check: (Bool, String) -> Void) throws {
        try r2AnnalsDefaultPeriodChecks(check)
        r2AnnalsTileChecks(check)
    }

    // MARK: 默认时段：真库取最早一条

    private static func r2AnnalsDefaultPeriodChecks(_ check: (Bool, String) -> Void) throws {
        let c = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: c)
        DataStore.save(c)
        let today = LocalDay.today()
        let blank = AnnalsView.firstRecordDay(context: c)
        check(blank == nil && AnnalsView.period(for: "", today: today, firstRecord: blank).storageKey
              == AnnalsPeriod.make(AnnalsPeriod.defaultScope(today: today), today: today)?.storageKey,
              "长卷默认时段：一条记录都没有时照旧（全年；1 月上半月看上一年）")

        // 新人：20 天前打过一次卡、10 天前写过一篇；另有一条日期写坏的打卡、一笔一年前的手记账（都不算）
        let habit = Habit(title: "r2 自检晨读")
        habit.startDate = today.adding(days: -30).key
        c.insert(habit)
        let log = HabitLog(dateKey: today.adding(days: -20).key)
        log.habit = habit
        c.insert(log)
        let broken = HabitLog(dateKey: "")
        broken.habit = habit
        c.insert(broken)
        c.insert(JournalEntry(kind: .diary, body: "r2 自检", dateKey: today.adding(days: -10).key))
        var ledger = FinanceLedger()
        ledger.transactions = [FinanceTransaction(id: "r2-old", date: today.adding(days: -365).key, amountCents: -1200, balanceCents: 0,
                                                  description: "r2 自检", account: "手记", category: "餐饮与外卖", kind: "消费",
                                                  needsReview: false, reason: "", sourceLine: 0)]
        try FinanceService.save(ledger, context: c)
        DataStore.save(c)
        let fresh = AnnalsView.firstRecordDay(context: c)
        let freshPeriod = AnnalsView.period(for: "", today: today, firstRecord: fresh)
        let expected = AnnalsPeriod.defaultScope(today: today, firstRecord: today.adding(days: -20))
        check(fresh == today.adding(days: -20) && freshPeriod.scope == expected && { if case .quarter = expected { true } else { false } }(),
              "长卷默认时段：最早一条是 20 天前的打卡（账目、写坏的日期不算）→ 默认看 \(freshPeriod.title)")
        check(AnnalsView.period(for: "\(today.year - 1)", today: today, firstRecord: fresh).storageKey == "\(today.year - 1)"
              && AnnalsView.period(for: "乱写", today: today, firstRecord: fresh).storageKey == freshPeriod.storageKey,
              "长卷默认时段：用户选过的时段照旧记住，写坏的键回到默认")

        // 补了一篇半年前的日记：记录满 90 天，默认回到全年
        c.insert(JournalEntry(kind: .note, body: "r2 自检·旧", dateKey: today.adding(days: -200).key))
        DataStore.save(c)
        let old = AnnalsView.firstRecordDay(context: c)
        check(old == today.adding(days: -200)
              && AnnalsView.period(for: "", today: today, firstRecord: old).scope == AnnalsPeriod.defaultScope(today: today),
              "长卷默认时段：补了 200 天前的一篇，记录满 90 天 → 默认回到全年")
    }

    // MARK: 卷首格：持平、稳在

    private static func r2AnnalsTileChecks(_ check: (Bool, String) -> Void) {
        let today = LocalDay.today()
        guard let period = AnnalsPeriod.make(.year(today.year), today: today) else { return check(false, "长卷卷首格：今年的时段为空") }
        // 今年与去年同期各 3 篇（都在 1 月 1 日起的头几天，今年一定已过；1 月 1 日当天只放今天）
        let offsets = today.month == 1 && today.day < 3 ? [0] : [0, 1, 2]
        let history = offsets.flatMap { offset -> [(day: LocalDay, kind: JournalKind)] in
            [(LocalDay(year: today.year - 1, month: 1, day: 1 + offset), .diary), (LocalDay(year: today.year, month: 1, day: 1 + offset), .diary)]
        }
        let entries = history.filter { $0.day >= period.first }.map { RecordEntry(uid: "r2t\($0.day.key)", day: $0.day, kind: $0.kind) }
        var config = CultivationConfig()
        config.enabled = true
        let input = RecordInput(today: today, entries: entries, history: history, habits: [], cultivation: config, ledger: nil)
        let report = AnnalsEngine.report(period, input: input)
        let tiles = AnnalsTileSpec.tiles(report)
        let writing = tiles.first { $0.label == "落笔" }
        check(writing?.compare == "与去年同期持平", "长卷卷首格：篇数与去年同期一样时写“\(writing?.compare ?? "nil")”，不写“+0%”")
        // 修为格与修为节同一判断：境界与小阶都没变才写“稳在”；本境升了小阶（今年 15 → 30，炼气 · 初期 → 中期）写“炼气 · 初期 → 中期”
        if let c = report.cultivation, c.breakthroughs.isEmpty, AnnalsLayout.showsCultivation(report) {
            let tile = tiles.first { $0.label == "修为" }
            let note = tile?.note ?? "nil"
            if c.isSteady {
                check(note == "稳在 \(c.endState.title)", "长卷卷首格：境界与小阶都没变的修为格写“\(note)”")
            } else {
                check(c.stagesAdvanced > 0 && note == "\(c.startState.title) → \(c.endState.stage)" && !note.contains("稳在"),
                      "长卷卷首格：本境升了小阶的修为格写“\(note)”，不写“稳在”")
            }
        }
    }
}
