import Foundation
import SwiftData

// 时辰卷周视图（#23）的运行时自检：真 SwiftData、内存库，不写正式偏好、不弹窗口、不碰系统通知。
// 叠放 / 并排、标题挪不挪、空周画几点、“每周一、四”的说法在 Tools/CoreCheck（// MARK: r2-schedule）里逐条测；
// 这里测接上数据库的那一段：真日程按周展开（ScheduleWindow 取数 → Occurrences.list）后交给周视图同一套换算
// （WeekGridView.spans → WeekStack.layout / frame），H2 那一天在 1180 / 1440 宽下每块都读得出；
// 标题下露出来多少（labelRoom）、指针下浮起哪一块（WeekStack.topmost）；全部日程一行里的重复方式与起止；
// 作息名字压着日程时不写、留到下一天；5 年数据下逐周翻一遍不卡。真窗口里悬停浮起、点开详情、双击新建要人手试。

extension SelfTest {
    static func scheduleChecks(_ check: (Bool, String) -> Void) throws {
        let container = try DataStore.makeContainer(inMemory: true)
        let context = container.mainContext
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        let today = LocalDay.today()
        let monday = today.mondayOfWeek
        let thursday = monday.adding(days: 3)
        func event(_ title: String, _ day: LocalDay, _ start: Int?, _ end: Int?, kind: RecurrenceKind = .none,
                   weekdays: [Int] = [], interval: Int = 1, location: String = "", category: String = "学业") -> ScheduleEvent {
            let e = ScheduleEvent(title: title, dateKey: day.key)
            e.startMinute = start
            e.endMinute = end
            e.recurrenceKind = kind
            e.weekdays = weekdays
            e.interval = interval
            e.location = location
            e.category = category
            context.insert(e)
            return e
        }
        // 视觉审计 H2 那一天：周一、四的 GEOS2115（13–15）、当天的图书馆写作（14–17）、隔周的导师会面（14–14:30）
        let geos = event("周视图自检 GEOS2115", monday.adding(days: -14), 13 * 60, 15 * 60, kind: .custom, weekdays: [0, 3], location: "Madsen 450")
        _ = event("周视图自检 图书馆写作", thursday, 14 * 60, 17 * 60, location: "Fisher 图书馆五楼")
        let supervisor = event("周视图自检 导师会面", thursday, 14 * 60, 14 * 60 + 30, kind: .weekly, interval: 2, location: "导师办公室")
        _ = event("周视图自检 全天", thursday, nil, nil)
        DataStore.save(context)

        let weekEvents = (try? context.fetch(ScheduleWindow.descriptor(from: monday, to: monday.adding(days: 6)))) ?? []
        let items = Occurrences.list(events: weekEvents, from: monday, to: monday.adding(days: 6))
        let thursdayTimed = WeekGridView.spans(items.filter { $0.day == thursday })
        check(thursdayTimed.count == 3 && items.contains { $0.day == thursday && $0.startMinute == nil },
              "周视图自检：周四展开出三件有钟点的日程和一件全天的（全天的不进叠放）")
        for width in [107.0, 144.0] {
            let slots = WeekStack.layout(thursdayTimed.map(\.span), dayWidth: width, labelMinutes: WeekGridView.labelMinutes)
            let frames = slots.map { WeekStack.frame($0, dayWidth: width) }
            let byTitle = Dictionary(uniqueKeysWithValues: zip(thursdayTimed.map(\.item.title), zip(slots, frames).map { $0 }))
            let library = byTitle["周视图自检 图书馆写作"]
            check(slots.allSatisfy(\.stacked) && frames.allSatisfy { $0.width >= WeekStack.compactWidth && $0.x + $0.width <= width - 2 + 0.001 }
                  && byTitle["周视图自检 GEOS2115"]?.0.column == 0 && byTitle["周视图自检 导师会面"]?.0.column == 2
                  && library?.0.column == 1 && library?.0.labelOffset == 30,
                  "周视图自检（一天 \(Int(width))pt）：H2 三件错位叠放，每块 ≥ 64pt 写得下时间和标题，图书馆写作的标题挪到导师会面结束的 14:30")
            // GEOS 在最下层，14:00 起被压住：标题只按露出来的 60 分钟挑写法
            check(byTitle["周视图自检 GEOS2115"]?.0.labelRoom == 60 && library?.0.labelRoom == 150,
                  "周视图自检（一天 \(Int(width))pt）：GEOS 标题下只露 60 分钟、图书馆写作从 14:30 露到 17:00")
            // 指针下浮起哪一块：按原先层次，与此刻谁浮着无关
            func lifted(_ minute: Double, _ x: Double) -> String? {
                WeekStack.topmost(at: minute, x: x, spans: thursdayTimed.map(\.span), slots: slots, dayWidth: width,
                                  minMinutes: 18.0 / 44 * 60).map { thursdayTimed[$0].item.title }
            }
            let picks = [lifted(13 * 60 + 30, 50), lifted(14 * 60 + 10, 40), lifted(16 * 60, 50)]
            check(picks == ["周视图自检 GEOS2115", "周视图自检 导师会面", "周视图自检 图书馆写作"],
                  "周视图自检（一天 \(Int(width))pt）：13:30 浮起 GEOS、14:10 x=40 浮起导师会面、16:00 浮起图书馆写作：\(picks.map { $0 ?? "无" })")
        }
        // 全部日程一行里的重复方式
        check(geos.rule.summary == "每周一、四", "全部日程：重复方式写“每周一、四”：\(geos.rule.summary)")
        // 全部日程那一行的小字：起止并成一段放在时段后面，不是今年的日期带年份（不入库，免得改了后面空周的检查）
        let ruleToday = LocalDay(key: "2026-10-22")!
        func series(_ start: String, _ weekdays: [Int], _ from: Int, _ to: Int, until: String? = nil, stop: String? = nil,
                    kind: RecurrenceKind = .custom) -> ScheduleEvent {
            let e = ScheduleEvent(title: "全部日程自检", dateKey: start)
            e.startMinute = from
            e.endMinute = to
            e.recurrenceKind = kind
            e.weekdays = weekdays
            e.repeatUntil = until
            e.stopBefore = stop
            return e
        }
        let whens = [
            RulesList.when(series("2024-10-23", [2, 5], 16 * 60 + 30, 18 * 60), today: ruleToday),
            RulesList.when(series("2025-08-03", [0, 3], 13 * 60, 15 * 60, until: "2026-11-07"), today: ruleToday),
            RulesList.when(series("2026-10-29", [3], 10 * 60, 11 * 60), today: ruleToday),
            RulesList.when(series("2025-03-03", [0], 9 * 60, 10 * 60, until: "2027-06-30", stop: "2026-11-02"), today: ruleToday),
            RulesList.when(series("2025-12-01", [], 9 * 60, 10 * 60, until: "2027-01-15", kind: .weekly), today: ruleToday),
            RulesList.when(series("2026-10-23", [], 19 * 60, 20 * 60, kind: .none), today: ruleToday),
        ]
        check(whens == ["每周三、六　16:30–18:00　自 2024年10月23日",
                        "每周一、四　13:00–15:00　2025年8月3日 – 11月7日",
                        "每周四　10:00–11:00　自 10月29日",
                        "每周一　09:00–10:00　2025年3月3日 – 11月1日",
                        "每周一　09:00–10:00　2025年12月1日 – 2027年1月15日",
                        "2026年10月23日 周五　19:00–20:00"],
              "全部日程一行：重复方式　时段　起止（不是今年的带年份，没有止日写“自 …”，停止的写到停止前一天）：\(whens)")

        // 作息名字：周三 18:00 的“运动”顶上压着 17:45 的健身房 → 周三不写（不只露一个图标），留到周四写；
        // 周三 12:00 的“午饭”没压着 → 周三写，周四同一段只留底纹
        let wednesday = monday.adding(days: 2)
        _ = event("周视图自检 健身房", wednesday, 17 * 60 + 45, 18 * 60 + 45, category: "运动")
        DataStore.save(context)
        let routine = [RoutineBlock(title: "周视图自检 运动", kind: "exercise", weekday: 2, startMinute: 18 * 60, endMinute: 19 * 60),
                       RoutineBlock(title: "周视图自检 运动", kind: "exercise", weekday: 3, startMinute: 18 * 60, endMinute: 19 * 60),
                       RoutineBlock(title: "周视图自检 午饭", kind: "meal", weekday: 2, startMinute: 12 * 60, endMinute: 13 * 60),
                       RoutineBlock(title: "周视图自检 午饭", kind: "meal", weekday: 3, startMinute: 12 * 60, endMinute: 13 * 60)]
        let week = LocalDay.range(monday, monday.adding(days: 6))
        let routineEvents = (try? context.fetch(ScheduleWindow.descriptor(from: monday, to: monday.adding(days: 6)))) ?? []
        let routineItems = Occurrences.list(events: routineEvents, from: monday, to: monday.adding(days: 6))
        let labels = WeekGridView.routineLabels(days: week, items: routineItems, routine: routine, startHour: 6)
        let exercise = "周视图自检 运动|1080|1140", lunch = "周视图自检 午饭|720|780"
        check(labels[wednesday] == [lunch] && labels[thursday] == [exercise],
              "周视图自检：作息名字压着日程那天不写、留到下一天；没压着的写一次，第二天只留底纹：周三 \(labels[wednesday] ?? []) 周四 \(labels[thursday] ?? [])")

        // 空周：两件重复的都改成到下周为止，30 周后那一周一件日程都没有 → 网格只画 08–20 点、格线淡一半
        geos.repeatUntil = monday.adding(days: 13).key
        supervisor.repeatUntil = monday.adding(days: 13).key
        DataStore.save(context)
        let farMonday = monday.adding(days: 7 * 30)
        let farEvents = (try? context.fetch(ScheduleWindow.descriptor(from: farMonday, to: farMonday.adding(days: 6)))) ?? []
        let farItems = Occurrences.list(events: farEvents, from: farMonday, to: farMonday.adding(days: 6))
        let farHours = WeekStack.hours(hasItems: !farItems.isEmpty, earliestMinute: farItems.compactMap(\.startMinute).min())
        check(farItems.isEmpty && farHours == 8..<20, "周视图自检：重复日程截止以后的空周只画 08–20 点")

        // 5 年数据：七成的日子有一两件单次（约 1700 件）、十二门每周两次的课；逐周往回翻 52 周，按窗口取数 + 展开 + 七天叠放，平均每周要快
        var rng = WeekStackCheckRandom(state: 2023)
        let fiveYearsAgo = today.adding(days: -365 * 5)
        for offset in stride(from: 0, to: 365 * 5, by: 1) where Int.random(in: 0..<10, using: &rng) < 7 {
            let day = fiveYearsAgo.adding(days: offset)
            let start = Int.random(in: 8...20, using: &rng) * 60
            _ = event("五年自检\(offset)", day, start, start + Int.random(in: 1...4, using: &rng) * 30)
            if offset % 3 == 0 { _ = event("五年自检同时\(offset)", day, start, start + 60) }
        }
        for index in 0..<12 {
            _ = event("五年自检课\(index)", fiveYearsAgo.adding(days: index * 140), 9 * 60 + index * 30, 11 * 60 + index * 30,
                      kind: .custom, weekdays: [index % 5, (index + 2) % 5])
        }
        DataStore.save(context)
        let began = Date()
        var stackedDays = 0
        for week in 0..<52 {
            let first = monday.adding(days: -7 * week)
            let events = (try? context.fetch(ScheduleWindow.descriptor(from: first, to: first.adding(days: 6)))) ?? []
            let weekItems = Occurrences.list(events: events, from: first, to: first.adding(days: 6))
            for day in LocalDay.range(first, first.adding(days: 6)) {
                let slots = WeekStack.layout(WeekGridView.spans(weekItems.filter { $0.day == day }).map(\.span), dayWidth: 107,
                                             labelMinutes: WeekGridView.labelMinutes)
                if slots.contains(where: \.stacked) { stackedDays += 1 }
            }
        }
        let perWeek = Date().timeIntervalSince(began) / 52
        check(perWeek < 0.25 && stackedDays > 0,
              "5 年数据：逐周翻 52 周（取数 + 展开 + 七天叠放）平均每周 \(Int(perWeek * 1000)) ms，不卡；其中 \(stackedDays) 天有叠放")
    }
}

/// 自检用的定种子随机数（SplitMix64），每次跑出来的 5 年数据都一样
private struct WeekStackCheckRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
