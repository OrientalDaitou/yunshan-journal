import SwiftUI
import SwiftData

// 首页回看入口（#14）：今日洞府上三处轻轻提一句“回头看看”，都不另占一张大卡：
// - 七日小卷纸笺：周日 18:00 到周一 12:00、那一周有记录时，正文最上面一条通栏纸笺（约 44 高），点开就是七日小卷；× 掉本周不再出；
// - 出关：最近一条记录（落笔或打卡）在 3 天以前、今天还没有记录时，落笔框下面一行金灰小字“闭关 5 日，今日出关——从一句开始。”
//   （不放卡顶：会把“落笔”标题推下一行，与右栏“今日功课”标题错开）；
// - 今日小结：20:00 起落笔卡底一行“今日：功课 3/5 · 已落 1 篇 · 心境未记”。
// 出不出、写什么都是 Core/WeeklyDigest.swift 里 DashboardCues 的纯函数（CoreCheck 覆盖）；这里只管取数和画。
// 取数都按 dateKey 谓词或借修为模型（CultivationModel）已算好的功课统计，5 年数据也不整表取。
// 时刻一律取 SkyTime.fixedMinute ?? 现在（离屏按 APT_RENDER_CLOCK）；离屏另认 APT_RENDER_HOOKS_DAY=<yyyy-MM-dd> 把“今天”定在那天（只管这三处，截周日晚的纸笺用）。

// MARK: - 时刻

enum DashboardHookClock {
    /// 离屏截图时这三处当作“今天”的那天（APT_RENDER_HOOKS_DAY）；平时 nil
    static let renderDay: LocalDay? = RenderMode.offscreen
        ? ProcessInfo.processInfo.environment["APT_RENDER_HOOKS_DAY"].flatMap { LocalDay(key: $0) } : nil
}

/// 每分钟给一次“今天”和“现在第几分钟”；离屏时定格（APT_RENDER_CLOCK、APT_RENDER_HOOKS_DAY）。只有这几行跟着重算，首页 body 不动
private struct HookClock<Content: View>: View {
    @ViewBuilder var content: (LocalDay, Int) -> Content

    var body: some View {
        if let fixed = SkyTime.fixedMinute {
            content(DashboardHookClock.renderDay ?? .today(), Int(fixed))
        } else {
            TimelineView(.everyMinute) { context in
                content(LocalDay(date: context.date), ClockTime.minutes(of: context.date))
            }
        }
    }
}

// MARK: - 取数（界面的 @Query 与自检共用）

