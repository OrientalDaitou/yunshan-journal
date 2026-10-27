import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// 习惯打卡圈：今日洞府的功课卡、功课列表、功课详情共用，几处行为一致。
/// 点击时再取“今天”（页面停在昨天也不会把打卡记到昨天）；数量型习惯这天已记了未达标的数量时，
/// 不把真实数量改写成目标值，而是弹出数量输入（这时并没有打卡，不放打卡灵光）；否则切换打卡。
/// 调用方已算好这个习惯的统计时用 init(habit:stats:…)：达标与否、要不要弹数量输入都从统计里取，body 里不再扫打卡。
struct HabitCheckIn: View {
    /// 键盘打卡（功课页按空格）：每按一次是一个新的请求，只交给那一项的打卡圈
    struct Request: Equatable {
        var habit: PersistentIdentifier
        var id = UUID()
    }

    var habit: Habit
    /// 今天是否已达标（调用方已算好的统计）
    var done: Bool
    /// 今天点圈时是否要弹数量输入（调用方已算好时传入）；nil 时由打卡圈自己查这个习惯今天的打卡
    var needsInput: Bool? = nil
    var size: CGFloat = 26
    var allHabits: [Habit]
    var config: CultivationConfig
    /// 数量输入从哪一侧弹出
    var arrowEdge: Edge = .trailing
    /// 直接切换了打卡之后调用（详情页用它回填数量框）
    var onToggled: (LocalDay) -> Void = { _ in }
    /// 键盘打卡的请求（与点一下打卡圈相同）；换成新的请求时打一次
    var request: Request? = nil
    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    /// 打开数量输入的那一天
    @State private var quantityDay: LocalDay?

    var body: some View {
        // 调用方没算好时按日期直接取今天的打卡（不读 habit.logs：保存、重新取习惯之后打卡关系是冷的，读一次要把这个习惯的打卡逐条补回来）
        CheckInButton(done: done, size: size,
                      animated: effects.motionEnabled && !(needsInput ?? HabitQuantity.needsInput(habit, on: .today(), context: context)),
                      keyPress: request?.id, action: tap)
        // 数量型：右键“记数量…”直接弹出数量输入（点圈仍是记满；想记“3 杯”不必翻到功课页）
        .modifier(QuantityMenu(enabled: (habit.targetValue ?? 0) > 0) {
            // 等右键菜单收起再弹，弹窗才挂得上
            DispatchQueue.main.async { quantityDay = .today() }
        })
        .popover(isPresented: Binding(isPresent: $quantityDay), arrowEdge: arrowEdge) {
            QuantityLogPopover(habit: habit, day: quantityDay ?? .today(), allHabits: allHabits, config: config,
                               context: context, effects: effects) { quantityDay = nil }
        }
    }

    /// 点一下（或键盘打卡，经 CheckInButton 同一条路，灵光迸发照放）：今天要填数量就弹出数量输入，否则直接切换今天的打卡
    private func tap() {
        let day = LocalDay.today()
        if HabitQuantity.needsInput(habit, on: day, context: context) {
            quantityDay = day
        } else {
            HabitActions.toggle(habit, on: day, context: context, effects: effects, allHabits: allHabits, config: config)
            onToggled(day)
        }
    }
}

extension HabitCheckIn {
    /// stats 是调用方已算好的这个习惯的统计（stats.today 即今天）：达标与否、要不要弹数量输入都按 stats.logs[今天] 判断，
    /// 结果与只传 done 时打卡圈自己查的相同，但不必把这个习惯的全部打卡再扫一遍
    init(habit: Habit, stats: HabitStats, size: CGFloat = 26, allHabits: [Habit], config: CultivationConfig,
         arrowEdge: Edge = .trailing, request: Request? = nil, onToggled: @escaping (LocalDay) -> Void = { _ in }) {
        self.init(habit: habit, done: stats.isAchieved(stats.today),
                  needsInput: HabitQuantity.needsInput(habit, log: stats.logs[stats.today]),
                  size: size, allHabits: allHabits, config: config, arrowEdge: arrowEdge, onToggled: onToggled, request: request)
    }
}

/// 打卡圈的右键菜单“记数量…”：只给数量型功课挂（别的功课右键没有空菜单）
private struct QuantityMenu: ViewModifier {
    var enabled: Bool
    var action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu {
                Button("记数量…", action: action)
            }
        } else {
            content
        }
    }
}

/// 数量型功课行尾的“3/8 杯 +1”（今日洞府的功课卡用；别处要同样的写法直接用它）。
/// 数字是今天已记 / 目标（等宽数字、说明字号）；没达标时后面一颗“+”小按钮，步长见 `DashboardRules.quantityStep`
/// （目标 ≤ 20 加 1、≤ 120 加 5、更大加八分之一，按钮上写实际步长）；达标后不再显示“+”，数字转玉色。
/// 点“+”走 `HabitQuantityStep.add`：点的那一刻再取今天那条打卡、在它的数量上加一步（连点不会少算），修为、功课圆满照常。
/// 动效开着时数字滚动换新、按钮上飘起一枚淡金的“+1”；关着时直接换数字。今天适用的目标为空（不是数量型）时什么都不画。
struct HabitPlusStep: View {
    var habit: Habit
    /// 调用方已算好的这个习惯的统计（stats.today 即今天）
    var stats: HabitStats
    var allHabits: [Habit]
    var config: CultivationConfig
    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    @Environment(\.spiritMotion) private var motion
    /// 正在飘起的“+1”（每点一次一枚，飘完自己收走）
    @State private var puffs: [UUID] = []

