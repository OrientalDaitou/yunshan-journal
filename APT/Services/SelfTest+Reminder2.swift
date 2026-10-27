import AppKit
import SwiftData
import SwiftUI

// #17 提醒扩展：日程开始前、那年今日、周复盘写本周实数。排哪几条、正文怎么写在 Core/ReminderPlan 末尾一节，逐条核对在 Tools/CoreCheck；
// 这里测要用到数据库与偏好设置的部分：三个开关在调试实例里只记下、按库现取今天明天的日程（重复、改期都算上）、
// 那年今日挑哪一篇、本周落笔几篇与功课完成率（与七日小卷同一个数），以及点开后去哪（周复盘在三种页面上各点一次，小卷只弹一次）。

extension SelfTest {
    static func reminder2Checks(_ check: (Bool, String) -> Void) throws {
        guard AppPreferences.suiteName != nil else { return }
        let defaults = AppPreferences.defaults
        let keys = [DailyReminder.eventsKey, DailyReminder.eventsLeadKey, DailyReminder.lookbackKey,
                    ReviewReminder.enabledKey, ReviewReminder.weekdayKey, ReviewReminder.minuteKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        let router = AppRouter.shared
        let savedRoute = (router.page, router.scheduleDay)
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            router.page = savedRoute.0
            router.scheduleDay = savedRoute.1
            router.chronicleCompose = nil
            router.weeklyScroll = false
            DailyReminder.openWeekly = nil
        }
        keys.forEach(defaults.removeObject)

        /// 在主线程上等一个异步操作做完（自检本身是同步跑的）：最多等 3 秒
        func wait<T>(_ work: @escaping @MainActor () async -> T) -> T? {
            var result: T?
            Task { @MainActor in result = await work() }
            let deadline = Date().addingTimeInterval(3)
            while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return result
        }

        // 1. 三个开关默认关；调试实例里打开只记下（不申请权限、不排通知），提前量认不出的回到 10 分钟
        check(!DailyReminder.isEventsEnabled && !DailyReminder.isLookbackEnabled && !DailyReminder.isWeeklyEnabled
              && DailyReminder.eventsLead == 10 && !DailyReminder.touchesSystem,
              "#17 提醒：日程、那年今日、周复盘默认都关，日程默认提前 10 分钟")
        let on = [wait { await DailyReminder.shared.setEvents(enabled: true) },
                  wait { await DailyReminder.shared.setLookback(enabled: true) },
                  wait { await DailyReminder.shared.setWeekly(enabled: true) }]
        _ = wait { await DailyReminder.shared.reschedule() }
        check(on.allSatisfy { $0 == true } && DailyReminder.isEventsEnabled && DailyReminder.isLookbackEnabled && DailyReminder.isWeeklyEnabled
              && DailyReminder.anyEnabled && DailyReminder.state == ReminderPlan.State(),
              "#17 提醒：调试实例里打开三行只记下开关（\(DailyReminder.debugNote)）")
        DailyReminder.shared.setEventsLead(7)
        let odd = DailyReminder.eventsLead
        DailyReminder.shared.setEventsLead(30)
        check(odd == 10 && DailyReminder.eventsLead == 30, "#17 提醒：日程提前量只有 5 / 10 / 15 / 30，写坏的按 10 分钟")

        // 2. 通知代理按前缀分派：三类交给 DailyReminder，以前每周重复的那条照旧归 ReviewReminder
        let today = LocalDay.today()
        check(DailyReminder.handles("apt.event.\(today.key).1500.0") && DailyReminder.handles("apt.lookback.\(today.key)")
              && DailyReminder.handles("apt.weekly.\(today.key)") && !DailyReminder.handles(ReviewReminder.identifier),
              "#17 通知代理：apt.event. / apt.lookback. / apt.weekly. 交给 DailyReminder，旧的 apt.weekly-review 不归它")

        let container = try DataStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        DataStore.save(context)
        let tomorrow = today.adding(days: 1)

        // 3. 日程：今天与明天有钟点的（重复的展开、单次改期套上），全天的、后天的不排
        let meeting = ScheduleEvent(title: "组会", dateKey: today.key)
        meeting.startMinute = 23 * 60 + 50
        meeting.location = "图书馆 3 楼"
        let reading = ScheduleEvent(title: "晨读", dateKey: today.adding(days: -5).key)
        reading.startMinute = 7 * 60
        reading.recurrenceKind = .daily
        reading.overridesJSON = "{\"\(tomorrow.key)\":{\"title\":\"晨读（改到图书馆）\",\"start_time\":\"08:30\"}}"
        let allDay = ScheduleEvent(title: "全天的", dateKey: tomorrow.key)
        let later = ScheduleEvent(title: "后天的", dateKey: today.adding(days: 2).key)
        later.startMinute = 9 * 60
        [meeting, reading, allDay, later].forEach { context.insert($0) }
        DataStore.save(context)
        let items = DailyReminder.eventItems(today: today, context: context)
        let eventPlan = ReminderPlan.eventSlots(today: today, nowMinute: 12 * 60, lead: 10, items: items)
        check(items.count == 4 && eventPlan.map(\.body) == ["23:50 组会 · 还有 10 分钟 · 图书馆 3 楼", "08:30 晨读（改到图书馆） · 还有 10 分钟"]
              && eventPlan.last?.day == tomorrow && eventPlan.last?.minute == 8 * 60 + 20,
              "#17 日程：按库取今天与明天（今天晨读已过、全天与后天的不排，明天的改期套上）：\(eventPlan.map(\.body))")

        // 4. 那年今日：往年那天挑一篇（珍藏优先；再先日记、灵感后复盘；同类取最早落笔的一篇；去掉小标题与素材段后空了的跳过），
        //    只按 dateKey 取这几天。一年前那一档挑 7 天里没被截到月底的那天（今天是 2 月 29 日时，今天的一年前不算）
        let yearTarget = (0..<ReminderPlan.horizonDays).map { today.adding(days: $0) }.first {
            ReminderPlan.lookbackSpans(today: $0).first?.label == "一年前"
        } ?? today
        let yearAgo = DashboardRules.monthAgo(12, today: yearTarget)
        let plain = JournalEntry(kind: .diary, body: "那天先写的一篇", dateKey: yearAgo.key)
        plain.minute = 8 * 60
        let pinned = JournalEntry(kind: .diary, body: "珍藏的这一篇：秋夜读完了那本书，窗外起了雾。", dateKey: yearAgo.key)
        pinned.minute = 22 * 60
        pinned.pinned = true
        let blank = JournalEntry(kind: .diary, body: "  \n ", dateKey: today.adding(days: -6).key)
        let weekNote = JournalEntry(kind: .note, body: "一周前的灵感", dateKey: today.adding(days: -5).key)
        // 同一天：早上一篇只有模板和本期素材的复盘、一篇写了字的复盘，晚上一篇日记 → 取日记
        let reviewDay = today.adding(days: -4)
        let templateReview = JournalEntry(kind: .review, body: "【所得】\n〔本期素材 · 本周〕\n· 功课：冥想 7/7 天\n· 落笔 5 篇\n\n【所失】\n\n【所悟】\n\n【下一步】\n",
                                          dateKey: reviewDay.key)
        templateReview.minute = 7 * 60
        let earlyReview = JournalEntry(kind: .review, body: "【所得】\n读完两章", dateKey: reviewDay.key)
        earlyReview.minute = 8 * 60
        let evening = JournalEntry(kind: .diary, body: "晚上散步，想通了一件事。", dateKey: reviewDay.key)
        evening.minute = 22 * 60
        // 只有一篇复盘的那天：摘句去掉【所得】【所失】小标题
        let onlyReview = JournalEntry(kind: .review, body: "【所得】\n读完两章\n\n【所失】\n拖延了一下午\n\n【所悟】\n\n【下一步】\n",
                                      dateKey: today.adding(days: -3).key)
        [plain, pinned, blank, weekNote, templateReview, earlyReview, evening, onlyReview].forEach { context.insert($0) }
        DataStore.save(context)
        let written = DailyReminder.lookbackWritten(today: today, context: context)
        let lookback = ReminderPlan.lookbackSlots(today: today, nowMinute: 0, written: written)
        func slot(_ offset: Int) -> String? { lookback.first { $0.day == today.adding(days: offset) }?.body }
        check(written[yearAgo.key] == pinned.body && written[today.adding(days: -6).key] == nil
              && lookback.first { $0.day == yearTarget }?.body == "一年前的今天，你写下：「珍藏的这一篇：秋夜读完了那本书，窗外起了雾。」"
              && slot(2) == "一周前的今天，你写下：「一周前的灵感」",
              "#17 那年今日：一年前那天取珍藏的一篇，后天取一周前的灵感；空白的那篇当没写")
        check(written[reviewDay.key] == evening.body && slot(3) == "一周前的今天，你写下：「晚上散步，想通了一件事。」"
              && slot(4) == "一周前的今天，你写下：「读完两章 拖延了一下午」"
              && !lookback.contains { $0.body.contains("【") || $0.body.contains("〔") },
              "#17 那年今日：同一天先取日记（只有模板和素材的复盘不算写过），只有复盘时摘句去掉【所得】小标题：\(slot(4) ?? "无")")

        // 5. 周复盘的本周实数：落笔篇数按 dateKey 数；功课完成率与点开后七日小卷的“本周完成 N%”同一个数
        //    （同一批没归档的功课、完成次数之和 / 应做次数之和；有一项指定星期的、一项已归档的）
        let monday = today.mondayOfWeek
        let before = DailyReminder.weekNumbers(from: monday, to: today, today: today, context: context)
        let thisWeek = [JournalEntry(kind: .diary, body: "本周一篇", dateKey: monday.key),
                        JournalEntry(kind: .review, body: "本周又一篇", dateKey: today.key)]
        thisWeek.forEach { context.insert($0) }
        let meditate = Habit(title: "冥想")
        meditate.startDate = today.adding(days: -10).key
        let run = Habit(title: "跑步")
        run.frequencyKind = .weekdays
        run.weekdays = [0, 2, 4]
        run.startDate = today.adding(days: -10).key
        run.sortOrder = 1
        let shelved = Habit(title: "已归档的读书")
        shelved.startDate = today.adding(days: -10).key
        shelved.archived = true
        shelved.archivedAt = today.key
        shelved.sortOrder = 2
        [meditate, run, shelved].forEach { context.insert($0) }
        DataStore.save(context)
        var logs: [(Habit, LocalDay)] = LocalDay.range(monday, today).map { (meditate, $0) } + [(run, monday)]
        logs += LocalDay.range(today.adding(days: -10), today).map { (shelved, $0) }
        for (habit, day) in logs {
            let log = HabitLog(dateKey: day.key)
            log.habit = habit
            context.insert(log)
        }
        DataStore.save(context)
        let numbers = DailyReminder.weekNumbers(from: monday, to: today, today: today, context: context)
        let week = WeeklyDigest.Week(monday: monday, today: today)
        let scroll = WeeklyScrollContent.load(week: week, context: context).habits
        let lastWeek = DailyReminder.weekNumbers(from: monday.adding(days: -7), to: monday.adding(days: -1), today: today, context: context)
        let lastScroll = WeeklyScrollContent.load(week: week.previous, context: context).habits
        let headline = scroll.map { WeeklyDigest.habitHeadline($0, week: week) } ?? ""
        let body = ReminderPlan.weeklyBody(numbers, previous: false)
        check(numbers.entries == before.entries + 2 && scroll != nil && numbers.habitRate == scroll?.rate
              && scroll.map { body.contains("功课 \(RecordStats.percent($0.rate))") && headline.contains(RecordStats.percent($0.rate)) } == true
              && lastWeek.habitRate == lastScroll?.rate && scroll?.lines.contains { $0.title == shelved.title } == false,
              "#17 周复盘：本周落笔 \(numbers.entries) 篇；提醒“\(body)”与七日小卷“\(headline)”同一个数（上周 \(lastWeek.habitRate.map(RecordStats.percent) ?? "–") 也一致，已归档的不算）")
        let weekly = DailyReminder.extraPlan(today: today, nowMinute: 0, context: context).filter { $0.kind == .weekly }
        let fresh = weekly.first.map { today.days(to: $0.day) <= 1 } ?? false
        check(weekly.count == ReminderPlan.weeklyHorizon && weekly.count == 12 && weekly.first?.minute == 21 * 60 && weekly.first?.day.weekdayIndex == 6
              && weekly.first?.body.contains("落笔 \(numbers.entries) 篇") == true && weekly.first?.body.contains("功课") == fresh
              && weekly.dropFirst().allSatisfy { $0.body == ReminderPlan.weeklyGeneric },
              "#17 周复盘：默认周日 21:00 排 12 次，第一条写本周实数（功课的数只在提醒前一天起写）：\(weekly.first?.body ?? "")")
        let all = DailyReminder.extraPlan(today: today, nowMinute: 0, context: context)
        check(Set(all.map(\.identifier)).count == all.count && all.allSatisfy { ReminderPlan.parseExtra(identifier: $0.identifier) != nil },
              "#17 三类一起排时标识不重，且都认得出")
        _ = wait { await DailyReminder.shared.setEvents(enabled: false) }
        _ = wait { await DailyReminder.shared.setLookback(enabled: false) }
        _ = wait { await DailyReminder.shared.setWeekly(enabled: false) }
        check(DailyReminder.extraPlan(today: today, nowMinute: 0, context: context).isEmpty && !DailyReminder.isWeeklyEnabled,
              "#17 三行都关掉：一条也不排")

        // 6. 点开去哪：日程 → 时辰卷那一周；那年今日 → 今日洞府；周复盘 → 修行录翻开七日小卷（没接钩子时直达修行录的复盘落笔）
        DailyReminder.shared.open(.schedule(tomorrow), bringWindow: false)
        let toSchedule = router.page == .schedule && router.scheduleDay == tomorrow
        router.page = nil
        DailyReminder.shared.open(.overview, bringWindow: false)
        let toOverview = router.page == .overview
        router.page = nil
        DailyReminder.openWeekly = nil
        DailyReminder.shared.open(.weekly, bringWindow: false)
        let bareWeekly = router.page == .chronicle && router.chronicleCompose == .review && !router.weeklyScroll
        router.page = nil
        router.chronicleCompose = nil
        DailyReminder.openWeekly = { DailyReminder.openWeeklyInChronicle() }
        DailyReminder.shared.open(.weekly, bringWindow: false)
        let hooked = router.page == .chronicle && router.weeklyScroll && router.chronicleCompose == nil
        router.page = nil
        router.weeklyScroll = false
        check(toSchedule && toOverview && bareWeekly && hooked,
              "#17 点开：日程回时辰卷那一周，那年今日回今日洞府，周复盘切到修行录并请它翻开七日小卷（没接钩子时直达复盘落笔）")
        try weeklyRouteChecks(check)
    }

