import Foundation

// 岁月长卷导出成 Markdown（给 AI / 存档）：卷首 → 一行数字 → 只写有数据的各节（节号按实际出现的重排）→ 落款。
// 附录“珍藏与长篇全文”由页面接在后面（JournalExport.markdown），不在这里。

enum AnnalsRenderer {
    static func markdown(_ r: AnnalsReport) -> String {
        let p = r.period
        var out: [String] = []
        out.append("# \(p.title) · 岁月长卷")
        out.append(p.rangeLabel + (r.startsLate ? " · 记录始于 \(r.recordStart.map(longDate) ?? "")" : ""))
        let figures = headline(r)
        if !r.isEmpty, !figures.isEmpty {
            out.append("")
            out.append("> " + figures.joined(separator: " · "))
        }
        if r.isEmpty {
            out.append("")
            out.append("这段时间没有记录。")
        } else {
            var number = 0
            func section(_ title: String, _ lines: [String]) {
                guard !lines.isEmpty else { return }
                number += 1
                out.append("")
                out.append("## 其\(ChineseNumerals.ordinal(number)) · \(title)")
                out.append(contentsOf: lines)
            }
            section("笔墨", r.writing.map { writing($0, period: p) } ?? [])
            section("心境", r.mood.map(mood) ?? [])
            section("功课", r.habits.map { habits($0, period: p) } ?? [])
            section("修为", r.cultivation.map { cultivation($0, period: p) } ?? [])
            section("灵石", r.finance.map { finance($0, period: p) } ?? [])
            section("珍藏与长篇", highlights(r.highlights, today: r.today))
            if !r.insights.isEmpty {
                section("洞见", ["（只做统计，不代表因果；样本不够的不列。）", ""] + r.insights.map { "- \($0.text)（\($0.basis)）" })
            }
        }
        out.append("")
        out.append("---")
        out.append("")
        out.append("辑于 \(longDate(r.today)) · 云山修习录")
        return out.joined(separator: "\n") + "\n"
    }

    /// 卷首一行：“落笔 612 篇 · 约 18.4 万字 · 功课完成率 73% · 修为 +12,480 · 净消费 $9,820”（没有的项不写）
    static func headline(_ r: AnnalsReport) -> [String] {
        var parts: [String] = []
        if let w = r.writing {
            parts.append("落笔 \(RecordStats.grouped(w.entries)) 篇")
            if w.chars > 0 { parts.append("约 " + RecordStats.charsText(w.chars)) }
        }
        if let h = r.habits { parts.append("功课完成率 \(RecordStats.percent(h.rate))") }
        if let c = r.cultivation { parts.append("修为 +\(RecordStats.grouped(c.gained))") }
        if let f = r.finance { parts.append("净消费 \(RecordStats.dollars(f.netCents))" + (f.manualOnly ? "（仅手记）" : "")) }
        return parts
    }

    // MARK: 各节

    private static func writing(_ w: AnnalsReport.Writing, period: AnnalsPeriod) -> [String] {
        var lines: [String] = []
        let kinds = JournalKind.allCases.compactMap { kind in w.byKind[kind].map { "\(kind.label) \($0)" } }
        var first = "- 落笔 \(RecordStats.grouped(w.entries)) 篇（\(kinds.joined(separator: "、"))）"
        if let previous = w.previousEntries, let compare = AnnalsReport.compareText(w.entries, from: previous, label: period.previousLabel) {
            first += "，" + compare
        }
        lines.append(first)
        lines.append("- 动笔 \(w.writingDays) 天（占 \(RecordStats.percent(w.writingShare))）")
        if let run = w.longestRun {
            lines.append("- 最长连续 \(run.count) 天 · \(run.first.shortLabel)—\(run.last.shortLabel)")
        }
        if w.chars > 0 {
            var line = "- 日均 \(RecordStats.grouped(w.averageChars)) 字"
            if let longest = w.longest {
                line += " · 最长一篇 \(RecordStats.grouped(longest.chars)) 字（\(longest.day.shortLabel)「\(longest.displayTitle)」）"
            }
            lines.append(line)
        }
        if !w.tags.isEmpty {
            lines.append("- 常用标签：" + w.tags.map { "#\($0.tag) \($0.count)" }.joined(separator: "、"))
        }
        let buckets = w.perBucket.filter { $0.diary + $0.note + $0.review > 0 }
        if !buckets.isEmpty {
            lines.append("")
            lines.append("| \(unitName(period)) | 日记 | 灵感 | 复盘 |")
            lines.append("|---|---|---|---|")
            for b in buckets { lines.append("| \(bucketName(b.bucket, period: period)) | \(b.diary) | \(b.note) | \(b.review) |") }
        }
        return lines
    }