    var body: some View {
        let log = stats.logs[stats.today]
        if let target = HabitQuantity.target(habit, log: log) {
            let done = log?.quantity ?? 0
            let achieved = stats.isAchieved(stats.today)
            let step = DashboardRules.quantityStep(target: target)
            let unit = habit.unit.isEmpty ? "" : " \(habit.unit)"
            HStack(spacing: 6) {
                Text(DashboardRules.quantityText(done: done, target: target, unit: habit.unit))
                    .font(.ysCaption.monospacedDigit())
                    .foregroundStyle(achieved ? Theme.positive : Theme.inkSoft)
                    .contentTransition(.numericText(value: done))
                    .animation(motion ? Motion.quick : nil, value: done)
                    .help(Self.hint(done: done, target: target, unit: habit.unit, achieved: achieved,
                                    needsInput: HabitQuantity.needsInput(habit, log: log)))
                if !achieved {
                    Button { add() } label: { Text(DashboardRules.stepLabel(step)) }
                        .buttonStyle(PlusStepButtonStyle())
                        .help("今天再记 \(DashboardRules.number(step))\(unit)")
                        .accessibilityLabel("「\(habit.title)」再记 \(DashboardRules.number(step))\(unit)")
                }
            }
            .lineLimit(1)
            .fixedSize()
            // 飘字挂在整组上：这一下正好达标、“+”按钮收起时，飘字照样放完
            .overlay(alignment: .topTrailing) {
                ZStack {
                    ForEach(puffs, id: \.self) { id in
                        PlusPuff(text: DashboardRules.stepLabel(step)) { puffs.removeAll { $0 == id } }
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func add() {
        guard HabitQuantityStep.add(habit, context: context, effects: effects, allHabits: allHabits, config: config) != nil else { return }
        if motion && !RenderMode.offscreen { puffs.append(UUID()) }
    }

    /// 数字上的悬停提示，说的是此刻点打卡圈会怎样（与 HabitCheckIn.tap 同一条判断）：
    /// 今天还没记过 → 点圈记满；已记了一部分（例如点过 +1）→ 点圈弹出数量框，可改数量或按目标记为达标
    static func hint(done: Double, target: Double, unit: String, achieved: Bool, needsInput: Bool) -> String {
        if achieved { return "今天已达标" }
        let unit = unit.trimmingCharacters(in: .whitespaces)
        let head = "今天已记 \(DashboardRules.number(max(0, done))) / \(DashboardRules.number(target))" + (unit.isEmpty ? "" : " \(unit)")
        return head + (needsInput ? "；点打卡圈可改数量，或按目标记为达标" : "；点打卡圈记满，右键打卡圈可填数量")
    }
}

/// 数量型功课“+1”的做法（界面与自检共用）
@MainActor
enum HabitQuantityStep {
    /// 今天已记的数量加一步（步长按今天适用的目标），返回加完的数量；不是数量型或已归档时不动、返回 nil。
    /// 今天那条在点的这一刻按日期取（不读 habit.logs、也不用界面上可能还没刷新的统计），连点几下各加一步。
    @discardableResult
    static func add(_ habit: Habit, context: ModelContext, effects: EffectsCenter, allHabits: [Habit], config: CultivationConfig) -> Double? {
        guard !habit.archived else { return nil }
        let day = LocalDay.today()
        let log = HabitDayLogs(day: day, context: context).log(of: habit)
        guard let target = HabitQuantity.target(habit, atLog: log?.targetAtLog) else { return nil }
        let quantity = (log?.quantity ?? 0) + DashboardRules.quantityStep(target: target)
        HabitActions.setQuantity(habit, on: day, quantity: quantity, context: context, effects: effects, allHabits: allHabits, config: config)
        return quantity
    }
}

/// “+1”小按钮：玉色小字、淡玉底的小胶囊，悬停加深，按下时（动效开着）轻轻一缩
private struct PlusStepButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlusStepLabel(configuration: configuration)
    }
}

private struct PlusStepLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.spiritMotion) private var motion
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        let dark = scheme == .dark
        configuration.label
            .font(.system(size: TypeSize.caption, weight: .semibold).monospacedDigit())
            .foregroundStyle(Theme.jadeDeep)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            // 底和描边用 PathCapsule（按路径画），不用系统的 Capsule：系统胶囊会被交给图层按圆角画，两端多出两截细竖线
            // （离屏渲染里可复现，与 MoodPicker 同一个毛病；compositingGroup 压不掉，drawingGroup 要起 Metal、占内存）
            .background(Theme.jade.opacity(hover ? (dark ? 0.24 : 0.16) : (dark ? 0.14 : 0.09)), in: PathCapsule())
            .overlay(PathCapsule().strokeBorder(Theme.jade.opacity(hover ? 0.55 : 0.3), lineWidth: 1))
            .scaleEffect(configuration.isPressed && motion ? 0.9 : 1)
            .animation(motion ? Motion.quick : nil, value: configuration.isPressed)
            .contentShape(Capsule())
            .onHover { inside in
                withAnimation(motion ? Motion.hover : nil) { hover = inside }
            }
    }
}

/// 按路径画的胶囊（两端半圆）。系统的 Capsule 在底色加描边时会被交给图层按圆角画，离屏渲染里两端各多出一截细竖线；
/// 自己给出路径就照路径画，没有这截线，也不必为它起 drawingGroup。细小的胶囊（“+1”、撤销条）用它
struct PathCapsule: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }
        return Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2, style: .circular)
    }

    func inset(by amount: CGFloat) -> PathCapsule { PathCapsule(inset: inset + amount) }
}

/// 点“+”时飘起的一枚淡金小字：上浮 18pt、渐隐，约 0.7 秒放完后交回 onDone（只在动效开着时出现）
private struct PlusPuff: View {
    var text: String
    var onDone: () -> Void
    @State private var risen = false

    var body: some View {
        Text(text)
            .font(.system(size: TypeSize.caption, weight: .bold).monospacedDigit())
            .foregroundStyle(Theme.gold)
            .shadow(color: Theme.gold.opacity(0.35), radius: 4)
            .offset(y: risen ? -20 : -4)
            .opacity(risen ? 0 : 1)
            .fixedSize()
            .onAppear {
                withAnimation(.easeOut(duration: 0.7)) { risen = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: onDone)
            }
    }
}

/// 时间选择：玉签式按钮，点开是时 / 分两组格子（分钟以 5 分为一档）。
struct MinuteField: View {
    var label: String
    @Binding var minutes: Int
    /// 结束时间可选 24:00（当天结束）
    var allowMidnight = false
    @State private var open = false

    var body: some View {
        if label.isEmpty { chip } else { LabeledContent(label) { chip } }
    }

    private var chip: some View {
        Button { open.toggle() } label: {
            FieldChip(symbol: "clock", text: ClockTime.text(minutes), active: open)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            TimeGrid(minutes: $minutes, allowMidnight: allowMidnight) { open = false }
        }
    }
}

/// 日期选择：玉签式按钮（“10月13日 周二 · 今天”），点开是自绘月历。
/// height：要和同一行的按钮、输入框对齐时给定高度；不给时按内容。
struct DayField: View {
    var label: String
    @Binding var key: String
    var height: CGFloat? = nil
    @State private var open = false

    var body: some View {
        if label.isEmpty { chip } else { LabeledContent(label) { chip } }
    }

    private var chip: some View {
        let day = LocalDay(key: key) ?? .today()
        let offset = LocalDay.today().days(to: day)
        let relative = offset == 0 ? " · 今天" : offset == -1 ? " · 昨天" : offset == 1 ? " · 明天" : ""
        return Button { open.toggle() } label: {
            FieldChip(symbol: "calendar", text: "\(day.label(relativeTo: .today())) \(day.weekdayName)\(relative)", active: open, height: height)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            MonthCalendar(selection: Binding(get: { LocalDay(key: key) ?? .today() }, set: { key = $0.key })) { open = false }
        }
    }
}

