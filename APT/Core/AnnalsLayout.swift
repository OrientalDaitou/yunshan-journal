import Foundation

// 岁月长卷的排版规则（纯逻辑，CoreCheck 可测）：显示哪几节、节号怎么排、卷首数字格几列、心境曲线在哪里断开、PDF 怎么装页。
// 页面（AnnalsView / AnnalsSections）与 PDF（AnnalsPDF）共用，两边节号、分档一致。

enum AnnalsLayout {
    /// 长卷里的一节（顺序固定；没有数据的节不出，后面的节号依次前移）
    enum Part: String, CaseIterable {
        case writing, mood, habits, cultivation, finance, highlights, insights

        var title: String {
            switch self {
            case .writing: "笔墨"
            case .mood: "心境"
            case .habits: "功课"
            case .cultivation: "修为"
            case .finance: "灵石"
            case .highlights: "珍藏与长篇"
            case .insights: "洞见"
            }
        }

        /// 节标题旁的小物插画（yunshan-ornament-<名>-v1）
        var ornament: String {
            let name: String = switch self {
            case .writing: "brush"
            case .mood: "incense"
            case .habits: "lotus"
            case .cultivation: "summit-token"
            case .finance: "abacus"
            case .highlights: "treasurebox"
            case .insights: "star-map"
            }
            return "yunshan-ornament-\(name)-v1"
        }
    }

    /// 实际显示的节与节号（“其一”“其二”……按出现的先后重排）。整段没有记录时一节都不出（只画卷首与卷尾）；
    /// 洞见在有记录时总显示（一条都没有时显示“样本不够”的提示）
    static func parts(_ r: AnnalsReport) -> [(part: Part, number: String)] {
        guard !r.isEmpty else { return [] }
        var shown: [Part] = []
        if r.writing != nil { shown.append(.writing) }
        if r.mood != nil { shown.append(.mood) }
        if r.habits != nil { shown.append(.habits) }
        if showsCultivation(r) { shown.append(.cultivation) }
        if r.finance != nil { shown.append(.finance) }
        if !r.highlights.isEmpty { shown.append(.highlights) }
        shown.append(.insights)
        return shown.enumerated().map { ($0.element, "其" + ChineseNumerals.ordinal($0.offset + 1)) }
    }

    /// 修为一格与“修为”一节：修为开着、且这段时间真有所得（一篇没写、一次卡没打时只有账目，不出一节“+0 修为”）
    static func showsCultivation(_ r: AnnalsReport) -> Bool {
        guard let c = r.cultivation else { return false }
        return c.gained > 0 || !c.breakthroughs.isEmpty
    }

    // MARK: 宽度分档（卷内宽度：纸面减去左右留白）

    /// 图表与要点左右两栏（6:4）的最小卷内宽度，窄于它上下排
    static let twoColumnWidth = 820.0
    /// 卷首右侧竖排题签的最小卷内宽度
    static let labelWidth = 760.0
    /// 卷首数字格一行排下的最小卷内宽度
    static let tileRowWidth = 800.0

    /// 卷首数字格的列数：宽时 4、5 格一行排完；窄时 5 格排 3 + 2、4 格排 2 + 2（不排成难看的 4 + 1 或 3 + 1）；
    /// 3 格及以下按 3 列的格宽靠左排（只有一两格时不被拉成半幅宽的大块）
    static func tileColumns(count: Int, innerWidth: Double) -> Int {
        guard count > 3 else { return 3 }
        if innerWidth >= tileRowWidth { return count }
        return count == 4 ? 2 : 3
    }

    /// 按列数把格子切成行：[[0, 1, 2], [3, 4]]（末行靠左，与上排同宽）
    static func rows(count: Int, columns: Int) -> [[Int]] {
        let columns = max(1, columns)
        return stride(from: 0, to: count, by: columns).map { Array($0..<min(count, $0 + columns)) }
    }