    /// 主窗口挂进一扇离屏窗口（不显示），分别停在今日洞府、修行录、每日功课，点一次周复盘提醒：
    /// 七日小卷弹出一次（窗口上挂着一张小卷），页面请求与 weeklyScroll 都被接住清零，不会留到以后再弹
    private static func weeklyRouteChecks(_ check: (Bool, String) -> Void) throws {
        let router = AppRouter.shared
        let defaults = AppPreferences.defaults
        let savedOpen = router.openMainWindow
        let savedDismissed = defaults.object(forKey: "legacyPromptDismissed")
        defaults.set(true, forKey: "legacyPromptDismissed")
        DailyReminder.openWeekly = { DailyReminder.openWeeklyInChronicle() }
        defer {
            router.openMainWindow = savedOpen
            router.page = nil
            router.weeklyScroll = false
            DailyReminder.openWeekly = nil
            if let savedDismissed {
                defaults.set(savedDismissed, forKey: "legacyPromptDismissed")
            } else {
                defaults.removeObject(forKey: "legacyPromptDismissed")
            }
        }
        let container = try DataStore.makeContainer(inMemory: true)
        let context = container.mainContext
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        context.insert(JournalEntry(kind: .diary, body: "本周写过一句", dateKey: LocalDay.today().key))
        DataStore.save(context)

        func spin(_ seconds: Double, until done: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        var results: [String] = []
        for section in [AppSection.overview, .chronicle, .habits] {
            router.page = nil
            router.weeklyScroll = false
            let hosting = NSHostingView(rootView: RootView(initialSelection: section).modelContainer(container).defaultAppStorage(defaults))
            hosting.frame = CGRect(x: 0, y: 0, width: 1280, height: 860)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            spin(0.4)
            // 停在修行录以外的页时，标志此刻没人接（证明下面清零的是切过去的修行录）
            var idle = true
            if section != .chronicle {
                router.weeklyScroll = true
                spin(0.3)
                idle = router.weeklyScroll
                router.weeklyScroll = false
                spin(0.1)
            }
            DailyReminder.shared.open(.weekly, bringWindow: false)
            spin(2.5) { !router.weeklyScroll && router.page == nil }
            spin(0.5)
            let cleared = !router.weeklyScroll && router.page == nil
            // 修行录接住后还留在当前页（没被随后的切页换掉、小卷不会跟着页面一起消失）：再请求一次，它当场接住
            router.weeklyScroll = true
            spin(1) { !router.weeklyScroll }
            let stayed = !router.weeklyScroll
            router.weeklyScroll = false
            results.append("\(section.title)：\(cleared ? "已接住" : "标志还挂着")\(stayed ? "、停在修行录" : "、修行录被换掉")")
            check(idle && cleared && stayed,
                  "#17 点开周复盘提醒（停在\(section.title)）：切到修行录、由它打开七日小卷并清零，之后仍停在修行录（小卷不会随页面消失，也不会留到以后再弹）")
            window.contentView = nil
            window.close()
            spin(0.1)
        }
        check(!router.weeklyScroll && router.page == nil, "#17 点开周复盘提醒：三处都试过后标志没有留下（\(results.joined(separator: "；"))）")
    }
}
