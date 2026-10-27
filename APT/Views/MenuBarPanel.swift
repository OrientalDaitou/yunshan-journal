import SwiftUI
import SwiftData
import AppKit
import Carbon.HIToolbox

/// 菜单栏小窗：点菜单栏的笔形小图标弹出，宽 460，上下两段，中间一条金色渐隐细线。
/// 上半段一眼看今天：“今日 · 申时”与“功课 2/5 · 已落 1 篇”、未圆满的功课（点圈即打卡，数量型带“3/8 杯 +1”）、
/// 下一项日程与倒计时；下半段是原样的随手记（QuickCaptureView）。随手记记完、按 Esc 都收起这扇小窗
/// （记完到自动收起前这一小会儿里点过上半段的打卡圈、+1，或打卡圈弹出的数量输入框还开着，就不自动收起）；
/// “时辰卷 →”“打开洞府 →”这类去别处的，先收起小窗再把主窗口带到前面（关着就重新打开）。
/// 浅 / 深色跟主窗口右上角的外观设置走（同一个偏好键 appearance）。
///
/// 取数只取今天：今日已落按 dateKey 谓词取，日程只取可能落在今天的（Occurrences.candidates，与首页同一套），
/// 功课统计借应用级的修为模型（与首页、侧栏同一份，不另算）。列几项、倒计时与标题行的说法在 Core/MenuBarDigest；
/// 数量型“3/8 杯 +1”的步长与数量写法直接用首页的 DashboardRules（首页、功课页、小窗同一条规则，不另抄）。
/// 小窗有自己的特效中心（MenuBarSupport.effects）：打卡的“+修为”、功课圆满就飘在小窗里——主窗口多半在别的应用后面、
/// 或者关着，飘在那里看不见；动效按设置里的开关与系统“减少动态效果”，不跟主窗口在不在前台走。
struct MenuBarPanel: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var settingsList: [AppSettings]
    /// 全局快捷键没注册上时：底栏不说“按 ⌥⌘J 也能随手记”，改说被占用了、在这里随手记
    @AppStorage(QuickCaptureKeys.hotKeyError) private var hotKeyError = ""
    /// 外观设置（与主窗口、快捷键一览同一个键）：主窗口设成深色，小窗也是深色
    @AppStorage("appearance") private var appearanceRaw = AppearanceMode.system.rawValue
    /// 这扇小窗本身（记完、Esc 时只收起它）
    @State private var handle = MenuBarWindowHandle()

    private var motion: Bool { (settingsList.first?.motionEnabled ?? true) && !reduceMotion }

    var body: some View {
        // 主 context 的那一份修为模型（主窗口开着时就是它正在用的那份；第一次取时完整算一次）
        let cultivation = CultivationModel.shared(for: context)
        VStack(spacing: 0) {
            MenuBarClock { today, minute in
                MenuBarToday(today: today, minute: minute, cultivation: cultivation, motion: motion, open: open,
                             onAct: { [handle] in handle.noteTopAction() })
            }
            // 上半段这一块：在它里面按下鼠标（打卡圈——点了弹出数量输入框也算、右键“记数量…”、+1）就算点过上半段
            .background(MenuBarAreaReader { [handle] in handle.topArea = $0 })
            // 每次打开都是新的一轮：上回打上卡、留在原位的签收进“已圆满”，细线上的金光再掠一次
            .id(handle.session)
            // 打卡的“+修为”、功课圆满、未达标的提示：飘在上半段（不接收点击）
            .overlay { XPToastOverlay().padding(.top, -10) }
            MenuBarDivider(motion: motion).id(handle.session)
            QuickCaptureView(onDone: captureDone, showsHotKeyHint: false)
            footer
        }
        .frame(width: 460)
        .background(Theme.card)
        .background(MenuBarWindowReader { handle.window = $0 })
        .buttonStyle(.yunshan)
        .tint(Theme.jade)
        .environment(MenuBarSupport.effects)
        .environment(\.spiritMotion, motion)
        .onAppear { MenuBarSupport.effects.motionEnabled = motion }
        .onDisappear { handle.endSession() }
        .onChange(of: motion) { _, on in MenuBarSupport.effects.motionEnabled = on }
        // 焦点不在随手记里时（例如刚点了打卡圈）Esc 也收起；写了一半的随手记留在草稿里
        .onExitCommand(perform: dismiss)
        .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.scheme)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(MenuBarSupport.footerHint(hotKeyFailed: !hotKeyError.isEmpty)).font(.ysCaption).foregroundStyle(Theme.inkSoft)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("打开洞府") { open(.overview) }
                .buttonStyle(.cardLink)
                .help("打开主窗口的今日洞府")
        }
        .padding(.horizontal, 18)
        .padding(.top, -6)
        .padding(.bottom, 14)
    }

    /// 收起小窗（Esc、去主窗口）
    private func dismiss() { handle.close() }

    /// 随手记要收起时（记完自动收起、或在随手记里按 Esc）：Esc 照常收起；
    /// 自动收起前这一小会儿里点过上半段（打卡圈、+1），或打卡圈弹出的数量输入框还开着，就不收——
    /// 小窗不会在两次点击之间突然收起，正在填的数量框也不会跟着小窗一起没了
    private func captureDone() {
        handle.captureFinished(escape: MenuBarSupport.isEscape(NSApp.currentEvent, in: handle.window))
    }

    /// 去主窗口的某一页：先收起小窗，再把主窗口带到前面；主窗口从没出现过（还没登记重新打开的办法）时用这里的 openWindow 打开
    private func open(_ page: AppSection) {
        MenuBarSupport.request(page)
        if AppRouter.shared.openMainWindow == nil {
            AppRouter.shared.openMainWindow = { [openWindow] in openWindow(id: "main") }
        }
        dismiss()
        AppRouter.showMainWindow()
    }
}

