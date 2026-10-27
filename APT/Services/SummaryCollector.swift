import Foundation
import SwiftData

/// 从 SwiftData 收集数据，生成 AI 优化用的结构化摘要。
@MainActor
enum SummaryCollector {
    struct Options {
        var sections: Set<SummarySection> = Set(SummarySection.allCases)
        var hideIdentity = true
        var focusQuestion = ""
        /// 列出未来几天的安排（含今天）
        var upcomingDays = 7
        var journalDays = 30
        /// 每条修行录正文最多保留的字数（给 AI 的摘要不宜太长）
        var journalBodyLimit = 400
        /// 回看过去几天已经发生的日程、逐日打卡（周复盘用）；0 表示不带
        var pastDays = 7
        /// 修行录从新到旧排列（快照用：AI 先读到最近的内容）
        var journalNewestFirst = false
        /// 早于最近 journalFullDays 天的条目，正文只留这么多字；nil 表示同 journalBodyLimit
        var journalOlderBodyLimit: Int? = nil
        var journalFullDays = 14
        /// 修行录正文总字数上限；超出后更早的条目省略。0 表示不限
        var journalCharBudget = 0
    }

    static let identityKeys: Set<String> = ["name", "nickname", "preferred_name"]
    /// 日程时长按未来 4 周折算成每周平均：双周一次的日程也能算准，和列出的安排天数无关
    static let hoursWindowDays = 28
    /// “本月至今”里逐笔列出的手记上限
    static let manualListLimit = 30

