import Foundation

// 岁月长卷：选一年或一季，把这段时间的落笔、心境、功课、修为、灵石、珍藏与洞见汇成一份报告（纯逻辑）。
// 页面（AnnalsView / AnnalsSections）与 Markdown 导出（AnnalsRenderer）都只读这份报告，口径见 RecordStats。

enum AnnalsScope: Hashable {
    /// 全年
    case year(Int)
    /// （年, 第几季 1…4）
    case quarter(Int, Int)

    var year: Int {
        switch self {
        case .year(let y), .quarter(let y, _): y
        }
    }
}

/// 一段回看时段：起止（已截到今天）、对比期（同样长度）与各处要用的文案。
struct AnnalsPeriod: Hashable {
    var scope: AnnalsScope
    var first: LocalDay
    /// 已截到今天
    var last: LocalDay
    var isOngoing: Bool
    /// 对比期：全年 → 上一年同月同日（2/29 → 2/28）；季度 → 上一季首日起同样天数、不超过上一季末
    var previousFirst: LocalDay
    var previousLast: LocalDay
    /// “二〇二六年” / “二〇二六年 · 第四季”
    var title: String
    /// “1月1日 — 10月20日 · 尚未过完” / “全年 365 天” / “7月1日 — 9月30日 · 共 92 天”
    var rangeLabel: String
    /// “去年同期” / “上一年” / “上一季同期” / “上一季”
    var previousLabel: String
    /// “2026” / “2026-Q4”（@AppStorage 里存的就是它）
    var storageKey: String
    /// “今年” / “这一年” / “本季” / “这一季”
    var unitLabel: String

    var dayCount: Int { first.days(to: last) + 1 }

    /// 还没开始的时段（未来的年份、季度）、不存在的季度返回 nil
    static func make(_ scope: AnnalsScope, today: LocalDay) -> AnnalsPeriod? {
        let first: LocalDay, end: LocalDay, previousFirst: LocalDay, previousEnd: LocalDay
        switch scope {
        case .year(let y):
            guard (2...9999).contains(y) else { return nil }
            first = LocalDay(year: y, month: 1, day: 1)
            end = LocalDay(year: y, month: 12, day: 31)
            previousFirst = LocalDay(year: y - 1, month: 1, day: 1)
            previousEnd = LocalDay(year: y - 1, month: 12, day: 31)
        case .quarter(let y, let q):
            guard (2...9999).contains(y), (1...4).contains(q) else { return nil }
            first = LocalDay(year: y, month: q * 3 - 2, day: 1)
            end = monthEnd(LocalDay(year: y, month: q * 3, day: 1))
            let (py, pq) = q == 1 ? (y - 1, 4) : (y, q - 1)
            previousFirst = LocalDay(year: py, month: pq * 3 - 2, day: 1)
            previousEnd = monthEnd(LocalDay(year: py, month: pq * 3, day: 1))
        }
        guard first <= today else { return nil }
        let last = min(end, today)
        let ongoing = last < end
        let previousLast: LocalDay
        switch scope {
        case .year(let y):
            previousLast = ongoing ? sameDay(as: last, inYear: y - 1) : previousEnd
        case .quarter:
            previousLast = min(previousFirst.adding(days: first.days(to: last)), previousEnd)
        }
        let days = first.days(to: last) + 1
        let range: String
        if ongoing {
            range = (first == last ? first.shortLabel : "\(first.shortLabel) — \(last.shortLabel)") + " · 尚未过完"
        } else if case .year = scope {
            range = "全年 \(days) 天"
        } else {
            range = "\(first.shortLabel) — \(last.shortLabel) · 共 \(days) 天"
        }
        switch scope {
        case .year(let y):
            return AnnalsPeriod(scope: scope, first: first, last: last, isOngoing: ongoing, previousFirst: previousFirst, previousLast: previousLast,
                                title: ChineseNumerals.year(y) + "年", rangeLabel: range, previousLabel: ongoing ? "去年同期" : "上一年",
                                storageKey: "\(y)", unitLabel: ongoing ? "今年" : "这一年")
        case .quarter(let y, let q):
            return AnnalsPeriod(scope: scope, first: first, last: last, isOngoing: ongoing, previousFirst: previousFirst, previousLast: previousLast,
                                title: ChineseNumerals.year(y) + "年 · 第" + ChineseNumerals.ordinal(q) + "季", rangeLabel: range,
                                previousLabel: ongoing ? "上一季同期" : "上一季", storageKey: "\(y)-Q\(q)", unitLabel: ongoing ? "本季" : "这一季")
        }
    }