// MARK: - 上半段：今日

/// 上半段：标题行、功课、下一项。today、minute 由 MenuBarClock 每分钟给一次（离屏截图按 APT_RENDER_CLOCK 定格）
private struct MenuBarToday: View {
    var today: LocalDay
    var minute: Int
    var cultivation: CultivationModel
    var motion: Bool
    var open: (AppSection) -> Void
    /// 点了上半段的打卡圈、+1（记完自动收起前点过就不收起）
    var onAct: () -> Void
    /// 这次打开小窗后列成过签的功课：在小窗里刚打上卡的留在原位（见 MenuBarDigest.HabitItem.keepShown）
    @State private var listed: Set<PersistentIdentifier> = []

    var body: some View {
        // 刚删掉、模型还没来得及重算的习惯不再显示（已删除的对象不能再读）；与首页“今日功课”同一口径
        let rows = cultivation.rows.filter { $0.habit.modelContext != nil }
        let items = MenuBarSupport.items(rows, today: today, keep: listed)
        let plan = MenuBarDigest.plan(items)
        let chipIDs = plan.chips.map { rows[$0].id }
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                SceneryImage(name: "yunshan-ornament-crane-v1").frame(width: 26, height: 26)
                Text(MenuBarDigest.heading(minute: minute)).font(.ysHeading).tracking(1).foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                MenuBarTally(dayKey: today.key, done: plan.done, due: plan.due)
            }
            habits(plan, rows: rows, items: items)
            MenuBarNextItem(today: today, minute: minute) { open(.schedule) }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 13)
        // 打开小窗、或开着时过了午夜：让修为模型看一眼（换到新的一天；没变化时约 1 毫秒）
        .task(id: today.key) { cultivation.refresh() }
        .onChange(of: chipIDs, initial: true) { _, ids in listed.formUnion(ids) }
    }

    @ViewBuilder
    private func habits(_ plan: MenuBarDigest.HabitPlan, rows: [CultivationModel.HabitRow], items: [MenuBarDigest.HabitItem]) -> some View {
        switch plan.state {
        case .noHabits:
            EmptyHint(symbol: "leaf", text: "还没有功课") {
                Button("立一项") { open(.habits) }.buttonStyle(.cardLink).help("打开每日功课，立下第一项")
            }
        case .restDay:
            EmptyHint(.restDay)
        case .allDone:
            consummated(bonus: cultivation.perfectToday)
        case .chips:
            VStack(alignment: .leading, spacing: 7) {
                FlowLayout(spacing: 8) {
                    ForEach(plan.chips.map { MenuBarChipSlot(row: rows[$0], item: items[$0]) }) { slot in
                        MenuBarHabitChip(row: slot.row, item: slot.item, allHabits: cultivation.habits,
                                         config: cultivation.config, motion: motion, onAct: onAct)
                    }
                    if plan.overflow > 0 {
                        Button("另有 \(plan.overflow) 项") { open(.overview) }
                            .buttonStyle(.cardLink)
                            .padding(.vertical, 6)
                            .help("打开今日洞府，看全部功课")
                    }
                }
                // “功课圆满”只写在签的下方（不插在签上方）：刚在小窗里打完最后一项时签还留在原位、不挪，
                // 金字顶替“已圆满：…”那一行；只剩每周 N 次的签、修为里已算圆满时，“已圆满”一行下面添一行金色小字
                let consummation = MenuBarDigest.consummation(allDone: plan.allDone, perfectToday: cultivation.perfectToday)
                if case let .full(bonus) = consummation {
                    consummated(bonus: bonus)
                        .transition(.opacity)
                } else if let line = MenuBarDigest.doneLine(plan.doneTitles) {
                    Text(line).font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(1)
                }
                if consummation == .bonusOnly {
                    bonusLine.transition(.opacity)
                }
            }
            .animation(motion ? Motion.standard : nil, value: plan)
            .animation(motion ? Motion.standard : nil, value: cultivation.perfectToday)
        }
    }

    /// 金字“功课圆满”（修为规则里也算圆满时，另写今日额外所得）
    private func consummated(bonus: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.precious).accessibilityHidden(true)
            Text("功课圆满").font(Theme.songti(TypeSize.body, .semibold)).tracking(1).foregroundStyle(Theme.precious)
            if bonus {
                Text("今日额外 +\(CultivationEngine.perfectDayXP) 修为").font(.ysCaption).foregroundStyle(Theme.precious.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// 只剩每周 N 次的签、修为里已算圆满：一行金色小字，与首页功课卡同一句
    private var bonusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.seal.fill").font(.ysCaption).foregroundStyle(Theme.precious).accessibilityHidden(true)
            Text(MenuBarDigest.bonusLine()).font(.ysCaption).foregroundStyle(Theme.precious).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 一枚签要的两样：功课（含统计）与小窗里的样子
private struct MenuBarChipSlot: Identifiable {
    var row: CultivationModel.HabitRow
    var item: MenuBarDigest.HabitItem
    var id: PersistentIdentifier { row.id }
}

/// 标题行右侧“功课 2/5 · 已落 1 篇”：今日已落只按日期取今天的（#Predicate 交给数据库），不挂全部修行录
private struct MenuBarTally: View {
    var done: Int
    var due: Int
    @Query private var todays: [JournalEntry]

    init(dayKey: String, done: Int, due: Int) {
        self.done = done
        self.due = due
        _todays = Query(MenuBarSupport.todayEntries(dayKey))
    }

    var body: some View {
        Text(MenuBarDigest.summary(done: done, due: due, entries: todays.count))
            .font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft).lineLimit(1).fixedSize()
    }
}

/// 一枚功课签：打卡圈 + 名字；数量型另带“3/8 杯”与“+1”（步长与数量写法直接用首页的 DashboardRules，按钮上写实际步长）。
/// 打卡圈就是首页那个（今天记了未达标的数量时点圈弹出数量输入，不把真实数量改写成目标值）。
/// 签的宽度在这次打开期间不变（后面的签不会在指针底下左右挪）：数量那一格按“目标/目标”留宽，
/// 达标后“+1”那一格换成同宽的玉色 ✓、右侧留白不变
struct MenuBarHabitChip: View {
    var row: CultivationModel.HabitRow
    var item: MenuBarDigest.HabitItem
    var allHabits: [Habit]
    var config: CultivationConfig
    var motion: Bool
    /// 点了打卡圈、+1（小窗据此在记完自动收起前不收起）
    var onAct: () -> Void = {}
    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            HabitCheckIn(habit: row.habit, stats: row.stats, size: 20, allHabits: allHabits, config: config, arrowEdge: .bottom,
                         onToggled: { _ in onAct() })
            Text(item.title).font(.ysCallout).foregroundStyle(Theme.ink).lineLimit(1).frame(maxWidth: 150, alignment: .leading)
            if let target = item.target {
                // 达标后（刚在小窗里记满、签还留在原位）数字转玉色（与首页一致）。
                // 底下垫一份看不见的“目标/目标”：0/8000 记到 1000/8000 时这一格不变宽
                ZStack(alignment: .trailing) {
                    Text(Self.progress(quantity: target, target: target, unit: item.unit)).hidden()
                    Text(Self.progress(quantity: item.quantity, target: target, unit: item.unit))
                        .foregroundStyle(item.achieved ? Theme.positive : Theme.inkSoft)
                }
                .font(.ysCaption.monospacedDigit())
                .lineLimit(1).fixedSize()
                stepSlot(target: target)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, item.target == nil ? 12 : 4)
        .padding(.vertical, 4)
        .background(Theme.paper.opacity(hover ? 0.85 : 0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(hover ? Theme.gold.opacity(0.55) : Theme.line, lineWidth: 1))
        .shadow(color: Theme.gold.opacity(hover && motion ? 0.18 : 0), radius: 6)
        .animation(motion ? Motion.quick : nil, value: hover)
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)
    }

    /// 签上的进度“3/8 杯”（没记过写 0）：与首页功课卡同一个写法（DashboardRules.quantityText）
    static func progress(quantity: Double?, target: Double, unit: String) -> String {
        DashboardRules.quantityText(done: quantity ?? 0, target: target, unit: unit)
    }

    /// “+1”一步：步长、按钮字（“+5”“+1000”）、悬停里说的“再记 5 分钟”——都是首页的 DashboardRules
    static func step(target: Double, unit: String) -> (step: Double, label: String, amount: String) {
        let step = DashboardRules.quantityStep(target: target)
        let unit = unit.trimmingCharacters(in: .whitespaces)
        return (step, DashboardRules.stepLabel(step), DashboardRules.number(step) + (unit.isEmpty ? "" : " \(unit)"))
    }

    /// “+1”那一格：没达标是按钮；达标后按钮隐去（不接点击）、原处一个同宽的玉色 ✓，签不变窄
    private func stepSlot(target: Double) -> some View {
        let (step, label, amount) = Self.step(target: target, unit: item.unit)
        return ZStack {
            Button(label) {
                onAct()
                MenuBarSupport.addStep(row.habit, step: step, context: context, effects: effects, allHabits: allHabits, config: config)
            }
            .buttonStyle(.inlineAction(Theme.gold))
            .help("再记 \(amount)")
            .accessibilityLabel("「\(item.title)」再记 \(amount)")
            .opacity(item.achieved ? 0 : 1)
            .allowsHitTesting(!item.achieved)
            .disabled(item.achieved)
            .accessibilityHidden(item.achieved)
            if item.achieved {
                Image(systemName: "checkmark")
                    .font(.system(size: TypeSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.positive)
                    .transition(.opacity)
                    .accessibilityLabel("今日已达标")
            }
        }
        .animation(motion ? Motion.quick : nil, value: item.achieved)
    }
}

/// 下一项：今天还没开始的第一个日程（与首页“下一项”同一口径，作息不算），倒计时随 MenuBarClock 每分钟刷新；
/// 都开始了写正在进行的那项，只剩全天的写全天，都没有写“今日已无安排”。行尾“时辰卷 →”
private struct MenuBarNextItem: View {
    var today: LocalDay
    var minute: Int
    var onOpen: () -> Void
    @Query private var events: [ScheduleEvent]

    init(today: LocalDay, minute: Int, onOpen: @escaping () -> Void) {
        self.today = today
        self.minute = minute
        self.onOpen = onOpen
        _events = Query(filter: Occurrences.candidates(from: today, to: today))
    }

    var body: some View {
        let line = MenuBarDigest.nextLine(MenuBarSupport.slots(Occurrences.list(events: events, from: today, to: today), today: today),
                                          now: minute)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !line.label.isEmpty {
                Text(line.label).font(.ysCaption).foregroundStyle(line.label == "进行中" ? Theme.positive : Theme.precious).fixedSize()
            } else {
                Image(systemName: "cloud").font(.ysCaption).foregroundStyle(Theme.inkSoft.opacity(0.8)).accessibilityHidden(true)
            }
            Text(line.text).font(.ysCallout.monospacedDigit()).foregroundStyle(line.label.isEmpty ? Theme.inkSoft : Theme.ink)
                .lineLimit(1).truncationMode(.tail)
            if !line.detail.isEmpty {
                Text("· \(line.detail)").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 8)
            Button("时辰卷", action: onOpen).buttonStyle(.cardLink).help("打开主窗口的时辰卷")
        }
        .accessibilityElement(children: .combine)
    }
}

