import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    var onNavigate: (AppSection) -> Void

    // 修为、功课统计读应用级的 CultivationModel（与侧栏境界卡共用，数据变了才重算）；今日已落、今日行程拆成子视图，
    // 只取今天的落笔、只取可能落在今天到之后三天的日程，不再为了这几条把全部修行录与日程挂在 @Query 上。
    // 本页顶层不读动效开关：窗口前后台切换时不必整页重算，只有今日功课卡、旧笔新读卡和“已过 N 项”的展开按钮自己读。
    @Environment(CultivationModel.self) private var cultivation
    @Environment(\.modelContext) private var context
    @Query private var profiles: [Profile]
    /// 筑基三关：点过“收起”、三关全过的那天（出不出现见 Onboarding.shows；落过的印等其余几项由卡片自己读写）
    @AppStorage(Onboarding.dismissedKey) private var onboardingDismissed = false
    @AppStorage(Onboarding.doneDayKey) private var onboardingDoneDay = ""
    /// 落笔类型也算草稿：切页、重启后接着写（正文等由 JournalComposer 存在 draft.dashboard.* 下）
    @AppStorage("draft.dashboard.kind") private var quickKind: JournalKind = .diary
    /// 还没有功课时，“今日功课”卡上的“立下第一项功课”就地打开新建弹窗
    @State private var creatingHabit = false

    var body: some View {
        // “今天”在一次渲染里只取一次，各卡片共用
        let today = LocalDay.today()
        // 新手的筑基三关（老用户、收起了、功成次日都不出）；出现时修为卡收成一行
        let onboarding = showsOnboarding(today)
        // 横幅只留问候（眉题）和题词；跳转入口在侧栏和各卡片里。问候每分钟自己刷新（LiveGreetingText），首页 body 不跟着重算
        PageScaffold(page: .overview, greeting: HeroGreeting(name: profiles.first?.displayName ?? "道友", today: today)) {
            // 左栏：落笔（含今日已落）、筑基三关（新手）、旧笔新读、修为；右栏：所向（有进行中的目标时）、今日功课、今日行程（含之后三天）。
            // 每张卡用 overviewSlot 说明放哪一栏、窄窗口上下排时排第几；两栏顶端对齐，不再强行等高（见 OverviewColumns）
            OverviewColumns {
                // 周日 18:00 到周一 12:00：两栏上面一条通栏纸笺“七日已过 · …　翻看七日小卷 →”（#14）；其余时候整条不出、不占卡距
                DashboardWeeklyStrip().overviewSlot(.top, stacked: -1)
                composerCard(today).ysEntrance(order: 0).overviewSlot(.left, stacked: 0)
                if onboarding {
                    OnboardingCard(today: today) { creatingHabit = true }.ysEntrance(order: 1).overviewSlot(.left, stacked: 0.5)
                }
                // 一篇修行录都没有时整张不出：里面什么都不出，这一格就没有子视图，左栏不留卡距
                DashboardLookBack(today: today).equatable().overviewSlot(.left, stacked: 3)
                cultivationCard(today, compact: onboarding).ysEntrance(order: 4).overviewSlot(.left, stacked: 4)
                // 没有进行中的目标时整张不出（同旧笔新读）
                GoalStrip(today: today) { onNavigate(.profile) }.equatable().overviewSlot(.right, stacked: 0.8)
                DashboardHabits(today: today) { creatingHabit = true }.ysEntrance(order: 1).overviewSlot(.right, stacked: 1)
                timelineCard(today).ysEntrance(order: 3).overviewSlot(.right, stacked: 2)
            }
        }
        // 旧笔新读里删掉一篇后，页面底部约 8 秒“撤销删除”（只有这条提示自己读删除记录，首页 body 不跟着重算）
        .overlay(alignment: .bottom) { DashboardLookBackUndoBar() }
        // 七日小卷：纸笺“翻看七日小卷”、或别处发来的 AppRouter.weeklyScroll，首页在当前页时由首页打开（不与修行录抢，见 DashboardHooks）
        .dashboardWeeklyReceiver()
        // 落笔草稿什么都没写时，停在“复盘”的空白模板回到日记，免得以后随手写的一句被当成复盘入卷
        .onAppear { JournalDraft.resetIfBlank(page: "dashboard") }
        // 页面出现、或页面还开着时过了午夜：让修为模型看一眼（换到新的一天；没变化时约 1 毫秒），功课统计与“今天”对得上
        .task(id: today.key) { cultivation.refresh() }
        // 排序号与每日功课页一致：接在全部功课（含已归档）之后
        .sheet(isPresented: $creatingHabit) { HabitEditor(habit: nil, nextSortOrder: (cultivation.habits.map(\.sortOrder).max() ?? 0) + 1) }
    }

    // MARK: 落笔（含今日已落）

    private func composerCard(_ today: LocalDay) -> some View {
        // 两段之间的 14 由“今日已落”自己留（顶部留白）：它没内容时也占栈里的一格，间距放在栈上会多出一道空隙
        VStack(alignment: .leading, spacing: 0) {
            JournalComposer(kind: $quickKind, compact: true, onOpenChronicle: openChronicle)
            // 隔了 3 天以上回来、今天还没记录：落笔框下面一行“闭关 5 日，今日出关——从一句开始。”（自带上边距，不出时不占地方）。
            // 不放在卡顶：那样“落笔”标题被推下一行，与右栏“今日功课”的标题不再齐平
            DashboardReturnLine()
            // 今天写过的才列出来（最多 3 篇）；没写时不显示这一节，邀请只说一次
            DashboardTodayEntries(dayKey: today.key).equatable()
            // 20:00 起卡底一行今日小结“今日：功课 3/5 · 已落 1 篇 · 心境未记”（自带上边距）
            DashboardTonightLine()
        }
        .xianCard(tier: .jade)
    }

    /// 出不出筑基三关：收起了、或功成那天已过就不必数；否则按“有记录的日子”判断老用户（数过的按库、日期、篇数记住，见 OnboardingLoader）
    private func showsOnboarding(_ today: LocalDay) -> Bool {
        guard !onboardingDismissed, onboardingDoneDay.isEmpty || onboardingDoneDay == today.key else { return false }
        return Onboarding.shows(dismissed: false, doneDay: onboardingDoneDay, today: today,
                                recordDays: OnboardingLoader.recordDays(context: context, cultivation: cultivation, today: today))
    }

    /// 翻开修行录：这里写了一半、修行录的落笔框又是空的，就把草稿带过去接着补标题和标签
    private func openChronicle() {
        JournalDraft.moveIfTargetBlank(from: "dashboard", to: "chronicle")
        onNavigate(.chronicle)
    }

    // MARK: 修为

    /// 首页唯一的修为卡：境界名、累计修为、今日所得、距下一境界都在侧栏境界卡上（一屏只说一次），
    /// 这里放侧栏没有的近 14 日走势与合计；标题行右侧衬一枚当前境界的徽记（只是图，不再写字）。
    /// 图表高度至少 96；左栏比右栏矮时卡片最多多拉 160（OverviewColumns），多出来的都给图表（最多 256），卡里不留空白。
    /// 近 14 日一根柱都没有（修为开着）：整卡收成一行提示，不画空图。
    /// 筑基三关出现时（compact）：同样收成一行“近 14 日修为 共 +N”，把地方让给新手卡。
    @ViewBuilder
    private func cultivationCard(_ today: LocalDay, compact: Bool) -> some View {
        let cultivation = self.cultivation.state
        let config = self.cultivation.config
        let days = (0..<14).map { today.adding(days: -13 + $0) }
        let total = days.reduce(0) { $0 + (cultivation.perDay[$1] ?? 0) }
        if config.enabled && days.allSatisfy({ (cultivation.perDay[$0] ?? 0) == 0 }) {
            emptyCultivationCard(realmIndex: cultivation.realmIndex, realm: cultivation.realmName + cultivation.stage)
        } else if compact {
            compactCultivationCard(total: total, enabled: config.enabled, realmIndex: cultivation.realmIndex,
                                   realm: cultivation.realmName + cultivation.stage)
        } else {
            cultivationChartCard(today, days: days, total: total)
        }
    }

    /// 近 14 日一根柱都没有：一行提示，行尾衬一枚当前境界的徽记（认得出这是修为卡）。不拉高（没有 maxHeight: .infinity）
    private func emptyCultivationCard(realmIndex: Int, realm: String) -> some View {
        HStack(spacing: 12) {
            EmptyHint(.noCultivation)
            SceneryImage(name: RealmBadge.emblem(for: realmIndex))
                .frame(width: 28, height: 28)
                .shadow(color: Theme.precious.opacity(0.3), radius: 5)
                .help("当前境界：\(realm)")
                .accessibilityLabel("当前境界：\(realm)")
        }
        .padding(.vertical, -4)
        .help("近 14 日修为：打卡与落笔所得的修为，有了第一笔就画成柱图")
        .xianCard()
    }

    /// 筑基三关出现时的一行：标题、合计，行尾衬一枚当前境界的徽记。不拉高
    private func compactCultivationCard(total: Int, enabled: Bool, realmIndex: Int, realm: String) -> some View {
        CardTitle(title: "近 14 日修为", detail: enabled ? (total == 0 ? "" : "共 +\(total)") : "已关闭",
                  hint: "近 14 天打卡与落笔所得的修为；筑基三关收起后，这里展开成柱图") {
            SceneryImage(name: RealmBadge.emblem(for: realmIndex))
                .frame(width: 28, height: 28)
                .shadow(color: Theme.precious.opacity(0.3), radius: 5)
                .padding(.vertical, -6)
                .help("当前境界：\(realm)")
                .accessibilityLabel("当前境界：\(realm)")
        }
        .xianCard()
    }

    private func cultivationChartCard(_ today: LocalDay, days: [LocalDay], total: Int) -> some View {
        let cultivation = self.cultivation.state
        let config = self.cultivation.config
        return VStack(alignment: .leading, spacing: 12) {
            // 合计为 0 时不写“共 +0”（修为开着时这时整卡已收成一行；关着时标题旁写“已关闭”）
            CardTitle(title: "近 14 日修为", detail: config.enabled ? (total == 0 ? "" : "共 +\(total)") : "已关闭",
                      hint: "近 14 天每天打卡与落笔所得的修为，今天那根是金色；境界、今日所得与距下一境界见侧栏境界卡") {
                SceneryImage(name: RealmBadge.emblem(for: cultivation.realmIndex))
                    .frame(width: 36, height: 36)
                    .shadow(color: Theme.precious.opacity(0.3), radius: 6)
                    // 徽记比标题行高：上下各探出一点，不把标题行撑高
                    .padding(.vertical, -6)
                    .help("当前境界：\(cultivation.realmName)\(cultivation.stage)")
                    .accessibilityLabel("当前境界：\(cultivation.realmName)\(cultivation.stage)")
            }
            Chart(days, id: \.self) { day in
                // 按“天”为单位画：柱子居中在那一天，横轴标签与柱子对齐
                BarMark(x: .value("日期", day.date(), unit: .day), y: .value("修为", cultivation.perDay[day] ?? 0), width: .ratio(0.55))
                    .foregroundStyle(day == today ? Theme.precious : Theme.positive)
                    .cornerRadius(3)
            }
            // 刻度放在每两天那根柱子的正中（当天中午），标签正对着柱子
            .chartXAxis {
                AxisMarks(values: stride(from: 0, to: days.count, by: 2).map { days[$0].date().addingTimeInterval(12 * 3600) }) { value in
                    AxisValueLabel(anchor: .top) { if let date = value.as(Date.self) { Text(LocalDay(date: date).axisLabel).font(.ysMicro) } }
                }
            }
            // 刻度放左边：右端今天那根不再贴着“0”
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)").font(.ysMicro).monospacedDigit() } }
                }
            }
            .frame(minHeight: 96, idealHeight: 96, maxHeight: 96 + DashboardRules.maxStretch)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .xianCard(tier: .jade)
    }

    // MARK: 今日行程

    private func timelineCard(_ today: LocalDay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "今日行程", hint: "今天的日程与固定作息") {
                Button("时辰卷") { onNavigate(.schedule) }.buttonStyle(.cardLink)
                    .help("打开时辰卷；固定作息在侧栏的“起居有常”里编辑")
            }
            // 行程与之后三天：只取可能落在这几天的日程，今天与之后三天合成一次展开
            DashboardSchedule(today: today).equatable()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .xianCard()
    }
}

