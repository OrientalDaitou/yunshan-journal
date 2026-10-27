import SwiftUI
import SwiftData

struct ScheduleView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case week = "周视图", agenda = "近期列表", rules = "全部日程"
        var id: String { rawValue }
    }

    struct EditorRequest: Identifiable {
        var id = UUID()
        var event: ScheduleEvent?
        var day: LocalDay
        var startMinute: Int?
        /// “从这次起修改”：从这一次（按规则算出的原定日期）起拆成新系列
        var splitFrom: LocalDay? = nil
    }

    @Environment(\.modelContext) private var context
    // 日程不在这里整表取：周视图、近期列表各自只取窗口里可能出现的（ScheduleWindow），只有“全部日程”取全表
    @Query private var routine: [RoutineBlock]
    /// 有没有任何日程：只取 1 条的小查询（保存后 SwiftData 会重取，很便宜）。一个都没有时三种视图都给空状态，
    /// “新增日程”从工具条挪进空状态里（一屏只放一处）
    @Query(ScheduleView.firstEvent) private var anyEvent: [ScheduleEvent]
    @AppStorage("schedule.mode") private var modeRaw = Mode.week.rawValue
    @AppStorage("schedule.showRoutine") private var showRoutine = true
    @State private var weekStart = LocalDay.today().mondayOfWeek
    @State private var editor: EditorRequest?
    @State private var selected: OccurrenceItem?
    /// “仅修改这一次”的那一次发生
    @State private var onceEditor: OccurrenceItem?

    /// 全局搜索带来的日期：切到周视图并翻到那一周
    private func applyRoute() {
        guard let day = AppRouter.shared.scheduleDay else { return }
        modeRaw = Mode.week.rawValue
        weekStart = day.mondayOfWeek
        AppRouter.shared.scheduleDay = nil
    }

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .week }

    private static var firstEvent: FetchDescriptor<ScheduleEvent> {
        var descriptor = FetchDescriptor<ScheduleEvent>()
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// 新建日程：默认今天（或所看那一周的周一，取较晚的）9:00
    private func createEvent() {
        editor = EditorRequest(event: nil, day: max(.today(), weekStart), startMinute: 9 * 60)
    }

    /// 还没有任何日程时的“新增日程”（空状态里那一个；工具条里的这时不出现，⌘N 跟着它走）。
    /// 周视图里衬在一行小字后面，用紧凑的主按钮
    private func firstEventButton(compact: Bool = false) -> some View {
        Button(action: createEvent) { Label("新增日程", systemImage: "plus") }
            .buttonStyle(YunshanButtonStyle(primary: true, compact: compact))
            .keyCommand(.newEvent)
            .help(KeyCommand.newEvent.help("新增日程") + "；也可以在周视图的空白处双击")
    }

    var body: some View {
        // 整页一起滚动：周视图展开成完整高度，不再卡在剩余空间里单独滚动。
        // 横幅只留眉题、标题和一句短句：“全部日程”就是下面分段里的一项，“新增日程”在分段这一行的最右边
        PageScaffold(page: .schedule) {
            // 分段工具条与下面的视图挨得近一些（10），和别的卡片之间仍是卡距
            VStack(alignment: .leading, spacing: 10) {
                toolbar
                switch mode {
                case .week:
                    // 周导航是日历卡的第一行：一个容器、一种圆角。一个日程都没有时，第一行下面多一行小字和“新增日程”
                    WeekSection(weekStart: $weekStart, showRoutine: $showRoutine, routine: routine, noEvents: anyEvent.isEmpty,
                                onSelect: { selected = $0 },
                                onCreate: { day, minute in editor = EditorRequest(event: nil, day: day, startMinute: minute) }) {
                        if anyEvent.isEmpty {
                            EmptyHint(.weekEmpty) { firstEventButton(compact: true) }
                        }
                    }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .xianCard(padding: 0, tier: .jade)
                        .ysEntrance(order: 0)
                case .agenda, .rules:
                    if anyEvent.isEmpty {
                        // 一个日程都没有：近期列表与全部日程同一张留白
                        OrnamentEmpty(.schedule) { firstEventButton() }
                            .xianCard(tier: .jade)
                            .ysEntrance(order: 0)
                    } else if mode == .agenda {
                        AgendaSection(onSelect: { selected = $0 })
                    } else {
                        RulesSection(onEdit: { editor = EditorRequest(event: $0, day: $0.startDay, startMinute: $0.startMinute) })
                            .ysEntrance(order: 0)
                    }
                }
            }
        }
        .onAppear(perform: applyRoute)
        .onChange(of: AppRouter.shared.scheduleDay) { _, _ in applyRoute() }
        .sheet(item: $editor) { request in
            EventEditor(event: request.event, defaultDay: request.day, defaultStart: request.startMinute, splitFrom: request.splitFrom)
        }
        .sheet(item: $selected) { item in
            OccurrenceDetail(item: item, onEdit: {
                selected = nil
                editor = EditorRequest(event: item.event, day: item.event.startDay, startMinute: item.event.startMinute)
            }, onEditOnce: {
                selected = nil
                onceEditor = item
            }, onEditFromHere: {
                selected = nil
                editor = EditorRequest(event: item.event, day: item.sourceDay, startMinute: item.event.startMinute, splitFrom: item.sourceDay)
            })
        }
        .sheet(item: $onceEditor) { item in OccurrenceEditor(item: item) }
    }

    /// 视图切换 + 新增日程（三种视图共用这一行，切换时不跳位）
    private var toolbar: some View {
        HStack(spacing: 12) {
            SegmentedTabs(options: Mode.allCases.map { ($0.rawValue, $0.rawValue) }, selection: $modeRaw)
            Spacer(minLength: 12)
            // 还没有日程时这个按钮在空状态里（一屏只放一处）
            if !anyEvent.isEmpty {
                Button(action: createEvent) { Label("新增日程", systemImage: "plus") }
                    // 紧凑的主按钮：和左边的分段控件差不多高，这一行不再一高一矮
                    .buttonStyle(YunshanButtonStyle(primary: true, compact: true))
                    .keyCommand(.newEvent)
                    .help(KeyCommand.newEvent.help("新增日程") + "；也可以在周视图的空白处双击")
            }
        }
    }

    /// “10月12日 – 18日”；跨月写“9月28日 – 10月4日”；不是今年的带年份
    static func weekRangeText(_ start: LocalDay) -> String {
        let end = start.adding(days: 6)
        if end.year != start.year { return "\(start.year)年\(start.shortLabel) – \(end.year)年\(end.shortLabel)" }
        let head = start.label(relativeTo: .today())
        if end.month != start.month { return "\(head) – \(end.shortLabel)" }
        return "\(head) – \(end.day)日"
    }
}

