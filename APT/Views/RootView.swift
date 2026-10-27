import SwiftUI
import SwiftData
import AppKit
import Combine

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    // case 顺序 = 侧栏自上而下的显示顺序（⌘ 数字按这个位置编号，见 NavShortcut）
    case overview, chronicle, profile, schedule, routine, habits, finance, annals, ai, data
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "今日洞府"
        case .chronicle: "修行录"
        case .profile: "修士名帖"
        case .schedule: "时辰卷"
        case .routine: "起居有常"
        case .habits: "每日功课"
        case .finance: "灵石账簿"
        case .annals: "岁月长卷"
        case .ai: "问道灵枢"
        case .data: "洞府设置"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "今天"
        case .chronicle: "日记 · 灵感 · 复盘"
        case .profile: "个人档案"
        case .schedule: "日程"
        case .routine: "固定作息"
        case .habits: "习惯打卡"
        case .finance: "消费账本"
        case .annals: "年度 · 季度回看"
        case .ai: "AI 优化"
        case .data: "数据与设置"
        }
    }

    /// 侧栏用的小物插画
    var ornament: String {
        let name: String = switch self {
        case .overview: "crane"
        case .chronicle: "journal"
        case .profile: "jade-pendant"
        case .schedule: "waterclock"
        case .routine: "hourglass"
        case .habits: "lotus"
        case .finance: "abacus"
        case .annals: "scroll"
        case .ai: "astrolabe"
        case .data: "archive-chest"
        }
        return "yunshan-ornament-\(name)-v1"
    }

    static let common: [AppSection] = [.overview, .chronicle, .profile, .schedule, .routine, .habits, .finance]
    /// 问道与藏卷：先回看（岁月长卷），再问道
    static let more: [AppSection] = [.annals, .ai, .data]
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "晨光 · 浅色"
        case .dark: "月色 · 深色"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    /// 窗口不在前台时暂停所有动效，省电也不抢 CPU
    @Environment(\.controlActiveState) private var activeState
    // 修为不在这里查询、也不在侧栏里查询：由应用级的 CultivationModel 在数据库保存后按指纹判断要不要重算，
    // 侧栏境界卡与今日洞府共用（修订弹窗、名帖里每敲一个字都不会再触发全量修为）
    @Query private var settingsList: [AppSettings]
    @Query private var receipts: [ImportReceipt]
    @State private var selection: AppSection

    /// effects：正式应用传入 AppHost 持有的那一个（后台传书巡查也用它）；离屏截图各自新建
    init(initialSelection: AppSection = .overview, effects: EffectsCenter = EffectsCenter()) {
        _selection = State(initialValue: initialSelection)
        _effects = State(initialValue: effects)
    }
    @State private var effects: EffectsCenter
    @State private var showLegacyPrompt = false
    @State private var showSearch = false
    /// 今天（YYYY-MM-DD）：跨过午夜、唤醒、改时区后更新，页面随之重建，“今天”不会停在昨天
    @State private var dayKey = LocalDay.today().key
    /// 启动时从备份恢复的结果，显示一次
    @State private var restoreNotice: BackupService.RestoreOutcome?
    /// 各页页首横幅滚到了哪里（SceneHero 上报）：决定顶栏的纸色底、底线和小号页名
    @State private var heroScroll = HeroScrollReport()
    /// 近 3 分钟有没有人动过、主窗口有没有被完全挡住：没人看时常驻动效视为关，一动立刻恢复（#20 能耗，ActivityWatch）
    @StateObject private var activity = ActivityWatch()
    @AppStorage("legacyPromptDismissed") private var legacyPromptDismissed = false
    @AppStorage("appearance") private var appearanceRaw = AppearanceMode.system.rawValue

    private var settings: AppSettings? { settingsList.first }
    /// 这个数据库的修为模型（第一次取时完整算一次，之后只在数据变了时重算）
    private var cultivation: CultivationModel { CultivationModel.shared(for: context) }
    /// 动效开关（原义：设置开、没开“减少动态效果”、窗口在前台）：悬停、转场、打卡圈、仪式都看它，闲着不算关
    private var motion: Bool {
        MotionGate.allows(enabled: settings?.motionEnabled ?? true, reduceMotion: reduceMotion, inactive: activeState == .inactive,
                          idle: false, occluded: false)
    }
    /// 常驻循环层（页面底的云与光点、横幅光点、金光呼吸）另要有人在看：闲满 3 分钟、主窗口被完全挡住时停（#20 能耗）
    private var ambient: Bool {
        MotionGate.allows(enabled: settings?.motionEnabled ?? true, reduceMotion: reduceMotion, inactive: activeState == .inactive,
                          idle: activity.idle, occluded: activity.occluded)
    }
    /// 当前页已往下滚（内容开始从顶栏底下经过）
    private var pageScrolled: Bool { heroScroll.scrolled.contains(selection) }
    /// 当前页的页首横幅已滚过（大标题被遮住）
    private var heroPassed: Bool { heroScroll.passed.contains(selection) }

    var body: some View {
        // 自己排侧栏与正文（不用系统的分栏视图）：侧栏固定 300 宽，不会被拖窄、收起或恢复成奇怪的宽度
        HStack(spacing: 0) {
            // 窗口矮时侧栏改紧凑排布，十项导航都能直接看到（常规排布约需 845 pt，860 高的窗口放得下）
            GeometryReader { proxy in sidebar(compact: proxy.size.height < 860) }
                .frame(width: 300)
            VStack(spacing: 0) {
                topBar
                // 顶栏底线：页面在顶上时不画，往下滚后才出现
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, Theme.gold.opacity(0.35), Theme.line, .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)
                    .opacity(pageScrolled ? 1 : 0)
                ZStack {
                    detail
                        // 跨过午夜时整页重建：落笔框里写到一半的正文存在草稿里；页面上开着弹窗（修订、编辑表单等）时
                        // 先不换日，等弹窗关掉再重建（见 refreshDay），弹窗里还没保存的内容不会被关掉
                        .id("\(selection.rawValue)|\(dayKey)")
                        .transition(motion ? .mistReveal : .identity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .coordinateSpace(name: HeroScroll.space)
                .onPreferenceChange(HeroScrollKey.self) { report in
                    guard report != heroScroll else { return }
                    withAnimation(motion ? .easeOut(duration: 0.2) : nil) { heroScroll = report }
                }
            }
            .background(PaperBackground(page: selection).environment(\.spiritMotion, ambient))
            .environment(\.someoneWatching, activity.watched)
            .buttonStyle(.yunshan)
            .textFieldStyle(.yunshan)
            .toggleStyle(.yunshan)
            .disclosureGroupStyle(.yunshan)
            .font(.ysBody)
            // 隐藏滚动条：常驻滚动条（接鼠标时）会占宽度，内容高度恰在临界点时会反复重排而卡住
            .scrollIndicators(.hidden)
            // 正文只能用剩下的宽度：内容再宽也只在正文里收缩，绝不挤压侧栏
            .frame(minWidth: 0, maxWidth: .infinity)
            .clipped()
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle("云山修习录")
        .overlay { XPToastOverlay() }
        // 关键时刻的仪式（落笔入卷、功课圆满、朱印）：Core Animation，不接收点击
        .overlay { RitualOverlay() }
        .overlay { SealStampOverlay() }
        .overlay {
            CourierOverlay(onOpen: { go(.chronicle) }, onUndo: undoDelivery, undoPreview: undoPreview)
        }
        .alert(restoreNotice?.succeeded == true ? "已从备份恢复" : restoreNotice?.cancelled == true ? "已放回原数据" : "没有完成恢复",
               isPresented: Binding(isPresent: $restoreNotice)) {
            Button("好") {}
        } message: {
            Text(restoreNotice?.message ?? "")
        }
        .overlay { TribulationOverlay().animation(effects.motionEnabled ? .easeInOut(duration: 0.4) : nil, value: effects.breakthrough) }
        .environment(effects)
        .environment(cultivation)
        .environment(AppRouter.shared)
        .environment(\.spiritMotion, motion)
        .onChange(of: AppRouter.shared.page) { _, page in
            guard let page else { return }
            go(page)
            AppRouter.shared.page = nil
        }
        .tint(Theme.jade)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.scheme)
        .onAppear(perform: bootstrap)
        // 主窗口关掉后，后台巡查照常（AppHost），但传书笺等特效不再需要动画
        .onDisappear { effects.motionEnabled = false }
        // 飞剑传书巡查、自动备份、快照刷新都挂在应用级的 AppHost 上（关掉主窗口也不停），这里不再启动
        // 跨午夜：系统日期变化、唤醒、改时区、回到前台时检查；另每 30 秒兜底查一次
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in refreshDay() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: RunLoop.main)) { _ in refreshDay() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange).receive(on: RunLoop.main)) { _ in refreshDay() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).receive(on: RunLoop.main)) { _ in refreshDay() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshDay() }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                refreshDay()
            }
        }
        .task(id: colorScheme) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await Scenery.prewarm(dark: colorScheme == .dark)
        }
        .onChange(of: motion) { _, value in effects.motionEnabled = value }
        .sheet(isPresented: $showSearch) { GlobalSearchView() }
        .sheet(isPresented: $showLegacyPrompt) {
            LegacyImportSheet(url: LegacyReader.defaultDatabaseURL, isFirstRun: true) {
                legacyPromptDismissed = true
            }
        }
    }

    // MARK: 侧栏

    private func sidebar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 品牌：一枚小印 + 宋体名（不发光，不再挂英文旧名）
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.card, Theme.mist], startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Theme.gold.opacity(0.6), Theme.line], startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.jade.opacity(0.5), lineWidth: 1).padding(4)
                    Text("山").font(Theme.songti(20, .semibold)).foregroundStyle(Theme.jade)
                }
                .frame(width: 44, height: 44)
                Text("云山修习录").font(Theme.songti(TypeSize.title, .bold)).tracking(4).foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.top, 30)   // 隐藏标题栏后，给左上角的红黄绿按钮留出位置
            .padding(.bottom, compact ? 10 : 14)

            SidebarRealmSection(dayKey: dayKey)
                .padding(.bottom, compact ? 10 : 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: "常用空间").padding(.horizontal, 6).padding(.bottom, compact ? 4 : 8)
                    ForEach(AppSection.common) { navItem($0, compact: compact) }

                    SectionLabel(text: "问道与藏卷").padding(.horizontal, 6).padding(.top, compact ? 8 : 14).padding(.bottom, compact ? 4 : 8)
                    ForEach(AppSection.more) { navItem($0, compact: compact) }
                }
                .padding(.leading, 2)
                .padding(.vertical, 4)
            }
            // 列表滚动时上下边缘淡出，不会生硬地压在境界卡下面
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                         .init(color: .black, location: 0.97), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            Spacer(minLength: compact ? 4 : 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(edges: .top)
        .background { SidebarBackground().accessibilityHidden(true) }
        // 侧栏一直在主窗口里：借它把主窗口报给 ActivityWatch（放在 body 的长链上会让编译器类型检查超时）
        .background(ActivityProbe(watch: activity))
    }

    private func navItem(_ section: AppSection, compact: Bool) -> some View {
        SidebarNavItem(section: section, on: selection == section, motion: motion, compact: compact) { go(section) }
            // 落笔入卷后，卷成的小卷化作灵光飞进“修行录”
            .ritualAnchor(section == .chronicle ? .chronicleNav : nil)
    }

    // MARK: 顶栏

    /// 薄顶栏：只有搜索和晨昏切换。页名平时由页首大标题和侧栏选中项表示，
    /// 页面往下滚时顶栏才垫上纸色底和底线，滚过横幅（大标题被遮住）后左侧再淡入一个小号页名。
    private var topBar: some View {
        HStack(spacing: 14) {
            Text(selection.title)
                .font(Theme.songti(16, .semibold))
                .tracking(2)
                .foregroundStyle(Theme.ink)
                .opacity(heroPassed ? 1 : 0)
                .accessibilityHidden(!heroPassed)
            Spacer()
            // 全局搜索 ⌘F
            Button { showSearch = true } label: {
                HStack(spacing: 8) {
                    // 普通图标用次要灰（金色只给修为、选中、珍藏）
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkSoft)
                    Text("搜索记录").foregroundStyle(Theme.inkSoft)
                    Text(KeyCommand.search.display).font(.ysCaption.monospacedDigit()).foregroundStyle(Theme.inkSoft.opacity(0.7))
                }
                .font(.ysCallout)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.card.opacity(0.8), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyCommand(.search)
            .help(KeyCommand.search.help("搜索全部记录"))
            Menu {
                Picker("外观", selection: $appearanceRaw) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: (AppearanceMode(rawValue: appearanceRaw) ?? .system) == .dark ? "moon.stars" : "sun.haze")
                    .foregroundStyle(Theme.inkSoft)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("晨光 / 月色")
            .accessibilityLabel("外观：" + (AppearanceMode(rawValue: appearanceRaw) ?? .system).label)
        }
        .font(.ysBody)
        .padding(.horizontal, 44)
        .padding(.top, 16)
        .padding(.bottom, 10)
        // 页面在顶上时顶栏完全透明，与页面底色连成一片；往下滚后才垫纸色
        // 纸色取页面最顶端随时辰变化后的实际纸色（浅色夜里不会是一条发白的带子）
        .background(SkyPaperFill(top: 0.92, bottom: 0.55).opacity(pageScrolled ? 1 : 0))
        // 印谱：保存后约 1 秒、跨午夜时看一眼有没有新得的印。顶栏一直都在，挂在它背后（看不见、不接点击）；
        // 计数放在这个小视图里，保存不会让整个根视图重算（根视图的修饰链也已长到编译器难以推断，不再往上加）
        .background { MilestoneProbe(dayKey: dayKey) }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .overview: DashboardView(onNavigate: { go($0) })
        case .chronicle: ChronicleView()
        case .profile: ProfileView()
        case .schedule: ScheduleView()
        case .routine: RoutineView()
        case .habits: HabitsView()
        case .finance: FinanceView()
        case .annals: AnnalsView()
        case .ai: AIOptimizeView()
        case .data: DataSettingsView()
        }
    }

    /// 找到窗口里最大的滚动区（当前页面）：切页后回到顶部用
    static func largestScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ v: NSView) {
            if let s = v as? NSScrollView, s.frame.width > (best?.frame.width ?? 0), (s.documentView?.frame.height ?? 0) > s.frame.height { best = s }
            v.subviews.forEach(visit)
        }
        visit(view)
        return best
    }

    private func go(_ section: AppSection) {
        guard section != selection else { return }
        withAnimation(motion ? .easeOut(duration: 0.28) : nil) { selection = section }
        settlePage()
    }

    /// 新页面出现时：不让系统自动把光标放进第一个输入框（那会顺带把页面滚下去），并从顶部开始
    private func settlePage() {
        guard !RenderMode.offscreen else { return }
        for delay in [0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 800 }) else { return }
                if window.firstResponder is NSTextView { window.makeFirstResponder(nil) }
                if let content = window.contentView, let scroll = Self.largestScrollView(in: content) {
                    scroll.contentView.scroll(to: .zero)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
    }

    /// 传书笺上的“撤销此书”（两步确认在传书笺里做）：撤回这封传书写入的内容，结果用中文提示出来
    /// （删了几条记录、恢复了几个档案字段和目标、保留了哪些收录后改过的，接第一条保留原因；账本出错时说明原因，什么都不动）。
    private func undoDelivery(_ id: String) {
        guard let delivery = context.all(CourierDelivery.self).first(where: { $0.deliveryID == id }) else { return }
        effects.courierUndoResult(CourierService.undo(delivery, context: context, refresh: true, keepEdited: true))
    }

    /// 传书笺上第一次点“撤销此书”时显示的说明：删几条记录、恢复几个档案字段和目标、保留哪些收录后改过的，再接第一条保留原因。
    /// 与修行录里飞剑传书卡的撤销说明同一套说法（CourierUndoWording；传书笺上只有“保留改过的”这一种撤销）
    private func undoPreview(_ id: String) -> String? {
        guard let delivery = context.all(CourierDelivery.self).first(where: { $0.deliveryID == id }) else { return nil }
        return Self.courierUndoPlan(CourierService.undoPreviewDetail(delivery, context: context))
    }

    /// 撤销说明的正文（自检也用它核对说法）
    static func courierUndoPlan(_ p: CourierUndoPreview) -> String {
        CourierUndoWording.cardPreview(p.wording)
    }

    /// 日期变了（跨午夜、唤醒、改时区）就更新 dayKey，让页面重建。
    /// 应用里正开着弹窗时先不换：整页重建会把挂在页面上的修订 / 编辑表单、确认框、打卡数量框连同里面
    /// 还没保存的内容一起关掉。刚删了一篇修行录、“撤销删除”还在的约 8 秒里也先不换：重建会把撤销提示和删除时
    /// 拍的快照一起丢掉。等弹窗关了、撤销提示过了，每 30 秒的兜底检查或下一次回到前台时再换。
    private func refreshDay() {
        let key = LocalDay.today().key
        guard key != dayKey, !Self.isPresentingModal, !JournalActions.undoWindowOpen else { return }
        dayKey = key
    }

    /// 有没有正开着的弹窗：sheet、alert、confirmationDialog 在 macOS 上都是挂在窗口上的 attachedSheet；
    /// popover 是单独的 _NSPopoverWindow；文件面板等模态窗口会让 modalWindow 不为空。
    /// 菜单栏“洞府设置… ⌘,”也看它：开着弹窗时不切页（KeyMenuCommands.openSettings）
    static var isPresentingModal: Bool {
        let app = NSApplication.shared
        return app.modalWindow != nil || app.windows.contains { window in
            window.attachedSheet != nil || (window.isVisible && String(describing: type(of: window)).contains("Popover"))
        }
    }

    private func bootstrap() {
        settlePage()
        refreshDay()
        if !RenderMode.offscreen {
            // 传书巡查、备份、热键、通知代理都由 AppHost 在应用启动时安排；这里只管窗口自己的事
            ScrollActivity.shared.install()
            AppRouter.shared.openMainWindow = { [openWindow] in openWindow(id: "main") }
            if let outcome = BackupService.lastRestoreOutcome {
                BackupService.lastRestoreOutcome = nil
                restoreNotice = outcome
            }
        }
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        DataStore.save(context)
        FinanceService.migrateArchivedLedgerIfNeeded(context)
        effects.motionEnabled = motion
        // 窗口出现之前就挂着的跳转（例如主窗口关着时点了周复盘通知）：现在补上
        if let page = AppRouter.shared.page {
            AppRouter.shared.page = nil
            go(page)
        }
        // 首次启动：发现旧版数据库且还没导入过时，询问是否导入。
        if receipts.isEmpty, !legacyPromptDismissed, FileManager.default.fileExists(atPath: LegacyReader.defaultDatabaseURL.path) {
            showLegacyPrompt = true
        }
    }
}

