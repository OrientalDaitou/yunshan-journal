import Foundation

// 岁月长卷、卷中洞见、问道灵枢“长期趋势与洞察”三处共用的值类型与统计口径（纯逻辑，CoreCheck 可测）。
// 口径写死在这里，界面、AI 摘要、导出都用同一套：
// - 字数：title + body 去掉空白与换行后的 Character 数；
// - 心境日：某天所有带心境的篇目的平均（不按类型过滤，与“卷中气象”曲线同口径）；时段平均按篇（与复盘“本期素材”同口径）；
// - 当天功课完成率：只看计入“功课圆满”的功课（CultivationEngine.countsTowardPerfectDay），今天不算；
// - 时段功课完成率：各项 HabitStats.rate 按有效天数加权；
// - 消费日：只看已导全且已过完的月份，金额筛法与 monthFacts.categories 完全相同（按银行记账日期，不扣退款）；
// - 一律按 dateKey 的日期计算，晚于今天的篇目不计。

/// 修行录一篇的值拷贝。不取正文（RecordCollector 的 text: false）时 title / body / excerpt 为空、chars 为 0。
struct RecordEntry: Equatable {
    var uid: String
    var day: LocalDay
    var minute: Int?
    var kind: JournalKind
    var title: String
    var body: String
    var mood: Int?
    var tags: [String]
    var pinned: Bool
    var period: String
    /// 标题 + 正文的字数（构造时算好：引擎里要反复读）
    var chars: Int
    /// 正文折叠空白后的前 120 字，超出的加“……”（构造时算好）
    var excerpt: String

    static let excerptLength = 120

    init(uid: String, day: LocalDay, minute: Int? = nil, kind: JournalKind, title: String = "", body: String = "",
         mood: Int? = nil, tags: [String] = [], pinned: Bool = false, period: String = "") {
        self.uid = uid
        self.day = day
        self.minute = minute
        self.kind = kind
        self.title = title
        self.body = body
        self.mood = mood
        self.tags = tags
        self.pinned = pinned
        self.period = period
        chars = RecordStats.charCount(title) + RecordStats.charCount(body)
        let folded = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        excerpt = folded.count > Self.excerptLength ? String(folded.prefix(Self.excerptLength)) + "……" : folded
    }

    /// 与 JournalEntry.displayTitle 相同的规则：有标题用标题，否则正文第一行前 28 字，再没有就写类型名
    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? kind.label : String(firstLine.prefix(28))
    }
}

/// 习惯 + 全部打卡的值拷贝（含已归档的）。
struct RecordHabit {
    var title: String
    var symbol: String
    var spec: HabitSpec
    var logs: [HabitLogValue]
    var archived: Bool

    /// CultivationEngine.sources / isPerfectDay 要的写法
    var cultivationInput: (spec: HabitSpec, logs: [HabitLogValue], archived: Bool) { (spec, logs, archived) }
}

/// 统计引擎的全部输入（由 RecordCollector 从数据库取出，测试里可以手造）。
struct RecordInput {
    var today: LocalDay
    /// 只含取数窗口内的篇目（岁月长卷取全文，卡片 / AI 不取正文）
    var entries: [RecordEntry]
    /// 全部落笔的（日期, 类型）：算修为、连续纪录、记录起点、对比期篇数
    var history: [(day: LocalDay, kind: JournalKind)]
    var habits: [RecordHabit]
    var cultivation: CultivationConfig
    /// nil = 没有账簿或读不出
    var ledger: FinanceLedger?

    /// 每个习惯的统计（与 habits 一一对应）。引擎里算一次反复用
    func habitStats() -> [HabitStats] { habits.map { HabitStats(spec: $0.spec, logs: $0.logs, today: today) } }
}