// MARK: - 今日功课

/// 今日功课卡：每项一行（打卡圈、名字、连续 N 天；数量型行尾“3/8 杯 +1”，见 Shared 的 HabitPlusStep）。
/// 每个习惯的统计由修为模型算好（与修为同一份，数据变了才重算），筛选、计数、列表共用。
/// 今天要做的超过 6 项时只列未圆满的，已圆满的收成一行“已圆满 N 项”（点开展开，记在 dashboard.habits.showDone）；
/// 刚打满的那一项先留在原处约 1.2 秒（打卡迸发放完、看得见勾上了）再收进去——不论是点圈、点“+1”，
/// 还是在数量框里“按目标记为达标”、填满数量（按“已圆满的几项”前后对比，不靠哪个按钮报信）。
/// 动效开关只在这张卡里读（收起、展开要不要动画），整页不必因为窗口前后台切换而重算。
private struct DashboardHabits: View {
    var today: LocalDay
    /// 还没有功课时，“立下第一项功课”就地打开新建弹窗（弹窗挂在首页上）
    var onCreate: () -> Void
    @Environment(CultivationModel.self) private var cultivation
    @Environment(\.spiritMotion) private var motion
    @AppStorage("dashboard.habits.showDone") private var showDone = false
    /// 上一次看到的已圆满的几项（卡片出现时记下；nil = 还没出现过）。比它多出来的就是刚圆满的
    @State private var seenDone: Set<PersistentIdentifier>?
    /// 刚圆满、还在“留一会儿”的几项（值是这一次留的记号：中途取消又打满时，旧的那次到点不把新的提前收走）
    @State private var lingering: [PersistentIdentifier: UUID] = [:]