/// 日期 / 时间按钮的统一外观。
struct FieldChip: View {
    var symbol: String?
    var text: String
    var active = false
    /// 固定高度（与同一行的按钮对齐）；nil 时按内容
    var height: CGFloat? = nil

    var body: some View {
        HStack(spacing: 7) {
            // 图标只是装饰：VoiceOver 只读文字（“8:30”“10月13日 周二”），不读“时钟”“向下箭头”
            if let symbol {
                Image(systemName: symbol).font(.system(size: TypeSize.caption, weight: .medium)).foregroundStyle(Theme.inkSoft)
                    .accessibilityHidden(true)
            }
            Text(text).font(.system(size: TypeSize.callout, weight: .medium)).monospacedDigit().foregroundStyle(Theme.ink).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.inkSoft)
                .accessibilityHidden(true)
        }
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, height == nil ? 7 : 0)
        .frame(height: height)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        // 打开时（当前选中）描边转金
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .strokeBorder(active ? Theme.gold.opacity(0.7) : Theme.line, lineWidth: active ? 1.3 : 1))
        .contentShape(Rectangle())
    }
}

/// 自绘月历：周一为首，今天金圈，选中玉色实心，可一键回到今天。
struct MonthCalendar: View {
    @Binding var selection: LocalDay
    var onPick: () -> Void
    @State private var month: LocalDay
    @FocusState private var focused: Bool

    init(selection: Binding<LocalDay>, onPick: @escaping () -> Void) {
        _selection = selection
        self.onPick = onPick
        _month = State(initialValue: selection.wrappedValue.firstOfMonth)
    }