/// 侧栏境界卡：修为读应用级的 CultivationModel（不再自己 @Query 全部习惯与落笔、每次刷新全量重算）；渡劫在这里判断。
/// 只读模型的修为与设置：打字、与修为无关的保存都不会让这张卡重算；动效开关只交给卡片里做动画的徽记。
private struct SidebarRealmSection: View {
    /// 跨午夜时让修为模型换到新的一天（“今日 +N”归零）
    var dayKey: String
    @Environment(EffectsCenter.self) private var effects
    @Environment(CultivationModel.self) private var cultivation
    /// 历史最高境界（只升不降，沿用原来的键名）：只有超过它才播放渡劫。
    /// 关掉再打开修为、调门槛、删掉复盘再写回、归档又取消归档，都不会重复“突破”。
    @AppStorage("lastRealmIndex") private var highestRealmIndex = -1

    var body: some View {
        let config = cultivation.config
        let state = cultivation.state
        SidebarRealmCard(state: state)
            .onAppear {
                // 主窗口关着时可能已经换了一天：先让模型看一眼（没变化时约 1 毫秒），再按最新的修为判断
                cultivation.refresh()
                let config = cultivation.config
                let state = cultivation.state
                // 第一次运行，或主窗口关着时境界升了（传书照常收录，这张卡不在、onChange 不会触发）、规则变化让修为上升：
                // 都静默记为历史最高、不补放渡劫，保证历史最高不低于当前境界，之后回落再回升不会对它补放渡劫
                if config.enabled, !RenderMode.offscreen, state.realmIndex > highestRealmIndex { highestRealmIndex = state.realmIndex }
            }
            .onChange(of: state.realmIndex) { _, index in
                guard config.enabled, !RenderMode.offscreen else { return }
                if highestRealmIndex < 0 { highestRealmIndex = index; return }
                guard index > highestRealmIndex else { return }
                highestRealmIndex = index
                effects.celebrate(realm: state.realmName, index: state.realmIndex)
            }
            .onChange(of: dayKey) { _, _ in cultivation.refresh() }
    }
}