    // MARK: 心境曲线

    /// 曲线的“段”：相邻两点隔得太久就断开另起一段。季度按日画，相隔 3 天以上断开（与卷中气象同规则）；
    /// 全年按周画（每周一个点），按周放宽：中间空了一整周以上（相隔超过 14 天）才断开。返回每个点所属的段号
    static func moodSegments(_ days: [LocalDay], weekly: Bool) -> [Int] {
        let gap = weekly ? 14 : 3
        var result: [Int] = []
        var segment = 0
        for (index, day) in days.enumerated() {
            if index > 0, days[index - 1].days(to: day) > gap { segment += 1 }
            result.append(segment)
        }
        return result
    }

    // MARK: PDF 装页

    /// 贪心装页：按顺序往当前页放，放不下就换一页；单块比一整页还高时独占一页（由调用方等比缩小）。
    /// gap 是块与块之间的间距（只算在同一页的两块之间）。返回每页放哪几块（下标）
    static func pack(heights: [Double], available: Double, gap: Double = 0) -> [[Int]] {
        var pages: [[Int]] = []
        var current: [Int] = []
        var used = 0.0
        for (index, height) in heights.enumerated() {
            let need = (current.isEmpty ? 0 : gap) + height
            if !current.isEmpty, used + need > available {
                pages.append(current)
                current = []
                used = 0
            }
            used += current.isEmpty ? height : gap + height
            current.append(index)
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }

    /// 单块超过一页时的缩放比例（≤ 1）
    static func fitScale(height: Double, available: Double) -> Double {
        height > available && height > 0 ? available / height : 1
    }

    // MARK: 文案

    /// 常用标签超过 12 字截断（悬停看全名）
    static let tagLimit = 12
    static func tagLabel(_ tag: String) -> String {
        tag.count > tagLimit ? String(tag.prefix(tagLimit)) + "…" : tag
    }

    /// 其二心境图表标题旁的小字：全年“按周平均 · 264 篇带心境”，季度“逐日 · 75 篇带心境”（不再写“43 个周点”这种说法）
    static func moodCaption(entries: Int, weekly: Bool) -> String {
        (weekly ? "按周平均" : "逐日") + " · \(entries) 篇带心境"
    }

    /// 卷首灵石格的对比：格里只写“较去年同期 +2%”（五格一行时不再折出只剩“整月）”的孤行），
    /// 按几个整月比的放进悬停说明（节末那一行也写着）。不能比较、对比期为 0 时 nil
    static func financeCompare(_ f: AnnalsReport.FinancePart, previousLabel: String) -> (text: String, help: String)? {
        guard let c = f.comparison, let change = AnnalsReport.change(c.currentNetCents, from: c.previousNetCents) else { return nil }
        return ("较\(previousLabel) \(change)", "按 \(c.months) 个已导全的整月比较（本月与没导全的月份不算）")
    }

    /// 导出文件名：“岁月长卷-2026” / “岁月长卷-2026-第四季”
    static func fileName(_ period: AnnalsPeriod) -> String {
        switch period.scope {
        case .year(let y): "岁月长卷-\(y)"
        case .quarter(let y, let q): "岁月长卷-\(y)-第\(ChineseNumerals.ordinal(q))季"
        }
    }

    /// 工具条的季度签：当年只列已开始的季度
    static func quarters(year: Int, today: LocalDay) -> [Int] {
        (1...4).filter { AnnalsPeriod.make(.quarter(year, $0), today: today) != nil }
    }

    /// 切年份时保持“全年 / 第几季”；那一季在新年份还没开始就回到全年
    static func move(_ scope: AnnalsScope, toYear year: Int, today: LocalDay) -> AnnalsScope {
        switch scope {
        case .year: return .year(year)
        case .quarter(_, let q):
            return AnnalsPeriod.make(.quarter(year, q), today: today) != nil ? .quarter(year, q) : .year(year)
        }
    }
}