// MARK: - 按窗口取日程

/// 只取可能在 [first, last] 里出现的日程：重复日程、带单次改期的（改期可能把它挪进来，见 RecurrenceRule.occurrences），
/// 以及日期落在这段里的单次日程。日期一律是规范的 YYYY-MM-DD（编辑、导入、传书都经 LocalDay 写入），按字符串比较就是按日期比较。
/// 取出的是全表的一个子集、先后不变：拿去展开（Occurrences.list）的结果与整表展开完全相同，只是不必再碰几百个早已过去的单次日程。
enum ScheduleWindow {
    static func predicate(from first: LocalDay, to last: LocalDay) -> Predicate<ScheduleEvent> {
        let from = first.key, to = last.key
        return #Predicate<ScheduleEvent> { $0.recurrence != "none" || $0.overridesJSON != "" || ($0.dateKey >= from && $0.dateKey <= to) }
    }

    /// 不排序（与不带排序的整表 @Query 一样按库里的存放次序）
    static func descriptor(from first: LocalDay, to last: LocalDay) -> FetchDescriptor<ScheduleEvent> {
        FetchDescriptor(predicate: predicate(from: first, to: last))
    }
}

/// 周视图（含日历卡第一行）：只取这一周可能出现的日程，翻周时重取
private struct WeekSection<Notice: View>: View {
    @Binding var weekStart: LocalDay
    @Binding var showRoutine: Bool
    var routine: [RoutineBlock]
    /// 一个日程都没有：第一行不写“0 项安排”，只留下面那行空状态（与修行录卷中气象 0 篇时不写“共 0 篇”一致）
    var noEvents = false
    var onSelect: (OccurrenceItem) -> Void
    var onCreate: (LocalDay, Int) -> Void
    /// 第一行下面的一行小字（一个日程都没有时的空状态）；平时为空、不占地方
    @ViewBuilder var notice: () -> Notice
    @Query private var events: [ScheduleEvent]

    init(weekStart: Binding<LocalDay>, showRoutine: Binding<Bool>, routine: [RoutineBlock], noEvents: Bool = false,
         onSelect: @escaping (OccurrenceItem) -> Void, onCreate: @escaping (LocalDay, Int) -> Void,
         @ViewBuilder notice: @escaping () -> Notice) {
        _weekStart = weekStart
        _showRoutine = showRoutine
        self.routine = routine
        self.noEvents = noEvents
        self.onSelect = onSelect
        self.onCreate = onCreate
        self.notice = notice
        let start = weekStart.wrappedValue
        // 排序与原来整表的 @Query 相同（按日期），展开后同一时刻的几项先后不变
        _events = Query(filter: ScheduleWindow.predicate(from: start, to: start.adding(days: 6)), sort: \ScheduleEvent.dateKey)
    }

    var body: some View {
        // 本周的发生只展开一次，计数和网格共用
        let weekItems = Occurrences.list(events: events, from: weekStart, to: weekStart.adding(days: 6))
        VStack(spacing: 0) {
            weekBar(count: weekItems.count)
            notice()
                .padding(.horizontal, 22)
                .padding(.bottom, 6)
            WeekGridView(days: LocalDay.range(weekStart, weekStart.adding(days: 6)),
                         items: weekItems,
                         routine: showRoutine ? routine : [],
                         onSelect: onSelect,
                         onCreate: onCreate)
        }
    }

