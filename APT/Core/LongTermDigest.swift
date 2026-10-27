import Foundation

// “长期摘要”：近 12 个月逐月趋势 + 近 90 天洞见（纯逻辑）。三处共用同一份：
// 修行录左栏「卷中洞见」卡（取前 3 条）、问道灵枢摘要“长期趋势与洞察”、snapshot.md。
// 取数（只取元数据，不取正文）与按“数据戳 + 今天”的缓存在 Services/AIDigest；这里只算、只填。

struct LongTermDigest: Equatable {
    /// 近 12 个月逐月（旧 → 新，早于第一条记录的月份不列）
    var trends: [PlannerSummary.MonthTrend]
    /// 账簿只有手记、从没导入过银行账单：逐月表不标“未导全”
    var manualOnly: Bool
    /// 近 90 天 [今天−90, 今天−1] 过了门槛的洞见，顺序固定（Insight.Kind.allCases 的顺序：先报喜，常歇的功课最后）；
    /// 连续落笔另把今天已写的也算上（与卷中气象的“连续落笔”同一个数）
    var insights: [Insight]

    static let months = 12
    static let windowDays = 90
    /// 修行录卡片最多显示几条
    static let cardLimit = 3

    static let empty = LongTermDigest(trends: [], manualOnly: false, insights: [])

    /// 取数窗口的起点：本月往前 11 个月的 1 日（逐月表要整月；洞见的 90 天也在里面）
    static func fetchStart(today: LocalDay) -> LocalDay {
        var month = today.firstOfMonth
        for _ in 1..<months { month = month.adding(days: -1).firstOfMonth }
        return month
    }

    /// 洞见窗口：近 90 天，止于昨天（今天还没过完）
    static func insightWindow(today: LocalDay) -> (from: LocalDay, to: LocalDay) {
        (today.adding(days: -windowDays), today.adding(days: -1))
    }

    /// input 只需覆盖 fetchStart … 今天的元数据（心境、类型、日期；不读正文、档案、标签，所以不会带出姓名）
    static func make(_ input: RecordInput, today: LocalDay) -> LongTermDigest {
        let window = insightWindow(today: today)
        // 止日传今天：其余几类在 InsightEngine 里仍截到昨天，只有连续落笔把今天已写的也算上
        return LongTermDigest(trends: TrendDigest.months(input, endingAt: today, count: months),
                              manualOnly: TrendDigest.manualOnly(input),
                              insights: InsightEngine.insights(input, from: window.from, to: today))
    }

    var isEmpty: Bool { trends.isEmpty && insights.isEmpty }

    /// 卡片上显示的几条（顺序同 insights：有报喜的，第一条就是报喜的）
    var cardInsights: [Insight] { Array(insights.prefix(Self.cardLimit)) }

    /// 填进摘要的“长期趋势与洞察”：洞见写成“正文（依据）”。两段都空时不动摘要——
    /// JSON 里不多出一个空的 longTerm，Markdown 也不出这两个标题
    func attach(to summary: inout PlannerSummary) {
        guard !isEmpty else { return }
        summary.trends = trends
        summary.trendsManualOnly = manualOnly
        summary.insights = insights.map(\.line)
        summary.insightWindowDays = Self.windowDays
    }

    // MARK: 卡片上“新浮现”的几条

    /// 记下已经给用户看过的几条：每条“类型 + 正文”一行（存进偏好设置，跨重启也认得）
    static func seenToken(_ shown: [Insight]) -> String {
        shown.map { $0.kind.rawValue + "\t" + $0.text }.joined(separator: "\n")
    }

    /// 和上次看过的相比，新出现或文字变了的几条（卡片上淡入并在图标处一闪金星）；看过的原样不闪
    static func freshKinds(seen token: String, shown: [Insight]) -> Set<Insight.Kind> {
        let seen = Set(token.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        return Set(shown.filter { !seen.contains($0.kind.rawValue + "\t" + $0.text) }.map(\.kind))
    }
}