    /// 记录不满几天算“刚起步”：默认看本季而不是全年（全年 12 格只有一两格有柱、完成率被没开始的月份摊薄）
    static let recentDays = 90
    /// 每段（年 / 季）开头几天仍看上一段：刚翻页的这一段还没几天可看
    static let lookBackDays = 15

    /// 没选过（或选的已失效）时的默认。firstRecord = 最早一条修行录 / 打卡的日子（nil = 还没有记录）：
    /// - 记录不满 90 天 → 本季；本季刚开头 15 天内、上一季也有记录时看上一季（1 月上半月因此看上一年第四季）
    /// - 其余 → 全年；1 月 1–15 日看上一年全年
    static func defaultScope(today: LocalDay, firstRecord: LocalDay? = nil) -> AnnalsScope {
        if let firstRecord, firstRecord <= today, firstRecord.days(to: today) < recentDays {
            let q = (today.month - 1) / 3 + 1
            let quarterStart = LocalDay(year: today.year, month: q * 3 - 2, day: 1)
            if quarterStart.days(to: today) < lookBackDays, firstRecord < quarterStart {
                return q == 1 ? .quarter(today.year - 1, 4) : .quarter(today.year, q - 1)
            }
            return .quarter(today.year, q)
        }
        return today.month == 1 && today.day <= lookBackDays ? .year(today.year - 1) : .year(today.year)
    }

    static func monthEnd(_ day: LocalDay) -> LocalDay { day.firstOfMonth.adding(days: 32).firstOfMonth.adding(days: -1) }

    /// 上一年的同月同日；那年没有这一天（2/29）时取当月最后一天
    private static func sameDay(as day: LocalDay, inYear year: Int) -> LocalDay {
        let end = monthEnd(LocalDay(year: year, month: day.month, day: 1))
        return LocalDay(year: year, month: day.month, day: min(day.day, end.day))
    }
}

extension AnnalsPeriod {
    /// 解析 storageKey（“2026” / “2026-Q4”）；解析不了、还没开始的返回 nil（页面改用 defaultScope）
    init?(storageKey: String, today: LocalDay) {
        let parts = storageKey.split(separator: "-", omittingEmptySubsequences: false)
        let scope: AnnalsScope
        if parts.count == 1, parts[0].count == 4, let y = Int(parts[0]) {
            scope = .year(y)
        } else if parts.count == 2, parts[0].count == 4, let y = Int(parts[0]), parts[1].count == 2, parts[1].first == "Q",
                  let q = Int(parts[1].dropFirst()) {
            scope = .quarter(y, q)
        } else {
            return nil
        }
        guard let period = AnnalsPeriod.make(scope, today: today) else { return nil }
        self = period
    }
}

/// 一段时间的长卷报告。没有数据的部分为 nil（页面与导出都按“有数据才出这一节”处理）。
struct AnnalsReport {
    var period: AnnalsPeriod
    /// 生成这份报告时的“今天”（卷尾“辑于 …”）
    var today: LocalDay
    /// 期内没有落笔、没有有效功课、账簿期内没有交易
    var isEmpty: Bool
    var recordStart: LocalDay?
    var writing: Writing?
    var mood: MoodPart?
    var habits: HabitPart?
    var cultivation: CultivationPart?
    var finance: FinancePart?
    var highlights: Highlights
    var insights: [Insight]

    /// 记录起点晚于段首：卷首接“ · 记录始于 2024年10月21日”
    var startsLate: Bool { recordStart.map { $0 > period.first } ?? false }

    /// 图表的一格：全年按月（“3月”），季度按周（周一起，首尾不足一周照算，标签是这一格的首日“10/6”）
    struct Bucket: Equatable {
        var start: LocalDay
        var label: String
        var last: LocalDay
    }

    struct Writing {
        var entries: Int
        var byKind: [JournalKind: Int]
        var chars: Int
        var writingDays: Int
        /// “动笔占比”的分母：段内且不早于记录起点的天数
        var spanDays: Int
        /// 最长连续落笔（≥ 2 天才有）
        var longestRun: (count: Int, first: LocalDay, last: LocalDay)?
        /// 字数最多的一篇（不取正文时为 nil）
        var longest: RecordEntry?
        var perBucket: [(bucket: Bucket, diary: Int, note: Int, review: Int)]
        /// 前 10 个标签（篇数降序，同数按首次出现早的在前）
        var tags: [(tag: String, count: Int)]
        /// 对比期篇数（从 history 数）；记录起点晚于对比期首 7 天以上时为 nil（没法比）
        var previousEntries: Int?

