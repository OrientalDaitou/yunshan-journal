import SwiftUI
import Charts

// 岁月长卷的卷内内容：卷首（大字年份、五枚数字格、竖排题签）、其一至其七、卷尾落款；另给 PDF 排版用的分块 printBlocks。
// 数据全部来自 AnnalsReport（Core 的 AnnalsEngine 算好），这里只管排版与特效。节号按实际显示的节重排（AnnalsLayout.parts）。

// MARK: - 长卷正文

/// 卷内全部内容。卷首不在懒加载区（数字升腾不受回收影响）；各节与卷尾在 LazyVStack 里，滚到才建、触发各自的进场特效
struct AnnalsBody: View {
    var report: AnnalsReport
    /// 点开一篇（按 uid 现取 JournalEntry，只读打开）
    var onRead: (String) -> Void

    var body: some View {
        let key = report.period.storageKey
        VStack(alignment: .leading, spacing: 40) {
            AnnalsHeader(report: report)
            LazyVStack(alignment: .leading, spacing: 40) {
                if report.isEmpty {
                    Hint("这段时间没有记录。")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                ForEach(AnnalsSections.items(report)) { item in
                    PlayOnce(id: "\(key)|\(item.part.rawValue)") { play in
                        AnnalsPartView(report: report, item: item, play: play, onRead: onRead)
                    }
                    .ysEntrance(order: 0)
                }
                PlayOnce(id: "\(key)|colophon") { play in
                    AnnalsColophon(report: report, play: play)
                }
            }
        }
    }
}

/// 一节：节标题 + 内容
struct AnnalsPartView: View {
    var report: AnnalsReport
    var item: AnnalsSections.Item
    var play: Bool
    var onRead: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AnnalsSectionTitle(number: item.number, title: item.part.title, ornament: item.part.ornament)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        let period = report.period
        switch item.part {
        case .writing:
            if let w = report.writing { WritingSection(w: w, period: period, play: play, onRead: onRead) }
        case .mood:
            if let m = report.mood { MoodSection(m: m, period: period, play: play) }
        case .habits:
            if let h = report.habits {
                VStack(alignment: .leading, spacing: 18) {
                    HabitSummary(h: h, period: period, play: play)
                    HabitTable(rows: h.rows, showHeading: true, total: h.rows.count)
                }
            }
        case .cultivation:
            if let c = report.cultivation { CultivationSection(c: c, period: period, play: play) }
        case .finance:
            if let f = report.finance { FinanceSection(f: f, period: period, play: play) }
        case .highlights:
            HighlightsSection(h: report.highlights, onRead: onRead)
        case .insights:
            InsightsSection(insights: report.insights, play: play)
        }
    }
}

enum AnnalsSections {
    struct Item: Identifiable {
        var part: AnnalsLayout.Part
        var number: String
        var id: String { part.rawValue }
    }

    static func items(_ r: AnnalsReport) -> [Item] {
        AnnalsLayout.parts(r).map { Item(part: $0.part, number: $0.number) }
    }

    /// PDF 打印宽度：A4 595 − 左右各 48
    static let printWidth: CGFloat = 499

    /// PDF 的排版块：卷首、各节（图表与要点各一块；长列表预先切块：功课每 6 行、珍藏卡每 4 张、洞见每 4 条一块）、卷尾。
    /// 都在打印模式（无特效、无悬停、无懒加载、强制浅色）下、宽 499
    @MainActor
    static func printBlocks(_ r: AnnalsReport) -> [AnyView] {
        var blocks: [AnyView] = [AnyView(AnnalsHeader(report: r))]
        let period = r.period
        if r.isEmpty { blocks.append(AnyView(Hint("这段时间没有记录。"))) }
        for item in items(r) {
            let title = AnnalsSectionTitle(number: item.number, title: item.part.title, ornament: item.part.ornament)
            func titled<V: View>(_ view: V) -> AnyView {
                AnyView(VStack(alignment: .leading, spacing: 18) { title; view })
            }
            /// 一节拆两块：节标题 + 图表、要点
            func split<V: View>(_ view: V) {
                blocks.append(titled(view.environment(\.annalsPiece, .leading)))
                blocks.append(AnyView(view.environment(\.annalsPiece, .trailing)))
            }
            switch item.part {
            case .writing:
                if let w = r.writing { split(WritingSection(w: w, period: period, play: false, onRead: { _ in })) }
            case .mood:
                if let m = r.mood { split(MoodSection(m: m, period: period, play: false)) }
            case .habits:
                guard let h = r.habits else { continue }
                split(HabitSummary(h: h, period: period, play: false))
                // 功课表每 6 行一块（比整 10 行装页更紧：一节的图表后面常常还放得下几行）
                for (index, start) in stride(from: 0, to: h.rows.count, by: 6).enumerated() {
                    let chunk = Array(h.rows[start..<min(h.rows.count, start + 6)])
                    blocks.append(AnyView(HabitTable(rows: chunk, showHeading: index == 0, total: h.rows.count)))
                }
            case .cultivation:
                if let c = r.cultivation { split(CultivationSection(c: c, period: period, play: false)) }
            case .finance:
                if let f = r.finance { split(FinanceSection(f: f, period: period, play: false)) }
            case .highlights:
                let h = r.highlights
                var first = true
                for (heading, entries, more) in [("珍藏", h.pinned, h.pinnedMore), ("最长的日记", h.longest, 0)] where !entries.isEmpty {
                    for (index, start) in stride(from: 0, to: entries.count, by: 4).enumerated() {
                        let chunk = Array(entries[start..<min(entries.count, start + 4)])
                        let last = start + 4 >= entries.count
                        let group = HighlightGroup(title: index == 0 ? heading : nil, entries: chunk, more: last ? more : 0, onRead: { _ in })
                        blocks.append(first ? titled(group) : AnyView(group))
                        first = false
                    }
                }
            case .insights:
                // 洞见每 4 条一块
                let chunks = stride(from: 0, to: max(1, r.insights.count), by: 4).map { Array(r.insights[$0..<min(r.insights.count, $0 + 4)]) }
                for (index, chunk) in chunks.enumerated() {
                    let view = InsightsSection(insights: chunk, play: false, showNote: index == 0)
                    blocks.append(index == 0 ? titled(view) : AnyView(view))
                }
            }
        }
        blocks.append(AnyView(AnnalsColophon(report: r, play: false)))
        return blocks.map { block in
            AnyView(block
                .frame(width: printWidth, alignment: .leading)
                .environment(\.annalsPrint, true)
                .environment(\.annalsAnimate, false)
                .environment(\.annalsInnerWidth, printWidth)
                .environment(\.spiritMotion, false)
                .environment(\.colorScheme, .light)
                .font(.ysBody)
                .foregroundStyle(Theme.text))
        }
    }
}

// MARK: - 小件：两栏、要点、数字

