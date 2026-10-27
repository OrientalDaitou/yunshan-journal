import Foundation

// 快照 snapshot.md 开头的「近况速览」（境界、本周功课、目标、最近复盘、落笔与心境、消费），以及快照各节的收缩与全文硬上限。
// 全是纯函数：数据由 Services/SnapshotDigestCollector.swift 从缓存与小范围查询里取好再传进来，这里不读数据库。
// 日期一律用 LocalDay.label(relativeTo: today)：同一年写“10月21日”，跨年写“2027年2月17日”。

enum SnapshotDigest {
    struct GoalFact: Equatable {
        var title: String; var status: String; var progress: Int; var priority: String; var category: String
        var targetDate: LocalDay?; var createdDay: LocalDay; var updatedDay: LocalDay
    }
    struct HabitFact { var title: String; var stats: HabitStats }
    struct ReviewFact: Equatable { var day: LocalDay; var period: String; var title: String; var body: String }
    struct EntryFact: Equatable { var day: LocalDay; var kind: JournalKind; var mood: Int? }
    struct Realm: Equatable {
        var title: String; var totalXP: Int; var nextRealm: String?; var toNext: Int?; var last7: Int; var enabled: Bool
    }
    struct Input {
        var today: LocalDay
        var realm: Realm                        // 总有值；关了修为时 enabled = false
        var habits: [HabitFact]                 // 未归档，按 sortOrder（取自 CultivationModel.rows）
        var goals: [GoalFact]                   // 全部（含已放弃，函数里自己筛）
        var reviews: [ReviewFact]               // 近 60 天、新→旧、已去掉 AI建议
        var lastReviewDay: LocalDay?            // 全部复盘里最近一篇的日子
        var entries: [EntryFact]                // 近 14 天的全部落笔
        var lastEntryDay: LocalDay?
        var finance: PlannerSummary.Finance?
        var financeToDate: PlannerSummary.FinanceToDate?
    }

    /// 各组的条数上限（速览整体 ≤ 30 行、≤ 2,000 字）
    static let activeGoalsShown = 5
    static let reviewsShown = 3
    static let reviewDays = 60
    static let behindShown = 4
    static let steadyShown = 3
    static let weeklyShown = 6

    /// 「近况速览」的全部行（已带列表符号，不含标题）
    static func lines(_ input: Input) -> [String] {
        var out = [realmLine(input.realm)]
        out += habitLines(input.habits, today: input.today)
        out += goalLines(input.goals, today: input.today)
        out += reviewLines(input)
        out.append(writingLine(input.entries, today: input.today, lastEntryDay: input.lastEntryDay))
        out += moneyLines(input.finance, input.financeToDate, today: input.today)
        return out
    }

    // MARK: 境界

    /// “- 境界：化神 · 后期，累计修为 2,318，距「炼虚」还差 682；近 7 日 +296（日均 42）”
    static func realmLine(_ realm: Realm) -> String {
        guard realm.enabled else { return "- 境界：修为已在设置里关闭" }
        var line = "- 境界：\(realm.title)，累计修为 \(grouped(realm.totalXP))"
        if let next = realm.nextRealm, let gap = realm.toNext {
            line += "，距「\(next)」还差 \(grouped(gap))"
        } else {
            line += "，已至最高境界"
        }
        return line + "；近 7 日 +\(grouped(realm.last7))（日均 \(Int((Double(realm.last7) / 7).rounded()))）"
    }

    // MARK: 本周功课

    struct HabitRow: Equatable { var title: String; var done: Int; var due: Int }
    /// streakWeeks：连续达标的整周数（≥ 3 时写“（连续 N 周）”）
    struct WeeklyRow: Equatable { var title: String; var done: Int; var target: Int; var daysLeft: Int?; var streakWeeks: Int = 0 }
    struct StreakRow: Equatable { var title: String; var count: Int; var unit: String }
    struct WeekHabits: Equatable {
        var lastWeek: Bool; var first: LocalDay; var last: LocalDay
        var due: Int; var done: Int; var pendingToday: Int; var todayDone: Int; var todayDue: Int
        var behind: [HabitRow]; var steady: [StreakRow]; var weekly: [WeeklyRow]
    }

