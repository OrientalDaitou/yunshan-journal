import SwiftUI
import SwiftData
import Charts

struct HabitsView: View {
    struct EditorRequest: Identifiable {
        var id = UUID()
        var habit: Habit?
    }

    @Query(sort: \Habit.sortOrder) private var habits: [Habit]
    @Query private var settingsList: [AppSettings]
    /// 各习惯的统计读应用级的修为模型（数据变了才按习惯重算）：这个 @Query 每次保存都会重取习惯、让打卡关系变冷，
    /// 再从 habit.logs 现算要把全部打卡逐条补回来（5 年数据约 1.3 秒）
    @Environment(CultivationModel.self) private var cultivation
    @Environment(\.spiritMotion) private var motion
    @State private var selectedID: PersistentIdentifier?
    @State private var editor: EditorRequest?
    @State private var showArchived = false
    /// 键盘打卡（空格）：交给选中那一项左侧的打卡圈去打，与点一下打卡圈相同——数量型直接按目标记满；
    /// 这天已记了未达标的数量时不改写成目标值，而是弹出数量输入
    @State private var checkInRequest: HabitCheckIn.Request?

    private var config: CultivationConfig { settingsList.first?.cultivation ?? CultivationConfig() }
    private var active: [Habit] { habits.filter { !$0.archived } }
    private var archived: [Habit] { habits.filter(\.archived) }
    private var selected: Habit? { habits.first { $0.persistentModelID == selectedID } ?? active.first }

    var body: some View {
        // 整页一起滚动：横幅随页滚走（和其他页一致），左侧列表和右侧详情不再各自滚动。
        // 横幅只留短句；修为规则在侧栏境界卡里（点一下弹出），打卡时也有“+N 修为”飘字
        PageScaffold(page: .habits) {
            if habits.isEmpty {
                OrnamentEmpty(.habits) {
                    Button { editor = EditorRequest(habit: nil) } label: { Label("立下第一项功课", systemImage: "plus") }
                        .buttonStyle(.yunshanPrimary)
                        .keyCommand(.newHabit)
                }
                .xianCard()
                .ysEntrance(order: 0)
            } else {
                // 每个习惯的统计只算一次：左侧列表、打卡圈和右侧详情共用，不再各自把打卡读一遍、扫一遍
                let today = LocalDay.today()
                let selected = self.selected
                let stats = statsByHabit(today: today, selected: selected)
                ScrollViewReader { proxy in
                    HStack(alignment: .top, spacing: PageLayout.gutter) {
                        habitList(stats, selected: selected, today: today).frame(width: PageLayout.side).ysEntrance(order: 0)
                        Group {
                            if let habit = selected {
                                HabitDetail(habit: habit, stats: self.stats(habit, stats, today: today),
                                            allHabits: habits, config: config, onEdit: { editor = EditorRequest(habit: habit) })
                                    .id(habit.persistentModelID)   // 切换习惯时重建，数量框不会沿用上一个习惯的值
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .ysEntrance(order: 1)
                    }
                    // ↑↓ 换一项功课，空格给它打卡（光标在数量框里时不接，见 PageKeys）
                    .pageKeys([
                        .habitPrev: { moveSelection(-1, from: selected, proxy: proxy) },
                        .habitNext: { moveSelection(1, from: selected, proxy: proxy) },
                        .habitCheckIn: { checkIn(selected) },
                    ])
                }
            }
        } actions: {
            // 还没有功课时，空状态卡里的“立下第一项功课”就是这个入口，横幅不再重复
            if !habits.isEmpty {
                Button { editor = EditorRequest(habit: nil) } label: { Label("新立功课", systemImage: "plus") }
                    .buttonStyle(.yunshanPrimary)
                    .keyCommand(.newHabit)
                    .help(KeyCommand.newHabit.help("新立功课"))
            }
        }
        .sheet(item: $editor) { HabitEditor(habit: $0.habit, nextSortOrder: (habits.map(\.sortOrder).max() ?? 0) + 1) }
    }

    /// 列表里看得到的各项（未归档的，加上展开着的已归档），键盘上下切换按这个次序
    private var listed: [Habit] { active + (showArchived ? archived : []) }

    /// ↑↓：选中上一项 / 下一项功课（到头了停在原处），列表里那一行滚进视野
    private func moveSelection(_ step: Int, from current: Habit?, proxy: ScrollViewProxy) -> Bool {
        let items = listed
        guard !items.isEmpty else { return false }
        let index = current.flatMap { habit in items.firstIndex { $0.persistentModelID == habit.persistentModelID } }
        let target = items[min(max(0, (index ?? -step) + step), items.count - 1)].persistentModelID
        selectedID = target
        withAnimation(motion ? Motion.standard : nil) { proxy.scrollTo(target, anchor: nil) }
        return true
    }

    /// 空格：给选中的那一项打卡（已归档的不能打卡）
    private func checkIn(_ habit: Habit?) -> Bool {
        guard let habit, !habit.archived else { return false }
        checkInRequest = HabitCheckIn.Request(habit: habit.persistentModelID)
        return true
    }

    /// 未归档的习惯和选中的那个各取一份统计（修为模型里缓存好的，与 habit.stats(today:) 相同）。
    /// 已归档的只在列表里展开时才取；模型里还没有的（刚新建、模型还没看到）才照原来的写法现算
    private func statsByHabit(today: LocalDay, selected: Habit?) -> [PersistentIdentifier: HabitStats] {
        var map: [PersistentIdentifier: HabitStats] = [:]
        for habit in habits where !habit.archived || habit === selected {
            map[habit.persistentModelID] = cultivation.stats(for: habit, today: today) ?? habit.stats(today: today)
        }
        return map
    }

    /// 列表里展开已归档的一项时用：同样先取模型里的
    private func stats(_ habit: Habit, _ stats: [PersistentIdentifier: HabitStats], today: LocalDay) -> HabitStats {
        stats[habit.persistentModelID] ?? cultivation.stats(for: habit, today: today) ?? habit.stats(today: today)
    }

    private func habitList(_ stats: [PersistentIdentifier: HabitStats], selected: Habit?, today: LocalDay) -> some View {
        let selectedID = selected?.persistentModelID
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(active) { habit in
                row(habit, stats: self.stats(habit, stats, today: today), isSelected: habit.persistentModelID == selectedID)
            }
            if !archived.isEmpty {
                DisclosureGroup(isExpanded: $showArchived) {
                    ForEach(archived) { habit in
                        row(habit, stats: self.stats(habit, stats, today: today), isSelected: habit.persistentModelID == selectedID)
                    }
                } label: {
                    Text("已归档（\(archived.count)）").font(.ysCaption).foregroundStyle(Theme.inkSoft)
                }
                .padding(.top, 8)
                .padding(.horizontal, 8)
            }
        }
        .xianCard(padding: 10)
    }

    private func row(_ habit: Habit, stats: HabitStats, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            // 已记了未达标的数量时点圈弹出数量输入（不把真实数量改写成目标值）；键盘空格打卡也交给它
            HabitCheckIn(habit: habit, stats: stats, size: 24, allHabits: habits, config: config,
                         request: checkInRequest?.habit == habit.persistentModelID ? checkInRequest : nil)
                .disabled(habit.archived)
            Image(systemName: habit.symbol).foregroundStyle(Theme.jade).frame(width: 18)
            // 两行各带自己的行尾：名称一行的末尾是连续的火苗，频率一行的末尾是数量型今天的“3/8”，
            // 窄列表里“每周一、二、三、四、五”这类长的频率不会被两样东西一起挤成省略号
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(habit.title).foregroundStyle(habit.archived ? Theme.inkSoft : Theme.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    let streak = stats.streak
                    if streak.count > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "flame").font(.ysCaption)
                            Text("\(streak.count)").font(.ysCaption.monospacedDigit())
                        }
                        .foregroundStyle(Theme.gold)
                        .help("连续 \(streak.count) \(streak.unit)")
                    }
                }
                HStack(spacing: 4) {
                    Text(stats.spec.scheduleSummary + (stats.spec.frequency == .weekly ? "　本周 \(stats.achievedThisWeek)/\(habit.targetPerWeek)" : ""))
                        .font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft).lineLimit(1)
                    Spacer(minLength: 4)
                    // 数量型：今天记到多少（“3/8”）。三种一眼分得开：达标是玉色加粗、前面一个小勾；
                    // 记了一部分是金色；还没记的比旁边的频率说明再淡一档（深色下玉色与淡墨很接近，只靠颜色分不开）
                    if !habit.archived, let target = HabitQuantity.target(habit, log: stats.logs[stats.today]) {
                        let done = stats.logs[stats.today]?.quantity ?? 0
                        let achieved = stats.isAchieved(stats.today)
                        let unit = habit.unit.isEmpty ? "" : " \(habit.unit)"
                        let label = "今日 \(amountText(done)) / \(amountText(target))\(unit)" + (achieved ? "，已达标" : "")
                        HStack(spacing: 2) {
                            if achieved {
                                Image(systemName: "checkmark").font(.system(size: TypeSize.caption - 2, weight: .bold))
                            }
                            Text("\(amountText(done))/\(amountText(target))")
                                .font(.ysCaption.monospacedDigit().weight(achieved ? .semibold : .regular))
                        }
                        .foregroundStyle(achieved ? Theme.jade : done > 0 ? Theme.gold : Theme.inkSoft.opacity(0.75))
                        .fixedSize()
                        .help(label)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(label)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        // 能点的块：悬停淡玉底 + 金色细描边，选中时金边常亮
        .yunshanTile(selected: isSelected)
        .onTapGesture {
            selectedID = habit.persistentModelID
            PageKeys.endTyping()
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .id(habit.persistentModelID)
    }
}