    private var days: [LocalDay?] {
        let first = month.firstOfMonth
        var cells: [LocalDay?] = Array(repeating: nil, count: first.weekdayIndex)
        var day = first
        while day.month == first.month {
            cells.append(day)
            day = day.adding(days: 1)
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    var body: some View {
        let today = LocalDay.today()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: MonthKey.label(year: month.year, month: month.month)).font(.ysHeading).tracking(1).foregroundStyle(Theme.ink)
                Spacer()
                calendarButton("chevron.left", label: "上个月") { month = month.adding(days: -1).firstOfMonth }
                calendarButton("chevron.right", label: "下个月") { month = month.adding(days: 32).firstOfMonth }
            }
            HStack(spacing: 0) {
                ForEach(LocalDay.weekdayShortNames, id: \.self) { name in
                    Text(name).font(.ysCaption).foregroundStyle(Theme.inkSoft).frame(width: 38)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 0), count: 7), spacing: 4) {
                ForEach(days.indices, id: \.self) { index in
                    if let day = days[index] {
                        let selected = day == selection, isToday = day == today
                        Button {
                            selection = day
                            onPick()
                        } label: {
                            // 周末用次要灰（朱砂只表示警示）；今天金色细圈，选中玉色实底
                            Text("\(day.day)")
                                .font(.system(size: TypeSize.callout, weight: selected || isToday ? .semibold : .regular).monospacedDigit())
                                .foregroundStyle(selected ? Theme.onJadeFill : (day.weekdayIndex >= 5 ? Theme.inkSoft : Theme.ink))
                                .frame(width: 32, height: 32)
                                .background {
                                    if selected { Circle().fill(Theme.jadeFill) }
                                }
                                .overlay { if isToday && !selected { Circle().strokeBorder(Theme.gold, lineWidth: 1.2) } }
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: 38, height: 34)
                        .accessibilityLabel("\(day.month)月\(day.day)日 \(day.weekdayName)" + (isToday ? "，今天" : "") + (selected ? "，已选" : ""))
                    } else {
                        Color.clear.frame(width: 38, height: 34)
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                ForEach([(-1, "昨天"), (0, "今天"), (1, "明天")], id: \.0) { item in
                    Button(item.1) {
                        selection = today.adding(days: item.0)
                        onPick()
                    }
                    .buttonStyle(.yunshanCompact)
                }
            }
        }
        .padding(18)
        .background(Theme.card)
        // 键盘：方向键移动日期，回车确认，Esc 关闭
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-7) }
        .onKeyPress(.downArrow) { move(7) }
        .onKeyPress(.return) { onPick(); return .handled }
        .keyNote(.calendarMove)
        .keyNote(.calendarPick)
    }

    private func move(_ days: Int) -> KeyPress.Result {
        selection = selection.adding(days: days)
        month = selection.firstOfMonth
        return .handled
    }

    private func calendarButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: TypeSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                .frame(width: 28, height: 28)
                .background(Theme.mist, in: Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// 时 / 分格子。
struct TimeGrid: View {
    @Binding var minutes: Int
    var allowMidnight = false
    var onDone: () -> Void

    var body: some View {
        let hour = min(23, minutes / 60), minute = minutes >= 24 * 60 ? 0 : minutes % 60
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("择时 · \(ClockTime.text(minutes))").font(.ysHeading).monospacedDigit().foregroundStyle(Theme.ink)
                Spacer()
                // 分钟微调：格子以 5 分钟为一档，精确时间用 −1 / +1
                Button { minutes = max(0, minutes - 1) } label: { Image(systemName: "minus").frame(width: 14, height: 14) }.buttonStyle(.yunshanCompact).help("早 1 分钟")
                Button { minutes = min(max(minutes, allowMidnight ? 24 * 60 : 23 * 60 + 59), minutes + 1) } label: { Image(systemName: "plus").frame(width: 14, height: 14) }.buttonStyle(.yunshanCompact).help("晚 1 分钟")
            }
            Text("时").font(.ysCaption).foregroundStyle(Theme.inkSoft)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 4), count: 6), spacing: 4) {
                ForEach(0..<24, id: \.self) { h in
                    cell(String(format: "%02d", h), on: h == hour && minutes < 24 * 60) { minutes = h * 60 + minute }
                }
            }
            if allowMidnight {
                Button {
                    minutes = 24 * 60
                    onDone()
                } label: {
                    Label("到当天结束（24:00）", systemImage: "moon.zzz")
                        .font(.ysCaption)
                        .foregroundStyle(minutes >= 24 * 60 ? Theme.onJadeFill : Theme.ink)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(minutes >= 24 * 60 ? AnyShapeStyle(Theme.jadeFill) : AnyShapeStyle(Theme.mist.opacity(0.7)), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Text("分").font(.ysCaption).foregroundStyle(Theme.inkSoft)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 4), count: 6), spacing: 4) {
                ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { m in
                    cell(String(format: "%02d", m), on: m == minute && minutes < 24 * 60) {
                        minutes = hour * 60 + m
                        onDone()
                    }
                }
            }
        }
        .padding(18)
        .background(Theme.card)
    }

    private func cell(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                // 时刻用正文字体的等宽数字，不用像终端的代码字体
                .font(.system(size: TypeSize.callout, weight: on ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(on ? Theme.onJadeFill : Theme.ink)
                .frame(width: 40, height: 28)
                .background(on ? AnyShapeStyle(Theme.jadeFill) : AnyShapeStyle(Theme.mist.opacity(0.7)),
                            in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 周一至周日多选。
struct WeekdayPicker: View {
    @Binding var selection: [Int]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    if on { selection.removeAll { $0 == day } } else { selection = (selection + [day]).sorted() }
                } label: {
                    // 选中样式与 ChipPicker、月历一致：玉色实底（jadeFill）+ onJadeFill 字
                    Text(LocalDay.weekdayShortNames[day])
                        .font(.ysCallout.weight(on ? .semibold : .regular))
                        .frame(width: 30, height: 26)
                        .background(on ? AnyShapeStyle(Theme.jadeFill) : AnyShapeStyle(Theme.mist),
                                    in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                        .foregroundStyle(on ? Theme.onJadeFill : Theme.ink)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalDay.weekdayNames[day] + (on ? "，已选" : ""))
            }
        }
    }
}

enum FilePanels {
    /// 弹出保存面板并写入数据；用户取消时返回 nil。
    @MainActor
    static func save(data: Data, suggestedName: String, allowedExtensions: [String]) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = allowedExtensions.compactMap { .init(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            return nil
        }
    }

    @MainActor
    static func open(allowedExtensions: [String], directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = allowedExtensions.compactMap { .init(filenameExtension: $0) }
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension Double {
    var percentText: String { "\(Int((self * 100).rounded()))%" }
}

extension Binding where Value == Bool {
    /// 弹窗是否显示：可选值不为 nil 时显示；弹窗关掉时把它清成 nil
    init<Wrapped>(isPresent value: Binding<Wrapped?>) {
        self.init(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    /// 一组同类弹窗里的一个（例如热力图上的某一天）：可选值等于 item 时显示；弹窗关掉时清成 nil
    init<Wrapped: Equatable>(isPresent value: Binding<Wrapped?>, equals item: Wrapped) {
        self.init(get: { value.wrappedValue == item }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

// MARK: - 布局：自动换行、一行两段；筛选签

/// 一行两段：左边一组控件、右边一个按钮。放得下时同一行（按钮靠右、上下居中）；
/// 放不下时按钮换到下一行、仍靠右。左边那组里可伸缩的控件（如标签框）先收窄到它的最小宽度再换行。
/// 只传一个子视图时它就是右边的按钮。
struct WrapTrailingRow: Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 10

    private func split(_ subviews: Subviews) -> (lead: LayoutSubview?, trail: LayoutSubview?) {
        switch subviews.count {
        case 0: (nil, nil)
        case 1: (nil, subviews[0])
        default: (subviews[0], subviews[subviews.count - 1])
        }
    }

    /// 同一行放得下吗：左边那组的最小宽度 + 按钮宽度
    private func fits(_ lead: LayoutSubview?, _ trail: CGSize, width: CGFloat) -> Bool {
        guard let lead else { return true }
        let minLead = lead.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
        return minLead + spacing + trail.width <= width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (lead, trail) = split(subviews)
        let trailSize = trail?.sizeThatFits(.unspecified) ?? .zero
        guard let width = proposal.width else {
            let leadSize = lead?.sizeThatFits(.unspecified) ?? .zero
            return CGSize(width: leadSize.width + (lead == nil ? 0 : spacing) + trailSize.width, height: max(leadSize.height, trailSize.height))
        }
        if fits(lead, trailSize, width: width) {
            let leadHeight = lead?.sizeThatFits(ProposedViewSize(width: width - spacing - trailSize.width, height: nil)).height ?? 0
            return CGSize(width: width, height: max(leadHeight, trailSize.height))
        }
        let leadHeight = lead?.sizeThatFits(ProposedViewSize(width: width, height: nil)).height ?? 0
        return CGSize(width: width, height: leadHeight + rowSpacing + trailSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (lead, trail) = split(subviews)
        let trailSize = trail?.sizeThatFits(.unspecified) ?? .zero
        if fits(lead, trailSize, width: bounds.width) {
            let leadWidth = bounds.width - spacing - trailSize.width
            if let lead {
                let size = lead.sizeThatFits(ProposedViewSize(width: leadWidth, height: nil))
                lead.place(at: CGPoint(x: bounds.minX, y: bounds.midY - size.height / 2), proposal: ProposedViewSize(width: leadWidth, height: size.height))
            }
            trail?.place(at: CGPoint(x: bounds.maxX - trailSize.width, y: bounds.midY - trailSize.height / 2), proposal: ProposedViewSize(trailSize))
        } else {
            let size = lead?.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)) ?? .zero
            lead?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: size.height))
            trail?.place(at: CGPoint(x: bounds.maxX - trailSize.width, y: bounds.minY + size.height + rowSpacing), proposal: ProposedViewSize(trailSize))
        }
    }
}

/// 筛选签：选中为玉色实底。count 为篇数（淡一档）；removable 为已生效的条件，末尾带“✕”，点一下去掉。
struct FilterChip: View {
    var text: String
    var count: Int? = nil
    var on: Bool
    var removable = false
    var action: () -> Void

    var body: some View {
        if removable {
            chip.help("去掉这个条件").accessibilityHint("去掉这个条件")
        } else {
            chip.accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    private var chip: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(text).lineLimit(1)
                if let count { Text("\(count)").monospacedDigit().opacity(0.7) }
                if removable { Image(systemName: "xmark").font(.system(size: TypeSize.micro - 1.5, weight: .bold)).opacity(0.8) }
            }
            .font(.system(size: TypeSize.caption, weight: on ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(on ? Theme.onJadeFill : Theme.ink)
            .background(on ? AnyShapeStyle(Theme.jadeFill) : AnyShapeStyle(Theme.mist.opacity(0.8)), in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 自动换行排列（标签、筛选项）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - 手记金额

/// 手记金额输入：“$” + 输入框，有输入但写法不对时在下面用朱砂小字说明原因。
/// 随手记、手记一笔、交易编辑共用；规则与飞剑传书相同（FinanceEngine.manualCents）。
struct AmountField: View {
    @Binding var text: String
    var prompt = "例如：18.50"
    /// false：说明由调用方自己摆（随手记把它和“可能是同一笔”的提醒放在同一处）
    var showsProblem = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("$").font(Theme.money(TypeSize.body, .semibold)).foregroundStyle(Theme.inkSoft)
                TextField("", text: $text, prompt: Text(prompt))
            }
            if showsProblem, let problem = Self.problem(text) { Self.problemLabel(problem) }
        }
    }

    /// 有输入但写法不对时的说明；没输入或写对了时为 nil
    static func problem(_ text: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do { _ = try FinanceEngine.manualCents(text); return nil } catch { return error.localizedDescription }
    }

    static func problemLabel(_ problem: String) -> some View {
        Hint(problem, tone: .error, symbol: "")
    }
}

/// “账上已有同额银行流水”的提醒（金额相同、日期相差 3 天内）：只提醒，不拦着入账。没有这样的流水时不显示。
/// compact：随手记里的一行小字；否则是手记一笔里带说明的一段。
struct BankMatchHint: View {
    var matches: [FinanceTransaction]
    var compact = false

    var body: some View {
        if let first = matches.first {
            if compact {
                Hint("账上已有 \(first.date.suffix(5)) \(FinanceEngine.merchantDisplay(first)) \(FinanceEngine.money(first.amountCents))，可能是同一笔",
                     tone: .warning, symbol: "")
            } else {
                let shown = matches.prefix(2).map { "\($0.date.suffix(5)) \(FinanceEngine.merchantDisplay($0))（\($0.account)）" }.joined(separator: "、")
                Hint("账上已有 \(shown)\(matches.count > 2 ? " 等 \(matches.count) 笔" : "")，同为 \(FinanceEngine.money(first.amountCents))、日期相差 3 天内，可能就是这一笔。刷卡的消费不必再手记；确认不是同一笔再入账。",
                     tone: .warning)
            }
        }
    }
}

// MARK: - 玉简式表单

/// 编辑窗口的标题：金色小字 + 宋体标题。
struct SheetHeader: View {
    var eyebrow: String
    var title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Rectangle().fill(LinearGradient(colors: [Theme.gold.opacity(0), Theme.gold], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 24, height: 1)
                Text(eyebrow).font(Theme.songti(TypeSize.caption, .medium)).tracking(6).foregroundStyle(Theme.gold)
            }
            // 汉字宋体、拉丁字母系统字体（商户名“Tong Lin Li · Chatswood”不会被宋体字距拆开）
            CardTitle<EmptyView>.styled(title, size: TypeSize.title, tracking: 2).foregroundStyle(Theme.ink)
        }
    }
}

/// 表单分组：可选的小标题 + 一块淡色玉简底。
struct FormSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 7) {
                    Capsule().fill(Theme.gold.opacity(0.8)).frame(width: 1.5, height: 11)
                    Text(title).font(Theme.songti(TypeSize.callout, .semibold)).tracking(2).foregroundStyle(Theme.inkSoft)
                }
                .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 2) { content() }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.paper.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.line.opacity(0.9)))
        }
    }
}