        /// 动笔日均字数（四舍五入）
        var averageChars: Int { writingDays == 0 ? 0 : (chars + writingDays / 2) / writingDays }
        /// 动笔天数占比 0…1
        var writingShare: Double { spanDays == 0 ? 0 : Double(writingDays) / Double(spanDays) }
    }

    struct MoodPart {
        /// 曲线：全年按周（这一周心境日的平均，日期为这一周在段内的首日），季度按日（心境日）
        var points: [(day: LocalDay, value: Double)]
        /// 下标 1…5 = 雨 阴 平 晴 霁 的篇数（下标 0 不用）
        var distribution: [Int]
        /// 按篇平均
        var average: Double
        /// 带心境的篇数
        var entries: Int
        /// 最晴 / 最阴的月份（只比心境日 ≥ 5 天的月份，至少两个、差 ≥ 0.3 才有）
        var brightest: (label: String, value: Double)?
        var dimmest: (label: String, value: Double)?

        /// “多在「晴」”：篇数最多的一档；一样多时取离平均更近的
        var dominant: Int {
            (1...5).max { a, b in
                distribution[a] != distribution[b] ? distribution[a] < distribution[b] : abs(Double(a) - average) > abs(Double(b) - average)
            } ?? 3
        }
    }

    struct HabitPart {
        var rate: Double
        /// 对比期的综合完成率（对比期至少一项功课有效 ≥ 14 天才有）
        var previousRate: Double?
        /// 期内“功课圆满”的天数
        var perfectDays: Int
        var perBucket: [(bucket: Bucket, rate: Double?)]
        /// 按完成率降序，已归档的排最后
        var rows: [HabitRow]
    }

    struct HabitRow {
        var title: String
        var symbol: String
        /// spec.scheduleSummary
        var schedule: String
        var rate: Double
        /// 有效区间里达标的次数
        var achieved: Int
        var longest: (count: Int, unit: String)
        var archived: Bool
    }

    struct CultivationPart {
        var gained: Int
        var startXP: Int
        var endXP: Int
        /// 已 sanitized
        var config: CultivationConfig
        /// 期内每次升入新境界（一天跨两个境界时各一行）
        var breakthroughs: [(day: LocalDay, realm: String, index: Int)]
        var perBucket: [(bucket: Bucket, xp: Int)]

        var startState: CultivationState { CultivationEngine.state(for: startXP, config: config) }
        var endState: CultivationState { CultivationEngine.state(for: endXP, config: config) }
    }

    struct FinancePart {
        var netCents: Int
        var spendCents: Int
        var refundCents: Int
        /// 段内的月份（账簿最早一笔之前的月份不列）。已过完的月份 full = monthFacts.fullMonth；
        /// 本月 ongoing、label 写“10月（至今）”，full 按“至今”判断（AnnalsEngine.coveredSoFar）。
        /// 只含手记的账簿 full 一律是 false，界面按 manualOnly 处理：不标“未导全”、不变淡
        var months: [(month: String, label: String, netCents: Int, full: Bool, ongoing: Bool)]
        /// 前 6 类；change：能比较时为配对月份里的增减（分），否则 nil
        var categories: [(name: String, cents: Int, change: Int?)]
        /// 前 6 类之外还有几类
        var otherCategories: Int
        /// 按顺序配对、两边都整月导全且都已过完的月份：配对数与两边的净消费合计
        var comparison: (months: Int, previousNetCents: Int, currentNetCents: Int)?
        /// 未导全的月份（“8月”；本月按“至今”算），只含手记时为空
        var incompleteMonths: [String]
        var pendingReview: Int
        /// 账簿从没导入过银行账单（ledger.sources 为空）：不标“未导全”、不出未导全提示、不比较
        var manualOnly: Bool

        /// 逐月柱的刻度下标：本月写“至今”；已过完又没导全的写 partial（PartialMonthRule.label“未导全”，
        /// 与灵石账簿月份旁、导出逐月表同一个说法、同一条判断）；导全的、只含手记的账簿不写
        static func monthNote(full: Bool, ongoing: Bool, manualOnly: Bool, partial: String = PartialMonthRule.label) -> String {
            if ongoing { return "至今" }
            return PartialMonthRule.flags(full: full, manualOnly: manualOnly) ? partial : ""
        }