/// 数量的显示：整数不带小数点，其余保留一位小数
/// 数量的写法与首页、菜单栏同一套（DashboardRules.number）：整数不带小数点，小数最多两位（2.5 杯、1.25 升）
private func amountText(_ value: Double) -> String { DashboardRules.number(value) }

struct HabitDetail: View {
    var habit: Habit
    /// 这个习惯的统计（功课页已算好，与左侧列表共用一份）。stats.today 是页面算统计时的“今天”，显示都按它
    var stats: HabitStats
    var allHabits: [Habit]
    var config: CultivationConfig
    var onEdit: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    @State private var quantityText = ""
    /// 取消归档会让修为下降时，先确认
    @State private var unarchiveXP: HabitXPChange?

    /// 点按钮记录时再取“今天”（页面停在昨天也不会把记录记到昨天）
    private var today: LocalDay { .today() }

    var body: some View {
        VStack(alignment: .leading, spacing: PageLayout.gutter) {
            header
            // 热力图、最近记录拆成只接收值的子视图：在今日数量框里打字、弹出确认框时，统计没变就不重画它们
            HabitHeatmap(habit: habit, stats: stats, allHabits: allHabits, config: config).equatable().xianCard()
            trendChart.xianCard()
            if showsRecentLogs { HabitRecentLogs(habit: habit, stats: stats, allHabits: allHabits, config: config).equatable().xianCard() }
        }
        .confirmationDialog("取消归档会扣除修为", isPresented: Binding(isPresent: $unarchiveXP),
                            presenting: unarchiveXP) { _ in
            Button("仍然取消归档") { setArchived(false) }
        } message: { change in
            Text("取消归档后，这项功课会重新计入每天的“功课圆满”：归档期间没打卡的日子会算作没做完，修为将从 \(change.before) 变为 \(change.after)（\(change.deltaText)）。")
        }
    }

    /// “最近记录”只在它能多给点信息时显示：数量型功课，或打卡带了数量、时长、备注。
    /// 普通打卡型只会是一列对勾，热力图已经说明了，不再重复。
    /// 有没有这样的打卡交给数据库数（取到一条就停，不读 habit.logs）
    private var showsRecentLogs: Bool {
        (habit.targetValue ?? 0) > 0 || HabitLogQuery.hasDetails(habit)
    }

    /// 归档时记下归档日（此前的日子照常计入功课圆满）；取消归档时清掉
    private func setArchived(_ archived: Bool) {
        habit.archived = archived
        habit.archivedAt = archived ? LocalDay.today().key : nil
        habit.updatedAt = Date()
        DataStore.save(context)
        // 修为模型当场看一眼（归档改了统计的设定），列表、侧栏接着刷新时读到的就是新的
        CultivationModel.existing(for: context)?.refresh()
    }

    private func requestUnarchive() {
        var spec = habit.spec
        spec.archivedDay = nil
        if let change = HabitXPChange.preview(habit, spec: spec, archived: false, context: context), change.after < change.before {
            unarchiveXP = change
        } else {
            setArchived(false)
        }
    }

    // MARK: 头部（玉简主卡）：名称、今日打卡、四个统计

