import Foundation

/// AI 优化用的结构化摘要。纯值类型：既能渲染成 Markdown 给人 / AI 看，也能编码成 JSON。
struct PlannerSummary: Codable {
    struct Goal: Codable { var title: String; var category: String; var status: String; var progress: Int; var targetDate: String? }
    /// rule 里已带起止说明（“，至 11月2日”“（自 11月3日 起）”）
    struct RecurringEvent: Codable { var title: String; var category: String; var time: String; var rule: String; var location: String }
    struct Occurrence: Codable { var date: String; var weekday: String; var time: String; var title: String; var category: String }
    struct RoutineBlock: Codable { var weekdays: String; var time: String; var title: String; var kind: String }
    struct Habit: Codable {
        var title: String; var schedule: String; var completion7d: Int?; var completion30d: Int?
        var streak: String; var weeklyTrend: [Int?]; var archived: Bool
        /// 最近几天每天的状态（旧→新，与 PlannerSummary.habitDays 一一对应）：✓ 达标 · ◐ 有记录未达标 · ✗ 漏打 · ○ 今天还没打 · – 当天不用打
        var recent: [String] = []
    }
    struct Cultivation: Codable { var realm: String; var totalXP: Int; var toNextRealm: Int?; var nextRealm: String? }
    struct TimeBudget: Codable { var category: String; var hoursPerWeek: Double }
    struct Finance: Codable {
        var month: String; var fullMonth: Bool; var spend: String; var refund: String; var netSpend: String; var otherDebits: String
        var topCategories: [String]; var changeVsPreviousMonth: String?; var budgets: [String]; var pendingReview: Int
    }
    /// 本月至今的消费：银行流水通常月底才导入，所以单独标出导入覆盖到哪天，并逐笔列出手记（含飞剑传书代记）
    struct FinanceToDate: Codable {
        var month: String; var through: String
        var spend: String; var refund: String; var netSpend: String
        var topCategories: [String]
        /// 银行流水导入覆盖到哪一天；nil 表示还没导入过任何账单
        var bankThrough: String?
        var manualCount: Int; var manualTotal: String
        /// 本月手记逐笔（最多 30 笔，新→旧）
        var manual: [String]
        var pendingReview: Int
    }
    struct JournalItem: Codable {
        var date: String; var weekday: String; var time: String?; var kind: String; var title: String; var body: String
        var mood: String?; var period: String?; var tags: [String]; var source: String?
    }
    /// 近 12 个月逐月趋势的一行（TrendDigest.months 生成，口径见 RecordStats）
    struct MonthTrend: Codable, Equatable {
        /// “2026-10”
        var month: String
        /// 本月还没过完
        var ongoing: Bool
        /// 落笔篇数
        var entries: Int
        var writingDays: Int
        /// 带心境篇目的按篇平均（一位小数）；没有为 nil
        var averageMood: Double?
        /// 综合功课完成率 %（RecordStats.habitRate）
        var habitRate: Int?
        /// “$1,203”；没有账簿、或这个月账簿里没有数据为 nil
        var netSpend: String?
        /// monthFacts.fullMonth（银行账单整月导全）
        var spendComplete: Bool
    }
    /// “长期趋势与洞察”一段（SummarySection.trends，由 AIDigest.attach 填入；读写都经下面同名的四个属性）。
    /// 没带这一段时为 nil：编码 JSON 时整个键都不出现，问道灵枢不勾这一段时 Markdown 与 JSON 都与原来逐字相同
    struct LongTerm: Codable, Equatable {
        var trends: [MonthTrend] = []
        /// 账簿只有手记（从没导入银行账单）：表头说明改写，不逐月标“未导全”
        var trendsManualOnly = false
        /// 每条已拼好“正文（依据）”
        var insights: [String] = []
        var insightWindowDays = 0
    }

