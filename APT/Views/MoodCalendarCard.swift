import SwiftUI

// MARK: - 心境月历（#15）

@MainActor
extension JournalDigest.Snapshot {
    /// 最早一篇的日期：摘要按新的在前排好、日期都规范时（ordered）就是最后一行，否则走一遍取最小
    var earliestDay: LocalDay? {
        ordered ? rows.last?.day : rows.lazy.compactMap(\.day).min()
    }

    /// 心境月历的一个月：只借摘要里已缓存的（日期键、心境），日期规范时越过这个月就停
    func moodMonth(year: Int, month: Int, today: LocalDay) -> MoodCalendar.Month {
        MoodCalendar.month(year: year, month: month, today: today, earliest: earliestDay,
                           entries: rows.lazy.map { ($0.dateKey, $0.mood) }, newestFirst: ordered)
    }
}

/// 心境月历：修行录左栏、卷中气象之后。一月一张，七列（一 … 日），每天一格：
/// 记了心境的按当天日记心境的平均上淡金（越晴越亮，与七日小卷“心境七日”同一套金色，不用朱砂）；
/// 写了没记心境的格里一个墨点；没写的只描极淡的边；今天金色细框；还没到的日子不画。
/// 点写过的一格 → 时间线只看那天（修行录原有的“只看某一天”筛选），再点同一格或筛选行的 × 回到全部。
/// 标题右侧“‹ 10月 ›”翻月，早于第一篇的月份翻不过去，点中间的月份回到本月；悬停一格，卡底那行换成那天的心境与篇数。
/// 只依赖修行录摘要和正看的那一天：搜索打字、展开条目时不重算。
struct MoodCalendarCard: View, Equatable {
    var digest: JournalDigest.Snapshot
    /// 时间线正“只看”的那一天（修行录页的 day 筛选，往日回看“查看当天全部”设的也算）
    var selected: String?
    /// 点了一格：那天的日期键；再点同一格传 nil（回到全部）
    var onPick: (String?) -> Void

    static func == (a: Self, b: Self) -> Bool { a.digest == b.digest && a.selected == b.selected }