    private var header: some View {
        // 当前连续是计算属性（要往回数日子）：取一次，下面几处共用
        let streak = stats.streak
        return VStack(alignment: .leading, spacing: 18) {
            // 宽时打卡控件和名称同一行；窄窗口（数量型的输入框较宽）放到名称下面
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    titleBlock
                    Spacer(minLength: 12)
                    if !habit.archived { todayControl }
                    moreMenu
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        titleBlock
                        Spacer(minLength: 8)
                        moreMenu
                    }
                    if !habit.archived {
                        todayControl.padding(.leading, 66)
                    }
                }
            }
            if !habit.notes.isEmpty {
                Text(habit.notes).font(.ysCaption).foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 66)
                    .padding(.top, -8)
            }
            // 五个统计并进头部：数字一律墨色，只有“连续”用金色点睛；最长连续与岁月长卷同一口径（从开始日到今天）
            let longest = HabitRecord.longest(stats)
            let note = HabitRecord.note(current: streak.count, longest: longest.count, unit: streak.unit)
            let onRecord = note != nil && streak.count >= longest.count
            // 五格的字放得下就一排五格；窄窗口里“最长连续”并进下面那行小字，格子仍是四个（标签不被截成“当前…”）
            ViewThatFits(in: .horizontal) {
                VStack(alignment: .leading, spacing: 8) {
                    MetricRow {
                        streakTile(streak)
                        MetricTile(label: "最长连续", value: "\(longest.count)", unit: longest.unit)
                        rateTiles
                    }
                    if let note { recordNote(note, onRecord: onRecord) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    MetricRow {
                        streakTile(streak)
                        rateTiles
                    }
                    let parts = (longest.count > 0 ? ["最长连续 \(longest.count) \(longest.unit)"] : []) + [note].compactMap { $0 }
                    if !parts.isEmpty { recordNote(parts.joined(separator: " · "), onRecord: onRecord) }
                }
            }
        }
        .xianCard(tier: .jade)
    }

    private func streakTile(_ streak: (count: Int, unit: String)) -> some View {
        MetricTile(label: "当前连续", value: "\(streak.count)", unit: streak.unit, tint: streak.count > 0 ? Theme.precious : nil)
    }

    @ViewBuilder
    private var rateTiles: some View {
        MetricTile(label: "近 7 天", value: stats.completionRate(days: 7)?.percentText ?? "–")
        MetricTile(label: "近 30 天", value: stats.completionRate(days: 30)?.percentText ?? "–")
        MetricTile(label: "累计打卡", value: "\(stats.totalAchieved)", unit: "次")
    }

    /// 数字格下一行小字：“正在创纪录”金色带小勋章；“距纪录还差 2 天”淡墨带小旗
    private func recordNote(_ text: String, onRecord: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: onRecord ? "rosette" : "flag").font(.system(size: TypeSize.caption - 1))
            Text(text).font(.ysCaption.monospacedDigit())
        }
        .foregroundStyle(onRecord ? Theme.precious : Theme.inkSoft)
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
    }

    private var titleBlock: some View {
        HStack(spacing: 14) {
            Image(systemName: habit.symbol).font(.system(size: TypeSize.title)).foregroundStyle(Theme.jade)
                .frame(width: 52, height: 52).background(Theme.mist, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(habit.title).font(.ysTitle).tracking(1).foregroundStyle(Theme.ink).lineLimit(1)
                    if habit.archived { Chip(text: "已归档", color: Theme.inkSoft) }
                    if !habit.category.isEmpty { Chip(text: habit.category, color: Theme.color(for: habit.category)) }
                }
                Text(stats.spec.scheduleSummary + targetText + "　自 \(stats.spec.startDay.label(relativeTo: LocalDay.today())) 起")
                    .font(.ysCallout).monospacedDigit().foregroundStyle(Theme.inkSoft).lineLimit(1)
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("编辑…", action: onEdit)
            Button(habit.archived ? "取消归档" : "归档") {
                if habit.archived { requestUnarchive() } else { setArchived(true) }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("编辑或归档")
        .accessibilityLabel("更多")
    }

    private var targetText: String {
        guard let target = habit.targetValue, target > 0 else { return "" }
        return "，每次 \(format(target))\(habit.unit)"
    }

    private func format(_ value: Double) -> String { amountText(value) }

    @ViewBuilder
    private var todayControl: some View {
        // 今天这条打卡直接从统计里取（stats.logs 按天的字典），不再一遍遍扫全部打卡
        let todayLog = stats.logs[stats.today]
        // 显示与达标判定一致：今天按这条打卡记下的目标算（改目标时今天这条不补记，按新目标；旧版本改目标时补记过的才按旧目标）
        let todayTarget = HabitQuantity.target(habit, log: todayLog)
        if HabitQuantity.usesInput(habit, log: todayLog) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("数量", text: $quantityText)
                        .frame(width: 60)
                        .textFieldStyle(.yunshan)
                        .onAppear { quantityText = todayLog?.quantity.map(HabitQuantity.text) ?? "" }
                        .onSubmit(saveQuantity)
                    Text(todayTarget.map { habit.unit.isEmpty ? "/ \(format($0))" : "/ \(format($0)) \(habit.unit)" } ?? habit.unit)
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkSoft)
                        .fixedSize()
                    Button("记录", action: saveQuantity)
                    // 与首页直接用同一条规则（DashboardRules）：目标 ≤20 → +1，≤120 → +5，更大按目标的 1/8（8000 步 → +1000）
                    let step = Self.step(todayTarget)
                    Button(DashboardRules.stepLabel(step)) { addStep(todayTarget) }
                        .help("今天再记 \(format(step))\(habit.unit.isEmpty ? "" : " \(habit.unit)")")
                        .accessibilityLabel("今天再记 \(format(step)) \(habit.unit)")
                    if todayLog != nil {
                        Button { clearToday() } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.inkSoft)
                            .help("清除今日记录")
                            .accessibilityLabel("清除今日记录")
                    }
                    // 已记了未达标的数量时点圈弹出数量输入（与左侧列表一致；不用程序把焦点交给数量框——它的样式里已有一层 .focused）
                    HabitCheckIn(habit: habit, stats: stats, size: 30, allHabits: allHabits, config: config,
                                 arrowEdge: .bottom) { day in
                        quantityText = HabitDayLogs(day: day, context: context).log(of: habit)?.quantity.map(HabitQuantity.text) ?? ""
                    }
                }
                if let note = targetChangeNote(todayTarget) {
                    Hint(note)
                }
            }
            // 列表、热力图、飞剑传书改了今天的记录时，输入框跟着刷新（只在记录变化时回填，不打断正在输入的内容）
            .onChange(of: todayLog?.quantity) { _, quantity in
                quantityText = quantity.map(HabitQuantity.text) ?? ""
            }
        } else {
            HStack(spacing: 8) {
                Text(stats.isAchieved(stats.today) ? "今日已完成" : "今日打卡").foregroundStyle(Theme.inkSoft).fixedSize()
                HabitCheckIn(habit: habit, stats: stats, size: 34, allHabits: allHabits, config: config, arrowEdge: .bottom)
            }
        }
    }

    /// 今天适用的目标与习惯当前的目标不同（旧版本里今天改过数量目标、今天这条已补记成改之前的设定）时的说明
    private func targetChangeNote(_ todayTarget: Double?) -> String? {
        let current = habit.targetValue.flatMap { $0 > 0 ? $0 : nil }
        guard todayTarget != current else { return nil }
        let unit = habit.unit.isEmpty ? "" : " \(habit.unit)"
        if let todayTarget { return "今天仍按改目标前的 \(format(todayTarget))\(unit) 计，明天起按新设定" }
        return "今天按改目标前的设定计：记了即算完成，明天起按新目标"
    }

    private func saveQuantity() {
        // 输错、清空、填 0 都不动记录（要删除今天的记录请点“清除”）；“8,500”这类千分位按 8500 解析
        guard let value = HabitQuantity.parse(quantityText), value > 0 else {
            NSSound.beep()
            return
        }
        HabitActions.setQuantity(habit, on: today, quantity: value, context: context, effects: effects, allHabits: allHabits, config: config)
    }

    /// “+1”：在今天已记的数量上加一步（点的时候再取今天这条，列表、首页、传书刚改过也不会算错）。
    /// 数量框里改了数、还没点“记录”就点“+1”：以框里的数为底再加一步，打的数不被冲掉（HabitQuantity.stepBase）；
    /// 框里是读不懂的字时不加、响一声
    private func addStep(_ target: Double?) {
        let day = today
        let stored = HabitDayLogs(day: day, context: context).log(of: habit)?.quantity
        guard let base = HabitQuantity.stepBase(typed: quantityText, shown: stats.logs[stats.today]?.quantity, stored: stored) else {
            NSSound.beep()
            return
        }
        let value = base + Self.step(target)
        HabitActions.setQuantity(habit, on: day, quantity: value, context: context,
                                 effects: effects, allHabits: allHabits, config: config)
        // 存下的数与原来一样时（框里 3、库里 4，点“+1”还是 4）下面的 onChange 不会回填：这里直接写回
        quantityText = HabitQuantity.text(value)
    }

    /// 一步加多少：首页的 DashboardRules.quantityStep（没有目标时按 1）
    static func step(_ target: Double?) -> Double { DashboardRules.quantityStep(target: target ?? 0) }

    private func clearToday() {
        HabitActions.setQuantity(habit, on: today, quantity: nil, context: context, effects: effects, allHabits: allHabits, config: config)
        quantityText = ""
    }

    // MARK: 趋势

    private var trendChart: some View {
        let thisMonday = stats.today.mondayOfWeek
        let trend = stats.weeklyTrend(weeks: 12)
        return VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "近 12 周完成率", hint: "开始打卡之前的几周不画线")
            Chart {
                ForEach(trend, id: \.weekStart) { point in
                    if let rate = point.rate {
                        // 单调插值：曲线不会越过 0% 和 100%（catmullRom 会沉到 0% 以下，像负的完成率）
                        LineMark(x: .value("周", point.weekStart.date()), y: .value("完成率", rate * 100))
                            .foregroundStyle(Theme.jade)
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("周", point.weekStart.date()), y: .value("完成率", rate * 100))
                            .foregroundStyle(point.weekStart == thisMonday ? Theme.gold : Theme.jade)
                        AreaMark(x: .value("周", point.weekStart.date()), y: .value("完成率", rate * 100))
                            .foregroundStyle(LinearGradient(colors: [Theme.jade.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYScale(domain: 0...100)
            // 横轴固定 12 周：开始之前的几周留空，不会自动收成只有数据的那几周（与标题对得上）
            .chartXScale(domain: (trend.first?.weekStart ?? thisMonday).date() ... (trend.last?.weekStart ?? thisMonday).date())
            // 百分比刻度放左边，右端的“本周”圆点不再和 100% 挤在一起
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.ysMicro).monospacedDigit() }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            let day = LocalDay(date: date)
                            Text("\(day.month)月\(day.day)日").font(.ysMicro).monospacedDigit()
                        }
                    }
                }
            }
            .chartPlotStyle { $0.padding(.trailing, 6) }
            .frame(height: 160)
            if trend.allSatisfy({ $0.rate == nil }) {
                Hint("开始打卡后，这里会显示每周完成率的变化。")
            }
        }
    }
}