    /// 本周一到今天（今天是周一时看上周整周）。主行只统计“每天”“指定星期”的习惯，口径与 HabitStats.rate 一致：
    /// 窗口内自开始日期起每个应做日，达标算 done，今天没达标不计入 due（今天还有机会）；“每周 N 次”的单列。
    static func weekHabits(_ habits: [HabitFact], today: LocalDay) -> WeekHabits {
        let lastWeek = today.weekdayIndex == 0
        let first = lastWeek ? today.adding(days: -7) : today.mondayOfWeek
        let last = lastWeek ? today.adding(days: -1) : today
        // 本周剩余天数（含今天）；看上周时为 nil
        let daysLeft: Int? = lastWeek ? nil : 7 - today.weekdayIndex
        var week = WeekHabits(lastWeek: lastWeek, first: first, last: last, due: 0, done: 0, pendingToday: 0, todayDone: 0, todayDue: 0,
                              behind: [], steady: [], weekly: [])
        var behind: [(row: HabitRow, missed: Int, order: Int)] = []
        var steady: [(row: StreakRow, order: Int)] = []
        for (order, habit) in habits.enumerated() {
            let stats = habit.stats, spec = stats.spec
            if stats.isDueToday {
                week.todayDue += 1
                if stats.isAchieved(today) { week.todayDone += 1 } else { week.pendingToday += 1 }
            }
            switch spec.frequency {
            case .daily, .weekdays:
                var due = 0, done = 0
                for day in LocalDay.range(first, last) where spec.isScheduled(day) {
                    let ok = stats.isAchieved(day)
                    if day == today && !ok { continue }
                    due += 1
                    if ok { done += 1 }
                }
                week.due += due
                week.done += done
                if due - done >= 2 { behind.append((HabitRow(title: habit.title, done: done, due: due), due - done, order)) }
                let streak = stats.streak
                if streak.count >= 7 { steady.append((StreakRow(title: habit.title, count: streak.count, unit: streak.unit), order)) }
            case .weekly:
                guard spec.startDay <= last else { continue }   // 还没开始
                let target = max(1, spec.targetPerWeek)
                let done = LocalDay.range(first, last).filter(stats.isAchieved).count
                // 还差的次数比剩下的天数还多：挪进“落后”（上周已经过完，没达标就是落后）
                if target - done > (daysLeft ?? 0) {
                    behind.append((HabitRow(title: habit.title, done: done, due: target), target - done, order))
                } else {
                    week.weekly.append(WeeklyRow(title: habit.title, done: done, target: target, daysLeft: daysLeft, streakWeeks: stats.streak.count))
                }
            }
        }
        week.behind = behind.sorted { $0.missed != $1.missed ? $0.missed > $1.missed : $0.order < $1.order }.prefix(behindShown).map(\.row)
        week.steady = steady.sorted { $0.row.count != $1.row.count ? $0.row.count > $1.row.count : $0.order < $1.order }.prefix(steadyShown).map(\.row)
        return week
    }

    private static func habitLines(_ habits: [HabitFact], today: LocalDay) -> [String] {
        guard !habits.isEmpty else { return ["- 功课：还没有习惯"] }
        let week = weekHabits(habits, today: today)
        var parts: [String] = []
        // 只有“每周 N 次”的习惯时主行不写应做 / 已成
        if habits.contains(where: { $0.stats.spec.frequency != .weekly }) {
            parts.append(week.due > 0 ? "应做 \(week.due) 次，已成 \(week.done) 次（\(Int((Double(week.done) * 100 / Double(week.due)).rounded()))%）"
                                      : "还没有可统计的日子")
        }
        if week.todayDue == 0 {
            parts.append("今天没有要打的")
        } else if week.lastWeek {
            parts.append("今天已打 \(week.todayDone) / \(week.todayDue) 项")
        } else {
            parts.append(week.pendingToday > 0 ? "今天还有 \(week.pendingToday) 项没打" : "今天的都打完了")
        }
        let head = week.lastWeek ? "- 上周功课（\(rangeText(week.first, week.last, today: today))）："
                                 : "- 本周功课（\(week.first.label(relativeTo: today))起，今天第 \(today.weekdayIndex + 1) 天）："
        var out = [head + parts.joined(separator: "；")]
        if !week.behind.isEmpty { out.append("  - 落后：" + week.behind.map { "\($0.title) \($0.done)/\($0.due)" }.joined(separator: "、")) }
        if !week.steady.isEmpty { out.append("  - 稳住：" + week.steady.map { "\($0.title) 连续 \($0.count) \($0.unit)" }.joined(separator: "、")) }
        if !week.weekly.isEmpty {
            out.append("  - 每周 N 次：" + listText(week.weekly.map { row in
                var text = "\(row.title) \(row.done)/\(row.target) 次"
                if row.done >= row.target { text += " ✓" } else if let left = row.daysLeft { text += "（剩 \(left) 天）" }
                if row.streakWeeks >= 3 { text += "（连续 \(row.streakWeeks) 周）" }
                return text
            }, limit: weeklyShown))
        }
        return out
    }