        /// 节末的一行说明（有哪句写哪句，用“；”连成一行）；都没有时为 nil
        var remark: String? {
            var parts: [String] = []
            if manualOnly { parts.append("账目只含手记，还没导入银行账单") }
            if !incompleteMonths.isEmpty { parts.append(incompleteMonths.joined(separator: "、") + "账单未导全，合计可能偏低") }
            if let comparison { parts.append("按 \(comparison.months) 个已导全的整月比较") }
            if pendingReview > 0 { parts.append("另有 \(pendingReview) 笔待确认用途") }
            return parts.isEmpty ? nil : parts.joined(separator: "；") + "。"
        }
    }

    struct Highlights {
        /// 期内珍藏，按日期先后，最多 8 篇
        var pinned: [RecordEntry]
        /// 珍藏超出 8 篇的数目
        var pinnedMore: Int
        /// 不在珍藏里的日记按字数取前 3 篇（≥ 100 字）
        var longest: [RecordEntry]

        var isEmpty: Bool { pinned.isEmpty && longest.isEmpty }
    }

    static let pinnedLimit = 8
    static let longestLimit = 3
    static let longestMinChars = 100

    /// “+12%” / “−5%”（较对比期）；对比期为 0 时 nil
    static func change(_ current: Int, from previous: Int) -> String? {
        guard previous > 0 else { return nil }
        let percent = Int((Double(current - previous) / Double(previous) * 100).rounded())
        return percent >= 0 ? "+\(percent)%" : "−\(-percent)%"
    }

    /// 变化四舍五入后是 0（“+0%”）：写“与去年同期持平”，不写“较去年同期 +0%”
    static func isFlat(_ change: String) -> Bool { change == "+0%" }

    /// 与对比期比较的一句：“较去年同期 +12%” / “与去年同期持平”；对比期为 0 时 nil
    static func compareText(_ current: Int, from previous: Int, label: String) -> String? {
        change(current, from: previous).map { isFlat($0) ? flatText(label) : "较\(label) \($0)" }
    }

    /// 完成率的对比：“去年同期 62%”；两边显示出来的百分数一样时写“与去年同期持平”
    static func rateCompareText(_ rate: Double, previous: Double, label: String) -> String {
        RecordStats.percent(rate) == RecordStats.percent(previous) ? flatText(label) : "\(label) \(RecordStats.percent(previous))"
    }

    /// 金额变化（分）按整元四舍五入后是 0（不到 50 分，与 RecordStats.dollars 同一种取整）：写“与上一季持平”，不写“+$0 / −$0”
    static func isFlatCents(_ cents: Int) -> Bool { abs(cents) < 50 }

    /// “与去年同期持平” / “与上一季持平”
    static func flatText(_ label: String) -> String { "与\(label)持平" }
}

extension AnnalsReport.CultivationPart {
    /// 期初期末的境界与小阶都一样：修为节只画一枚徽记写“稳在”。
    /// 同一境界里升了小阶（“渡劫 · 中期 → 大圆满”）和破了境一样，都画期初 → 期末两枚徽记对照，不能写成“稳在”
    var isSteady: Bool { breakthroughs.isEmpty && startState.title == endState.title }

    /// 没破境时本境里进了几阶（初期 → 中期 → 后期 → 圆满 → 大圆满）；破了境或没进阶时 0
    var stagesAdvanced: Int {
        guard breakthroughs.isEmpty else { return 0 }
        let order = CultivationEngine.stages + ["大圆满"]
        let from = order.firstIndex(of: startState.stage) ?? 0, to = order.firstIndex(of: endState.stage) ?? 0
        return max(0, to - from)
    }

    /// 没破境时的一句（修为节、导出同一句）：“这一年稳在「渡劫 · 大圆满」，累计 +17,511”（累计 = 这一段所得）；
    /// unitLabel 是“今年 / 这一年 / 本季 / 这一季”。只在 isSteady 时用
    func steadyLine(unitLabel: String) -> String {
        "\(unitLabel)稳在「\(endState.title)」，累计 +\(RecordStats.grouped(gained))"
    }

    /// 本境进阶的一句：“由「渡劫 · 中期」进到「渡劫 · 大圆满」”
    var advanceLine: String { "由「\(startState.title)」进到「\(endState.title)」" }