/// 宽时左右两栏（6:4），窄时上下排
private struct AnnalsColumns<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.annalsInnerWidth) private var width
    @Environment(\.annalsPiece) private var piece

    var body: some View {
        if piece == .leading {
            leading()
        } else if piece == .trailing {
            trailing()
        } else if Double(width) >= AnnalsLayout.twoColumnWidth {
            let gap: CGFloat = 32
            HStack(alignment: .top, spacing: gap) {
                leading().frame(width: (width - gap) * 0.6, alignment: .topLeading)
                trailing().frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                leading()
                trailing()
            }
        }
    }
}

/// PDF 排版时把一节拆成两块（图表 / 要点），装页更紧凑：leading 只排左栏（图表），trailing 只排右栏（要点）与节末说明
enum AnnalsPiece { case all, leading, trailing }

private struct AnnalsPieceKey: EnvironmentKey { static let defaultValue = AnnalsPiece.all }

extension EnvironmentValues {
    var annalsPiece: AnnalsPiece {
        get { self[AnnalsPieceKey.self] }
        set { self[AnnalsPieceKey.self] = newValue }
    }
}

/// 要点一行：金色小图标 + 正文 13（数字用 New York 衬线体加粗）
private struct AnnalsPoint: View {
    var icon: String
    var text: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.gold)
                .frame(width: 16)
                .accessibilityHidden(true)
            text
                .font(.ysCallout)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 要点里的数字：New York 衬线体、等宽、墨色
private func figure(_ text: String, size: CGFloat = 17) -> Text {
    Text(text).font(Theme.figure(size, .semibold)).foregroundStyle(Theme.ink)
}

private func soft(_ text: String) -> Text {
    Text(text).foregroundStyle(Theme.inkSoft)
}

/// 图表上方的小说明（“每月落笔”“心境走势”）
private struct ChartCaption: View {
    var text: String
    var body: some View {
        Text(text).font(Theme.songti(TypeSize.callout, .semibold)).tracking(1).foregroundStyle(Theme.ink)
    }
}

/// 一节的主数字：“+12,480 修为”“$9,820 净消费”“73% 综合完成率”
private struct LeadFigure: View {
    var target: Double
    var play: Bool
    var text: (Double) -> String
    var caption: String
    var tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RisingText(target: target, play: play, text: text)
                .font(Theme.figure(34, .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption).font(Theme.songti(TypeSize.body, .semibold)).tracking(2).foregroundStyle(Theme.inkSoft)
        }
    }
}

private func isYear(_ period: AnnalsPeriod) -> Bool {
    if case .year = period.scope { return true }
    return false
}

// MARK: - 卷首

/// 卷首：大字年份（墨色渐变 + 掠光）、范围一行、五枚数字格；右侧竖排题签（卷内宽 ≥ 760 时）
struct AnnalsHeader: View {
    var report: AnnalsReport
    @Environment(\.annalsPrint) private var printing
    @Environment(\.annalsInnerWidth) private var width
    @Environment(\.annalsAnimate) private var animate
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let period = report.period
        let tiles = AnnalsTileSpec.tiles(report)
        let showSlip = Double(width) >= AnnalsLayout.labelWidth
        let slipWidth: CGFloat = showSlip ? 52 : 0
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                title(period)
                HStack(spacing: 10) {
                    Rectangle()
                        .fill(AnnalsFade.style(LinearGradient(colors: [Theme.gold, Theme.gold.opacity(0)], startPoint: .leading, endPoint: .trailing),
                                               print: Theme.gold.opacity(0.5), printing: printing))
                        .frame(width: 46, height: 1)
                    Text(rangeText)
                        .font(.ysCaption)
                        .foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
                if !tiles.isEmpty {
                    AnnalsTiles(tiles: tiles, width: width - slipWidth)
                        .padding(.top, 26)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showSlip {
                VerticalTitleSlip()
                    .padding(.leading, 18)
                    .frame(width: slipWidth, alignment: .trailing)
            }
        }
    }

    private var rangeText: String {
        let p = report.period
        guard report.startsLate, let start = report.recordStart else { return p.rangeLabel }
        return p.rangeLabel + " · 记录始于 \(start.year)年\(start.shortLabel)"
    }