    var body: some View {
        // 刚删掉、模型还没来得及重算的习惯不再显示（已删除的对象不能再读）
        let rows = cultivation.rows.filter { $0.habit.modelContext != nil }
        let due = rows.filter { $0.stats.isDueToday || $0.stats.logs[today] != nil }
        let doneIDs = Set(due.filter { $0.stats.isAchieved(today) }.map(\.id))
        // 收起时：未圆满的、刚圆满的（这一刻才圆满、或还在“留一会儿”的）照常列出；其余已圆满的收进一行
        let split = DashboardHabitFold.split(due, done: doneIDs, seen: seenDone, lingering: Set(lingering.keys))
        let listed = split.listed
        let folded = split.folded
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "今日功课", detail: due.isEmpty ? "" : "\(doneIDs.count)/\(due.count)")
            if due.isEmpty {
                if rows.isEmpty {
                    // 与每日功课页同一张留白；按钮就地打开“立下功课”的弹窗，立好后直接出现在这张卡里
                    OrnamentEmpty(.habits) {
                        Button(action: onCreate) { Label("立下第一项功课", systemImage: "plus") }
                            .buttonStyle(.yunshanPrimary)
                    }
                } else {
                    EmptyHint(.restDay)
                }
            } else {
                ForEach(listed) { row in habitRow(row) }
                if !folded.isEmpty {
                    DoneFoldToggle(count: folded.count, open: $showDone)
                    if showDone {
                        ForEach(folded) { row in habitRow(row) }
                    }
                }
                // 与修为规则一致：只看“每天 / 指定星期”的习惯，每周 N 次的不影响圆满
                if cultivation.perfectToday {
                    Text("功课圆满，今日额外 +\(CultivationEngine.perfectDayXP) 修为").font(.ysCaption).foregroundStyle(Theme.precious)
                }
            }
        }
        .xianCard()
        // 卡片出现时已圆满的不算“刚圆满”
        .onAppear { if seenDone == nil { seenDone = doneIDs } }
        .onChange(of: doneIDs) { old, new in
            for id in new.subtracting(seenDone ?? old) { linger(id) }
            seenDone = new
        }
    }

    private func habitRow(_ row: CultivationModel.HabitRow) -> some View {
        let quantity = HabitQuantity.target(row.habit, log: row.stats.logs[today]) != nil
        return HStack(spacing: 10) {
            // 今天记了未达标的数量时，点圈弹出数量输入（不把真实数量改写成目标值）；右键“记数量…”。
            // 达标与否、要不要弹数量输入都按模型统计里今天那条判断，打卡圈不再自己读 habit.logs
            HabitCheckIn(habit: row.habit, stats: row.stats, allHabits: cultivation.habits, config: cultivation.config)
            if quantity {
                // 数量型：放得下就“名字 … 连续 N 天 3/8 杯 +1”；窄了先省掉“连续”，名字不被挤成“…”
                ViewThatFits(in: .horizontal) {
                    rowLine(row, streak: true, quantity: true)
                    rowLine(row, streak: false, quantity: true)
                }
            } else {
                rowLine(row, streak: true, quantity: false)
            }
        }
    }

    private func rowLine(_ row: CultivationModel.HabitRow, streak showStreak: Bool, quantity: Bool) -> some View {
        let streak = row.stats.streak
        return HStack(spacing: 10) {
            Image(systemName: row.habit.symbol).foregroundStyle(Theme.inkSoft).frame(width: 18)
            Text(row.habit.title).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 8)
            if showStreak && streak.count > 0 {
                Text("连续 \(streak.count) \(streak.unit)").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                    .lineLimit(1).fixedSize()
            }
            if quantity {
                HabitPlusStep(habit: row.habit, stats: row.stats, allHabits: cultivation.habits, config: cultivation.config)
            }
        }
    }

    /// 刚圆满的一项：先留在原处，约 1.2 秒后再收进“已圆满”
    private func linger(_ id: PersistentIdentifier) {
        let mark = UUID()
        lingering[id] = mark
        let animated = motion
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(DashboardHabitFold.lingerSeconds))
            guard lingering[id] == mark else { return }
            withAnimation(animated ? Motion.standard : nil) { lingering[id] = nil }
        }
    }
}