/// 表单一行：左侧标签，右侧控件。
/// 标签与控件结成一对（像系统的 LabeledContent）：控件以这行的标签为题，但保留自己的名字，
/// 一行里有两个控件（如“时段”的开始 / 结束）时，VoiceOver 仍能分清各是什么。
struct FormRow<Content: View>: View {
    var label: String
    var top = false
    @ViewBuilder var content: () -> Content
    @Namespace private var pair

    var body: some View {
        HStack(alignment: top ? .top : .center, spacing: 12) {
            Text(label)
                .font(.ysCallout)
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 72, alignment: .leading)
                .padding(.top, top ? 8 : 0)
                .accessibilityLabeledPair(role: .label, id: "row", in: pair)
            content().frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabeledPair(role: .content, id: "row", in: pair)
        }
        .padding(.vertical, 5)
    }
}

/// 编辑弹窗的骨架（功课、目标、作息、日程、仅修改这一次共用）：标题，可滚动的表单，
/// 底部一行“删除 · 出错说明 ⟶ 额外按钮 · 取消（Esc）· 保存（回车，主按钮）”。以后调弹窗留白、按钮顺序只改这里。
/// 各弹窗自己的确认框（删除确认、修为将改变、跨夜过长……）挂在外层，不进骨架。
struct EditorSheet<Fields: View, Extra: View>: View {
    var eyebrow: String
    var title: String
    var size: CGSize
    var canSave: Bool
    /// 底栏左侧的出错说明（如“请填写标题”）；nil 时不显示
    var problem: String?
    var onSave: () -> Void
    /// 底栏最左的“删除”（一般是先弹确认框）；nil 时不显示（新建时）
    var onDelete: (() -> Void)?
    @ViewBuilder var fields: () -> Fields
    /// “取消”左边的额外按钮（如“恢复为系列设置”）
    @ViewBuilder var extraActions: () -> Extra
    @Environment(\.dismiss) private var dismiss
    /// 表单底部渐隐的浓淡（0 不显示）：下面还藏着多少内容，见 EditorSheetFade
    @State private var fade = 0.0

    init(eyebrow: String, title: String, size: CGSize, canSave: Bool, problem: String? = nil,
         onSave: @escaping () -> Void, onDelete: (() -> Void)? = nil,
         @ViewBuilder fields: @escaping () -> Fields, @ViewBuilder extraActions: @escaping () -> Extra) {
        self.eyebrow = eyebrow
        self.title = title
        self.size = size
        self.canSave = canSave
        self.problem = problem
        self.onSave = onSave
        self.onDelete = onDelete
        self.fields = fields
        self.extraActions = extraActions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(eyebrow: eyebrow, title: title).padding([.top, .horizontal], 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { fields() }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    // 表单比弹窗高时，量出视口下面还藏着多少，换算成渐隐的浓淡
                    .measuresHiddenBelow($fade)
            }
            // 内容超出时底部一段纸色渐隐：看得出下面还有，不再像被按钮栏拦腰切断；滚到底就淡没了
            .bottomFade(fade)
            // 按钮栏上一条细线，和表单分开
            Rectangle().fill(Theme.line).frame(height: 0.5).accessibilityHidden(true)
            HStack {
                if let onDelete { Button("删除", role: .destructive, action: onDelete) }
                if let problem { Hint(problem, tone: .error, symbol: "") }
                Spacer()
                extraActions()
                Button("取消") { dismiss() }.keyCommand(.dialogCancel)
                Button("保存", action: onSave)
                    .buttonStyle(.yunshanPrimary)
                    .keyCommand(.dialogConfirm)
                    .disabled(!canSave)
            }
            .padding(20)
        }
        .frame(width: size.width, height: size.height)
        .yunshanSheet()
    }
}