/// 功课详情的热力图（按卡片宽度铺满，8–26 周；点击补卡 / 取消）。
/// 只接收值：格子的颜色、悬停提示里的数量都从 stats 里按天查（stats.logs 是按天的字典），不再每格把全部打卡扫一遍；
/// 卡片宽度也记在这里，拖窗口改宽度时只重画热力图，详情页的其他部分不跟着重算。
private struct HabitHeatmap: View, Equatable {
    var habit: Habit
    var stats: HabitStats
    var allHabits: [Habit]
    var config: CultivationConfig

    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    /// 没打的淡墨、无需打卡的底色按浅 / 深色各取一档（深色下两者靠透明度才分得开）
    @Environment(\.colorScheme) private var scheme
    /// 点开数量输入的那一天
    @State private var quantityDay: LocalDay?
    /// 可用的宽度：格子大小按它算，铺满整张卡
    @State private var heatWidth: CGFloat = 0

    /// 详情页因为打字、弹出确认框而重建时，习惯、统计、设置都没变就不重画。
    /// 打卡、改设置之后统计会变，照常刷新；直接读的习惯字段（单位、归档等）变了也会按 SwiftData 的观察单独刷新。
    /// 跳过时保留的旧点击闭包用的 allHabits、config 也在比较之列，不会拿旧的去打卡
    static func == (a: Self, b: Self) -> Bool {
        a.habit === b.habit && a.stats == b.stats && a.config == b.config && a.allHabits.elementsEqual(b.allHabits, by: ===)
    }