    var generatedAt: String
    /// 修行录回看天数（与 journalDays 相同，保留旧字段名）
    var periodDays: Int
    var today: String
    var profile: [String: String]
    var goals: [Goal]
    var recurringEvents: [RecurringEvent]
    var upcoming: [Occurrence]
    /// 各类别日程的每周平均小时数（按未来 hoursWindowDays 天的安排折算）
    var scheduleHoursByCategory: [TimeBudget]
    var routine: [RoutineBlock]
    var routineHoursByKind: [TimeBudget]
    var habits: [Habit]
    var cultivation: Cultivation?
    var finance: Finance? = nil
    var journal: [JournalItem] = []
    var journalDays: Int = 30
    var focusQuestion: String
    // 以下字段都带默认值：只按旧字段做成员初始化的代码（例如 Tools/CoreCheck）不受影响
    /// upcoming 覆盖的天数（含今天）
    var upcomingDays: Int = 7
    /// 折算日程每周时长用的窗口天数
    var hoursWindowDays: Int = 28
    /// 过去几天已经发生的日程（不含今天）与逐日打卡的天数；0 表示不带
    var pastDays: Int = 0
    var past: [Occurrence] = []
    /// 逐日打卡的日期表头（旧→新），例如“10-08 三”
    var habitDays: [String] = []
    var financeToDate: FinanceToDate? = nil
    var journalNewestFirst: Bool = false
    /// 因篇幅省略的更早修行录条数
    var journalOmitted: Int = 0
    /// 放在最前面的概览（快照用：修为、最近的传书等），每行已带列表符号
    var overview: [String] = []
    /// 日程前后缓冲（作息页的设置，分钟）；都为 0 时不写
    var bufferBeforeMinutes: Int = 0
    var bufferAfterMinutes: Int = 0
    var longTerm: LongTerm? = nil
}

/// “长期趋势与洞察”的四个字段：存在 longTerm 里，第一次写入时才建（见 PlannerSummary.LongTerm）
extension PlannerSummary {
    var trends: [MonthTrend] {
        get { longTerm?.trends ?? [] }
        set { editLongTerm { $0.trends = newValue } }
    }
    var trendsManualOnly: Bool {
        get { longTerm?.trendsManualOnly ?? false }
        set { editLongTerm { $0.trendsManualOnly = newValue } }
    }
    var insights: [String] {
        get { longTerm?.insights ?? [] }
        set { editLongTerm { $0.insights = newValue } }
    }
    var insightWindowDays: Int {
        get { longTerm?.insightWindowDays ?? 0 }
        set { editLongTerm { $0.insightWindowDays = newValue } }
    }

    private mutating func editLongTerm(_ edit: (inout LongTerm) -> Void) {
        var block = longTerm ?? LongTerm()
        edit(&block)
        longTerm = block
    }
}

/// 日程时长：把一段时间内各次日程的时长按类别累加，再折成“每周平均”小时数（双周一次的日程也能算准）。
enum ScheduleHours {
    static func weeklyAverage(_ items: [(category: String, start: Int?, end: Int?)], days: Int) -> [PlannerSummary.TimeBudget] {
        guard days > 0 else { return [] }
        var hours: [String: Double] = [:]
        for item in items {
            guard let s = item.start, let e = item.end, e > s else { continue }
            hours[item.category.isEmpty ? "未分类" : item.category, default: 0] += Double(e - s) / 60
        }
        return hours.map { .init(category: $0.key, hoursPerWeek: $0.value * 7 / Double(days)) }
            .sorted { $0.hoursPerWeek != $1.hoursPerWeek ? $0.hoursPerWeek > $1.hoursPerWeek : $0.category < $1.category }
    }
}

enum SummarySection: String, CaseIterable, Identifiable, Codable {
    case profile, goals, schedule, routine, habits, finance, journal, cultivation, trends
    var id: String { rawValue }
    var label: String {
        switch self {
        case .profile: "个人档案"
        case .goals: "目标"
        case .schedule: "日程"
        case .routine: "固定作息"
        case .habits: "习惯"
        case .finance: "消费概况"
        case .journal: "修行录"
        case .cultivation: "修为进度"
        case .trends: "长期趋势与洞察"
        }
    }
}