enum RecordStats {
    /// 字数：去掉空白与换行后的 Character 数（汉字、字母、标点、emoji 各算 1）
    static func charCount(_ text: String) -> Int { text.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 } }

    /// 心境日：每天所有带心境篇目的平均
    static func moodByDay(_ entries: [RecordEntry]) -> [LocalDay: Double] {
        var sums: [LocalDay: (total: Int, count: Int)] = [:]
        for entry in entries {
            guard let mood = entry.mood else { continue }
            sums[entry.day, default: (0, 0)].total += mood
            sums[entry.day, default: (0, 0)].count += 1
        }
        return sums.mapValues { Double($0.total) / Double($0.count) }
    }

    /// 当天功课完成率：计入“功课圆满”的功课里达标的比例（与 CultivationEngine.isPerfectDay 同一判定）。
    /// 没有这样的功课、或这天不早于今天（还没过完）时为 nil。stats 与 habits 一一对应。
    static func dayHabitRate(_ habits: [RecordHabit], stats: [HabitStats], on day: LocalDay) -> Double? {
        guard let today = stats.first?.today, day < today else { return nil }
        var scheduled = 0, done = 0
        for (habit, s) in zip(habits, stats) {
            let ok = s.isAchieved(day)
            guard CultivationEngine.countsTowardPerfectDay(habit.spec, archived: habit.archived, on: day, achieved: ok) else { continue }
            scheduled += 1
            if ok { done += 1 }
        }
        return scheduled == 0 ? nil : Double(done) / Double(scheduled)
    }

    /// 习惯在 [from, to] 里的有效区间：[max(段首, 开始日), min(段尾, 今天, 归档日前一天)]；
    /// 已归档却没有归档日的旧数据止于最后一次打卡（一次都没打过就没有有效区间）
    static func activeRange(_ habit: RecordHabit, stats: HabitStats, from: LocalDay, to: LocalDay) -> (first: LocalDay, last: LocalDay)? {
        let first = max(from, habit.spec.startDay)
        var last = min(to, stats.today)
        if habit.archived {
            if let archivedDay = habit.spec.archivedDay {
                last = min(last, archivedDay.adding(days: -1))
            } else if let lastLog = stats.logs.keys.max() {
                last = min(last, lastLog)
            } else {
                return nil
            }
        }
        return first <= last ? (first, last) : nil
    }

    /// 时段功课完成率：每项功课在有效区间里的 HabitStats.rate，按有效天数加权平均；没有可算的功课时为 nil
    static func habitRate(_ habits: [RecordHabit], stats: [HabitStats], from: LocalDay, to: LocalDay) -> (rate: Double, habits: Int)? {
        var weighted = 0.0, weight = 0, count = 0
        for (habit, s) in zip(habits, stats) {
            guard let range = activeRange(habit, stats: s, from: from, to: to), let rate = s.rate(from: range.first, to: range.last) else { continue }
            let days = range.first.days(to: range.last) + 1
            weighted += rate * Double(days)
            weight += days
            count += 1
        }
        return weight == 0 ? nil : (weighted / Double(weight), count)
    }

    /// 期内最长连续（每天 / 指定星期按应打卡日；每周 N 次按达标的整周），今天没打不算断。
    /// 单位：每天的写“天”，指定星期的写“次”（数的是连续的应打卡日，写“天”会被当成日历上的天数；与洞见“平均连续 2.3 次”同一说法），
    /// 每周 N 次的写“周”。只有岁月长卷用；单位与首页、功课页的 HabitStats.streak（当前连续）相同
    static func longestStreak(_ stats: HabitStats, from: LocalDay, to: LocalDay) -> (count: Int, unit: String) {
        let spec = stats.spec
        let last = min(to, stats.today)
        var best = 0, run = 0
        switch spec.frequency {
        case .daily, .weekdays:
            for day in LocalDay.range(max(from, spec.startDay), last) where spec.isScheduled(day) {
                if stats.isAchieved(day) {
                    run += 1
                    best = max(best, run)
                } else if day != stats.today {
                    run = 0
                }
            }
            return (best, spec.frequency == .daily ? "天" : "次")
        case .weekly:
            let target = max(1, spec.targetPerWeek)
            var monday = max(from, spec.startDay).mondayOfWeek
            while monday <= last {
                // 与 HabitStats.streak 相同：按整周数，这一周落在段外的那几天的打卡也算
                let achieved = LocalDay.range(monday, monday.adding(days: 6)).filter(stats.isAchieved).count
                if achieved >= target {
                    run += 1
                    best = max(best, run)
                } else if monday != stats.today.mondayOfWeek {
                    run = 0
                }
                monday = monday.adding(days: 7)
            }
            return (best, "周")
        }
    }

    /// 期内的“段”（易断功课用）：达标次数、中断次数（达标后紧跟一次漏打）、最长连续、应打卡次数。
    /// 每天 / 指定星期按应打卡日；每周 N 次按整周。今天还没打的不计入。
    static func runs(_ stats: HabitStats, from: LocalDay, to: LocalDay) -> (achieved: Int, breaks: Int, longest: Int, scheduled: Int) {
        let spec = stats.spec
        let last = min(to, stats.today)
        var achieved = 0, breaks = 0, longest = 0, scheduled = 0, run = 0
        func record(_ ok: Bool) {
            scheduled += 1
            if ok {
                achieved += 1
                run += 1
                longest = max(longest, run)
            } else {
                if run > 0 { breaks += 1 }
                run = 0
            }
        }
        switch spec.frequency {
        case .daily, .weekdays:
            for day in LocalDay.range(max(from, spec.startDay), last) where spec.isScheduled(day) {
                let ok = stats.isAchieved(day)
                if day == stats.today && !ok { continue }
                record(ok)
            }
        case .weekly:
            let target = max(1, spec.targetPerWeek)
            var monday = max(from, spec.startDay).mondayOfWeek
            while monday <= last {
                let ok = LocalDay.range(monday, monday.adding(days: 6)).filter(stats.isAchieved).count >= target
                if !(monday == stats.today.mondayOfWeek && !ok) { record(ok) }
                monday = monday.adding(days: 7)
            }
        }
        return (achieved, breaks, longest, scheduled)
    }

    /// [from, to] 里 days 的最长连续一段；一样长时取靠后的那段（“至今仍在延续”更好判断）
    static func longestRun(_ days: Set<LocalDay>, from: LocalDay, to: LocalDay) -> (count: Int, first: LocalDay, last: LocalDay)? {
        guard !days.isEmpty else { return nil }
        var best: (count: Int, first: LocalDay, last: LocalDay)?
        var start: LocalDay?
        var count = 0
        for day in LocalDay.range(from, to) {
            guard days.contains(day) else {
                count = 0
                continue
            }
            if count == 0 { start = day }
            count += 1
            if let start, count >= (best?.count ?? 0) { best = (count, start, day) }
        }
        return best
    }

    /// 消费日：[from, to] 里属于“已导全（monthFacts.fullMonth）且已过完”月份的日子（covered），
    /// 以及这些日子按银行记账日期合计的消费（cents，没花钱的日子不在字典里）与笔数。
    /// 金额筛法与 monthFacts.categories 完全相同：amountCents < 0、没标“不计入”、类别不在 nonSpend（不看 kind，不扣退款）。
    static func spendDays(_ ledger: FinanceLedger, from: LocalDay, to: LocalDay, today: LocalDay)
        -> (cents: [LocalDay: Int], covered: [LocalDay], transactions: Int) {
        guard from <= to else { return ([:], [], 0) }
        var spans: [String: (first: LocalDay, last: LocalDay)] = [:]
        var covered: [LocalDay] = []
        var month = from.firstOfMonth
        while month <= to {
            let monthLast = month.adding(days: 32).firstOfMonth.adding(days: -1)
            if monthLast < today, FinanceEngine.monthFacts(ledger, month: month.monthKey).fullMonth {
                let span = (max(month, from), min(monthLast, to))
                spans[month.monthKey] = span
                covered += LocalDay.range(span.0, span.1)
            }
            month = monthLast.adding(days: 1)
        }
        guard !spans.isEmpty else { return ([:], [], 0) }
        var cents: [LocalDay: Int] = [:]
        var count = 0
        for row in ledger.transactions where row.amountCents < 0 && !row.isIgnored && !FinanceEngine.nonSpend.contains(row.category) {
            guard let span = spans[row.month], let day = LocalDay(key: row.date), day >= span.first, day <= span.last else { continue }
            cents[day, default: 0] -= row.amountCents
            count += 1
        }
        return (cents, covered, count)
    }

    /// 记录起点：全部修行录、打卡、账簿交易里最早的日期
    static func recordStart(_ input: RecordInput) -> LocalDay? {
        var earliest = input.history.map(\.day).min()
        func consider(_ day: LocalDay?) {
            guard let day else { return }
            earliest = min(earliest ?? day, day)
        }
        for habit in input.habits { consider(habit.logs.map(\.day).min()) }
        if let ledger = input.ledger {
            consider(ledger.transactions.lazy.map(\.date).filter { $0.count == 10 }.min().flatMap(LocalDay.init(key:)))
        }
        return earliest
    }

    // MARK: 数字写法（一律不随系统地区设置变）

    /// “$1,203”：四舍五入到元，千分位
    static func dollars(_ cents: Int) -> String {
        let whole = (abs(cents) + 50) / 100
        return (cents < 0 && whole > 0 ? "-$" : "$") + grouped(whole)
    }

    /// “12,480”
    static func grouped(_ n: Int) -> String {
        let digits = String(n.magnitude)
        var out = ""
        for (index, ch) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + out
    }

    /// “82%”
    static func percent(_ rate: Double) -> String { rate.isFinite ? "\(Int((rate * 100).rounded()))%" : "–" }

    /// 字数：≥ 1 万时“18.4”“万字”，否则“8,320”“字”
    static func chars(_ n: Int) -> (number: String, unit: String) {
        guard n >= 10_000 else { return (grouped(n), "字") }
        let tenth = (n + 500) / 1000
        return (tenth % 10 == 0 ? "\(tenth / 10)" : "\(tenth / 10).\(tenth % 10)", "万字")
    }

    /// “18.4 万字” / “8,320 字”
    static func charsText(_ n: Int) -> String {
        let c = chars(n)
        return "\(c.number) \(c.unit)"
    }

    /// 心境、比值的一位小数：“3.6”
    static func decimal(_ value: Double) -> String { String(format: "%.1f", value) }
}