    var body: some View {
        let today = stats.today
        let thisMonday = today.mondayOfWeek
        let labelWidth: CGFloat = 16, gap: CGFloat = 3, maxCell: CGFloat = 22
        // 周数按卡片宽度算：格子放到最大（22pt）时这一行放得下几周就画几周（至少 8、至多 26），网格横向铺满整张卡；
        // 开始之前的日子画成极淡的底格，不留空列。还没量到宽度时，先按开始那一周起算（8–20 周）。
        // 最早的一天：开始日期和最早一条打卡取早的（打卡的日子就是 stats.logs 的键，不必再把全部打卡的日期解析一遍）
        let earliest = min(stats.spec.startDay, stats.logs.keys.min() ?? stats.spec.startDay)
        let sinceStart = earliest.mondayOfWeek.days(to: thisMonday) / 7 + 1
        let weeks = heatWidth > 0
            ? min(26, max(8, Int((heatWidth - labelWidth) / (maxCell + gap)), min(20, sinceStart)))
            : min(20, max(8, sinceStart))
        let firstMonday = thisMonday.adding(days: -7 * (weeks - 1))
        let size = heatWidth > 0 ? max(10, min(maxCell, ((heatWidth - labelWidth) / CGFloat(weeks) - gap).rounded(.down))) : 14
        let unit = habit.unit
        return VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "近 \(weeks) 周",
                      hint: (habit.targetValue ?? 0) > 0 ? "点击格子可补记或修改当天数量" : "点击格子可补卡或取消")
            VStack(alignment: .leading, spacing: 5) {
                // 月份刻度：写在某月 1 日所在的那一列
                HStack(spacing: gap) {
                    Color.clear.frame(width: labelWidth, height: 12)
                    ForEach(0..<weeks, id: \.self) { w in
                        Color.clear.frame(width: size, height: 12)
                            .overlay(alignment: .leading) {
                                if let label = monthLabel(column: w, firstMonday: firstMonday) {
                                    Text(label).font(.ysMicro).foregroundStyle(Theme.inkSoft).fixedSize()
                                }
                            }
                    }
                }
                HStack(alignment: .top, spacing: gap) {
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { d in
                            Text(d % 2 == 0 ? LocalDay.weekdayShortNames[d] : "").font(.ysMicro).foregroundStyle(Theme.inkSoft)
                                .frame(width: labelWidth, height: size)
                        }
                    }
                    ForEach(0..<weeks, id: \.self) { w in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { d in
                                let day = firstMonday.adding(days: w * 7 + d)
                                cell(day, state: stats.state(on: day), quantity: stats.logs[day]?.quantity, unit: unit, size: size)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if abs(width - heatWidth) > 0.5 { heatWidth = width }
            }
            // 图例与格子同一套颜色：已打 · （数量型才有的）未达标 · 未打 · 无需
            HStack(spacing: 12) {
                legend(.done, "已打")
                if (habit.targetValue ?? 0) > 0 || stats.logs.values.contains(where: { !stats.spec.achieved($0) }) {
                    legend(.partial, "未达标")
                }
                legend(.missed, "未打")
                legend(.rest, "无需")
            }
        }
    }

    /// 某一列（一周）顶上的月份：这一周里有某月 1 日就写那个月；第一列写当月，除非紧接着两列内就要换月
    private func monthLabel(column w: Int, firstMonday: LocalDay) -> String? {
        func startsMonth(_ column: Int) -> Bool {
            let monday = firstMonday.adding(days: 7 * column)
            return monday.day == 1 || monday.adding(days: 6).month != monday.month
        }
        let monday = firstMonday.adding(days: 7 * w)
        if startsMonth(w) { return "\(monday.adding(days: 6).month)月" }
        if w == 0, !startsMonth(1), !startsMonth(2) { return "\(monday.month)月" }
        return nil
    }

    /// quantity：这天记的数量（悬停提示里显示），由调用方从 stats.logs 查好
    /// 格子的底色。没打的日子是淡墨（朱砂只表示警示，不给过去盖章），让“已打”的墨绿当主角；
    /// 无需打卡的日子更淡、另描一圈细边（浅色下单靠底色与淡墨分不开）；开始之前的日子画成极淡的底格（铺满时左边不留空列）
    private func fill(_ state: HabitDayState) -> Color {
        let dark = scheme == .dark
        return switch state {
        case .done: Theme.jade
        case .partial: Theme.gold.opacity(0.6)
        case .missed: Theme.ink.opacity(dark ? 0.16 : 0.08)
        case .rest: Theme.line.opacity(dark ? 0.35 : 0.3)
        case .future: Theme.line.opacity(0.2)
        case .beforeStart: Theme.line.opacity(0.12)
        }
    }

    /// 无需打卡的格子另描的细边
    private var restBorder: Color { Theme.line.opacity(scheme == .dark ? 0.9 : 1) }

    private func cell(_ day: LocalDay, state: HabitDayState, quantity: Double?, unit: String, size: CGFloat) -> some View {
        let radius = max(3, size * 0.2)
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill(state))
            .overlay {
                if state == .rest { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(restBorder, lineWidth: 0.75) }
            }
            .frame(width: size, height: size)
            .overlay { if day == stats.today { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.ink, lineWidth: 1) } }
            .contentShape(Rectangle())
            .help("\(day.shortLabel) \(day.weekdayName)" + (quantity.map { "　\(amountText($0)) \(unit)" } ?? ""))
            .onTapGesture {
                // 点的时候再取“今天”和这天的打卡（与打卡圈一致）
                guard day <= .today(), !habit.archived else { return }
                // 数量型（或这天按当时的目标记过数量）：打开数量输入补记真实数量，不把它改写成目标值，也不会一点就整条删掉。
                // 这天的打卡按日期直接取（不读 habit.logs）
                if HabitQuantity.usesInput(habit, on: day, context: context) {
                    quantityDay = day
                } else {
                    HabitActions.toggle(habit, on: day, context: context, effects: effects, allHabits: allHabits, config: config)
                }
            }
            .popover(isPresented: Binding(isPresent: $quantityDay, equals: day), arrowEdge: .bottom) {
                QuantityLogPopover(habit: habit, day: day, allHabits: allHabits, config: config, context: context, effects: effects) { quantityDay = nil }
            }
    }

    private func legend(_ state: HabitDayState, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(fill(state))
                .overlay { if state == .rest { RoundedRectangle(cornerRadius: 2).strokeBorder(restBorder, lineWidth: 0.75) } }
                .frame(width: 10, height: 10)
            Text(text).font(.ysCaption).foregroundStyle(Theme.inkSoft)
        }
    }
}

/// 功课详情的“最近记录”（最近 10 条）。与热力图一样只接收值，详情页里打字时统计没变就不重画
private struct HabitRecentLogs: View, Equatable {
    var habit: Habit
    var stats: HabitStats
    var allHabits: [Habit]
    var config: CultivationConfig

    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    /// 点开数量输入的那一天（与热力图分开，免得两个弹窗同时出现）
    @State private var quantityDay: LocalDay?

