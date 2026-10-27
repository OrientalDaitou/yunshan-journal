import SwiftUI
import SwiftData

/// 新建 / 编辑日程（整个系列），以及“从这次起修改”（把系列从这一次起拆成新系列）。
struct EventEditor: View {
    var event: ScheduleEvent?
    var defaultDay: LocalDay
    var defaultStart: Int?
    /// “从这次起修改”：保存时把 event 从这一天（这一次的原定日期）起拆成新系列，之前的保持原样
    var splitFrom: LocalDay? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allEvents: [ScheduleEvent]
    @Query private var settingsList: [AppSettings]
    @State private var title = ""
    @State private var dateKey = LocalDay.today().key
    @State private var allDay = false
    @State private var start = 9 * 60
    @State private var end = 10 * 60
    @State private var category = ""
    @State private var location = ""
    @State private var priority = "should"
    @State private var recurrence = RecurrenceKind.none
    @State private var interval = 1
    @State private var weekdays: [Int] = []
    @State private var hasUntil = false
    @State private var until = LocalDay.today().adding(days: 90).key
    @State private var notes = ""
    /// “从这次起停止”留下的停止日（这一天及以后不再出现），可在编辑器里恢复
    @State private var stopBefore: String?
    /// “仅删除这一次”跳过的日期，可逐个恢复
    @State private var excludedDates: [String] = []
    /// 保存失败的原因（例如原有的单次改期数据无法解析）
    @State private var failure: String?
    @State private var confirmDelete = false
    /// 标题框碰过了（点过保存，或光标离开过标题框）：这之前标题空着也不先报红字
    @State private var titleTouched = false
    @FocusState private var titleFocused: Bool

    private var categories: [String] { Array(Set(allEvents.map(\.category).filter { !$0.isEmpty })).sorted() }

    private var startDay: LocalDay { LocalDay(key: dateKey) ?? defaultDay }

    /// 真正要拆分的那一天：只对重复日程、且不是第一次时拆（第一次就“从这次起”等同于编辑整个系列）
    private var splitDay: LocalDay? {
        guard let splitFrom, let event, event.recurrenceKind != .none, splitFrom > event.startDay else { return nil }
        return splitFrom
    }

    /// 打开时的开始日期（拆分时是这一次的原定日期），用来判断用户有没有挪开始日期
    private var baseDateKey: String? { splitDay?.key ?? event?.dateKey }

    /// 新系列要带上的单次改期：拆分时只取这一天及以后的，否则是原日程全部的
    private var carriedOverridesJSON: String {
        guard let event else { return "" }
        guard let splitDay else { return event.overridesJSON }
        return SeriesSplit.partitionOverrides(event.overridesJSON, at: splitDay)?.after ?? ""
    }

    /// 保存时实际写入的停止日：改成不重复、或把开始日期挪到停止日当天及以后（否则整条日程一次都不会出现）时自动解除。
    /// 没挪开始日期就保持原样（由用户点“恢复系列”），免得只是打开再保存就让停掉的系列复活。
    private var effectiveStopBefore: String? {
        guard recurrence != .none, let stopBefore, let stop = LocalDay(key: stopBefore) else { return nil }
        if stop <= startDay && baseDateKey != dateKey { return nil }
        return stopBefore
    }

    /// 不重复且挪了日期：旧的单次改期都对不上了，保存时清掉（只改别的字段时保留旧版导入的改期）
    private var dropsOverrides: Bool { recurrence == .none && event != nil && baseDateKey != dateKey }

    /// 与保存后一致的规则：带上停止日、跳过的日期和单次改期，预览文案和冲突提醒才与实际相符
    private var draftRule: RecurrenceRule {
        RecurrenceRule(start: startDay, kind: recurrence, interval: interval, weekdays: weekdays,
                       repeatUntil: recurrence != .none && hasUntil ? LocalDay(key: until) : nil,
                       stopBefore: effectiveStopBefore.flatMap(LocalDay.init(key:)),
                       excluded: recurrence == .none ? [] : Set(excludedDates),
                       overrides: dropsOverrides ? [:] : OccurrencePatch.decodeMap(carriedOverridesJSON))
    }

