import Foundation

// 问道灵枢摘要（与 snapshot.md）里的“长期趋势与洞察”：近 12 个月逐月表 + 近 90 天的统计洞察（纯逻辑）。
// 取数与缓存在 AIDigest（Services）；这里只算逐月表、渲染 Markdown。

enum TrendDigest {
    /// 截至今天的近 count 个自然月（含本月，旧 → 新）；早于第一条记录的月份不列，一条记录都没有时为空。
    /// input 的 entries 要覆盖这几个月（只用心境，不读正文）；落笔篇数从 history 数。
    static func months(_ input: RecordInput, endingAt today: LocalDay, count: Int = 12) -> [PlannerSummary.MonthTrend] {
        guard count > 0, let start = RecordStats.recordStart(input) else { return [] }
        var months: [LocalDay] = [today.firstOfMonth]
        while months.count < count { months.insert(months[0].adding(days: -1).firstOfMonth, at: 0) }
        months = months.filter { $0 >= start.firstOfMonth }
        guard let firstMonth = months.first else { return [] }

        var written: [String: (entries: Int, days: Set<LocalDay>)] = [:]
        for item in input.history where item.day >= firstMonth && item.day <= today {
            written[item.day.monthKey, default: (0, [])].entries += 1
            written[item.day.monthKey, default: (0, [])].days.insert(item.day)
        }
        var moods: [String: (total: Int, count: Int)] = [:]
        for entry in input.entries where entry.day >= firstMonth && entry.day <= today {
            guard let mood = entry.mood else { continue }
            moods[entry.day.monthKey, default: (0, 0)].total += mood
            moods[entry.day.monthKey, default: (0, 0)].count += 1
        }
        let stats = input.habitStats()
        let ledgerMonths = Set(input.ledger?.transactions.map(\.month) ?? [])

        return months.map { month in
            let key = month.monthKey
            let last = min(AnnalsPeriod.monthEnd(month), today)
            let mood = moods[key].map { (Double($0.total) / Double($0.count) * 10).rounded() / 10 }
            let rate = RecordStats.habitRate(input.habits, stats: stats, from: month, to: last).map { Int(($0.rate * 100).rounded()) }
            var netSpend: String?
            var complete = false
            if let ledger = input.ledger {
                let facts = FinanceEngine.monthFacts(ledger, month: key)
                // 进行中的本月按“至今”判断（与岁月长卷同一口径，见 AnnalsEngine.coveredSoFar）：导到最近几天就不标“未导全”
                complete = facts.fullMonth || (key == today.monthKey && AnnalsEngine.coveredSoFar(ledger, today: today))
                // 这个月账簿里一笔都没有、也没导全：写“–”，不写成“$0（未导全）”
                if complete || ledgerMonths.contains(key) { netSpend = RecordStats.dollars(facts.netSpendCents) }
            }
            return .init(month: key, ongoing: key == today.monthKey, entries: written[key]?.entries ?? 0,
                         writingDays: written[key]?.days.count ?? 0, averageMood: mood, habitRate: rate,
                         netSpend: netSpend, spendComplete: complete)
        }
    }

    /// 账簿只有手记、从没导入过银行账单：逐月表不标“未导全”，表头说明改写
    static func manualOnly(_ input: RecordInput) -> Bool {
        guard let ledger = input.ledger else { return false }
        return ledger.sources.isEmpty && !ledger.transactions.isEmpty
    }

    /// 摘要里“概览”之后、“个人档案”之前的两段；trends 与 insights 都空时返回 []
    static func markdownLines(_ s: PlannerSummary) -> [String] {
        guard !s.trends.isEmpty || !s.insights.isEmpty else { return [] }
        var out: [String] = []
        if !s.trends.isEmpty {
            out.append("")
            out.append("## 近 \(s.trends.count) 个月逐月趋势")
            if !s.trends.contains(where: { $0.netSpend != nil }) {
                out.append("（心境 1 雨 … 5 霁）")
            } else if s.trendsManualOnly {
                out.append("（心境 1 雨 … 5 霁；账目只含手记，未导入银行账单，净消费只是手记合计）")
            } else {
                out.append("（心境 1 雨 … 5 霁；净消费标“未导全”的月份银行账单不完整、偏低）")
            }
            out.append("| 月份 | 落笔 / 动笔天数 | 平均心境 | 功课完成率 | 净消费 |")
            out.append("|---|---|---|---|---|")
            let through = LocalDay(key: s.today).map { "（至 \($0.day) 日）" } ?? "（至今）"
            for t in s.trends {
                let mood = t.averageMood.map { RecordStats.decimal($0) } ?? "–"
                let rate = t.habitRate.map { "\($0)%" } ?? "–"
                let spend = t.netSpend.map { $0 + (t.spendComplete || s.trendsManualOnly ? "" : "（未导全）") } ?? "–"
                out.append("| \(t.month)\(t.ongoing ? through : "") | \(t.entries) / \(t.writingDays) | \(mood) | \(rate) | \(spend) |")
            }
        }
        if !s.insights.isEmpty {
            out.append("")
            out.append("## 统计洞察（近 \(s.insightWindowDays > 0 ? s.insightWindowDays : 90) 天；纯统计相关，不代表因果；样本不够的不列）")
            out.append(contentsOf: s.insights.map { "- " + $0 })
        }
        return out
    }
}