    /// 日历卡第一行：本周日期、安排数、作息开关、翻周
    private func weekBar(count: Int) -> some View {
        CardTitle(title: ScheduleView.weekRangeText(weekStart), detail: noEvents && count == 0 ? "" : "\(count) 项安排") {
            HStack(spacing: 10) {
                Toggle("显示作息", isOn: $showRoutine).font(.ysCallout)
                    .padding(.trailing, 4)
                Button { weekStart = weekStart.adding(days: -7) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.yunshanCompact)
                    .keyCommand(.weekPrev)
                    .help(KeyCommand.weekPrev.help("上一周"))
                    .accessibilityLabel("上一周")
                Button("今天") { weekStart = LocalDay.today().mondayOfWeek }
                    .buttonStyle(.yunshanCompact)
                    .keyCommand(.weekToday)
                    .help(KeyCommand.weekToday.help("回到本周"))
                    .disabled(weekStart == LocalDay.today().mondayOfWeek)
                Button { weekStart = weekStart.adding(days: 7) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.yunshanCompact)
                    .keyCommand(.weekNext)
                    .help(KeyCommand.weekNext.help("下一周"))
                    .accessibilityLabel("下一周")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}

/// 近期列表：只取今天起 30 天里可能出现的日程
private struct AgendaSection: View {
    var onSelect: (OccurrenceItem) -> Void
    @Query private var events: [ScheduleEvent]
    private let today: LocalDay

    init(onSelect: @escaping (OccurrenceItem) -> Void) {
        self.onSelect = onSelect
        let today = LocalDay.today()
        self.today = today
        _events = Query(filter: ScheduleWindow.predicate(from: today, to: today.adding(days: 30)), sort: \ScheduleEvent.dateKey)
    }

    var body: some View {
        AgendaList(items: Occurrences.list(events: events, from: today, to: today.adding(days: 30)), onSelect: onSelect)
    }
}

/// 全部日程：只有这一页要整表
private struct RulesSection: View {
    var onEdit: (ScheduleEvent) -> Void
    @Query(sort: \ScheduleEvent.dateKey) private var events: [ScheduleEvent]

    var body: some View {
        RulesList(events: events, onEdit: onEdit)
    }
}

// MARK: - 周视图

struct WeekGridView: View {
    var days: [LocalDay]
    var items: [OccurrenceItem]
    var routine: [RoutineBlock]
    var onSelect: (OccurrenceItem) -> Void
    var onCreate: (LocalDay, Int) -> Void

    /// 鼠标停在哪一天的哪个半小时空格上：在那里淡淡提示“双击新建”
    private struct HoverSlot: Equatable {
        var day: LocalDay
        var minute: Int
    }
    @State private var hoverSlot: HoverSlot?
    /// 错位叠放时鼠标停在哪一块上：那一块浮到最上、标题回到块顶。由这一天的 onContinuousHover 按指针位置和
    /// 原先的层次算（WeekStack.topmost），不靠各块自己的 onHover：先浮起的大块会把落在它里面的小块整个盖住，
    /// 小块再也收不到悬停、点下去打开的是大块
    @State private var liftedBlock: String?

    private let hourHeight: CGFloat = 44
    private let gutter: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // 本周没有全天日程时，不占一行
            if items.contains(where: { $0.startMinute == nil }) {
                allDayRow
                Divider()
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(hours, id: \.self) { hour in
                        // 时刻用正文字体的等宽数字，不用像终端的代码字体
                        Text(String(format: "%02d:00", hour))
                            .font(.ysMicro.monospacedDigit())
                            .foregroundStyle(Theme.inkSoft)
                            .frame(width: gutter, height: hourHeight, alignment: .topTrailing)
                            .padding(.trailing, 4)
                            .offset(y: -6)
                            .id(hour)
                    }
                }
                let labels = Self.routineLabels(days: days, items: items, routine: routine, startHour: startHour)
                ForEach(days, id: \.self) { day in
                    dayColumn(day, labeled: labels[day] ?? [])
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
    }

    /// 画哪几个钟点：默认 06:00–24:00，本周有更早的日程就从那一小时开始（作息只作底纹，不影响起点）；
    /// 本周一项日程都没有时只画 08–20 点、格线淡一半，不再拉出一大片空格（WeekStack.hours）
    private var hours: Range<Int> { WeekStack.hours(hasItems: !items.isEmpty, earliestMinute: items.compactMap(\.startMinute).min()) }
    private var startHour: Int { hours.lowerBound }
    private var endHour: Int { hours.upperBound }
    /// 格线的浓淡：空周淡一半
    private var gridLine: Color { Theme.line.opacity(items.isEmpty ? 0.3 : 0.6) }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter + 4, height: 1)
            ForEach(days, id: \.self) { day in
                let isToday = day == .today()
                VStack(spacing: 2) {
                    Text(day.weekdayName).font(.ysCaption).foregroundStyle(Theme.inkSoft)
                    // “今天”只留表头这枚玉色圆点和当前时刻线
                    Text("\(day.day)")
                        .font(Theme.figure(TypeSize.heading, isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? Theme.onJadeFill : Theme.ink)
                        .frame(width: 30, height: 30)
                        .background { if isToday { Circle().fill(Theme.jadeFill) } }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(day.shortLabel) \(day.weekdayName)" + (isToday ? "，今天" : ""))
            }
        }
    }

    private var allDayRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("全天").font(.ysCaption).foregroundStyle(Theme.inkSoft).frame(width: gutter + 4, alignment: .trailing).padding(.top, 4)
            ForEach(days, id: \.self) { day in
                VStack(spacing: 2) {
                    ForEach(items.filter { $0.day == day && $0.startMinute == nil }) { item in
                        Button { onSelect(item) } label: {
                            Text(item.title).font(.ysCaption).foregroundStyle(Theme.ink).lineLimit(1)
                                .padding(.leading, 6).padding(.trailing, 4).padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.color(for: item.category).opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(Theme.color(for: item.category)).frame(width: 2.5)
                                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                }
                        }
                        .buttonStyle(.plain)
                        .help(item.title)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .top)
                .padding(2)
            }
        }
    }

    private struct Placed: Identifiable {
        var item: OccurrenceItem
        var start: Int
        var end: Int
        var slot: WeekStack.Slot
        var id: String { item.id }
    }

    /// 有钟点的日程 → 占的时段（结束至少 20 分钟，没写结束算一小时）；周视图与自检（SelfTest+Schedule）共用
    static func spans(_ dayItems: [OccurrenceItem]) -> [(item: OccurrenceItem, span: WeekStack.Span)] {
        dayItems.compactMap { item in
            guard let s = item.startMinute else { return nil }
            return (item, WeekStack.Span(start: s, end: max(s + 20, item.endMinute ?? s + 60)))
        }
    }

    /// 标题（时间一行 + 标题一行，约 34pt）折成分钟，按周视图每小时 44pt 算；自检也用这个数
    static let labelMinutes = Int((34.0 / 44 * 60).rounded(.up))

    /// 重叠日程：宽够就并排；窄了 3 列起错位叠放、被压住的标题挪到露出来的地方（规则见 Core/WeekStack.swift）
    private func layout(_ dayItems: [OccurrenceItem], width: CGFloat) -> [Placed] {
        let timed = Self.spans(dayItems)
        let slots = WeekStack.layout(timed.map(\.span), dayWidth: Double(width), labelMinutes: Self.labelMinutes)
        return zip(timed, slots).map { Placed(item: $0.item, start: $0.span.start, end: $0.span.end, slot: $1) }
    }

    private func y(_ minute: Int) -> CGFloat { CGFloat(minute - startHour * 60) / 60 * hourHeight }