    /// “10月12日–18日”；跨月 “9月28日–10月4日”
    private static func rangeText(_ first: LocalDay, _ last: LocalDay, today: LocalDay) -> String {
        let end = first.year == last.year && first.month == last.month ? "\(last.day)日" : last.label(relativeTo: today)
        return "\(first.label(relativeTo: today))–\(end)"
    }

    // MARK: 目标

    static func goalLines(_ goals: [GoalFact], today: LocalDay) -> [String] {
        guard !goals.isEmpty else { return ["- 目标：还没有设立具体目标"] }
        let active = byDeadline(goals.filter { $0.status == "active" })
        let paused = goals.filter { $0.status == "paused" }
        let completed = goals.filter { $0.status == "completed" }
        let recent = completed.enumerated()
            .filter { $0.element.updatedDay >= today.adding(days: -29) && $0.element.updatedDay <= today }
            .sorted { $0.element.updatedDay != $1.element.updatedDay ? $0.element.updatedDay > $1.element.updatedDay : $0.offset < $1.offset }
            .map(\.element)
        var out: [String] = []
        if active.isEmpty && paused.isEmpty {
            out.append("- 目标：目前没有进行中的目标" + (completed.isEmpty ? "" : "（已完成 \(completed.count) 个）"))
        } else {
            let counts = [active.isEmpty ? nil : "进行中 \(active.count)", paused.isEmpty ? nil : "暂停 \(paused.count)"].compactMap { $0 }
            out.append("- 目标（\(counts.joined(separator: " · "))）：")
            out += active.prefix(activeGoalsShown).map { "  - " + activeGoalText($0, today: today) }
            if active.count > activeGoalsShown {
                out.append("  - 另有 \(active.count - activeGoalsShown) 个进行中的目标，见下方「目标」一节")
            }
            if !paused.isEmpty { out.append("  - 暂停：" + listText(paused.map { "\($0.title) \($0.progress)%" }, limit: 5)) }
        }
        if !recent.isEmpty {
            // 模型没有“完成日”，括号里是最后更新那天
            out.append("  - 近 30 天完成：" + listText(recent.map { "\($0.title)（\($0.updatedDay.label(relativeTo: today))）" }, limit: 3))
        }
        return out
    }

    /// “完成学位论文初稿 65%，期限 2027年2月17日（还剩 119 天）［必须］”；进度落后时间进度 10 个点以上时加“时间已过 N%”
    private static func activeGoalText(_ g: GoalFact, today: LocalDay) -> String {
        var text = "\(g.title) \(g.progress)%"
        if let deadline = g.targetDate {
            let left = today.days(to: deadline)
            var info = left > 0 ? "还剩 \(left) 天" : left == 0 ? "今天到期" : "已逾期 \(-left) 天"
            if left > 0, let share = timeShare(created: g.createdDay, deadline: deadline, today: today), g.progress < share - 10 {
                info += "，时间已过 \(share)%"
            }
            text += "，期限 \(deadline.label(relativeTo: today))（\(info)）"
        }
        if g.priority == "must" { text += "［\(GoalCatalog.priorityLabels["must"] ?? "必须")］" }
        return text
    }

    /// 时间进度：（今天 − 创建日）÷（期限 − 创建日），0–100。创建日不早于期限时不算
    static func timeShare(created: LocalDay, deadline: LocalDay, today: LocalDay) -> Int? {
        let total = created.days(to: deadline)
        guard total > 0 else { return nil }
        let passed = Double(created.days(to: today)) / Double(total)
        return Int((min(1, max(0, passed)) * 100).rounded())
    }