/// 两段之间的金色渐隐细线。动效开着时，小窗出现那一下有一点金光从左掠到右（只一次）；关动效时只是一条静线
private struct MenuBarDivider: View {
    var motion: Bool
    @State private var swept = false

    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: [Theme.gold.opacity(0), Theme.gold.opacity(0.55), Theme.gold.opacity(0)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(height: 1)
            .overlay {
                // 一小段亮金从线的左端外掠到右端外：只在线的范围里看得见（两端之外裁掉），掠完停在右端外
                if motion {
                    GeometryReader { proxy in
                        LinearGradient(colors: [Theme.gold.opacity(0), Theme.gold.opacity(0.95), Theme.gold.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 90, height: 2)
                            .offset(x: swept ? proxy.size.width : -90, y: -0.5)
                    }
                    .clipped()
                    .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 18)
            .accessibilityHidden(true)
            .onAppear {
                guard motion, !RenderMode.offscreen else { return }
                swept = false
                withAnimation(.easeInOut(duration: 1.3).delay(0.15)) { swept = true }
            }
            .onDisappear { swept = false }
    }
}

/// 每分钟给一次“今天”和“现在第几分钟”（时辰、倒计时、跨午夜）；离屏截图按 SkyTime.fixedMinute 定格
private struct MenuBarClock<Content: View>: View {
    @ViewBuilder var content: (LocalDay, Int) -> Content

    var body: some View {
        if let fixed = SkyTime.fixedMinute {
            content(.today(), Int(fixed))
        } else {
            TimelineView(.everyMinute) { context in
                content(LocalDay(date: context.date), ClockTime.minutes(of: context.date))
            }
        }
    }
}

// MARK: - 取数与动作（自检也走这里）

@MainActor
enum MenuBarSupport {
    /// 小窗自己的特效中心：打卡的“+修为”、提示、功课圆满飘在小窗里（主窗口开着时它的特效中心是另一份，互不打扰）
    static let effects = EffectsCenter()

    /// 修为模型里的未归档功课 → 小窗用的样子（今天要做 / 已达标 / 今天的数量与目标），与首页“今日功课”同一口径
    /// keep：这次打开小窗后列成过签的（刚打上卡也留在原位）
    static func items(_ rows: [CultivationModel.HabitRow], today: LocalDay,
                      keep: Set<PersistentIdentifier> = []) -> [MenuBarDigest.HabitItem] {
        rows.map { row in
            let log = row.stats.logs[today]
            return MenuBarDigest.HabitItem(title: row.habit.title, due: row.stats.isDueToday || log != nil,
                                           achieved: row.stats.isAchieved(today), quantity: log?.quantity,
                                           target: HabitQuantity.target(row.habit, log: log), unit: row.habit.unit,
                                           keepShown: keep.contains(row.id))
        }
    }

    /// “+1”：今天已记的数量（点的那一刻按日期从库里取，不用可能还没刷新的统计）加一步，走 HabitActions.setQuantity
    /// （修为、功课圆满照常）。返回记成的数量
    @discardableResult
    static func addStep(_ habit: Habit, step: Double, context: ModelContext, effects: EffectsCenter,
                        allHabits: [Habit], config: CultivationConfig) -> Double {
        let day = LocalDay.today()
        let current = HabitDayLogs(day: day, context: context).log(of: habit)?.quantity ?? 0
        let quantity = current + max(step, 0)
        HabitActions.setQuantity(habit, on: day, quantity: quantity, context: context, effects: effects, allHabits: allHabits, config: config)
        return quantity
    }

    /// 今天的修行录（只按日期取）
    static func todayEntries(_ dayKey: String) -> FetchDescriptor<JournalEntry> {
        FetchDescriptor<JournalEntry>(predicate: #Predicate<JournalEntry> { $0.dateKey == dayKey })
    }

    /// 今天的日程 → 下一项要看的时段（单次改期挪走的、挪到今天的都按展开结果）
    static func slots(_ items: [OccurrenceItem], today: LocalDay) -> [MenuBarDigest.Slot] {
        items.filter { $0.day == today }.map { MenuBarDigest.Slot(start: $0.startMinute, end: $0.endMinute, title: $0.title) }
    }

    /// 请主窗口切到某一页（主窗口在时 RootView 监听后切；关着时重新打开后在 bootstrap 里补上）
    static func request(_ page: AppSection) {
        AppRouter.shared.page = page
    }

    /// 底栏那一句（浅墨小字）：快捷键注册上了说“在别的应用里按 ⌥⌘J，也能随手记”；没注册上（被别的应用占用）说在这里随手记
    static func footerHint(hotKeyFailed: Bool) -> String {
        let key = KeyCommand.quickCapture.display
        return hotKeyFailed ? "\(key) 被别的应用占用，可在这里随手记" : "在别的应用里按 \(key)，也能随手记"
    }

    /// 随手记要收起时，眼下这一下是不是 Esc（或 ⌘.）：是就照常收起；不是（记完后延时自动收起）再看上半段刚点过没有。
    /// 只认小窗这扇窗里的按键（window 为 nil 时不比窗口）
    static func isEscape(_ event: NSEvent?, in window: NSWindow?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        if let window, event.windowNumber != window.windowNumber { return false }
        return event.keyCode == UInt16(kVK_Escape)
            || (event.keyCode == UInt16(kVK_ANSI_Period) && event.modifierFlags.contains(.command))
    }

    /// 这一下鼠标按下算不算“点过上半段”：按在小窗这扇窗里、落在上半段那一块（打卡圈——点了弹出数量输入框也算、
    /// 右键“记数量…”、+1）。按在下半段的随手记里、或别的窗口里都不算
    static func isTopClick(inPanel: Bool, inTopArea: Bool) -> Bool { inPanel && inTopArea }

    /// 小窗上是否挂着弹出的小气泡（打卡圈弹出的数量输入框；SwiftUI 的 popover 是挂在小窗上的子窗口）
    static func hasOpenPopover(_ window: NSWindow?) -> Bool {
        window?.childWindows?.contains { $0.isVisible } ?? false
    }
}

/// 小窗所在的那扇窗（菜单栏小窗是系统给的面板）：随手记记完、Esc 时只收起它，而且只在它还开着时收。
/// 小窗每收起一次算一轮结束（session 加一）：下次打开时上半段重新排（视图 onDisappear，或窗口被收起、整个看不见时）。
/// 还记着这一轮里上半段（打卡圈、+1）最近一次被点的时刻：随手记记完后的自动收起看它决定收不收。
/// 点打卡圈时圈自己只在直接打上 / 取消卡时报一声（onToggled）；点了弹出数量输入框、右键“记数量…”不经过它，
/// 所以另外看鼠标：小窗里在上半段那一块按下就记一笔（本应用自己的事件，不要辅助功能权限）
@MainActor
@Observable
final class MenuBarWindowHandle {
    @ObservationIgnored weak var window: NSWindow? {
        didSet { if window !== oldValue { watch(window) } }
    }
    /// 上半段那一块（MenuBarAreaReader 报上来）：鼠标在它里面按下就算点过上半段
    @ObservationIgnored weak var topArea: NSView?
    @ObservationIgnored private var clickMonitor: Any?
    private(set) var session = 0
    @ObservationIgnored private var hiddenToken: NSObjectProtocol?
    /// 这一轮里是否露过面（没露过面就收起，不算一轮）
    @ObservationIgnored private var shown = false
    /// 这一轮里上半段最近一次被点的时刻（不参与界面刷新）
    @ObservationIgnored private(set) var lastTopAction: Date?

    func close() {
        guard let window, window.isVisible else { return }
        window.close()
    }

    func endSession() {
        lastTopAction = nil
        guard shown else { return }
        shown = false
        session += 1
    }

    /// 点了上半段的打卡圈、+1
    func noteTopAction(at now: Date = Date()) { lastTopAction = now }

    /// 一下鼠标按下：按在小窗上半段那一块里就记成点过上半段（打卡圈弹出数量输入框、右键“记数量…”也走这里）。
    /// 返回记没记
    @discardableResult
    func noteClick(_ event: NSEvent, at now: Date = Date()) -> Bool {
        guard event.type == .leftMouseDown || event.type == .rightMouseDown else { return false }
        let inPanel = window.map { event.windowNumber == $0.windowNumber } ?? false
        var inTop = false
        if inPanel, let area = topArea, area.window === window {
            inTop = area.bounds.contains(area.convert(event.locationInWindow, from: nil))
        }
        guard MenuBarSupport.isTopClick(inPanel: inPanel, inTopArea: inTop) else { return false }
        noteTopAction(at: now)
        return true
    }

    /// 随手记要收起小窗时：Esc 照常收起；记完后的自动收起，若这之前一小会儿里点过上半段、
    /// 或打卡圈弹出的数量输入框此刻还开着（算刚点过），就不收（见 MenuBarDigest.autoCloses）。
    /// popoverOpen 为 nil 时看小窗上此刻挂没挂着小气泡。返回这次收没收
    @discardableResult
    func captureFinished(escape: Bool, popoverOpen: Bool? = nil, now: Date = Date()) -> Bool {
        let open = popoverOpen ?? MenuBarSupport.hasOpenPopover(window)
        let since = open ? 0 : lastTopAction.map { now.timeIntervalSince($0) }
        let closes = MenuBarDigest.autoCloses(escape: escape, sinceTopAction: since)
        if closes { close() }
        return closes
    }

    private func watch(_ window: NSWindow?) {
        if let hiddenToken { NotificationCenter.default.removeObserver(hiddenToken) }
        hiddenToken = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard let window else { return }
        // 只看本应用自己的鼠标按下（本地监视，事件原样放行）；是不是按在小窗上半段由 noteClick 判断
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.noteClick(event) }
            return event
        }
        shown = shown || window.isVisible
        hiddenToken = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                             queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow else { return }
                if window.occlusionState.contains(.visible) && window.isVisible {
                    self.shown = true
                } else {
                    self.endSession()
                }
            }
        }
    }
}

/// 把一块视图在 AppKit 里的那一层报上来（挂在上半段的 background 上，大小就是上半段那一块）：
/// 小窗据此判断鼠标是不是按在上半段里
struct MenuBarAreaReader: NSViewRepresentable {
    var onView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onView(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        onView(view)
    }
}

/// 把小窗所在的窗口报上来（视图放进窗口、换窗口时都报一次）
struct MenuBarWindowReader: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
        if let window = view.window { onWindow(window) }
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
