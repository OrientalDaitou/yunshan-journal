import Foundation
import SwiftData
import SwiftUI
import AppKit

// 随手记“随心”的运行时自检：认句子的上下文从库里取得对、五类各记一条再撤销，
// 修为、数量、备注、账、日程都还原；第一次记好写下 onboarding.quickUsed；浮窗带着各类草稿挂得起来。
// 认句子本身（一百多句例句、钟点、单位、改作）在 Tools/CoreCheck 里测。

extension SelfTest {
    static func quickParseChecks(_ check: (Bool, String) -> Void) throws {
        let container = try DataStore.makeContainer(inMemory: true)
        let c = container.mainContext
        DataStore.settings(in: c)
        DataStore.profile(in: c)
        let today = LocalDay.today()
        let yesterday = today.adding(days: -1)
        func habit(_ title: String, unit: String = "", target: Double? = nil, order: Int) -> Habit {
            let h = Habit(title: title)
            h.unit = unit
            h.targetValue = target
            h.sortOrder = order
            h.startDate = today.adding(days: -30).key
            c.insert(h)
            return h
        }
        let meditate = habit("冥想", unit: "分钟", target: 10, order: 0)
        let water = habit("喝水", unit: "杯", target: 8, order: 1)
        let sport = habit("运动", order: 2)
        let archived = habit("旧功课", order: 3)
        archived.archived = true
        archived.archivedAt = today.adding(days: -2).key
        let morning = HabitLog(dateKey: today.key, completed: true, quantity: 2)
        morning.notes = "早上"
        c.insert(morning)
        morning.habit = water
        DataStore.save(c)
        let effects = EffectsCenter()
        func xp() -> Int { CultivationService.fullState(context: c).totalXP }
        func parse(_ text: String, choice: QuickParse.Choice? = nil) -> (QuickParse.Result, [Habit]) {
            let (ctx, models) = QuickCommit.parseContext(in: c)
            return (QuickParse.parse(text, context: ctx, choice: choice), models)
        }
        func log(_ h: Habit, _ day: LocalDay = today) -> HabitLog? { HabitDayLogs(day: day, context: c).log(of: h) }

        // 1. 认句子的上下文：只列未归档的功课，按排序；今天已记的数量带上
        let (ctx, models) = QuickCommit.parseContext(in: c)
        check(models.map(\.title) == ["冥想", "喝水", "运动"] && ctx.habits[1].days[today] == .init(quantity: 2, done: false)
              && ctx.habits[0].target == 10 && ctx.habits[2].target == nil && ctx.today == today,
              "随心的功课清单：未归档的三项按排序，喝水今天已记 2 杯")

        // 2. 日记：入卷、修为 +5；撤销后这一篇没了、修为扣回
        let xp0 = xp()
        let (diary, h0) = parse("今天心情不错，下午去了图书馆 #读书")
        let r1 = try QuickCommit.apply(diary, mood: 4, category: nil, habits: h0, context: c, effects: effects)
        let entry = c.all(JournalEntry.self).first { $0.body == "今天心情不错，下午去了图书馆" }
        check(diary.intent == .diary && entry?.mood == 4 && entry?.tags == ["读书"] && entry?.dateKey == today.key && entry?.minute != nil
              && xp() == xp0 + 5,
              "随心记日记：入卷带心境与标签、修为 +5（\(xp() - xp0)）")
        try QuickCommit.undo(r1, context: c, effects: effects)
        check(!c.all(JournalEntry.self).contains { $0.body.hasPrefix("今天心情不错") } && xp() == xp0, "撤销日记：这一篇删掉，修为扣回")

        // 3. 补记昨天：记在昨天、不写时刻
        let (late, h1) = parse("昨天睡得很晚")
        let r2 = try QuickCommit.apply(late, mood: nil, category: nil, habits: h1, context: c, effects: effects)
        let backdated = c.all(JournalEntry.self).first { $0.body == "睡得很晚" }
        check(backdated?.dateKey == yesterday.key && backdated?.minute == nil, "“昨天睡得很晚”补记在昨天，不写时刻")
        try QuickCommit.undo(r2, context: c, effects: effects)

        // 4. 记账：入账（类别可改）；撤销后这笔没了
        let (lunch, h2) = parse("午饭 18.5")
        let r3 = try QuickCommit.apply(lunch, mood: nil, category: "娱乐", habits: h2, context: c, effects: effects)
        let row = try FinanceService.load(c).transactions.first { $0.description == "午饭" }
        check(lunch.intent == .expense && row?.amountCents == -1850 && row?.category == "娱乐" && row?.reason == "随手记" && row?.date == today.key,
              "随心记账：午饭 18.5 入账 $18.50，改过的类别（娱乐）照记")
        try QuickCommit.undo(r3, context: c, effects: effects)
        check(!(try FinanceService.load(c).transactions.contains { $0.description == "午饭" }), "撤销记账：这笔账删掉")

        // 5. 数量型打卡累加到今天已记的；撤销恢复成原来的 2 杯与备注
        let xp1 = xp()
        let (drink, h3) = parse("喝水 3 杯，有点渴")
        let r4 = try QuickCommit.apply(drink, mood: nil, category: nil, habits: h3, context: c, effects: effects)
        check(drink.intent == .checkin && log(water)?.quantity == 5 && log(water)?.notes == "早上；有点渴",
              "随心打卡：喝水 3 杯累加到 5 杯，备注接在原来的后面（\(log(water)?.notes ?? "")）")
        try QuickCommit.undo(r4, context: c, effects: effects)
        check(log(water)?.quantity == 2 && log(water)?.notes == "早上" && xp() == xp1, "撤销打卡：喝水回到 2 杯、备注回到“早上”、修为还原")

        // 6. 没写数量记满；只打卡的功课按同类说法对上（跑步 → 运动），数量写进备注；撤销后删掉这条打卡
        let (full, h4) = parse("冥想")
        let r5 = try QuickCommit.apply(full, mood: nil, category: nil, habits: h4, context: c, effects: effects)
        check(log(meditate)?.quantity == 10 && xp() > xp1, "随心打卡：没写数量记满 10 分钟、修为增加")
        try QuickCommit.undo(r5, context: c, effects: effects)
        check(log(meditate) == nil && xp() == xp1, "撤销记满：原来没有打卡，就删掉这条，修为还原")
        let (run, h5) = parse("跑步 30 分钟")
        let r6 = try QuickCommit.apply(run, mood: nil, category: nil, habits: h5, context: c, effects: effects)
        check(run.checkin?.via == "跑步" && log(sport)?.completed == true && log(sport)?.notes == "跑步 30 分钟",
              "同类说法：跑步 30 分钟给「运动」打卡，备注“跑步 30 分钟”")
        // 已打过的只打卡功课再说一次：认成日记，不会把卡取消掉
        check(parse("健身了").0.intent == .diary && parse("健身了").0.notice == "「运动」今日已圆满",
              "运动今天已打过：再说“健身了”认成日记（不取消打卡）")
        try QuickCommit.undo(r6, context: c, effects: effects)
        check(log(sport) == nil && xp() == xp1, "撤销运动打卡：删掉这条，修为还原")

        // 7. 补昨天的卡
        let (yRun, h6) = parse("昨天跑步了")
        let r7 = try QuickCommit.apply(yRun, mood: nil, category: nil, habits: h6, context: c, effects: effects)
        check(log(sport, yesterday)?.completed == true && log(sport) == nil, "“昨天跑步了”补在昨天")
        try QuickCommit.undo(r7, context: c, effects: effects)

        // 8. 日程：明天下午3点 组会 → 时辰卷 15:00–16:00；撤销删掉
        let (meeting, h7) = parse("明天下午3点 组会")
        let r8 = try QuickCommit.apply(meeting, mood: nil, category: nil, habits: h7, context: c, effects: effects)
        let event = c.all(ScheduleEvent.self).first { $0.title == "组会" }
        check(meeting.intent == .event && event?.dateKey == today.adding(days: 1).key && event?.startMinute == 15 * 60
              && event?.endMinute == 16 * 60 && event?.category == "" && event?.recurrence == "none",
              "随心记日程：明天 15:00–16:00「组会」，类别留空")
        try QuickCommit.undo(r8, context: c, effects: effects)
        check(!c.all(ScheduleEvent.self).contains { $0.title == "组会" }, "撤销日程：这条删掉")
        let (allDay, h8) = parse("后天交报告")
        let r9 = try QuickCommit.apply(allDay, mood: nil, category: nil, habits: h8, context: c, effects: effects)
        let deadline = c.all(ScheduleEvent.self).first { $0.title == "交报告" }
        check(deadline?.dateKey == today.adding(days: 2).key && deadline?.startMinute == nil && deadline?.endMinute == nil,
              "全天日程：后天「交报告」没有钟点")
        try QuickCommit.undo(r9, context: c, effects: effects)

        // 9. 改作：已过的 9 点选定日程记在今晚 21:00；没写做什么的日程不让记
        let (chosen, h9) = parse("9点 开会", choice: .event)
        check(chosen.intent == .event && chosen.chosen && (chosen.event?.start == 9 * 60 || chosen.event?.start == 21 * 60),
              "改作日程：选定后按日程记（9 点已过按晚上）")
        _ = h9
        check(parse("明天下午3点").0.canSave == false, "日程没写做什么：不能记")
        do {
            let (untitled, h10) = parse("明天下午3点")
            _ = try QuickCommit.apply(untitled, mood: nil, category: nil, habits: h10, context: c, effects: effects)
            check(false, "没写做什么的日程被记下了")
        } catch {
            check(error.localizedDescription == "写上要做什么", "没写做什么的日程：记不上，说明“写上要做什么”")
        }

        // 10. 第一次记好写下 onboarding.quickUsed（筑基三关读它）；之后不再重写
        let suite = "io.github.orientaldaitou.yunshan.selftest-quick"
        if let scratch = UserDefaults(suiteName: suite) {
            scratch.removePersistentDomain(forName: suite)
            check(!scratch.bool(forKey: QuickCommit.usedKey), "还没用过随手记时 onboarding.quickUsed 为假")
            QuickCommit.markUsed(in: scratch)
            check(scratch.bool(forKey: "onboarding.quickUsed"), "记好一条后 onboarding.quickUsed = true")
            scratch.removePersistentDomain(forName: suite)
        }

        // 11. 打开时用哪一类：草稿空 → 随心；写了一半 → 保持上次
        check(QuickCaptureView.openingKind(stored: "note", text: "", amount: "") == .auto
              && QuickCaptureView.openingKind(stored: "expense", text: "", amount: "18") == .expense
              && QuickCaptureView.openingKind(stored: "note", text: "写到一半", amount: "") == .note
              && QuickCaptureView.openingKind(stored: "坏的", text: "x", amount: "") == .auto
              && QuickCaptureView.Kind.allCases.map(\.label) == ["随心", "日记", "灵感", "复盘", "记账"],
              "随手记的五个签“随心 · 日记 · 灵感 · 复盘 · 记账”；草稿空时打开回到随心，写了一半的账保持记账")

        // 13. 审查后的修正，在真库里走一遍：没做的不打卡、空正文不入卷、功课名核心词能打卡、晚上12点记 23:59 前
        let (notDone, h11) = parse("今天没冥想")
        check(notDone.intent == .diary && notDone.notice == "像是还没做，先记成日记；做了要打卡点“改作”", "“今天没冥想”认成日记，不打卡")
        let r11 = try QuickCommit.apply(notDone, mood: nil, category: nil, habits: h11, context: c, effects: effects)
        check(log(meditate) == nil && c.all(JournalEntry.self).contains { $0.body == "今天没冥想" }, "“今天没冥想”入卷为日记，冥想没有打卡")
        try QuickCommit.undo(r11, context: c, effects: effects)
        let journals = c.all(JournalEntry.self).count
        let (blank, h12) = parse("复盘：")
        check(!blank.canSave && blank.problem == "写上要记的话", "只写“复盘：”：不能记")
        do {
            _ = try QuickCommit.apply(blank, mood: nil, category: nil, habits: h12, context: c, effects: effects)
            check(false, "空正文的复盘被记下了")
        } catch {
            check(error.localizedDescription == "写上要记的话" && c.all(JournalEntry.self).count == journals, "空正文：记不上，也不加修为")
        }
        let reading = habit("晨读二十分钟", order: 4)
        DataStore.save(c)
        let (morningRead, h13) = parse("晨读了 20 分钟")
        let r13 = try QuickCommit.apply(morningRead, mood: nil, category: nil, habits: h13, context: c, effects: effects)
        check(morningRead.checkin?.title == "晨读二十分钟" && log(reading)?.completed == true && log(reading)?.notes == "20 分钟",
              "功课叫“晨读二十分钟”，说“晨读了 20 分钟”给它打卡，备注“20 分钟”")
        try QuickCommit.undo(r13, context: c, effects: effects)
        check(log(reading) == nil, "撤销晨读打卡")
        var noonCtx = QuickCommit.parseContext(in: c)
        noonCtx.0.nowMinute = 12 * 60
        let sleep = QuickParse.parse("晚上12点 睡觉", context: noonCtx.0)
        let r14 = try QuickCommit.apply(sleep, mood: nil, category: nil, habits: noonCtx.1, context: c, effects: effects)
        let bed = c.all(ScheduleEvent.self).first { $0.title == "睡觉" }
        check(sleep.intent == .event && bed?.startMinute == 23 * 60 + 59 && bed?.endMinute == nil && bed?.dateKey == today.key,
              "“晚上12点 睡觉”记成今天 23:59 的日程（不跨夜）")
        try QuickCommit.undo(r14, context: c, effects: effects)

        // 12. 浮窗带着各类草稿挂得起来（随心认记账 / 打卡 / 日程、改作、手记账）
        let defaults = UserDefaults(suiteName: suite + ".view")!
        defer { defaults.removePersistentDomain(forName: suite + ".view") }
        for draft in [["draft.quick.text": "午饭 18.5"], ["draft.quick.text": "冥想 10 分钟"], ["draft.quick.text": "明天下午3点 组会"],
                      ["draft.quick.text": "9点 开会", "draft.quick.choice": "event", "draft.quick.choiceText": "9点 开会"],
                      ["draft.quick.text": "复盘："], ["draft.quick.text": "今天冥想了 10 分钟，喝水 3 杯"],
                      ["quick.kind": "expense", "draft.quick.text": "午饭", "draft.quick.amount": "18"]] {
            defaults.removePersistentDomain(forName: suite + ".view")
            for (k, v) in draft { defaults.set(v, forKey: k) }
            let host = NSHostingView(rootView: QuickCaptureView(onDone: {}).modelContainer(container).defaultAppStorage(defaults))
            host.frame = CGRect(origin: .zero, size: CGSize(width: 500, height: 420))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let size = host.fittingSize
            check(size.width >= 440 && size.height > 200, "随手记带草稿 \(draft) 挂得起来（\(Int(size.width))×\(Int(size.height))）")
        }
    }
}