    /// 同 HabitHeatmap：习惯、统计、设置都没变就不重画；打卡的时长、备注变了由 SwiftData 的观察单独刷新
    static func == (a: Self, b: Self) -> Bool {
        a.habit === b.habit && a.stats == b.stats && a.config == b.config && a.allHabits.elementsEqual(b.allHabits, by: ===)
    }

    var body: some View {
        // 只让数据库按日期倒序取最新的 10 条（不读 habit.logs，也不把全部打卡排序）
        let logs = HabitLogQuery.recent(habit, 10)
        return VStack(alignment: .leading, spacing: 6) {
            CardTitle(title: "最近记录")
            if logs.isEmpty { EmptyHint(.noLogs) }
            ForEach(logs) { log in
                let day = LocalDay(key: log.dateKey)
                HStack {
                    Text(day.map { "\($0.shortLabel) \($0.weekdayName)" } ?? log.dateKey)
                        .font(.ysCallout.monospacedDigit()).frame(width: 120, alignment: .leading)
                    // 达标与否按这条打卡当时的数量目标算（与热力图一致）；未达标的数量用金色标出
                    let ok = day.map { stats.isAchieved($0) } ?? false
                    if let q = log.quantity { Text("\(amountText(q)) \(habit.unit)").monospacedDigit().foregroundStyle(ok ? Theme.inkSoft : Theme.gold) }
                    if let minutes = log.durationMinutes { Text("\(minutes) 分钟").monospacedDigit().foregroundStyle(Theme.inkSoft) }
                    if !log.notes.isEmpty { Text(log.notes).foregroundStyle(Theme.inkSoft).lineLimit(1) }
                    Spacer()
                    // 这天要不要用数量输入：按统计里这天的打卡判断（stats.logs），不再每行扫一遍全部打卡
                    if let day, !habit.archived, day <= stats.today, HabitQuantity.usesInput(habit, log: stats.logs[day]) {
                        Button { quantityDay = day } label: { Image(systemName: "square.and.pencil") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.inkSoft)
                            .help("修改这天的数量")
                            .accessibilityLabel("修改 \(day.shortLabel) 的数量")
                            .popover(isPresented: Binding(isPresent: $quantityDay, equals: day), arrowEdge: .bottom) {
                                QuantityLogPopover(habit: habit, day: day, allHabits: allHabits, config: config,
                                                   context: context, effects: effects) { quantityDay = nil }
                            }
                    }
                    Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? Theme.jade : Theme.gold)
                }
            }
        }
    }
}

struct HabitEditor: View {
    var habit: Habit?
    var nextSortOrder: Int

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// 现有的功课（只看名称）：功法谱里与它们同名的那式变淡、写“已立”
    @Query(sort: \Habit.sortOrder) private var existing: [Habit]
    /// 功法谱里刚点的那一式（名称改掉之后不再亮着）
    @State private var picked: String?
    @State private var title = ""
    @State private var category = ""
    @State private var symbol = "leaf"
    @State private var frequency = HabitFrequency.daily
    @State private var targetPerWeek = 3
    @State private var weekdays: [Int] = [0, 2, 4]
    @State private var hasTarget = false
    @State private var targetValue = 30.0
    @State private var unit = "分钟"
    @State private var startDate = LocalDay.today().key
    @State private var notes = ""
    @State private var confirmDelete = false
    /// 改频率 / 星期 / 开始日期会让历史修为变化时，先确认
    @State private var pendingXP: HabitXPChange?

    /// 开始日期早于今天（新建，或比原来更早）：提醒这些日子会变成应打卡
    private var startsEarlier: Bool {
        guard let day = LocalDay(key: startDate), day < LocalDay.today() else { return false }
        guard let habit else { return true }
        return day < (LocalDay(key: habit.startDate) ?? LocalDay(date: habit.createdAt))
    }

    /// 弹窗高度：新建 700（多一块功法谱），编辑 680。都在 1180×780 的窗口里放得下
    static func sheetHeight(new: Bool) -> CGFloat { new ? 700 : 680 }