/// 编辑弹窗底部的渐隐：表单比弹窗高时，按钮栏上方一段 24pt 纸色渐隐，提示“下面还有”。
/// 浓淡随下面藏着的高度走：藏着 24pt 以上全浓，越滚越淡，滚到底（或本来就放得下）不显示。取到 0.1 一档，滚动时少重画
enum EditorSheetFade {
    static let height: CGFloat = 24
    static let space = "editorSheet.form"

    static func opacity(hiddenBelow: CGFloat) -> Double {
        guard hiddenBelow.isFinite, hiddenBelow > 1 else { return 0 }
        return (min(1, Double(hiddenBelow / height)) * 10).rounded() / 10
    }
}

extension View {
    /// 挂在滚动视图里的内容上：量出视口下面还藏着多少，换成渐隐浓淡写进 fade
    /// （只在浓淡变了时才回写，滚动时不逐帧重算内容）。滚动视图本身要挂 .bottomFade(fade)
    func measuresHiddenBelow(_ fade: Binding<Double>) -> some View {
        onGeometryChange(for: Double.self) { proxy in
            guard let viewport = proxy.bounds(of: .named(EditorSheetFade.space)) else { return 0 }
            return EditorSheetFade.opacity(hiddenBelow: proxy.size.height - viewport.maxY)
        } action: { fade.wrappedValue = $0 }
    }

    /// 挂在滚动视图上：定下量高用的坐标系，底部按 fade 盖一段 24pt 纸色（弹窗底色）渐隐，不挡点击
    func bottomFade(_ fade: Double) -> some View {
        coordinateSpace(.named(EditorSheetFade.space))
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [Theme.card.opacity(0), Theme.card], startPoint: .top, endPoint: .bottom)
                    .frame(height: EditorSheetFade.height)
                    .opacity(fade)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension EditorSheet where Extra == EmptyView {
    init(eyebrow: String, title: String, size: CGSize, canSave: Bool, problem: String? = nil,
         onSave: @escaping () -> Void, onDelete: (() -> Void)? = nil, @ViewBuilder fields: @escaping () -> Fields) {
        self.init(eyebrow: eyebrow, title: title, size: size, canSave: canSave, problem: problem,
                  onSave: onSave, onDelete: onDelete, fields: fields) { EmptyView() }
    }
}

/// 编辑弹窗里的“备注”一节：可不填，随内容在 lines 行之间长高。
struct NotesSection: View {
    @Binding var text: String
    var lines: ClosedRange<Int> = 2...4

    var body: some View {
        FormSection(title: "备注") {
            TextField("", text: $text, prompt: Text("可不填"), axis: .vertical).lineLimit(lines).padding(.vertical, 4)
        }
    }
}

/// 多行输入框（落笔、修订、随手记、问道的提示语与回音、月末备注共用）：宣纸底、细边、占位文字，
/// 聚焦时边框亮起 accent 色（默认金；落笔框用这一类记录的颜色，并泛一层同色柔光）。
/// height 给范围时框随内容长高（用一段隐形的同样文字撑出高度），到上限后在框里滚动；给一个数时固定高度。
struct PaperEditor: View {
    @Binding var text: String
    var placeholder: String
    var font: Font
    var height: ClosedRange<CGFloat>
    var accent: Color
    /// 聚焦时外缘再泛一层 accent 色的柔光
    var glow: Bool
    /// 调用方要自己控制焦点（例如打开就把光标放进来）时传入；不传时用自己的
    var focus: FocusState<Bool>.Binding?
    @FocusState private var ownFocus: Bool

    /// 行距：隐形文字与输入框必须一致，量出的高度才对得上
    private static let lineSpacing: CGFloat = 3

    init(text: Binding<String>, placeholder: String = "", font: Font = .ysBody, height: ClosedRange<CGFloat>,
         accent: Color = Theme.gold, glow: Bool = false, focus: FocusState<Bool>.Binding? = nil) {
        _text = text
        self.placeholder = placeholder
        self.font = font
        self.height = height
        self.accent = accent
        self.glow = glow
        self.focus = focus
    }

    init(text: Binding<String>, placeholder: String = "", font: Font = .ysBody, height: CGFloat,
         accent: Color = Theme.gold, glow: Bool = false, focus: FocusState<Bool>.Binding? = nil) {
        self.init(text: text, placeholder: placeholder, font: font, height: height...height, accent: accent, glow: glow, focus: focus)
    }