    /// 本境进阶时对照卡箭头上的字：“进 3 阶”
    var advanceLabel: String { "进 \(stagesAdvanced) 阶" }

    /// 卷首格修为下的小字：稳在 → “稳在 渡劫 · 大圆满”；本境进阶 → “渡劫 · 中期 → 大圆满”；破境 → “大乘 → 渡劫”
    var tileNote: String {
        let start = startState, end = endState
        if isSteady { return "稳在 \(end.title)" }
        if breakthroughs.isEmpty { return "\(start.title) → \(end.stage)" }
        return "\(start.realmName) → \(end.realmName)"
    }
}

enum AnnalsEngine {
    static func report(_ period: AnnalsPeriod, input: RecordInput) -> AnnalsReport {
        let today = input.today
        let first = period.first, last = min(period.last, today)
        let entries = input.entries.enumerated()
            .filter { $0.element.day >= first && $0.element.day <= last }
            .sorted { ($0.element.day, $0.element.minute ?? -1, $0.offset) < ($1.element.day, $1.element.minute ?? -1, $1.offset) }
            .map(\.element)
        let stats = input.habitStats()
        let recordStart = RecordStats.recordStart(input)
        let buckets = self.buckets(period)
        // 修为来源与“功课圆满”天数共用一份
        let habitSources = CultivationEngine.sources(habits: input.habits.map(\.cultivationInput), today: today)

        let writing = self.writing(entries, period: period, input: input, recordStart: recordStart, buckets: buckets)
        let mood = self.mood(entries, period: period, buckets: buckets)
        let habits = self.habits(period, input: input, stats: stats, habitSources: habitSources, buckets: buckets)
        let cultivation = self.cultivation(period, input: input, habitSources: habitSources, buckets: buckets)
        let finance = input.ledger.flatMap { self.finance(period, ledger: $0, today: today) }

        let pinned = entries.filter(\.pinned)
        let longest = entries.filter { $0.kind == .diary && !$0.pinned && $0.chars >= AnnalsReport.longestMinChars }
            .enumerated().sorted { ($1.element.chars, $0.offset) < ($0.element.chars, $1.offset) }.map(\.element)
        let highlights = AnnalsReport.Highlights(pinned: Array(pinned.prefix(AnnalsReport.pinnedLimit)),
                                                 pinnedMore: max(0, pinned.count - AnnalsReport.pinnedLimit),
                                                 longest: Array(longest.prefix(AnnalsReport.longestLimit)))
        // 洞见窗口在 InsightEngine 里截到昨天（段首就是今天时没有洞见）；止日照传段尾，是让连续落笔把今天已写的也算上；
        // 连续落笔不往段首之前延伸（跨季、跨年时也只数段内）：与其一的“最长连续”“动笔天数”同一个数
        let insights = InsightEngine.insights(input, from: first, to: last, streakBeforeFrom: false)

        return AnnalsReport(period: period, today: today, isEmpty: entries.isEmpty && habits == nil && finance == nil,
                            recordStart: recordStart, writing: writing, mood: mood, habits: habits, cultivation: cultivation,
                            finance: finance, highlights: highlights, insights: insights)
    }

    /// 图表的格子：全年按月，季度按周（周一起，首尾截在段内）
    static func buckets(_ period: AnnalsPeriod) -> [AnnalsReport.Bucket] {
        var result: [AnnalsReport.Bucket] = []
        switch period.scope {
        case .year:
            var month = period.first.firstOfMonth
            while month <= period.last {
                let end = AnnalsPeriod.monthEnd(month)
                result.append(.init(start: max(month, period.first), label: "\(month.month)月", last: min(end, period.last)))
                month = end.adding(days: 1)
            }
        case .quarter:
            var monday = period.first.mondayOfWeek
            while monday <= period.last {
                let start = max(monday, period.first)
                result.append(.init(start: start, label: start.axisLabel, last: min(monday.adding(days: 6), period.last)))
                monday = monday.adding(days: 7)
            }
        }
        return result
    }

    private static func bucketIndex(_ day: LocalDay, in buckets: [AnnalsReport.Bucket]) -> Int? {
        buckets.firstIndex { $0.start <= day && day <= $0.last }
    }

    // MARK: 其一 · 笔墨