    static let symbols = ["leaf", "book", "figure.run", "drop", "moon.zzz", "brain.head.profile", "pencil.and.scribble",
                          "dumbbell", "fork.knife", "cup.and.saucer", "music.note", "globe.asia.australia", "heart", "sun.max", "graduationcap"]

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !(frequency == .weekdays && weekdays.isEmpty) && !(hasTarget && !validTarget)
    }

    var body: some View {
        // 新建时顶上多一块功法谱，弹窗高一些（表单本身在弹窗里滚动，超出时底部渐隐，小窗口下底栏的保存仍在原处）。
        // 编辑时 600 → 680：备注一节整块放得下，不再被按钮栏切在一半
        EditorSheet(eyebrow: "每日功课", title: habit == nil ? "新建习惯" : "编辑习惯",
                    size: CGSize(width: 540, height: Self.sheetHeight(new: habit == nil)),
                    canSave: canSave, onSave: requestSave, onDelete: habit == nil ? nil : { confirmDelete = true }) {
            if habit == nil { templateShelf }
            FormSection {
                FormRow(label: "名称") { TextField("", text: $title, prompt: Text("例如：晨读")) }
                FormRow(label: "类别") { TextField("", text: $category, prompt: Text("学习 / 健康 / 生活…")) }
                FormRow(label: "图标", top: true) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), alignment: .leading, spacing: 6) {
                        ForEach(Self.symbols, id: \.self) { name in
                            let on = symbol == name
                            Button { symbol = name } label: {
                                // 选中样式与月历、选项一致：玉色实底（深色是温玉）+ onJadeFill
                                Image(systemName: name)
                                    .foregroundStyle(on ? Theme.onJadeFill : Theme.jade)
                                    .frame(width: 30, height: 30)
                                    .background(on ? AnyShapeStyle(Theme.jadeFill) : AnyShapeStyle(Theme.mist.opacity(0.7)),
                                                in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("图标 \(name)")
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
            }
            FormSection(title: "节奏") {
                FormRow(label: "频率") {
                    ChipPicker(selection: $frequency, options: HabitFrequency.allCases.map { ($0, $0.label) })
                }
                if frequency == .weekly {
                    FormRow(label: "次数") { Stepper("每周 \(targetPerWeek) 次", value: $targetPerWeek, in: 1...7).fixedSize() }
                }
                if frequency == .weekdays {
                    FormRow(label: "星期") { WeekdayPicker(selection: $weekdays) }
                }
                FormRow(label: "数量") { Toggle("设定数量目标", isOn: $hasTarget) }
                if hasTarget {
                    FormRow(label: "每次") {
                        HStack {
                            TextField("", value: $targetValue, format: .number, prompt: Text("目标")).frame(width: 90)
                                .accessibilityLabel("目标数量")
                            TextField("", text: $unit, prompt: Text("单位")).frame(width: 90)
                                .accessibilityLabel("单位")
                            Text("达到目标才算完成").font(.ysCaption).foregroundStyle(Theme.inkSoft)
                        }
                    }
                }
                FormRow(label: "开始日期") { DayField(label: "", key: $startDate) }
                if startsEarlier {
                    Hint("开始日期早于今天：这之后没打卡的应做日会在热力图上显示为“未打”，并计入完成率；可以点格子补卡。")
                        .padding(.vertical, 3)
                }
            }
            NotesSection(text: $notes, lines: 1...3)
        }
        .onAppear(perform: load)
        .onChange(of: title) { _, now in
            if let picked, now != picked { self.picked = nil }
        }
        .confirmationDialog("这次修改会改变历史修为", isPresented: Binding(isPresent: $pendingXP),
                            presenting: pendingXP) { _ in
            Button("仍然保存") { save() }
        } message: { change in
            Text("修为按新的频率、星期和开始日期重算过去每一天的“功课圆满”，将从 \(change.before) 变为 \(change.after)（\(change.deltaText)）。")
        }
        .confirmationDialog("删除这个习惯及其全部打卡记录？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                if let habit { context.delete(habit) }
                DataStore.save(context)
                // 修为模型当场看一眼：去掉这个习惯和它的打卡（不留着已删除的对象等下一轮）
                CultivationModel.existing(for: context)?.refresh()
                dismiss()
            }
        } message: { Text("修为会同步扣除，且无法恢复。若只是暂停，建议使用“归档”。") }
    }

    // MARK: 功法谱

    /// 新建功课弹窗顶部的功法谱：四组胶囊，点一式把名称、类别、图标、频率、数量、备注填进下面的表单（还能改），再点保存
    private var templateShelf: some View {
        let active = existing.filter { !$0.archived }.map(\.title)
        let archived = existing.filter(\.archived).map(\.title)
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "功法谱 · 点一式，再按需改")
            VStack(alignment: .leading, spacing: 7) {
                ForEach(HabitTemplates.grouped, id: \.group) { group in
                    HStack(alignment: .top, spacing: 10) {
                        Text(group.group)
                            .font(Theme.songti(TypeSize.caption, .medium)).tracking(1)
                            .foregroundStyle(Theme.inkSoft)
                            .frame(width: 30, alignment: .leading)
                            .padding(.top, 5)
                        FlowLayout(spacing: 6) {
                            ForEach(group.items) { template in
                                let inUse = HabitTemplates.isInstalled(template, titles: active)
                                let shelved = !inUse && HabitTemplates.isInstalled(template, titles: archived)
                                HabitTemplateChip(template: template, installed: inUse || shelved, archivedOnly: shelved,
                                                  picked: picked == template.id) { use(template) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Text("数量型功课：首页、功课页、菜单栏都可一点“+1”累计。").font(.ysCaption).foregroundStyle(Theme.inkSoft)
        }
    }

    /// 点了一式：填进表单（开始日期仍是今天）
    private func use(_ template: HabitTemplate) {
        title = template.title
        picked = template.id
        category = template.group
        symbol = template.symbol
        frequency = template.frequency
        targetPerWeek = template.targetPerWeek
        if !template.weekdays.isEmpty { weekdays = template.weekdays }
        hasTarget = template.targetValue != nil
        if let value = template.targetValue {
            targetValue = value
            unit = template.unit
        }
        notes = template.notes
    }

    private func load() {
        guard let habit else { return }
        title = habit.title
        category = habit.category
        symbol = habit.symbol
        frequency = habit.frequencyKind
        targetPerWeek = habit.targetPerWeek
        weekdays = habit.weekdays.isEmpty ? weekdays : habit.weekdays
        hasTarget = (habit.targetValue ?? 0) > 0
        targetValue = habit.targetValue ?? targetValue
        unit = habit.unit
        startDate = habit.startDate
        notes = habit.notes
    }

    /// 已有习惯改了频率 / 星期 / 开始日期：先估算历史修为的变化，有变化就请用户确认
    private func requestSave() {
        guard let habit else { return save() }
        let rhythmChanged = frequency != habit.frequencyKind || targetPerWeek != habit.targetPerWeek
            || (frequency == .weekdays ? weekdays : []) != habit.weekdays || startDate != habit.startDate
        guard rhythmChanged else { return save() }
        var spec = habit.spec
        spec.frequency = frequency
        spec.targetPerWeek = targetPerWeek
        spec.weekdays = frequency == .weekdays ? weekdays : []
        spec.startDay = LocalDay(key: startDate) ?? spec.startDay
        // 数量目标的改动不计入：改之前会给今天之前的旧打卡补记当时的目标，历史达标不受影响（今天起按新目标）
        if let change = HabitXPChange.preview(habit, spec: spec, archived: habit.archived, context: context) {
            pendingXP = change
        } else {
            save()
        }
    }

    /// 数量目标必须是有限的正数（拦住 1e999、inf、NaN 这类输入）
    private var validTarget: Bool { targetValue.isFinite && targetValue > 0 && targetValue < 1_000_000_000 }

    private func save() {
        let target = habit ?? Habit(title: title)
        if habit == nil {
            target.sortOrder = nextSortOrder
            context.insert(target)
        }
        let newTarget = hasTarget && validTarget ? targetValue : nil
        HabitQuantity.recordTargetsBeforeChange(target, to: newTarget)
        target.title = title.trimmingCharacters(in: .whitespaces)
        target.category = category
        target.symbol = symbol
        target.frequencyKind = frequency
        target.targetPerWeek = targetPerWeek
        target.weekdays = frequency == .weekdays ? weekdays : []
        target.targetValue = newTarget
        target.unit = hasTarget ? unit : ""
        target.startDate = startDate
        target.notes = notes
        target.updatedAt = Date()
        DataStore.save(context)
        // 修为模型当场看一眼：新设定、改数量目标前补记的旧目标（不动打卡的 updatedAt，靠保存通知里的 ID 认出来）一并算进统计
        CultivationModel.existing(for: context)?.refresh()
        dismiss()
    }
}

/// 功法谱的一枚胶囊：小图标 + “喝水 · 8 杯”。悬停时描一圈金边、浮起一点（关动效时只换颜色）；
/// 点中的那式是玉色实底；与现有功课同名的写“已立”（只剩已归档的那项时写“已归档”），不可点：
/// 去掉底色、描一圈虚线，字仍是淡墨整色。已立的那式不做成按钮（不用 .disabled）：系统会把停用的按钮再压暗一半，
/// 连同以前叠的半透明，“已立”两个字在深浅色下都读不出来
private struct HabitTemplateChip: View {
    var template: HabitTemplate
    var installed: Bool
    var archivedOnly: Bool
    var picked: Bool
    var action: () -> Void
    @Environment(\.spiritMotion) private var motion
    @State private var hover = false

    var body: some View {
        Group {
            if installed {
                face(lit: false)
                    .accessibilityElement(children: .ignore)
            } else {
                Button(action: action) { face(lit: hover && !picked) }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        withAnimation(motion ? Motion.hover : nil) { hover = inside }
                    }
            }
        }
        .help(installed ? (archivedOnly ? "已有同名的功课「\(template.title)」（已归档，可在列表里取消归档）" : "已有同名的功课「\(template.title)」")
              : template.detailText)
        .accessibilityLabel(installed ? "\(template.title)，\(archivedOnly ? "已归档" : "已立")" : template.chipText)
        .accessibilityHint(installed ? "" : template.detailText)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func face(lit: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: template.symbol)
                .font(.system(size: TypeSize.caption - 1))
                .foregroundStyle(picked ? Theme.onJadeFill : installed ? Theme.inkSoft : Theme.jade)
            Text(installed ? "\(template.title) · \(archivedOnly ? "已归档" : "已立")" : template.chipText).lineLimit(1)
        }
        .font(.system(size: TypeSize.caption, weight: picked ? .semibold : .regular))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(picked ? Theme.onJadeFill : installed ? Theme.inkSoft : Theme.ink)
        .background(picked ? AnyShapeStyle(Theme.jadeFill) : installed ? AnyShapeStyle(Color.clear)
                    : AnyShapeStyle(Theme.mist.opacity(lit ? 1 : 0.75)), in: Capsule())
        .overlay {
            if installed {
                Capsule().strokeBorder(Theme.inkSoft.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
            } else {
                Capsule().strokeBorder(picked ? Color.clear : lit ? Theme.gold.opacity(0.75) : Theme.line)
            }
        }
        .shadow(color: Theme.gold.opacity(lit && motion ? 0.25 : 0), radius: 4, y: 1)
        .scaleEffect(lit && motion ? 1.04 : 1)
        .contentShape(Capsule())
    }
}

/// 一键立好一式功法（筑基三关等不经新建弹窗的地方用）：名称、类别（组名）、图标、频率、数量、备注照模板，开始日期今天。
/// 已有同名、未归档的功课时不再新立，交回那一项（连点两下也只立一项）。立好即保存，修为模型当场看一眼
@MainActor
enum HabitTemplateInstaller {
    @discardableResult
    static func install(_ t: HabitTemplate, context: ModelContext, sortOrder: Int) -> Habit {
        let key = HabitTemplates.normalized(t.title)
        if let same = context.allHabits().first(where: { !$0.archived && HabitTemplates.normalized($0.title) == key }) { return same }
        let habit = Habit(title: t.title)
        habit.sortOrder = sortOrder
        context.insert(habit)
        habit.category = t.group
        habit.symbol = t.symbol
        habit.frequencyKind = t.frequency
        habit.targetPerWeek = t.targetPerWeek
        habit.weekdays = t.frequency == .weekdays ? t.weekdays : []
        habit.targetValue = t.targetValue
        habit.unit = t.targetValue == nil ? "" : t.unit
        habit.startDate = LocalDay.today().key
        habit.notes = t.notes
        habit.updatedAt = Date()
        DataStore.save(context)
        CultivationModel.existing(for: context)?.refresh()
        return habit
    }
}

/// 某数量型习惯在某一天的数量输入：补记 / 修改真实数量、按目标记为达标、清除当天记录。
/// 热力图、左侧列表的打卡圈和“最近记录”共用。
struct QuantityLogPopover: View {
    var habit: Habit
    var day: LocalDay
    var allHabits: [Habit]
    var config: CultivationConfig
    /// 显式传入（不依赖弹窗窗口继承环境）
    var context: ModelContext
    var effects: EffectsCenter
    var onDone: () -> Void

    @State private var text = ""

    var body: some View {
        // 这天的那条打卡按日期直接取（不读 habit.logs）
        let log = HabitDayLogs(day: day, context: context).log(of: habit)
        let target = HabitQuantity.target(habit, atLog: log?.targetAtLog)   // 用上面取好的这条，不再扫一遍
        let unit = habit.unit.isEmpty ? "" : " \(habit.unit)"
        VStack(alignment: .leading, spacing: 10) {
            Text("\(day.shortLabel) \(day.weekdayName) · \(habit.title)").font(.ysCallout.weight(.semibold)).foregroundStyle(Theme.ink)
            HStack(spacing: 6) {
                TextField("数量", text: $text)
                    .frame(width: 80)
                    .textFieldStyle(.yunshan)
                    .onSubmit(save)
                Text(target.map { "/ \(HabitQuantity.text($0))\(unit)" } ?? (habit.unit.isEmpty ? "" : habit.unit))
                    .foregroundStyle(Theme.inkSoft)
            }
            if target == nil {
                Text("这天打卡时还没有数量目标，记下数量即算完成。").font(.ysCaption).foregroundStyle(Theme.inkSoft)
            }
            HStack(spacing: 8) {
                Button("记录", action: save).buttonStyle(.yunshanPrimary)
                if let target, (log?.quantity ?? 0) < target {
                    Button("按目标记为达标") { commit(target) }
                        .help("把这天记为 \(HabitQuantity.text(target))\(unit)")
                }
                if log != nil {
                    Button("清除", role: .destructive) { commit(nil) }
                        .help("删除这天的打卡记录")
                }
            }
        }
        .padding(14)
        .frame(minWidth: 260, alignment: .leading)
        .onAppear { text = log?.quantity.map(HabitQuantity.text) ?? "" }
    }

    private func save() {
        // 空白、输错、填 0 都不动记录（删除请点“清除”）
        guard let value = HabitQuantity.parse(text), value > 0 else {
            NSSound.beep()
            return
        }
        commit(value)
    }

    private func commit(_ quantity: Double?) {
        guard day <= .today(), !habit.archived else { return onDone() }
        HabitActions.setQuantity(habit, on: day, quantity: quantity, context: context, effects: effects, allHabits: allHabits, config: config)
        onDone()
    }
}