    private var focused: Bool { focus?.wrappedValue ?? ownFocus }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        sizer
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder)
                        .font(font)
                        .foregroundStyle(Theme.inkSoft.opacity(0.7))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                TextEditor(text: $text)
                    .font(font)
                    .lineSpacing(Self.lineSpacing)
                    .scrollContentBackground(.hidden)
                    .focused(focus ?? $ownFocus)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .background(Theme.paper.opacity(0.6), in: shape)
            .overlay(shape.strokeBorder(focused ? accent.opacity(0.65) : Theme.line, lineWidth: focused ? 1.3 : 1))
            .shadow(color: accent.opacity(glow ? 0.18 : 0), radius: glow && focused ? 10 : 0)
    }

    /// 撑出框的高度：固定高度时是一块空白；随内容长高时是一段隐形的同样文字（外层给了更高的空间也不把框撑大）
    @ViewBuilder
    private var sizer: some View {
        if height.lowerBound >= height.upperBound {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: height.lowerBound)
        } else {
            Text(text.isEmpty ? " " : text + " ")
                .font(font)
                .lineSpacing(Self.lineSpacing)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .frame(minHeight: height.lowerBound, maxHeight: height.upperBound, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 下拉选择：玉签按钮，点开是选项列表（取代系统灰色弹出菜单）。
struct ChipPicker<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var symbol: ((Value) -> String)? = nil
    @State private var open = false

    var body: some View {
        let current = options.first { $0.value == selection }
        Button { open.toggle() } label: {
            FieldChip(symbol: symbol?(selection), text: current?.label ?? "请选择", active: open)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(options.indices, id: \.self) { index in
                        let option = options[index]
                        let on = option.value == selection
                        Button {
                            selection = option.value
                            open = false
                        } label: {
                            HStack(spacing: 8) {
                                if let symbol { Image(systemName: symbol(option.value)).frame(width: 16).foregroundStyle(on ? Theme.onJadeFill : Theme.inkSoft) }
                                Text(option.label).font(.system(size: TypeSize.callout, weight: on ? .semibold : .regular))
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
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(8)
            }
            .frame(minWidth: 200, maxHeight: 360)
            .fixedSize(horizontal: true, vertical: options.count <= 9)
            .background(Theme.card)
        }
    }
}

// MARK: - 共用组件：数字格、可点的列表行、卡内链接、提示文字

/// 数字格（内嵌格样式）：标签 / 数值 / 单位 / 备注。数值用 New York 等宽数字，默认墨色；
/// 一排最多一格强调（emphasized 为玉色；超支等警示传 tint: Theme.warning）。
/// 一排几格请放进 MetricRow，格子等高、顶端对齐（有的格有备注也不会参差）。
struct MetricTile: View {
    var label: String
    var value: String
    var unit: String = ""
    var note: String = ""
    var emphasized = false
    var tint: Color? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.figure(TypeSize.title))
                    .foregroundStyle(tint ?? (emphasized ? Theme.positive : Theme.ink))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty { Text(unit).font(.ysCaption).foregroundStyle(Theme.inkSoft) }
            }
            if !note.isEmpty {
                Text(note).font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.mist.opacity(scheme == .dark ? 0.9 : 0.75), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// 一排数字格：等高、顶端对齐。
struct MetricRow<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: spacing) { content() }
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 整行可点的列表行（作息条目、日程、目标、固定账单……）：点整行编辑；悬停时泛起淡雾底、右侧露出淡淡的 ›；
/// 右键菜单有“编辑 / 删除”。行本身是按钮，可获得焦点，读屏可用“编辑”“删除”动作。
/// content 里不要再放按钮或开关（会被整行的点击吞掉）。分隔线只画在两行之间：从第二行起传 dividerAbove: true。
struct EditableRow<Content: View>: View {
    var dividerAbove = false
    var editLabel = "编辑"
    /// 右键菜单与读屏里的“删除”；nil 时不提供（删除放在编辑弹窗里）
    var onDelete: (() -> Void)? = nil
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.spiritMotion) private var motion
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            if dividerAbove {
                Rectangle().fill(Theme.line.opacity(0.8)).frame(height: 1)
            }
            Button(action: action) {
                HStack(spacing: 10) {
                    content().frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: TypeSize.micro, weight: .semibold))
                        .foregroundStyle(Theme.inkSoft)
                        .opacity(hover ? 0.8 : 0)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(Theme.mist.opacity(hover ? 0.85 : 0), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 悬停底色向两侧多铺 10pt，文字仍与卡片标题对齐
            .padding(.horizontal, -10)
            .onHover { inside in
                if inside && ScrollActivity.shared.isScrolling { return }
                withAnimation(motion ? Motion.hover : nil) { hover = inside }
            }
            .onReceive(ScrollActivity.shared.began) { _ in
                if hover { hover = false }
            }
            .contextMenu {
                Button(editLabel, action: action)
                if let onDelete { Button("删除", role: .destructive, action: onDelete) }
            }
            .accessibilityAction(named: editLabel, action)
            .modifier(OptionalDeleteAction(onDelete: onDelete))
        }
    }
}

private struct OptionalDeleteAction: ViewModifier {
    var onDelete: (() -> Void)?
    func body(content: Content) -> some View {
        if let onDelete { content.accessibilityAction(named: "删除", onDelete) } else { content }
    }
}

/// 卡内链接：淡金小字加“→”，悬停出现下划线。每张卡最多一个，放在 CardTitle 的 trailing 里。
/// 用法：`Button("时辰卷") { … }.buttonStyle(.cardLink)`
struct CardLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardLinkLabel(configuration: configuration)
    }
}

private struct CardLinkLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hover = false

    var body: some View {
        HStack(spacing: 3) {
            configuration.label
            Text(verbatim: "→").accessibilityHidden(true)
        }
        .font(.system(size: TypeSize.caption, weight: .medium))
        .foregroundStyle(Theme.gold)
        .lineLimit(1)
        .fixedSize()
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.gold.opacity(0.6)).frame(height: 1).offset(y: 2).opacity(hover && isEnabled ? 1 : 0)
        }
        .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

extension ButtonStyle where Self == CardLinkStyle {
    static var cardLink: CardLinkStyle { CardLinkStyle() }
}

/// 就地执行的小操作（撤销、收起……）：次要墨色小字，悬停加深。不带“→”：“→”只表示去别处。
/// 撤销这类要留意的操作传 tint: Theme.warning。用法：`Button { … } label: { Label("撤销", systemImage: "arrow.uturn.backward") }.buttonStyle(.inlineAction())`
struct InlineActionStyle: ButtonStyle {
    var tint: Color = Theme.inkSoft
    func makeBody(configuration: Configuration) -> some View {
        InlineActionLabel(configuration: configuration, tint: tint)
    }
}

private struct InlineActionLabel: View {
    let configuration: ButtonStyleConfiguration
    var tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @State private var hover = false

    var body: some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: TypeSize.caption, weight: .medium))
            .foregroundStyle(tint.opacity(hover ? 1 : 0.85))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(hover && isEnabled ? 0.1 : 0), in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Capsule())
            .onHover { hover = $0 }
    }
}

extension ButtonStyle where Self == InlineActionStyle {
    static func inlineAction(_ tint: Color = Theme.inkSoft) -> InlineActionStyle { InlineActionStyle(tint: tint) }
}

/// 折叠小节（“修为规则 ›”“从备份恢复 ›”这类）：文字 + 旋转的 chevron，与设置组标题同一种写法，
/// 取代系统 DisclosureGroup 的小三角。挂在页面根上：`.disclosureGroupStyle(.yunshan)`
struct YunshanDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        YunshanDisclosure(configuration: configuration)
    }
}

private struct YunshanDisclosure: View {
    let configuration: DisclosureGroupStyleConfiguration
    @Environment(\.spiritMotion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(motion ? Motion.standard : nil) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    configuration.label
                    Image(systemName: "chevron.right")
                        .font(.system(size: TypeSize.micro, weight: .semibold))
                        .foregroundStyle(Theme.inkSoft)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
    }
}

extension DisclosureGroupStyle where Self == YunshanDisclosureStyle {
    static var yunshan: YunshanDisclosureStyle { YunshanDisclosureStyle() }
}

/// 提示文字，按语气分四档，颜色和图标统一：
/// 说明（次要灰，默认无图标）/ 警示（朱砂 + 三角）/ 错误（朱砂 + 叉）/ 成功（玉色 + 勾）。自动换行。
/// symbol 传别的 SF Symbol 名可换图标，传 "" 不显示图标。
struct Hint: View {
    enum Tone {
        case note, warning, error, success

