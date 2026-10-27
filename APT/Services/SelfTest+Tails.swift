import AppKit
import SwiftData
import SwiftUI

// MARK: - r3-tails：几处收尾
// 1. 菜单栏小窗的“3/8 杯”“+1”直接用首页的 DashboardRules（步长、按钮字、悬停里的“再记 5 分钟”）；
// 2. 小窗里点打卡圈弹出数量输入框也算“刚点过上半段”：在上半段那一块按下鼠标（左键、右键）记一笔，
//    数量输入框（挂在小窗上的小气泡）开着时记完也不自动收起；按在下半段随手记里、别的窗口里不算；
// 3. 日程弹窗 680 → 752、目标弹窗 560 → 620，都在 1180×780 的窗口里放得下；
// 4. 岁月长卷逐月柱刻度下标、导出的逐月表与灵石账簿同一个说法“未导全”（Core 的 PartialMonthRule）。
// 写法逐个相同、刻度下标的规矩在 Tools/CoreCheck 的 r3-tails 一节核对；这里测要用到窗口、事件与界面布局的部分。

extension SelfTest {
    static func tailsChecks(_ check: (Bool, String) -> Void) throws {
        // 1. 小窗签上的写法就是首页那一套
        let water = MenuBarHabitChip.step(target: 8, unit: "杯")
        let focus = MenuBarHabitChip.step(target: 30, unit: "分钟")
        let steps = MenuBarHabitChip.step(target: 8000, unit: "步")
        let bare = MenuBarHabitChip.step(target: 3, unit: " ")
        check(water == (1, "+1", "1 杯") && focus == (5, "+5", "5 分钟") && steps == (1000, "+1000", "1000 步") && bare == (1, "+1", "1")
              && water.label == DashboardRules.stepLabel(DashboardRules.quantityStep(target: 8)),
              "菜单栏小窗 +1：步长、按钮字、悬停“再记 5 分钟”都用首页 DashboardRules（8 杯 +1、30 分钟 +5、8000 步 +1000）")
        let progress = [MenuBarHabitChip.progress(quantity: nil, target: 8, unit: "杯"), MenuBarHabitChip.progress(quantity: 2.5, target: 8, unit: "杯"),
                        MenuBarHabitChip.progress(quantity: 1000, target: 8000, unit: "步"), MenuBarHabitChip.progress(quantity: 3, target: 8, unit: "")]
        check(progress == ["0/8 杯", "2.5/8 杯", "1000/8000 步", "3/8"]
              && progress[1] == DashboardRules.quantityText(done: 2.5, target: 8, unit: "杯"),
              "菜单栏小窗“3/8 杯”与首页功课卡同一个写法（没记过写 0、小数去掉末尾的 0）：\(progress)")

        // 2. 数量输入框开着、或刚在上半段按过鼠标：记完不自动收起；Esc 照常收
        let bareHandle = MenuBarWindowHandle()
        let withPopover = bareHandle.captureFinished(escape: false, popoverOpen: true)
        let escWithPopover = bareHandle.captureFinished(escape: true, popoverOpen: true)
        let noPopover = bareHandle.captureFinished(escape: false, popoverOpen: false)
        check(!withPopover && escWithPopover && noPopover && bareHandle.lastTopAction == nil,
              "菜单栏小窗：打卡圈弹出的数量输入框还开着时，记完不自动收起（\(withPopover ? "收了" : "不收")）；按 Esc 照常收；没开着照常收")

        // 小窗这扇窗（不显示）：上半一块是上半段，下半是随手记。鼠标按在哪里才算点过上半段
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 460, height: 400))
        let top = NSView(frame: CGRect(x: 0, y: 220, width: 460, height: 180))   // AppKit 坐标原点在左下：上面 180pt 是上半段
        content.addSubview(top)
        window.contentView = content
        check(!MenuBarSupport.hasOpenPopover(window) && !MenuBarSupport.hasOpenPopover(nil),
              "菜单栏小窗：没挂小气泡时不算数量输入框开着")
        let handle = MenuBarWindowHandle()
        handle.window = window
        handle.topArea = top
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, window number: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: number, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let start = Date()
        let inBottom = mouse(.leftMouseDown, NSPoint(x: 120, y: 90), window: window.windowNumber).map { handle.noteClick($0, at: start) } ?? true
        let elsewhere = mouse(.leftMouseDown, NSPoint(x: 120, y: 300), window: window.windowNumber + 1).map { handle.noteClick($0, at: start) } ?? true
        let mouseUp = mouse(.leftMouseUp, NSPoint(x: 120, y: 300), window: window.windowNumber).map { handle.noteClick($0, at: start) } ?? true
        let untouched = handle.lastTopAction == nil
        let closesUntouched = handle.captureFinished(escape: false, popoverOpen: false, now: start.addingTimeInterval(0.5))
        check(!inBottom && !elsewhere && !mouseUp && untouched && closesUntouched,
              "菜单栏小窗：按在下半段随手记里、别的窗口里、松开鼠标都不算点过上半段，记完照常收起")
        // 点打卡圈（这一下弹出数量输入框，圈自己不报）：按下就记一笔，0.8 秒后记完不收；右键“记数量…”同样
        let leftTop = mouse(.leftMouseDown, NSPoint(x: 30, y: 380), window: window.windowNumber).map { handle.noteClick($0, at: start) } ?? false
        let keptAfterCircle = !handle.captureFinished(escape: false, popoverOpen: false, now: start.addingTimeInterval(0.8))
        let closesLater = handle.captureFinished(escape: false, popoverOpen: false, now: start.addingTimeInterval(MenuBarDigest.autoCloseGrace + 1))
        handle.endSession()
        let rightTop = mouse(.rightMouseDown, NSPoint(x: 30, y: 230), window: window.windowNumber).map { handle.noteClick($0, at: start) } ?? false
        let keptAfterRight = !handle.captureFinished(escape: false, popoverOpen: false, now: start.addingTimeInterval(0.8))
        let escAfterRight = handle.captureFinished(escape: true, popoverOpen: false, now: start.addingTimeInterval(0.8))
        check(leftTop && keptAfterCircle && closesLater && rightTop && keptAfterRight && escAfterRight,
              "菜单栏小窗：在上半段按下鼠标（点打卡圈弹出数量输入框、右键“记数量…”）算刚点过上半段，记完不自动收起；过后、按 Esc 照常收")
        handle.window = nil   // 拆掉鼠标监视
        handle.topArea = nil
        let afterDetach = mouse(.leftMouseDown, NSPoint(x: 30, y: 380), window: window.windowNumber).map { handle.noteClick($0, at: start) } ?? true
        check(!afterDetach, "菜单栏小窗：窗口换掉后旧窗口里的点按不再算")
        window.close()

        // 3. 日程、目标弹窗加高后在 1180×780 的窗口（去掉 28pt 标题栏）里放得下
        let container = try DataStore.makeContainer(inMemory: true)
        let c = container.mainContext
        DataStore.settings(in: c)
        DataStore.profile(in: c)
        let today = LocalDay.today()
        let event = ScheduleEvent(title: "自检组会", dateKey: today.key)
        event.recurrenceKind = .weekly
        c.insert(event)
        let goal = Goal(title: "自检目标")
        c.insert(goal)
        DataStore.save(c)
        func size<V: View>(_ view: V) -> CGSize {
            let host = NSHostingView(rootView: view
                .environment(EffectsCenter())
                .environment(\.spiritMotion, false)
                .modelContainer(container)
                .defaultAppStorage(AppPreferences.defaults))
            host.frame = CGRect(origin: .zero, size: CGSize(width: 900, height: 900))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        let limit = CGSize(width: 1180, height: 780 - 28)
        let sheets: [(String, CGSize, CGFloat)] = [
            ("新建日程", size(EventEditor(event: nil, defaultDay: today, defaultStart: 9 * 60)), 752),
            ("编辑重复日程", size(EventEditor(event: event, defaultDay: today, defaultStart: nil)), 752),
            ("新建目标", size(GoalEditor(goal: nil)), 620),
            ("编辑目标", size(GoalEditor(goal: goal)), 620),
        ]
        let wrong = sheets.filter { abs($0.1.height - $0.2) > 0.5 || $0.1.width > limit.width || $0.1.height > limit.height }
        check(wrong.isEmpty,
              "日程弹窗 680 → 752、目标弹窗 560 → 620，在 1180×780 的窗口里放得下" + (wrong.isEmpty ? "" : "（不对：\(wrong.map { "\($0.0) \(Int($0.1.width))×\(Int($0.1.height))" })）"))
        c.delete(event)
        c.delete(goal)
        DataStore.save(c)

        // 4. 长卷逐月柱刻度下标与灵石账簿月份旁同一个说法
        let note = AnnalsReport.FinancePart.monthNote(full: false, ongoing: false, manualOnly: false, partial: FinanceHeadlineRule.partialLabel)
        check(note == "未导全" && FinanceHeadlineRule.partialLabel == "未导全" && FinanceHeadlineRule.partialLabel == PartialMonthRule.label,
              "岁月长卷没导全的月份与灵石账簿同写“未导全”（不再写“部分”；账簿的小标取 Core 的 PartialMonthRule）：\(note)")

        // 5. 长卷导出的 Markdown（导出按钮走的 AnnalsPDF.markdown）逐月表也写“（未导全）”；只记手记的不写
        let exportDay = LocalDay(key: "2026-10-20")!
        var ledger = FinanceLedger()
        for (i, day) in LocalDay.range(LocalDay(key: "2026-01-01")!, exportDay).enumerated() where day.day % 5 == 1 {
            ledger.transactions.append(FinanceTransaction(id: "tails-t\(i)", date: day.key, amountCents: -(1000 + i), balanceCents: 0, description: "自检",
                                                          account: "CBA", category: "餐饮与外卖", kind: "消费", needsReview: false, reason: "", sourceLine: i))
        }
        func exported(_ ranges: [(String, String)]) -> String {
            var l = ledger
            l.sources = ranges.map { FinanceSource(sha256: "tails\($0.0)", account: "CBA", rawCsv: "", importedAt: "", rows: 0, start: $0.0, end: $0.1,
                                                   statementPeriod: StatementPeriod(start: $0.0, end: $0.1)) }
            let input = RecordInput(today: exportDay, entries: [], history: [], habits: [], cultivation: CultivationConfig(), ledger: l)
            return AnnalsPDF.markdown(AnnalsEngine.report(AnnalsPeriod.make(.year(2026), today: exportDay)!, input: input), appendix: [])
        }
        let gap = exported([("2026-01-01", "2026-08-31"), ("2026-09-10", "2026-10-19")])
        let manual = exported([])
        let septRow = gap.split(separator: "\n").first { $0.hasPrefix("| 9月 |") }.map(String.init) ?? ""
        check(septRow.hasSuffix("（未导全） |") && !gap.contains("（部分）") && !manual.contains("（未导全）") && !manual.contains("（部分）"),
              "岁月长卷导出的逐月表：没导全的 9 月写“\(septRow)”，与页面同一个说法；只记手记的不标")
    }
}