    private var titleMissing: Bool { title.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 能不能保存（标题空着也算不能）；冲突提醒、“一次也不会出现”都按它
    private var validationMessage: String? { validation(checkTitle: true) }

    /// 底栏的红字：标题还没碰过时不先报“请填写标题”（刚打开新建弹窗就挨一句批评）；其余问题照常说
    private var shownProblem: String? { validation(checkTitle: titleTouched) }

    private func validation(checkTitle: Bool) -> String? {
        if checkTitle, titleMissing { return "请填写标题" }
        if !allDay && end <= start { return "结束时间要晚于开始时间（跨夜安排请拆成两个日程）" }
        // 拆分后原系列在这一天之前停止，新系列再往前挪就会和原系列重复
        if let splitDay, startDay < splitDay { return "从这次起修改时，开始日期不能早于 \(splitDay.shortLabel)" }
        if recurrence == .custom && weekdays.isEmpty { return "请至少选择一个星期" }
        // 截止日期只对重复日程有意义（改成不重复后它被隐藏，不能再拦住保存）
        if recurrence != .none, hasUntil, let u = LocalDay(key: until), u < startDay { return "重复截止日期不能早于开始日期" }
        return nil
    }

    /// 按当前设置一次都不会出现（例如开始日正好是跳过的那天、截止前没有符合的星期）：保存后只会留在“全部日程”里
    private var neverOccurs: Bool {
        guard validationMessage == nil, recurrence != .none else { return false }
        let rule = draftRule
        var last = startDay.adding(days: 400)   // 覆盖最长的“每 52 周”间隔
        if let u = rule.repeatUntil { last = min(last, u) }
        if let s = rule.stopBefore { last = min(last, s.adding(days: -1)) }
        guard startDay <= last else { return true }
        return !LocalDay.range(startDay, last).contains { rule.matches($0) && !rule.excluded.contains($0.key) }
    }

    struct ConflictReport {
        var overlaps: [String] = []
        var tight: [String] = []
    }

    /// 未来 8 周内与其他日程的时间重叠，以及“日程前后缓冲”不足（只作提醒，不阻止保存）。
    private func conflictReport() -> ConflictReport {
        var report = ConflictReport()
        guard !allDay, validationMessage == nil else { return report }
        let rule = draftRule
        let first = max(startDay, .today())
        let last = first.adding(days: 56)
        let before = settingsList.first?.bufferBeforeMinutes ?? 0
        let after = settingsList.first?.bufferAfterMinutes ?? 0
        let others = Dictionary(grouping: Occurrences.list(events: allEvents.filter { $0 !== event }, from: first, to: last), by: \.day)
        for occurrence in rule.occurrences(from: first, to: last) {
            // 单独改过时间的那一次按改后的时间算
            let patch = rule.overrides[occurrence.sourceDay.key]
            let s = patch?.start_time.flatMap { ClockTime.minutes(from: $0) } ?? start
            let e = patch?.end_time.flatMap { ClockTime.minutes(from: $0, allowEndOfDay: true) } ?? end
            let day = occurrence.scheduledDay
            for other in others[day] ?? [] {
                guard let os = other.startMinute else { continue }
                // 只有开始时间的日程按 1 小时算，与周视图一致
                let oe = other.endMinute ?? min(24 * 60, os + 60)
                // 缓冲套在已有日程周围，与旧版 planning.py 的判定一致：
                // 已有日程结束后要留“结束后缓冲”，开始前要留“开始前缓冲”
                if os < e && s < oe {
                    if report.overlaps.count < 3 { report.overlaps.append("\(day.shortLabel) 与「\(other.title)」\(ClockTime.range(os, oe)) 重叠") }
                } else if oe <= s, s - oe < after {
                    if report.tight.count < 3 {
                        report.tight.append("\(day.shortLabel) 「\(other.title)」（\(ClockTime.text(oe)) 结束）结束后要留 \(after) 分钟缓冲，这里只隔 \(s - oe) 分钟")
                    }
                } else if os >= e, os - e < before {
                    if report.tight.count < 3 {
                        report.tight.append("\(day.shortLabel) 「\(other.title)」（\(ClockTime.text(os)) 开始）开始前要留 \(before) 分钟缓冲，这里只隔 \(os - e) 分钟")
                    }
                }
            }
            if report.overlaps.count >= 3 && report.tight.count >= 3 { break }
        }
        return report
    }

    var body: some View {
        // 冲突提醒每次刷新只算一遍（在标题、备注里打字也会刷新）
        let report = conflictReport()
        EditorSheet(eyebrow: "时辰卷", title: event == nil ? "新建日程"
                    : splitDay.map { "从这次起修改（\($0.shortLabel) 起）" }
                    ?? (event?.recurrenceKind == RecurrenceKind.none ? "编辑日程" : "编辑重复日程（整个系列）"),
                    // 标题还空着、没碰过时“保存”也可点：点了才说“请填写标题”并把光标放回标题框
                    // 高 680 → 752：编辑重复日程时“重复”第二行、冲突提醒不再被按钮栏切在一半；
                    // 752 正好是 1180×780 的窗口去掉 28pt 标题栏，再高就超出窗口
                    size: CGSize(width: 540, height: 752), canSave: shownProblem == nil,
                    problem: failure ?? shownProblem, onSave: attemptSave,
                    // 全部日程的行改成整行可点后，删除也放进编辑窗口（与作息、目标的编辑窗口一致）；“从这次起修改”时不给删除
                    onDelete: event != nil && splitDay == nil ? { confirmDelete = true } : nil) {
            if let splitDay {
                Text("\(splitDay.longLabel) 及以后的每一次按这里的设置，之前的保持原样：保存后原系列在这一天之前停止，另起一个新系列（这天及以后单独改过或跳过的日期一并带过去）。")
                    .font(.ysCaption).foregroundStyle(Theme.inkSoft)
            } else if let event, event.recurrenceKind != .none {
                Text("修改会套用到这个系列过去和未来的每一次。只想改某一次，请在周视图或近期列表里点开那一次，选“仅修改这一次”或“从这次起修改”。")
                    .font(.ysCaption).foregroundStyle(Theme.inkSoft)
            }
            FormSection {
                FormRow(label: "标题") {
                    TextField("", text: $title, prompt: Text("例如：导师组会"))
                        .textFieldStyle(.plain)
                        .focused($titleFocused)
                        .modifier(EventFieldFrame(active: titleFocused))
                }
                // 类别是一个组合框：照常输入，右侧内嵌的 ⌄ 列出用过的类别（不再在旁边把类别名再写一遍）
                FormRow(label: "类别") { EventCategoryCombo(text: $category, options: categories) }
                FormRow(label: "地点") { TextField("", text: $location, prompt: Text("可不填")) }
                FormRow(label: "优先级") {
                    ChipPicker(selection: $priority, options: EventPriority.allCases.map { ($0.rawValue, $0.label) })
                }
            }
            FormSection(title: "时间") {
                FormRow(label: recurrence == .none ? "日期" : "开始日期") { DayField(label: "", key: $dateKey) }
                FormRow(label: "全天") { Toggle("全天日程", isOn: $allDay) }
                if !allDay {
                    FormRow(label: "时段") {
                        HStack(spacing: 8) {
                            MinuteField(label: "", minutes: startBinding)
                            Text("至").foregroundStyle(Theme.inkSoft)
                            MinuteField(label: "", minutes: $end, allowMidnight: true)
                        }
                    }
                }
            }
            FormSection(title: "重复") {
                FormRow(label: "方式") {
                    ChipPicker(selection: $recurrence, options: RecurrenceKind.allCases.map { ($0, $0.label) })
                }
                if recurrence != .none {
                    FormRow(label: "间隔") {
                        Stepper(value: $interval, in: 1...52) {
                            Text(recurrence == .daily ? "每 \(interval) 天" : "每 \(interval) 周")
                        }
                        .fixedSize()
                    }
                    if recurrence == .custom {
                        FormRow(label: "星期") { WeekdayPicker(selection: $weekdays) }
                    }
                    FormRow(label: "截止") {
                        HStack(spacing: 10) {
                            Toggle("设置截止日期", isOn: $hasUntil)
                            if hasUntil { DayField(label: "", key: $until) }
                        }
                    }
                    seriesMarks
                    Text(draftRule.summary).font(.ysCaption).foregroundStyle(Theme.inkSoft).padding(.vertical, 4)
                    if neverOccurs {
                        Hint("按当前设置，这个日程一次也不会出现，保存后只会留在“全部日程”里。", tone: .warning).padding(.bottom, 4)
                    }
                } else if stopBefore != nil || !excludedDates.isEmpty {
                    Hint("改为不重复后，原来“从这次起停止 / 仅删除这一次”留下的记录会一并清除，这个日程会在所选日期出现。")
                        .padding(.vertical, 4)
                }
            }
            NotesSection(text: $notes, lines: 2...5)
            if !report.overlaps.isEmpty {
                FormSection(title: "时间冲突提醒") {
                    ForEach(Array(report.overlaps.enumerated()), id: \.offset) { _, text in
                        Hint(text, tone: .warning).padding(.vertical, 3)
                    }
                }
            }
            if !report.tight.isEmpty {
                FormSection(title: "前后缓冲不足") {
                    ForEach(Array(report.tight.enumerated()), id: \.offset) { _, text in
                        Hint(text, tone: .warning, symbol: "hourglass").padding(.vertical, 3)
                    }
                }
            }
        }
        .onAppear(perform: load)
        // 离开过标题框才算碰过（打开时光标就在标题框里，这一下不算）
        .onChange(of: titleFocused) { was, now in if was, !now { titleTouched = true } }
        .confirmationDialog(event?.recurrenceKind == RecurrenceKind.none ? "删除这个日程？" : "删除整个重复日程？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                if let event { context.delete(event) }
                DataStore.save(context)
                dismiss()
            }
        } message: {
            Text(event?.recurrenceKind != RecurrenceKind.none ? "所有过去和未来的发生都会被删除，且无法恢复。若只是以后不再上，请用“从这次起停止”。" : "删除后无法恢复。")
        }
    }