    private func title(_ period: AnnalsPeriod) -> some View {
        let dark = scheme == .dark
        let ink = LinearGradient(colors: [Theme.ink, dark ? Color(red: 0.85, green: 0.78, blue: 0.6) : Theme.jadeDeep],
                                 startPoint: .top, endPoint: .bottom)
        let year = ChineseNumerals.year(period.scope.year) + "年"
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(year)
                .font(.ysDisplay)
                .tracking(6)
                .foregroundStyle(ink)
                .shimmerSweep(animate)
            if case .quarter(_, let q) = period.scope {
                Text(" · 第\(ChineseNumerals.ordinal(q))季")
                    .font(Theme.songti(TypeSize.title, .semibold))
                    .tracking(3)
                    .foregroundStyle(Theme.ink)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .shadow(color: dark ? Theme.gold.opacity(0.2) : .white.opacity(0.9), radius: dark ? 10 : 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 卷首一枚数字格的内容
struct AnnalsTileSpec {
    var label: String
    var target: Double
    var text: (Double) -> String
    var unit: String
    var note: String
    /// 期内有未导全的月份：底注后挂灰色小标“! 未导全”（与灵石账簿月份旁同一个说法、同一枚圆圈感叹号）
    var partial = false
    var compare: String?
    /// 对比句的悬停说明（灵石格：按几个整月比）
    var compareHelp: String?
    var tint: Color = Theme.ink

    /// 没有某类数据时那一格不出现；修为关闭时没有修为格
    static func tiles(_ r: AnnalsReport) -> [AnnalsTileSpec] {
        let p = r.period
        var result: [AnnalsTileSpec] = []
        if let w = r.writing {
            // 变化为 0 时写“与去年同期持平”
            let compare = w.previousEntries.flatMap { AnnalsReport.compareText(w.entries, from: $0, label: p.previousLabel) }
            result.append(.init(label: "落笔", target: Double(w.entries), text: { RecordStats.grouped(Int($0.rounded())) }, unit: "篇",
                                note: "动笔 \(w.writingDays) 天", compare: compare))
            if w.chars > 0 {
                let c = RecordStats.chars(w.chars)
                let big = w.chars >= 10_000
                let target = big ? Double(w.chars) / 10_000 : Double(w.chars)
                result.append(.init(label: "字数", target: target,
                                    text: { v in v >= target - 1e-9 ? c.number : (big ? String(format: "%.1f", v) : RecordStats.grouped(Int(v.rounded()))) },
                                    unit: c.unit, note: w.longest.map { "最长一篇 \(RecordStats.grouped($0.chars)) 字" } ?? ""))
            }
        }
        if let h = r.habits {
            result.append(.init(label: "功课", target: h.rate * 100, text: { "\(Int($0.rounded()))" }, unit: "%",
                                note: "圆满 \(h.perfectDays) 天",
                                compare: h.previousRate.map { AnnalsReport.rateCompareText(h.rate, previous: $0, label: p.previousLabel) },
                                tint: Theme.positive))
        }
        if let c = r.cultivation, AnnalsLayout.showsCultivation(r) {
            // 与修为节同一判断（isSteady）：境界与小阶都没变才写“稳在”，本境升了小阶写“渡劫 · 中期 → 大圆满”
            result.append(.init(label: "修为", target: Double(c.gained), text: { "+" + RecordStats.grouped(Int($0.rounded())) }, unit: "",
                                note: c.tileNote, tint: Theme.precious))
        }
        if let f = r.finance {
            let net = f.netCents
            let compare = AnnalsLayout.financeCompare(f, previousLabel: p.previousLabel)
            // 格里的对比句与落笔格同一种写法（变化为 0 写“与去年同期持平”）；按几个整月比照旧放进悬停
            let compareText = f.comparison.flatMap { AnnalsReport.compareText($0.currentNetCents, from: $0.previousNetCents, label: p.previousLabel) }
            result.append(.init(label: "灵石", target: Double(net) / 100,
                                text: { v in abs(v - Double(net) / 100) < 1e-9 ? RecordStats.dollars(net) : RecordStats.dollars(Int((v * 100).rounded())) },
                                unit: "", note: f.manualOnly ? "净消费 · 仅手记" : "净消费",
                                partial: !f.manualOnly && !f.incompleteMonths.isEmpty, compare: compare.flatMap { _ in compareText }, compareHelp: compare?.help))
        }
        return result
    }
}

/// 五枚数字格：宽时一行，窄时 3 + 2（第二行靠左、与上排同宽），见 AnnalsLayout.tileColumns
private struct AnnalsTiles: View {
    var tiles: [AnnalsTileSpec]
    var width: CGFloat
    @Environment(\.annalsAnimate) private var animate

    var body: some View {
        let spacing: CGFloat = 12
        let columns = AnnalsLayout.tileColumns(count: tiles.count, innerWidth: Double(width))
        let tileWidth = max(80, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(AnnalsLayout.rows(count: tiles.count, columns: columns), id: \.self) { row in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(row, id: \.self) { index in
                        AnnalsTile(spec: tiles[index], play: animate).frame(width: tileWidth)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 一枚数字格（样式同 MetricTile：内嵌格底；数字 New York 26，带“数字升腾”）
private struct AnnalsTile: View {
    var spec: AnnalsTileSpec
    var play: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(spec.label).font(Theme.songti(TypeSize.callout, .semibold)).tracking(3).foregroundStyle(Theme.gold)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                RisingText(target: spec.target, play: play, text: spec.text)
                    .font(Theme.figure(TypeSize.title))
                    .foregroundStyle(spec.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !spec.unit.isEmpty { Text(spec.unit).font(.ysCaption).foregroundStyle(Theme.inkSoft) }
            }
            if !spec.note.isEmpty || spec.partial {
                HStack(spacing: 6) {
                    if !spec.note.isEmpty {
                        Text(spec.note).font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    if spec.partial {
                        // 与灵石账簿月份旁的小标同一个说法、同一枚图标（FinanceHeadlineRule），从账簿切过来不会看到两种叫法
                        HStack(spacing: 3) {
                            Image(systemName: FinanceHeadlineRule.partialSymbol)
                                .font(.system(size: TypeSize.micro, weight: .semibold))
                            Text(FinanceHeadlineRule.partialLabel)
                        }
                        .font(.ysCaption)
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(1)
                        .fixedSize()
                        .help("期内有银行账单未导全的月份，合计可能偏低")
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let compare = spec.compare {
                Text(compare).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(spec.compareHelp ?? "")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.mist.opacity(scheme == .dark ? 0.9 : 0.72), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(alignment: .topLeading) {
            // 左上一笔金线：像题签的封口
            Capsule().fill(Theme.gold.opacity(0.7)).frame(width: 18, height: 1.5).padding(.leading, 14).offset(y: -0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 其一 · 笔墨

private struct WritingSection: View {
    var w: AnnalsReport.Writing
    var period: AnnalsPeriod
    var play: Bool
    var onRead: (String) -> Void
    @Environment(\.annalsPrint) private var printing
    @Environment(\.annalsPiece) private var piece

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AnnalsColumns {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        ChartCaption(text: isYear(period) ? "每月落笔" : "每周落笔")
                        KindLegend(byKind: w.byKind)
                    }
                    WritingChart(w: w, yearly: isYear(period), play: play)
                }
            } trailing: {
                VStack(alignment: .leading, spacing: 13) {
                    AnnalsPoint(icon: "pencil.line", text: Text("落笔 ") + figure(RecordStats.grouped(w.entries)) + Text(" 篇"))
                    AnnalsPoint(icon: "calendar", text: Text("动笔 ") + figure("\(w.writingDays)") + Text(" 天") + soft("（占 \(RecordStats.percent(w.writingShare))）"))
                    if let run = w.longestRun {
                        AnnalsPoint(icon: "flame", text: Text("最长连续 ") + figure("\(run.count)") + Text(" 天") + soft(" · \(run.first.shortLabel)—\(run.last.shortLabel)"))
                    }
                    if w.chars > 0 {
                        AnnalsPoint(icon: "text.alignleft", text: Text("日均 ") + figure(RecordStats.grouped(w.averageChars)) + Text(" 字"))
                    }
                    if let longest = w.longest {
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Image(systemName: "scroll").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.gold).frame(width: 16)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                (Text("最长一篇 ") + figure(RecordStats.grouped(longest.chars)) + Text(" 字"))
                                    .font(.ysCallout).foregroundStyle(Theme.text)
                                ReadLink(text: "\(longest.day.shortLabel)「\(longest.displayTitle)」", enabled: !printing) { onRead(longest.uid) }
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            if !w.tags.isEmpty && piece != .leading {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("常用标签").font(Theme.songti(TypeSize.callout, .semibold)).tracking(1).foregroundStyle(Theme.ink).fixedSize()
                    FlowLayout(spacing: 8) {
                        ForEach(w.tags.indices, id: \.self) { index in
                            let tag = w.tags[index]
                            Chip(text: "#\(AnnalsLayout.tagLabel(tag.tag)) \(tag.count)", color: Theme.jade)
                                .fixedSize()
                                .help(tag.tag.count > AnnalsLayout.tagLimit ? "#\(tag.tag)" : "")
                        }
                    }
                }
            }
        }
    }
}

/// 打开一篇的小链接：淡金小字一行（太长时截断），悬停出下划线与“→”；打印时只是灰字
private struct ReadLink: View {
    var text: String
    var enabled: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        if enabled {
            Button(action: action) {
                HStack(spacing: 3) {
                    Text(verbatim: text).lineLimit(1).truncationMode(.tail)
                    Text(verbatim: "→").opacity(hover ? 1 : 0.6).accessibilityHidden(true)
                }
                .font(.system(size: TypeSize.caption, weight: .medium))
                .foregroundStyle(Theme.gold)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.gold.opacity(0.6)).frame(height: 1).offset(y: 2).opacity(hover ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help("只读打开：\(text)")
        } else {
            Text(verbatim: text).font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(1).truncationMode(.tail)
        }
    }
}

/// 三类的颜色与篇数：● 日记 412 ● 灵感 160 ● 复盘 40（颜色同修行录：日记玉、灵感金、复盘青）
private struct KindLegend: View {
    var byKind: [JournalKind: Int]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(JournalKind.allCases) { kind in
                if let n = byKind[kind], n > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(kind.color).frame(width: 7, height: 7)
                        Text("\(kind.label) \(n)").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                    }
                }
            }
        }
    }
}

/// 堆叠柱：全年按月、季度按周；悬停浮出“3月：日记 52 · 灵感 31 · 复盘 5”
private struct WritingChart: View {
    var w: AnnalsReport.Writing
    var yearly: Bool
    var play: Bool
    @Environment(\.annalsPrint) private var printing
    @State private var selected: String?

    private struct Bar: Identifiable {
        var index: Int
        var label: String
        var kind: JournalKind
        var count: Int
        var id: String { "\(index)-\(kind.rawValue)" }
    }

    var body: some View {
        let bars = w.perBucket.enumerated().flatMap { index, b in
            [Bar(index: index, label: b.bucket.label, kind: .diary, count: b.diary),
             Bar(index: index, label: b.bucket.label, kind: .note, count: b.note),
             Bar(index: index, label: b.bucket.label, kind: .review, count: b.review)]
        }
        let top = max(1, w.perBucket.map { $0.diary + $0.note + $0.review }.max() ?? 1)
        let labels = w.perBucket.map(\.bucket.label)
        let shown = Set(stride(from: 0, to: labels.count, by: labels.count > 9 ? 2 : 1).map { labels[$0] })
        Growing(play: play) { grown in
            Chart {
                ForEach(bars) { bar in
                    BarMark(x: .value("时段", bar.label), y: .value("篇数", grown ? bar.count : 0), width: .ratio(0.62))
                        .foregroundStyle(by: .value("类型", bar.kind.label))
                }
                if let selected, let b = w.perBucket.first(where: { $0.bucket.label == selected }) {
                    RuleMark(x: .value("时段", selected))
                        .foregroundStyle(Theme.gold.opacity(0.18))
                        .lineStyle(StrokeStyle(lineWidth: 18))
                        .zIndex(-1)
                        .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text("\(yearly ? b.bucket.label : b.bucket.label + " 起")：日记 \(b.diary) · 灵感 \(b.note) · 复盘 \(b.review)")
                                .font(.ysCaption).monospacedDigit()
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).strokeBorder(Theme.gold.opacity(0.4)))
                        }
                }
            }
            .chartForegroundStyleScale(domain: JournalKind.allCases.map(\.label), range: JournalKind.allCases.map(\.color))
            .chartLegend(.hidden)
            .chartYScale(domain: 0...(Double(top) * 1.15))
            .chartXAxis {
                AxisMarks(values: labels) { value in
                    AxisValueLabel {
                        if let label = value.as(String.self), shown.contains(label) { Text(label).font(.ysMicro) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Theme.line.opacity(0.6))
                    AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)").font(.ysMicro).monospacedDigit() } }
                }
            }
            .modifier(SelectionModifier(selected: $selected, enabled: !printing))
            .frame(height: 160)
        }
    }
}

/// 悬停选中（打印时不挂）
private struct SelectionModifier: ViewModifier {
    @Binding var selected: String?
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.chartXSelection(value: $selected) } else { content }
    }
}

// MARK: - 其二 · 心境

private struct MoodSection: View {
    var m: AnnalsReport.MoodPart
    var period: AnnalsPeriod
    var play: Bool

    var body: some View {
        AnnalsColumns {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // 标题不再写“每周平均 / 每日”：右边的小字已写“按周平均 / 逐日”，免得同一行说两遍
                    ChartCaption(text: "心境走势")
                    Text(AnnalsLayout.moodCaption(entries: m.entries, weekly: isYear(period))).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                }
                MoodCurve(m: m, period: period).drawOn(play)
            }
        } trailing: {
            VStack(alignment: .leading, spacing: 14) {
                MoodSpread(distribution: m.distribution)
                AnnalsPoint(icon: Mood.symbol(m.dominant),
                            text: Text("平均 ") + figure(RecordStats.decimal(m.average)) + Text("，多在「\(Mood.label(m.dominant))」"))
                if let bright = m.brightest, let dim = m.dimmest {
                    AnnalsPoint(icon: "sun.max", text: Text("最晴的月份：\(bright.label)") + soft("（平均 \(RecordStats.decimal(bright.value))）"))
                    AnnalsPoint(icon: "cloud.rain", text: Text("最阴的月份：\(dim.label)") + soft("（平均 \(RecordStats.decimal(dim.value))）"))
                }
            }
            .padding(.top, 4)
        }
    }
}

/// 心境曲线：金线 + 渐隐面积，Y 轴“雨 / 平 / 霁”；相隔太久断线（AnnalsLayout.moodSegments）；不足 3 个点只画点
private struct MoodCurve: View {
    var m: AnnalsReport.MoodPart
    var period: AnnalsPeriod
    @Environment(\.annalsPrint) private var printing

    private struct Point: Identifiable {
        var day: LocalDay
        var value: Double
        var segment: Int
        var id: Int { day.jdn }
    }

    var body: some View {
        let yearly = isYear(period)
        let segments = AnnalsLayout.moodSegments(m.points.map(\.day), weekly: yearly)
        let points = zip(m.points, segments).map { Point(day: $0.0.day, value: $0.0.value, segment: $0.1) }
        let line = points.count >= 3
        let ticks = Self.ticks(period)
        Chart(points) { point in
            if line {
                AreaMark(x: .value("日期", point.day.date()), yStart: .value("底", 0.5), yEnd: .value("心境", point.value),
                         series: .value("段", "段\(point.segment)"))
                    .foregroundStyle(AnnalsFade.style(LinearGradient(colors: [Theme.gold.opacity(0.28), Theme.gold.opacity(0)], startPoint: .top, endPoint: .bottom),
                                                      print: Theme.gold.opacity(0.1), printing: printing))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("日期", point.day.date()), y: .value("心境", point.value), series: .value("段", "段\(point.segment)"))
                    .foregroundStyle(Theme.gold)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            PointMark(x: .value("日期", point.day.date()), y: .value("心境", point.value))
                .foregroundStyle(Theme.gold)
                .symbolSize(line ? 14 : 40)
        }
        .chartXScale(domain: period.first.date() ... max(period.last, period.first.adding(days: 1)).date())
        .chartYScale(domain: 0.5...5.5)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [1, 3, 5]) { value in
                AxisGridLine().foregroundStyle(Theme.line.opacity(0.6))
                AxisValueLabel { Text(Mood.label(value.as(Int.self))).font(.ysMicro) }
            }
        }
        .chartXAxis {
            AxisMarks(values: ticks.map { $0.day.date() }) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self), let tick = ticks.first(where: { $0.day == LocalDay(date: date) }) {
                        Text(tick.label).font(.ysMicro)
                    }
                }
            }
        }
        .frame(height: 140)
        .padding(.top, 6)
    }

    /// 横轴刻度：全年每月 1 日（“3月”），季度每两周（“10/15”）
    static func ticks(_ period: AnnalsPeriod) -> [(day: LocalDay, label: String)] {
        if isYear(period) {
            var result: [(LocalDay, String)] = []
            var month = period.first.firstOfMonth
            while month <= period.last {
                result.append((month, "\(month.month)月"))
                month = AnnalsPeriod.monthEnd(month).adding(days: 1)
            }
            return result.map { (day: $0.0, label: $0.1) }
        }
        return stride(from: 0, through: period.first.days(to: period.last), by: 14).map {
            let d = period.first.adding(days: $0)
            return (day: d, label: d.axisLabel)
        }
    }
}