    static func build(context: ModelContext, options: Options, today: LocalDay = .today()) -> PlannerSummary {
        var profile: [String: String] = [:]
        if options.sections.contains(.profile), let p = context.all(Profile.self).sorted(by: { $0.createdAt < $1.createdAt }).first {
            for field in ProfileCatalog.allFields {
                let value = p[field.key].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !(options.hideIdentity && identityKeys.contains(field.key)) else { continue }
                profile[field.key] = value
            }
        }

        let goals: [PlannerSummary.Goal] = options.sections.contains(.goals)
            ? context.all(Goal.self).filter { $0.status != "cancelled" }.sorted { $0.createdAt < $1.createdAt }.map {
                .init(title: $0.title, category: $0.category, status: $0.statusLabel, progress: $0.progress, targetDate: $0.targetDate)
            } : []

        var recurring: [PlannerSummary.RecurringEvent] = []
        var upcoming: [PlannerSummary.Occurrence] = []
        var past: [PlannerSummary.Occurrence] = []
        var hours: [PlannerSummary.TimeBudget] = []
        var buffer = (before: 0, after: 0)
        let pastDays = max(0, options.pastDays)
        if options.sections.contains(.schedule) {
            // 作息页的“日程前后缓冲”：供 AI 安排建议参考
            if let settings = context.all(AppSettings.self).first {
                buffer = (max(0, settings.bufferBeforeMinutes), max(0, settings.bufferAfterMinutes))
            }
            // 一次构建只取一次日程、只展开一次：重复的日程全要（列规则），单次日程只要可能落在回看到往后 4 周里的
            let first = today.adding(days: -pastDays)
            let last = today.adding(days: max(1, options.upcomingDays) - 1)
            let hoursLast = today.adding(days: hoursWindowDays - 1)
            let events = Occurrences.events(in: context, from: first, to: max(last, hoursLast))
            for event in events where event.recurrenceKind != .none {
                let rule = event.rule
                let ended = (rule.repeatUntil.map { $0 < today } ?? false) || (rule.stopBefore.map { $0 <= today } ?? false)
                guard !ended else { continue }
                // 还没开始的规则写明起始日，免得 AI 以为它已经在占用时间
                let since = event.startDay > today ? "（自 \(event.startDay.shortLabel) 起）" : ""
                recurring.append(.init(title: event.title, category: event.category,
                                       time: ClockTime.range(event.startMinute, event.endMinute), rule: rule.summary + since, location: event.location))
            }
            // 回看与往后合成一次展开，再按日期分开（展开只看“显示日期”落在哪个窗口，分开展开与合并展开的结果相同）
            let items = Occurrences.list(events: events, from: first, to: max(last, hoursLast))
            upcoming = items.filter { $0.day >= today && $0.day <= last }.map(occurrence)
            hours = ScheduleHours.weeklyAverage(items.filter { $0.day >= today && $0.day <= hoursLast }.map { ($0.category, $0.startMinute, $0.endMinute) },
                                                days: hoursWindowDays)
            if pastDays > 0 {
                past = items.filter { $0.day < today }.map(occurrence)
            }
            recurring.sort { $0.title < $1.title }
        }

        var routine: [PlannerSummary.RoutineBlock] = []
        var routineHours: [String: Double] = [:]
        if options.sections.contains(.routine) {
            let blocks = context.all(RoutineBlock.self)
            var groups: [String: (block: RoutineBlock, days: [Int])] = [:]
            for block in blocks {
                let key = "\(block.title)|\(block.kind)|\(block.startMinute)|\(block.endMinute)"
                groups[key, default: (block, [])].days.append(block.weekday)
                routineHours[RoutineKind.of(block.kind).label, default: 0] += Double(block.durationMinutes) / 60
            }
            routine = groups.values.sorted { ($0.block.startMinute, $0.block.title) < ($1.block.startMinute, $1.block.title) }.map {
                .init(weekdays: WeekdayText.summary($0.days), time: ClockTime.range($0.block.startMinute, $0.block.endMinute),
                      title: $0.block.title, kind: RoutineKind.of($0.block.kind).label)
            }
        }

        var habits: [PlannerSummary.Habit] = []
        var habitDays: [String] = []
        if options.sections.contains(.habits) {
            let recentDays = pastDays > 0 ? LocalDay.range(today.adding(days: -(pastDays - 1)), today) : []
            habitDays = recentDays.map { String($0.key.dropFirst(5)) + " " + LocalDay.weekdayShortNames[$0.weekdayIndex] }
            // 未归档的习惯与统计：界面已经建了修为模型（且算的是同一天）时借它算好的，不再把习惯重新取一遍
            // （重新取会让全部打卡关系变冷，读统计要把两万条打卡逐条补回来，见 CultivationModel）
            let model = CultivationModel.existing(for: context)
            model?.refresh()
            let rows: [(habit: Habit, stats: HabitStats)] = model.flatMap { $0.today == today ? $0.rows.map { ($0.habit, $0.stats) } : nil }
                ?? context.allHabits().filter { !$0.archived }.sorted { $0.sortOrder < $1.sortOrder }.map { ($0, $0.stats(today: today)) }
            for (habit, stats) in rows {
                let streak = stats.streak
                habits.append(.init(title: habit.title, schedule: habit.spec.scheduleSummary + targetText(habit),
                                    completion7d: stats.completionRate(days: 7).map { Int(($0 * 100).rounded()) },
                                    completion30d: stats.completionRate(days: 30).map { Int(($0 * 100).rounded()) },
                                    streak: "\(streak.count) \(streak.unit)",
                                    weeklyTrend: stats.weeklyTrend(weeks: 8).map { $0.rate.map { Int(($0 * 100).rounded()) } },
                                    archived: habit.archived,
                                    recent: recentDays.map { symbol(stats.state(on: $0), day: $0, today: today, spec: stats.spec) }))
            }
        }

        var cultivation: PlannerSummary.Cultivation?
        if options.sections.contains(.cultivation) {
            let state = CultivationService.state(context: context, today: today)
            cultivation = .init(realm: state.title, totalXP: state.totalXP, toNextRealm: state.xpToNext, nextRealm: state.nextRealmName)
        }

        var finance: PlannerSummary.Finance?
        var financeToDate: PlannerSummary.FinanceToDate?
        if options.sections.contains(.finance), let ledger = try? FinanceService.load(context), !ledger.transactions.isEmpty {
            let month = FinanceEngine.defaultMonth(ledger, today: today)
            let report = FinanceEngine.reportDraft(ledger, month: month)
            let f = report.summary
            finance = .init(
                month: MonthKey.label(month), fullMonth: f.fullMonth, spend: FinanceEngine.money(f.spendCents), refund: FinanceEngine.money(f.refundCents),
                netSpend: FinanceEngine.money(f.netSpendCents), otherDebits: FinanceEngine.money(f.excludedCents),
                topCategories: f.categories.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \(FinanceEngine.money($0.value))" },
                changeVsPreviousMonth: report.comparison.map { "消费 \(FinanceEngine.money($0.spendChangeCents, sign: true))，扣除教育后 \(FinanceEngine.money($0.nonEducationChangeCents, sign: true))" },
                budgets: report.budgets.compactMap { b in b.limitCents.map { "\(b.label) 已用 \(FinanceEngine.money(b.spentCents)) / 预算 \(FinanceEngine.money($0))" } },
                pendingReview: f.needsReviewCount)
            let current = String(today.key.prefix(7))
            if month != current { financeToDate = monthToDate(ledger, month: current, today: today) }
        }

        var journal: [PlannerSummary.JournalItem] = []
        var omitted = 0
        if options.sections.contains(.journal) {
            let since = today.adding(days: -(options.journalDays - 1)).key
            let fullSince = today.adding(days: -(options.journalFullDays - 1)).key
            // 只取这几天的（#Predicate 交给数据库筛），不必把全部修行录取出来再过滤
            let todayKey = today.key
            let recent = (try? context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.dateKey >= since && $0.dateKey <= todayKey })))
                ?? context.all(JournalEntry.self)
            var entries = recent.filter { $0.dateKey >= since && $0.dateKey <= todayKey }
                .sorted { ($0.dateKey, $0.minute ?? -1, $0.createdAt) < ($1.dateKey, $1.minute ?? -1, $1.createdAt) }
            if options.journalNewestFirst { entries.reverse() }
            var used = 0
            for (index, e) in entries.enumerated() {
                let limit = e.dateKey < fullSince ? (options.journalOlderBodyLimit ?? options.journalBodyLimit) : options.journalBodyLimit
                let body = e.body.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = body.count > limit ? String(body.prefix(limit)) + "……" : body
                // 总量有上限时，从排在后面的（快照里是最早的）开始省略
                if options.journalCharBudget > 0, !journal.isEmpty, used + text.count + e.title.count > options.journalCharBudget {
                    omitted = entries.count - index
                    break
                }
                used += text.count + e.title.count
                journal.append(.init(date: e.dateKey, weekday: e.day.weekdayName, time: e.minute.map { ClockTime.text($0) }, kind: e.kindValue.label,
                                     title: e.title, body: text, mood: e.mood.map { Mood.label($0) }, period: ReviewPeriod.label(for: e.period),
                                     tags: e.tags, source: e.isFromCourier ? e.sourceNote : nil))
            }
        }

        return PlannerSummary(
            generatedAt: DateText.stamp(Date()), periodDays: options.journalDays, today: today.key, profile: profile, goals: goals,
            recurringEvents: recurring, upcoming: upcoming,
            scheduleHoursByCategory: hours,
            routine: routine,
            routineHoursByKind: routineHours.map { .init(category: $0.key, hoursPerWeek: $0.value) }.sorted { $0.hoursPerWeek > $1.hoursPerWeek },
            habits: habits, cultivation: cultivation, finance: finance, journal: journal, journalDays: options.journalDays,
            focusQuestion: options.focusQuestion.trimmingCharacters(in: .whitespacesAndNewlines),
            upcomingDays: max(1, options.upcomingDays), hoursWindowDays: hoursWindowDays,
            pastDays: options.sections.contains(.schedule) || options.sections.contains(.habits) ? pastDays : 0, past: past,
            habitDays: habits.isEmpty ? [] : habitDays, financeToDate: financeToDate,
            journalNewestFirst: options.journalNewestFirst, journalOmitted: omitted,
            bufferBeforeMinutes: buffer.before, bufferAfterMinutes: buffer.after)
    }

    private static func occurrence(_ item: OccurrenceItem) -> PlannerSummary.Occurrence {
        .init(date: item.day.key, weekday: item.day.weekdayName, time: ClockTime.range(item.startMinute, item.endMinute),
              title: item.title, category: item.category)
    }

    /// 逐日打卡的符号（只用相等比较，HabitDayState 以后加了新状态也不会编不过）。
    /// 今天“还没打”（○）只给今天应打的习惯；只在部分星期打卡、今天不用打的写 –。每周 N 次的习惯哪天打都行，今天照样是 ○。
    private static func symbol(_ state: HabitDayState, day: LocalDay, today: LocalDay, spec: HabitSpec) -> String {
        if state == .done { return "✓" }
        if state == .partial { return "◐" }
        if state == .missed { return "✗" }
        if state == .rest, day == today, spec.frequency == .weekly || spec.isScheduled(day) { return "○" }
        return "–"
    }

    /// 本月至今：银行流水的覆盖范围 + 合计 + 手记逐笔（只列手记，不把银行明细里的商户、转账对象写进去）
    private static func monthToDate(_ ledger: FinanceLedger, month: String, today: LocalDay) -> PlannerSummary.FinanceToDate {
        let facts = FinanceEngine.monthFacts(ledger, month: month)
        // 与 monthFacts 一致：设为“不计入统计”的不算
        let manual = ledger.transactions
            .filter { $0.account == ManualExpense.account && $0.month == month && $0.amountCents < 0 && !$0.isIgnored }
            .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
        let lines = manual.prefix(manualListLimit).map { row in
            "\(row.date.dropFirst(5)) \(row.description) \(FinanceEngine.money(-row.amountCents))［\(row.category)］"
                + (row.id.hasPrefix("courier-") ? "（传书）" : "") + (row.note.isEmpty ? "" : " 备注：\(row.note)")
        }
        return .init(month: MonthKey.label(month), through: today.key,
                     spend: FinanceEngine.money(facts.spendCents), refund: FinanceEngine.money(facts.refundCents),
                     netSpend: FinanceEngine.money(facts.netSpendCents),
                     topCategories: facts.categories.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \(FinanceEngine.money($0.value))" },
                     bankThrough: bankThrough(ledger, month: month),
                     manualCount: manual.count, manualTotal: FinanceEngine.money(manual.reduce(0) { $0 - $1.amountCents }),
                     manual: Array(lines), pendingReview: facts.needsReviewCount)
    }

    /// 银行流水覆盖到哪天：取各账户最后导入日中**最早**的那个（只要有一个账户没导到今天，合计就不完整）。
    /// 只看近期还在用的账户（最后导入日不早于上月 1 日），免得早已停用的旧账户让快照永远显示“不完整”；都不在用时取最晚的那天。
    private static func bankThrough(_ ledger: FinanceLedger, month: String) -> String? {
        var latestByAccount: [String: String] = [:]
        for source in ledger.sources {
            guard let end = source.range?.1 else { continue }
            latestByAccount[source.account] = max(latestByAccount[source.account] ?? end, end)
        }
        let recentFrom = (FinanceEngine.previousMonth(month) ?? month) + "-01"
        let active = latestByAccount.values.filter { $0 >= recentFrom }
        return active.min() ?? latestByAccount.values.max()
    }

    private static func targetText(_ habit: Habit) -> String {
        guard let target = habit.targetValue, target > 0 else { return "" }
        let number = target.rounded() == target ? String(Int(target)) : String(target)
        return "，每次 \(number)\(habit.unit)"
    }
}