enum DashboardHookData {
    /// 不晚于这一天的最近一篇修行录（按日期倒序只取 1 条）
    static func lastEntry(through day: LocalDay) -> FetchDescriptor<JournalEntry> {
        let key = day.key
        var descriptor = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.dateKey <= key }, sortBy: [SortDescriptor(\.dateKey, order: .reverse)])
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// 不晚于这一天的最近一次打卡（按日期倒序只取 1 条）
    static func lastLog(through day: LocalDay) -> FetchDescriptor<HabitLog> {
        let key = day.key
        var descriptor = FetchDescriptor<HabitLog>(predicate: #Predicate { $0.dateKey <= key }, sortBy: [SortDescriptor(\.dateKey, order: .reverse)])
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// 两样里较晚的那天
    static func lastRecord(entry: String?, log: String?) -> LocalDay? {
        [entry, log].compactMap { $0.flatMap { LocalDay(key: $0) } }.max()
    }

    /// 纸笺那一周的修行录（周一到这一周已过的最后一天）
    static func weekEntries(_ week: WeeklyDigest.Week) -> Predicate<JournalEntry> {
        let from = week.monday.key, to = week.last.key
        return #Predicate<JournalEntry> { $0.dateKey >= from && $0.dateKey <= to }
    }
}

// MARK: - 七日小卷纸笺

/// 正文最上面的通栏纸笺（OverviewColumns 的 .top 一格）：不在时段里、× 掉了、那一周没有记录时什么都不出（高度 0，不占卡距）
/// 点 × 收起时与首页其余卡片收起同一套动画（纸笺淡出上收、下面的卡片跟着上移）；动效关着时瞬间收起。
/// 周日 18:00 到点自己出现、周一 12:00 到点自己收起时也走这一套（见 WeeklyStripSlot），页面不再一下子跳动；
/// 周日晚写下或打下本周第一条记录（纸笺由数据触发出现）时也走这一套（见 WeeklyStripPaper.shown）
struct DashboardWeeklyStrip: View {
    @AppStorage(DashboardCues.stripDismissedKey) private var dismissed = ""

    var body: some View {
        HookClock { today, minute in
            WeeklyStripSlot(target: DashboardCues.stripWeek(today: today, minute: minute), dismissed: $dismissed)
        }
    }

    /// 时刻走到下一分钟、该出的那一周变了时要不要放过渡：纸笺出现或收起（周日 18:00、周一 12:00）才放，
    /// 同一周跨午夜（周日 → 周一上午，“这一周”改称“上一周”）只换字不放；动效关着时一律瞬间（自检逐分钟走一遍）
    static func animatesChange(from old: WeeklyDigest.Week?, to new: WeeklyDigest.Week?, motion: Bool) -> Bool {
        motion && old?.monday != new?.monday
    }

    /// 同一周里“有没有可说的一句”变了（周日晚写下或打下本周第一条记录、删光本周记录）要不要放过渡：
    /// shown 是纸笺上一次画没画（nil = 刚出现，还没记过，直接按当时的画、不放）；有了变化才放，动效关着时一律瞬间（自检核对）
    static func paperAnimates(from shown: Bool?, to has: Bool, motion: Bool) -> Bool {
        motion && shown != nil && shown != has
    }
}

/// 纸笺那一格：时刻给的“该出哪一周”先记在 @State 里，变了再用动画改过去——这样时刻一到，纸笺淡入下移、下面的卡片跟着让开
/// （TimelineView 换分钟时自己不带动画）。第一次出现时直接按当时的那一周画（打开首页、离屏截图都不先空一帧）。
/// 外面套一层竖排：onChange 挂在它上面，纸笺不出时也一直在；不出时它量出来高 0，通栏一格照旧不占位、不留卡距
struct WeeklyStripSlot: View {
    let target: WeeklyDigest.Week?
    @Binding var dismissed: String
    @Environment(\.spiritMotion) private var motion
    @State private var week: WeeklyDigest.Week?

    init(target: WeeklyDigest.Week?, dismissed: Binding<String>) {
        self.target = target
        _dismissed = dismissed
        _week = State(initialValue: target)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let week, dismissed != week.monday.key {
                WeeklyStripPaper(week: week) {
                    withAnimation(motion ? Motion.standard : nil) { dismissed = week.monday.key }
                }
                .equatable()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: target) { old, new in
            withAnimation(DashboardWeeklyStrip.animatesChange(from: old, to: new, motion: motion) ? Motion.standard : nil) { week = new }
        }
    }
}

/// 纸笺本身：只取那一周的修行录（dateKey 谓词，至多几十篇）；功课完成率借修为模型的统计（与小卷“其三 · 功课”同一口径）
private struct WeeklyStripPaper: View, Equatable {
    let week: WeeklyDigest.Week
    var onDismiss: () -> Void
    @Query private var entries: [JournalEntry]
    @Environment(CultivationModel.self) private var cultivation
    @Environment(\.spiritMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false
    /// 纸笺出现时一道淡金光从左掠到右（动效关着时不掠）
    @State private var sheen: CGFloat = -0.4
    /// 这一周有没有可说的一句，先记在 @State 里、变了再用动画改过去：周日晚写下或打下本周第一条记录时，
    /// 纸笺淡入下移、下面的卡片跟着让开，不再一下子把落笔框顶走。nil = 刚出现，直接按当时的画（打开首页、离屏截图都不先空一帧）
    @State private var shown: Bool?
    /// 最近一次可说的那句：删光本周记录、纸笺淡出时还照着它画完
    @State private var lastLine = ""

    init(week: WeeklyDigest.Week, onDismiss: @escaping () -> Void) {
        self.week = week
        self.onDismiss = onDismiss
        _entries = Query(filter: DashboardHookData.weekEntries(week))
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.week == rhs.week }

    private var animate: Bool { motion && !reduceMotion && !RenderMode.offscreen }

    var body: some View {
        let rows = cultivation.rows.filter { $0.habit.modelContext != nil }
        let habits = WeeklyDigest.habits(rows.map { ($0.habit.title, $0.stats) }, week: week)
        let line = DashboardCues.stripLine(week: week, entries: entries.count, habits: habits)
        // 外面套一层竖排：onChange 挂在它上面，纸笺不出时也一直在；不出时量出来高 0，通栏一格照旧不占位、不留卡距
        VStack(spacing: 0) {
            if shown ?? (line != nil) {
                paper(line ?? lastLine)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: line, initial: true) { _, new in
            if let new { lastLine = new }
            let has = new != nil
            guard shown != has else { return }
            withAnimation(DashboardWeeklyStrip.paperAnimates(from: shown, to: has, motion: motion) ? Motion.standard : nil) { shown = has }
        }
    }

    private func paper(_ line: String) -> some View {
        HStack(spacing: 12) {
            SceneryImage(name: "yunshan-ornament-scroll-v1")
                .frame(width: 30, height: 30)
                .background(SoftGlow(color: Theme.gold.opacity(0.22)).frame(width: 64, height: 52))
                .accessibilityHidden(true)
            Text(line)
                .font(Theme.songti(TypeSize.callout, .medium))
                .tracking(0.5)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            Button("翻看七日小卷") { AppRouter.shared.weeklyScroll = true }
                .buttonStyle(.cardLink)
                .help("打开七日小卷：自己的话、心境七日、功课、灵石与上次许下的下一步")
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.inkSoft.opacity(hover ? 0.9 : 0.55))
            .help("这一周不再提示（修行录“卷中气象”里随时翻得到七日小卷）")
            .accessibilityLabel("这一周不再提示")
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(minHeight: 44)
        .background {
            RoundedRectangle(cornerRadius: Radius.inner + 2, style: .continuous)
                .fill(Theme.card.opacity(scheme == .dark ? 0.82 : 0.92))
                .overlay {
                    LinearGradient(colors: [Theme.goldSoft.opacity(scheme == .dark ? 0.32 : 0.75), Theme.goldSoft.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.inner + 2, style: .continuous))
                }
                .overlay {
                    // 掠过的一道淡金光：只在出现时走一次
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Theme.gold.opacity(scheme == .dark ? 0.22 : 0.28), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.28)
                            .offset(x: geo.size.width * sheen)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.inner + 2, style: .continuous))
                    .opacity(animate ? 1 : 0)
                    .allowsHitTesting(false)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.inner + 2, style: .continuous)
                .strokeBorder(Theme.gold.opacity(hover ? 0.6 : 0.34), lineWidth: 0.75)
        }
        // 左缘一道金线，像卷轴的轴头
        .overlay(alignment: .leading) {
            Capsule().fill(LinearGradient(colors: [Theme.gold.opacity(0.9), Theme.gold.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                .frame(width: 2).padding(.vertical, 9)
        }
        .shadow(color: Theme.gold.opacity(hover ? 0.16 : 0), radius: 10, y: 2)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(motion ? Motion.hover : nil) { hover = inside } }
        .onAppear {
            guard animate else { return }
            withAnimation(.easeInOut(duration: 1.8).delay(0.5)) { sheen = 1.15 }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 出关

/// 落笔框下面一行：最近一条记录（落笔或打卡，不晚于今天）在 3 天以前、今天还没有记录时出现；今天一有记录就消失，从没记录过的不出。
/// 两样各按日期倒序只取 1 条（谓词交给数据库），5 年数据也只取 2 条
struct DashboardReturnLine: View {
    var body: some View {
        HookClock { today, _ in ReturnLineBody(today: today).equatable() }
    }
}

private struct ReturnLineBody: View, Equatable {
    let today: LocalDay
    @Query private var lastEntry: [JournalEntry]
    @Query private var lastLog: [HabitLog]
    @Environment(\.spiritMotion) private var motion
    @State private var shown = false

    init(today: LocalDay) {
        self.today = today
        _lastEntry = Query(DashboardHookData.lastEntry(through: today))
        _lastLog = Query(DashboardHookData.lastLog(through: today))
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.today == rhs.today }

    var body: some View {
        let last = DashboardHookData.lastRecord(entry: lastEntry.first?.dateKey, log: lastLog.first?.dateKey)
        if let days = DashboardCues.retreat(lastRecord: last, today: today) {
            let hidden = !shown && motion && !RenderMode.offscreen
            HStack(spacing: 6) {
                Image(systemName: "door.left.hand.open").font(.system(size: 11, weight: .medium))
                Text(DashboardCues.retreatLine(days)).monospacedDigit()
            }
            .font(.ysCaption)
            .foregroundStyle(Theme.gold.opacity(0.85))
            .padding(.top, 12)
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden ? 4 : 0)
            .help("最近一条记录在 \(last.map { $0.label(relativeTo: today) } ?? "")；今天写一句、打一次卡，这行就收起")
            .onAppear {
                guard !shown else { return }
                guard motion, !RenderMode.offscreen else { shown = true; return }
                withAnimation(.easeOut(duration: 0.6).delay(0.35)) { shown = true }
            }
        }
    }
}

// MARK: - 今日小结

/// 落笔卡底（今日已落之后）一行：20:00 起出现，到午夜换了一天就收起
struct DashboardTonightLine: View {
    var body: some View {
        HookClock { today, minute in
            if DashboardCues.showsTonight(minute: minute) {
                TonightLineBody(dayKey: today.key).equatable()
            }
        }
    }
}

/// 只取今天的修行录（与“今日已落”同一个谓词）；功课按修为模型的统计数今天要做的与已圆满的（与今日功课卡标题的 3/5 同一口径）
private struct TonightLineBody: View, Equatable {
    let dayKey: String
    @Query private var todays: [JournalEntry]
    @Environment(CultivationModel.self) private var cultivation

    init(dayKey: String) {
        self.dayKey = dayKey
        _todays = Query(filter: #Predicate<JournalEntry> { $0.dateKey == dayKey })
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.dayKey == rhs.dayKey }

    var body: some View {
        let today = LocalDay(key: dayKey) ?? .today()
        let rows = cultivation.rows.filter { $0.habit.modelContext != nil }
        let due = rows.filter { $0.stats.isDueToday || $0.stats.logs[today] != nil }
        let done = due.filter { $0.stats.isAchieved(today) }.count
        if let line = DashboardCues.tonightLine(habitsDone: done, habitsDue: due.count, entries: todays.count, moods: todays.compactMap(\.mood)) {
            HStack(spacing: 7) {
                Image(systemName: "moon.stars").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.gold)
                Text(line).monospacedDigit().foregroundStyle(Theme.inkSoft)
            }
            .font(.ysCaption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(Theme.goldSoft.opacity(0.4))
                    .overlay { Capsule().strokeBorder(Theme.gold.opacity(0.22), lineWidth: 0.75) }
            }
            .padding(.top, 12)
            .help("今日小结：20:00 起出现。功课按今天要做的数，落笔数今天写的篇数")
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - 首页接七日小卷

/// 首页也接 AppRouter.weeklyScroll（纸笺上的“翻看七日小卷”就走这条路）：首页在当前页、也没有别的页在等着切过去时，由首页打开并清零。
/// 晚一拍再看：同一刻要切到修行录（router.page 不空，或已经切走、首页消失了）就留给修行录接，不抢
struct DashboardWeeklyReceiver: ViewModifier {
    @State private var showWeekly = false
    /// 首页还在不在屏上（晚一拍时读，首页已消失也读得到）
    @State private var presence = Presence()

    final class Presence {
        var onScreen = false
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                presence.onScreen = true
                take()
            }
            .onDisappear { presence.onScreen = false }
            .onChange(of: AppRouter.shared.weeklyScroll) { _, on in if on { take() } }
            .sheet(isPresented: $showWeekly) { WeeklyScrollSheet() }
    }

    private func take() {
        let presence = presence
        DispatchQueue.main.async {
            let router = AppRouter.shared
            guard Self.shouldTake(onScreen: presence.onScreen, flag: router.weeklyScroll, pendingPage: router.page,
                                  target: router.weeklyScrollTarget) else { return }
            router.weeklyScroll = false
            router.weeklyScrollTarget = nil
            showWeekly = true
        }
    }

    /// 首页接不接这次打开：首页在屏上、标志开着、没有要切到别的页（自检直接调）
    static func shouldTake(onScreen: Bool, flag: Bool, pendingPage: AppSection?, target: AppSection? = nil) -> Bool {
        onScreen && flag && (pendingPage == nil || pendingPage == .overview) && (target == nil || target == .overview)
    }
}

extension View {
    /// 今日洞府接七日小卷的打开请求（见 DashboardWeeklyReceiver）
    func dashboardWeeklyReceiver() -> some View { modifier(DashboardWeeklyReceiver()) }
}