    private static func writing(_ entries: [RecordEntry], period: AnnalsPeriod, input: RecordInput, recordStart: LocalDay?,
                                buckets: [AnnalsReport.Bucket]) -> AnnalsReport.Writing? {
        guard !entries.isEmpty else { return nil }
        var byKind: [JournalKind: Int] = [:]
        var perBucket = buckets.map { (bucket: $0, diary: 0, note: 0, review: 0) }
        var tagCount: [String: Int] = [:]
        var tagOrder: [String: Int] = [:]
        for entry in entries {
            byKind[entry.kind, default: 0] += 1
            if let index = bucketIndex(entry.day, in: buckets) {
                switch entry.kind {
                case .diary: perBucket[index].diary += 1
                case .note: perBucket[index].note += 1
                case .review: perBucket[index].review += 1
                }
            }
            var seen = Set<String>()
            for tag in entry.tags where seen.insert(tag).inserted {
                tagCount[tag, default: 0] += 1
                if tagOrder[tag] == nil { tagOrder[tag] = tagOrder.count }
            }
        }
        let tags = tagCount.sorted { ($1.value, tagOrder[$0.key] ?? 0) < ($0.value, tagOrder[$1.key] ?? 0) }
            .prefix(10).map { (tag: $0.key, count: $0.value) }
        let days = Set(entries.map(\.day))
        let spanFirst = max(period.first, recordStart ?? period.first)
        let span = spanFirst <= period.last ? spanFirst.days(to: period.last) + 1 : 0
        let run = RecordStats.longestRun(days, from: period.first, to: period.last).flatMap { $0.count >= 2 ? $0 : nil }
        let longest = entries.enumerated().max { ($0.element.chars, $1.offset) < ($1.element.chars, $0.offset) }?.element
        var previous: Int?
        if let recordStart, recordStart <= period.previousFirst.adding(days: 7) {
            previous = input.history.filter { $0.day >= period.previousFirst && $0.day <= period.previousLast && $0.day <= input.today }.count
        }
        return .init(entries: entries.count, byKind: byKind, chars: entries.reduce(0) { $0 + $1.chars }, writingDays: days.count,
                     spanDays: span, longestRun: run, longest: (longest?.chars ?? 0) > 0 ? longest : nil, perBucket: perBucket,
                     tags: Array(tags), previousEntries: previous)
    }

    // MARK: 其二 · 心境