/// 心境分布：一根横条按“雨 阴 平 晴 霁”五段着色，下面写各档篇数
private struct MoodSpread: View {
    var distribution: [Int]

    static func color(_ level: Int) -> Color {
        switch level {
        case 1: Theme.info
        case 2: Theme.info.opacity(0.45)
        case 3: Theme.inkSoft.opacity(0.35)
        case 4: Theme.gold.opacity(0.6)
        default: Theme.gold
        }
    }

    var body: some View {
        let counts = (1...5).map { distribution.indices.contains($0) ? distribution[$0] : 0 }
        let total = max(1, counts.reduce(0, +))
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geo in
                let present = counts.filter { $0 > 0 }.count
                let usable = geo.size.width - CGFloat(max(0, present - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { level in
                        let n = counts[level - 1]
                        if n > 0 {
                            Rectangle().fill(Self.color(level)).frame(width: max(3, usable * CGFloat(n) / CGFloat(total)))
                        }
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            HStack(spacing: 10) {
                ForEach(1...5, id: \.self) { level in
                    HStack(spacing: 4) {
                        Circle().fill(Self.color(level)).frame(width: 6, height: 6)
                        Text("\(Mood.label(level)) \(counts[level - 1])").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                    }
                    .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("心境分布：" + (1...5).map { "\(Mood.label($0)) \(counts[$0 - 1]) 篇" }.joined(separator: "，"))
    }
}

// MARK: - 其三 · 功课

private struct HabitSummary: View {
    var h: AnnalsReport.HabitPart
    var period: AnnalsPeriod
    var play: Bool

    var body: some View {
        AnnalsColumns {
            VStack(alignment: .leading, spacing: 10) {
                ChartCaption(text: isYear(period) ? "逐月综合完成率" : "逐周综合完成率")
                HabitRateChart(h: h, period: period).drawOn(play)
            }
        } trailing: {
            VStack(alignment: .leading, spacing: 13) {
                LeadFigure(target: h.rate * 100, play: play, text: { "\(Int($0.rounded()))%" }, caption: "综合完成率", tint: Theme.positive)
                if let previous = h.previousRate {
                    if RecordStats.percent(previous) == RecordStats.percent(h.rate) {
                        AnnalsPoint(icon: "arrow.left.arrow.right", text: Text(AnnalsReport.flatText(period.previousLabel)))
                    } else {
                        AnnalsPoint(icon: "arrow.left.arrow.right", text: Text("\(period.previousLabel) ") + figure(RecordStats.percent(previous)))
                    }
                }
                AnnalsPoint(icon: "seal", text: Text("功课圆满 ") + figure("\(h.perfectDays)") + Text(" 天"))
                AnnalsPoint(icon: "list.bullet", text: Text("计入 ") + figure("\(h.rows.count)") + Text(" 项功课")
                            + soft(h.rows.contains(where: \.archived) ? "（含已归档）" : ""))
            }
        }
    }
}

/// 逐月 / 逐周综合完成率：玉色折线 + 淡面积
private struct HabitRateChart: View {
    var h: AnnalsReport.HabitPart
    var period: AnnalsPeriod
    @Environment(\.annalsPrint) private var printing

    private struct Point: Identifiable {
        var day: LocalDay
        var label: String
        var rate: Double
        var id: Int { day.jdn }
    }

    var body: some View {
        let points = h.perBucket.compactMap { b in b.rate.map { Point(day: b.bucket.start, label: b.bucket.label, rate: $0 * 100) } }
        let step = points.count > 9 ? 2 : 1
        let ticks = stride(from: 0, to: points.count, by: step).map { points[$0] }
        Chart(points) { p in
            AreaMark(x: .value("时段", p.day.date()), y: .value("完成率", p.rate))
                .foregroundStyle(AnnalsFade.style(LinearGradient(colors: [Theme.jade.opacity(0.22), Theme.jade.opacity(0)], startPoint: .top, endPoint: .bottom),
                                                  print: Theme.jade.opacity(0.1), printing: printing))
                .interpolationMethod(.monotone)
            LineMark(x: .value("时段", p.day.date()), y: .value("完成率", p.rate))
                .foregroundStyle(Theme.jade)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)
            PointMark(x: .value("时段", p.day.date()), y: .value("完成率", p.rate))
                .foregroundStyle(Theme.jade)
                .symbolSize(points.count > 1 ? 16 : 40)
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Theme.line.opacity(0.6))
                AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%").font(.ysMicro).monospacedDigit() } }
            }
        }
        .chartXAxis {
            AxisMarks(values: ticks.map { $0.day.date() }) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self), let p = ticks.first(where: { $0.day == LocalDay(date: date) }) { Text(p.label).font(.ysMicro) }
                }
            }
        }
        .frame(height: 120)
        // 顶上“100%”的刻度会探出图表上沿：留出位置，免得被描画的遮罩切掉
        .padding(.top, 8)
    }
}

