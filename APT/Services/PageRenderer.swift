import SwiftUI
import SwiftData
import AppKit

/// 调试用：`APT --render-pages <输出文件夹> [旧版数据库]`
/// 在内存数据库里导入旧数据并加几条示例习惯，把每个页面在浅色 / 深色下离屏渲染成 PNG，不读写正式数据：
/// - 数据库只在内存里；收件箱、快照、备份等文件都落在临时数据目录（SelfTest 先把 APT_STORE_DIR 指过去）；
/// - 偏好设置（外观、账簿标签、草稿、历史最高境界……）写进单独的临时 UserDefaults（每个进程一个），不影响正在运行的正式应用；
/// - 后台服务（传书巡查、自动备份）挂在 AppHost 上，离屏渲染时不会启动。
///
/// 环境变量（都可不设）：
/// - `APT_RENDER_SIZE=1280x800`：窗口尺寸（默认 1440×920）；
/// - `APT_RENDER_ONLY=<名字>`：只渲染一张，如 `light-schedule`；`sheets` 只渲染弹窗，`effects` 只渲染特效定格（含仪式）；
///   `rituals` 只渲染落笔入卷、功课圆满、朱印、随手记小印、渡劫、飞剑的定格；`courier` 只渲染传书笺的定格（深浅色各 6 张）；
///   `sky` 只渲染今日洞府在晨 / 昼 / 暮 / 夜 × 浅 / 深色下的 8 张；
///   `keys` 只渲染快捷键一览（浅 / 深色各一屏、一张整卷长图；`light-keys`、`dark-keys` 只渲一套）；
///   `weekly` 只渲染七日小卷（浅 / 深色各一屏 light-weekly.png、一张整卷长图 light-weekly-full.png；`light-weekly`、`dark-weekly` 只渲一套；
///   看哪一周按 APT_RENDER_WEEK=<那周任一天 yyyy-MM-dd>，默认按今天与 APT_RENDER_CLOCK：周一 12:00 前是上一周）；
///   `sheets` 里有落笔模板的两个小弹窗（sheet-light-tpl-save.png“存为模板”、sheet-light-tpl-manage.png“管理模板”，先存两套自存的）；
///   `menubar` 只渲染菜单栏小窗（浅 / 深色各一张 light-menubar.png、dark-menubar.png；`light-menubar`、`dark-menubar` 只渲一张）；
///   `menubar-session` 只渲染小窗开着时接连打卡的四张（light-menubar-s0…s3.png：刚打开、数量型各 +1 一次、
///   每天 / 指定星期的签打满、全部打满；飘字清掉再截，另留一张带飘字的 s2-toast），对照签有没有挪位、签下方的“功课圆满”；
/// - `APT_RENDER_RITUAL_FRAMES=1`：落笔入卷、功课圆满另出每 50 ms 一张的逐帧（effect-frames/、effect-light-frames/），逐帧看分镜；
/// - `APT_RENDER_CLOCK=HH:MM`：天色与首页问候按这个时刻画（默认 12:00，昼，与原来的截图一致）；
/// - `APT_RENDER_DEFAULTS="schedule.mode=全部日程;ai.preset=custom;settings.group.storage=1"`：渲染前预设几项偏好（字符串值），
///   用来截“近期列表 / 全部日程”“自定义问法”“设置组展开 / 折叠”这类状态；
/// - `APT_RENDER_SCROLL=<点数>`：截图前把正文的滚动区往下滚这么多（看顶栏的底线和淡入的页名）；
/// - `APT_RENDER_ADVICE=1`：另加两条参悟记录（看问道页的“参悟记录”卡）；
/// - `APT_RENDER_NOSEED=1`：不加示例数据（旧版数据库照样导入：本机有旧版数据时日程、档案、账目仍在）；
/// - `APT_RENDER_EMPTY=1`（仅调试版）：完全空的内存库，不读旧版数据库、不加示例数据，看全新使用者的空状态（优先于下面的 DEMO）；
/// - `APT_RENDER_DEMO=<年数>`（仅调试版）：用 DemoSeeder 在内存库里造 N 年的演示数据（1–20，压力测试用 5），
///   代替导入旧版数据库和示例习惯（这时不读旧版数据库，APT_RENDER_NOSEED 不起作用）；
///   写成 `<天数>d`（例如 14d）造“轻度新手”：只用了这么些天、记录很少（见 DemoSeeder.seedLight）。
@MainActor
enum PageRenderer {
    /// 渲染尺寸：默认 1440×920，可用 APT_RENDER_SIZE=1180x780 检查小窗口下的排版
    static let size: CGSize = {
        let parts = (ProcessInfo.processInfo.environment["APT_RENDER_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : CGSize(width: 1440, height: 920)
    }()

    /// 渲染专用的偏好设置（@AppStorage 通过 .defaultAppStorage 读写这里），用完整个清掉。
    /// 套件名带上进程号：分进程逐页渲染（APT_RENDER_ONLY）时，前一个进程留下的账簿标签等偏好不会串到后一个进程。
    /// 与 AppPreferences 离屏时用的是同一个名字：落笔草稿、月末备注这类直接读写偏好的地方（AppPreferences.defaults）
    /// 和 @AppStorage 读写的是同一份，渲染完一起清掉
    private static let defaultsSuite = AppPreferences.renderSuiteName
    private static let defaults: UserDefaults = {
        // 套件名与应用的 bundle id 不同，系统一定会给出这个独立的偏好域
        let d = UserDefaults(suiteName: defaultsSuite)!
        d.removePersistentDomain(forName: defaultsSuite)
        return d
    }()

    /// 清空渲染用的偏好，并删掉系统留下的空 plist（套件名带进程号，不删就会每跑一次留一个）。
    /// 偏好进程（cfprefsd）把空域写回文件是异步的，删了它有时还会稍后再写一个：所以先等一会儿再删，
    /// 并顺带清掉以前的渲染进程留下的空文件（十分钟以前的，不会碰到正在并行渲染的进程）。
    /// 这样最多只留下最近十分钟里几次渲染的空文件，下次渲染时清掉。
    /// 不带进程号的 io.github.orientaldaitou.yunshan.render.plist 不是渲染器建的，不动
    private static func discardDefaults() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults.synchronize()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let fm = FileManager.default
        let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let prefix = "io.github.orientaldaitou.yunshan.render."
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) && name.hasSuffix(".plist") {
            let pid = name.dropFirst(prefix.count).dropLast(".plist".count)
            guard !pid.isEmpty, pid.allSatisfy(\.isNumber) else { continue }
            let url = folder.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
            if name == "\(defaultsSuite).plist" || Date().timeIntervalSince(modified) > 600 {
                try? fm.removeItem(at: url)
            }
        }
    }