    private static func mood(_ entries: [RecordEntry], period: AnnalsPeriod, buckets: [AnnalsReport.Bucket]) -> AnnalsReport.MoodPart? {
        let moods = entries.compactMap(\.mood)
        guard !moods.isEmpty else { return nil }
        var distribution = Array(repeating: 0, count: 6)
        for mood in moods { distribution[max(1, min(5, mood))] += 1 }
        // 按日期排好再累加：浮点加法与顺序有关，同样的输入每次得到同样的结果
        let byDay = RecordStats.moodByDay(entries).sorted { $0.key < $1.key }
        let points: [(day: LocalDay, value: Double)]
        switch period.scope {
        case .quarter:
            points = byDay.map { ($0.key, $0.value) }
        case .year:
            var weeks: [LocalDay: [Double]] = [:]
            for (day, value) in byDay { weeks[max(day.mondayOfWeek, period.first), default: []].append(value) }
            points = weeks.sorted { $0.key < $1.key }.map { ($0.key, $0.value.reduce(0, +) / Double($0.value.count)) }
        }
        // 最晴 / 最阴的月份：只比心境日 ≥ 5 天的月份
        var months: [LocalDay: [Double]] = [:]
        for (day, value) in byDay { months[day.firstOfMonth, default: []].append(value) }
        let eligible = months.filter { $0.value.count >= 5 }
            .map { (month: $0.key, value: $0.value.reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.month < $1.month }
        var brightest: (label: String, value: Double)?, dimmest: (label: String, value: Double)?
        if eligible.count >= 2, let high = eligible.max(by: { $0.value < $1.value }), let low = eligible.min(by: { $0.value < $1.value }),
           high.value - low.value >= 0.3 {
            brightest = ("\(high.month.month)月", high.value)
            dimmest = ("\(low.month.month)月", low.value)
        }
        return .init(points: points, distribution: distribution, average: Double(moods.reduce(0, +)) / Double(moods.count),
                     entries: moods.count, brightest: brightest, dimmest: dimmest)
    }

    // MARK: 其三 · 功课

    private static func habits(_ period: AnnalsPeriod, input: RecordInput, stats: [HabitStats], habitSources: [XPSource],
                               buckets: [AnnalsReport.Bucket]) -> AnnalsReport.HabitPart? {
        guard let overall = RecordStats.habitRate(input.habits, stats: stats, from: period.first, to: period.last) else { return nil }
        let comparable = zip(input.habits, stats).contains { habit, s in
            RecordStats.activeRange(habit, stats: s, from: period.previousFirst, to: period.previousLast)
                .map { $0.first.days(to: $0.last) + 1 >= 14 } ?? false
        }
        let previous = comparable
            ? RecordStats.habitRate(input.habits, stats: stats, from: period.previousFirst, to: period.previousLast)?.rate : nil
        let perfect = Set(habitSources.filter { $0.kind == "perfect" && $0.day >= period.first && $0.day <= period.last }.map(\.day))
        var rows: [AnnalsReport.HabitRow] = []
        for (habit, s) in zip(input.habits, stats) {
            guard let range = RecordStats.activeRange(habit, stats: s, from: period.first, to: period.last),
                  let rate = s.rate(from: range.first, to: range.last) else { continue }
            let achieved = s.logs.keys.filter { $0 >= range.first && $0 <= range.last && s.isAchieved($0) }.count
            rows.append(.init(title: habit.title, symbol: habit.symbol, schedule: habit.spec.scheduleSummary, rate: rate, achieved: achieved,
                              longest: RecordStats.longestStreak(s, from: range.first, to: range.last), archived: habit.archived))
        }
        rows = rows.enumerated().sorted { a, b in
            if a.element.archived != b.element.archived { return !a.element.archived }
            if a.element.rate != b.element.rate { return a.element.rate > b.element.rate }
            return a.offset < b.offset
        }.map(\.element)
        return .init(rate: overall.rate, previousRate: previous, perfectDays: perfect.count,
                     perBucket: buckets.map { ($0, RecordStats.habitRate(input.habits, stats: stats, from: $0.start, to: $0.last)?.rate) },
                     rows: rows)
    }

    // MARK: 其四 · 修为

    private static func cultivation(_ period: AnnalsPeriod, input: RecordInput, habitSources: [XPSource],
                                    buckets: [AnnalsReport.Bucket]) -> AnnalsReport.CultivationPart? {
        guard input.cultivation.enabled else { return nil }
        let config = input.cultivation.sanitized
        // 用现行设置把全部历史重算一遍（与侧栏境界卡同一算法）
        let sources = habitSources + CultivationEngine.journalSources(input.history, today: input.today)
        let perDay = CultivationEngine.compute(sources: sources, config: config, today: input.today).perDay
        let start = perDay.reduce(0) { $1.key < period.first ? $0 + $1.value : $0 }
        func realm(_ total: Int) -> Int { config.thresholds.lastIndex { total >= $0 } ?? 0 }
        var total = start
        var index = realm(total)
        var breakthroughs: [(day: LocalDay, realm: String, index: Int)] = []
        var perBucket = buckets.map { (bucket: $0, xp: 0) }
        for day in LocalDay.range(period.first, period.last) {
            guard let xp = perDay[day], xp > 0 else { continue }
            total += xp
            if let b = bucketIndex(day, in: buckets) { perBucket[b].xp += xp }
            let next = realm(total)
            if next > index {
                for i in (index + 1)...next { breakthroughs.append((day, config.realms[i], i)) }
                index = next
            }
        }
        return .init(gained: total - start, startXP: start, endXP: total, config: config, breakthroughs: breakthroughs, perBucket: perBucket)
    }

    // MARK: 其五 · 灵石

    private static func finance(_ period: AnnalsPeriod, ledger: FinanceLedger, today: LocalDay) -> AnnalsReport.FinancePart? {
        let firstKey = period.first.key, lastKey = period.last.key
        let inPeriod = ledger.transactions.filter { $0.date >= firstKey && $0.date <= lastKey }
        guard !inPeriod.isEmpty else { return nil }
        let manualOnly = ledger.sources.isEmpty
        var factsCache: [String: MonthFacts] = [:]
        func facts(_ month: LocalDay) -> MonthFacts {
            if let hit = factsCache[month.monthKey] { return hit }
            let made = FinanceEngine.monthFacts(ledger, month: month.monthKey)
            factsCache[month.monthKey] = made
            return made
        }
        func months(from start: LocalDay, count: Int) -> [LocalDay] {
            var result: [LocalDay] = []
            var month = start.firstOfMonth
            while result.count < count {
                result.append(month)
                month = AnnalsPeriod.monthEnd(month).adding(days: 1)
            }
            return result
        }
        let periodMonths = months(from: period.first, count: (period.last.year - period.first.year) * 12 + period.last.month - period.first.month + 1)
        // 账簿最早一笔（交易或导入范围）之前的月份不列：那时还没开始记账，不算“未导全”
        let ledgerStart = (ledger.transactions.map { String($0.date.prefix(7)) } + ledger.sources.compactMap { $0.range.map { String($0.0.prefix(7)) } })
            .filter { $0.count == 7 }.min() ?? period.first.monthKey
        let shown = periodMonths.filter { $0.monthKey >= ledgerStart }
        var net = 0, spend = 0, refund = 0
        var categoryTotals: [String: Int] = [:]
        var rows: [(month: String, label: String, netCents: Int, full: Bool, ongoing: Bool)] = []
        for month in shown {
            let f = facts(month)
            net += f.netSpendCents
            spend += f.spendCents
            refund += f.refundCents
            for (name, cents) in f.categories { categoryTotals[name, default: 0] += cents }
            let ongoing = month.monthKey == today.monthKey
            // 本月还没过完，导入范围不可能覆盖到月底：按“至今”看，导到最近几天就算全（不挂“未导全”、柱子不变淡）
            let full = ongoing ? !manualOnly && coveredSoFar(ledger, today: today) : f.fullMonth
            rows.append((month.monthKey, "\(month.month)月" + (ongoing ? "（至今）" : ""), f.netSpendCents, full, ongoing))
        }
        // 比较：第 i 个月对对比期第 i 个月，只取两边都整月导全且都已过完的配对
        var pairs: [(current: MonthFacts, previous: MonthFacts)] = []
        if !manualOnly {
            for (current, previous) in zip(periodMonths, months(from: period.previousFirst, count: periodMonths.count))
            where AnnalsPeriod.monthEnd(current) < today && AnnalsPeriod.monthEnd(previous) < today {
                let c = facts(current), p = facts(previous)
                if c.fullMonth && p.fullMonth { pairs.append((c, p)) }
            }
        }
        let sorted = categoryTotals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let categories = sorted.prefix(6).map { name, cents -> (name: String, cents: Int, change: Int?) in
            let change = pairs.isEmpty ? nil : pairs.reduce(0) { $0 + ($1.current.categories[name] ?? 0) - ($1.previous.categories[name] ?? 0) }
            return (name, cents, change)
        }
        let comparison: (months: Int, previousNetCents: Int, currentNetCents: Int)? = pairs.isEmpty ? nil
            : (pairs.count, pairs.reduce(0) { $0 + $1.previous.netSpendCents }, pairs.reduce(0) { $0 + $1.current.netSpendCents })
        return .init(netCents: net, spendCents: spend, refundCents: refund, months: rows, categories: Array(categories),
                     otherCategories: max(0, sorted.count - 6), comparison: comparison,
                     incompleteMonths: manualOnly ? [] : zip(shown, rows).filter { !$0.1.full }.map { "\($0.0.month)月" },
                     pendingReview: inPeriod.filter(\.awaitingReview).count, manualOnly: manualOnly)
    }

    /// 本月按“至今”可以晚几天：银行导出常晚一两天入账，周末再晚一天
    static let ongoingLagDays = 3

    /// 本月（还没过完）到今天为止算不算导全：导入范围从月初覆盖到 ongoingLagDays 天前（导到昨天当然也算）。
    /// 账户口径同 monthFacts（到那天为止导入过的账户都要覆盖到）。
    /// 月初头几天（ongoingLagDays 天前还在上个月）本月还没有该覆盖的日子：改看各账户是否已导到那一天，
    /// 早已停导的账簿不算本月导全（与“导入范围已到最近 3 天内”的说法一致）。
    /// 只给长卷与逐月趋势用；灵石账簿自己的“未导全”小标仍按整月判断，这里不改
    static func coveredSoFar(_ ledger: FinanceLedger, today: LocalDay) -> Bool {
        let through = today.adding(days: -ongoingLagDays)
        let from = min(today.firstOfMonth, through)
        let accounts = FinanceEngine.coveredAccounts(ledger.sources, through: through.key)
        return !accounts.isEmpty && accounts.allSatisfy { account in
            FinanceEngine.covers(ledger.sources.filter { $0.account == account }.compactMap(\.range), from.key, through.key)
        }
    }
}