/// 逐项表：符号图标、名称（已归档挂小签）、频率、完成率条、达标次数、最长连续。按完成率降序，已归档的排最后；功课多时全列
private struct HabitTable: View {
    var rows: [AnnalsReport.HabitRow]
    var showHeading: Bool
    var total: Int
    @Environment(\.annalsInnerWidth) private var width

    var body: some View {
        let wide = width >= 600
        VStack(alignment: .leading, spacing: 8) {
            if showHeading { AnnalsSubheading(text: "各项功课", detail: "\(total) 项") }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    if index > 0 { Rectangle().fill(Theme.line.opacity(0.55)).frame(height: 1) }
                    GridRow(alignment: .center) {
                        ZStack {
                            Circle().fill(Theme.jade.opacity(row.archived ? 0.06 : 0.12))
                            Image(systemName: row.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.jade)
                        }
                        .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(row.title).font(.system(size: TypeSize.body, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                                if row.archived { Chip(text: "已归档", color: Theme.inkSoft).fixedSize() }
                            }
                            Text(wide ? row.schedule : "\(row.schedule) · 达标 \(row.achieved) 次 · 最长连续 \(row.longest.count) \(row.longest.unit)")
                                .font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(1)
                        }
                        .frame(minWidth: 120, maxWidth: wide ? 230 : 210, alignment: .leading)
                        ProgressBar(value: row.rate, color: Theme.jade, height: 6, solid: true)
                            .frame(minWidth: 60, maxWidth: .infinity)
                        Text(RecordStats.percent(row.rate))
                            .font(Theme.figure(15, .semibold)).foregroundStyle(Theme.ink)
                            .frame(width: 46, alignment: .trailing)
                        if wide {
                            Text("达标 \(row.achieved) 次").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft).lineLimit(1)
                            Text("最长连续 \(row.longest.count) \(row.longest.unit)").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 9)
                    .opacity(row.archived ? 0.75 : 1)
                }
            }
        }
    }
}

