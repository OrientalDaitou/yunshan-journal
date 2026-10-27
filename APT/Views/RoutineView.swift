import SwiftUI
import SwiftData

/// 同一名称、类别、时间的作息块按“哪几天”合并显示和编辑。
struct RoutineGroup: Identifiable {
    var blocks: [RoutineBlock]
    var first: RoutineBlock { blocks[0] }
    var weekdays: [Int] { blocks.map(\.weekday).sorted() }
    var id: String { "\(first.title)|\(first.kind)|\(first.startMinute)|\(first.endMinute)" }

    static func make(_ blocks: [RoutineBlock]) -> [RoutineGroup] {
        let grouped = Dictionary(grouping: blocks) { "\($0.title)|\($0.kind)|\($0.startMinute)|\($0.endMinute)" }
        return grouped.values.map { RoutineGroup(blocks: $0) }
            .sorted { ($0.first.startMinute, $0.first.title) < ($1.first.startMinute, $1.first.title) }
    }
}

struct RoutineView: View {
    struct EditorRequest: Identifiable {
        var id = UUID()
        var group: RoutineGroup?
    }

    @Environment(\.modelContext) private var context
    @Query private var blocks: [RoutineBlock]
    @Query private var settingsList: [AppSettings]
    @State private var editor: EditorRequest?
    @State private var confirmTemplate = false
    /// 右键菜单里“删除”的那条作息（先确认）
    @State private var pendingDelete: RoutineGroup?
    /// 没有作息时缓冲行这次已经摆出来过（调回 0 也不立刻收起）
    @State private var bufferRowShown = false

    var body: some View {
        // 横幅只留“新增作息”；“套用学生作息”只在空状态里出现，有作息后收进“作息条目”标题右侧的“⋯”菜单
        PageScaffold(page: .routine) {
            if blocks.isEmpty {
                // 还没有作息：只给一张引导卡。缓冲还是 0 时不摆（空卡里“开始前 0 分钟”只会让人困惑）；
                // 但缓冲与作息无关，设过（不是 0）时日程弹窗照样按它提醒、AI 摘要照样写，得照常可改，放在引导卡底部
                VStack(alignment: .leading, spacing: 0) {
                    OrnamentEmpty(.routine) {
                        Button { editor = EditorRequest(group: nil) } label: { Label("新增作息", systemImage: "plus") }
                            .buttonStyle(.yunshanPrimary)
                            .keyCommand(.newRoutine)
                        Button { confirmTemplate = true } label: { Label("套用学生作息", systemImage: "wand.and.stars") }
                    }
                    // 已经摆出来的这一行，在页面上把两边都调回 0 也先不收起（不在鼠标底下突然消失），下次进页面再按规矩
                    if let settings = settingsList.first,
                       bufferRowShown || RoutineChartRules.showsBuffer(hasRoutine: false, before: settings.bufferBeforeMinutes, after: settings.bufferAfterMinutes) {
                        bufferRow.onAppear { bufferRowShown = true }
                    }
                }
                .xianCard()
                .ysEntrance(order: 0)
            } else {
                // 一栏到底：作息图（主卡）在上，条目在下，日程前后缓冲是条目卡底的一行（不再单独占一张矮卡，两栏高低不齐）
                weekChart.xianCard(tier: .jade).ysEntrance(order: 0)
                groupList.ysEntrance(order: 1)
            }
        } actions: {
            // 空状态卡里已有同一个按钮，一屏只放一处
            if !blocks.isEmpty {
                Button { editor = EditorRequest(group: nil) } label: { Label("新增作息", systemImage: "plus") }
                    .buttonStyle(.yunshanPrimary)
                    .keyCommand(.newRoutine)
                    .help(KeyCommand.newRoutine.help("新增作息"))
            }
        }
        .sheet(item: $editor) { RoutineEditor(group: $0.group) }
        .confirmationDialog("套用“学生作息”模板？", isPresented: $confirmTemplate) {
            Button("添加模板作息") { applyTemplate() }
        } message: {
            Text("会新增睡眠、三餐、上午 / 下午学习和运动等作息块，不会删除已有作息。添加后可逐条修改。")
        }
        .confirmationDialog("删除这条作息？", isPresented: Binding(isPresent: $pendingDelete), presenting: pendingDelete) { group in
            Button("删除", role: .destructive) {
                group.blocks.forEach { context.delete($0) }
                DataStore.save(context)
                pendingDelete = nil
            }
        } message: { group in
            Text("「\(group.first.title)」（\(WeekdayText.summary(group.weekdays))）会从每周作息里删除。")
        }
    }

