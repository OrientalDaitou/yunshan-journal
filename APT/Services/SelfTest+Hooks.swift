import Foundation
import SwiftData
import SwiftUI
import AppKit

// r3-hooks（#14 首页回看入口）的运行时自检：七日小卷“上次许下的下一步”取哪一篇（这周一之前或周一当天的周复盘，本周六日写的不算、
// 太久以前的不翻出来、只有日省时不出），出关那一行按库取“最近一条记录”（落笔、打卡各只取 1 条，不晚于今天），纸笺按 dateKey 只取那一周，
// 首页接七日小卷不与修行录抢，两栏上面的通栏一格（纸笺）排得对、不出时不留卡距。
// 时段、说法这些纯函数在 CoreCheck（DashboardCues）。

extension SelfTest {
    @MainActor
    static func hooksChecks(_ check: (Bool, String) -> Void) throws {
        let container = try DataStore.makeContainer(inMemory: true)
        let context = container.mainContext
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        let today = LocalDay.today()
        // 一整周都已过去的那一周（两周前），结果不随今天是星期几变
        let week = WeeklyDigest.Week(monday: today.mondayOfWeek.adding(days: -14), today: today)

        func review(_ day: LocalDay, _ next: String, period: ReviewPeriod = .week) -> JournalEntry {
            let entry = JournalEntry(kind: .review, title: "", body: "【所得】\n读完一章\n【下一步】\n\(next)\n", dateKey: day.key)
            entry.period = period.rawValue
            context.insert(entry)
            return entry
        }

        // 1. 上次许下的下一步：前一个周日写的周复盘；本周六写的（许的是下一周）不算；60 天前那篇太久，不翻出来
        let before = review(week.monday.adding(days: -1), "1. 跑三次步 2. 早睡")
        let inside = review(week.monday.adding(days: 5), "下周的事")
        let ancient = review(week.monday.adding(days: -60), "很久以前的打算")
        DataStore.save(context)
        let content = WeeklyScrollContent.load(week: week, context: context)
        check(content.promise?.steps == ["跑三次步", "早睡"] && content.promise?.day == before.day
              && content.promise?.label.hasSuffix("周复盘") == true,
              "七日小卷“上次许下的下一步”：取这周一之前最近的周复盘（\(content.promise?.label ?? "无")），本周六写的不算")
        context.delete(before)
        DataStore.save(context)
        let stale = WeeklyScrollContent.load(week: week, context: context)
        check(stale.promise == nil, "七日小卷“上次许下的下一步”：只剩 60 天前的一篇时整节不出")
        // 周一当天写、没改日期的上周复盘也算
        let monday = review(week.monday, "先写 90 分钟")
        DataStore.save(context)
        let onMonday = WeeklyScrollContent.load(week: week, context: context)
        check(onMonday.promise?.steps == ["先写 90 分钟"] && onMonday.promise?.label.contains("写的周复盘") == true,
              "七日小卷“上次许下的下一步”：周一当天写的上周复盘也算，小标题写“X月X日写的周复盘”：\(onMonday.promise?.label ?? "无")")
        context.delete(monday)
        context.delete(inside)
        // 下面几条要“一篇周复盘都没有”：60 天前那篇也拿掉，否则 latest 先找到它、按太久不出，测不到退回日省这条路
        context.delete(ancient)
        DataStore.save(context)
        // 只写晚课日省（带【下一步】“明日第一件事”）、没有周复盘时整节不出：不退回去取周一那篇日省，也不取月复盘
        let daily = review(week.monday, "明早先写 30 分钟", period: .day)
        let saturdayDaily = review(week.monday.adding(days: -2), "周日去爬山", period: .day)
        let monthly = review(week.monday.adding(days: -3), "下个月每周读一本", period: .month)
        DataStore.save(context)
        let dailyOnly = WeeklyScrollContent.load(week: week, context: context)
        check(dailyOnly.promise == nil,
              "七日小卷“上次许下的下一步”：只有带【下一步】的日省（和月复盘）、没有周复盘时其六不出：\(dailyOnly.promise?.label ?? "无")")
        // 有周复盘时仍取周复盘，旁边更近的日省不抢
        let weekly = review(week.monday.adding(days: -8), "每天冥想")
        DataStore.save(context)
        let withWeekly = WeeklyScrollContent.load(week: week, context: context)
        check(withWeekly.promise?.day == weekly.day && withWeekly.promise?.steps == ["每天冥想"],
              "七日小卷“上次许下的下一步”：有周复盘时取周复盘，更近的日省、月复盘不抢：\(withWeekly.promise?.label ?? "无")")
        for entry in [daily, saturdayDaily, monthly, weekly] { context.delete(entry) }
        DataStore.save(context)

        // 2. 出关：最近一条记录（落笔、打卡里较晚的那天，不晚于今天）
        func last(_ day: LocalDay) -> LocalDay? {
            let entry = (try? context.fetch(DashboardHookData.lastEntry(through: day)))?.first?.dateKey
            let log = (try? context.fetch(DashboardHookData.lastLog(through: day)))?.first?.dateKey
            return DashboardHookData.lastRecord(entry: entry, log: log)
        }
        let fresh = try freshHooksContext()
        check((try? fresh.fetch(DashboardHookData.lastEntry(through: today)))?.isEmpty == true
              && DashboardCues.retreat(lastRecord: nil, today: today) == nil,
              "出关：从没记录过的不出")
        let habit = Habit(title: "冥想")
        context.insert(habit)
        let log = HabitLog(dateKey: today.adding(days: -4).key)
        context.insert(log)
        log.habit = habit
        // 明天的一篇（补记到以后的）不算“最近一条”
        context.insert(JournalEntry(kind: .diary, title: "", body: "明天的计划", dateKey: today.adding(days: 1).key))
        DataStore.save(context)
        let lastDay = last(today)
        check(lastDay == today.adding(days: -4) && lastDay.flatMap { DashboardCues.retreat(lastRecord: $0, today: today) } == 4,
              "出关：最近一条是 4 天前的打卡（落笔只有更早的、和补记到明天的），闭关 4 日")
        context.insert(JournalEntry(kind: .diary, title: "", body: "今天回来了", dateKey: today.key))
        DataStore.save(context)
        check(DashboardCues.retreat(lastRecord: last(today), today: today) == nil, "出关：今天一落笔这一行就收起")

        // 3. 纸笺只取那一周的篇目
        context.insert(JournalEntry(kind: .diary, title: "", body: "那一周周一", dateKey: week.monday.key))
        context.insert(JournalEntry(kind: .diary, title: "", body: "那一周周日", dateKey: week.sunday.key))
        context.insert(JournalEntry(kind: .diary, title: "", body: "前一周周日", dateKey: week.monday.adding(days: -1).key))
        context.insert(JournalEntry(kind: .diary, title: "", body: "下一周周一", dateKey: week.monday.adding(days: 7).key))
        DataStore.save(context)
        let inWeek = (try? context.fetchCount(FetchDescriptor<JournalEntry>(predicate: DashboardHookData.weekEntries(week)))) ?? -1
        check(inWeek == 2, "纸笺：只数那一周（周一到周日）的篇目，前后一周的不算：\(inWeek) 篇")

        // 4. 首页接七日小卷：首页在屏上、标志开着、没有要切到别的页才接
        check(DashboardWeeklyReceiver.shouldTake(onScreen: true, flag: true, pendingPage: nil)
              && DashboardWeeklyReceiver.shouldTake(onScreen: true, flag: true, pendingPage: .overview)
              && !DashboardWeeklyReceiver.shouldTake(onScreen: true, flag: true, pendingPage: .chronicle)
              && !DashboardWeeklyReceiver.shouldTake(onScreen: false, flag: true, pendingPage: nil)
              && !DashboardWeeklyReceiver.shouldTake(onScreen: true, flag: false, pendingPage: nil)
              && !AppRouter.shared.weeklyScroll,
              "首页接七日小卷：要切到修行录、或首页已不在屏上时留给修行录接；标志平时是关的")

        // 5. 通栏一格：排在两栏上面占满整宽；不出（高 0）时不留卡距；窄窗口上下排时排最前
        func height(_ top: CGFloat, width: CGFloat) -> CGFloat {
            let host = NSHostingView(rootView: OverviewColumns {
                Color.clear.frame(height: 100).overviewSlot(.left, stacked: 0)
                Color.clear.frame(height: 200).overviewSlot(.right, stacked: 1)
                Color.clear.frame(height: top).overviewSlot(.top, stacked: -1)
            }.frame(width: width))
            return host.fittingSize.height
        }
        let gutter = PageLayout.gutter
        let wide = height(44, width: 1000), hidden = height(0, width: 1000), narrow = height(44, width: 600)
        check(abs(wide - (44 + gutter + 200)) < 1 && abs(hidden - 200) < 1 && abs(narrow - (44 + 100 + 200 + 2 * gutter)) < 1,
              "首页通栏纸笺：两栏上面占一行（\(Int(wide))）、不出时不留卡距（\(Int(hidden))）、窄窗口上下排时排最前（\(Int(narrow))）")
    }

    @MainActor
    private static func freshHooksContext() throws -> ModelContext {
        let context = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: context)
        return context
    }
}