/// 今日功课卡的收起规则（界面与自检共用）：要做的超过 6 项、且圆满了至少一项时，已圆满的收进一行；
/// 但刚圆满的照常列出——seen 是上一次看到的已圆满的几项（nil = 卡片刚出现，这时已圆满的都不算刚圆满），
/// done 比 seen 多出来的、和还在“留一会儿”的（lingering）都留在原处。
/// 多出来的那几项在同一次重算里就留下（不等 onChange 把它们记进 lingering），不会先收进去一帧再冒出来、把打卡迸发打断。
enum DashboardHabitFold {
    /// 刚圆满的一项留在原处多久
    static let lingerSeconds = 1.2

    static func split<Row: Identifiable>(_ due: [Row], done: Set<Row.ID>, seen: Set<Row.ID>?, lingering: Set<Row.ID>) -> (listed: [Row], folded: [Row]) {
        guard DashboardRules.foldsDone(due: due.count, done: done.count) else { return (due, []) }
        let fresh = seen.map { done.subtracting($0) } ?? []
        let stays = { (id: Row.ID) in !done.contains(id) || fresh.contains(id) || lingering.contains(id) }
        return (due.filter { stays($0.id) }, due.filter { !stays($0.id) })
    }
}

/// “已圆满 N 项”的展开开关（与今日行程“已过 N 项”同一种写法）：动效开关只在这颗小按钮里读
private struct DoneFoldToggle: View {
    var count: Int
    @Binding var open: Bool
    @Environment(\.spiritMotion) private var motion