enum SummaryRenderer {
    static let defaultPreamble = """
    你是一位务实的个人效率顾问。下面是我的个人档案、目标、日程、固定作息、习惯与修行录数据（由我的个人工具 APT 自动整理）。
    请基于这些事实，给出具体、可执行的调整建议：
    1. 时间安排：哪些时段过满或有冲突，固定作息是否合理；
    2. 习惯：哪些习惯需要降低难度、调整频率或换时间段；
    3. 目标对齐：当前日程与习惯是否服务于我的目标，缺了什么；
    4. 修行录：从日记、灵感与复盘里看出的模式（心境、精力、反复出现的问题）；
    5. 下周最值得做的三件调整，每条附上理由。
    请只根据数据推断，不确定的地方直接说明；用中文回答。
    """

    /// digest：快照开头的「近况速览」（SnapshotDigest.lines，每行已带列表符号），空时不写这一节；
    /// overviewTitle：概览一节的标题（快照写“传书近况”）；multilineProfile：多行档案字段逐行缩进列出（只给快照用）。
    /// 三个参数都带默认值，问道灵枢照旧调用、输出一字不变；它们是渲染参数而不是 PlannerSummary 的字段，导出的 JSON 也不变
    static func markdown(_ s: PlannerSummary, preamble: String, digest: [String] = [], overviewTitle: String = "概览",
                         multilineProfile: Bool = false) -> String {
        var out: [String] = []
        if !preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(preamble.trimmingCharacters(in: .whitespacesAndNewlines))
            out.append("")
            out.append("---")
            out.append("")
        }
        out.append("# APT 个人状态摘要")
        let weekday = LocalDay(key: s.today).map { " " + $0.weekdayName } ?? ""
        out.append("生成时间：\(s.generatedAt)　｜　今天：\(s.today)\(weekday)　｜　修行录：最近 \(s.periodDays) 天")
        if !s.focusQuestion.isEmpty {
            out.append("")
            out.append("**我这次最想解决的问题：** \(s.focusQuestion)")
        }
        if !digest.isEmpty {
            out.append("")
            out.append("## 近况速览")
            out.append(contentsOf: digest)
        }
        if !s.overview.isEmpty {
            out.append("")
            out.append("## \(overviewTitle)")
            out.append(contentsOf: s.overview)
        }
        out.append(contentsOf: TrendDigest.markdownLines(s))
        if !s.profile.isEmpty {
            out.append("")
            out.append("## 个人档案")
            for section in ProfileCatalog.sections {
                let lines = section.fields.flatMap { field -> [String] in
                    guard let value = s.profile[field.key], !value.isEmpty else { return [] }
                    // 快照里多行字段保留换行：AI 改写时照原样分行（问道灵枢仍用“；”连成一行）
                    if multilineProfile, field.multiline, value.contains(where: \.isNewline) {
                        let rows = value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        return ["- \(field.label)："] + rows.map { "  " + $0 }
                    }
                    return ["- \(field.label)：\(value.replacingOccurrences(of: "\n", with: "；"))"]
                }
                if !lines.isEmpty {
                    out.append("### \(section.title)")
                    out.append(contentsOf: lines)
                }
            }
        }
        if !s.goals.isEmpty {
            out.append("")
            out.append("## 目标")
            for g in s.goals {
                var line = "- \(g.title)（\(g.status)，进度 \(g.progress)%"
                if let d = g.targetDate { line += "，期限 \(d)" }
                if !g.category.isEmpty { line += "，类别 \(g.category)" }
                out.append(line + "）")
            }
        }
        let hasBuffer = s.bufferBeforeMinutes > 0 || s.bufferAfterMinutes > 0
        if !s.recurringEvents.isEmpty || !s.upcoming.isEmpty || !s.past.isEmpty || hasBuffer {
            out.append("")
            out.append("## 日程")
            if hasBuffer {
                out.append("- 日程前后缓冲：开始前 \(s.bufferBeforeMinutes) 分钟、结束后 \(s.bufferAfterMinutes) 分钟（安排相邻日程时请留出）")
            }
            if !s.recurringEvents.isEmpty {
                out.append("### 重复日程（时间｜重复规则）")
                for e in s.recurringEvents {
                    var line = "- \(e.title)：\(e.time)｜\(e.rule)"
                    if !e.category.isEmpty { line += "［\(e.category)］" }
                    if !e.location.isEmpty { line += " @\(e.location)" }
                    out.append(line)
                }
            }
            if !s.scheduleHoursByCategory.isEmpty {
                let weeks = s.hoursWindowDays % 7 == 0 ? "\(s.hoursWindowDays / 7) 周" : "\(s.hoursWindowDays) 天"
                out.append("### 日程时长（每周平均，按未来 \(weeks)的安排折算，按类别）")
                for b in s.scheduleHoursByCategory { out.append("- \(b.category)：每周约 \(format(b.hoursPerWeek)) 小时") }
            }
            if !s.past.isEmpty {
                out.append("### 过去 \(s.pastDays) 天的安排（已经过去）")
                for o in s.past { out.append(occurrenceLine(o)) }
            }
            if !s.upcoming.isEmpty {
                out.append("### 未来 \(s.upcomingDays) 天安排（含今天）")
                for o in s.upcoming { out.append(occurrenceLine(o)) }
            }
        }
        if !s.routine.isEmpty {
            out.append("")
            out.append("## 固定作息")
            for r in s.routine { out.append("- \(r.weekdays) \(r.time) \(r.title)（\(r.kind)）") }
            if !s.routineHoursByKind.isEmpty {
                out.append("每周合计：" + s.routineHoursByKind.map { "\($0.category) \(format($0.hoursPerWeek)) 小时" }.joined(separator: "，"))
            }
        }
        if !s.habits.isEmpty {
            out.append("")
            out.append("## 习惯")
            out.append("| 习惯 | 频率 | 近 7 天 | 近 30 天 | 当前连续 | 近 8 周趋势 |")
            out.append("|---|---|---|---|---|---|")
            for h in s.habits {
                let trend = h.weeklyTrend.map { $0.map { "\($0)%" } ?? "–" }.joined(separator: " → ")
                out.append("| \(h.title)\(h.archived ? "（已归档）" : "") | \(h.schedule) | \(percent(h.completion7d)) | \(percent(h.completion30d)) | \(h.streak) | \(trend) |")
            }
            if !s.habitDays.isEmpty, s.habits.contains(where: { $0.recent.count == s.habitDays.count }) {
                out.append("")
                out.append("### 近 \(s.habitDays.count) 天逐日打卡（✓ 达标 · ◐ 有记录未达标 · ✗ 漏打 · ○ 今天还没打 · – 当天不用打）")
                out.append("| 习惯 | " + s.habitDays.joined(separator: " | ") + " |")
                out.append("|---|" + String(repeating: "---|", count: s.habitDays.count))
                for h in s.habits where h.recent.count == s.habitDays.count {
                    out.append("| \(h.title) | " + h.recent.joined(separator: " | ") + " |")
                }
            }
        }
        if let f = s.finance {
            out.append("")
            out.append("## 消费概况（\(f.month)\(f.fullMonth ? "，最近一个完整月" : "，部分月份")）")
            out.append("- 消费扣款 \(f.spend)，退款 \(f.refund)，净消费 \(f.netSpend)；转账 / 投资等其他扣款 \(f.otherDebits)（不计入消费）")
            if let change = f.changeVsPreviousMonth { out.append("- 与上月相比：\(change)") }
            if !f.topCategories.isEmpty { out.append("- 主要类别：" + f.topCategories.joined(separator: "，")) }
            if !f.budgets.isEmpty { out.append("- 预算：" + f.budgets.joined(separator: "，")) }
            if f.pendingReview > 0 { out.append("- 另有 \(f.pendingReview) 笔交易尚未确认用途，结论可能有偏差") }
        }
        if let m = s.financeToDate {
            out.append("")
            out.append("## 本月至今的消费（\(m.month)，截至 \(m.through)）")
            if let bank = m.bankThrough, bank >= m.through {
                out.append("- 银行流水已导入到 \(bank)")
            } else {
                let bank = m.bankThrough.map { "银行流水只导入到 \($0)" } ?? "还没有导入过银行流水"
                out.append("- \(bank)：之后的刷卡消费要等用户导入 CommBank 账单后才会出现，下面的合计**不完整**，不要据此判断消费变少了")
            }
            out.append("- 消费扣款 \(m.spend)，退款 \(m.refund)，净消费 \(m.netSpend)")
            if !m.topCategories.isEmpty { out.append("- 主要类别：" + m.topCategories.joined(separator: "，")) }
            if m.manualCount > 0 {
                out.append("- 手记 \(m.manualCount) 笔（含飞剑传书代记），共 \(m.manualTotal)" + (m.manual.count < m.manualCount ? "，最近 \(m.manual.count) 笔：" : "："))
                out.append(contentsOf: m.manual.map { "  - " + $0 })
            }
            if m.pendingReview > 0 { out.append("- 另有 \(m.pendingReview) 笔交易尚未确认用途") }
        }
        if !s.journal.isEmpty {
            out.append("")
            out.append("## 修行录（最近 \(s.journalDays) 天的日记、灵感与复盘，共 \(s.journal.count) 条\(s.journalNewestFirst ? "，从新到旧" : "")）")
            for j in s.journal {
                var head = "### \(j.date) \(j.weekday)"
                if let t = j.time { head += " \(t)" }
                head += " · \(j.kind)"
                if let p = j.period, !p.isEmpty { head += "（\(p)）" }
                if let m = j.mood, !m.isEmpty { head += " · 心境「\(m)」" }
                if !j.title.isEmpty { head += " · \(j.title)" }
                out.append(head)
                if !j.body.isEmpty { out.append(wrapped(j.body)) }
                var meta: [String] = []
                if !j.tags.isEmpty { meta.append("标签：" + j.tags.joined(separator: "、")) }
                if let source = j.source { meta.append("由 \(source) 代记") }
                if !meta.isEmpty { out.append("（" + meta.joined(separator: "；") + "）") }
            }
            if s.journalOmitted > 0 {
                out.append("")
                out.append("（另有更早的 \(s.journalOmitted) 条因篇幅未列出，可在应用的修行录里查看）")
            }
        }
        if let c = s.cultivation {
            out.append("")
            out.append("## 修为进度")
            var line = "当前境界：\(c.realm)，累计修为 \(c.totalXP)"
            if let next = c.nextRealm, let gap = c.toNextRealm { line += "，距「\(next)」还差 \(gap)" }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    private static func occurrenceLine(_ o: PlannerSummary.Occurrence) -> String {
        "- \(o.date) \(o.weekday) \(o.time) \(o.title)" + (o.category.isEmpty ? "" : "［\(o.category)］")
    }

    /// 没有换行的超长段落按句子断开：AI 读文件时，太长的一行可能被截断
    static func wrapped(_ text: String, width: Int = 800) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            guard line.count > width * 3 / 2 else { return line }
            var pieces: [String] = []
            var current = ""
            for ch in line {
                current.append(ch)
                if current.count >= width, "。！？!?；;".contains(ch) || current.count >= width * 3 / 2 {
                    pieces.append(current)
                    current = ""
                }
            }
            if !current.isEmpty { pieces.append(current) }
            return pieces.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    static func json(_ s: PlannerSummary) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // 万一某个数字是无穷大 / NaN（例如以前存进去的异常目标值），JSONEncoder 会直接抛错、整份摘要变成 {}：
        // 先写成占位字符串，再换成 null
        let marker = "APT-NONFINITE-NUMBER"
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: marker, negativeInfinity: marker, nan: marker)
        guard let data = try? encoder.encode(s) else { return "{}" }
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"\(marker)\"", with: "null")
    }

    private static func percent(_ value: Int?) -> String { value.map { "\($0)%" } ?? "–" }
    private static func format(_ hours: Double) -> String { String(format: hours.rounded() == hours ? "%.0f" : "%.1f", hours) }
}