/// 侧栏境界卡：境界与阶段、修为与今日所得、离下一境还差多少（进度看徽记外的金环）。点一下弹出修为规则。
struct SidebarRealmCard: View {
    var state: CultivationState
    /// 徽记的动效（含窗口不在前台时暂停）：只在这张小卡里读，算修为的部分不因它重算
    @Environment(\.spiritMotion) private var animated
    @State private var showRules = false

    private var remaining: String {
        state.nextRealmName.map { "距「\($0)」还差 \(state.xpToNext ?? 0)" } ?? "已至最高境界"
    }

    var body: some View {
        Button { showRules = true } label: {
            HStack(spacing: 12) {
                RealmBadge(state: state, size: 64, animated: animated)
                    // 功课圆满时四方灵光汇到这里（“丹田”）
                    .ritualAnchor(.dantian)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(state.realmName).font(Theme.songti(TypeSize.heading, .bold)).tracking(2).foregroundStyle(Theme.ink)
                        Text(state.stage).font(.ysCaption.weight(.medium)).foregroundStyle(Theme.gold)
                    }
                    Text("修为 \(state.totalXP)" + (state.todayXP > 0 ? " · 今日 +\(state.todayXP)" : ""))
                        .font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                    Text(remaining)
                        .font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft.opacity(0.8))
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(
                Theme.card
                    .overlay(alignment: .trailing) {
                        SceneryImage(name: "yunshan-ornament-texture-cloud-v1")
                            .frame(width: 90, height: 90)
                            .opacity(0.14)
                            .offset(x: 18)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
            // 悬停时描边转金（与问法块、列表行同一套反馈；滑动时不跟着亮）
            .yunshanTile(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showRules, arrowEdge: .trailing) { rules }
        .accessibilityLabel("\(state.realmName)\(state.stage)，修为 \(state.totalXP)，\(remaining)")
        .accessibilityHint("查看修为规则")
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("修为规则").font(.ysHeading).tracking(1).foregroundStyle(Theme.ink)
            Text(CultivationEngine.rulesDescription)
                .font(.ysCaption).lineSpacing(3).foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 380, alignment: .leading)
    }
}

/// 侧栏底：纸色渐变，底部一株淡淡的松，右缘一线金。
struct SidebarBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: [Theme.sidebar, dark ? Color(red: 0.05, green: 0.1, blue: 0.11) : Theme.mist.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
            // 天色罩色的一半：侧栏与正文的色调连得上，侧栏比正文浅一档的层次还在
            SkyVeil(strength: 0.5)
            SceneryImage(name: "yunshan-ornament-texture-pine-v1")
                .frame(width: 170, height: 170)
                .saturation(dark ? 0.4 : 0.8)
                .opacity(dark ? 0.07 : 0.11)
                .offset(x: 50, y: 10)
            Rectangle()
                .fill(LinearGradient(colors: [.clear, Theme.gold.opacity(0.3), Theme.line, .clear], startPoint: .top, endPoint: .bottom))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }
}