// MARK: - 其四 · 修为

private struct CultivationSection: View {
    var c: AnnalsReport.CultivationPart
    var period: AnnalsPeriod
    var play: Bool
    @Environment(\.annalsAnimate) private var animate
    @Environment(\.colorScheme) private var scheme
    @Environment(\.annalsPrint) private var printing

    var body: some View {
        AnnalsColumns {
            VStack(alignment: .leading, spacing: 18) {
                LeadFigure(target: Double(c.gained), play: play, text: { "+" + RecordStats.grouped(Int($0.rounded())) }, caption: "修为", tint: Theme.precious)
                // 境界与小阶都没变才只画一枚徽记；本境升了小阶（渡劫 · 中期 → 大圆满）与破境一样画两枚对照
                if c.isSteady {
                    steady
                } else {
                    advance
                }
            }
        } trailing: {
            VStack(alignment: .leading, spacing: 10) {
                ChartCaption(text: isYear(period) ? "逐月所得" : "逐周所得")
                XPChart(c: c, play: play)
            }
        }
    }

    /// 境界与小阶都没变：一枚徽记 + 一句“这一年稳在「渡劫 · 大圆满」，累计 +17,511”（不再画两枚一样的徽记对照、也不再另起一行“仍在…”）
    private var steady: some View {
        let end = c.endState
        return HStack(alignment: .center, spacing: 16) {
            VStack(spacing: 4) {
                badge(end, glow: false)
                // 原先对照卡箭头上的“未破境”
                Text("稳在本境").font(.ysMicro).foregroundStyle(Theme.gold).fixedSize()
            }
            Text(c.steadyLine(unitLabel: period.unitLabel))
                .font(Theme.songti(TypeSize.body, .semibold)).tracking(0.5).foregroundStyle(Theme.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .modifier(MistPanel(scheme: scheme))
        .accessibilityElement(children: .combine)
    }

    /// 破境或本境升了小阶：期初 → 期末两枚徽记对照；破境下面逐条写破境日，本境进阶写一句“由「渡劫 · 中期」进到「渡劫 · 大圆满」”
    private var advance: some View {
        let start = c.startState, end = c.endState
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 0) {
                realm(start, caption: "期初 · 累计 \(RecordStats.grouped(c.startXP))", glow: false)
                VStack(spacing: 4) {
                    HStack(spacing: 0) {
                        Rectangle().fill(AnnalsFade.style(LinearGradient(colors: [Theme.gold.opacity(0.1), Theme.gold.opacity(0.8)], startPoint: .leading, endPoint: .trailing),
                                                          print: Theme.gold.opacity(0.6), printing: printing))
                            .frame(height: 1.2)
                        Image(systemName: "arrowtriangle.right.fill").font(.system(size: 8)).foregroundStyle(Theme.gold)
                    }
                    Text(c.breakthroughs.isEmpty ? c.advanceLabel : "破境 \(c.breakthroughs.count) 次").font(.ysMicro).foregroundStyle(Theme.gold)
                }
                .frame(minWidth: 50, maxWidth: 120)
                .padding(.horizontal, 10)
                .padding(.bottom, 26)
                realm(end, caption: "期末 · 累计 \(RecordStats.grouped(c.endXP))", glow: true)
            }
            // 期初 → 期末的境界放在一块淡雾底的格里，居中排（像一方题跋）
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .modifier(MistPanel(scheme: scheme))
            VStack(alignment: .leading, spacing: 9) {
                if c.breakthroughs.isEmpty {
                    AnnalsPoint(icon: "mountain.2", text: Text("由「") + Text(start.title) + Text("」进到「") + Text(end.title).foregroundStyle(Theme.precious) + Text("」"))
                }
                ForEach(c.breakthroughs.indices, id: \.self) { index in
                    let b = c.breakthroughs[index]
                    AnnalsPoint(icon: "bolt.fill", text: soft(b.day.shortLabel + " · ") + Text("破境入「") + Text(b.realm).foregroundStyle(Theme.precious) + Text("」"))
                }
            }
        }
    }

    /// 境界徽记（打印时栅格化）；glow 时底下一团呼吸金光
    private func badge(_ state: CultivationState, glow: Bool) -> some View {
        ZStack {
            if glow { BreathingGlow(size: 104) }
            RasterInPrint(size: CGSize(width: 80, height: 80)) {
                RealmBadge(state: state, size: 56, animated: animate).frame(width: 80, height: 80)
            }
        }
        .frame(width: 80, height: 80)
    }

    private func realm(_ state: CultivationState, caption: String, glow: Bool) -> some View {
        VStack(spacing: 8) {
            badge(state, glow: glow)
            VStack(spacing: 2) {
                Text(state.title).font(Theme.songti(TypeSize.callout, .semibold)).tracking(1).foregroundStyle(Theme.ink).lineLimit(1)
                Text(caption).font(.ysMicro).monospacedDigit().foregroundStyle(Theme.inkSoft).lineLimit(1)
            }
            .fixedSize()
        }
    }
}

/// 修为节那块淡雾底的格（像一方题跋）：没破境的一枚徽记、破境的两枚对照共用
private struct MistPanel: ViewModifier {
    var scheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .background(Theme.mist.opacity(scheme == .dark ? 0.55 : 0.5), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.gold.opacity(0.18)))
    }
}

private struct XPChart: View {
    var c: AnnalsReport.CultivationPart
    var play: Bool
    @Environment(\.annalsPrint) private var printing

    var body: some View {
        let labels = c.perBucket.map(\.bucket.label)
        let shown = Set(stride(from: 0, to: labels.count, by: labels.count > 9 ? 2 : 1).map { labels[$0] })
        let top = max(1, c.perBucket.map(\.xp).max() ?? 1)
        Growing(play: play) { grown in
            Chart(c.perBucket.indices, id: \.self) { index in
                let b = c.perBucket[index]
                BarMark(x: .value("时段", b.bucket.label), y: .value("修为", grown ? b.xp : 0), width: .ratio(0.55))
                    .foregroundStyle(AnnalsFade.style(LinearGradient(colors: [Theme.gold, Theme.gold.opacity(0.55)], startPoint: .top, endPoint: .bottom),
                                                      print: Theme.gold.opacity(0.85), printing: printing))
                    .cornerRadius(3)
            }
            .chartYScale(domain: 0...(Double(top) * 1.12))
            .chartXAxis {
                AxisMarks(values: labels) { value in
                    AxisValueLabel { if let l = value.as(String.self), shown.contains(l) { Text(l).font(.ysMicro) } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Theme.line.opacity(0.6))
                    AxisValueLabel { if let v = value.as(Int.self) { Text(RecordStats.grouped(v)).font(.ysMicro).monospacedDigit() } }
                }
            }
            .frame(height: 100)
        }
    }
}