    @Environment(\.spiritMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 正看的月份（年 × 12 + 月 − 1）；nil 是本月
    @State private var shownIndex: Int?
    /// 鼠标停在哪一格（卡底那行换成这一天）
    @State private var hovered: LocalDay?
    /// 翻月方向：往后翻新的一月从右边滑入，往前翻从左边
    @State private var forward = true

    static let tile: CGFloat = 24
    private static let rowGap: CGFloat = 6
    private var animate: Bool { motion && !reduceMotion }

    var body: some View {
        let today = LocalDay.today()
        let index = shownIndex ?? Self.index(today)
        let month = digest.moodMonth(year: index / 12, month: index % 12 + 1, today: today)
        VStack(alignment: .leading, spacing: 12) {
            MoodCalendarHeader(month: month, today: today, onStep: { go($0, from: month) }, onHome: { backToCurrent(month) })
            // 新旧两个月叠在一处交替淡入淡出，卡片不会在翻月的那一下拉高成两份
            ZStack(alignment: .top) {
                grid(month)
                    .id(month.key)
                    .transition(animate ? .asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 14 : -14)),
                                                      removal: .opacity) : .identity)
            }
            .frame(maxWidth: .infinity)
            footer(month)
        }
        .xianCard()
        .onAppear { follow(selected, today: today) }
        .onChange(of: selected) { _, key in follow(key, today: .today()) }
    }

    private static func index(_ day: LocalDay) -> Int { day.year * 12 + day.month - 1 }

    /// 自检用：只画标题行（套同样的卡片外框、同样宽），量翻到往年月份时卡头是否仍与本月一样高
    static func headerProbe(_ month: MoodCalendar.Month, today: LocalDay) -> some View {
        MoodCalendarHeader(month: month, today: today, onStep: { _ in }, onHome: {}).xianCard()
    }

    // MARK: 翻月

    /// 点中间的月份回到本月（本月时点了不动）
    private func backToCurrent(_ month: MoodCalendar.Month) {
        guard !month.isCurrent else { return }
        forward = true
        withAnimation(animate ? Motion.standard : nil) {
            shownIndex = nil
            hovered = nil
        }
    }

    private func go(_ step: Int, from month: MoodCalendar.Month) {
        let target = MoodCalendar.shift(year: month.year, month: month.month, by: step)
        let today = LocalDay.today()
        let value = target.year * 12 + target.month - 1
        forward = step > 0
        withAnimation(animate ? Motion.standard : nil) {
            shownIndex = value == Self.index(today) ? nil : value
            hovered = nil
        }
    }

    /// 时间线改成只看某一天（例如往日回看里“查看当天全部”）而那天不在正看的月份：翻到那个月，格子上看得到选中的是哪天
    private func follow(_ key: String?, today: LocalDay) {
        guard let key, let day = LocalDay(key: key), day <= today else { return }
        let target = Self.index(day)
        guard target != (shownIndex ?? Self.index(today)) else { return }
        forward = target > (shownIndex ?? Self.index(today))
        withAnimation(animate ? Motion.standard : nil) {
            shownIndex = target == Self.index(today) ? nil : target
        }
    }

    // MARK: 格子

    private func grid(_ month: MoodCalendar.Month) -> some View {
        VStack(spacing: Self.rowGap) {
            HStack(spacing: 0) {
                ForEach(LocalDay.weekdayShortNames, id: \.self) { name in
                    Text(name).font(.ysMicro).foregroundStyle(Theme.inkSoft).frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            ForEach(Array(month.weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(0 ..< 7, id: \.self) { column in
                        Group {
                            if let cell = week[column], cell.mark != .future {
                                MoodDayTile(cell: cell, selected: cell.day.key == selected, animate: animate,
                                            onHover: { inside in
                                                if inside { hovered = cell.day } else if hovered == cell.day { hovered = nil }
                                            },
                                            onTap: { onPick(MoodCalendar.toggled(selected: selected, tapped: cell.day.key)) })
                            } else {
                                Color.clear.frame(width: Self.tile, height: Self.tile)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: 卡底

    /// 平时是图例；悬停一格时换成那天的心境与篇数（同一行，卡片不跳）；这个月一篇没有时上面多一行说明
    private func footer(_ month: MoodCalendar.Month) -> some View {
        let cell = hovered.flatMap { day in month.cells.first { $0.day == day } }
        return VStack(alignment: .leading, spacing: 8) {
            if let note = month.emptyNote {
                Text(note).font(.ysCaption).foregroundStyle(Theme.inkSoft)
            }
            ZStack(alignment: .leading) {
                legend.opacity(cell == nil ? 1 : 0)
                if let cell {
                    hoverLine(cell).transition(.opacity)
                }
            }
            .animation(animate ? Motion.hover : nil, value: cell?.day)
        }
    }

    private var legend: some View {
        HStack(spacing: 6) {
            ForEach(1 ... 5, id: \.self) { level in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(MoodDayTile.fill(level))
                        .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Theme.gold.opacity(0.35), lineWidth: 0.5))
                        .frame(width: 9, height: 9)
                    Text(Mood.label(level))
                }
            }
            Text("·")
            Text(MoodCalendar.legendNote).lineLimit(1)
        }
        .font(.ysMicro)
        .foregroundStyle(Theme.inkSoft)
        .accessibilityElement(children: .combine)
    }

    private func hoverLine(_ cell: MoodCalendar.Cell) -> some View {
        HStack(spacing: 5) {
            if case .mood(let value) = cell.mark {
                Image(systemName: Mood.symbol(value)).foregroundStyle(Theme.gold)
            } else if cell.mark == .ink {
                Circle().fill(Theme.ink.opacity(0.65)).frame(width: 4, height: 4)
            }
            Text(cell.hint).foregroundStyle(Theme.ink).monospacedDigit().lineLimit(1)
            Spacer(minLength: 6)
            // 正只看的那天即使篇目已删光（格子空了）也写“再点回到全部”
            if let action = cell.tapHint(selected: selected) {
                Text(action)
                    .foregroundStyle(Theme.precious)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(.ysMicro)
    }
}

/// 标题行：“心境月历 落笔 12 日”与右侧“‹ 10月 ›”。侧栏卡内只有 272pt 宽：往年的月份翻月器写“2025年12月”，
/// 标题旁就只写“30 日”、箭头 18 宽，整行仍是一行，翻月时卡头不变高、卡片不跳（自检用 headerProbe 量高度）
private struct MoodCalendarHeader: View {
    var month: MoodCalendar.Month
    var today: LocalDay
    var onStep: (Int) -> Void
    var onHome: () -> Void

    var body: some View {
        CardTitle(title: "心境月历", detail: month.titleDetail(today: today),
                  hint: "每天一格，按当天日记的心境上色；点一天，时间线只看那天") {
            HStack(spacing: 0) {
                arrow("chevron.left", label: "上个月", enabled: month.canGoBack) { onStep(-1) }
                // 本月时点了不动（不置灰：月份字要看得清）
                Button(action: onHome) {
                    Text(verbatim: MonthKey.label(year: month.year, month: month.month, relativeTo: today))
                        .font(.system(size: TypeSize.caption, weight: .semibold).monospacedDigit())
                        .foregroundStyle(month.isCurrent ? Theme.ink : Theme.precious)
                        .fixedSize()
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(month.isCurrent ? "本月" : "回到本月")
                .accessibilityLabel(month.isCurrent ? "本月" : "回到本月")
                arrow("chevron.right", label: "下个月", enabled: month.canGoForward) { onStep(1) }
            }
        }
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: TypeSize.caption, weight: .semibold))
                .frame(width: 18, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.inkSoft.opacity(enabled ? 1 : 0.3))
        .disabled(!enabled)
        .help(enabled ? label : (symbol == "chevron.left" ? "再往前没有落笔了" : "已是本月"))
        .accessibilityLabel(label)
    }
}

/// 月历的一格：日子数字在中间；心境按平均上淡金（越晴越亮），写了没记心境的数字下一个墨点，没写的只描极淡的边。
/// 今天金色细框（静态）；时间线正只看这天时外面一圈玉色（那天的篇目删光、格子空了也照样点得动，再点回到全部）。
/// 悬停点得动的那格微微放大、衬一团金光（关动效时只描金边，不放大）；点不动的空格读屏不当按钮念。
private struct MoodDayTile: View {
    var cell: MoodCalendar.Cell
    var selected: Bool
    var animate: Bool
    var onHover: (Bool) -> Void
    var onTap: () -> Void
    @State private var hovering = false

    private static let radius: CGFloat = 6
    /// 压在较亮金底（晴、霁）上的数字：浅色仍是墨色，深色下金底发亮，换深墨
    private static let onBright = Color.adaptive(light: 0x24493D, dark: 0x0E191B)

    /// 心境的金底：雨最淡、霁最亮
    static func fill(_ level: Int) -> Color { Theme.gold.opacity(0.1 + 0.17 * Double(max(1, min(5, level)) - 1)) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let active = cell.tappable || selected
        let lit = hovering && active
        Button {
            if active { onTap() }
        } label: {
            ZStack {
                switch cell.mark {
                case .mood(let level):
                    shape.fill(Self.fill(level))
                    shape.strokeBorder(Theme.gold.opacity(0.3), lineWidth: 0.5)
                case .ink:
                    shape.fill(Theme.mist.opacity(0.75))
                    shape.strokeBorder(Theme.line, lineWidth: 0.75)
                case .blank, .future:
                    shape.strokeBorder(Theme.line.opacity(0.75), lineWidth: 0.75)
                }
                Text("\(cell.day.day)")
                    .font(.system(size: TypeSize.micro, weight: cell.isToday || selected ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(numberColor)
                    .offset(y: cell.mark == .ink ? -3 : 0)
                if cell.mark == .ink {
                    Circle().fill(Theme.ink.opacity(0.65)).frame(width: 3.5, height: 3.5).offset(y: 6)
                }
            }
            .frame(width: MoodCalendarCard.tile, height: MoodCalendarCard.tile)
            .overlay {
                if cell.isToday { shape.strokeBorder(Theme.gold, lineWidth: 1.2) }
            }
            .overlay {
                // 悬停：金边（关动效时也有，只是不放大、不衬光）
                shape.strokeBorder(Theme.gold.opacity(0.8), lineWidth: 1).opacity(lit && !cell.isToday ? 1 : 0)
            }
            .background {
                if animate {
                    SoftGlow(color: Theme.gold.opacity(0.35)).frame(width: 46, height: 46).opacity(lit ? 1 : 0)
                }
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Self.radius + 2.5, style: .continuous)
                        .strokeBorder(Theme.jade, lineWidth: 1.6)
                        .padding(-3)
                }
            }
            .scaleEffect(lit && animate ? 1.14 : 1)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
        .animation(animate ? Motion.hover : nil, value: lit)
        .help(selected ? "\(cell.hint)\n再点一下回到全部" : (cell.tappable ? "\(cell.hint)\n点一下，时间线只看这天" : cell.hint))
        .accessibilityLabel(cell.hint + (selected ? "，时间线正只看这天" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityRemoveTraits(active ? [] : .isButton)
    }

    private var numberColor: Color {
        switch cell.mark {
        case .mood(let level): level >= 4 ? Self.onBright : Theme.ink
        case .ink: Theme.ink
        case .blank, .future: Theme.inkSoft.opacity(cell.isToday ? 1 : 0.75)
        }
    }
}