    /// 用户改开始时间时整体平移、保持原时长（先点“时”再点“分”两步选完时长也不变）。
    /// load() 直接写 start，不经过这里，所以打开编辑器不会改动结束时间。
    private var startBinding: Binding<Int> {
        Binding(get: { start }, set: { new in
            let duration = end - start
            start = new
            end = min(24 * 60, new + (duration > 0 ? duration : 60))
        })
    }

    /// “从这次起停止 / 仅删除这一次”留下的标记：显示出来，并可恢复
    @ViewBuilder
    private var seriesMarks: some View {
        if let stopBefore, let stop = LocalDay(key: stopBefore) {
            FormRow(label: "已停止") {
                HStack(spacing: 10) {
                    if effectiveStopBefore == nil {
                        Hint("原定 \(stop.shortLabel) 起停止；开始日期已挪到这天或之后，保存时会自动解除")
                    } else {
                        let untilBlocked = hasUntil && (LocalDay(key: until).map { $0 >= stop } ?? false)
                        Hint("已于 \(stop.shortLabel) 起停止，此后不再出现" + (untilBlocked ? "；要让截止日期生效，请先恢复" : ""), tone: .warning)
                    }
                    Button("恢复系列") { self.stopBefore = nil }
                        .help("清除停止日，按重复规则（和截止日期）继续出现")
                }
            }
        }
        if !excludedDates.isEmpty {
            FormRow(label: "已跳过", top: true) {
                VStack(alignment: .leading, spacing: 6) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(excludedDates.sorted(), id: \.self) { key in
                            HStack(spacing: 4) {
                                Text(LocalDay(key: key).map { "\($0.shortLabel) \($0.weekdayName)" } ?? key)
                                    .font(.ysCaption).foregroundStyle(Theme.ink).lineLimit(1)
                                Button { excludedDates.removeAll { $0 == key } } label: {
                                    Image(systemName: "arrow.uturn.backward.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.jade)
                                .help("恢复这一次")
                                .accessibilityLabel("恢复 \(key)")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.mist.opacity(0.7), in: Capsule())
                        }
                    }
                    Button("全部恢复（\(excludedDates.count) 次）") { excludedDates = [] }
                        .buttonStyle(.link)
                        .font(.ysCaption)
                }
            }
        }
    }