        var color: Color {
            switch self {
            case .note: Theme.inkSoft
            case .warning, .error: Theme.warning
            case .success: Theme.positive
            }
        }

        var symbol: String? {
            switch self {
            case .note: nil
            case .warning: "exclamationmark.triangle"
            case .error: "xmark.circle"
            case .success: "checkmark.circle"
            }
        }
    }

    var text: String
    var tone: Tone = .note
    var symbol: String? = nil

    init(_ text: String, tone: Tone = .note, symbol: String? = nil) {
        self.text = text
        self.tone = tone
        self.symbol = symbol
    }

    var body: some View {
        let icon = symbol ?? tone.symbol
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let icon, !icon.isEmpty { Image(systemName: icon).accessibilityHidden(true) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.ysCaption)
        .foregroundStyle(tone.color)
    }
}

// MARK: - 空状态

// 全应用的空状态只用下面两种（写法与全部文案见 Core/EmptyCopy.swift，各页从那里取，不在视图里另写）：
// 整页 / 首页整张卡一条都没有 → OrnamentEmpty；有数据的页里某一块空着、筛选没有结果 → EmptyHint；
// 卡内小节空着 → 更轻的 Hint 一句。

/// 大号留白的尺寸：各页一致（自检按它核对各页留白等高）
enum EmptyStateMetrics {
    /// 小物边长
    static let ornament: CGFloat = 84
    /// 小物背后柔光的大小（比小物宽，边缘完全化开，不占布局）
    static let glow = CGSize(width: 176, height: 124)
    /// 小物、标题、说明、按钮之间
    static let spacing: CGFloat = 12
    /// 上下留白
    static let vertical: CGFloat = 30
    /// 几个按钮之间
    static let buttonSpacing: CGFloat = 10
}

/// 大号留白：小物 84pt + 宋体对句标题 + 一句说明 + 直达下一步的按钮（主按钮在前、带图标；同一屏横幅里不再放同一个按钮）。
/// 小物背后衬一团淡金柔光。进场时小物从下方浮出、柔光由小化开（只一次，约 1 秒），标题掠过一道光；
/// 悬停在这一块上时小物轻轻上浮、柔光转亮。动效关闭、系统“减少动态效果”或离屏截图时直接是静止的终态。
/// 各页尺寸一致：小物、柔光、间距都取 EmptyStateMetrics，同宽下文案行数相同、按钮一行时各页留白等高。
struct OrnamentEmpty<Action: View>: View {
    var ornament: String
    var title: String
    var text: String
    @ViewBuilder var action: () -> Action

    @Environment(\.spiritMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    /// 进场是否已经播过：播过之后动效开关再变，也不会把小物重新藏起来
    @State private var shown = false
    @State private var hover = false

    private typealias Metrics = EmptyStateMetrics

    init(ornament: String, title: String, text: String, @ViewBuilder action: @escaping () -> Action) {
        self.ornament = ornament
        self.title = title
        self.text = text
        self.action = action
    }

    /// 按页取文案：`OrnamentEmpty(.habits) { Button … }`
    init(_ copy: EmptyCopy, @ViewBuilder action: @escaping () -> Action) {
        self.init(ornament: copy.ornament, title: copy.title, text: copy.text, action: action)
    }

    private var animate: Bool { motion && !reduceMotion && !RenderMode.offscreen }

    var body: some View {
        let dark = scheme == .dark
        // 没开动效时直接是终态（离屏截图拍到的就是这一帧）
        let risen = shown || !animate
        let lit = hover && animate
        VStack(spacing: Metrics.spacing) {
            SceneryImage(name: ornament)
                .frame(width: Metrics.ornament, height: Metrics.ornament)
                .background {
                    SoftGlow(color: Theme.gold.opacity(dark ? 0.24 : 0.2))
                        .frame(width: Metrics.glow.width, height: Metrics.glow.height)
                        .scaleEffect(risen ? (lit ? 1.12 : 1) : 0.5)
                        .opacity(risen ? (lit ? 1 : 0.8) : 0)
                }
                .opacity(risen ? 0.95 : 0)
                .offset(y: risen ? (lit ? -4 : 0) : 10)
                .scaleEffect(lit ? 1.04 : 1)
            Text(title).font(.ysHeading).tracking(2).foregroundStyle(Theme.ink)
                .shimmerSweep(animate)
            Text(text).font(.ysCallout).foregroundStyle(Theme.inkSoft).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // 不带按钮时连这一排也不放（空的一排也会占掉一道间距）
            if Action.self != EmptyView.self {
                HStack(spacing: Metrics.buttonSpacing) { action() }
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.vertical)
        .contentShape(Rectangle())
        .onHover { inside in
            guard animate else { return }
            // 滑动经过时不亮（与卡片悬停同一规矩）
            if inside && ScrollActivity.shared.isScrolling { return }
            withAnimation(Motion.standard) { hover = inside }
        }
        .onAppear {
            guard !shown else { return }
            guard animate else { shown = true; return }
            withAnimation(.easeOut(duration: 0.9).delay(0.15)) { shown = true }
        }
        .accessibilityElement(children: .contain)
    }
}

extension OrnamentEmpty where Action == EmptyView {
    init(ornament: String, title: String, text: String) {
        self.init(ornament: ornament, title: title, text: text) { EmptyView() }
    }

    /// 不带按钮（下一步就在眼前时，如修行录正上方的落笔框）
    init(_ copy: EmptyCopy) {
        self.init(copy) { EmptyView() }
    }
}

/// 一行小字：图标 + 一句话（写法与文案见 Core/EmptyCopy.swift）。
/// 能就地做下一步时行尾带一个小操作 trailing：打开新建弹窗用 `.inlineAction(Theme.gold)`，去别的页用 `.cardLink`。
struct EmptyHint<Trailing: View>: View {
    var symbol: String
    var text: String
    @ViewBuilder var trailing: () -> Trailing

    init(symbol: String, text: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.symbol = symbol
        self.text = text
        self.trailing = trailing
    }

    init(_ line: EmptyCopy.Line, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(symbol: line.symbol, text: line.text, trailing: trailing)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Theme.inkSoft.opacity(0.8)).accessibilityHidden(true)
            Text(text).foregroundStyle(Theme.inkSoft)
            trailing()
        }
        .font(.ysCallout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

extension EmptyHint where Trailing == EmptyView {
    init(symbol: String, text: String) {
        self.init(symbol: symbol, text: text) { EmptyView() }
    }

    init(_ line: EmptyCopy.Line) {
        self.init(line) { EmptyView() }
    }
}