/// 日程展开（多个视图共用）。
struct OccurrenceItem: Identifiable, Hashable {
    var event: ScheduleEvent
    var sourceDay: LocalDay
    var day: LocalDay
    var title: String
    var startMinute: Int?
    var endMinute: Int?
    var location: String
    var category: String
    var isOverride: Bool
    var id: String { "\(event.persistentModelID.hashValue)-\(sourceDay.key)" }

    /// 显示用到的字段都要比较：只比 id 和日期的话，改了标题 / 时间 / 地点 / 类别后，SwiftUI 会以为没变而不重绘色块
    static func == (lhs: OccurrenceItem, rhs: OccurrenceItem) -> Bool {
        lhs.id == rhs.id && lhs.day == rhs.day && lhs.sourceDay == rhs.sourceDay && lhs.title == rhs.title
            && lhs.startMinute == rhs.startMinute && lhs.endMinute == rhs.endMinute && lhs.location == rhs.location
            && lhs.category == rhs.category && lhs.isOverride == rhs.isOverride
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum Occurrences {
    /// 可能在 [first, last] 里出现的日程（宁多勿少）：重复的（含认不出的重复类型，按不重复展开也不会漏）、
    /// 有单次改期的（单次改期能把一次挪到很远的日子，所以不管原日期在哪都要）、原日期落在窗口里的单次日程。
    /// 日程的日期都是规范的 `YYYY-MM-DD`（编辑器、传书、旧版导入都先规范化），按字符串比较即按日期比较。
    /// 用它取出来的日程展开 [first, last]，与全部日程展开的结果相同（自检里对照）。
    static func candidates(from first: LocalDay, to last: LocalDay) -> Predicate<ScheduleEvent> {
        let none = RecurrenceKind.none.rawValue
        let lower = first.key
        let upper = last.key
        return #Predicate<ScheduleEvent> { $0.recurrence != none || $0.overridesJSON != "" || ($0.dateKey >= lower && $0.dateKey <= upper) }
    }

    /// 只取可能落在 [first, last] 里的日程（见 candidates）；取数失败时退回全部日程
    static func events(in context: ModelContext, from first: LocalDay, to last: LocalDay) -> [ScheduleEvent] {
        (try? context.fetch(FetchDescriptor(predicate: candidates(from: first, to: last)))) ?? context.all(ScheduleEvent.self)
    }

    static func list(events: [ScheduleEvent], from first: LocalDay, to last: LocalDay) -> [OccurrenceItem] {
        var items: [OccurrenceItem] = []
        for event in events {
            let rule = event.rule
            for occurrence in rule.occurrences(from: first, to: last) {
                let patch = rule.overrides[occurrence.sourceDay.key]
                items.append(OccurrenceItem(
                    event: event, sourceDay: occurrence.sourceDay, day: occurrence.scheduledDay,
                    title: patch?.title ?? event.title,
                    startMinute: patch?.start_time.flatMap { ClockTime.minutes(from: $0) } ?? event.startMinute,
                    endMinute: patch?.end_time.flatMap { ClockTime.minutes(from: $0, allowEndOfDay: true) } ?? event.endMinute,
                    location: patch?.location ?? event.location, category: event.category, isOverride: occurrence.isOverride))
            }
        }
        return items.sorted { ($0.day, $0.startMinute ?? -1, $0.title) < ($1.day, $1.startMinute ?? -1, $1.title) }
    }
}

@MainActor
enum CultivationService {
    /// 当前的修为。界面已经建了修为模型（CultivationModel）时直接用它（数据变了才增量重算，结果与全量相同）；
    /// 没有模型、或要的不是模型那一天时全量算一次。
    static func state(context: ModelContext, today: LocalDay = .today()) -> CultivationState {
        if let model = CultivationModel.existing(for: context) {
            model.refresh()
            if model.today == today { return model.state }
        }
        return fullState(context: context, today: today)
    }

    /// 全量算一次（取出全部习惯与落笔）：没有修为模型时用；自检拿它当对照。
    /// 习惯只取 ID 再拿已登记的对象（同样的对象与次序），不重新取习惯本身，不让打卡关系变冷（见 ModelContext.allHabits）
    static func fullState(context: ModelContext, today: LocalDay = .today()) -> CultivationState {
        let config = context.all(AppSettings.self).first?.cultivation ?? CultivationConfig()
        return state(habits: context.allHabits(), entries: context.all(JournalEntry.self), config: config, today: today)
    }

    static func state(habits: [Habit], entries: [JournalEntry] = [], config: CultivationConfig, today: LocalDay = .today()) -> CultivationState {
        let sources = CultivationEngine.sources(habits: habits.map { ($0.spec, $0.logValues, $0.archived) }, today: today)
            + journalSources(entries, today: today)
        return CultivationEngine.compute(sources: sources, config: config, today: today)
    }

    static func journalSources(_ entries: [JournalEntry], today: LocalDay = .today()) -> [XPSource] {
        CultivationEngine.journalSources(entries.map { ($0.day, $0.kindValue) }, today: today)
    }

    /// 改数据前后各算一次修为，把差值交给 effects 飘“+N 修为”（落笔入卷、删除、撤销删除共用），返回差值。
    /// 这几样都只改动 day 这一天的一篇：同日递减、每日上限、功课圆满都按天算，总修为的变化 = 这一天修为的变化，
    /// 所以只取这一天的落笔与打卡算前后两次（与 HabitActions.apply 同一做法），不必把全部修行录、打卡整表取出各算一遍。
    /// 结果与“前后各全量算一次再相减”完全相同（自检里随机落笔 / 删除 / 撤销逐次对照）。
    /// 日期写坏了的那篇（修为按创建日计）找不到“这一天”，只能退回前后各算一次全部修为。
    @discardableResult
    static func withGain(on day: LocalDay, dateKey: String, context: ModelContext, effects: EffectsCenter?, _ change: () -> Void) -> Int {
        guard day.key == dateKey else {
            let before = state(context: context).totalXP
            change()
            let gain = state(context: context).totalXP - before
            effects?.gain(gain)
            return gain
        }
        let today = LocalDay.today()
        let config = context.all(AppSettings.self).first?.cultivation ?? CultivationConfig()
        // 习惯列表：有修为模型时借它的（不重新取习惯：重新取会让全部打卡关系变冷，下一次打卡要把两万条逐条补回来）
        let habits: [Habit] = CultivationModel.existing(for: context).map { model in
            model.refresh()
            return model.habits
        } ?? context.allHabits()
        let before = dayXP(day, habits: habits, context: context, config: config, today: today)
        change()
        let gain = dayXP(day, habits: habits, context: context, config: config, today: today) - before
        effects?.gain(gain)
        return gain
    }

    /// 某一天的修为：只取这一天的落笔与打卡（#Predicate 交给数据库筛），不碰习惯的打卡关系。
    /// habits 传全部习惯（含已归档的）：当天没有打卡的“每天 / 指定星期”习惯也算进功课圆满的应做数。
    /// 当天的打卡与打卡时（HabitActions）同一种取法（HabitDayLogs）：同一习惯这天有不止一条的（旧数据才可能有），
    /// 照全量计算的规则从它的打卡关系里取、以最后一条为准，结果与全量计算的当天修为相同
    static func dayXP(_ day: LocalDay, habits: [Habit], context: ModelContext, config: CultivationConfig, today: LocalDay) -> Int {
        guard day <= today else { return 0 }
        let key = day.key
        let entries = (try? context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.dateKey == key })))
            ?? context.all(JournalEntry.self).filter { $0.dateKey == key }
        let dayLogs = HabitDayLogs(day: day, context: context)
        let inputs = habits.filter { $0.modelContext != nil && !$0.isDeleted }
            .map { (spec: $0.spec, logs: dayLogs.values(of: $0), archived: $0.archived) }
        return CultivationEngine.dayXP(day, habits: inputs, journal: entries.map { ($0.day, $0.kindValue) }, config: config, today: today)
    }
}