    /// 点“保存”（或 ⌘↩）：先算碰过标题；还有问题就只把红字亮出来，标题空着时光标回到标题框
    private func attemptSave() {
        titleTouched = true
        guard validationMessage == nil else {
            if titleMissing { titleFocused = true }
            return
        }
        save()
    }

    private func load() {
        guard let event else {
            // 新建：光标先放进标题框（弹窗挂上之后再放）
            DispatchQueue.main.async { titleFocused = true }
            dateKey = defaultDay.key
            if let defaultStart {
                start = defaultStart
                end = min(24 * 60, defaultStart + 60)
            }
            return
        }
        title = event.title
        dateKey = event.dateKey
        allDay = event.isAllDay
        start = event.startMinute ?? 9 * 60
        end = min(24 * 60, event.endMinute ?? (start + 60))
        category = event.category
        location = event.location
        priority = event.priority
        recurrence = event.recurrenceKind
        interval = event.interval
        weekdays = event.weekdays
        hasUntil = event.repeatUntil != nil
        until = event.repeatUntil ?? until
        notes = event.notes
        stopBefore = event.stopBefore
        excludedDates = event.excludedDates
        if let splitDay {
            // 新系列从这一次开始；只带上这一天及以后跳过的日期（之前的留在原系列）
            dateKey = splitDay.key
            excludedDates = event.excludedDates.filter { SeriesSplit.movesToNew($0, from: splitDay) }
        }
    }