    var body: some View {
        Button {
            withAnimation(motion ? Motion.standard : nil) { open.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.positive.opacity(0.8))
                Text("已圆满 \(count) 项").monospacedDigit()
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: TypeSize.micro, weight: .semibold))
            }
            .font(.ysCaption)
            .foregroundStyle(Theme.inkSoft)
            .padding(.vertical, 2)
            // 图标与上面各行的打卡圈居中对齐（圈宽 26）
            .padding(.leading, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "收起今天已圆满的功课" : "展开今天已圆满的功课")
    }
}

// MARK: - 今日已落

/// 今日洞府“今日已落”：只取今天的修行录（#Predicate 交给数据库，约 1 毫秒），不再为了这几篇把全部修行录挂在 @Query 上。
/// 今天写过的才列出来（最多 3 篇），那行后面接“ · 本月落笔 9 日”；今天还没写、本月写过时只在卡底写一行“本月已落笔 9 日”
/// （说明字号、金灰色；不说“你已经 N 天没写”这类话）；本月一日都没写时什么都不显示。
/// 本月的篇目同样按 dateKey 谓词只取这个月（每月至多几十篇）。只依赖日期：父视图刷新时不重取。
private struct DashboardTodayEntries: View, Equatable {
    let dayKey: String
    /// 与原来一样按创建时间从新到旧
    @Query private var todays: [JournalEntry]
    /// 本月一日到今天的篇目（只数落笔的日子）
    @Query private var month: [JournalEntry]

    init(dayKey: String) {
        self.dayKey = dayKey
        _todays = Query(filter: #Predicate<JournalEntry> { $0.dateKey == dayKey }, sort: \JournalEntry.createdAt, order: .reverse)
        let first = LocalDay(key: dayKey)?.firstOfMonth.key ?? dayKey
        _month = Query(filter: #Predicate<JournalEntry> { $0.dateKey >= first && $0.dateKey <= dayKey })
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.dayKey == rhs.dayKey }

    var body: some View {
        let monthDays = LocalDay(key: dayKey).map { Onboarding.monthDays(month.map(\.dateKey), today: $0) } ?? 0
        if !todays.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(Theme.line).frame(height: 1)
                Text(Onboarding.todayLine(todayCount: todays.count, monthDays: monthDays))
                    .font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                    .padding(.top, 2)
                    .help("本月落笔：这个月写过修行录的日子（同一天几篇算一日）")
                ForEach(todays.prefix(3)) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.kindValue.symbol).font(.ysCaption).foregroundStyle(entry.kindValue.color).frame(width: 16)
                        Text(entry.displayTitle).font(.ysCallout).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        if entry.isFromCourier {
                            Image(systemName: "paperplane").font(.ysCaption).foregroundStyle(Theme.info)
                                .help("传书 · \(entry.sourceNote)")
                                .accessibilityLabel("传书 · \(entry.sourceNote)")
                        }
                        if let minute = entry.minute {
                            Text(ClockTime.text(minute)).font(.ysCaption.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if todays.count > 3 {
                    Hint("另有 \(todays.count - 3) 篇，翻开修行录可见全部")
                }
            }
            // 与落笔框隔开 14（原来是外层栈的间距）
            .padding(.top, 14)
        } else if let line = Onboarding.monthOnlyLine(todayCount: 0, monthDays: monthDays) {
            Text(line)
                .font(.ysCaption).monospacedDigit()
                .foregroundStyle(Theme.gold.opacity(0.8))
                .help("这个月写过修行录的日子（同一天几篇算一日）；今天写一句就接上")
                .padding(.top, 12)
        }
    }
}

// MARK: - 今日行程（含之后三天）

/// 今日行程卡的正文：今天的日程与作息、之后三天的日程。
/// 日程只取“可能落在今天到之后三天”的那些（重复的、有单次改期的、原日期在这几天的单次日程，见 Occurrences.candidates），
/// 今天与之后三天合成一次展开再按日期分开（与分两次展开结果相同）。只依赖日期：父视图刷新时不重取。
private struct DashboardSchedule: View, Equatable {
    let today: LocalDay
    @Query private var events: [ScheduleEvent]
    @Query private var routine: [RoutineBlock]
    /// 今日行程里已经过去的几项是否展开
    @State private var showPast = false
    /// 今天与之后三天都空时，行尾“新增日程”就地打开新建弹窗
    @State private var creatingEvent = false

