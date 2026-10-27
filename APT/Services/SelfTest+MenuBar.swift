import SwiftUI
import SwiftData
import AppKit
import Carbon.HIToolbox

// 菜单栏小窗（#6）的运行时自检：真 SwiftData、内存库、自己的特效中心，不写正式偏好、不弹任何窗口、不碰系统通知。
// 列几项、步长、倒计时、标题行这些说法在 Tools/CoreCheck（// MARK: r1-menubar）里测；这里测接上数据库的那一段：
// 修为模型的统计 → 小窗的功课签、“+1”真的记进库、签在达标前后同宽（不在指针底下挪位）、今日已落只数今天、
// 日程展开后的下一项、整扇小窗排得出来、记完收起只收自己那扇窗（自动收起前点过上半段就不收、Esc 照常收）、
// 底栏那一句、去主窗口的跳转请求。真窗口里点菜单栏图标、记完自动收起、Esc 收起要人手试（“待真窗口验证”）。
// 签挪不挪、“功课圆满”写在哪，另有离屏连拍：APT_RENDER_ONLY=menubar-session（light-menubar-s0…s3.png）。

extension SelfTest {
    static func menuBarChecks(_ check: (Bool, String) -> Void) throws {
        let today = LocalDay.today()
        let container = try DataStore.makeContainer(inMemory: true)
        let context = container.mainContext
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        func habit(_ title: String, _ order: Int, target: Double? = nil, unit: String = "", weekly: Bool = false) -> Habit {
            let h = Habit(title: title)
            h.frequencyKind = weekly ? .weekly : .daily
            h.targetPerWeek = weekly ? 3 : 1
            h.targetValue = target
            h.unit = unit
            h.startDate = today.adding(days: -20).key
            h.sortOrder = order
            context.insert(h)
            return h
        }
        let meditate = habit("小窗自检冥想", 0, target: 10, unit: "分钟")
        let water = habit("小窗自检喝水", 1, target: 8, unit: "杯")
        _ = habit("小窗自检运动", 2, weekly: true)
        let sleep = habit("小窗自检早睡", 3)
        let shelved = habit("小窗自检归档", 4)
        shelved.archived = true
        shelved.archivedAt = today.adding(days: -2).key
        DataStore.save(context)
        let effects = EffectsCenter()
        effects.motionEnabled = false
        let config = CultivationConfig()
        HabitActions.toggle(sleep, on: today, context: context, effects: effects, allHabits: context.all(Habit.self), config: config)

        // 1. 修为模型的统计 → 小窗的功课签：归档的不列；早睡已打卡收进“已圆满”；其余按原次序列成签
        let model = CultivationModel.shared(for: context)
        model.refresh()
        func plan(keep: Set<PersistentIdentifier> = []) -> (MenuBarDigest.HabitPlan, [MenuBarDigest.HabitItem]) {
            let items = MenuBarSupport.items(model.rows, today: today, keep: keep)
            return (MenuBarDigest.plan(items), items)
        }
        let (first, items) = plan()
        check(first.state == .chips && first.chips.map { items[$0].title } == ["小窗自检冥想", "小窗自检喝水", "小窗自检运动"]
              && first.doneTitles == ["小窗自检早睡"] && first.done == 1 && first.due == 4 && !items.contains { $0.title == "小窗自检归档" },
              "菜单栏小窗：未圆满的按原次序列成签（\(first.chips.map { items[$0].title })），已打卡的收进“已圆满”，归档的不列")
        check(items[1].target == 8 && items[1].unit == "杯" && items[2].target == nil,
              "菜单栏小窗：数量型带目标与单位（喝水 8 杯），布尔型没有目标")

        // 2. “+1”：按点的那一刻库里今天已记的数量加一步，走 HabitActions（修为、圆满照常），统计随之更新
        let one = MenuBarSupport.addStep(water, step: MenuBarDigest.step(target: 8), context: context, effects: effects,
                                         allHabits: model.habits, config: model.config)
        let two = MenuBarSupport.addStep(water, step: 1, context: context, effects: effects, allHabits: model.habits, config: model.config)
        model.refresh()
        let waterLog = HabitDayLogs(day: today, context: context).log(of: water)
        let (afterWater, waterItems) = plan()
        check(one == 1 && two == 2 && waterLog?.quantity == 2 && waterItems[1].quantity == 2 && !waterItems[1].achieved
              && MenuBarDigest.progress(quantity: waterItems[1].quantity, target: 8, unit: "杯") == "2/8 杯"
              && afterWater.chips.contains(1),
              "菜单栏小窗：喝水点两次 +1 记成 2 杯（库里 \(waterLog?.quantity.map { MenuBarDigest.number($0) } ?? "无")），签上写“2/8 杯”，仍在签里")
        // 统计还没刷新时（例如别处刚改过）也按库里的数接着加，不按旧统计
        HabitActions.setQuantity(meditate, on: today, quantity: 9, context: context, effects: effects, allHabits: model.habits, config: model.config)
        effects.toasts.removeAll()
        let ten = MenuBarSupport.addStep(meditate, step: MenuBarDigest.step(target: 10), context: context, effects: effects,
                                         allHabits: model.habits, config: model.config)
        model.refresh()
        let meditateID = model.rows.first { $0.habit === meditate }?.id
        check(ten == 10 && model.rows.first { $0.habit === meditate }?.stats.isAchieved(today) == true
              && effects.toasts.contains { $0.text.hasSuffix("修为") },
              "菜单栏小窗：冥想 9 → +1 记成 10 分钟、当场达标，“+修为”飘在传进来的特效中心（小窗自己那份）里")

        // 3. 刚在小窗里打上卡的签留在原位（下次打开才收进“已圆满”）
        let kept = plan(keep: Set([meditateID].compactMap { $0 }))
        let fresh = plan()
        check(kept.0.chips.first.map { kept.1[$0].title } == "小窗自检冥想" && kept.1[0].achieved && !kept.0.doneTitles.contains("小窗自检冥想")
              && !fresh.0.chips.contains(0) && fresh.0.doneTitles == ["小窗自检冥想", "小窗自检早睡"] && fresh.0.done == 2,
              "菜单栏小窗：刚打上卡的冥想留在原位（圈变实心），下次打开收进“已圆满：冥想、早睡”")

        // 3b. 签的宽度在这次打开期间不变：数量型达标前后（“+1”换成同宽的 ✓）、数字从 0 记到 1000 都同宽，后面的签不挪
        if let row = model.rows.first(where: { $0.habit === water }) {
            func width(_ item: MenuBarDigest.HabitItem) -> CGFloat {
                let chip = MenuBarHabitChip(row: row, item: item, allHabits: model.habits, config: model.config, motion: false)
                    .environment(effects).modelContainer(container)
                return NSHostingView(rootView: chip).fittingSize.width
            }
            var cup = MenuBarDigest.HabitItem(title: "喝水", due: true, achieved: false, quantity: 7, target: 8, unit: "杯")
            let open = width(cup)
            cup.quantity = 8
            cup.achieved = true
            cup.keepShown = true
            let reached = width(cup)
            var walk = MenuBarDigest.HabitItem(title: "步数", due: true, achieved: false, quantity: nil, target: 8000, unit: "步")
            let zero = width(walk)
            walk.quantity = 1000
            let thousand = width(walk)
            walk.quantity = 8000
            walk.achieved = true
            let walked = width(walk)
            check(open > 60 && abs(open - reached) < 0.5 && abs(zero - thousand) < 0.5 && abs(zero - walked) < 0.5,
                  "菜单栏小窗：签在这次打开期间同宽——喝水 7/8 与达标后 \(Int(open)) / \(Int(reached)) pt，步数 0、1000、8000 \(Int(zero)) / \(Int(thousand)) / \(Int(walked)) pt")
        } else {
            check(false, "菜单栏小窗：修为模型里找不到喝水，签宽没测")
        }

        // 4. 今日已落只数今天的（按 dateKey 谓词取，不挂全部修行录）
        context.insert(JournalEntry(kind: .diary, body: "小窗自检昨天", dateKey: today.adding(days: -1).key))
        context.insert(JournalEntry(kind: .diary, body: "小窗自检今天一", dateKey: today.key))
        context.insert(JournalEntry(kind: .note, body: "小窗自检今天二", dateKey: today.key))
        DataStore.save(context)
        let todayCount = (try? context.fetchCount(MenuBarSupport.todayEntries(today.key))) ?? -1
        check(todayCount == 2 && MenuBarDigest.summary(done: fresh.0.done, due: fresh.0.due, entries: todayCount) == "功课 2/4 · 已落 2 篇",
              "菜单栏小窗：标题行“功课 2/4 · 已落 2 篇”（昨天那篇不算；今天 \(todayCount) 篇）")

        // 5. 下一项：日程按与首页同一套取数、展开，只看今天；作息不算
        func event(_ title: String, _ day: LocalDay, _ start: Int?, _ end: Int?) {
            let e = ScheduleEvent(title: title, dateKey: day.key)
            e.startMinute = start
            e.endMinute = end
            context.insert(e)
        }
        event("小窗自检早会", today, 9 * 60, 10 * 60)
        event("小窗自检组会", today, 14 * 60, 15 * 60)
        event("小窗自检交报告", today, nil, nil)
        event("小窗自检明日", today.adding(days: 1), 8 * 60, 9 * 60)
        context.insert(RoutineBlock(title: "小窗自检午饭", kind: "meal", weekday: today.weekdayIndex, startMinute: 12 * 60, endMinute: 13 * 60))
        DataStore.save(context)
        let events = (try? context.fetch(FetchDescriptor(predicate: Occurrences.candidates(from: today, to: today)))) ?? []
        let slots = MenuBarSupport.slots(Occurrences.list(events: events, from: today, to: today), today: today)
        let at10 = MenuBarDigest.nextLine(slots, now: 10 * 60)
        let at1430 = MenuBarDigest.nextLine(slots, now: 14 * 60 + 30)
        let at16 = MenuBarDigest.nextLine(slots, now: 16 * 60)
        check(slots.count == 3 && at10 == .init(label: "下一项", text: "14:00–15:00 小窗自检组会", detail: "还有 4 时")
              && at1430 == .init(label: "进行中", text: "14:00–15:00 小窗自检组会", detail: "还剩 30 分")
              && at16 == .init(label: "今日全天", text: "小窗自检交报告", detail: ""),
              "菜单栏小窗：下一项只看今天的日程（作息、明天的不算）：10:00 “\(at10.text) · \(at10.detail)”，14:30 进行中，16:00 只剩全天")

        // 6. 整扇小窗排得出来（宽 460；不另给特效中心也不缺环境：小窗自己注入），不弹窗、不显示
        func fitted(_ c: ModelContainer) -> CGSize {
            let host = NSHostingView(rootView: MenuBarPanel().modelContainer(c).defaultAppStorage(AppPreferences.defaults))
            host.frame = CGRect(x: 0, y: 0, width: 460, height: 640)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        let full = fitted(container)
        let emptyContainer = try DataStore.makeContainer(inMemory: true)
        DataStore.settings(in: emptyContainer.mainContext)
        DataStore.profile(in: emptyContainer.mainContext)
        let empty = fitted(emptyContainer)
        check(abs(full.width - 460) < 0.5 && full.height > 320 && full.height < 900 && abs(empty.width - 460) < 0.5 && empty.height > 280
              && full.height > empty.height,
              "菜单栏小窗：排得出来，宽 460；有功课时 \(Int(full.height)) pt、全新的库 \(Int(empty.height)) pt")

        // 7. 记完 / Esc 收起只收小窗自己所在的那扇窗：读取器报上来的就是它；窗口没显示时不去关（离屏、自检都不会真的关窗）
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        var reported: NSWindow?
        window.contentView = NSHostingView(rootView: Color.clear.background(MenuBarWindowReader { reported = $0 }))
        window.contentView?.layoutSubtreeIfNeeded()
        let handle = MenuBarWindowHandle()
        handle.window = reported
        handle.close()
        handle.endSession()
        check(reported === window && handle.window === window && !window.isVisible && handle.session == 0,
              "菜单栏小窗：收起时找的是小窗自己那扇窗；没显示过的窗不关、不算一轮")
        // 记完后的自动收起：自动收起前点过上半段（打卡圈、+1）就不收；Esc 照常收；过了这一小会儿、或下一次打开，照常收
        let clicked = Date()
        let untouched = handle.captureFinished(escape: false, now: clicked)
        handle.noteTopAction(at: clicked)
        let afterClick = handle.captureFinished(escape: false, now: clicked.addingTimeInterval(0.8))
        let afterClickEsc = handle.captureFinished(escape: true, now: clicked.addingTimeInterval(0.8))
        let later = handle.captureFinished(escape: false, now: clicked.addingTimeInterval(MenuBarDigest.autoCloseGrace + 1))
        handle.endSession()
        let nextOpen = handle.captureFinished(escape: false, now: clicked.addingTimeInterval(0.8))
        check(untouched && !afterClick && afterClickEsc && later && nextOpen && handle.lastTopAction == nil,
              "菜单栏小窗：记完自动收起前点过打卡圈 / +1 就不收（\(afterClick ? "收了" : "不收")），按 Esc 照常收，过后、下次打开照常收")
        // 是不是 Esc：只认小窗这扇窗里按下的 Esc（或 ⌘.）；记完后延时收起时眼下的事件是 ⌘↩、点按，不算
        func key(_ code: Int, _ flags: NSEvent.ModifierFlags = [], window number: Int) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: number, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code))
        }
        let esc = key(kVK_Escape, window: window.windowNumber)
        let cmdPeriod = key(kVK_ANSI_Period, .command, window: window.windowNumber)
        let cmdReturn = key(kVK_Return, .command, window: window.windowNumber)
        let elsewhere = key(kVK_Escape, window: window.windowNumber + 1)
        check(MenuBarSupport.isEscape(esc, in: window) && MenuBarSupport.isEscape(cmdPeriod, in: window)
              && !MenuBarSupport.isEscape(cmdReturn, in: window) && !MenuBarSupport.isEscape(elsewhere, in: window)
              && !MenuBarSupport.isEscape(nil, in: window),
              "菜单栏小窗：小窗里的 Esc、⌘. 算收起；⌘↩、别的窗口里的 Esc、没有事件都不算")
        window.close()

        // 7b. 底栏：快捷键注册上了说“按 ⌥⌘J 也能随手记”；被占用了不说按它，改说在这里随手记（浅墨小字，不用警示色）
        let key = KeyCommand.quickCapture.display
        check(MenuBarSupport.footerHint(hotKeyFailed: false) == "在别的应用里按 \(key)，也能随手记"
              && MenuBarSupport.footerHint(hotKeyFailed: true) == "\(key) 被别的应用占用，可在这里随手记",
              "菜单栏小窗底栏：“\(MenuBarSupport.footerHint(hotKeyFailed: true))”")

        // 8. 去主窗口：只交给路由（主窗口在时 RootView 切页，关着时重新打开后补上）；自检不去真的打开主窗口
        let previous = AppRouter.shared.page
        MenuBarSupport.request(.habits)
        check(AppRouter.shared.page == .habits, "菜单栏小窗：“立一项 →”请主窗口切到每日功课")
        AppRouter.shared.page = previous
    }
}