    static func render(to directory: URL, legacyPath: String) {
        // 双保险：被直接调用、没经过 SelfTest 时也不让文件操作落到正式数据目录
        if DataStore.customDirectory == nil {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("APT-render-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            setenv("APT_STORE_DIR", scratch.path, 1)
        }
        defer { discardDefaults() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let container = try DataStore.makeContainer(inMemory: true)
            let context = container.mainContext
            DataStore.settings(in: context)
            DataStore.profile(in: context)
            let env = ProcessInfo.processInfo.environment
            prepareData(context, env: env, legacyPath: legacyPath)
            defaults.set("system", forKey: "appearance")   // 让窗口外观决定浅 / 深色
            // 预设偏好：“键=值;键=值”
            for pair in (env["APT_RENDER_DEFAULTS"] ?? "").split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { defaults.set(parts[1], forKey: parts[0].trimmingCharacters(in: .whitespaces)) }
            }
            var jobs: [(String, AppSection, String?)] = AppSection.allCases.map { ($0.rawValue, $0, nil) }
            for tab in FinanceView.Tab.allCases.dropFirst() { jobs.append(("finance-\(tab.id)", .finance, tab.rawValue)) }
            let only = env["APT_RENDER_ONLY"]
            if only == nil || only == "effects" || only == "courier" { renderEffects(container: container, directory: directory) }
            if only == nil || only == "effects" || only == "rituals" { renderRituals(container: container, directory: directory) }
            if only == "effects" || only == "rituals" || only == "courier" { return }
            if only == "sky" {
                renderSky(container: container, directory: directory)
                return
            }
            if only == "sheets" {
                renderSheets(container: container, directory: directory)
                let items = JournalExport.items(container.mainContext.all(JournalEntry.self))
                try? JournalExport.writePDF(html: JournalExport.html(items, title: "修行录 · 示例"), to: directory.appendingPathComponent("journal-sample.pdf"))
                return
            }
            // 菜单栏小窗（点菜单栏笔形图标弹出的那扇）：APT_RENDER_ONLY=menubar 浅深两张，light-menubar / dark-menubar 只渲一张
            if only == nil || only == "menubar" || only == "light-menubar" || only == "dark-menubar" {
                renderMenuBar(container: container, directory: directory, only: only)
                if only != nil { return }
            }
            // 小窗开着时接连打卡（会改动内存库里今天的打卡，所以只在单独要时渲染，放在最后也不影响别的页）
            if only == "menubar-session" {
                renderMenuBarSession(container: container, directory: directory)
                return
            }
            // 快捷键一览（帮助菜单 ⌘/ 打开的小卷）：APT_RENDER_ONLY=keys 浅深两套，light-keys / dark-keys 只渲一套
            if only == nil || only == "keys" || only == "light-keys" || only == "dark-keys" {
                renderKeyGuide(directory: directory, only: only)
                if only != nil { return }
            }
            // 七日小卷（修行录卷中气象“七日小卷 →”打开的小卷）：APT_RENDER_ONLY=weekly 浅深两套，light-weekly / dark-weekly 只渲一套
            if only == nil || only == "weekly" || only == "light-weekly" || only == "dark-weekly" {
                renderWeekly(container: container, directory: directory, only: only)
                if only != nil { return }
            }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for (label, page, tab) in jobs where only == nil || only == "\(name)-\(label)" {
                    let started = Date()
                    defer { print(String(format: "  用时 %.1fs", Date().timeIntervalSince(started))) }
                    defaults.set(tab ?? FinanceView.Tab.overview.rawValue, forKey: "finance.tab")
                    let root = RootView(initialSelection: page).modelContainer(container).defaultAppStorage(defaults)
                        .frame(width: size.width, height: size.height)
                    let host = NSHostingView(rootView: root)
                    host.frame = CGRect(origin: .zero, size: size)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
                    host.layoutSubtreeIfNeeded()
                    if let amount = Double(env["APT_RENDER_SCROLL"] ?? ""), let scroll = RootView.largestScrollView(in: host) {
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: amount))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                        host.layoutSubtreeIfNeeded()
                    }
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let url = directory.appendingPathComponent("\(name)-\(label).png")
                    try rep.representation(using: .png, properties: [:])?.write(to: url)
                    print("已渲染 \(url.lastPathComponent)")
                    window.close()
                }
            }
        } catch {
            print("渲染失败：\(error)")
        }
    }

    /// 快捷键一览：打开时窗口里看到的那一屏（620×780，<浅深>-keys.png），和整卷铺开的长图（<浅深>-keys-full.png）
    private static func renderKeyGuide(directory: URL, only: String?) {
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)]
        where only == nil || only == "keys" || only == "\(name)-keys" {
            for full in [false, true] {
                let host = NSHostingView(rootView: KeyGuideView(motion: false, fullLength: full).defaultAppStorage(defaults))
                host.frame = CGRect(origin: .zero, size: CGSize(width: 620, height: 780))
                if full {
                    host.layoutSubtreeIfNeeded()
                    host.frame = CGRect(origin: .zero, size: CGSize(width: 620, height: max(780, host.fittingSize.height)))
                }
                // 无边框窗口：带标题栏时宿主视图按标题栏的安全区多出一条（约 28pt），整卷图顶部一条黑
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let url = directory.appendingPathComponent("\(name)-keys\(full ? "-full" : "").png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    print("已渲染 \(url.lastPathComponent)")
                }
                window.close()
            }
        }
    }

    /// 七日小卷：打开时看到的那一屏（620×760，<浅深>-weekly.png）与整卷铺开的长图（<浅深>-weekly-full.png）。
    /// 看哪一周：APT_RENDER_WEEK=<那周任一天>，没设时与窗口里一样（今天、APT_RENDER_CLOCK 的时刻）
    private static func renderWeekly(container: ModelContainer, directory: URL, only: String?) {
        let today = LocalDay.today()
        let week = ProcessInfo.processInfo.environment["APT_RENDER_WEEK"].flatMap { LocalDay(key: $0) }
            .map { WeeklyDigest.Week(monday: min($0, today).mondayOfWeek, today: today) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)]
        where only == nil || only == "weekly" || only == "\(name)-weekly" {
            for full in [false, true] {
                let root = WeeklyScrollSheet(week: week, fullLength: full)
                    .yunshanSheet()
                    .environment(EffectsCenter())
                    .environment(\.spiritMotion, false)
                    .modelContainer(container)
                    .defaultAppStorage(defaults)
                let host = NSHostingView(rootView: root)
                host.frame = CGRect(origin: .zero, size: CGSize(width: 620, height: 760))
                // 无边框窗口（同快捷键一览）：顶部不多出标题栏那一条
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                if full {
                    host.frame = CGRect(origin: .zero, size: CGSize(width: 620, height: max(760, host.fittingSize.height)))
                    window.setContentSize(host.frame.size)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                }
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    write(rep, "\(name)-weekly\(full ? "-full" : "").png", to: directory)
                }
                window.close()
            }
        }
    }

    /// 菜单栏小窗：宽 460、高随内容，与点开菜单栏图标时看到的一样（上半段今日、金线、随手记、底栏）。
    /// 时辰与倒计时按 APT_RENDER_CLOCK（默认 12:00）；随手记草稿可用 APT_RENDER_DEFAULTS 预设（如 draft.quick.text=…）。
    /// 无边框窗口：带标题栏时宿主视图会按标题栏的安全区多出一条
    private static func renderMenuBar(container: ModelContainer, directory: URL, only: String?) {
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)]
        where only == nil || only == "menubar" || only == "\(name)-menubar" {
            let (window, host) = menuBarWindow(container: container, appearance: appearance)
            captureMenuBar(window: window, host: host, name: "\(name)-menubar.png", directory: directory)
            window.close()
        }
    }

    /// 小窗开着时接连打卡（同一扇小窗、同一次打开）：s0 刚打开；s1 数量型的签各 +1 一次；s2 每天 / 指定星期的签都打满
    /// （只剩每周 N 次的签）；s3 列出的签全部打满。打卡走小窗自己的那条路（+1 → MenuBarSupport.addStep，点圈 → HabitActions.toggle），
    /// 特效进小窗自己的特效中心。四张对照：签的位置在这次打开期间不变、“功课圆满”写在签的下方（另有 s2-toast：带着飘字的 s2）
    private static func renderMenuBarSession(container: ModelContainer, directory: URL) {
        let context = container.mainContext
        let model = CultivationModel.shared(for: context)
        model.refresh()
        let today = LocalDay.today()
        let items = MenuBarSupport.items(model.rows, today: today)
        let rows = MenuBarDigest.plan(items).chips.map { model.rows[$0] }
        let effects = MenuBarSupport.effects
        let (window, host) = menuBarWindow(container: container, appearance: .aqua)
        captureMenuBar(window: window, host: host, name: "light-menubar-s0.png", directory: directory)
        func target(_ row: CultivationModel.HabitRow) -> Double? {
            HabitQuantity.target(row.habit, atLog: HabitDayLogs(day: today, context: context).log(of: row.habit)?.targetAtLog)
        }
        func complete(_ row: CultivationModel.HabitRow) {
            if let target = target(row) {
                var guardCount = 0
                while (HabitDayLogs(day: today, context: context).log(of: row.habit)?.quantity ?? 0) < target, guardCount < 200 {
                    MenuBarSupport.addStep(row.habit, step: MenuBarHabitChip.step(target: target, unit: "").step, context: context, effects: effects,
                                           allHabits: model.habits, config: model.config)
                    guardCount += 1
                }
            } else if !(model.rows.first { $0.id == row.id }?.stats.isAchieved(today) ?? false) {
                HabitActions.toggle(row.habit, on: today, context: context, effects: effects, allHabits: model.habits, config: model.config)
            }
        }
        for row in rows {
            if let target = target(row) {
                MenuBarSupport.addStep(row.habit, step: MenuBarHabitChip.step(target: target, unit: "").step, context: context, effects: effects,
                                       allHabits: model.habits, config: model.config)
            }
        }
        // 飘字（+修为、功课圆满）会盖住签：s1–s3 先清掉再截；s2 另留一张带飘字的（刚飘过“功课圆满”时签下方有没有对应的说明）
        effects.toasts.removeAll()
        captureMenuBar(window: window, host: host, name: "light-menubar-s1.png", directory: directory)
        for row in rows where row.habit.frequencyKind != .weekly { complete(row) }
        captureMenuBar(window: window, host: host, name: "light-menubar-s2-toast.png", directory: directory)
        effects.toasts.removeAll()
        captureMenuBar(window: window, host: host, name: "light-menubar-s2.png", directory: directory)
        for row in rows { complete(row) }
        effects.toasts.removeAll()
        captureMenuBar(window: window, host: host, name: "light-menubar-s3.png", directory: directory)
        window.close()
    }

    private static func menuBarWindow(container: ModelContainer, appearance: NSAppearance.Name) -> (NSWindow, NSHostingView<some View>) {
        let host = NSHostingView(rootView: MenuBarPanel().modelContainer(container).defaultAppStorage(defaults))
        host.frame = CGRect(origin: .zero, size: CGSize(width: 460, height: 640))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        return (window, host)
    }

    /// 高度随内容（功课几枚、有没有“已圆满”一行）：量好再收一次，然后截图（内容贴着顶边，前后几张的签可以逐像素对照）
    private static func captureMenuBar(window: NSWindow, host: NSView, name: String, directory: URL) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let fitted = CGSize(width: 460, height: max(200, min(900, host.fittingSize.height)))
        window.setContentSize(fitted)
        host.frame = CGRect(origin: .zero, size: fitted)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            write(rep, name, to: directory)
        }
    }

    /// 弹出窗口（编辑表单、月历、时刻格子）单独渲染，检查表单外观。
    private static func renderSheets(container: ModelContainer, directory: URL) {
        let context = container.mainContext
        // 样本按固定次序取（数据库取出的顺序每次不同），前后两次渲染的弹窗才能逐张对比
        let event = context.all(ScheduleEvent.self).min { ($0.title, $0.dateKey) < ($1.title, $1.dateKey) }
        let habit = context.all(Habit.self).min { ($0.sortOrder, $0.title) < ($1.sortOrder, $1.title) }
        let goal = context.all(Goal.self).min { $0.title < $1.title }
        let entry = context.all(JournalEntry.self).min { ($0.dateKey, $0.body) > ($1.dateKey, $1.body) }
        let ledger = try? FinanceService.load(context)
        let row = ledger?.transactions.first
        // 已存的月卷：取最近一个月的最新一版（旧版导入的数据里没有时，这张图是空白）
        let report = ledger?.monthlyReports.max { ($0.month, $0.version) < ($1.month, $1.version) }
        var day = LocalDay.today()
        var minute = 14 * 60 + 30
        // 落笔模板的两个小弹窗：先存两套自存的（APT_RENDER_DEFAULTS 已设 templates.custom 时照它的），“管理模板”列得出改名、删除
        if defaults.string(forKey: JournalTemplates.customKey) == nil {
            JournalTemplateStore.save([JournalTemplate(name: "周末小结", body: "这周最开心的事：\n\n下周想试试：\n"),
                                       JournalTemplate(name: "晨跑", body: "【距离】\n\n【配速】\n\n【体感】\n")], defaults)
        }
        let readingNote = "【书名】《瓦尔登湖》\n\n【摘句】\n\n【所思】慢慢读，比读得多要紧。\n"
        let sheets: [(String, AnyView)] = [
            ("event-new", AnyView(EventEditor(event: nil, defaultDay: .today(), defaultStart: 9 * 60))),
            ("event-edit", AnyView(EventEditor(event: event, defaultDay: .today(), defaultStart: nil))),
            ("habit", AnyView(HabitEditor(habit: habit, nextSortOrder: 0))),
            ("routine", AnyView(RoutineEditor(group: nil))),
            ("goal", AnyView(GoalEditor(goal: goal))),
            ("journal", AnyView(Group { if let entry { JournalEditSheet(entry: entry) } })),
            ("journal-read", AnyView(Group { if let entry { JournalEditSheet(entry: entry, startReadOnly: true) } })),
            ("expense", AnyView(ManualExpenseSheet())),
            ("transaction", AnyView(Group { if let row { TransactionEditor(row: row) } })),
            ("finance-import", AnyView(FinanceImportSheet())),
            ("finance-sources", AnyView(FinanceSourcesSheet())),
            ("finance-rules", AnyView(FinanceRulesSheet())),
            ("finance-saved", AnyView(Group { if let report { FinanceSavedReportSheet(report: report, stale: false) } })),
            ("calendar", AnyView(MonthCalendar(selection: Binding(get: { day }, set: { day = $0 })) {})),
            ("time", AnyView(TimeGrid(minutes: Binding(get: { minute }, set: { minute = $0 })) {})),
            ("search", AnyView(GlobalSearchView())),
            ("export", AnyView(JournalExportSheet(filtered: context.all(JournalEntry.self), all: context.all(JournalEntry.self), filterDescription: ""))),
            ("quick", AnyView(QuickCaptureView(onDone: {}))),
            ("weekly", AnyView(WeeklyScrollSheet())),
            ("tpl-save", AnyView(JournalTemplateSaveSheet(templateBody: readingNote) { _ in })),
            ("tpl-manage", AnyView(JournalTemplateSheet())),
        ]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (label, view) in sheets {
                let root = view
                    .yunshanSheet()
                    .environment(EffectsCenter())
                    .environment(\.spiritMotion, false)
                    .modelContainer(container)
                    .defaultAppStorage(defaults)
                let host = NSHostingView(rootView: root)
                host.frame = CGRect(origin: .zero, size: CGSize(width: 900, height: 900))
                host.layoutSubtreeIfNeeded()
                let fitting = host.fittingSize
                host.frame = CGRect(origin: .zero, size: CGSize(width: max(320, fitting.width), height: max(200, min(1100, fitting.height))))
                // 无边框窗口：带标题栏时宿主视图按标题栏的安全区多出一条，弹窗图顶部一条黑、底部被裁
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("sheet-\(name)-\(label).png"))
                    print("已渲染 sheet-\(name)-\(label).png")
                }
                window.close()
            }
        }
    }

    /// 特效定格：传书笺（深色；名字以 -light 结尾的是浅色）。与仪式定格同一个思路，不等动画：先渲染今日洞府底图，
    /// 再把展开好的传书笺（CourierStills.card：与窗口里同一张笺、同一处位置）叠上去截图。以前是放出传书后固定等 2 秒再截，
    /// 离屏窗口没有显示刷新的时钟，笺的滑入转场走不完，数据多或窗口窄时截到的是空白或滑到半路的笺。
    /// 六种：演示传书（目标细进度条停在终值）、只含目标的（涨满、“达成”签）、第一次点“撤销此书”后的说明、撤销结果、
    /// 部分收录（一条打卡按条退回：副标题“· 1 条未收”，那行警示色、排在最后）、一轮收到两封（其中一封部分收录）。
    /// 渡劫、落印、飞剑由 renderRituals 按时间函数摆好再截。
    private static func renderEffects(container: ModelContainer, directory: URL) {
        // 撤销说明与结果（混合传书）：删记录、恢复档案字段和目标、保留改过的日记、接一条保留原因（与 RootView 传书笺上的说法同一套）
        let note = "习惯「晨跑」已有 3 条打卡，撤销时保留（要删请到「每日功课」里删）"
        let plan = CourierUndoWording.Plan(records: 2, editedRecords: 1, fields: 1, goals: 1, notes: [note])
        let result = EffectsCenter()
        result.courierUndoResult(CourierUndoReport(removed: 3, keptEdited: 1, failure: nil, restored: 1, restoredGoals: 1, notes: [note]))
        var cards: [(String, EffectsCenter.CourierNotice, String?)] = [
            ("courier-card", courierDemo, nil),
            ("courier-card-goal", courierGoalDemo, nil),
            ("courier-card-undo", courierMixedDemo, "再点一次即撤销：" + CourierUndoWording.cardPreview(plan)),
        ]
        if let undone = result.courier { cards.append(("courier-card-undone", undone, nil)) }
        if let partial = courierPartialDemo { cards.append(("courier-card-partial", partial, nil)) }
        if let batch = courierBatchDemo { cards.append(("courier-card-batch", batch, nil)) }
        for dark in [true, false] {
            guard let shot = snapshot(.overview, dark: dark, container: container) else { continue }
            for (label, notice, armed) in cards {
                write(still(CourierStills.card(notice, armedDetail: armed), over: shot, dark: dark),
                      "effect-\(label)\(dark ? "" : "-light").png", to: directory)
            }
        }
    }

    /// 在整窗截图上叠一层 SwiftUI 画面，整体再截一张。放进带外观的离屏窗口里画（不用 ImageRenderer），
    /// 主题里随深浅色变的颜色才按这个窗口的外观取色；特效按开着动效画（传书笺的灵光描边）
    private static func still(_ view: some View, over shot: (rep: NSBitmapImageRep, size: CGSize), dark: Bool) -> NSBitmapImageRep? {
        let image = NSImage(size: shot.size)
        image.addRepresentation(shot.rep)
        let root = ZStack {
            Image(nsImage: image).resizable()
            view
        }
        .frame(width: shot.size.width, height: shot.size.height)
        .ignoresSafeArea()
        .environment(\.spiritMotion, true)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: shot.size)
        // 无边框窗口：带标题栏时宿主视图会按标题栏的安全区多出一条（约 28pt），整张图顶部一条黑、内容整体下移
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// 演示传书的日子（10月21日写入、22日看）：目标与新习惯的行用传书收录时同一个函数写（CourierLineDecor），不换行空格也照真的来
    private static let demoDay = LocalDay(year: 2026, month: 10, day: 22)
    private static func demoHabitLine(_ title: String, target: Double?, unit: String) -> String {
        CourierLineDecor.habitCreateLine(CourierHabit(title: title, frequency: .daily, timesPerWeek: 1, weekdays: [], target: target, unit: unit,
                                                      startDay: LocalDay(year: 2026, month: 10, day: 21), category: "", symbol: "", notes: ""),
                                         today: demoDay)
    }

    /// 演示传书笺：目标更新（下面衬细进度条）+ 新习惯 + 打卡（设计稿 P2 §1.1 的样例）
    private static var courierDemo: EffectsCenter.CourierNotice {
        let lines = [CourierLineDecor.goalUpdateLine(title: "完成学位论文初稿", changes: [.progress(60, 65), .note("第三章初稿完成")], today: demoDay),
                     demoHabitLine("冥想", target: 10, unit: "分钟"), "打卡 · 10月21日 · 冥想"]
        return .init(title: "飞剑传书", detail: "来自 Claude · 收录 3 条", lines: lines, deliveryID: "demo", failed: false,
                     symbol: CourierLineDecor.symbol(lines), openPage: CourierLineDecor.page(lines))
    }

    /// 只含目标的传书笺：一个目标涨满 100%（掠光、“达成”签），一个照常涨
    private static var courierGoalDemo: EffectsCenter.CourierNotice {
        let lines = [CourierLineDecor.goalUpdateLine(title: "存下三个月生活费的应急金", changes: [.progress(80, 100), .status("active", "completed")], today: demoDay),
                     CourierLineDecor.goalUpdateLine(title: "完成学位论文初稿", changes: [.progress(60, 65), .note("第三章初稿完成")], today: demoDay)]
        return .init(title: "飞剑传书", detail: "来自 Claude · 收录 2 条", lines: lines, deliveryID: "demo", failed: false,
                     symbol: CourierLineDecor.symbol(lines), openPage: CourierLineDecor.page(lines))
    }

    /// 混合传书笺（看撤销说明用）：日记、档案、目标更新、新习惯、打卡各一条
    private static var courierMixedDemo: EffectsCenter.CourierNotice {
        let lines = ["日记 · 10月21日 · 下午把实验部分的图重画了一遍，终于顺眼。", "档案 · 主要任务：写论文；健身",
                     CourierLineDecor.goalUpdateLine(title: "完成学位论文初稿", changes: [.progress(60, 65)], today: demoDay),
                     demoHabitLine("晨跑", target: nil, unit: ""), "打卡 · 10月21日 · 晨跑"]
        return .init(title: "飞剑传书", detail: "来自 Claude · 收录 5 条", lines: lines, deliveryID: "demo", failed: false,
                     symbol: CourierLineDecor.symbol(lines), openPage: CourierLineDecor.page(lines))
    }

    /// 部分收录的传书：午饭照收、“跑步”按同类说法记到「运动」，“弹琴”对不上任何功课按条退回。
    /// 走 EffectsCenter.courierArrived（与窗口里收到传书时同一套接线），摘要行用传书收录时的写法
    private static var courierPartialDemo: EffectsCenter.CourierNotice? {
        let effects = EffectsCenter()
        effects.courierArrived(partialDelivery(from: "Claude"))
        return effects.courier
    }

    /// 一轮巡查收到两封（其中一封部分收录）：每封一行，部分收录的那封冒号前注“1 条未收”，副标题合计（EffectsCenter.courierBatch）
    private static var courierBatchDemo: EffectsCenter.CourierNotice? {
        let today = LocalDay.today()
        let diary = CourierDelivery(fileName: "demo-diary.json", from: "Claude", note: "")
        diary.itemCount = 1
        diary.summary = CourierItem.entry(kind: .diary, day: today, minute: nil, title: "", body: "下午把实验部分的图重画了一遍，终于顺眼。",
                                          mood: 4, period: "", tags: []).summary
        let effects = EffectsCenter()
        effects.courierBatch(deliveries: [partialDelivery(from: "Claude"), diary], failures: [])
        return effects.courier
    }

    private static func partialDelivery(from: String) -> CourierDelivery {
        let today = LocalDay.today()
        let delivery = CourierDelivery(fileName: "demo-partial.json", from: from, note: "")
        delivery.itemCount = 2
        delivery.summary = [
            CourierItem.expense(day: today, cents: 1800, category: "餐饮与外卖", description: "午饭", note: "未说明支付方式").summary,
            CourierItem.checkin(habit: "运动", day: today, quantity: nil).summary,
            CourierLineDecor.skippedLine("打卡「弹琴」：没有这项功课"),
        ].joined(separator: "\n")
        return delivery
    }

    /// 渲染一张整窗（RootView）：返回位图与窗口内容的尺寸（点）。锚点（落笔框、修行录、境界徽记、落印按钮）登记在 effects 里
    private static func snapshot(_ page: AppSection, dark: Bool, container: ModelContainer,
                                 effects: EffectsCenter = EffectsCenter()) -> (rep: NSBitmapImageRep, size: CGSize)? {
        let root = RootView(initialSelection: page, effects: effects).modelContainer(container).defaultAppStorage(defaults)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return (rep, host.bounds.size)
    }

    private static func write(_ rep: NSBitmapImageRep?, _ name: String, to directory: URL) {
        guard let png = rep?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent(name))
        print("已渲染 \(name)")
    }

    /// 天色：今日洞府在 06:15 / 12:00 / 18:00 / 23:00 × 浅 / 深色各一张（sky-light-dawn.png … sky-dark-night.png）
    private static func renderSky(container: ModelContainer, directory: URL) {
        let saved = SkyTime.fixedMinute
        defer { SkyTime.fixedMinute = saved }
        for (name, dark) in [("light", false), ("dark", true)] {
            for (minute, phase) in [(375, "dawn"), (720, "day"), (1080, "dusk"), (1380, "night")] {
                SkyTime.fixedMinute = Double(minute)
                write(snapshot(.overview, dark: dark, container: container)?.rep, "sky-\(name)-\(phase).png", to: directory)
            }
        }
    }

    /// 仪式定格：先渲染深色、浅色首页底图，再按那次渲染登记的锚点把落笔入卷、功课圆满、朱印摆到指定时刻叠上去；
    /// 渡劫用 TribulationScene.still 摆到 0.3 / 1.2 / 3.2 秒、飞剑摆到 0.55 秒，叠在深色首页上；另有随手记浮窗里的小印。
    /// 都不等动画（离屏窗口没有显示刷新的时钟，动画不往前走），而是用同一套时间函数直接摆到那一刻
    private static func renderRituals(container: ModelContainer, directory: URL) {
        for dark in [true, false] {
            let effects = EffectsCenter()
            guard let shot = snapshot(.overview, dark: dark, container: container, effects: effects) else { continue }
            RitualStills.write(over: shot.rep, size: shot.size, dark: dark, anchors: effects.ritualAnchors.mapValues(\.rect),
                               seal: effects.sealAnchor?.rect, to: directory, prefix: dark ? "effect-" : "effect-light-")
            guard dark else { continue }
            // 金雨 2.4 秒才开始淡入（0.6 秒），那一刻还看不见：定格取 3.2 秒（“点击任意处或按 Esc 继续”也已出现）
            for (label, elapsed) in [("strike", 0.3), ("pillar", 1.2), ("blessing", 3.2)] {
                let scene = TribulationScene.still(realm: "元婴", emblem: RealmBadge.emblem(for: 3), elapsed: elapsed)
                write(RitualStills.overlay(scene, on: shot.rep, size: shot.size, dark: true), "effect-tribulation-\(label).png", to: directory)
            }
            let calm = StaticBreakthrough(realm: "元婴", emblem: RealmBadge.emblem(for: 3))
            write(RitualStills.overlay(calm, on: shot.rep, size: shot.size, dark: true), "effect-tribulation-static.png", to: directory)
            write(RitualStills.overlay(CourierStills.flight(elapsed: 0.55), on: shot.rep, size: shot.size, dark: true),
                  "effect-courier-flight.png", to: directory)
        }
        // 菜单栏随手记：浮窗里就地盖的小印（0.6 秒，落定之后）
        for dark in [false, true] {
            let view = QuickCaptureView(onDone: {})
                .environment(\.spiritMotion, false)
                .modelContainer(container)
                .defaultAppStorage(defaults)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            func find(_ view: NSView) -> MiniSealHostView? {
                (view as? MiniSealHostView) ?? view.subviews.lazy.compactMap(find).first
            }
            find(host)?.pose("入卷", at: 0.6)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                write(rep, "effect-\(dark ? "" : "light-")quick-seal.png", to: directory)
            }
            window.close()
        }
    }

    /// 往渲染用的内存库里放数据：APT_RENDER_EMPTY（全空）> APT_RENDER_DEMO（演示数据）> 导入旧版数据库 + 示例数据（NOSEED 时不加示例），
    /// 最后按 APT_RENDER_ADVICE 加两条参悟记录。自检也用它核对“全空”真的一条记录都没有
    static func prepareData(_ context: ModelContext, env: [String: String], legacyPath: String) {
        if emptyRequested(env) {
            // 全新使用者：不读旧版数据库、不加示例数据（档案与设置是应用启动时本来就会建的空白两份）
        } else if !seedDemoIfRequested(context, env: env) {
            if let snapshot = try? LegacyReader.read(url: URL(fileURLWithPath: legacyPath)) {
                _ = LegacyImporter.run(snapshot, context: context, dryRun: false)
            }
            // APT_RENDER_NOSEED=1：不加示例数据（旧版数据库里有的日程、档案、账目照样导入）
            if env["APT_RENDER_NOSEED"] != "1" { seedSamples(context) }
        }
        if env["APT_RENDER_ADVICE"] == "1" { seedAdvice(context) }
    }

    /// APT_RENDER_EMPTY=1（仅调试版）：完全空的内存库，看全新使用者的空状态。
    /// APT_RENDER_NOSEED 只是不加示例数据，旧版数据库仍会导入（本机有旧版数据时时辰卷、账簿、名帖都不空）
    static func emptyRequested(_ env: [String: String]) -> Bool {
        #if DEBUG
        return env["APT_RENDER_EMPTY"] == "1"
        #else
        return false
        #endif
    }

    /// APT_RENDER_DEMO=<年数> 或 <天数>d（仅调试版）：用 DemoSeeder 在内存库里造演示数据，返回是否造了（造了就不再导入旧版数据库和示例习惯）
    private static func seedDemoIfRequested(_ context: ModelContext, env: [String: String]) -> Bool {
        #if DEBUG
        guard let scale = DemoSeeder.Scale(env["APT_RENDER_DEMO"]) else { return false }
        DemoSeeder.seed(into: context, scale: scale).lines.forEach { print($0) }
        return true
        #else
        return false
        #endif
    }

    /// 两条参悟记录（一条记了决定）：问道页的“参悟记录”卡
    private static func seedAdvice(_ context: ModelContext) {
        context.insert(AdviceRecord(title: "10月13日 · 周复盘", summary: "示例摘要", response: "示例回复：先把上午的 90 分钟留给论文。"))
        let decided = AdviceRecord(title: "为什么这周总是拖到很晚才开始写论文？", summary: "示例摘要", response: "示例回复")
        decided.decision = "上午先写 90 分钟"
        context.insert(decided)
        DataStore.save(context)
    }

    private static func seedSamples(_ context: ModelContext) {
        let today = LocalDay.today()
        let samples: [(String, String, HabitFrequency, Int, [Int])] = [
            ("晨读二十分钟", "book", .daily, 1, [1, 2, 3, 4, 6, 7, 8, 9, 10, 12, 13, 15]),
            ("运动", "figure.run", .weekly, 3, [1, 3, 6, 8, 10, 13, 15, 17]),
            ("论文写作", "pencil.and.scribble", .weekdays, 1, [1, 2, 6, 7, 8, 9, 13]),
        ]
        for (index, sample) in samples.enumerated() {
            let habit = Habit(title: sample.0)
            habit.symbol = sample.1
            habit.frequencyKind = sample.2
            habit.targetPerWeek = sample.3
            habit.weekdays = sample.2 == .weekdays ? [0, 1, 2, 3, 4] : []
            habit.startDate = today.adding(days: -40).key
            habit.sortOrder = index
            context.insert(habit)
            for offset in sample.4 {
                let log = HabitLog(dateKey: today.adding(days: -offset).key)
                context.insert(log)
                log.habit = habit
            }
        }
        for item in RoutineTemplate.student {
            for day in item.weekdays {
                context.insert(RoutineBlock(title: item.title, kind: item.kind.rawValue, weekday: day, startMinute: item.start, endMinute: item.end))
            }
        }
        let journal: [(JournalKind, Int, Int?, String, String, Int?, String, [String], Bool)] = [
            (.diary, 0, 21 * 60 + 40, "第三章收尾", "下午把实验部分的图重画了一遍，终于顺眼。晚上和导师对了一下结构，第三章可以收尾了。有点累，但心里踏实。", 4, "", ["论文", "写作"], false),
            (.note, 0, 15 * 60 + 5, "", "读到一句话：先完成，再完美。做研究也一样，先把骨架立起来，细节在第二遍里长出来。", nil, "", ["读书"], true),
            (.review, 1, 22 * 60, "第 41 周复盘", "【所得】论文写了 6000 字；运动 3 次。\n【所失】周三熬夜，周四状态很差。\n【所悟】晚上 11 点后的产出几乎都要重写。\n【下一步】23:30 前收工；每天上午先写 90 分钟。", nil, "week", ["复盘"], false),
            (.diary, 2, 23 * 60 + 10, "", "补习的学生终于把导数弄明白了，讲第三遍的时候换了个比喻，他眼睛一下子亮了。", 5, "", ["教学"], false),
            (.diary, 4, nil, "", "下雨，没出门。读了半本书，整个人很平静。", 3, "", [], false),
            (.note, 5, nil, "灵石账簿的想法", "每月月底花十分钟看一眼大类支出，比每天记账更容易坚持。", nil, "", ["理财"], true),
            (.diary, 7, nil, "", "睡太晚，一整天都没精神。", 2, "", [], false),
        ]
        for item in journal {
            let entry = JournalEntry(kind: item.0, title: item.3, body: item.4, dateKey: today.adding(days: -item.1).key)
            entry.minute = item.2
            entry.mood = item.5
            entry.period = item.6
            entry.tags = item.7
            if item.8 {
                entry.source = "courier"
                entry.sourceNote = "Claude"
            }
            context.insert(entry)
        }
        let delivery = CourierDelivery(fileName: "sample.json", from: "Claude", note: "")
        delivery.itemCount = 2
        delivery.summary = "灵感 · 示例"
        context.insert(delivery)
        let goal = Goal(title: "完成 Thesis 初稿")
        goal.progress = 40
        goal.category = "学业"
        goal.targetDate = today.adding(days: 45).key
        context.insert(goal)
        DataStore.save(context)
    }
}