    init(today: LocalDay) {
        self.today = today
        _events = Query(filter: Occurrences.candidates(from: today, to: today.adding(days: 3)))
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.today == rhs.today }

    private struct TimelineEntry: Identifiable {
        var id: String
        var start: Int?
        var end: Int?
        var title: String
        /// 日程：类别 · 地点；作息：只在跨夜时写“至次日 07:30 / 昨晚延续”（类别已由图标和颜色表达）
        var detail: String
        var color: Color
        var symbol: String
        var isRoutine: Bool
    }

    var body: some View {
        let items = Occurrences.list(events: events, from: today, to: today.adding(days: 3))
        let entries = timeline(items.filter { $0.day == today })
        let upcoming = items.filter { $0.day > today }
        VStack(alignment: .leading, spacing: 12) {
            if entries.isEmpty && upcoming.isEmpty {
                // 今天与之后三天都空：只说一次，行尾就地新增日程（不再“今天没有…”“之后三天没有…”连说两遍）
                EmptyHint(.nothingAhead) {
                    Button { creatingEvent = true } label: { Label("新增日程", systemImage: "plus") }
                        .buttonStyle(.inlineAction(Theme.gold))
                        .help("就地新增一个日程；固定作息在侧栏的“起居有常”里设")
                }
            } else {
                if entries.isEmpty {
                    EmptyHint(.todayFree)
                } else {
                    // 每分钟刷新一次“进行中 / 下一项 / 已过”，窗口一直开着也不会停在上次渲染的时刻
                    TimelineView(.everyMinute) { clock in
                        timelineRows(entries, now: ClockTime.minutes(of: clock.date))
                    }
                }
                upcomingSection(upcoming)
            }
        }
        .sheet(isPresented: $creatingEvent) { EventEditor(event: nil, defaultDay: today, defaultStart: 9 * 60) }
    }

    private func timeline(_ todays: [OccurrenceItem]) -> [TimelineEntry] {
        var entries: [TimelineEntry] = todays.map { item in
            TimelineEntry(id: "e" + item.id, start: item.startMinute, end: item.endMinute, title: item.title,
                          detail: [item.category, item.location].filter { !$0.isEmpty }.joined(separator: " · "),
                          color: Theme.color(for: item.category), symbol: "calendar", isRoutine: false)
        }
        for segment in RoutineBlock.segments(routine, weekday: today.weekdayIndex) {
            let block = segment.block
            let kind = RoutineKind.of(block.kind)
            let detail = segment.carried ? "昨晚延续" : block.crossesMidnight ? "至次日 \(ClockTime.text(block.endMinute))" : ""
            entries.append(TimelineEntry(id: (segment.carried ? "c" : "r") + "\(block.persistentModelID.hashValue)",
                                         start: segment.start, end: segment.end, title: block.title, detail: detail,
                                         color: Theme.color(for: kind), symbol: kind.symbol, isRoutine: true))
        }
        return entries.sorted { ($0.start ?? -1, $0.isRoutine ? 1 : 0) < ($1.start ?? -1, $1.isRoutine ? 1 : 0) }
    }

    private func timelineRows(_ entries: [TimelineEntry], now: Int) -> some View {
        let nextID = entries.first { ($0.start ?? -1) > now && !$0.isRoutine }?.id
        /// 已经过去：结束（没有结束时间的按开始后 1 分钟）不晚于现在
        func isPast(_ entry: TimelineEntry) -> Bool {
            guard let start = entry.start else { return false }
            return (entry.end ?? start + 1) <= now
        }
        let pastCount = entries.filter(isPast).count
        return VStack(alignment: .leading, spacing: 6) {
            // 已过的收成一行，点开再看
            if pastCount > 0 { PastToggle(count: pastCount, showPast: $showPast) }
            ForEach(entries) { entry in
                let past = isPast(entry)
                if !past || showPast {
                    let running = !past && entry.start.map { $0 <= now } == true
                    timelineRow(entry, running: running, isNext: entry.id == nextID)
                        .opacity(past ? 0.45 : 1)
                }
            }
        }
    }

