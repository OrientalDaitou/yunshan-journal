import Foundation
import SwiftData

// 岁月长卷、卷中洞见、问道灵枢“长期趋势与洞察”的取数桥自检（统计本身在 Tools/CoreCheck 里测）。

extension SelfTest {
    /// RecordCollector：按日期窗口取的修行录与整表过滤逐条相同、history 是全部落笔、不取正文时只带元数据、
    /// 数据戳随保存而变、有记录的年份；再拿取出的数据把长卷、洞见、逐月趋势各算一遍
    static func recordChecks(_ check: (Bool, String) -> Void) throws {
        let c = try recordsContext()
        let today = LocalDay.today()
        check(RecordCollector.years(context: c, today: today).isEmpty, "取数桥：一条记录都没有时没有可选的年份")

        // 两年零星修行录：每 3 天一篇，带心境、标签、珍藏、时刻；另有一篇写在后天（补记 / 传书可写未来日期）
        for offset in stride(from: 730, through: 0, by: -3) {
            let kind: JournalKind = offset % 9 == 0 ? .review : offset % 2 == 0 ? .diary : .note
            let entry = JournalEntry(kind: kind, title: offset % 4 == 0 ? "第 \(offset) 天" : "", body: "取数自检 \(offset)\n  第二行",
                                     dateKey: today.adding(days: -offset).key)
            entry.mood = kind == .diary ? 1 + offset % 5 : nil
            entry.tags = offset % 5 == 0 ? ["自检", "第\(offset % 3)组"] : []
            entry.pinned = offset % 30 == 0
            entry.minute = offset % 7 == 0 ? 600 : nil
            entry.period = kind == .review ? "week" : ""
            c.insert(entry)
        }
        let future = JournalEntry(kind: .diary, body: "后天的补记", dateKey: today.adding(days: 2).key)
        c.insert(future)
        // 两项功课：一项每天、30 天前归档（有归档日）；一项指定星期
        let daily = Habit(title: "取数自检晨读")
        daily.startDate = today.adding(days: -400).key
        daily.archived = true
        daily.archivedAt = today.adding(days: -30).key
        let weekdays = Habit(title: "取数自检跑步")
        weekdays.frequencyKind = .weekdays
        weekdays.weekdays = [0, 2, 4]
        weekdays.startDate = today.adding(days: -200).key
        c.insert(daily)
        c.insert(weekdays)
        for (habit, days) in [(daily, (31...400).filter { $0 % 3 != 0 }), (weekdays, (0...200).filter { $0 % 2 == 0 })] {
            for offset in days {
                let log = HabitLog(dateKey: today.adding(days: -offset).key)
                c.insert(log)
                log.habit = habit
            }
        }
        var ledger = FinanceLedger()
        for (index, offset) in [0, 40, 380].enumerated() {
            ledger.transactions.append(ManualExpense.transaction(id: "manual-records-\(index)", day: today.adding(days: -offset), cents: 1200 + index * 100,
                                                                 category: "餐饮与外卖", description: "取数自检", note: "", reason: "自检"))
        }
        try FinanceService.save(ledger, context: c)
        DataStore.save(c)

        let all = c.all(JournalEntry.self)
        let from = today.adding(days: -100), to = today.adding(days: 5)
        let started = Date()
        let input = RecordCollector.input(context: c, from: from, to: to, today: today, text: true)
        let fetchMs = Int(Date().timeIntervalSince(started) * 1000)
        let expected = Dictionary(uniqueKeysWithValues: all.filter { $0.dateKey >= from.key && $0.dateKey <= today.key }.map { ($0.uid, $0) })
        let same = input.entries.count == expected.count && input.entries.allSatisfy { r in
            guard let e = expected[r.uid] else { return false }
            return r.day == e.day && r.kind == e.kindValue && r.minute == e.minute && r.mood == e.mood && r.tags == e.tags && r.pinned == e.pinned
                && r.period == e.period && r.title == e.title && r.body == e.body && r.chars == RecordStats.charCount(e.title) + RecordStats.charCount(e.body)
        }
        check(same && !input.entries.contains { $0.uid == future.uid },
              "取数桥：窗口内修行录 \(input.entries.count) 篇，与整表过滤逐条相同（后天的补记不计，用时 \(fetchMs) ms）")
        let meta = RecordCollector.input(context: c, from: from, to: to, today: today, text: false)
        let withText = Dictionary(uniqueKeysWithValues: input.entries.map { ($0.uid, $0) })
        check(meta.entries.count == input.entries.count
              && meta.entries.allSatisfy { m in
                  guard let t = withText[m.uid] else { return false }
                  return m.day == t.day && m.kind == t.kind && m.minute == t.minute && m.mood == t.mood && m.tags == t.tags && m.pinned == t.pinned && m.period == t.period
              }
              && meta.entries.allSatisfy { $0.title.isEmpty && $0.body.isEmpty && $0.chars == 0 && $0.excerpt.isEmpty },
              "取数桥：不取正文时只带日期、类型、时刻、心境、标签、珍藏、复盘周期")
        check(input.history.count == all.count && input.history.map(\.day.jdn).sorted() == all.map(\.day.jdn).sorted(),
              "取数桥：history 是全部 \(all.count) 篇落笔（只取日期与类型）")
        let logCounts = input.habits.map(\.logs.count).sorted()
        check(input.habits.count == 2 && logCounts == [daily.logValues.count, weekdays.logValues.count].sorted() && input.habits.contains { $0.archived }
              && input.ledger?.transactions.count == 3,
              "取数桥：全部习惯（含已归档）与打卡、账簿一并带上")
        let xp = CultivationEngine.compute(sources: CultivationEngine.sources(habits: input.habits.map(\.cultivationInput), today: today)
                                               + CultivationEngine.journalSources(input.history, today: today),
                                           config: input.cultivation, today: today).totalXP
        check(xp == CultivationService.state(context: c, today: today).totalXP, "取数桥：用取出的数据重算修为，与侧栏境界卡同一结果（\(xp)）")

        // 数据戳：没变时不变，插入并保存、改修为设置后都会变
        let stamp = RecordCollector.stamp(context: c)
        check(stamp == RecordCollector.stamp(context: c), "取数桥：数据没变时数据戳不变")
        c.insert(JournalEntry(kind: .note, body: "数据戳自检", dateKey: today.key))
        DataStore.save(c)
        let afterInsert = RecordCollector.stamp(context: c)
        DataStore.settings(in: c).dailyCap = 120
        DataStore.save(c)
        check(afterInsert != stamp && RecordCollector.stamp(context: c) != afterInsert, "取数桥：插入一篇并保存、改每日修为上限后数据戳都会变")

        // 有记录的年份：最早一条所在年 … 今年，篇数与按年过滤相同（晚于今天的不计）
        let years = RecordCollector.years(context: c, today: today)
        let all2 = c.all(JournalEntry.self)
        let expectedYears = (today.adding(days: -730).year...today.year).map { year in
            (year, all2.filter { $0.day.year == year && $0.day <= today }.count)
        }
        check(years.map(\.year) == expectedYears.map(\.0) && years.map(\.entries) == expectedYears.map(\.1),
              "取数桥：有记录的年份 " + years.map { "\($0.year)年 \($0.entries) 篇" }.joined(separator: "、"))

        // 拿真数据把长卷、洞见、逐月趋势各算一遍：篇数与按日期数的相同
        let engineStart = Date()
        guard let period = AnnalsPeriod.make(.year(today.year), today: today) else { return check(false, "取数桥：今年的时段为空") }
        let yearInput = RecordCollector.input(context: c, from: period.first, to: period.last, today: today, text: true)
        let report = AnnalsEngine.report(period, input: yearInput)
        let yearCount = all2.filter { $0.day >= period.first && $0.day <= today }.count
        let trendInput = RecordCollector.input(context: c, from: today.firstOfMonth.adding(days: -340).firstOfMonth, to: today, today: today, text: false)
        let trends = TrendDigest.months(trendInput, endingAt: today)
        let insights = InsightEngine.insights(trendInput, from: today.adding(days: -90), to: today.adding(days: -1))
        let engineMs = Int(Date().timeIntervalSince(engineStart) * 1000)
        check((report.writing?.entries ?? 0) == yearCount && report.finance?.manualOnly == true && trends.count == 12
              && trends.last?.ongoing == true && trends.reduce(0) { $0 + $1.entries } == all2.filter { $0.day >= trends[0].monthStart && $0.day <= today }.count,
              "取数桥：长卷今年 \(yearCount) 篇、逐月趋势 12 个月、洞见 \(insights.count) 条（取数加计算 \(engineMs) ms）")
        check(!AnnalsRenderer.markdown(report).contains("Optional("), "取数桥：长卷 Markdown 不含 Optional(")

        try mirrorChecks(c, daily: daily, weekdays: weekdays, check)
    }