// MARK: - 其五 · 灵石

private struct FinanceSection: View {
    var f: AnnalsReport.FinancePart
    var period: AnnalsPeriod
    var play: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.annalsPiece) private var piece

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AnnalsColumns {
                VStack(alignment: .leading, spacing: 12) {
                    LeadFigure(target: Double(f.netCents) / 100, play: play,
                               text: { v in abs(v - Double(f.netCents) / 100) < 1e-9 ? RecordStats.dollars(f.netCents) : RecordStats.dollars(Int((v * 100).rounded())) },
                               caption: f.manualOnly ? "净消费 · 仅手记" : "净消费", tint: Theme.ink)
                    HStack(spacing: 6) {
                        soft("扣款 ") + figure(RecordStats.dollars(f.spendCents), size: 14) + soft(" · 退款 ") + figure(RecordStats.dollars(f.refundCents), size: 14)
                    }
                    .font(.ysCallout)
                    if let c = f.comparison, let change = AnnalsReport.change(c.currentNetCents, from: c.previousNetCents) {
                        // 按几个整月比较只在节末那一行（f.remark）说一次；变化为 0 写“与去年同期持平”
                        AnnalsPoint(icon: "arrow.left.arrow.right",
                                    text: AnnalsReport.isFlat(change) ? Text(AnnalsReport.flatText(period.previousLabel))
                                        : Text("较\(period.previousLabel) ") + figure(change, size: 15))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ChartCaption(text: "逐月净消费")
                        MonthBars(f: f, play: play)
                    }
                    .padding(.top, 6)
                }
            } trailing: {
                VStack(alignment: .leading, spacing: 12) {
                    AnnalsSubheading(text: "主要类别", detail: f.otherCategories > 0 ? "其余 \(f.otherCategories) 类" : "")
                    ForEach(f.categories.indices, id: \.self) { index in
                        category(f.categories[index])
                    }
                }
            }
            if let remark = f.remark, piece != .leading {
                Hint(remark)
            }
        }
    }

    private func category(_ c: (name: String, cents: Int, change: Int?)) -> some View {
        let share = f.spendCents > 0 ? Double(c.cents) / Double(f.spendCents) : 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(AnnalsLedgerPalette.color(c.name)).frame(width: 7, height: 7)
                Text(c.name).font(.ysCallout).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: RecordStats.dollars(c.cents)).font(Theme.money(TypeSize.callout)).foregroundStyle(Theme.ink).fixedSize()
                Text(RecordStats.percent(share)).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft).frame(width: 36, alignment: .trailing)
            }
            ProgressBar(value: share, color: AnnalsLedgerPalette.color(c.name).opacity(scheme == .dark ? 0.8 : 1), height: 4, solid: true)
            if let change = c.change {
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    if AnnalsReport.isFlatCents(change) {
                        // 不到 50 分的差取整后是 $0：整行只写“与上一季持平”，不写“+$0”、也不上多花 / 少花的颜色（与导出同一判断）
                        Text(AnnalsReport.flatText(period.previousLabel)).font(.ysMicro).foregroundStyle(Theme.inkSoft)
                    } else {
                        Text("较\(period.previousLabel)").font(.ysMicro).foregroundStyle(Theme.inkSoft)
                        // 与灵石账簿“与上月比较”同一套颜色：多花朱砂、少花玉色
                        Text(verbatim: change > 0 ? "+" + RecordStats.dollars(change) : "−" + RecordStats.dollars(-change))
                            .font(Theme.money(TypeSize.caption, .semibold))
                            .foregroundStyle(AmountText.color(change, .change))
                    }
                }
            }
        }
    }
}

/// 逐月柱（季度也是逐月 3 根）：玉色；未导全的月份 0.35 透明、刻度下标“未导全”（与灵石账簿同一个说法）；本月刻度下标“至今”。
/// 只含手记的账簿不标、不变淡
private struct MonthBars: View {
    var f: AnnalsReport.FinancePart
    var play: Bool

    var body: some View {
        let months = f.months
        let top = max(1, months.map(\.netCents).max() ?? 1)
        let notes = Dictionary(uniqueKeysWithValues: months.map { m in
            (m.month, (label: m.label.replacingOccurrences(of: "（至今）", with: ""),
                       note: AnnalsReport.FinancePart.monthNote(full: m.full, ongoing: m.ongoing, manualOnly: f.manualOnly,
                                                                partial: FinanceHeadlineRule.partialLabel)))
        })
        Growing(play: play) { grown in
            Chart(months.indices, id: \.self) { index in
                let m = months[index]
                let faint = !m.full && !f.manualOnly
                BarMark(x: .value("月份", m.month), y: .value("净消费", grown ? Double(max(0, m.netCents)) / 100 : 0), width: .ratio(0.55))
                    .foregroundStyle(Theme.jade.opacity(faint ? 0.35 : 0.9))
                    .cornerRadius(3)
            }
            .chartYScale(domain: 0...(Double(top) / 100 * 1.12))
            .chartXAxis {
                AxisMarks(values: months.map(\.month)) { value in
                    AxisValueLabel {
                        if let key = value.as(String.self), let n = notes[key] {
                            VStack(spacing: 1) {
                                Text(n.label).font(.ysMicro)
                                if !n.note.isEmpty { Text(n.note).font(.system(size: 9)).foregroundStyle(Theme.inkSoft.opacity(0.8)) }
                            }
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Theme.line.opacity(0.6))
                    AxisValueLabel { if let v = value.as(Double.self) { Text("$" + RecordStats.grouped(Int(v))).font(.ysMicro).monospacedDigit() } }
                }
            }
            .frame(height: 140)
        }
    }
}

/// 账簿的类别配色：照灵石账簿 FinanceView 里私有的 LedgerPalette 原样另抄一份（那边正被别的改动占着，不去改它）。
/// 12 个消费类各一种低饱和色（不用朱砂），“消费之外”一律灰
private enum AnnalsLedgerPalette {
    private static let table: [String: Color] = [
        "餐饮与外卖": .adaptive(light: 0x9A6B4F, dark: 0xD4AE92),
        "超市与食品": .adaptive(light: 0x5E7D3A, dark: 0xB2CC8E),
        "交通出行": .adaptive(light: 0x4C6E8E, dark: 0x93B3CF),
        "通讯与网络": .adaptive(light: 0x3F7E8E, dark: 0x8CC5D2),
        "软件与会员": .adaptive(light: 0x7D5C7E, dark: 0xC4A3C5),
        "教育与学费": .adaptive(light: 0x9B7951, dark: 0xD2B682),
        "购物": .adaptive(light: 0x9C6B7A, dark: 0xD3A9B6),
        "健康与健身": .adaptive(light: 0x427560, dark: 0xA3C5AE),
        "娱乐": .adaptive(light: 0x5A5F8E, dark: 0xA9AED6),
        "彩票": .adaptive(light: 0x8A7A3C, dark: 0xCDBF85),
        "银行手续费": .adaptive(light: 0x7A6A55, dark: 0xBCAA90),
        "待分类消费": .adaptive(light: 0x6F7F86, dark: 0xA8B7BD),
    ]