    /// 指针下该浮起的那块（WeekStack.topmost，按原先层次、块最矮 18pt 算）；不是叠放的块不浮起
    private func liftTarget(_ placed: [Placed], at point: CGPoint, width: CGFloat) -> String? {
        let minute = Double(point.y / hourHeight * 60) + Double(startHour * 60)
        let index = WeekStack.topmost(at: minute, x: Double(point.x), spans: placed.map { WeekStack.Span(start: $0.start, end: $0.end) },
                                      slots: placed.map(\.slot), dayWidth: Double(width), minMinutes: Double(18 / hourHeight * 60))
        guard let index, placed[index].slot.stacked else { return nil }
        return placed[index].id
    }

    /// 双击 / 悬停处对应的新建时刻：按半小时取整，最晚 23:00（新建默认一小时）
    private func createMinute(at pointY: CGFloat) -> Int {
        min(23 * 60, max(0, (Int(pointY / hourHeight * 60) + startHour * 60) / 30 * 30))
    }

    /// 这一天的作息切段（跨夜的按 RoutineBlock.segments 切开），只取画得到的部分
    private func routineSegments(_ day: LocalDay) -> [(block: RoutineBlock, start: Int, end: Int, carried: Bool)] {
        Self.routineSegments(routine, day: day, startHour: startHour)
    }

    private static func routineSegments(_ routine: [RoutineBlock], day: LocalDay, startHour: Int) -> [(block: RoutineBlock, start: Int, end: Int, carried: Bool)] {
        RoutineBlock.segments(routine, weekday: day.weekdayIndex).filter { $0.end > startHour * 60 }
    }

    static func segmentKey(_ segment: (block: RoutineBlock, start: Int, end: Int, carried: Bool)) -> String {
        "\(segment.block.title)|\(segment.start)|\(segment.end)"
    }

    /// 每天哪些作息段要写名字：同一段（名字、起止都相同）只在第一次出现的那天写，后面几天只留底纹；
    /// 那天名字的位置压着日程就不写，留到下一天再写，免得一整周都看不到它叫什么。自检（SelfTest+Schedule）也用它
    static func routineLabels(days: [LocalDay], items: [OccurrenceItem], routine: [RoutineBlock], startHour: Int) -> [LocalDay: Set<String>] {
        var result: [LocalDay: Set<String>] = [:]
        var known: Set<String> = []
        for day in days {
            let timed = items.filter { $0.day == day }.compactMap { item -> (start: Int, end: Int)? in
                guard let s = item.startMinute else { return nil }
                return (s, max(s + 20, item.endMinute ?? s + 60))
            }
            var labeled: Set<String> = []
            var knownToday: Set<String> = []
            for segment in routineSegments(routine, day: day, startHour: startHour) {
                let key = segmentKey(segment)
                if known.contains(key) {
                    knownToday.insert(key)
                    continue
                }
                // 名字写在段的顶上（约 20 分钟高）：那里压着日程就不写（写了也只从日程边上露出一个图标或半个字），
                // 也不算写过，留到下一天再写
                let top = max(segment.start, startHour * 60)
                if !timed.contains(where: { $0.start < top + 20 && $0.end > top }) {
                    labeled.insert(key)
                    knownToday.insert(key)
                }
            }
            result[day] = labeled
            known = knownToday
        }
        return result
    }

    /// labeled：这一天要写名字的作息段（见 routineLabels）
    private func dayColumn(_ day: LocalDay, labeled: Set<String>) -> some View {
        let dayItems = items.filter { $0.day == day }
        let isToday = day == .today()
        let segments = routineSegments(day)
        let gridHeight = hourHeight * CGFloat(hours.count)
        return GeometryReader { geo in
            let placed = layout(dayItems, width: geo.size.width)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(hours, id: \.self) { _ in
                        Rectangle().fill(Color.clear).frame(height: hourHeight)
                            .overlay(alignment: .top) { Rectangle().fill(gridLine).frame(height: 0.5) }
                    }
                }
                // 作息只是淡淡的底纹：约 5% 的类别色，不画圆角块
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    let kind = RoutineKind.of(segment.block.kind)
                    let color = Theme.color(for: kind)
                    let top = y(max(segment.start, startHour * 60))
                    Rectangle()
                        .fill(color.opacity(0.05))
                        .overlay(alignment: .topLeading) {
                            if labeled.contains(Self.segmentKey(segment)) {
                                Label(segment.block.title, systemImage: kind.symbol)
                                    .font(.ysMicro)
                                    .foregroundStyle(color.opacity(0.85))
                                    .padding(.leading, 6)
                                    .padding(.top, 3)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: geo.size.width, height: max(4, y(segment.end) - top))
                        .offset(y: top)
                        .allowsHitTesting(false)
                }
                // 日程块单独一层：叠放时靠 zIndex 排上下（后一列在上，悬停的那块浮到最上），
                // 不会盖过下面的“双击新建”提示和当前时刻线
                ZStack(alignment: .topLeading) {
                    ForEach(placed) { p in
                        let frame = WeekStack.frame(p.slot, dayWidth: Double(geo.size.width))
                        let lifted = p.slot.stacked && liftedBlock == p.id
                        // 叠放且没浮起时，标题只能写在露出来的那一段里（labelRoom），按那一段的高矮挑写法
                        let covered = p.slot.stacked && !lifted && p.slot.labelOffset + p.slot.labelRoom < p.end - p.start
                        EventBlock(item: p.item,
                                   compact: frame.width < WeekStack.compactWidth,
                                   stacked: p.slot.stacked,
                                   labelInset: lifted ? 0 : CGFloat(p.slot.labelOffset) / 60 * hourHeight,
                                   labelRoom: covered ? CGFloat(p.slot.labelRoom) / 60 * hourHeight : nil)
                            .frame(width: CGFloat(frame.width), height: max(18, y(p.end) - y(p.start) - 1))
                            .offset(x: CGFloat(frame.x), y: y(p.start))
                            .zIndex(lifted ? 1000 : Double(p.slot.column))
                            .onTapGesture { onSelect(p.item) }
                    }
                }
                .frame(width: geo.size.width, height: gridHeight, alignment: .topLeading)
                // 悬停在空白处：淡淡标出双击会新建在哪个时刻（盖住的是作息底纹，不压到日程上）
                if let slot = hoverSlot, slot.day == day,
                   !placed.contains(where: { $0.start < slot.minute + 30 && slot.minute < $0.end }) {
                    CreateHint(minute: slot.minute)
                        .frame(width: max(10, geo.size.width - 4), height: hourHeight / 2 - 2)
                        .offset(x: 2, y: y(slot.minute) + 1)
                        .allowsHitTesting(false)
                }
                if isToday {
                    // 当前时刻线：每分钟更新一次
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let now = ClockTime.minutes(of: context.date)
                        if now >= startHour * 60 && now < endHour * 60 {
                            HStack(spacing: 0) {
                                Circle().fill(Theme.cinnabar).frame(width: 7, height: 7)
                                Rectangle().fill(Theme.cinnabar).frame(height: 1.2)
                            }
                            .offset(x: -3, y: y(now) - 3.5)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, coordinateSpace: .local) { point in
                hoverSlot = nil
                onCreate(day, createMinute(at: point.y))
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                let mine = liftedBlock.map { id in placed.contains { $0.id == id } } ?? false
                switch phase {
                case .active(let point):
                    // 正在滑动时不跟着变（内容从鼠标下经过）
                    let scrolling = ScrollActivity.shared.isScrolling
                    let slot: HoverSlot? = scrolling ? nil : HoverSlot(day: day, minute: createMinute(at: point.y))
                    if slot != hoverSlot { hoverSlot = slot }
                    // 浮起指针下按原先层次最上面的那块（只有叠放的块才浮起）；离开所有块就放下
                    let lift = scrolling ? nil : liftTarget(placed, at: point, width: geo.size.width)
                    if lift != liftedBlock, lift != nil || mine { liftedBlock = lift }
                case .ended:
                    if hoverSlot?.day == day { hoverSlot = nil }
                    if mine { liftedBlock = nil }
                }
            }
        }
        .frame(height: gridHeight)
        .clipped()
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) { Rectangle().fill(gridLine).frame(width: 0.5) }
    }
}