    private func save() {
        // 从这次起修改：先把原有的单次改期按这一天切开，解析不了就什么都不改
        var split: (day: LocalDay, original: ScheduleEvent, overrides: (before: String, after: String))?
        if let splitDay, let event {
            guard let parts = SeriesSplit.partitionOverrides(event.overridesJSON, at: splitDay) else {
                failure = "这个日程原有的单次改期数据无法解析，未作修改"
                return
            }
            split = (splitDay, event, parts)
        }
        // 拆分时写进一个新日程（不复制 legacyID，不算旧版导入或传书），原日程只在下面截断
        let target = split == nil ? (event ?? ScheduleEvent(title: title, dateKey: dateKey)) : ScheduleEvent(title: title, dateKey: dateKey)
        if event == nil || split != nil { context.insert(target) }
        // 先按改动前的日期判断，再写入
        let clearOverrides = dropsOverrides
        let keptStop = effectiveStopBefore
        target.title = title.trimmingCharacters(in: .whitespaces)
        target.dateKey = dateKey
        target.startMinute = allDay ? nil : start
        target.endMinute = allDay ? nil : end
        target.category = category.trimmingCharacters(in: .whitespaces)
        target.location = location
        target.priority = priority
        target.recurrenceKind = recurrence
        target.interval = recurrence == .none ? 1 : interval
        target.weekdays = recurrence == .custom ? weekdays : []
        target.repeatUntil = recurrence != .none && hasUntil ? until : nil
        // “停止 / 跳过”：编辑器里恢复过的就清掉；改成不重复、或开始日期挪到停止日之后时自动解除
        target.stopBefore = keptStop
        target.excludedDates = recurrence == .none ? [] : excludedDates
        if let split {
            // 新系列带上这一天及以后的单次改期（旧版不认识的字段原样保留）
            target.timezoneID = split.original.timezoneID
            target.overridesJSON = clearOverrides ? "" : split.overrides.after
            // 原系列：只留这一天之前的跳过与改期，并在这一天之前停止（原有更早的停止日照旧）
            let original = split.original
            original.excludedDates = original.excludedDates.filter { !SeriesSplit.movesToNew($0, from: split.day) }
            original.overridesJSON = split.overrides.before
            let oldStop = original.stopBefore.flatMap(LocalDay.init(key:))
            original.stopBefore = min(oldStop ?? split.day, split.day).key
            original.updatedAt = Date()
        } else if clearOverrides {
            target.overridesJSON = ""
        }
        target.notes = notes
        target.updatedAt = Date()
        DataStore.save(context)
        dismiss()
    }
}

/// 日程弹窗里自己管焦点的输入框外观，与 .yunshan 输入框一样：宣纸底、细边，聚焦或展开时描边转金。
/// （.yunshan 样式里自带一层 .focused，程序要控制焦点、知道光标离没离开时不能叠着用）
private struct EventFieldFrame: ViewModifier {
    var active: Bool
    var trailing: CGFloat = 10

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        content
            .padding(.leading, 10)
            .padding(.trailing, trailing)
            .padding(.vertical, 7)
            .background(Theme.paper.opacity(0.6), in: shape)
            .overlay(shape.strokeBorder(active ? Theme.gold.opacity(0.6) : Theme.line, lineWidth: active ? 1.3 : 1))
    }
}

/// 日程的类别：一个组合框——照常输入；用过别的类别时右侧内嵌一个 ⌄，点开列出用过的类别（当前那个打勾）
private struct EventCategoryCombo: View {
    @Binding var text: String
    var options: [String]
    @State private var open = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text, prompt: Text("例如：组会 / 上课 / 运动"))
                .textFieldStyle(.plain)
                .focused($focused)
            if !options.isEmpty {
                Button { open.toggle() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(open ? Theme.ink : Theme.inkSoft)
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("用过的类别")
                .accessibilityLabel("用过的类别")
                .popover(isPresented: $open, arrowEdge: .bottom) { list }
            }
        }
        .modifier(EventFieldFrame(active: focused || open, trailing: options.isEmpty ? 10 : 4))
    }

    private var list: some View {
        let current = text.trimmingCharacters(in: .whitespaces)
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options, id: \.self) { option in
                    let on = option == current
                    Button {
                        text = option
                        open = false
                    } label: {
                        HStack(spacing: 8) {
                            Text(option).font(.system(size: TypeSize.callout, weight: on ? .semibold : .regular)).lineLimit(1)
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