    static func color(_ category: String) -> Color {
        if FinanceEngine.nonSpend.contains(category) { return Theme.inkSoft }
        return table[category] ?? Theme.color(for: category)
    }
}

// MARK: - 其六 · 珍藏与长篇

private struct HighlightsSection: View {
    var h: AnnalsReport.Highlights
    var onRead: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !h.pinned.isEmpty {
                HighlightGroup(title: "珍藏", entries: h.pinned, more: h.pinnedMore, onRead: onRead)
            }
            if !h.longest.isEmpty {
                HighlightGroup(title: "最长的日记", entries: h.longest, more: 0, onRead: onRead)
            }
        }
    }
}

/// 一组篇目卡（珍藏 / 最长的日记）。title 为 nil：PDF 里接着上一块的后半组
private struct HighlightGroup: View {
    var title: String?
    var entries: [RecordEntry]
    var more: Int
    var onRead: (String) -> Void
    @Environment(\.annalsPrint) private var printing

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                AnnalsSubheading(text: title, detail: title == "珍藏" ? "\(entries.count + more) 篇" : "不含珍藏 · 按字数")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: printing ? 220 : 260), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(entries, id: \.uid) { entry in
                    HighlightCard(entry: entry, onRead: onRead)
                }
            }
            if more > 0 {
                Hint("另有 \(more) 篇珍藏，在修行录「珍藏」里看全部", symbol: "bookmark")
            }
        }
    }
}

/// 一篇的卡片：类型图标 + 日期星期 + 心境；标题；摘录 3 行；字数；珍藏的右下角一枚金色方印“珍”。点开只读阅读
private struct HighlightCard: View {
    var entry: RecordEntry
    var onRead: (String) -> Void
    @Environment(\.annalsPrint) private var printing

    var body: some View {
        if printing {
            card
        } else {
            Button { onRead(entry.uid) } label: { card }
                .buttonStyle(.plain)
                .help("只读打开这一篇")
                .accessibilityHint("只读打开这一篇")
        }
    }

    /// 有标题：宋体标题 + 摘录 3 行；无标题：直接摘录 4 行（标题本来就是正文开头，不把同一句话写两遍）
    private var titled: Bool { !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: entry.kind.symbol).font(.system(size: TypeSize.caption, weight: .semibold)).foregroundStyle(entry.kind.color)
                Text(verbatim: "\(entry.day.shortLabel) \(entry.day.weekdayName)").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                Spacer(minLength: 4)
                if let mood = entry.mood {
                    Image(systemName: Mood.symbol(mood)).font(.ysCaption).foregroundStyle(Theme.gold)
                        .help("心境「\(Mood.label(mood))」")
                }
            }
            if titled {
                Text(verbatim: entry.displayTitle)
                    .font(Theme.songti(15, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            let excerpt = entry.excerpt.isEmpty && !titled ? entry.displayTitle : entry.excerpt
            if !excerpt.isEmpty {
                Text(verbatim: excerpt)
                    .font(titled ? .ysCallout : Theme.songti(TypeSize.body))
                    .lineSpacing(titled ? 3 : 4)
                    .foregroundStyle(titled ? Theme.text : Theme.ink)
                    .lineLimit(titled ? 3 : 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                Text("\(RecordStats.grouped(entry.chars)) 字").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                Spacer(minLength: 0)
                if entry.pinned { TreasureMark() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 128, maxHeight: .infinity, alignment: .topLeading)
        .slipCard(padding: 16, interactive: !printing)
        .contentShape(Rectangle())
    }
}

/// 珍藏的金色方印“珍”（18 pt）
private struct TreasureMark: View {
    var body: some View {
        Text("珍")
            .font(Theme.songti(11, .heavy))
            .foregroundStyle(Theme.onJade)
            .frame(width: 18, height: 18)
            .background(Theme.gold, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Theme.onJade.opacity(0.7), lineWidth: 0.6).padding(1.5))
            .rotationEffect(.degrees(-4))
            .accessibilityLabel("珍藏")
    }
}

// MARK: - 其七 · 洞见

private struct InsightsSection: View {
    var insights: [Insight]
    var play: Bool
    /// PDF 里接着上一块的后几条时不再写说明
    var showNote = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showNote {
                Text("只做统计，不代表因果；样本不够的不列。").font(.ysCaption).foregroundStyle(Theme.inkSoft)
            }
            if insights.isEmpty {
                Hint("这段时间的记录还不够看出规律：每条洞见都要十来天以上的样本。")
            } else {
                ForEach(insights.indices, id: \.self) { index in
                    InsightLine(insight: insights[index])
                        .insightLight(play, index: index)
                }
            }
        }
    }
}

private struct InsightLine: View {
    var insight: Insight
    @Environment(\.colorScheme) private var scheme

    private var color: Color {
        switch insight.tone {
        case .mood: Theme.precious
        case .habit: Theme.positive
        case .spend: Theme.info
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.13))
                Circle().strokeBorder(color.opacity(0.35), lineWidth: 0.8)
                Image(systemName: insight.symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.text).font(.ysBody).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                Text(insight.basis).font(.ysCaption).foregroundStyle(Theme.inkSoft)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.mist.opacity(scheme == .dark ? 0.55 : 0.5), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 卷尾

/// 卷尾：一道金线收束，居中一枚 2×2 朱印“岁月 / 成卷”（E6 落款），右侧“辑于 … · 云山修习录”
struct AnnalsColophon: View {
    var report: AnnalsReport
    var play: Bool
    @Environment(\.annalsPrint) private var printing

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 10) {
                Rectangle().fill(AnnalsFade.style(LinearGradient(colors: [.clear, Theme.gold.opacity(0.5)], startPoint: .leading, endPoint: .trailing),
                                                  print: Theme.gold.opacity(0.35), printing: printing)).frame(height: 1)
                Image(systemName: "diamond.fill").font(.system(size: 6)).foregroundStyle(Theme.gold.opacity(0.8))
                Rectangle().fill(AnnalsFade.style(LinearGradient(colors: [Theme.gold.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing),
                                                  print: Theme.gold.opacity(0.35), printing: printing)).frame(height: 1)
            }
            .frame(maxWidth: 320)
            .accessibilityHidden(true)
            HStack(alignment: .center, spacing: 18) {
                LandingSeal(play: play, size: 70)
                Text(verbatim: "辑于 \(report.today.year)年\(report.today.shortLabel) · 云山修习录")
                    .font(Theme.songti(TypeSize.caption, .medium))
                    .tracking(1)
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