    // MARK: 一周总览

    /// 每小时的高度（作息图只画 05/06 点到 24 点，拉开刻度）
    private let hourHeight = RoutineChartRules.hourHeight

    /// 作息图从几点画起：默认 06:00；睡眠以外的作息更早开始时从那一小时画起（跨夜的睡眠只在顶上留一小段）
    private var chartStartHour: Int {
        let earliest = (0..<7).flatMap { segments(for: $0) }
            .filter { RoutineKind.of($0.block.kind) != .sleep }
            .map(\.start).min()
        return max(0, min(6, (earliest ?? 6 * 60) / 60))
    }

    private var weekChart: some View {
        let start = chartStartHour
        let chartHeight = hourHeight * CGFloat(24 - start)
        return VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "一周作息", hint: "点击色块可编辑")
            HStack(alignment: .top, spacing: 6) {
                // 刻度列定宽：不定宽的 Color.clear 会被撑开，刻度就漂到了图中间
                VStack(spacing: 0) {
                    Color.clear.frame(width: 22, height: 18)
                    ForEach(start..<24, id: \.self) { hour in
                        Text(hour % 2 == 0 ? String(format: "%02d", hour) : "")
                            .font(.ysMicro.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                            .frame(width: 22, height: hourHeight, alignment: .topTrailing)
                            .offset(y: -6)
                    }
                }
                ForEach(0..<7, id: \.self) { weekday in
                    VStack(spacing: 0) {
                        Text(LocalDay.weekdayNames[weekday]).font(.ysCaption).foregroundStyle(Theme.inkSoft).frame(height: 18)
                        ZStack(alignment: .top) {
                            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).fill(Theme.mist.opacity(0.5))
                            // 每两小时一条极淡的刻度线，和左侧刻度对齐
                            ForEach(Array(stride(from: start + (start % 2 == 0 ? 2 : 1), to: 24, by: 2)), id: \.self) { hour in
                                Rectangle().fill(Theme.line.opacity(0.55)).frame(height: 0.5)
                                    .offset(y: CGFloat(hour - start) * hourHeight)
                                    .frame(maxHeight: .infinity, alignment: .top)
                            }
                            ForEach(segments(for: weekday).filter { $0.end > start * 60 }, id: \.key) { segment in
                                let top = max(segment.start, start * 60)
                                RoutineChartBlock(block: segment.block, visibleMinutes: segment.end - top, hourHeight: hourHeight) {
                                    editor = EditorRequest(group: group(containing: segment.block))
                                }
                                .offset(y: CGFloat(top - start * 60) / 60 * hourHeight)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .padding(.horizontal, 2)
                            }
                        }
                        .frame(height: chartHeight)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            legend
        }
    }

    /// 图例只列本周实际用到的类别，并带上每周时长（原“每周时长”卡并到这里）
    private var legend: some View {
        var totals: [RoutineKind: Int] = [:]
        for block in blocks { totals[RoutineKind.of(block.kind), default: 0] += block.durationMinutes }
        let sorted = totals.sorted { ($0.value, $1.key.label) > ($1.value, $0.key.label) }
        return FlowLayout(spacing: 14) {
            ForEach(sorted, id: \.key) { kind, minutes in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.color(for: kind)).frame(width: 10, height: 10)
                    Text(kind.label).foregroundStyle(Theme.inkSoft)
                    Text(RoutineChartRules.hoursText(minutes)).monospacedDigit().foregroundStyle(Theme.ink)
                }
                .font(.ysCaption)
                .accessibilityElement(children: .combine)
            }
            if let sleep = totals[.sleep] {
                // 按实际设了睡眠的天数平均（跨夜睡眠记在入睡那天），没设的日子不拉低平均值
                let nights = Set(blocks.filter { RoutineKind.of($0.kind) == .sleep }.map(\.weekday)).count
                let average = RoutineChartRules.hoursText(sleep / max(1, nights))
                Text(nights >= 7 ? "· 平均每晚睡眠 \(average)" : "· 已设睡眠的 \(nights) 天，平均每晚 \(average)")
                    .font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
            }
        }
    }

    private struct Segment { var key: String; var block: RoutineBlock; var start: Int; var end: Int }

    private func segments(for weekday: Int) -> [Segment] {
        RoutineBlock.segments(blocks, weekday: weekday).map {
            Segment(key: "\($0.block.persistentModelID.hashValue)" + ($0.carried ? "b" : "a"), block: $0.block, start: $0.start, end: $0.end)
        }
    }

    private func group(containing block: RoutineBlock) -> RoutineGroup? {
        RoutineGroup.make(blocks).first { $0.blocks.contains { $0 === block } }
    }

    // MARK: 列表

    private var groupList: some View {
        let groups = RoutineGroup.make(blocks)
        return VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "作息条目", detail: "\(groups.count) 条") {
                Menu {
                    Button("套用学生作息…") { confirmTemplate = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多")
                .accessibilityLabel("更多")
            }
            // 整行可点编辑；右键有“编辑 / 删除”。类别由左侧图标和颜色表达，不再另挂小签
            VStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    let kind = RoutineKind.of(group.first.kind)
                    EditableRow(dividerAbove: index > 0, onDelete: { pendingDelete = group }, action: { editor = EditorRequest(group: group) }) {
                        HStack(spacing: 10) {
                            Image(systemName: kind.symbol).foregroundStyle(Theme.color(for: kind)).frame(width: 22)
                                .accessibilityLabel(kind.label)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.first.title).foregroundStyle(Theme.ink)
                                Text("\(WeekdayText.summary(group.weekdays))　\(ClockTime.range(group.first.startMinute, group.first.endMinute))\(group.first.crossesMidnight ? "（跨夜）" : "")")
                                    .font(.ysCaption.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                            }
                        }
                    }
                }
            }
            bufferRow
        }
        .xianCard()
    }

    /// 日程前后缓冲：卡底一行，两个步进器并排；说明放在悬停提示里
    @ViewBuilder
    private var bufferRow: some View {
        if let settings = settingsList.first {
            VStack(alignment: .leading, spacing: 12) {
                Rectangle().fill(Theme.line.opacity(0.8)).frame(height: 1)
                HStack(spacing: 22) {
                    HStack(spacing: 6) {
                        Text("日程前后缓冲").font(Theme.songti(TypeSize.callout, .semibold)).tracking(1).foregroundStyle(Theme.ink)
                        Image(systemName: "info.circle").font(.ysCaption).foregroundStyle(Theme.inkSoft)
                            .accessibilityHidden(true)
                    }
                    .fixedSize()
                    .help("编辑日程时按它提醒前后留白；也会写进 AI 摘要，供安排建议参考。")
                    Stepper(value: Binding(get: { settings.bufferBeforeMinutes }, set: { settings.bufferBeforeMinutes = $0; DataStore.save(context) }), in: 0...120, step: 5) {
                        Text("开始前 \(settings.bufferBeforeMinutes) 分钟").monospacedDigit()
                    }
                    Stepper(value: Binding(get: { settings.bufferAfterMinutes }, set: { settings.bufferAfterMinutes = $0; DataStore.save(context) }), in: 0...120, step: 5) {
                        Text("结束后 \(settings.bufferAfterMinutes) 分钟").monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.top, 8)
            .accessibilityElement(children: .contain)
            .accessibilityHint("编辑日程时按它提醒前后留白；也会写进 AI 摘要，供安排建议参考。")
        }
    }

    private func applyTemplate() {
        let existing = context.all(RoutineBlock.self)
        for item in RoutineTemplate.student {
            for day in item.weekdays {
                // 已有完全相同的块就不重复添加
                if existing.contains(where: { $0.weekday == day && $0.title == item.title && $0.startMinute == item.start && $0.endMinute == item.end }) { continue }
                context.insert(RoutineBlock(title: item.title, kind: item.kind.rawValue, weekday: day, startMinute: item.start, endMinute: item.end))
            }
        }
        DataStore.save(context)
    }
}

/// 一周作息图的几条小规矩（自检 SelfTest+Dialogs 逐条核对）：每小时多高、多短的段画成细线、段里写多大的字、图例的时长写法。
enum RoutineChartRules {
    /// 每小时 26pt：30 分钟的早餐、通勤也有 13pt，写得下名字
    static let hourHeight: CGFloat = 26
    /// 不到 20 分钟的段画成一道细线加类别小图标
    static let lineBelowMinutes = 20

    /// 段里名字的字号：够高（≥14pt）用角标字号；20 分钟以上但矮的用 9pt；更短的是细线，不写字（nil）
    static func labelSize(minutes: Int, height: CGFloat) -> CGFloat? {
        guard minutes >= lineBelowMinutes else { return nil }
        return height >= 14 ? TypeSize.micro : 9
    }

    /// 色块底色的浓淡：类别色 18%（深色 28%，深底上同样的淡色看不出来），悬停再浓一档
    static func fillOpacity(dark: Bool, hover: Bool) -> Double { (dark ? 0.28 : 0.18) + (hover ? 0.1 : 0) }

    /// 日程前后缓冲那一行出不出现：有作息时总在条目卡底；还没有作息时只在设过缓冲（任一边不是 0）时放在引导卡底部。
    /// 缓冲与作息无关（日程弹窗按它提醒“前后缓冲不足”、AI 摘要也写它），不是 0 就必须有地方改
    static func showsBuffer(hasRoutine: Bool, before: Int, after: Int) -> Bool {
        hasRoutine || before != 0 || after != 0
    }

    /// 图例与平均睡眠的时长：“56 小时”“17.5 小时”
    static func hoursText(_ minutes: Int) -> String {
        let hours = Double(minutes) / 60
        return (hours.rounded() == hours ? "\(Int(hours))" : String(format: "%.1f", hours)) + " 小时"
    }
}

/// 作息图里的一块：写名字（够高用角标字号，矮的用 9pt）；不到 20 分钟的画成一道细线加小图标。悬停显示名称与时间，点一下编辑。
private struct RoutineChartBlock: View {
    var block: RoutineBlock
    /// 图上画得到的分钟数（跨夜段被起点裁掉后的长度）
    var visibleMinutes: Int
    var hourHeight: CGFloat
    var action: () -> Void
    @Environment(\.spiritMotion) private var motion
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    private var kind: RoutineKind { RoutineKind.of(block.kind) }
    private var color: Color { Theme.color(for: kind) }
    private var height: CGFloat { CGFloat(visibleMinutes) / 60 * hourHeight }

    var body: some View {
        shape
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { inside in if !(inside && ScrollActivity.shared.isScrolling) { hover = inside } }
            .animation(motion ? Motion.hover : nil, value: hover)
            .help("\(block.title) \(ClockTime.range(block.startMinute, block.endMinute))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(block.title) \(ClockTime.range(block.startMinute, block.endMinute))")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    @ViewBuilder
    private var shape: some View {
        if block.durationMinutes < RoutineChartRules.lineBelowMinutes { thinLine } else { box }
    }

    /// 不到 20 分钟：一道细线 + 类别小图标
    private var thinLine: some View {
        Capsule().fill(color.opacity(hover ? 1 : 0.75))
            .frame(height: 2.5)
            .overlay(alignment: .leading) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(color)
                    .padding(2)
                    .background(Theme.card, in: Circle())
                    .offset(x: 2)
            }
            .frame(height: max(4, height - 1))
    }

    /// 类别色淡底 + 1pt 类别色描边（各类别一眼对得上图例），里面写名字
    private var box: some View {
        let rect = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return rect.fill(color.opacity(RoutineChartRules.fillOpacity(dark: scheme == .dark, hover: hover)))
            .overlay(rect.strokeBorder(color.opacity(hover ? 1 : 0.85), lineWidth: 1))
            .overlay { boxLabel }
            .frame(height: max(3, height - 1))
    }

    @ViewBuilder
    private var boxLabel: some View {
        if let size = RoutineChartRules.labelSize(minutes: visibleMinutes, height: height) {
            // 矮的段（20–30 分钟）字比块略高一点也照写：只一行、不裁，读得出是“早餐”“通勤”
            Text(block.title).font(.system(size: size, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 3)
                .fixedSize(horizontal: false, vertical: true)
        } else if height >= 9 {
            Image(systemName: kind.symbol).font(.system(size: 7.5, weight: .semibold)).foregroundStyle(color)
        }
    }
}

/// 新增作息“哪几天”下面的三个常用选法
struct RoutineDayPreset {
    var label: String
    var days: [Int]
    static let all = [RoutineDayPreset(label: "工作日", days: [0, 1, 2, 3, 4]),
                      RoutineDayPreset(label: "周末", days: [5, 6]),
                      RoutineDayPreset(label: "每天", days: Array(0...6))]
}

struct RoutineEditor: View {
    var group: RoutineGroup?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind = RoutineKind.study
    @State private var weekdays: [Int] = [0, 1, 2, 3, 4]
    @State private var start = 9 * 60
    @State private var end = 12 * 60
    @State private var note = ""
    @State private var confirmDelete = false
    @State private var confirmLongOvernight = false

    private var crossesMidnight: Bool { end <= start }
    private var durationMinutes: Int { crossesMidnight ? 24 * 60 - start + end : end - start }
    /// 非睡眠的作息跨夜超过 12 小时，多半是只改了开始时间、忘了改结束（例如 09:00–12:00 把开始改成 14:00）
    private var suspiciousOvernight: Bool { crossesMidnight && start != end && kind != .sleep && durationMinutes > 12 * 60 }
    private var durationText: String {
        durationMinutes % 60 == 0 ? "\(durationMinutes / 60) 小时" : String(format: "%.1f 小时", Double(durationMinutes) / 60)
    }

    var body: some View {
        EditorSheet(eyebrow: "起居有常", title: group == nil ? "新建作息" : "编辑作息", size: CGSize(width: 520, height: 500),
                    canSave: !title.trimmingCharacters(in: .whitespaces).isEmpty && !weekdays.isEmpty && start != end,
                    onSave: { if suspiciousOvernight { confirmLongOvernight = true } else { save() } },
                    onDelete: group == nil ? nil : { confirmDelete = true }) {
            FormSection {
                FormRow(label: "名称") { TextField("", text: $title, prompt: Text("例如：睡眠 / 午餐 / 上午专注")) }
                FormRow(label: "类别") {
                    ChipPicker(selection: $kind, options: RoutineKind.allCases.map { ($0, $0.label) }, symbol: { $0.symbol })
                }
                FormRow(label: "哪几天", top: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        WeekdayPicker(selection: $weekdays)
                        // 三个常用选法做成筛选签（不再是系统蓝的链接）；正好选中这几天时那枚亮起
                        HStack(spacing: 6) {
                            ForEach(RoutineDayPreset.all, id: \.label) { preset in
                                FilterChip(text: preset.label, on: Set(weekdays) == Set(preset.days)) { weekdays = preset.days }
                            }
                        }
                    }
                }
                FormRow(label: "时段") {
                    HStack(spacing: 8) {
                        MinuteField(label: "", minutes: $start)
                        Text("至").foregroundStyle(Theme.inkSoft)
                        MinuteField(label: "", minutes: $end)
                    }
                }
                if suspiciousOvernight {
                    Hint("结束早于开始，会算作跨夜、长达 \(durationText)。如果只是想改开始时间，请同时把结束时间往后调。", tone: .warning)
                        .padding(.vertical, 3)
                } else if crossesMidnight {
                    Hint("结束早于开始，视为跨夜（例如 23:30 睡到次日 07:30）").padding(.vertical, 3)
                }
            }
            NotesSection(text: $note, lines: 1...3)
        }
        .onAppear {
            guard let group else { return }
            title = group.first.title
            kind = RoutineKind.of(group.first.kind)
            weekdays = group.weekdays
            start = group.first.startMinute
            end = group.first.endMinute
            note = group.first.note
        }
        .confirmationDialog("确认这是跨夜 \(durationText) 的作息？", isPresented: $confirmLongOvernight) {
            Button("仍然保存") { save() }
        } message: {
            Text("\(ClockTime.range(start, end)) 会从当天 \(ClockTime.text(start)) 一直算到次日 \(ClockTime.text(end))，计入每周时长和一周作息图。")
        }
        .confirmationDialog("删除这条作息（\(WeekdayText.summary(weekdays))）？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                group?.blocks.forEach { context.delete($0) }
                DataStore.save(context)
                dismiss()
            }
        }
    }

    private func save() {
        let existing = group?.blocks ?? []
        var byDay: [Int: RoutineBlock] = [:]
        for block in existing {
            // 同一天有重复的块（例如模板套用了两次）：只留一块，其余删除，避免改完后旧时间还残留
            if byDay[block.weekday] == nil { byDay[block.weekday] = block } else { context.delete(block) }
        }
        // 不再选中的日子删除；保留的日子原地更新（保留 legacyID）；新选中的日子新建。
        for block in existing where !weekdays.contains(block.weekday) { context.delete(block) }
        for day in weekdays {
            let block = byDay[day] ?? {
                let created = RoutineBlock(title: title, kind: kind.rawValue, weekday: day, startMinute: start, endMinute: end)
                context.insert(created)
                return created
            }()
            block.title = title.trimmingCharacters(in: .whitespaces)
            block.kind = kind.rawValue
            block.startMinute = start
            block.endMinute = end
            block.note = note
        }
        DataStore.save(context)
        dismiss()
    }
}