/// 中文数字：卷首年份“二〇二六”、节号“其一”“第四季”。
enum ChineseNumerals {
    private static let digits = Array("〇一二三四五六七八九")

    /// 2026 → “二〇二六”（逐位读）
    static func year(_ y: Int) -> String {
        String(String(y.magnitude).compactMap { $0.wholeNumberValue.map { digits[$0] } })
    }

    /// 1…10 → “一”…“十”；11…99 → “十一”“二十”“二十三”（再大的按逐位读）
    static func ordinal(_ n: Int) -> String {
        switch n {
        case 1...9: return String(digits[n])
        case 10: return "十"
        case 11...19: return "十" + String(digits[n % 10])
        case 20...99: return String(digits[n / 10]) + "十" + (n % 10 == 0 ? "" : String(digits[n % 10]))
        default: return year(n)
        }
    }
}

/// 侧栏导航的 ⌘ 数字：按侧栏自上而下的位置编号，与键盘数字行 1…9、0 的顺序一致。
enum NavShortcut {
    /// 第 position 项（从 1 数）：1–9 → "1"…"9"，第 10 项 → "0"，再往后 nil（Character("10") 会运行时崩溃）
    static func digit(forPosition position: Int) -> Character? {
        switch position {
        case 1...9: return Character(String(position))
        case 10: return "0"
        default: return nil
        }
    }
}