    private static func mood(_ m: AnnalsReport.MoodPart) -> [String] {
        var lines = ["- 平均 \(RecordStats.decimal(m.average))，多在「\(Mood.label(m.dominant))」（\(m.entries) 篇带心境）"]
        lines.append("- 分布：" + (1...5).map { "\(Mood.label($0)) \(m.distribution[$0])" }.joined(separator: " · "))
        if let bright = m.brightest, let dim = m.dimmest {
            lines.append("- 最晴的月份：\(bright.label)（平均 \(RecordStats.decimal(bright.value))）；最阴的月份：\(dim.label)（平均 \(RecordStats.decimal(dim.value))）")
        }
        return lines
    }

    private static func habits(_ h: AnnalsReport.HabitPart, period: AnnalsPeriod) -> [String] {
        var first = "- 综合完成率 \(RecordStats.percent(h.rate))"
        if let previous = h.previousRate { first += "（" + AnnalsReport.rateCompareText(h.rate, previous: previous, label: period.previousLabel) + "）" }
        first += " · 功课圆满 \(h.perfectDays) 天"
        var lines = [first]
        let trend = h.perBucket.compactMap { b in b.rate.map { "\(bucketName(b.bucket, period: period)) \(RecordStats.percent($0))" } }
        if trend.count >= 2 { lines.append("- " + (isYear(period) ? "逐月" : "逐周") + "：" + trend.joined(separator: " → ")) }
        if !h.rows.isEmpty {
            lines.append("")
            lines.append("| 功课 | 频率 | 完成率 | 达标 | 最长连续 |")
            lines.append("|---|---|---|---|---|")
            for row in h.rows {
                lines.append("| \(row.title)\(row.archived ? "（已归档）" : "") | \(row.schedule) | \(RecordStats.percent(row.rate)) | "
                             + "\(row.achieved) 次 | \(row.longest.count) \(row.longest.unit) |")
            }
        }
        return lines
    }

    /// 境界与小阶都没变：只一句“这一年稳在「…」，累计 +N”（与页面同一句，不再写“A → A”和“仍在「A」”）；
    /// 本境升了小阶或破了境：写期初 → 期末（“渡劫 · 中期 → 渡劫 · 大圆满”），破境另列破境日
    private static func cultivation(_ c: AnnalsReport.CultivationPart, period: AnnalsPeriod) -> [String] {
        guard !c.isSteady else {
            return ["- " + c.steadyLine(unitLabel: period.unitLabel) + "（修为共 \(RecordStats.grouped(c.endXP))）"]
        }
        let start = c.startState, end = c.endState
        return ["- 所得修为 +\(RecordStats.grouped(c.gained))（\(start.title) → \(end.title)，累计 \(RecordStats.grouped(c.endXP))）"]
            + c.breakthroughs.map { "- \($0.day.shortLabel) · 破境入「\($0.realm)」" }
    }