    private func timelineRow(_ entry: TimelineEntry, running: Bool, isNext: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(ClockTime.range(entry.start, entry.isRoutine && entry.end == 24 * 60 ? nil : entry.end))
                .font(.ysCallout.monospacedDigit())
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 96, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(entry.color.opacity(entry.isRoutine ? 0.45 : 1)).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: entry.symbol).font(.ysCaption).foregroundStyle(entry.color)
                    // 作息浅色单行；真正的日程深色、两行（类别 · 地点）
                    Text(entry.title)
                        .font(entry.isRoutine ? .ysCallout : .ysBody)
                        .foregroundStyle(entry.isRoutine ? Theme.inkSoft : Theme.ink)
                        .lineLimit(1)
                    if entry.isRoutine && !entry.detail.isEmpty {
                        Text(entry.detail).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft.opacity(0.8)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if running {
                        Text("进行中").font(.ysCaption).foregroundStyle(Theme.positive)
                    } else if isNext {
                        Text("下一项").font(.ysCaption).foregroundStyle(Theme.precious)
                    }
                }
                if !entry.isRoutine && !entry.detail.isEmpty {
                    Text(entry.detail).font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        // 正在进行的那一项铺一块淡淡的类别色底（底色向两侧多铺 8pt，文字仍与标题对齐）
        .background(running ? entry.color.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .padding(.horizontal, -8)
        // 行高只随内容：卡片被拉高（两栏等高）时，左侧色条不跟着拉长
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    /// 之后三天：今日行程卡底部的小节
    private func upcomingSection(_ items: [OccurrenceItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "之后三天").padding(.top, 6)
            if items.isEmpty { Hint("之后三天没有日程。") }
            ForEach(items.prefix(8)) { item in
                HStack(spacing: 8) {
                    Text("\(item.day.weekdayName) \(ClockTime.range(item.startMinute, item.endMinute))")
                        .font(.ysCaption.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                        .frame(width: 112, alignment: .leading)
                    Circle().fill(Theme.color(for: item.category)).frame(width: 6, height: 6)
                    Text(item.title).font(.ysCallout).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// “已过 N 项”的展开开关：动效开关只在这颗小按钮里读（展开收起要不要动画），
/// 整张行程卡、整页都不必因为窗口前后台切换而重算。
private struct PastToggle: View {
    var count: Int
    @Binding var showPast: Bool
    @Environment(\.spiritMotion) private var motion

    var body: some View {
        Button {
            withAnimation(motion ? Motion.standard : nil) { showPast.toggle() }
        } label: {
            HStack(spacing: 5) {
                Text("已过 \(count) 项").monospacedDigit()
                Image(systemName: showPast ? "chevron.down" : "chevron.right").font(.system(size: TypeSize.micro, weight: .semibold))
            }
            .font(.ysCaption)
            .foregroundStyle(Theme.inkSoft)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showPast ? "收起已经过去的行程" : "展开已经过去的行程")
    }
}

/// 今日洞府的一张卡放哪一栏；top 是两栏上面的通栏（七日小卷纸笺）
enum OverviewColumn: Equatable {
    case left, right, top
}

/// 今日洞府的一张卡：放哪一栏，窄窗口上下排时排第几（数小的在上；可写小数，插在两张之间）
struct OverviewSlot: Equatable {
    var column: OverviewColumn
    var stacked: Double
}

private struct OverviewSlotKey: LayoutValueKey {
    static let defaultValue = OverviewSlot(column: .left, stacked: 0)
}

extension View {
    /// 今日洞府的卡片放哪一栏、窄窗口上下排时排第几（见 OverviewColumns）。挂在卡片最外层（在 .equatable() 之外）；
    /// 有时整张不出的卡（如旧笔新读）照样挂在外面：里面什么都不出时这一格没有子视图，两栏都不为它留卡距
    func overviewSlot(_ column: OverviewColumn, stacked: Double) -> some View {
        layoutValue(key: OverviewSlotKey.self, value: OverviewSlot(column: column, stacked: stacked))
    }
}

/// 今日洞府的两栏：每张卡用 `.overviewSlot(.left / .right, stacked:)` 说明放哪一栏，同一栏里按书写的先后从上往下排。
/// 左栏约 60%，右栏约 40%（不窄于侧栏宽度 320、不宽于 460）；两栏顶端对齐。
/// 不再强行等高（视觉审计 H1：2 年数据时右栏很长，左栏最后一张被拉出约 900pt 的空白卡）：
/// 较矮那一栏的最后一张最多多拉 160pt（卡片自己要 `.frame(maxHeight: .infinity)` 才会拉长），再多的就留白，两栏底边不必齐。
/// 正文区太窄（约 1100 宽以下的窗口；最小窗口 1120 仍是两栏）时改成上下排，次序按 stacked：
/// 落笔、筑基三关（新手）、所向、今日功课、今日行程、旧笔新读、修为（今天要做的在前）。
/// `.top` 的几格（七日小卷纸笺）排在两栏上面、占满整宽；上下排时按 stacked（-1）排最前。
/// 量出来高度为 0 的（整张不出的卡）不占位、不留卡距。
struct OverviewColumns: Layout {
    var spacing: CGFloat = PageLayout.gutter
    /// 正文区窄于这个宽度就上下排
    var stackBelow: CGFloat = 720

    private func columnWidths(_ total: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let right = min(460, max(PageLayout.side, (total - spacing) * 0.4))
        return (max(0, total - spacing - right), right)
    }

    private func height(_ view: LayoutSubview, width: CGFloat) -> CGFloat {
        view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
    }

    /// 一栏（或上下排时的全部）：要放的卡（下标）与各自的自然高度；高度为 0 的不出
    private func cards(_ subviews: Subviews, column: OverviewColumn?, width: CGFloat) -> [(index: Int, height: CGFloat)] {
        var picked = subviews.indices.filter { column == nil || subviews[$0][OverviewSlotKey.self].column == column }
        if column == nil {
            // 上下排：按 stacked，一样时按书写先后
            picked.sort { (subviews[$0][OverviewSlotKey.self].stacked, $0) < (subviews[$1][OverviewSlotKey.self].stacked, $1) }
        }
        return picked.map { ($0, height(subviews[$0], width: width)) }.filter { $0.height > 0 }
    }

    private func stackHeight(_ cards: [(index: Int, height: CGFloat)]) -> CGFloat {
        cards.isEmpty ? 0 : cards.reduce(0) { $0 + $1.height } + spacing * CGFloat(cards.count - 1)
    }

    /// 通栏几格连同与两栏之间的卡距；一格都不出时 0
    private func topHeight(_ cards: [(index: Int, height: CGFloat)]) -> CGFloat {
        cards.isEmpty ? 0 : stackHeight(cards) + spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let total = proposal.width ?? 1000
        if total < stackBelow {
            return CGSize(width: total, height: stackHeight(cards(subviews, column: nil, width: total)))
        }
        let (left, right) = columnWidths(total)
        let leftHeight = stackHeight(cards(subviews, column: .left, width: left))
        let rightHeight = stackHeight(cards(subviews, column: .right, width: right))
        return CGSize(width: total, height: topHeight(cards(subviews, column: .top, width: total)) + max(leftHeight, rightHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let total = bounds.width
        var placed = Set<Int>()
        defer {
            // 不出的卡（高度 0）也放一次（左上角、0 大小）：不放的话 SwiftUI 会把它摆到正中
            for index in subviews.indices where !placed.contains(index) {
                subviews[index].place(at: bounds.origin, proposal: ProposedViewSize(width: 0, height: 0))
            }
        }
        if total < stackBelow {
            var y = bounds.minY
            for card in cards(subviews, column: nil, width: total) {
                subviews[card.index].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: total, height: card.height))
                placed.insert(card.index)
                y += card.height + spacing
            }
            return
        }
        // 通栏几格先排在最上面，两栏从它们下面起
        let tops = cards(subviews, column: .top, width: total)
        var topY = bounds.minY
        for card in tops {
            subviews[card.index].place(at: CGPoint(x: bounds.minX, y: topY), proposal: ProposedViewSize(width: total, height: card.height))
            placed.insert(card.index)
            topY += card.height + spacing
        }
        let (left, right) = columnWidths(total)
        let columns = [(cards(subviews, column: .left, width: left), bounds.minX, left),
                       (cards(subviews, column: .right, width: right), bounds.minX + left + spacing, right)]
        let heights = columns.map { stackHeight($0.0) }
        for (number, (stack, x, width)) in columns.enumerated() {
            // 较矮那一栏的最后一张多拉一点（最多 160），与另一栏底边差得不多时正好齐平
            let extra = CGFloat(DashboardRules.stretch(column: Double(heights[number]), other: Double(heights[1 - number])))
            var y = bounds.minY + topHeight(tops)
            for (position, card) in stack.enumerated() {
                let h = card.height + (position == stack.count - 1 ? extra : 0)
                subviews[card.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: h))
                placed.insert(card.index)
                y += h + spacing
            }
        }
    }
}