/// 周视图空白处的“双击新建”淡字提示（只在悬停时出现）
private struct CreateHint: View {
    var minute: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        HStack(spacing: 3) {
            Image(systemName: "plus").imageScale(.small)
            Text("双击新建 \(ClockTime.text(minute))")
        }
        .font(.ysMicro.monospacedDigit())
        .foregroundStyle(Theme.inkSoft)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.card.opacity(0.9), in: shape)
        .overlay(shape.strokeBorder(Theme.jade.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .accessibilityHidden(true)
    }
}

/// 周视图里的一块日程：像一张便笺压在作息底纹之上——先铺不透明的纸色，再叠淡淡的类别色，左侧 3pt 色条。
/// 宽够时写“时间 ↻ / 标题 / 地点”，块矮就按放得下的少写几行（见 label）；窄块（< 64pt）只写一行标题，时间与地点进悬停说明。
/// 错位叠放时描一圈 1pt 纸色细边，和压在下面的那块分开；标题被上层压住时往下挪到露出来的地方（labelInset），
/// 下面又被压住时只按露出来的那一段（labelRoom）挑写法，不让后几行字钻到上层块底下、只从露边里露出半截。
/// 字只叠在色块上、超出就裁掉：块的高矮只由时段决定（原来字多时块会被撑高、上下各多出一截，看着像提前开始）。
struct EventBlock: View {
    var item: OccurrenceItem
    var compact = false
    var stacked = false
    var labelInset: CGFloat = 0
    /// 标题顶往下露出来多高（pt）；nil = 一直到块底。浮到最上时周视图传 nil
    var labelRoom: CGFloat? = nil
    @Environment(\.spiritMotion) private var motion
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        let color = Theme.color(for: item.category)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        // 深色下类别色叠得浓一些：只叠 12% 时几乎是一块中性灰，和作息底纹分不开
        let tint = scheme == .dark ? (hover ? 0.3 : 0.22) : (hover ? 0.18 : 0.12)
        let recurring = item.event.recurrenceKind != .none
        ZStack {
            shape.fill(Theme.card)
            shape.fill(color.opacity(tint))
        }
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        .overlay(alignment: .topLeading) {
            // 露出来的那一段里扣掉上边距，再留 2pt 不贴着压在上面的那块
            label(color: color, recurring: recurring)
                .frame(maxHeight: labelRoom.map { max(0, $0 - (compact ? 3 : 4) - 2) }, alignment: .topLeading)
                .padding(.leading, compact ? 6 : 8)
                .padding(.trailing, compact ? 3 : 5)
                .padding(.top, (compact ? 3 : 4) + labelInset)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .clipShape(shape)
        .overlay { if stacked { shape.strokeBorder(Theme.card, lineWidth: 1) } }
        .contentShape(shape)
        .onHover { inside in
            if !(inside && ScrollActivity.shared.isScrolling) { hover = inside }
        }
        .animation(motion ? Motion.hover : nil, value: hover)
        .animation(motion ? Motion.hover : nil, value: labelInset)
        .help(helpText(recurring: recurring))
    }