    /// 已逾期的在前，再按期限近→远，无期限的在后；同期限的“必须”在前；其余保持原来的先后
    static func byDeadline(_ goals: [GoalFact]) -> [GoalFact] {
        goals.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if x.targetDate != y.targetDate {
                guard let dx = x.targetDate else { return false }
                guard let dy = y.targetDate else { return true }
                return dx < dy
            }
            let mx = x.priority == "must", my = y.priority == "must"
            if mx != my { return mx }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: 最近复盘

    private static func reviewLines(_ input: Input) -> [String] {
        let since = input.today.adding(days: -(reviewDays - 1))
        let recent = input.reviews.filter { $0.day >= since && $0.day <= input.today }.prefix(reviewsShown)
        guard !recent.isEmpty else {
            if let last = input.lastReviewDay { return ["- 最近复盘：近 \(reviewDays) 天没有（上一篇 \(last.label(relativeTo: input.today))）"] }
            return ["- 最近复盘：还没有写过复盘"]
        }
        return ["- 最近复盘："] + recent.map { reviewLine($0, today: input.today) }
    }

    /// “  - 10月18日 周复盘「第 42 周复盘」— 所悟：…；下一步：…”（没填周期写“复盘”，没有标题省掉「」）
    static func reviewLine(_ review: ReviewFact, today: LocalDay) -> String {
        let period = ReviewPeriod.label(for: review.period)
        var line = "  - \(review.day.label(relativeTo: today)) \(period.isEmpty ? JournalKind.review.label : period)"
        let title = CourierItem.oneLine(review.title)
        if !title.isEmpty { line += "「\(title)」" }
        let points = reviewPoints(review.body)
        if !points.isEmpty { line += (title.isEmpty ? " — " : "— ") + points }
        return line
    }

    /// 复盘要点：按【所得】【所失】【所悟】【下一步】切段，取“所悟”与“下一步”的第一句（缺一段只取另一段；两段都空取“所得”“所失”），
    /// 每句 ≤ 40 字；没有任何【】标记时，空白折叠后取前 80 字。整体不超过 limit
    static func reviewPoints(_ body: String, limit: Int = 90) -> String {
        let names = ["所得", "所失", "所悟", "下一步"]
        var marks: [(name: String, range: Range<String.Index>)] = []
        for name in names {
            var from = body.startIndex
            while let range = body.range(of: "【\(name)】", range: from..<body.endIndex) {
                marks.append((name, range))
                from = range.upperBound
            }
        }
        guard !marks.isEmpty else {
            let text = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return text.count > 80 ? String(text.prefix(80)) + "…" : text
        }
        marks.sort { $0.range.lowerBound < $1.range.lowerBound }
        var sections: [String: String] = [:]
        for (index, mark) in marks.enumerated() {
            let end = index + 1 < marks.count ? marks[index + 1].range.lowerBound : body.endIndex
            let content = body[mark.range.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            // 同一段写了两次时取第一段有内容的
            if (sections[mark.name] ?? "").isEmpty { sections[mark.name] = content }
        }
        /// 段内第一句：到第一个 。！？!?；; 或换行为止，≤ 40 字
        func firstSentence(_ name: String) -> String? {
            guard let text = sections[name], !text.isEmpty else { return nil }
            let sentence = text.prefix { !$0.isNewline && !"。！？!?；;".contains($0) }.trimmingCharacters(in: .whitespaces)
            guard !sentence.isEmpty else { return nil }
            return sentence.count > 40 ? String(sentence.prefix(40)) + "…" : sentence
        }
        func pick(_ pair: [String]) -> [String] { pair.compactMap { name in firstSentence(name).map { "\(name)：\($0)" } } }
        var parts = pick(["所悟", "下一步"])
        if parts.isEmpty { parts = pick(["所得", "所失"]) }
        let text = parts.joined(separator: "；")
        return text.count > limit ? String(text.prefix(max(0, limit - 1))) + "…" : text
    }

    // MARK: 落笔

    /// “- 落笔：近 7 天 9 篇（日记 6 · 灵感 2 · 复盘 1），心境多「晴」，均值 3.7（前 7 天 3.2）”。
    /// 心境只看日记，按篇平均、保留一位小数；“多”取出现次数最多的一档，并列时取较好的
    static func writingLine(_ entries: [EntryFact], today: LocalDay, lastEntryDay: LocalDay?) -> String {
        let recentFrom = today.adding(days: -6), previousFrom = today.adding(days: -13)
        let recent = entries.filter { $0.day >= recentFrom && $0.day <= today }
        guard !recent.isEmpty else {
            let last = lastEntryDay ?? entries.filter { $0.day <= today }.map(\.day).max()
            guard let last else { return "- 落笔：还没有写过日记、灵感或复盘" }
            return "- 落笔：近 7 天没有落笔（上一篇 \(last.label(relativeTo: today))）"
        }
        let kinds = JournalKind.allCases.compactMap { kind -> String? in
            let count = recent.filter { $0.kind == kind }.count
            return count > 0 ? "\(kind.label) \(count)" : nil
        }
        var line = "- 落笔：近 7 天 \(recent.count) 篇（\(kinds.joined(separator: " · "))）"
        let moods = diaryMoods(recent)
        if !moods.isEmpty {
            var counts: [Int: Int] = [:]
            for mood in moods { counts[mood, default: 0] += 1 }
            let top = counts.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? moods[0]
            line += "，心境多「\(Mood.label(top))」，均值 \(oneDecimal(moods))"
            let previous = diaryMoods(entries.filter { $0.day >= previousFrom && $0.day < recentFrom })
            if !previous.isEmpty { line += "（前 7 天 \(oneDecimal(previous))）" }
        }
        return line
    }

    private static func diaryMoods(_ entries: [EntryFact]) -> [Int] {
        entries.filter { $0.kind == .diary }.compactMap(\.mood).filter { (1...5).contains($0) }
    }

    private static func oneDecimal(_ values: [Int]) -> String {
        String(format: "%.1f", Double(values.reduce(0, +)) / Double(values.count))
    }

    // MARK: 消费

    /// 只有三种情况：有本月至今（另有最近整月）/ 账上只有本月 / 没有账。数据取 PlannerSummary，已经算好，不再读账本
    static func moneyLines(_ finance: PlannerSummary.Finance?, _ toDate: PlannerSummary.FinanceToDate?, today: LocalDay) -> [String] {
        if let m = toDate {
            let bank: String
            if let through = m.bankThrough, through >= m.through {
                bank = "银行流水已导入到 \(dayText(through, today: today))"
            } else if let through = m.bankThrough {
                bank = "银行流水只导入到 \(dayText(through, today: today))，之后的刷卡还没进账"
            } else {
                bank = "还没导入过银行流水"
            }
            var out = ["- 消费：\(monthText(m.month, today: today))至今净消费 \(m.netSpend)（\(bank)）" + mainCategories(m.topCategories)]
            if let f = finance {
                var line = "  - \(monthText(f.month, today: today))（\(f.fullMonth ? "最近一个整月" : "账单不全")）：净消费 \(f.netSpend)"
                if let change = f.changeVsPreviousMonth?.components(separatedBy: "，").first, !change.isEmpty { line += "，较上月 \(change)" }
                if f.pendingReview > 0 { line += "；另有 \(f.pendingReview) 笔待确认" }
                out.append(line)
            }
            return out
        }
        if let f = finance {
            var line = "- 消费：\(monthText(f.month, today: today))\(f.fullMonth ? "" : "（账单不全）")净消费 \(f.netSpend)" + mainCategories(f.topCategories)
            if f.pendingReview > 0 { line += "；另有 \(f.pendingReview) 笔待确认" }
            return [line]
        }
        return ["- 消费：还没有账目"]
    }

    /// “；主要：餐饮与外卖 $312.50、超市与食品 $268.10、交通出行 $145.00”（前 3 个）
    private static func mainCategories(_ top: [String]) -> String {
        top.isEmpty ? "" : "；主要：" + top.prefix(3).joined(separator: "、")
    }

    /// “2026年9月” → 同年时 “9月”，跨年原样
    static func monthText(_ label: String, today: LocalDay) -> String {
        let prefix = "\(today.year)年"
        return label.hasPrefix(prefix) ? String(label.dropFirst(prefix.count)) : label
    }

    // MARK: 写法

    /// 千分位：2318 → “2,318”
    static func grouped(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var out = ""
        for (index, ch) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (value < 0 ? "-" : "") + out
    }

    private static func dayText(_ key: String, today: LocalDay) -> String { LocalDay(key: key)?.label(relativeTo: today) ?? key }

    private static func listText(_ items: [String], limit: Int) -> String {
        items.prefix(limit).joined(separator: "、") + (items.count > limit ? " 等 \(items.count) 个" : "")
    }
}

/// 快照各节收缩与全文硬上限
enum SnapshotTrim {
    struct Limits {
        var journalDays = 60, fullDays = 14
        var fullBody = 1_500, olderBody = 200, olderReviewBody = 800
        var journalBudget = 25_000, keepNewest = 3
        var manualList = 15, deliveries = 5
        var activeGoalsMax = 30, completedGoalDays = 90, completedGoalsMax = 5
        var totalCap = 40_000
    }

    /// 快照“目标”一节：进行中 / 暂停（各按期限近→远，无期限的排后；合计 ≤ 30）+ 90 天内完成的（新→旧，≤ 5）；已放弃的不列
    static func goals(_ facts: [SnapshotDigest.GoalFact], today: LocalDay, limits: Limits) -> [PlannerSummary.Goal] {
        let open = SnapshotDigest.byDeadline(facts.filter { $0.status == "active" }) + SnapshotDigest.byDeadline(facts.filter { $0.status == "paused" })
        let since = today.adding(days: -(limits.completedGoalDays - 1))
        let done = facts.enumerated().filter { $0.element.status == "completed" && $0.element.updatedDay >= since }
            .sorted { $0.element.updatedDay != $1.element.updatedDay ? $0.element.updatedDay > $1.element.updatedDay : $0.offset < $1.offset }
            .map(\.element)
        return (open.prefix(limits.activeGoalsMax) + done.prefix(limits.completedGoalsMax)).map {
            PlannerSummary.Goal(title: $0.title, category: $0.category, status: GoalCatalog.statusLabel($0.status), progress: $0.progress,
                                targetDate: $0.targetDate?.key)
        }
    }

    /// 修行录：按年龄压正文、按预算省略最早的；返回新增省略条数。items 须是新→旧（快照的 journalNewestFirst）。
    /// 近 fullDays 天每篇 ≤ fullBody 字；更早的复盘 ≤ olderReviewBody、日记与灵感 ≤ olderBody；至少保留最新 keepNewest 篇。
    /// 判断复盘用 `item.kind == JournalKind.review.label`（JournalItem.kind 存的是中文标签“复盘”，不是 rawValue）
    static func journal(_ items: [PlannerSummary.JournalItem], today: LocalDay, limits: Limits,
                        budget: Int) -> (items: [PlannerSummary.JournalItem], omitted: Int) {
        let fullSince = today.adding(days: -(limits.fullDays - 1)).key
        let review = JournalKind.review.label
        var kept: [PlannerSummary.JournalItem] = []
        var used = 0
        for (index, original) in items.enumerated() {
            var item = original
            let limit = item.date >= fullSince ? limits.fullBody : item.kind == review ? limits.olderReviewBody : limits.olderBody
            // SummaryCollector 截短时也是“前 N 字 + ……”：再截一次结果不变
            if item.body.count > limit { item.body = String(item.body.prefix(limit)) + "……" }
            let size = item.body.count + item.title.count
            if kept.count >= limits.keepNewest, used + size > budget { return (kept, items.count - index) }
            used += size
            kept.append(item)
        }
        return (kept, 0)
    }

    /// 渲染 + 全文硬上限：超过 totalCap 字时，修行录预算再减去“超出量 + 1,000”重排，最多 5 轮
    static func compose(_ summary: PlannerSummary, preamble: String, digest: [String], today: LocalDay, limits: Limits) -> String {
        var budget = limits.journalBudget
        var text = ""
        for round in 0...5 {
            var s = summary
            let trimmed = journal(summary.journal, today: today, limits: limits, budget: budget)
            s.journal = trimmed.items
            s.journalOmitted = summary.journalOmitted + trimmed.omitted
            text = SummaryRenderer.markdown(s, preamble: preamble, digest: digest, overviewTitle: "传书近况", multilineProfile: true)
            let over = text.count - limits.totalCap
            guard over > 0, round < 5, budget > 0 else { break }
            budget = max(0, budget - (over + 1_000))
        }
        return text
    }
}
