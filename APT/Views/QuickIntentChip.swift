import SwiftUI

/// 随手记“随心”的预览签：正文框下一行，说这句话将记到哪里——
/// 左边一枚那一页的小物，第一行“此句将入 · 灵石账簿”，第二行“餐饮与外卖 · $18.50 · 今天”（记账时类别是可点的小签）。
/// 悬停整签看依据（“认出：金额 18.5，“午饭”→ 餐饮与外卖”）；认错了点“不对？改作 ▾”，展开一排胶囊一键换类型，
/// 选了就锁定这一句（签上写“已改作”），清空正文才回到自动。正文空着时是一句说明，签的高度不变，浮窗不跳。
/// 右上一枚日期签“今天 ⌄”：今天 / 昨天 / 前天 / 选日…，选了就覆盖句中写的日子（正文空着时也能先选好再写）。
struct QuickIntentChip: View {
    /// 认出的结果；nil 表示正文还空着
    var result: QuickParse.Result?
    /// 认句子时用的功课（改作打卡时列出来）
    var habits: [QuickParse.Habit]
    /// 记账时改过的类别（nil 用认出的）
    var category: String?
    /// 动效开关（浮窗拿不到主窗口的环境值，由随手记传进来）
    var motion: Bool
    var onCategory: (String) -> Void
    /// 选定一种类型；nil 是回到自动认
    var onChoose: (QuickParse.Choice?) -> Void
    /// 日期签上选定的那天（nil：按句中写的日子）
    var pinnedDay: LocalDay? = nil
    /// 选定 / 清除（nil）日期签；不给时不显示日期签
    var onPinDay: ((LocalDay?) -> Void)? = nil