    @ViewBuilder
    /// 块里写什么：按块的高矮挑放得下的那一种（ViewThatFits 只量高度，宽度照块宽折行）——
    /// 有地点：时间 ↻ / 标题两行 / 地点 → 地点并到时间那一行（“10:00 ↻ · 地理系 F09”）、标题两行 → 标题一行；
    /// 没地点：时间 ↻ / 标题两行 → 标题一行；再矮就时间和标题并一行，最后只剩标题。
    /// 放不全的行不画，不再露半行字。窄块只写一行标题
    private func label(color: Color, recurring: Bool) -> some View {
        let title = Text(item.title).font(.system(size: TypeSize.caption, weight: .medium)).foregroundStyle(Theme.ink)
        let clock = Text(ClockTime.text(item.startMinute)).font(.ysMicro.monospacedDigit()).foregroundStyle(Theme.inkSoft)
        // 循环图标跟在时间后面，不再压在时间上
        let icon = Image(systemName: "arrow.clockwise").font(.ysMicro).imageScale(.small).foregroundStyle(color)
            .accessibilityHidden(true)
        let time = HStack(spacing: 3) {
            clock
            if recurring { icon }
        }
        .fixedSize()
        let location = Text(item.location).font(.ysMicro).foregroundStyle(Theme.inkSoft).lineLimit(1)
        // 一小时上下的块：地点跟在时间后面，省出一行给标题；连四五个字都放不下时就只写时间（不留“地…”）
        let place = Text("· \(item.location)").font(.ysMicro).foregroundStyle(Theme.inkSoft).lineLimit(1)
        let timePlace = ViewThatFits(in: .horizontal) {
            HStack(spacing: 3) { time; place.fixedSize() }
            HStack(spacing: 3) { time; place.frame(idealWidth: 52, alignment: .leading) }
            time
        }
        if compact {
            title.lineLimit(1).minimumScaleFactor(0.85)
        } else {
            ViewThatFits(in: .vertical) {
                if item.location.isEmpty {
                    VStack(alignment: .leading, spacing: 1) { time; title.lineLimit(2) }
                    VStack(alignment: .leading, spacing: 1) { time; title.lineLimit(1) }
                } else {
                    VStack(alignment: .leading, spacing: 1) { time; title.lineLimit(2); location }
                    VStack(alignment: .leading, spacing: 1) { timePlace; title.lineLimit(2) }
                    VStack(alignment: .leading, spacing: 1) { timePlace; title.lineLimit(1) }
                }
                // 半小时上下的矮块：一行写下，宽不够先省循环图标、再省时间（时间看所在的格子、悬停说明里也有）
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { time; title.lineLimit(1).fixedSize() }
                    HStack(spacing: 4) { clock.fixedSize(); title.lineLimit(1).fixedSize() }
                    title.lineLimit(1).minimumScaleFactor(0.85)
                }
            }
        }
    }

    /// 悬停说明：标题、时段，有地点带地点，重复的注明（窄块只写标题，时间地点都靠这一句）
    private func helpText(recurring: Bool) -> String {
        var parts = ["\(item.title) \(ClockTime.range(item.startMinute, item.endMinute))"]
        if !item.location.isEmpty { parts.append(item.location) }
        if recurring { parts.append("重复日程") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 列表

/// 近期列表：一张卡，按天分小节（日期小标题，今天挂金圈），每行整行可点（点开这一次的详情）。
/// 不再一天一张卡：30 天十几张带描边的卡叠在一起太碎。
struct AgendaList: View {
    var items: [OccurrenceItem]
    var onSelect: (OccurrenceItem) -> Void

    var body: some View {
        let grouped = Dictionary(grouping: items, by: \.day)
        let today = LocalDay.today()
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty { EmptyHint(.agendaEmpty) }
            ForEach(Array(grouped.keys.sorted().enumerated()), id: \.element) { order, day in
                let dayItems = grouped[day] ?? []
                dayHeader(day, count: dayItems.count, today: today)
                    .padding(.top, order == 0 ? 0 : 20)
                    .padding(.bottom, 2)
                ForEach(Array(dayItems.enumerated()), id: \.element.id) { index, item in
                    EditableRow(dividerAbove: index > 0, editLabel: "查看详情", action: { onSelect(item) }) {
                        row(item)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .xianCard(tier: .jade)
        .ysEntrance(order: 0)
    }

    /// 一天的小标题：“10月14日 · 周三 [今天] ———— 2 项”
    private func dayHeader(_ day: LocalDay, count: Int, today: LocalDay) -> some View {
        HStack(spacing: 10) {
            Text("\(day.label(relativeTo: today)) · \(day.weekdayName)")
                .font(Theme.songti(TypeSize.callout, .semibold))
                .foregroundStyle(Theme.ink)
            if day == today { TodayMark() }
            Rectangle().fill(Theme.line.opacity(0.8)).frame(height: 1)
            Text("\(count) 项").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ item: OccurrenceItem) -> some View {
        HStack(spacing: 10) {
            Text(ClockTime.range(item.startMinute, item.endMinute))
                .font(.ysCallout.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                .frame(width: 104, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(Theme.color(for: item.category)).frame(width: 4, height: 20)
            Text(item.title).foregroundStyle(Theme.ink).lineLimit(1)
            if !item.category.isEmpty { Chip(text: item.category, color: Theme.color(for: item.category)) }
            // 挪了日期或时间才叫“改期”；只改标题、地点、备注的是“单次修改”（与详情页说法一致）
            if item.isRescheduled {
                Chip(text: "已改期", color: Theme.info)
            } else if item.isOverride {
                Chip(text: "单次修改", color: Theme.inkSoft)
            }
            Spacer(minLength: 8)
            if !item.location.isEmpty {
                Label(item.location, systemImage: "mappin").font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(1)
            }
        }
    }
}

/// “今天”：金色细圈（与月历一致），不用朱砂
private struct TodayMark: View {
    var body: some View {
        Text("今天")
            .font(.ysCaption)
            .foregroundStyle(Theme.gold)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.7), lineWidth: 1))
    }
}

/// 全部日程：整行可点编辑；右键菜单（或编辑窗口里）可删除。
struct RulesList: View {
    var events: [ScheduleEvent]
    var onEdit: (ScheduleEvent) -> Void
    @Environment(\.modelContext) private var context
    @State private var showEnded = false
    @State private var pendingDelete: ScheduleEvent?

    /// 已经不会再出现：截止日已过、已停止，或单次日程已过去
    private static func isEnded(_ event: ScheduleEvent, today: LocalDay) -> Bool {
        if event.recurrenceKind == .none { return event.startDay < today }
        return (event.repeatUntil.flatMap(LocalDay.init(key:)).map { $0 < today } ?? false)
            || (event.stopBefore.flatMap(LocalDay.init(key:)).map { $0 <= today } ?? false)
    }

    /// 一遍分成已结束 / 进行中的重复 / 进行中的单次三组（各组内的先后与原来逐组 filter 的相同）
    private static func partition(_ events: [ScheduleEvent], today: LocalDay) -> (ended: [ScheduleEvent], recurring: [ScheduleEvent], single: [ScheduleEvent]) {
        var ended: [ScheduleEvent] = [], recurring: [ScheduleEvent] = [], single: [ScheduleEvent] = []
        for event in events {
            if isEnded(event, today: today) {
                ended.append(event)
            } else if event.recurrenceKind != .none {
                recurring.append(event)
            } else {
                single.append(event)
            }
        }
        return (ended, recurring, single)
    }

    /// 最后一次可能出现的日期（已结束的按它倒序排）
    private static func lastDay(_ event: ScheduleEvent) -> LocalDay {
        guard event.recurrenceKind != .none else { return event.startDay }
        let bounds = [event.repeatUntil.flatMap(LocalDay.init(key:)), event.stopBefore.flatMap(LocalDay.init(key:))?.adding(days: -1)]
        return bounds.compactMap { $0 }.min() ?? event.startDay
    }

    var body: some View {
        let groups = Self.partition(events, today: LocalDay.today())
        let endedEvents = groups.ended, recurringEvents = groups.recurring, singleEvents = groups.single
        // 进行中的重复日程按星期、时间排；今天及以后的单次日程按日期排；已结束的按结束日期倒序、默认折叠（折叠时不排）。
        // 排序键先取出来再排：比较时不必反复解析日期、读 SwiftData 属性；比较规则与原来逐项相同
        let recurring = recurringEvents.map { (event: $0, key: ($0.startDay.weekdayIndex, $0.startMinute ?? -1, $0.title)) }
            .sorted { $0.key < $1.key }.map(\.event)
        let single = singleEvents.map { (event: $0, key: ($0.dateKey, $0.startMinute ?? -1, $0.title)) }
            .sorted { $0.key < $1.key }.map(\.event)
        let ended = showEnded
            ? endedEvents.map { (event: $0, last: Self.lastDay($0)) }.sorted { $0.last > $1.last }.map(\.event)
            : endedEvents
        VStack(alignment: .leading, spacing: 8) {
            if events.isEmpty { EmptyHint(symbol: "calendar", text: "还没有日程。") }
            if !recurring.isEmpty {
                SectionLabel(text: "重复日程（\(recurring.count)）")
                rows(recurring, ended: false)
            }
            if !single.isEmpty {
                SectionLabel(text: "单次日程（\(single.count)）").padding(.top, recurring.isEmpty ? 0 : 10)
                rows(single, ended: false)
            }
            if !ended.isEmpty {
                DisclosureGroup(isExpanded: $showEnded) {
                    rows(ended, ended: true)
                } label: {
                    Text("已结束（\(ended.count)）").font(.ysCaption).foregroundStyle(Theme.inkSoft)
                }
                .padding(.top, 10)
            }
        }
        .xianCard(tier: .jade)
        .confirmationDialog(pendingDelete?.recurrenceKind == RecurrenceKind.none ? "删除这个日程？" : "删除整个重复日程？",
                            isPresented: Binding(isPresent: $pendingDelete),
                            presenting: pendingDelete) { event in
            Button("删除", role: .destructive) {
                context.delete(event)
                DataStore.save(context)
                pendingDelete = nil
            }
        } message: { event in
            Text(event.recurrenceKind != .none ? "所有过去和未来的发生都会被删除，且无法恢复。若只是以后不再上，请用“从这次起停止”。" : "删除后无法恢复。")
        }
    }

    /// 一组日程：分隔线只画在两行之间。用 LazyVStack：展开几百条“已结束”时只画看得到的几行
    private func rows(_ list: [ScheduleEvent], ended: Bool) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, event in
                row(event, ended: ended, dividerAbove: index > 0)
            }
        }
    }

    /// 一行下面那句小字：单次写日期与时段；重复的写“重复方式　时段　起止”，起止并成一段放在最后——
    /// “每周一、四　13:00–15:00　2025年8月3日 – 11月7日”，没有止日写“自 2024年10月23日”。
    /// 日期不是今年的带年份（早就开始的系列不会读着像过几天才开始）；止日取最后一次可能出现的那天
    /// （截止日、“从这次起停止”的前一天，取早的）。重复方式只看规则本身，不必像 event.rule 那样解单次改期的 JSON
    static func when(_ event: ScheduleEvent, today: LocalDay) -> String {
        let time = ClockTime.range(event.startMinute, event.endMinute)
        guard event.recurrenceKind != .none else { return "\(event.startDay.longLabel)　\(time)" }
        let pattern = RecurrenceRule(start: event.startDay, kind: event.recurrenceKind, interval: event.interval,
                                     weekdays: event.weekdays).summary(relativeTo: today)
        let start = event.startDay.label(relativeTo: today)
        let bounded = event.repeatUntil != nil || event.stopBefore != nil
        let span = bounded ? "\(start) – \(lastDay(event).label(relativeTo: today))" : "自 \(start)"
        return "\(pattern)　\(time)　\(span)"
    }

    private func row(_ event: ScheduleEvent, ended: Bool, dividerAbove: Bool) -> some View {
        let when = Self.when(event, today: LocalDay.today())
        return EditableRow(dividerAbove: dividerAbove, onDelete: { pendingDelete = event }, action: { onEdit(event) }) {
            // 与近期列表同一种行：色条 + 标题 + 类别签，地点右对齐；下面一行小字是重复方式、时段与起止（见 when）
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.color(for: event.category)).frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(event.title).foregroundStyle(ended ? Theme.inkSoft : Theme.ink).lineLimit(1)
                        if !event.category.isEmpty {
                            Chip(text: event.category, color: ended ? Theme.inkSoft : Theme.color(for: event.category))
                        }
                        if ended { Chip(text: "已结束", color: Theme.inkSoft) }
                        // 飞剑传书写入的日程 legacyID 是 “courier:” + 编号，挂“传书”签；其余是旧版导入，
                        // 几乎每行都是，挂签只是噪音，改在悬停提示里说明
                        if let source = event.legacyID, source.hasPrefix("courier:") {
                            Chip(text: "传书", color: Theme.info)
                        }
                    }
                    Text(when).font(.ysCaption.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                }
                Spacer(minLength: 8)
                if !event.location.isEmpty || !event.excludedDates.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        if !event.location.isEmpty {
                            Label(event.location, systemImage: "mappin").font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(1)
                        }
                        if !event.excludedDates.isEmpty {
                            Text("已跳过 \(event.excludedDates.count) 次").font(.ysCaption).foregroundStyle(Theme.inkSoft)
                        }
                    }
                }
            }
            .help(event.legacyID.map { $0.hasPrefix("courier:") ? "由 AI 经飞剑传书写入" : "从旧版 APT 导入" } ?? "")
        }
    }
}