/// 侧栏一项：小物插画 + 宋体名 + 白话说明。
/// 选中只有两重标记：整行淡玉底 + 左侧 2pt 金线。悬停时浮起更淡的玉底、插画微微放大，
/// 文字不动（不改字距、不右移），插画也不旋转、不换色。
struct SidebarNavItem: View {
    var section: AppSection
    var on: Bool
    var motion: Bool
    /// 窗口矮时的紧凑排布：插画小一号、上下留白更少
    var compact: Bool = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        // 侧栏自上而下的位置（allCases 的顺序就是侧栏顺序）：1–9 → ⌘1…⌘9，第 10 项 → ⌘0，再往后没有快捷键
        let number = (AppSection.allCases.firstIndex(of: section) ?? 0) + 1
        let combo = KeyCommand.pageCombo(forPosition: number)
        let lit = on || hover
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    // 悬停 / 选中：小物背后泛起一圈金光，小物放大、轻轻一转、微微上浮
                    SoftGlow(color: Theme.gold.opacity(on ? 0.45 : 0.3))
                        .frame(width: compact ? 54 : 64, height: compact ? 54 : 64)
                        .opacity(lit ? 1 : 0)
                        .scaleEffect(hover && !on ? 1.08 : 1)
                    Circle()
                        .fill(on ? Theme.card : Theme.mist.opacity(hover ? 0.9 : 0.6))
                        .overlay(Circle().strokeBorder(lit ? Theme.gold.opacity(on ? 0.6 : 0.45) : Theme.line.opacity(0.8), lineWidth: 1))
                        .frame(width: compact ? 34 : 40, height: compact ? 34 : 40)
                    SceneryImage(name: section.ornament)
                        .frame(width: compact ? 30 : 35, height: compact ? 30 : 35)
                        .saturation(lit ? 1.05 : 0.85)
                        .opacity(lit ? 1 : 0.92)
                        .scaleEffect(hover ? 1.14 : (on ? 1.06 : 1))
                        .rotationEffect(.degrees(hover && motion ? -4 : 0))
                        .offset(y: hover && motion ? -1.5 : 0)
                }
                .frame(width: compact ? 36 : 42, height: compact ? 36 : 42)
                VStack(alignment: .leading, spacing: 1) {
                    // 字距保持不变：悬停时只换颜色、整体右移，文字本身不抖
                    Text(section.title)
                        .font(.ysHeading)
                        .tracking(2)
                        .foregroundStyle(hover && !on ? Theme.jadeDeep : Theme.ink)
                    Text(section.subtitle)
                        .font(.ysCaption)
                        .tracking(1)
                        .foregroundStyle(Theme.inkSoft.opacity(lit ? 1 : 0.7))
                        .lineLimit(1)
                }
                .offset(x: hover && !on && motion ? 3 : 0)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, compact ? 2 : 5)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.jade.opacity(on ? 0.16 : 0.10), Theme.card.opacity(on ? 0.7 : 0.35)],
                                         startPoint: .leading, endPoint: .trailing))
                    .opacity(lit ? 1 : 0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Theme.gold.opacity(on ? 0.45 : 0.25), lineWidth: 1)
                    .opacity(lit ? 1 : 0)
            }
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.gold)
                    .frame(width: 2, height: on ? (compact ? 16 : 20) : 10)
                    .opacity(on ? 1 : (hover ? 0.6 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(motion ? .spring(response: 0.28, dampingFraction: 0.72) : nil) { hover = inside }
        }
        .help(section.subtitle + (combo.map { "（\($0.display)）" } ?? ""))
        // ⌘1–⌘9、⌘0 直接切页（Character("10") 会运行时崩溃，所以按位置换成键盘数字行的字符，见 KeyCommand.pageCombo）
        .keyCommand(.pages, position: number)
        .accessibilityLabel(section.title + "，" + section.subtitle + (on ? "，当前页" : ""))
        .padding(.bottom, compact ? 2 : 3)
    }
}