    /// 全部落笔与打卡走增量镜像（只取新改过的几条）：增、删、改、撤销删除（带旧时间插回来）、没保存的插入、改数量目标之后，
    /// 取出的结果都要与整取逐条相同
    private static func mirrorChecks(_ c: ModelContext, daily: Habit, weekdays: Habit, _ check: (Bool, String) -> Void) throws {
        let today = LocalDay.today()
        let from = today.adding(days: -400)
        func meta(_ e: RecordEntry) -> String { "\(e.uid)|\(e.day.key)|\(e.kind.rawValue)|\(e.minute ?? -1)|\(e.mood ?? -1)|\(e.tags)|\(e.pinned)|\(e.period)" }
        func canonical(_ input: RecordInput) -> [String] {
            input.entries.map(meta).sorted() + input.history.map { "\($0.day.key)|\($0.kind.rawValue)" }.sorted()
                + input.habits.map { h in
                    "\(h.title)|\(h.symbol)|\(h.archived)|\(h.spec)|" + h.logs.map { "\($0.day.key),\($0.completed),\($0.quantity ?? -1),\($0.target ?? -1)" }.sorted().joined(separator: ";")
                }
        }
        func full() -> [String] {
            let habits = c.all(Habit.self).sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
                .map { RecordHabit(title: $0.title, symbol: $0.symbol, spec: $0.spec, logs: $0.logValues, archived: $0.archived) }
            let all = c.all(JournalEntry.self)
            let window = all.filter { $0.day >= from && $0.day <= today }
                .map { RecordEntry(uid: $0.uid, day: $0.day, minute: $0.minute, kind: $0.kindValue, mood: $0.mood, tags: $0.tags, pinned: $0.pinned, period: $0.period) }
            return canonical(RecordInput(today: today, entries: window, history: all.map { ($0.day, $0.kindValue) }, habits: habits,
                                         cultivation: CultivationConfig(), ledger: nil))
        }
        func same() -> Bool { canonical(RecordCollector.input(context: c, from: from, to: today, today: today, text: false)) == full() }
        var steps: [String] = []
        /// fullHabits：这一步该不该整取打卡（只有习惯本身变了才该）；落笔一律不该整取
        func step(_ name: String, fullHabits: Bool = false, _ change: () -> Void) {
            _ = same()
            let before = RecordCollector.mirrorFullLoads
            change()
            let ok = same()
            let after = RecordCollector.mirrorFullLoads
            if !ok || after.journal != before.journal || (after.habits != before.habits) != fullHabits { steps.append(name) }
        }
        step("新写一篇、新打一次卡并保存") {
            c.insert(JournalEntry(kind: .diary, body: "镜像自检", dateKey: today.adding(days: -1).key))
            let log = HabitLog(dateKey: today.adding(days: -1).key)
            c.insert(log)
            log.habit = weekdays
            DataStore.save(c)
        }
        step("改一篇的日期、类型、心境、标签，珍藏一篇，改一次打卡的数量") {
            if let entry = c.all(JournalEntry.self).first(where: { $0.body == "镜像自检" }) {
                entry.dateKey = today.adding(days: -3).key
                entry.kindValue = .review
                entry.mood = 2
                entry.tags = ["镜像"]
                entry.updatedAt = Date()
            }
            if let other = c.all(JournalEntry.self).first(where: { !$0.pinned && $0.dateKey == today.adding(days: -9).key }) {
                other.pinned = true
                other.updatedAt = Date()
            }
            if let log = weekdays.log(on: today.adding(days: -2)) {
                log.completed = false
                log.quantity = 3
                log.updatedAt = Date()
            }
            DataStore.save(c)
        }
        var removed: (dateKey: String, kind: String, created: Date, updated: Date)?
        step("删一篇、取消一次打卡") {
            if let entry = c.all(JournalEntry.self).first(where: { $0.dateKey == today.adding(days: -30).key }) {
                removed = (entry.dateKey, entry.kind, entry.createdAt, entry.updatedAt)
                c.delete(entry)
            }
            if let log = weekdays.log(on: today.adding(days: -4)) {
                weekdays.logs?.removeAll { $0 === log }
                c.delete(log)
            }
            DataStore.save(c)
        }
        step("撤销删除：带着原来的修改时间插回来") {
            if let removed {
                let back = JournalEntry(kind: JournalKind(rawValue: removed.kind) ?? .note, body: "撤销删除", dateKey: removed.dateKey)
                back.createdAt = removed.created
                back.updatedAt = removed.updated
                c.insert(back)
            }
            DataStore.save(c)
        }
        step("插入还没保存") {
            c.insert(JournalEntry(kind: .note, body: "还没保存", dateKey: today.key))
            let log = HabitLog(dateKey: today.adding(days: -6).key)
            c.insert(log)
            log.habit = weekdays
        }
        step("保存之后（换成正式标识）") { DataStore.save(c) }
        step("改数量目标：旧打卡补记当时的目标（不动修改时间）", fullHabits: true) {
            HabitQuantity.recordTargetsBeforeChange(weekdays, to: 5)
            weekdays.targetValue = 5
            weekdays.updatedAt = Date()
            DataStore.save(c)
        }
        step("删掉一个习惯（连同打卡）", fullHabits: true) {
            c.delete(daily)
            DataStore.save(c)
        }
        check(steps.isEmpty, "取数桥：增、删、改、珍藏、撤销删除、没保存的插入之后只取新改过的几条，改数量目标、删习惯才整取打卡，结果都与整取相同"
              + (steps.isEmpty ? "" : "（不对：\(steps.joined(separator: "、"))）"))
    }

    /// 干净的内存库（与 SelfTest.freshContext 相同，那个是 private 的）
    private static func recordsContext() throws -> ModelContext {
        let context = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        DataStore.save(context)
        return context
    }
}

private extension PlannerSummary.MonthTrend {
    /// “2026-10” → 那个月 1 日
    var monthStart: LocalDay { LocalDay(key: month + "-01") ?? .today() }
}
