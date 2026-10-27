import Foundation
import SwiftData
import SwiftUI
import AppKit

// #19 随手记补强（r2-quick2）的运行时自检：日期签选定的那天在真库里记对——补记日记、记账、补卡（按那天已记的数量累加）、
// 日程按那天的钟点，撤销都还原；认句子的上下文带上选定的更早那天的打卡；草稿空着打开时日期签与记账类别回到默认；
// 菜单栏小窗里不再写那两行朱砂快捷键提示；新建 / 编辑日程弹窗挂得起来。认句子本身在 Tools/CoreCheck（// MARK: r2-quick2）里测。

extension SelfTest {
    static func quickCapture2Checks(_ check: (Bool, String) -> Void) throws {
        let container = try DataStore.makeContainer(inMemory: true)
        let c = container.mainContext
        DataStore.settings(in: c)
        DataStore.profile(in: c)
        let today = LocalDay.today()
        let yesterday = today.adding(days: -1)
        let week = today.adding(days: -6)
        let water = Habit(title: "喝水")
        water.unit = "杯"
        water.targetValue = 8
        water.sortOrder = 0
        water.startDate = today.adding(days: -30).key
        c.insert(water)
        let earlier = HabitLog(dateKey: week.key, completed: false, quantity: 3)
        c.insert(earlier)
        earlier.habit = water
        DataStore.save(c)
        let effects = EffectsCenter()
        func xp() -> Int { CultivationService.fullState(context: c).totalXP }
        func parse(_ text: String, day: LocalDay?) -> (QuickParse.Result, [Habit]) {
            let (ctx, models) = QuickCommit.parseContext(in: c, extraDay: day)
            return (QuickParse.parse(text, context: ctx, day: day), models)
        }
        func log(_ h: Habit, _ day: LocalDay) -> HabitLog? { HabitDayLogs(day: day, context: c).log(of: h) }

        // 1. 认句子的上下文：平时只带今天、昨天、前天；日期签选了一周前，那天的打卡也带上
        let plainCtx = QuickCommit.parseContext(in: c).0
        let weekCtx = QuickCommit.parseContext(in: c, extraDay: week).0
        check(plainCtx.habits.first?.days[week] == nil && weekCtx.habits.first?.days[week] == .init(quantity: 3, done: false),
              "日期签选了一周前：认句子时带上那天喝水已记的 3 杯")

        // 2. 一周前补喝水 2 杯：累加到 5 杯、今天不动；撤销回到 3 杯
        let xp0 = xp()
        let (drink, h1) = parse("喝水 2 杯", day: week)
        let r1 = try QuickCommit.apply(drink, mood: nil, category: nil, habits: h1, context: c, effects: effects)
        check(drink.intent == .checkin && drink.checkin?.day == week && log(water, week)?.quantity == 5 && log(water, today) == nil,
              "日期签选一周前：“喝水 2 杯”补在那天，3 → 5 杯，今天不动（\(drink.savedText)）")
        try QuickCommit.undo(r1, context: c, effects: effects)
        check(log(water, week)?.quantity == 3 && xp() == xp0, "撤销补卡：那天回到 3 杯、修为还原")

        // 3. 补记昨天的日记：记在昨天、不写时刻；撤销删掉、修为扣回
        let (late, h2) = parse("睡得很晚", day: yesterday)
        let r2 = try QuickCommit.apply(late, mood: 3, category: nil, habits: h2, context: c, effects: effects)
        let entry = c.all(JournalEntry.self).first { $0.body == "睡得很晚" }
        check(entry?.dateKey == yesterday.key && entry?.minute == nil && entry?.mood == 3 && late.savedText == "已入卷 · 补记 \(yesterday.shortLabel)",
              "日期签选昨天：“睡得很晚”补记在昨天、不写时刻、心境照记")
        try QuickCommit.undo(r2, context: c, effects: effects)
        check(!c.all(JournalEntry.self).contains { $0.body == "睡得很晚" } && xp() == xp0, "撤销补记：这一篇删掉、修为还原")

        // 4. 记账记在昨天；撤销删掉
        let (lunch, h3) = parse("午饭 18.5", day: yesterday)
        let r3 = try QuickCommit.apply(lunch, mood: nil, category: nil, habits: h3, context: c, effects: effects)
        let row = try FinanceService.load(c).transactions.first { $0.description == "午饭" }
        check(lunch.intent == .expense && row?.date == yesterday.key && row?.amountCents == -1850 && row?.category == "餐饮与外卖",
              "日期签选昨天：午饭 $18.50 记在昨天（餐饮与外卖）")
        try QuickCommit.undo(r3, context: c, effects: effects)
        check(!(try FinanceService.load(c).transactions.contains { $0.description == "午饭" }), "撤销昨天那笔账")

        // 4b. 签盖过句中的别的日子：存进修行录的正文一字不少（“周五的组会……”不变成“的组会……”）
        let feeling = "周五的组会被取消了，有点失落"
        let (sad, h5) = parse(feeling, day: yesterday)
        let r5 = try QuickCommit.apply(sad, mood: nil, category: nil, habits: h5, context: c, effects: effects)
        let kept = c.all(JournalEntry.self).first { $0.dateKey == yesterday.key && $0.body.contains("组会被取消") }
        check(kept?.body == feeling, "日期签选昨天：“\(feeling)”原话入卷（存下的是“\(kept?.body ?? "nil")”）")
        try QuickCommit.undo(r5, context: c, effects: effects)

        // 4c. 补记到去年的最后一天：记好后的那句带年份，与日期签一致
        let lastYear = LocalDay(year: today.year - 1, month: 12, day: 31)
        let (old, h6) = parse("午饭 18.5", day: lastYear)
        let r6 = try QuickCommit.apply(old, mood: nil, category: nil, habits: h6, context: c, effects: effects)
        let oldRow = try FinanceService.load(c).transactions.first { $0.description == "午饭" }
        check(oldRow?.date == lastYear.key && old.savedText == "已入账 · \(today.year - 1)年12月31日",
              "日期签选去年 12月31日：记在那天，提示写“\(old.savedText)”")
        try QuickCommit.undo(r6, context: c, effects: effects)
        check(!(try FinanceService.load(c).transactions.contains { $0.description == "午饭" }) && xp() == xp0, "撤销去年那笔账、修为还原")

        // 5. 日程按签上的日子、句中的钟点：选后天，“下午3点 组会”记在后天 15:00
        let after = today.adding(days: 2)
        let (meeting, h4) = parse("下午3点 组会", day: after)
        let r4 = try QuickCommit.apply(meeting, mood: nil, category: nil, habits: h4, context: c, effects: effects)
        let event = c.all(ScheduleEvent.self).first { $0.title == "组会" }
        check(meeting.intent == .event && event?.dateKey == after.key && event?.startMinute == 15 * 60 && event?.endMinute == 16 * 60,
              "日期签选后天：“下午3点 组会”记在后天 15:00–16:00")
        try QuickCommit.undo(r4, context: c, effects: effects)

        // 6. 以后的日子不落笔、不打卡：界面上按钮变灰，直接记也拦得住（一篇不多、一条打卡不多）
        let tomorrow = today.adding(days: 1)
        let journals = c.all(JournalEntry.self).count
        for (text, choice) in [("今天心情不错，下午去了图书馆，见到了好多老朋友", nil), ("喝水 2 杯", QuickParse.Choice.checkin("喝水"))] {
            let (ctx, models) = QuickCommit.parseContext(in: c, extraDay: tomorrow)
            let future = QuickParse.parse(text, context: ctx, choice: choice, day: tomorrow)
            do {
                _ = try QuickCommit.apply(future, mood: nil, category: nil, habits: models, context: c, effects: effects)
                check(false, "日期签选明天的“\(text)”被记下了")
            } catch {
                check(!future.canSave && error.localizedDescription == future.problem && c.all(JournalEntry.self).count == journals
                      && log(water, today) == nil && log(water, tomorrow) == nil,
                      "日期签选明天的“\(text)”：记不上，说明“\(error.localizedDescription)”")
            }
        }

        // 7. 浮窗：草稿空着打开，日期签回到“按句中日期”、记账类别回到餐饮与外卖；写了一半的照留
        let suite = "io.github.orientaldaitou.yunshan.selftest-quick2"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func open<V: View>(_ view: V, width: CGFloat = 500) -> CGSize {
            let host = NSHostingView(rootView: view.modelContainer(container).defaultAppStorage(defaults))
            host.frame = CGRect(origin: .zero, size: CGSize(width: width, height: 700))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return host.fittingSize
        }
        defaults.removePersistentDomain(forName: suite)
        defaults.set(yesterday.key, forKey: "draft.quick.day")
        defaults.set("娱乐", forKey: "draft.quick.category")
        _ = open(QuickCaptureView(onDone: {}))
        check(defaults.string(forKey: "draft.quick.day") == "" && defaults.string(forKey: "draft.quick.category") == QuickCaptureView.defaultCategory,
              "草稿空着打开：日期签回到按句中日期、记账类别回到“餐饮与外卖”（不沿用上次）")
        defaults.removePersistentDomain(forName: suite)
        defaults.set("午饭 18.5", forKey: "draft.quick.text")
        defaults.set(yesterday.key, forKey: "draft.quick.day")
        let pinned = open(QuickCaptureView(onDone: {}))
        check(defaults.string(forKey: "draft.quick.day") == yesterday.key && pinned.width >= 440 && pinned.height > 200,
              "写了一半（日期签选了昨天）的草稿照留，浮窗挂得起来（\(Int(pinned.width))×\(Int(pinned.height))）")
        defaults.removePersistentDomain(forName: suite)
        defaults.set("expense", forKey: "quick.kind")
        defaults.set("午饭", forKey: "draft.quick.text")
        let expense = open(QuickCaptureView(onDone: {}))
        check(expense.width >= 440 && expense.height > 150, "“记账”的金额框挂得起来（\(Int(expense.width))×\(Int(expense.height))）")

        // 8. 快捷键没注册上时：随手记浮窗照旧写朱砂提示；菜单栏小窗不写（小窗底栏已有同义的一句）
        defaults.removePersistentDomain(forName: suite)
        defaults.set("全局快捷键 ⌥⌘J 没能注册（可能被其他应用占用），请从菜单栏的笔形图标随手记。", forKey: QuickCaptureKeys.hotKeyError)
        let withHint = open(QuickCaptureView(onDone: {}))
        let withoutHint = open(QuickCaptureView(onDone: {}, showsHotKeyHint: false))
        defaults.removeObject(forKey: QuickCaptureKeys.hotKeyError)
        let clean = open(QuickCaptureView(onDone: {}))
        check(withHint.height > withoutHint.height + 12 && abs(withoutHint.height - clean.height) < 1,
              "快捷键提示：浮窗里照写（\(Int(withHint.height)) pt），菜单栏小窗那份不写（\(Int(withoutHint.height)) pt，与没出错时 \(Int(clean.height)) pt 一样）")
        defaults.set("x", forKey: QuickCaptureKeys.hotKeyError)
        let panelFailed = open(MenuBarPanel(), width: 460)
        defaults.removeObject(forKey: QuickCaptureKeys.hotKeyError)
        let panelOK = open(MenuBarPanel(), width: 460)
        check(abs(panelFailed.height - panelOK.height) < 1,
              "菜单栏小窗：快捷键没注册上时只换底栏那句，不再多两行朱砂字（\(Int(panelFailed.height)) / \(Int(panelOK.height)) pt）")

        // 9. 日程弹窗（新建、编辑）挂得起来
        let sample = ScheduleEvent(title: "自检组会", dateKey: today.key)
        sample.category = "组会"
        c.insert(sample)
        let other = ScheduleEvent(title: "自检上课", dateKey: today.key)
        other.category = "上课"
        c.insert(other)
        DataStore.save(c)
        let newSheet = open(EventEditor(event: nil, defaultDay: today, defaultStart: 9 * 60), width: 600)
        let editSheet = open(EventEditor(event: sample, defaultDay: today, defaultStart: nil), width: 600)
        check(abs(newSheet.width - 540) < 1 && abs(editSheet.width - 540) < 1, "新建 / 编辑日程弹窗挂得起来（宽 540）")
        c.delete(sample)
        c.delete(other)
        DataStore.save(c)
    }
}