    private static func finance(_ f: AnnalsReport.FinancePart, period: AnnalsPeriod) -> [String] {
        var first = "- 净消费 \(RecordStats.dollars(f.netCents))（扣款 \(RecordStats.dollars(f.spendCents)) · 退款 \(RecordStats.dollars(f.refundCents))）"
        if let c = f.comparison, let compare = AnnalsReport.compareText(c.currentNetCents, from: c.previousNetCents, label: period.previousLabel) {
            first += "，" + compare  // 按几个整月比较写在节末那句里，这里不重复
        }
        var lines = [first]
        if !f.categories.isEmpty {
            var parts = f.categories.map { c -> String in
                var notes: [String] = []
                if f.spendCents > 0 { notes.append("占 " + RecordStats.percent(Double(c.cents) / Double(f.spendCents))) }
                if let change = c.change {
                    // 不到 50 分的差取整后是 $0：写“与上一季持平”，不写“+$0”（与页面类别行同一判断）
                    notes.append(AnnalsReport.isFlatCents(change) ? AnnalsReport.flatText(period.previousLabel) : "较\(period.previousLabel) \(signedDollars(change))")
                }
                return "\(c.name) \(RecordStats.dollars(c.cents))" + (notes.isEmpty ? "" : "（" + notes.joined(separator: "，") + "）")
            }
            if f.otherCategories > 0 { parts.append("其余 \(f.otherCategories) 类") }
            lines.append("- 主要类别：" + parts.joined(separator: "；"))
        }
        if f.months.count > 1 {
            lines.append("")
            lines.append("| 月份 | 净消费 |")
            lines.append("|---|---|")
            for m in f.months {
                // 与页面卷首灵石格、逐月柱下标同一个说法“未导全”（以前导出写“（部分）”，与页面两种叫法）
                let partial = PartialMonthRule.flags(full: m.full, manualOnly: f.manualOnly) ? PartialMonthRule.suffix : ""
                lines.append("| \(m.label) | \(RecordStats.dollars(m.netCents))\(partial) |")
            }
        }
        if let remark = f.remark {
            lines.append("")
            lines.append(remark)
        }
        return lines
    }

    private static func highlights(_ h: AnnalsReport.Highlights, today: LocalDay) -> [String] {
        var lines: [String] = []
        func item(_ e: RecordEntry) -> String {
            var line = "- \(e.day.shortLabel) \(e.day.weekdayName) · \(e.kind.label) · \(e.displayTitle)"
            if e.chars > 0 { line += " · \(RecordStats.grouped(e.chars)) 字" }
            if !e.excerpt.isEmpty, e.excerpt != e.displayTitle { line += "\n  > " + e.excerpt }
            return line
        }
        if !h.pinned.isEmpty {
            lines.append("### 珍藏")
            lines.append(contentsOf: h.pinned.map(item))
            if h.pinnedMore > 0 { lines.append("- 另有 \(h.pinnedMore) 篇珍藏，在修行录「珍藏」里看全部") }
        }
        if !h.longest.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("### 最长的日记")
            lines.append(contentsOf: h.longest.map(item))
        }
        return lines
    }

    // MARK: 小工具

    private static func longDate(_ day: LocalDay) -> String { "\(day.year)年\(day.shortLabel)" }

    private static func isYear(_ period: AnnalsPeriod) -> Bool {
        if case .year = period.scope { return true }
        return false
    }

    /// 表头：全年按月、季度按周
    private static func unitName(_ period: AnnalsPeriod) -> String { isYear(period) ? "月份" : "周" }

    /// 全年写“3月”；季度写“10/6 起”
    private static func bucketName(_ bucket: AnnalsReport.Bucket, period: AnnalsPeriod) -> String {
        isYear(period) ? bucket.label : bucket.label + " 起"
    }

    /// “+$320” / “−$85”
    private static func signedDollars(_ cents: Int) -> String {
        cents >= 0 ? "+" + RecordStats.dollars(cents) : "−" + RecordStats.dollars(-cents)
    }
}