// MARK: - 单次详情

struct OccurrenceDetail: View {
    var item: OccurrenceItem
    var onEdit: () -> Void
    /// 重复日程“仅修改这一次”（为空时不显示该按钮）
    var onEditOnce: (() -> Void)? = nil
    /// 重复日程“从这次起修改”（拆分系列；为空、或这是第一次时不显示该按钮）
    var onEditFromHere: (() -> Void)? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteAll = false
    @State private var confirmStopAll = false

    var body: some View {
        let event = item.event
        let recurring = event.recurrenceKind != .none
        // 这一次的单次改动（备注也可能单独改过）
        let patch = event.rule.overrides[item.sourceDay.key]
        let notes = patch?.notes ?? event.notes
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                RoundedRectangle(cornerRadius: 3).fill(Theme.color(for: event.category)).frame(width: 6, height: 40)
                VStack(alignment: .leading) {
                    Text(item.title).font(.ysTitle).foregroundStyle(Theme.ink)
                    Text("\(item.day.longLabel)　\(ClockTime.range(item.startMinute, item.endMinute))").foregroundStyle(Theme.inkSoft)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                if recurring { GridRow { Text("重复").foregroundStyle(Theme.inkSoft); Text(event.rule.summary) } }
                if !event.category.isEmpty { GridRow { Text("类别").foregroundStyle(Theme.inkSoft); Text(event.category) } }
                if !item.location.isEmpty { GridRow { Text("地点").foregroundStyle(Theme.inkSoft); Text(item.location) } }
                GridRow { Text("优先级").foregroundStyle(Theme.inkSoft); Text(EventPriority(rawValue: event.priority)?.label ?? event.priority) }
                if item.isOverride {
                    GridRow {
                        Text("说明").foregroundStyle(Theme.inkSoft)
                        Text(item.isMovedToOtherDay ? "这一次已单独改期（原定 \(item.sourceDay.shortLabel)）"
                             : item.isRescheduled ? "这一次已单独改期（原定 \(ClockTime.range(event.startMinute, event.endMinute))）"
                             : "这一次已单独修改，系列的其他发生不受影响")
                    }
                }
                if !notes.isEmpty { GridRow { Text("备注").foregroundStyle(Theme.inkSoft); Text(notes) } }
            }
            Divider()
            if recurring {
                HStack {
                    if let onEditOnce {
                        Button("仅修改这一次") { onEditOnce() }
                            .help("只改这一次的日期、时间、标题、地点或备注，系列的其他发生不变")
                    }
                    // 第一次就“从这次起”等同于编辑整个系列，不另给按钮
                    if let onEditFromHere, item.sourceDay > event.startDay {
                        Button("从这次起修改") { onEditFromHere() }
                            .help("这一次及以后按新的设置，之前的保持原样（系列在这里拆成两段）")
                    }
                    Button("编辑整个系列") { onEdit() }
                        .help("修改会套用到这个系列过去和未来的每一次")
                }
            }
            HStack {
                if !recurring { Button("编辑") { onEdit() } }
                if recurring {
                    Button("仅删除这一次") {
                        if !event.excludedDates.contains(item.sourceDay.key) { event.excludedDates.append(item.sourceDay.key) }
                        event.updatedAt = Date()
                        DataStore.save(context)
                        dismiss()
                    }
                    .help("跳过这一次；之后可在“编辑整个系列”里恢复")
                    Button("从这次起停止") {
                        if item.sourceDay <= event.startDay {
                            // 第一次就停止 = 整个日程再也不会出现，直接删除，所以先确认
                            confirmStopAll = true
                        } else {
                            event.stopBefore = item.sourceDay.key
                            event.updatedAt = Date()
                            DataStore.save(context)
                            dismiss()
                        }
                    }
                    .help("保留之前的记录，这一次及以后都不再出现；之后可在“编辑整个系列”里恢复")
                    .confirmationDialog("这是第一次，停止即删除整个日程？", isPresented: $confirmStopAll) {
                        Button("删除整个日程", role: .destructive) {
                            context.delete(event)
                            DataStore.save(context)
                            dismiss()
                        }
                    } message: {
                        Text("从第一次起停止，这个日程就一次也不会再出现，所以会连同类别、地点、备注一起删除，且无法恢复。")
                    }
                }
                Button(recurring ? "删除整个系列" : "删除", role: .destructive) { confirmDeleteAll = true }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 600)
        .yunshanSheet()
        .confirmationDialog(recurring ? "删除整个重复日程？" : "删除这个日程？", isPresented: $confirmDeleteAll) {
            Button("删除", role: .destructive) {
                context.delete(event)
                DataStore.save(context)
                dismiss()
            }
        } message: {
            Text(recurring ? "所有过去和未来的发生都会被删除，且无法恢复。若只是以后不再上，请用“从这次起停止”。" : "删除后无法恢复。")
        }
    }
}

extension OccurrenceItem {
    /// 这一次被单独挪到了别的日子
    var isMovedToOtherDay: Bool { day != sourceDay }

    /// 这一次单独改了日期或时间（只改标题、地点、备注的不算“改期”）。近期列表和单次详情共用。
    var isRescheduled: Bool {
        guard isOverride else { return false }
        return isMovedToOtherDay || startMinute != event.startMinute || endMinute != event.endMinute
    }
}