    @State private var choosing = false
    @State private var dayOpen = false
    /// 日期签弹出的是月历（点了“选日…”）
    @State private var dayCalendar = false
    @State private var hovering = false
    @State private var categoryOpen = false
    @State private var habitOpen = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.control, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                SceneryImage(name: "yunshan-ornament-\(result?.intent.ornament ?? "brush")-v1")
                    .frame(width: 18, height: 18)
                    .opacity(result == nil ? 0.45 : 1)
                    .padding(.top, 1)
                    .id(result?.intent.ornament ?? "brush")
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(result?.headline ?? "随心 · 写一句，自会认出记到哪里")
                            .font(.system(size: TypeSize.caption, weight: .semibold))
                            .foregroundStyle(result == nil ? Theme.inkSoft : Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if onPinDay != nil { daySign }
                        if result != nil { changeButton }
                    }
                    detailLine
                    if let result, let line = result.problem ?? result.notice {
                        Label(line, systemImage: result.problem == nil ? "info.circle" : "exclamationmark.triangle")
                            .font(.ysCaption)
                            .foregroundStyle(result.problem == nil ? Theme.inkSoft : Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if choosing, let result { choices(result) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper.opacity(0.55), in: shape)
        .overlay(shape.strokeBorder(hovering && result != nil ? Theme.gold.opacity(0.55) : Theme.line.opacity(0.8)))
        .contentShape(shape)
        .onHover { inside in
            if motion { withAnimation(Motion.hover) { hovering = inside } } else { hovering = inside }
        }
        .help(result?.evidence ?? "")
        .animation(motion ? Motion.quick : nil, value: result?.intent)
        .animation(motion ? Motion.standard : nil, value: choosing)
        .onChange(of: result == nil) { _, empty in if empty { choosing = false } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(result.map { "\($0.headline)，\($0.detail)" } ?? "随心：写一句，自会认出记到哪里")
    }

    /// 第二行：记账时类别是可点的小签；正文空着时列出能认的五类
    @ViewBuilder
    private var detailLine: some View {
        if let result {
            if result.intent == .expense, let e = result.expense {
                HStack(spacing: 6) {
                    categoryChip(category ?? e.category)
                    Text("· \(FinanceEngine.money(e.cents)) · \(QuickParse.dayPhrase(e.day, today: result.today))")
                        .font(.ysCaption).monospacedDigit().foregroundStyle(Theme.ink).lineLimit(1)
                }
            } else {
                Text(result.detail)
                    .font(.ysCaption).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("日记 · 灵感 · 记账 · 打卡 · 日程，认不准时记成日记")
                .font(.ysCaption).foregroundStyle(Theme.inkSoft.opacity(0.8)).lineLimit(1)
        }
    }

    private var changeButton: some View {
        Button {
            if motion { withAnimation(Motion.standard) { choosing.toggle() } } else { choosing.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text(choosing ? "收起" : "不对？改作")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(choosing ? 180 : 0))
            }
        }
        .buttonStyle(.inlineAction(Theme.inkSoft))
        .fixedSize()
        .help("认错了？换成日记、灵感、记账、打卡或日程")
    }

    // MARK: 日期签

    private var signToday: LocalDay { result?.today ?? .today() }
    /// 签上写的那天：选定的；没选按这句认出的日子
    private var signDay: LocalDay { pinnedDay ?? result?.recordDay ?? signToday }

    private var daySign: some View {
        let pinned = pinnedDay != nil
        let label = QuickParse.daySignLabel(signDay, today: signToday)
        // 悬停与读屏补上日子本身（签上写的已经是日子时不再重复；不是今年的带年份）
        let full = signDay.label(relativeTo: signToday)
        let spelled = label == full ? label : "\(label)（\(full)）"
        return Button {
            dayCalendar = false
            dayOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar").font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(pinned ? Theme.jade : Theme.inkSoft)
                Text(label).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Theme.inkSoft)
            }
            .font(.system(size: TypeSize.caption, weight: pinned ? .semibold : .medium))
            .monospacedDigit()
            .foregroundStyle(pinned ? Theme.jade : Theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            // 选定了：淡玉底、玉色细边，一眼看出这条不记在今天
            .background(Capsule().fill(pinned ? Theme.jade.opacity(0.1) : Theme.card))
            .overlay(Capsule().strokeBorder(dayOpen ? Theme.gold.opacity(0.7) : (pinned ? Theme.jade.opacity(0.45) : Theme.line)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(pinned ? "已选定记在\(spelled)；点开改日子，或回到按句中日期"
                     : "这句记在哪一天：补记昨天、前天或选一天，日记、记账、打卡都按这天记，日程按这天的钟点")
        .popover(isPresented: $dayOpen, arrowEdge: .bottom) { dayMenu }
        .accessibilityLabel("记在\(spelled)")
    }

    @ViewBuilder
    private var dayMenu: some View {
        if dayCalendar {
            MonthCalendar(selection: Binding(get: { signDay }, set: { pin($0) })) { dayOpen = false }
        } else {
            let near = [0, -1, -2].map { signToday.adding(days: $0) }
            let far = pinnedDay.flatMap { near.contains($0) ? nil : $0 }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(near, id: \.self) { day in
                    dayRow(QuickParse.daySignLabel(day, today: signToday), detail: "\(day.label(relativeTo: signToday)) \(day.weekdayName)", on: pinnedDay == day) {
                        pin(day)
                        dayOpen = false
                    }
                }
                dayRow("选日…", detail: far.map { "\($0.label(relativeTo: signToday)) \($0.weekdayName)" } ?? "月历", on: far != nil) {
                    dayCalendar = true
                }
                if pinnedDay != nil {
                    Divider().padding(.vertical, 4)
                    dayRow("按句中日期", detail: "不指定", on: false) {
                        onPinDay?(nil)
                        dayOpen = false
                    }
                    .help("回到按这句话里写的日子认（没写就是今天）")
                }
            }
            .padding(8)
            .frame(minWidth: 210)
            .fixedSize()
            .background(Theme.card)
        }
    }

    private func pin(_ day: LocalDay) { onPinDay?(day) }

    /// 日期签弹出的一行（样式同改作打卡的功课列表）
    private func dayRow(_ title: String, detail: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: TypeSize.callout, weight: on ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 12)
                Text(detail)
                    .font(.system(size: TypeSize.micro)).monospacedDigit()
                    .foregroundStyle(on ? Theme.onJadeFill.opacity(0.8) : Theme.inkSoft)
            }
            .foregroundStyle(on ? Theme.onJadeFill : Theme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(on ? AnyShapeStyle(Theme.jadeFill) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 改作

    private func choices(_ result: QuickParse.Result) -> some View {
        let options: [QuickParse.Intent] = [.diary, .note, .expense, .checkin, .event]
        return HStack(spacing: 6) {
            if result.chosen {
                FilterChip(text: "自动认", on: false) { pick(nil) }
                    .help("回到自动认")
            }
            ForEach(options, id: \.self) { intent in
                let on = result.intent == intent
                let enabled = on || result.alternatives.contains(intent)
                if intent == .checkin {
                    FilterChip(text: "打卡 ▾", on: on) { habitOpen.toggle() }
                        .disabled(!enabled)
                        .opacity(enabled ? 1 : 0.4)
                        .popover(isPresented: $habitOpen, arrowEdge: .bottom) { habitList(result) }
                        .help(enabled ? "选一项功课打卡" : "还没有功课")
                } else {
                    FilterChip(text: intent.label, on: on) {
                        switch intent {
                        case .diary: pick(.diary)
                        case .note: pick(.note)
                        case .expense: pick(.expense)
                        case .event: pick(.event)
                        default: break
                        }
                    }
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.4)
                    .help(enabled ? "改作\(intent.label)" : (intent == .expense ? "这句里没有金额" : "这句里没有日期或钟点"))
                }
            }
            Spacer(minLength: 0)
        }
        .transition(.opacity)
    }

    private func pick(_ choice: QuickParse.Choice?) {
        habitOpen = false
        if motion { withAnimation(Motion.standard) { choosing = false } } else { choosing = false }
        onChoose(choice)
    }

    /// 改作打卡：列出功课（可能的那项排在最前），那天已圆满的只打卡功课不能再点（再点就是取消）。
    /// 日期签选了以前的日子时，列的是那天的进度
    private func habitList(_ result: QuickParse.Result) -> some View {
        let today = result.checkin?.day ?? pinnedDay.map { min($0, result.today) } ?? result.today
        let isToday = today == result.today
        var order = Array(habits.indices)
        if let s = result.suggestedHabit, let i = order.firstIndex(of: s) { order.insert(order.remove(at: i), at: 0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(order, id: \.self) { index in
                    let habit = habits[index]
                    let state = habit.days[today]
                    let done = state?.done ?? false
                    let blocked = done && !habit.isQuantity
                    let on = result.intent == .checkin && result.checkin?.habit == index
                    Button { pick(.checkin(habit.title)) } label: {
                        HStack(spacing: 8) {
                            Text(habit.title).font(.system(size: TypeSize.callout, weight: on ? .semibold : .regular)).lineLimit(1)
                            Spacer(minLength: 12)
                            Text(progress(habit, state, isToday: isToday))
                                .font(.system(size: TypeSize.micro)).monospacedDigit()
                                .foregroundStyle(on ? Theme.onJadeFill.opacity(0.8) : Theme.inkSoft)
                        }
                        .foregroundStyle(on ? Theme.onJadeFill : Theme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(on ? AnyShapeStyle(Theme.jadeFill) : AnyShapeStyle(Color.clear),
                                    in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(blocked)
                    .opacity(blocked ? 0.45 : 1)
                    .help(blocked ? (isToday ? "今日已圆满" : "\(today.shortLabel)已圆满") : "给「\(habit.title)」打卡")
                }
            }
            .padding(8)
        }
        .frame(minWidth: 220, maxHeight: 320)
        .fixedSize(horizontal: true, vertical: habits.count <= 8)
        .background(Theme.card)
    }

    private func progress(_ habit: QuickParse.Habit, _ state: QuickParse.DayState?, isToday: Bool) -> String {
        if state?.done == true { return isToday ? "今日已圆满" : "已圆满" }
        guard let target = habit.target, habit.isQuantity else { return "未打卡" }
        let unit = habit.unit.isEmpty ? "" : " \(habit.unit)"
        return "\(QuickParse.number(state?.quantity ?? 0))/\(QuickParse.number(target))\(unit)"
    }

    /// 记账的类别小签：点开换类别（与“手记一笔”同一套消费类别）
    private func categoryChip(_ current: String) -> some View {
        Button { categoryOpen.toggle() } label: {
            HStack(spacing: 4) {
                Text(QuickParse.categoryLabel(current))
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Theme.inkSoft)
            }
            .font(.system(size: TypeSize.caption, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(categoryOpen ? Theme.gold.opacity(0.7) : Theme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("换类别")
        .popover(isPresented: $categoryOpen, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(FinanceEngine.spendCategories, id: \.self) { option in
                        let on = option == current
                        Button {
                            onCategory(option)
                            categoryOpen = false
                        } label: {
                            HStack(spacing: 8) {
                                Text(option).font(.system(size: TypeSize.callout, weight: on ? .semibold : .regular))
                                Spacer(minLength: 12)
                                if on { Image(systemName: "checkmark").font(.system(size: TypeSize.micro, weight: .bold)) }
                            }
                            .foregroundStyle(on ? Theme.onJadeFill : Theme.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(on ? AnyShapeStyle(Theme.jadeFill) : AnyShapeStyle(Color.clear),
                                        in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .frame(minWidth: 200, maxHeight: 360)
            .background(Theme.card)
        }
    }
}
