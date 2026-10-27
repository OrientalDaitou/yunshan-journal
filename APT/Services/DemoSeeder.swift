#if DEBUG
import Foundation
import SwiftData

/// 演示 / 压力数据生成器（只编进调试版）。
///
/// - `APT_STORE_DIR=<空文件夹> APT --seed-demo <年数>`：在这个文件夹里新建数据库，写入一位虚构修士（青岚，悉尼的研究生）
///   最近 N 年的修行录、习惯与打卡、日程与作息、目标、档案和灵石账簿。没设 APT_STORE_DIR、或文件夹里已经有 APT.store 时拒绝运行。
/// - `--seed-demo <天数>d`（例如 14d）：“轻度新手”——同一位修士刚用了这么些天，记录很少：几篇日记与灵感、
///   2–3 个习惯零星打卡、几笔手记、一两条日程、档案只填了几项；没有复盘、目标、作息，也没有导入过银行账单。审计新手阶段用。
/// - 离屏渲染设 `APT_RENDER_DEMO=<年数>`（或 `<天数>d`）时，PageRenderer 在内存库里用它造同样的数据。
///
/// 规矩：
/// - 固定种子的伪随机数（SplitMix64，各类数据各用一条随机流）：同一个“今天”、同样的年数，每次生成的内容完全相同；
/// - 写法与应用自己写入时一致：日期一律 `YYYY-MM-DD`，时刻是“当天第几分钟”；修为由打卡与落笔实时计算，不另存；
///   数量型习惯改过目标的，改之前的打卡记着当时的目标（targetAtLog，同 HabitQuantity.recordTargetsBeforeChange）；
/// - 灵石账簿按月生成 CommBank 格式的 CSV，经 FinanceEngine.previewImport / applyImport 导入（交易 ID、自动分类与真导入相同），
///   再像用户那样确认分类（记住商户、同商户批量归类）、手记现金消费、设预算、标记固定账单、存月卷，最后经 FinanceService 整本写回。
@MainActor
enum DemoSeeder {
    // MARK: - 命令行

    /// 演示数据的规模：`<年数>`（1–20，原来的写法）或 `<天数>d`（轻度新手，7–60 天，例如 14d）
    enum Scale: Equatable {
        case years(Int)
        case light(days: Int)

        static let yearRange = 1...20
        static let lightRange = 7...60

        /// 认不出、或超出范围时为 nil
        init?(_ text: String?) {
            guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
            if let years = Int(text) {
                guard Self.yearRange.contains(years) else { return nil }
                self = .years(years)
            } else if text.hasSuffix("d"), let days = Int(text.dropLast()), Self.lightRange.contains(days) {
                self = .light(days: days)
            } else {
                return nil
            }
        }
    }

    /// `APT --seed-demo <年数>` 或 `<天数>d`：返回退出码（0 成功；1 写入出错；2 拒绝运行或参数不对）。
    static func commandLine(_ argument: String?) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let custom = DataStore.customDirectory else {
            print("拒绝运行：没有设置 APT_STORE_DIR。演示数据只写进单独的空文件夹，不碰正式数据，例如：")
            print("  APT_STORE_DIR=\"$PWD/.night/demo-store\" APT --seed-demo 2")
            return 2
        }
        // 双保险：APT_STORE_DIR 指向的就是正式数据目录时同样拒绝
        if let official = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("APT-SwiftUI", isDirectory: true),
           custom.standardizedFileURL.resolvingSymlinksInPath().path == official.standardizedFileURL.resolvingSymlinksInPath().path {
            print("拒绝运行：APT_STORE_DIR 指向的是正式数据目录（\(official.path)）。")
            return 2
        }
        guard let scale = Scale(argument) else {
            print("用法：APT_STORE_DIR=<空文件夹> APT --seed-demo <年数>（1–20）")
            print("  或：APT_STORE_DIR=<空文件夹> APT --seed-demo <天数>d（轻度新手，7–60 天，例如 14d：只用了 14 天、记录很少）")
            return 2
        }
        guard !FileManager.default.fileExists(atPath: DataStore.storeURL.path) else {
            print("拒绝运行：\(DataStore.storeURL.path) 已经存在，为免覆盖没有写入。请换一个空文件夹。")
            return 2
        }
        guard InstanceLock.acquire() else {
            print("拒绝运行：另一个云山修习录进程正在使用这个数据文件夹。")
            return 2
        }
        do {
            let container = try DataStore.makeContainer()
            let context = ModelContext(container)
            print("数据库：\(DataStore.storeURL.path)")
            let report = seed(into: context, scale: scale)
            report.lines.forEach { print($0) }
            return report.problems.isEmpty ? 0 : 1
        } catch {
            print("打开失败：\(DataStore.describe(error))")
            return 1
        }
    }

    // MARK: - 结果

    struct Report {
        var years: Int
        var first: LocalDay
        var last: LocalDay
        var diaries = 0, notes = 0, weeklyReviews = 0, monthlyReviews = 0, pinned = 0
        var habits = 0, archivedHabits = 0, habitLogs = 0
        var events = 0, recurringEvents = 0, routineBlocks = 0
        var goals = 0, profileFields = 0
        var transactions = 0, manual = 0, refunds = 0, pendingReview = 0, ignored = 0
        var imports = 0, rules = 0, monthlyReports = 0
        var seconds = 0.0
        var problems: [String] = []
        /// 轻度新手（`<天数>d`）：用了几天；按年生成的为 nil
        var lightDays: Int? = nil

        var journal: Int { diaries + notes + weeklyReviews + monthlyReviews }

        var lines: [String] {
            [
                lightDays.map { "演示数据（轻度新手）：\(first.key) 至 \(last.key)（只用了 \($0) 天）" } ?? "演示数据：\(first.key) 至 \(last.key)（\(years) 年）",
                "修行录 \(journal)（日记 \(diaries)，灵感 \(notes)，周复盘 \(weeklyReviews)，月复盘 \(monthlyReviews)；珍藏 \(pinned)）",
                "习惯 \(habits)（已归档 \(archivedHabits)），打卡 \(habitLogs)",
                "日程 \(events)（重复 \(recurringEvents)），作息 \(routineBlocks)，目标 \(goals)，档案 \(profileFields)/\(ProfileCatalog.allFields.count) 项",
                "账簿交易 \(transactions)（手记 \(manual)，退款 \(refunds)，待确认 \(pendingReview)，不计入 \(ignored)），"
                    + "导入 \(imports) 次，分类记忆 \(rules) 条，月卷 \(monthlyReports) 份",
                String(format: "用时 %.1f 秒", seconds),
            ] + problems.map { "问题：\($0)" }
        }
    }

    // MARK: - 入口

    /// 往 context 里写入截至 today 的 years 年演示数据，并保存。设置（AppSettings）保持默认（没有就建一条默认的）。
    @discardableResult
    static func seed(into context: ModelContext, years: Int, endingAt today: LocalDay = .today()) -> Report {
        let started = Date()
        let years = max(1, min(20, years))
        let calendar = DemoCalendar(first: today.adding(days: -365 * years + 1), today: today)
        var report = Report(years: years, first: calendar.first, last: today)
        DataStore.settings(in: context)
        seedProfile(context, calendar, &report)
        seedGoals(context, calendar, &report)
        seedRoutine(context, &report)
        seedEvents(context, calendar, &report)
        let tracks = seedHabits(context, calendar, &report)
        seedJournal(context, calendar, tracks, &report)
        do {
            try context.save()
        } catch {
            report.problems.append("保存失败：\(DataStore.describe(error))")
        }
        seedLedger(context, calendar, &report)
        report.seconds = Date().timeIntervalSince(started)
        return report
    }

    /// 按规模写入：年数照原来的 seed(into:years:)；`<天数>d` 写轻度新手（seedLight）
    @discardableResult
    static func seed(into context: ModelContext, scale: Scale, endingAt today: LocalDay = .today()) -> Report {
        switch scale {
        case .years(let years): seed(into: context, years: years, endingAt: today)
        case .light(let days): seedLight(into: context, days: days, endingAt: today)
        }
    }

    // MARK: - 轻度新手

    /// 轻度新手：同一位修士刚用了 days 天（今天是第 days 天），记录很少，并保存。
    /// 按 14 天写好一份“剧本”（第 0…13 天各做了什么），天数不是 14 时按比例摊开；同一个习惯落到同一天的打卡只留一条。
    /// 有：档案 4 项、5 篇日记（1 篇珍藏）、2 条灵感、3 个习惯 11 条零星打卡（今天只打了 1 个）、5 笔手记、2 条日程；
    /// 没有：复盘、目标、作息、传书、银行账单。今天还没落笔，好看新手打开时的样子。
    @discardableResult
    static func seedLight(into context: ModelContext, days: Int, endingAt today: LocalDay = .today()) -> Report {
        let started = Date()
        let days = max(Scale.lightRange.lowerBound, min(Scale.lightRange.upperBound, days))
        let first = today.adding(days: -(days - 1))
        var report = Report(years: 0, first: first, last: today)
        report.lightDays = days
        var rng = SplitMix64(stream: 11)
        /// 剧本里的第 p 天（0…13）落到实际的哪一天
        func at(_ p: Int) -> LocalDay { first.adding(days: Int((Double(p) * Double(days - 1) / 13).rounded())) }

        DataStore.settings(in: context)
        // 档案：第一天只填了称呼、城市、身份和手头的事
        let profile = DataStore.profile(in: context)
        var fields = profile.fields
        for (key, value) in [("nickname", "青岚"), ("city", "悉尼"), ("identity", "研究生"), ("main_tasks", "写学位论文；每周两次高中数学补习。")] {
            fields[key] = value
        }
        profile.fields = fields
        profile.createdAt = at(0).date(minutes: 21 * 60 + 20)
        profile.updatedAt = at(0).date(minutes: 21 * 60 + 32)
        report.profileFields = ProfileCatalog.allFields.filter { !(fields[$0.key] ?? "").isEmpty }.count

        // 修行录：几篇短日记、两条灵感，没有复盘；今天还没写
        let entries: [(p: Int, kind: JournalKind, minute: Int?, title: String, body: String, mood: Int?, tags: [String], pinned: Bool)] = [
            (0, .diary, 21 * 60 + 40, "开个头", "今天装了云山修习录，先随手记几句。这周主要是改论文第三章，导师周四要看。", 3, ["开始"], false),
            (1, .diary, 22 * 60 + 15, "", "上午写了一个多小时，比想象中顺。下午去图书馆还书，顺路买了咖啡。", 4, ["论文"], false),
            (3, .note, 15 * 60 + 20, "", "想到一个标题：街道树冠与午后地表温度。先记下来。", nil, ["论文"], false),
            (4, .diary, 23 * 60 + 5, "", "补习回来有点累，今天没怎么写。明天早点起，先把晨读补上。", 2, ["补习"], false),
            (9, .diary, 21 * 60 + 30, "", "和导师聊了二十分钟，第三章的框架大致定了，心里踏实一些。晚上自己做了顿饭。", 4, ["论文", "导师"], true),
            (10, .note, nil, "", "复盘也许可以只写三句：做了什么、卡在哪、明天第一件事。", nil, ["方法"], false),
            (12, .diary, 22 * 60 + 40, "", "这几天有点散，记录也断了几天。周末想重新排一下每天的节奏。", 3, [], false),
        ]
        for item in entries {
            let day = at(item.p)
            let entry = JournalEntry(kind: item.kind, title: item.title, body: item.body, dateKey: day.key)
            entry.uid = rng.uuid()
            entry.minute = item.minute
            entry.mood = item.mood
            entry.tags = item.tags
            entry.pinned = item.pinned
            entry.createdAt = day.date(minutes: item.minute ?? 22 * 60)
            entry.updatedAt = entry.createdAt
            context.insert(entry)
            if item.kind == .diary { report.diaries += 1 } else { report.notes += 1 }
            if item.pinned { report.pinned += 1 }
        }

        // 习惯：第 0、2、4 天各建了一个，打卡零零星星（数量型的有一天没喝够）
        let habits: [(p: Int, title: String, category: String, symbol: String, frequency: HabitFrequency, perWeek: Int, target: Double?, unit: String,
                      logs: [(p: Int, quantity: Double?)])] = [
            (0, "晨读二十分钟", "学习", "book", .daily, 1, nil, "", [(1, nil), (2, nil), (3, nil), (6, nil), (10, nil), (13, nil)]),
            (2, "喝水", "健康", "drop", .daily, 1, 8, "杯", [(2, 5), (3, 8), (7, 9)]),
            (4, "运动", "健康", "figure.run", .weekly, 3, nil, "", [(4, nil), (9, nil)]),
        ]
        for (index, item) in habits.enumerated() {
            let start = at(item.p)
            let habit = Habit(title: item.title)
            habit.category = item.category
            habit.symbol = item.symbol
            habit.frequencyKind = item.frequency
            habit.targetPerWeek = item.frequency == .weekly ? item.perWeek : 1
            habit.targetValue = item.target
            habit.unit = item.unit
            habit.startDate = start.key
            habit.sortOrder = index
            habit.createdAt = start.date(minutes: 20 * 60 + 5 + index * 7)
            habit.updatedAt = habit.createdAt
            context.insert(habit)
            report.habits += 1
            var logged = Set<String>()
            for log in item.logs {
                let day = at(log.p)
                guard day >= start, logged.insert(day.key).inserted else { continue }
                let entry = HabitLog(dateKey: day.key, completed: true, quantity: log.quantity)
                entry.createdAt = day.date(minutes: 8 * 60 + rng.int(0...600))
                entry.updatedAt = entry.createdAt
                context.insert(entry)
                entry.habit = habit
                habit.updatedAt = max(habit.updatedAt, entry.createdAt)
                report.habitLogs += 1
            }
        }

        // 日程：一条已经过去的导师面谈、一条还没到的组会
        let events: [(day: LocalDay, made: LocalDay, title: String, start: Int, end: Int, location: String)] = [
            (at(9), at(5), "和导师面谈", 15 * 60, 15 * 60 + 30, "导师办公室"),
            (today.adding(days: 3), at(11), "组会", 10 * 60, 11 * 60, "地理系 F09 会议室"),
        ]
        for item in events {
            let event = ScheduleEvent(title: item.title, dateKey: item.day.key)
            event.startMinute = item.start
            event.endMinute = item.end
            event.category = "学业"
            event.location = item.location
            event.priority = "must"
            event.createdAt = item.made.date(minutes: 21 * 60)
            event.updatedAt = event.createdAt
            context.insert(event)
            report.events += 1
        }
        do {
            try context.save()
        } catch {
            report.problems.append("保存失败：\(DataStore.describe(error))")
        }

        // 灵石账簿：只有几笔随手记的现金 / 小额消费，没导入过银行账单
        let expenses: [(p: Int, description: String, category: String, cents: Int, reason: String)] = [
            (0, "咖啡", "餐饮与外卖", 520, "随手记"),
            (1, "超市 水果和牛奶", "超市与食品", 1840, "手动记账"),
            (4, "午饭 拉面", "餐饮与外卖", 1680, "随手记"),
            (8, "打印讲义", "教育与学费", 300, "手动记账"),
            (11, "早餐 煎饼", "餐饮与外卖", 750, "随手记"),
        ]
        var ledger = FinanceLedger()
        for item in expenses {
            ledger.transactions.append(ManualExpense.transaction(id: "manual-" + rng.uuid(), day: at(item.p), cents: item.cents, category: item.category,
                                                                 description: item.description, note: "", reason: item.reason))
        }
        do {
            try FinanceService.save(ledger, context: context)
            report.transactions = ledger.transactions.count
            report.manual = ledger.transactions.filter(\.isManual).count
        } catch {
            report.problems.append("账簿：\(error.localizedDescription)")
        }
        report.seconds = Date().timeIntervalSince(started)
        return report
    }

    // MARK: - 伪随机数与日历

    /// SplitMix64：固定种子、可复现。不用系统随机数，也不用标准库的 random(in:using:)（算法不保证跨版本不变）。
    struct SplitMix64 {
        private var state: UInt64

        /// 每类数据一条独立的随机流：改了某一类的生成方式，其他类别的内容不跟着变
        init(stream: UInt64) { state = 0x5EED_A97D_E302_6A01 &+ stream &* 0x9E37_79B9_7F4A_7C15 }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// [0, 1)
        mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992 }
        mutating func chance(_ p: Double) -> Bool { unit() < p }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func double(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }
        mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }

        mutating func weighted(_ weights: [Double]) -> Int {
            var x = unit() * weights.reduce(0, +)
            for (index, weight) in weights.enumerated() {
                if x < weight { return index }
                x -= weight
            }
            return weights.count - 1
        }

        /// 不放回地取 k 个（保持原来的先后顺序）
        mutating func sample<T>(_ items: [T], _ k: Int) -> [T] {
            var indices = Array(items.indices)
            let k = min(k, items.count)
            for i in 0..<k { indices.swapAt(i, i + Int(next() % UInt64(indices.count - i))) }
            return indices.prefix(k).sorted().map { items[$0] }
        }

        /// 形如 UUID 的稳定 ID（修行录的 uid、手记的交易 ID）
        mutating func uuid() -> String {
            let a = next(), b = next()
            return String(format: "%08X-%04X-%04X-%04X-%012llX",
                          UInt32(truncatingIfNeeded: a >> 32), UInt32(truncatingIfNeeded: (a >> 16) & 0xFFFF),
                          UInt32(truncatingIfNeeded: (a & 0x0FFF) | 0x4000), UInt32(truncatingIfNeeded: ((b >> 48) & 0x3FFF) | 0x8000),
                          b & 0xFFFF_FFFF_FFFF)
        }
    }

    /// 这位修士的一年：悉尼的学期、考试周，每年 12/22 – 次年 1/14 回国过年。
    struct DemoCalendar {
        let first: LocalDay
        let today: LocalDay

        var span: Int { max(1, first.days(to: today)) }
        /// 在整段时间里的位置（0 = 第一天，1 = 今天）
        func t(_ day: LocalDay) -> Double { Double(first.days(to: day)) / Double(span) }
        func day(at fraction: Double) -> LocalDay { first.adding(days: Int(Double(span) * fraction)) }

        func isAway(_ day: LocalDay) -> Bool { (day.month == 12 && day.day >= 22) || (day.month == 1 && day.day <= 14) }

        func isSemester(_ day: LocalDay) -> Bool {
            switch day.month {
            case 3, 4, 5, 8, 9, 10: true
            case 2: day.day >= 24
            case 6: day.day <= 13
            case 7: day.day >= 28
            case 11: day.day <= 7
            default: false
            }
        }

        func isCrunch(_ day: LocalDay) -> Bool { (day.month == 6 && day.day <= 20) || (day.month == 11 && day.day <= 15) }
        func isSummer(_ day: LocalDay) -> Bool { [12, 1, 2].contains(day.month) }
        func isWinter(_ day: LocalDay) -> Bool { [6, 7, 8].contains(day.month) }

        /// day 当天或之后第一个星期 weekday（0 = 周一）
        static func next(_ weekday: Int, onOrAfter day: LocalDay) -> LocalDay {
            day.adding(days: (weekday - day.weekdayIndex + 7) % 7)
        }

        /// ISO 周数（周一开始，含周四的那一年）
        static func isoWeek(_ day: LocalDay) -> Int {
            let thursday = day.mondayOfWeek.adding(days: 3)
            return LocalDay(year: thursday.year, month: 1, day: 1).days(to: thursday) / 7 + 1
        }
    }

    // MARK: - 档案、目标、作息

    private static func seedProfile(_ context: ModelContext, _ cal: DemoCalendar, _ report: inout Report) {
        let profile = DataStore.profile(in: context)
        let values: [(String, String)] = [
            ("nickname", "青岚"),
            ("name", "沈青岚"),
            ("preferred_name", "青岚"),
            ("city", "悉尼"),
            ("timezone", "Australia/Sydney"),
            ("identity", "研究生"),
            ("school", "悉尼某大学 · 地理系"),
            ("major", "城市地理 / 遥感"),
            ("work_status", "研究第二年"),
            ("main_tasks", "写学位论文（城市热岛与绿地降温）；每周两次高中数学补习；学期中带一门课的 tutorial。"),
            ("important_project", "学位论文第三、四章：用遥感影像估算街道树冠对地表温度的影响。"),
            ("current_stage", "数据基本跑完，进入集中写作期。补习和助教占掉不少时间，需要守住上午的写作时段。"),
            ("concerns", "毕业后的签证与工作方向还没想清楚；写作进度偶尔落后。"),
            ("stress_sources", "导师反馈周期长；房租和生活成本；晚上容易拖到很晚。"),
            ("improvements", "23:30 前收工；少点外卖；每周日固定复盘。"),
            ("academic_goals", "按时提交学位论文，争取一篇期刊发表。"),
            ("career_goals", "毕业后进入城市规划或环境咨询方向的研究岗位。"),
            ("financial_goals", "存够三个月生活费的应急金；每月定投一小部分。"),
            ("learning_goals", "把 Python 空间分析和统计建模练扎实。"),
            ("preferred_work_time", "上午 9–12 点效率最高，晚上适合读文献"),
            ("study_preference", "先看图和结论再决定细读；边读边写一句话摘要。"),
            ("work_style", "先搭骨架再填细节；需要整块不被打扰的时间。"),
            ("software", "Zotero、VS Code、QGIS、Python（pandas / rasterio）"),
            ("working_methods", "番茄钟（50 + 10）、每周复盘、睡前写下明天第一件事。"),
            ("rest_preferences", "海边散步、做饭、弹琴、和家里视频。"),
        ]
        var fields = profile.fields
        for (key, value) in values { fields[key] = value }
        profile.fields = fields
        profile.createdAt = cal.first.date(minutes: 20 * 60)
        profile.updatedAt = cal.today.adding(days: -9).date(minutes: 21 * 60 + 10)
        report.profileFields = ProfileCatalog.allFields.filter { !(fields[$0.key] ?? "").isEmpty }.count
    }

    private static func seedGoals(_ context: ModelContext, _ cal: DemoCalendar, _ report: inout Report) {
        // 标题、说明、类别、优先级、状态、进度、截止（距今天的天数）、备注、建立于（0…1）
        let goals: [(String, String, String, String, String, Int, Int?, String, Double)] = [
            ("完成学位论文初稿", "六章，约八万字；第三、四章是核心。", "学业", "must", "active", 65, 120, "每天上午先写 90 分钟。", 0.0),
            ("投出第一篇期刊论文", "以第三章为基础改写成论文。", "学业", "must", "completed", 100, -45, "已投稿，等审稿意见。", 0.15),
            ("每周运动三次，坚持一年", "跑步、力量训练都算。", "健康", "should", "active", 72, 60, "", 0.3),
            ("存下三个月生活费的应急金", "单独放在储蓄账户，不动它。", "财务", "should", "completed", 100, -20, "提前完成，之后改为每月定投。", 0.05),
            ("学会弹完整首《卡农》", "", "爱好", "could", "paused", 40, nil, "论文写作期先放一放。", 0.2),
            ("今年读完 24 本书", "专业书和闲书各一半。", "成长", "should", "active", 55, 72, "", 0.6),
            ("考澳洲驾照", "", "生活", "could", "cancelled", 20, nil, "暂时用不上，工作后再说。", 0.25),
            ("毕业后找到研究型岗位", "城市规划或环境咨询方向。", "职业", "must", "active", 15, 300, "先整理作品集，联系两位前辈聊聊。", 0.7),
        ]
        for item in goals {
            let goal = Goal(title: item.0)
            goal.detail = item.1
            goal.category = item.2
            goal.priority = item.3
            goal.status = item.4
            goal.progress = item.5
            goal.targetDate = item.6.map { cal.today.adding(days: $0).key }
            goal.notes = item.7
            goal.createdAt = cal.day(at: item.8).date(minutes: 21 * 60)
            goal.updatedAt = cal.today.adding(days: -Int(Double(cal.span) * 0.02) - 1).date(minutes: 21 * 60)
            context.insert(goal)
            report.goals += 1
        }
    }

    private static func seedRoutine(_ context: ModelContext, _ report: inout Report) {
        let weekdays = Array(0...4), everyday = Array(0...6)
        // 跨夜睡眠：周日到周四 23:30–07:30；周五、周六晚睡，记在次日 00:30–08:30
        let blocks: [(String, RoutineKind, [Int], Int, Int, String)] = [
            ("睡眠", .sleep, [6, 0, 1, 2, 3], 23 * 60 + 30, 7 * 60 + 30, "手机放客厅充电"),
            ("睡眠", .sleep, [5, 6], 30, 8 * 60 + 30, "周末晚一点"),
            ("早餐", .meal, weekdays, 7 * 60 + 45, 8 * 60 + 15, ""),
            ("早午餐", .meal, [5, 6], 9 * 60 + 30, 10 * 60 + 30, ""),
            ("通勤", .commute, weekdays, 8 * 60 + 20, 8 * 60 + 50, "路上听播客"),
            ("上午写作", .study, weekdays, 9 * 60, 12 * 60, "只写论文，不看邮件"),
            ("午餐", .meal, weekdays, 12 * 60, 13 * 60, ""),
            ("下午研究", .work, weekdays, 14 * 60, 17 * 60 + 30, "跑数据、读文献、备课"),
            ("运动", .exercise, [0, 2, 4], 17 * 60 + 45, 18 * 60 + 45, ""),
            ("晚餐", .meal, everyday, 18 * 60 + 45, 19 * 60 + 30, ""),
            ("晚间自由", .focus, weekdays, 20 * 60, 22 * 60, "可安排杂事或读文献"),
            ("睡前阅读", .rest, everyday, 22 * 60 + 45, 23 * 60 + 20, "闲书，不看屏幕"),
        ]
        for (title, kind, days, start, end, note) in blocks {
            for day in days {
                let block = RoutineBlock(title: title, kind: kind.rawValue, weekday: day, startMinute: start, endMinute: end)
                block.note = note
                context.insert(block)
                report.routineBlocks += 1
            }
        }
    }

    // MARK: - 日程

    private struct EventTemplate {
        var titles: [String]
        var category: String
        var location: String
        /// nil 为全天
        var start: Int?
        var minutes: Int
        var priority: String
        /// true 只在周末；false 只在工作日；nil 不限
        var weekend: Bool?
        var notes: [String] = [""]
    }

    private static let eventTemplates: [EventTemplate] = [
        EventTemplate(titles: ["牙医检查", "洗牙"], category: "健康", location: "Broadway 牙科诊所", start: 10 * 60 + 30, minutes: 45, priority: "should", weekend: false),
        EventTemplate(titles: ["体检"], category: "健康", location: "大学健康中心", start: 9 * 60, minutes: 60, priority: "should", weekend: false, notes: ["空腹", ""]),
        EventTemplate(titles: ["第二章交导师", "第三章交导师", "会议摘要截止", "年度进展报告截止", "伦理审批材料截止"], category: "学业", location: "",
                      start: nil, minutes: 0, priority: "must", weekend: false),
        EventTemplate(titles: ["年度进展答辩"], category: "学业", location: "地理系 F23 会议室", start: 14 * 60, minutes: 90, priority: "must", weekend: false,
                      notes: ["提前一天把幻灯片发给委员会", ""]),
        EventTemplate(titles: ["学术会议报告（线上）"], category: "学业", location: "Zoom", start: 10 * 60, minutes: 20, priority: "must", weekend: false),
        EventTemplate(titles: ["系里研讨会", "写作工作坊"], category: "学业", location: "Carslaw 350", start: 16 * 60, minutes: 60, priority: "could", weekend: false),
        EventTemplate(titles: ["和导师单独面谈"], category: "学业", location: "导师办公室", start: 15 * 60, minutes: 45, priority: "must", weekend: false,
                      notes: ["带上第三章的问题清单", ""]),
        EventTemplate(titles: ["图书馆培训：文献管理", "实验室安全培训"], category: "学业", location: "Fisher 图书馆", start: 13 * 60, minutes: 60, priority: "could", weekend: false),
        EventTemplate(titles: ["Mia 生日聚餐", "和阿哲吃火锅", "小雨的乔迁聚会", "师门聚餐"], category: "社交", location: "Haymarket", start: 18 * 60 + 30, minutes: 150,
                      priority: "should", weekend: true),
        EventTemplate(titles: ["剪头发"], category: "生活", location: "Chatswood", start: 15 * 60, minutes: 40, priority: "could", weekend: nil),
        EventTemplate(titles: ["取快递", "去银行办卡"], category: "生活", location: "Broadway", start: 12 * 60 + 30, minutes: 30, priority: "could", weekend: false),
        EventTemplate(titles: ["看房", "房屋检查"], category: "生活", location: "Ultimo", start: 11 * 60, minutes: 60, priority: "should", weekend: true),
        EventTemplate(titles: ["演唱会", "话剧"], category: "娱乐", location: "ICC Sydney", start: 19 * 60 + 30, minutes: 180, priority: "could", weekend: true),
        EventTemplate(titles: ["电影"], category: "娱乐", location: "Event Cinemas George St", start: 20 * 60, minutes: 135, priority: "could", weekend: true),
        EventTemplate(titles: ["徒步：蓝山", "渡轮去 Manly", "海岸步道 Bondi 到 Coogee"], category: "出游", location: "", start: 8 * 60, minutes: 480,
                      priority: "could", weekend: true, notes: ["带水和防晒", ""]),
        EventTemplate(titles: ["给外婆打电话"], category: "家人", location: "", start: 20 * 60, minutes: 30, priority: "should", weekend: nil),
        EventTemplate(titles: ["签证材料递交", "护照续期预约"], category: "事务", location: "", start: nil, minutes: 0, priority: "must", weekend: false),
        EventTemplate(titles: ["帮师兄搬器材"], category: "社交", location: "地理系实验楼", start: 10 * 60, minutes: 120, priority: "could", weekend: true),
    ]

    private static func seedEvents(_ context: ModelContext, _ cal: DemoCalendar, _ report: inout Report) {
        var rng = SplitMix64(stream: 3)
        let horizon = cal.today.adding(days: 60)

        @discardableResult
        func add(_ title: String, _ day: LocalDay, _ start: Int?, _ end: Int?, category: String, location: String = "",
                 priority: String = "should", notes: String = "") -> ScheduleEvent {
            let event = ScheduleEvent(title: title, dateKey: day.key)
            event.startMinute = start
            event.endMinute = end
            event.category = category
            event.location = location
            event.priority = priority
            event.notes = notes
            event.createdAt = min(day, cal.today).adding(days: -rng.int(2...12)).date(minutes: 21 * 60 + rng.int(0...50))
            event.updatedAt = event.createdAt
            context.insert(event)
            report.events += 1
            return event
        }

        @discardableResult
        func series(_ title: String, from day: LocalDay, _ start: Int?, _ end: Int?, kind: RecurrenceKind, interval: Int = 1,
                    weekdays: [Int] = [], until: LocalDay? = nil, stopBefore: LocalDay? = nil, category: String,
                    location: String = "", priority: String = "should", notes: String = "") -> ScheduleEvent {
            let event = add(title, day, start, end, category: category, location: location, priority: priority, notes: notes)
            event.recurrenceKind = kind
            event.interval = interval
            event.weekdays = weekdays
            event.repeatUntil = until?.key
            event.stopBefore = stopBefore?.key
            report.recurringEvents += 1
            return event
        }

        /// 回国期间跳过的那几次
        func awayDates(_ event: ScheduleEvent) -> [String] {
            let rule = event.rule
            return rule.occurrences(from: rule.start, to: horizon).map(\.sourceDay).filter { cal.isAway($0) }.map(\.key)
        }

        // 组会：每周二，回国期间跳过；有两次改到周三线上开
        let groupMeeting = series("组会", from: DemoCalendar.next(1, onOrAfter: cal.first), 10 * 60, 11 * 60, kind: .custom, weekdays: [1],
                                  category: "Research", location: "地理系 F09 会议室", priority: "must", notes: "轮到自己时提前一天发幻灯片")
        groupMeeting.excludedDates = awayDates(groupMeeting)
        let meetingDays = groupMeeting.rule.occurrences(from: groupMeeting.startDay, to: cal.today).map(\.sourceDay)
        if meetingDays.count > 6 {
            var patches: [String: OccurrencePatch] = [:]
            for day in rng.sample(meetingDays, 2) {
                patches[day.key] = OccurrencePatch(date: day.adding(days: 1).key, start_time: "10:00", end_time: "11:00", location: "Zoom")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(patches) { groupMeeting.overridesJSON = String(decoding: data, as: UTF8.self) }
        }

        let supervisor = series("导师会面", from: DemoCalendar.next(3, onOrAfter: cal.first), 14 * 60, 14 * 60 + 30, kind: .weekly, interval: 2,
                                category: "Research", location: "导师办公室", priority: "must")
        supervisor.excludedDates = awayDates(supervisor)
        let tutoring = series("补习：高中数学", from: DemoCalendar.next(2, onOrAfter: cal.first), 16 * 60 + 30, 18 * 60, kind: .custom, weekdays: [2, 5],
                              category: "Tutoring", location: "Chatswood 学生家", notes: "带上错题本")
        tutoring.excludedDates = awayDates(tutoring)
        series("周日采购", from: DemoCalendar.next(6, onOrAfter: cal.first), 10 * 60, 11 * 60, kind: .weekly, category: "生活", location: "Coles Broadway",
               priority: "could")
        series("给家里视频", from: DemoCalendar.next(5, onOrAfter: cal.first), 20 * 60, 21 * 60, kind: .weekly, category: "家人", priority: "should")
        series("交房租", from: DemoCalendar.next(4, onOrAfter: cal.first), nil, nil, kind: .daily, interval: 14, category: "生活", priority: "must",
               notes: "两周一次，网银转给房东")
        let gymStart = cal.day(at: 0.3)
        series("健身房", from: DemoCalendar.next(0, onOrAfter: gymStart), 17 * 60 + 45, 18 * 60 + 45, kind: .custom, weekdays: [0, 2, 4],
               category: "健康", location: "Anytime Fitness Chatswood", priority: "could")
        series("读书会", from: DemoCalendar.next(6, onOrAfter: cal.first.adding(days: 20)), 15 * 60, 17 * 60, kind: .weekly, interval: 4,
               stopBefore: cal.day(at: 0.6), category: "社交", location: "Glebe 的咖啡馆", priority: "could")

        // 每个学期带一门课的 tutorial（学期结束即止）
        for year in cal.first.year...cal.today.year {
            for (index, (start, end)) in [(LocalDay(year: year, month: 2, day: 24), LocalDay(year: year, month: 6, day: 6)),
                                          (LocalDay(year: year, month: 7, day: 28), LocalDay(year: year, month: 11, day: 7))].enumerated() {
                let begin = DemoCalendar.next(0, onOrAfter: max(start, cal.first))
                guard begin <= end, begin <= horizon else { continue }
                series(index == 0 ? "GEOS1001 Tutorial" : "GEOS2115 Tutorial", from: begin, 13 * 60, 15 * 60, kind: .custom, weekdays: [0, 3],
                       until: end, category: "Teaching", location: index == 0 ? "Carslaw 275" : "Madsen 450", notes: "提前十分钟到教室开投影")
            }
        }

        // 每年固定的：回国航班、返回悉尼、生日
        for year in (cal.first.year - 1)...(cal.today.year + 1) {
            let fixed: [(String, LocalDay, Int?, Int?, String, String, String, String)] = [
                ("回国航班", LocalDay(year: year, month: 12, day: 22), 10 * 60 + 40, 19 * 60 + 20, "出行", "悉尼机场 T1", "must", "提前三小时到机场"),
                ("返回悉尼", LocalDay(year: year, month: 1, day: 14), 9 * 60 + 30, 21 * 60, "出行", "浦东机场 T1", "must", ""),
                ("生日", LocalDay(year: year, month: 8, day: 17), nil, nil, "生活", "", "could", ""),
            ]
            for item in fixed where item.1 >= cal.first && item.1 <= horizon {
                add(item.0, item.1, item.2, item.3, category: item.4, location: item.5, priority: item.6, notes: item.7)
            }
        }

        func place(_ template: EventTemplate, near day: LocalDay) -> LocalDay {
            switch template.weekend {
            case true?: return day.weekdayIndex >= 5 ? day : DemoCalendar.next(5, onOrAfter: day)
            case false?: return day.weekdayIndex >= 5 ? DemoCalendar.next(0, onOrAfter: day) : day
            case nil: return day
            }
        }

        func addSingle(_ template: EventTemplate, on day: LocalDay) {
            let end = template.start.map { $0 + template.minutes }
            add(rng.pick(template.titles), day, template.start, end, category: template.category, location: template.location,
                priority: template.priority, notes: rng.pick(template.notes))
        }

        // 散落在这几年里的单次日程（回国期间不排本地的事）
        var placed = 0
        var attempts = 0
        while placed < 22 * (cal.span / 365 + 1), attempts < 2000 {
            attempts += 1
            let template = rng.pick(eventTemplates)
            let day = place(template, near: cal.first.adding(days: rng.int(0...cal.span)))
            guard day <= cal.today, !cal.isAway(day) else { continue }
            addSingle(template, on: day)
            placed += 1
        }
        // 接下来四周的安排，今天也排两件
        for offset in [1, 3, 5, 8, 11, 15, 19, 24] {
            let template = rng.pick(eventTemplates)
            let day = place(template, near: cal.today.adding(days: offset))
            guard !cal.isAway(day) else { continue }
            addSingle(template, on: day)
        }
        add("图书馆写作", cal.today, 14 * 60, 17 * 60, category: "学业", location: "Fisher 图书馆五楼", priority: "should", notes: "第四章 4.2 节")
        add("和阿哲吃饭", cal.today, 18 * 60 + 30, 20 * 60, category: "社交", location: "Darling Square", priority: "could")
    }

    // MARK: - 习惯与打卡

    private enum HabitKind { case study, sleep, body, exercise, mind, home }

    private struct HabitDef {
        var title: String
        var category: String
        var symbol: String
        var frequency: HabitFrequency
        var perWeek = 1
        var weekdays: [Int] = []
        var target: Double? = nil
        var unit = ""
        var step = 1.0
        /// 改过数量目标：changeAt 之前的打卡按旧目标记（targetAtLog）
        var oldTarget: Double? = nil
        var changeAt = 0.5
        var startAt = 0.0
        var archiveAt: Double? = nil
        var kind: HabitKind
        var base: Double
        var stick = 0.12
        var trend = 0.0
        var weekend = 1.0
        var notes = ""
    }

    /// 生成好的一个习惯：修行录的周复盘、月复盘按它写“功课”那一行
    private struct HabitTrack {
        var def: HabitDef
        var start: LocalDay
        /// 最后一个可以打卡的日子（归档的前一天，或今天）
        var last: LocalDay
        var achieved: Set<Int>

        func scheduled(_ day: LocalDay) -> Bool {
            day >= start && day <= last && (def.frequency != .weekdays || def.weekdays.contains(day.weekdayIndex))
        }
    }

    private static let habitDefs: [HabitDef] = [
        HabitDef(title: "晨读二十分钟", category: "学习", symbol: "book", frequency: .daily, kind: .study, base: 0.78, stick: 0.1, trend: 0.06,
                 weekend: 0.8, notes: "起床后先读，不看手机"),
        HabitDef(title: "早睡（23:30 前）", category: "健康", symbol: "moon.zzz", frequency: .daily, kind: .sleep, base: 0.52, stick: 0.14, trend: 0.12,
                 weekend: 0.6),
        HabitDef(title: "喝水", category: "健康", symbol: "drop", frequency: .daily, target: 8, unit: "杯", startAt: 0.08, kind: .body, base: 0.8),
        HabitDef(title: "背单词", category: "学习", symbol: "globe.asia.australia", frequency: .daily, target: 50, unit: "个", oldTarget: 30,
                 kind: .study, base: 0.66, stick: 0.18, notes: "学术英语词表"),
        HabitDef(title: "运动", category: "健康", symbol: "figure.run", frequency: .weekly, perWeek: 3, kind: .exercise, base: 0.68,
                 notes: "跑步、游泳、力量都算"),
        HabitDef(title: "力量训练", category: "健康", symbol: "dumbbell", frequency: .weekdays, weekdays: [0, 2, 4], startAt: 0.3, kind: .exercise,
                 base: 0.62, trend: 0.1),
        HabitDef(title: "论文写作", category: "学业", symbol: "pencil.and.scribble", frequency: .weekdays, weekdays: [0, 1, 2, 3, 4], target: 90,
                 unit: "分钟", step: 15, kind: .study, base: 0.74, stick: 0.08, trend: 0.08, notes: "上午整块时间，只写不改"),
        HabitDef(title: "冥想", category: "修心", symbol: "brain.head.profile", frequency: .daily, target: 10, unit: "分钟", startAt: 0.35,
                 kind: .mind, base: 0.45, stick: 0.3),
        HabitDef(title: "练琴", category: "爱好", symbol: "music.note", frequency: .weekdays, weekdays: [1, 3, 5], startAt: 0.2, kind: .home,
                 base: 0.55, trend: -0.1),
        HabitDef(title: "自己做饭", category: "生活", symbol: "fork.knife", frequency: .weekly, perWeek: 4, kind: .home, base: 0.62),
        HabitDef(title: "整理房间", category: "生活", symbol: "leaf", frequency: .weekly, perWeek: 1, startAt: 0.05, kind: .home, base: 0.85),
        HabitDef(title: "步数", category: "健康", symbol: "sun.max", frequency: .daily, target: 8000, unit: "步", step: 10, startAt: 0.15,
                 kind: .body, base: 0.68, stick: 0.05),
        HabitDef(title: "读文献", category: "学业", symbol: "graduationcap", frequency: .weekly, perWeek: 3, kind: .study, base: 0.66,
                 notes: "每篇写一句话摘要"),
        HabitDef(title: "不喝奶茶", category: "生活", symbol: "cup.and.saucer", frequency: .daily, archiveAt: 0.45, kind: .body, base: 0.58,
                 stick: 0.2, notes: "后来改成每周最多一杯，归档了"),
        HabitDef(title: "晨跑", category: "健康", symbol: "heart", frequency: .weekdays, weekdays: [1, 3, 6], archiveAt: 0.3, kind: .exercise,
                 base: 0.5, trend: -0.3, notes: "并进“运动”了"),
    ]

    private static func seedHabits(_ context: ModelContext, _ cal: DemoCalendar, _ report: inout Report) -> [HabitTrack] {
        var rng = SplitMix64(stream: 5)
        var tracks: [HabitTrack] = []
        for (index, def) in habitDefs.enumerated() {
            let start = cal.day(at: def.startAt)
            let archiveDay = def.archiveAt.map { cal.day(at: $0) }
            let last = archiveDay.map { $0.adding(days: -1) } ?? cal.today
            let changeDay = def.oldTarget == nil ? nil : cal.day(at: def.changeAt)

            let habit = Habit(title: def.title)
            habit.category = def.category
            habit.symbol = def.symbol
            habit.frequencyKind = def.frequency
            habit.targetPerWeek = def.frequency == .weekly ? def.perWeek : 1
            habit.weekdays = def.frequency == .weekdays ? def.weekdays : []
            habit.targetValue = def.target
            habit.unit = def.target == nil ? "" : def.unit
            habit.startDate = start.key
            habit.notes = def.notes
            habit.sortOrder = index
            habit.createdAt = start.date(minutes: 9 * 60 + rng.int(0...600))
            habit.updatedAt = habit.createdAt
            if let archiveDay {
                habit.archived = true
                habit.archivedAt = archiveDay.key
                report.archivedHabits += 1
            }
            context.insert(habit)
            report.habits += 1

            // 状态低迷的几段：大约每 120 天有一半机会出现一段 5–18 天
            var slumps: [ClosedRange<Int>] = []
            var block = start.jdn
            while block < last.jdn {
                if rng.chance(0.55) {
                    let from = block + rng.int(0...100)
                    slumps.append(from...(from + rng.int(5...18)))
                }
                block += 120
            }

            func probability(_ day: LocalDay, previous: Bool?) -> Double {
                var p = def.base + def.trend * (cal.t(day) - 0.5)
                if let previous { p += previous ? def.stick : -def.stick }
                if day.weekdayIndex >= 5 { p *= def.weekend }
                if slumps.contains(where: { $0.contains(day.jdn) }) { p *= 0.25 }
                if cal.isAway(day) {
                    switch def.kind {
                    case .study: p *= 0.5
                    case .exercise: p *= 0.15
                    case .home: p *= 0.1
                    case .sleep, .mind: p *= 0.8
                    case .body: break
                    }
                }
                if cal.isCrunch(day) {
                    switch def.kind {
                    case .sleep: p *= 0.6
                    case .exercise: p *= 0.7
                    case .mind: p *= 0.8
                    default: break
                    }
                }
                if day == cal.today { p *= 0.5 }
                return min(0.97, max(0.02, p))
            }

            var achieved = Set<Int>()
            func log(_ day: LocalDay, partial: Bool) {
                var quantity: Double?
                let target: Double? = {
                    if let changeDay, day < changeDay { return def.oldTarget }
                    return def.target
                }()
                if let target {
                    let raw = partial ? target * rng.double(0.3, 0.9) : target * rng.double(1.0, 1.45)
                    var value = (raw / def.step).rounded(.down) * def.step
                    value = partial ? max(def.step, min(value, target - def.step)) : max(value, target)
                    quantity = value
                }
                let entry = HabitLog(dateKey: day.key, completed: true, quantity: quantity)
                if let changeDay, day < changeDay { entry.targetAtLog = def.oldTarget }
                entry.createdAt = day.date(minutes: 7 * 60 + rng.int(0...900))
                entry.updatedAt = entry.createdAt
                context.insert(entry)
                entry.habit = habit
                report.habitLogs += 1
                if !partial { achieved.insert(day.jdn) }
                habit.updatedAt = max(habit.updatedAt, entry.createdAt)
            }

            if def.frequency == .weekly {
                var monday = start.mondayOfWeek
                while monday <= last {
                    let days = (0..<7).map { monday.adding(days: $0) }.filter { $0 >= start && $0 <= last }
                    let p = probability(monday.adding(days: 3), previous: nil)
                    var count = rng.chance(p) ? def.perWeek + (rng.chance(0.25) ? 1 : 0) : max(0, def.perWeek - rng.int(1...def.perWeek))
                    if days.count < 7 { count = Int((Double(count) * Double(days.count) / 7).rounded()) }
                    for day in rng.sample(days, count) { log(day, partial: false) }
                    monday = monday.adding(days: 7)
                }
            } else {
                var previous: Bool?
                for day in LocalDay.range(start, last) {
                    guard def.frequency != .weekdays || def.weekdays.contains(day.weekdayIndex) else { continue }
                    let done = rng.chance(probability(day, previous: previous))
                    previous = done
                    if done {
                        log(day, partial: def.target != nil && rng.chance(0.12))
                    } else if def.target != nil && rng.chance(0.06) {
                        log(day, partial: true)
                    }
                }
            }
            tracks.append(HabitTrack(def: def, start: start, last: last, achieved: achieved))
        }
        return tracks
    }

    // MARK: - 修行录

    /// 日记的一个主题。sentences 里 {名字} 换成 slots 里的词；句首的 +/- 表示这句让心境比 mood 基调好 / 差一档。
    private struct Theme {
        var tags: [String]
        var mood: Int
        var titles: [String]
        var sentences: [String]
    }

    private enum ThemeID: Int, CaseIterable {
        case research, teaching, exercise, food, social, family, reading, calm, low, sleep, money, errands, outing, away
    }

    private static let slots: [String: [String]] = [
        "章节": ["第二章", "第三章", "第四章", "引言", "方法部分", "讨论部分", "文献综述"],
        "对象": ["论证结构", "图表", "数据处理流程", "段落顺序", "研究问题的表述"],
        "实验": ["遥感影像分类", "地表温度反演", "回归模型", "聚类分析", "空间自相关分析"],
        "主题": ["城市热岛", "绿地降温效应", "地表温度", "街道树冠覆盖", "城市通风廊道"],
        "问题": ["坐标系转换", "一个数据清洗的 bug", "模型过拟合", "影像云量太多", "内存不够"],
        "原因": ["投影参数写错了", "把行列弄反了", "时区没对齐", "缺失值被当成了零", "文件路径里多了个空格"],
        "话题": ["第三章的结构", "下一阶段的计划", "会议投稿", "数据的局限性", "研究区的选择"],
        "建议": ["先把核心结论写出来", "缩小研究区", "多做一组对照", "把方法写得更具体一点", "先投一个小会议练练手"],
        "字数": ["600", "800", "1200", "1500", "2000", "2600", "3000"],
        "份数": ["十几", "二十", "三十多", "四十"],
        "数学": ["函数图像", "导数", "数列求和", "概率分布", "三角恒等变换", "平面向量"],
        "公里": ["3", "4", "5", "6", "8", "10"],
        "菜": ["番茄炒蛋", "红烧肉", "咖喱鸡", "酸菜鱼", "可乐鸡翅", "土豆炖牛腩", "葱油拌面", "麻婆豆腐"],
        "餐厅": ["火锅", "川菜", "拉面", "越南粉", "泰餐", "韩式烤肉", "麻辣烫"],
        "朋友": ["阿哲", "小雨", "Mia", "室友", "师兄", "老周"],
        "地方": ["Manly", "Bondi", "皇家植物园", "Barangaroo", "蓝山", "Watsons Bay", "Cockatoo Island", "Parramatta 河边", "Coogee", "Balmoral 海滩"],
        "书": ["置身事内", "被讨厌的勇气", "原则", "人类简史", "小王子", "活着", "刻意练习", "深度工作", "百年孤独", "平凡的世界", "乡土中国", "思考，快与慢"],
        "几章": ["两章", "一章", "前半部分", "最后几章"],
        "感想": ["有几段很想抄下来。", "作者把复杂的事讲得很清楚。", "读得很慢，但很享受。", "有些观点不太同意，但很有启发。", "心里安静了很多。"],
        "家乡菜": ["热干面", "火锅", "肠粉", "烤鸭", "酸辣粉", "小笼包"],
        "天数": ["三", "四", "五", "七", "十"],
        "次数": ["两", "三", "四", "五"],
        "星期": ["二", "三", "四"],
        "琐事": ["银行卡挂失", "续签手机套餐", "报销", "体检预约", "退税申报"],
        "事": ["读两篇文献", "整理实验记录", "回复积压的邮件", "备课"],
    ]

    private static let themes: [Theme] = [
        Theme(tags: ["论文", "研究"], mood: 3, titles: ["第三章收尾", "组会之后", "改稿", "卡住了", "数据跑通了", "文献日", "导师的红字", "图书馆的一天", "小进展", "初稿发出"],
              sentences: [
                  "上午把{章节}的{对象}重新梳理了一遍，逻辑顺了很多。",
                  "跑了一整天的{实验}，结果还是不太稳定，明天换个参数再试。",
                  "读了三篇关于{主题}的文献，做了笔记，有一篇的方法可以直接借鉴。",
                  "-下午卡在{问题}上两个多小时，最后发现是{原因}，有点哭笑不得。",
                  "今天写了{字数}字，不算多，但每一句都比较扎实。",
                  "和导师讨论了{话题}，她建议我{建议}。",
                  "把{章节}的图重新画了一遍，配色终于顺眼了。",
                  "整理了这周的实验记录，发现之前漏掉了一组对照。",
                  "+在图书馆待了一整天，效率出奇地高。",
                  "+{章节}的初稿发给了导师，心里一块石头落了地。",
                  "-导师的批注回来了，满屏的红字，深呼吸，一条条改。",
                  "+重新跑了一遍数据处理流程，这次从头到尾没有报错。",
                  "组会上讲了{话题}，被问住了两个问题，回去要补。",
                  "看到一篇和我思路很像的新论文，先慌了一下，仔细读完发现角度不同。",
                  "把参考文献都整理进了 Zotero，强迫症得到了满足。",
                  "上午效率很低，下午换到图书馆五楼，终于进入状态。",
              ]),
        Theme(tags: ["教学", "补习"], mood: 4, titles: ["教学相长", "补习日", "改作业", "讲课的感觉"],
              sentences: [
                  "补习的学生终于把{数学}弄明白了，讲第三遍的时候换了个比喻，他眼睛一下子亮了。",
                  "备课到很晚，把{数学}换了一种讲法，希望明天效果好一点。",
                  "带的学生这次小测进步很大，比我自己考好还开心。",
                  "学生家长发消息说孩子最近对数学有兴趣了，被这句话暖到。",
                  "讲课的时候发现自己对{数学}的理解也更深了一层。",
              ]),
        Theme(tags: ["运动", "健康"], mood: 4, titles: ["跑步", "练腿日", "海边", "流汗"],
              sentences: [
                  "傍晚去跑了{公里}公里，配速比上周快了一点。",
                  "健身房人很多，练完腿走路都在抖。",
                  "沿着海边走了一圈，风很大，心里却很静。",
                  "-今天没去运动，有点愧疚，明天补上。",
                  "早上去游了泳，一整天都很清醒。",
                  "跟着视频做了二十分钟拉伸，肩膀松了不少。",
                  "跑步的时候想通了论文里的一个结构问题，运动果然有用。",
                  "下雨没法跑步，在房间里做了一组徒手训练。",
              ]),
        Theme(tags: ["做饭", "生活"], mood: 4, titles: ["今天的饭", "下厨", "外卖又多了"],
              sentences: [
                  "晚上自己做了{菜}，味道还行。",
                  "和{朋友}去吃了{餐厅}，聊到很晚。",
                  "-又点了外卖，这周已经第三次了，下次要忍住。",
                  "做了一大锅{菜}，分装好够吃三天。",
                  "第一次尝试做{菜}，卖相一般，味道意外地不错。",
                  "中午在学校随便吃了点，太忙了。",
              ]),
        Theme(tags: ["朋友"], mood: 4, titles: ["朋友", "热闹", "聚会"],
              sentences: [
                  "{朋友}约我周末去{地方}，答应了。",
                  "和室友一起看了部电影，难得的放松。",
                  "跟{朋友}聊了很久以后找工作的事，大家都有点迷茫。",
                  "{朋友}过生日，一群人在家里煮火锅，很热闹。",
                  "好久没联系的老同学突然发来消息，聊起本科时候的事，恍如隔世。",
                  "参加了系里的聚会，认识了几个新同学。",
              ]),
        Theme(tags: ["家人"], mood: 4, titles: ["家书", "视频"],
              sentences: [
                  "和家里视频，妈妈又问我什么时候回国。",
                  "爸爸发来家里阳台的花，开得很好。",
                  "外婆身体不太好，打了个电话，听到她的声音放心了一些。",
                  "给爸妈寄的礼物到了，他们很开心。",
                  "和妈妈聊了很久，她说不用太拼，身体要紧。",
              ]),
        Theme(tags: ["读书"], mood: 4, titles: ["读书", "睡前读"],
              sentences: [
                  "睡前读了《{书}》的{几章}，{感想}",
                  "在通勤路上读完了《{书}》，{感想}",
                  "重读《{书}》，和几年前读的感受完全不同。",
              ]),
        Theme(tags: ["心情"], mood: 4, titles: ["晚霞", "平静的一天", "小确幸"],
              sentences: [
                  "阳光很好，在图书馆窗边坐了一下午。",
                  "今天整个人很平静，事情一件件做完的感觉很好。",
                  "傍晚的晚霞特别好看，停下来看了很久。",
                  "买到了一直想要的那支钢笔，写字都变得开心。",
              ]),
        Theme(tags: ["心情"], mood: 2, titles: ["雨天", "有点低落", "焦虑"],
              sentences: [
                  "下了一整天的雨，闷在屋里，什么都不想做。",
                  "有点焦虑，觉得进度落后了，写下来好受一些。",
                  "莫名有点低落，可能是太久没好好休息了。",
                  "看到同届的人都发了论文，忍不住比较，又陷进去了。",
                  "效率很低的一天，刷手机的时间比写论文还多。",
              ]),
        Theme(tags: ["睡眠", "健康"], mood: 3, titles: ["又熬夜了", "早睡", "感冒了"],
              sentences: [
                  "-昨晚又熬到一点多，今天一整天没精神。",
                  "+早睡早起的第{天数}天，状态明显好了。",
                  "-有点感冒，喝了很多热水，早早睡了。",
                  "-午睡睡过头了，晚上肯定又睡不着。",
                  "+最近睡眠不错，早上不用闹钟也能自然醒。",
              ]),
        Theme(tags: ["理财"], mood: 3, titles: ["看账", "理财"],
              sentences: [
                  "看了一眼账，这个月外卖花得有点多。",
                  "退掉了一个用不上的订阅，每个月省一点是一点。",
                  "这个月的餐饮预算超了，下个月多自己做饭。",
                  "研究了一下指数基金定投，先小额试试。",
              ]),
        Theme(tags: ["生活"], mood: 3, titles: ["琐事", "收拾房间"],
              sentences: [
                  "去超市采购了一周的菜，拎回来手都勒红了。",
                  "洗衣服、收拾房间，半天就这么过去了。",
                  "去银行办了点事，排了好久的队。",
                  "房东来修了热水器，终于不用洗冷水澡了。",
                  "整理了书桌，把用不上的东西清掉了一半。",
                  "终于把拖了很久的{琐事}办完了。",
              ]),
        Theme(tags: ["出游", "摄影"], mood: 5, titles: ["周末的海", "出走半日", "渡轮", "晚霞"],
              sentences: [
                  "带相机去了{地方}，拍到了很好看的晚霞。",
                  "坐渡轮去了{地方}，海风很舒服。",
                  "和{朋友}去{地方}走了一整天，脚很累，心很满。",
                  "在{地方}的草地上躺了一下午，什么都没想。",
              ]),
        Theme(tags: ["回国", "家人"], mood: 4, titles: ["回家", "团圆", "家乡的冬天"],
              sentences: [
                  "和高中同学聚了聚，大家都变了，又好像都没变。",
                  "陪外婆去公园散步，她走得比去年慢了。",
                  "家里的冬天好冷，悉尼这时候却是夏天，像是活在两个季节里。",
                  "吃到了想了很久的{家乡菜}，满足。",
                  "在家什么都不用操心，但也有点担心论文进度。",
              ]),
    ]

    /// 回国头几天、最后几天才有的句子
    private static let homecomingSentences = ["回到家的第一顿饭，妈妈做了一桌子菜。", "倒时差，下午困得睁不开眼。"]
    private static let farewellSentences = ["要走了，妈妈一直在叮嘱，舍不得。", "收拾行李，箱子里塞满了家里的零食。"]
    /// 只在学期中出现的助教句子
    private static let tutorialSentences = [
        "今天的 tutorial 有个学生问了一个很好的问题，我当场没答好，回去查了资料。",
        "改了{份数}份作业，眼睛有点花。",
        "tutorial 上大家都很沉默，下次得准备几个更好的开场问题。",
    ]
    /// 悉尼的季节（回国期间不用）
    private static let summerSentences = ["天气热得不想出门，开着风扇写东西。", "晚上去海边吹了吹风，暑气散了一些。"]
    private static let springSentences = ["楼下的蓝花楹开了，路过的时候忍不住拍了好几张。"]
    private static let winterSentences = ["风很大，降温了，翻出了厚外套。", "冬天的悉尼天黑得好早，五点多就要开灯了。"]
    private static let closers = ["有点累，但心里踏实。", "明天继续。", "慢慢来，比较快。", "记一笔，提醒自己。", "总的来说是不错的一天。"]
    /// 只用在晚上写的日记末尾
    private static let nightClosers = ["希望明天能早点睡。", "就这样吧，睡觉。", "关灯，晚安。"]

    /// 灵感：（正文, 标签）。前一半也用作复盘里的【所悟】
    private static let insights: [(String, String)] = [
        ("写作卡住的时候，先写最确定的那一段，其他的会慢慢跟上。", "写作"),
        ("与其等状态来了再开始，不如先开始，状态会在第十分钟出现。", "效率"),
        ("每天结束前写下明天第一件要做的事，第二天早上就不会在原地打转。", "效率"),
        ("开会前先写下自己想要的结论，开完对照一下。", "效率"),
        ("把大任务拆到半小时能完成的粒度，拖延就少了一半。", "效率"),
        ("情绪低落时不做重大决定，先睡一觉。", "生活"),
        ("读文献先看图和结论，再决定要不要细读。", "研究"),
        ("图表的第一读者是三个月后的自己。", "研究"),
        ("讲给别人听，是检验自己懂没懂的最好方法。", "教学"),
        ("休息不是奖励，是工作的一部分。", "生活"),
        ("能用一句话说清楚的研究问题，才是好问题。", "研究"),
        ("做计划时留两成空白，给意外。", "效率"),
        ("不要和别人的进度比，和上个月的自己比。", "生活"),
        ("每周留一个下午不安排任何事，用来想事情。", "效率"),
        ("写邮件先写结论和请求，背景放后面。", "写作"),
        ("代码和论文一样，命名清楚就省掉一半注释。", "研究"),
        ("焦虑时把担心的事一条条写下来，大多数其实不需要现在处理。", "生活"),
        ("早上第一个小时最宝贵，不要拿来刷手机。", "效率"),
        ("做饭是很好的休息：手在忙，脑子在放空。", "生活"),
        ("一个习惯断了一天不可怕，断了两天就要警惕。", "生活"),
        ("好的提问比好的回答更难。", "研究"),
        ("记账的意义不是省钱，是知道钱去了哪里。", "理财"),
        ("复杂的问题先画图，画不出来说明还没想清楚。", "研究"),
        ("反馈来得越早越便宜。", "写作"),
        ("累的时候先做最机械的事，比如整理参考文献。", "效率"),
        ("每次被导师问住的问题，都值得单独记下来。", "研究"),
        ("运动后的半小时是一天里思路最清楚的时候。", "生活"),
        ("不是没有时间，是没有把时间留给重要的事。", "效率"),
        ("说不出口的拒绝，最后都会变成加班。", "生活"),
        ("实验失败也是结果，记录下来就不算白做。", "研究"),
        ("周日晚上花十分钟看下周日程，周一就不慌。", "效率"),
        ("长时间专注之后去散步，很多想不通的事会自己解开。", "生活"),
        ("答应别人之前，先看一眼日程。", "效率"),
        ("完成比完美重要，但发出去之前要再读一遍。", "写作"),
    ]
    private static let ideas: [(String, String)] = [
        ("想到一个点子：把每周复盘的【下一步】直接排进下周的日程。", "效率"),
        ("可以试试把每一节的核心论点写在便利贴上，贴在墙上排顺序。", "写作"),
        ("给补习的学生做一张错题地图，按知识点归类。", "教学"),
        ("周末可以去{地方}拍日落，出门前查一下潮汐时间。", "生活"),
        ("做一个常用的 Python 绘图模板，每次画图不用从头调样式。", "研究"),
        ("论文致谢里要记得写上帮我借仪器的那位技术员。", "写作"),
        ("下次组会先放结论页，再讲过程。", "研究"),
        ("通勤时间可以用来听领域里的播客。", "效率"),
        ("番茄钟试试改成 50 分钟专注加 10 分钟走动。", "效率"),
        ("给读过的文献做一张一句话摘要表，写综述时会很省事。", "研究"),
        ("生日那天可以给自己写一封一年后打开的信。", "生活"),
        ("把冰箱里的菜列个清单贴在门上，少浪费一点。", "生活"),
        ("研究区地图可以加一个街道树冠覆盖的图层试试。", "研究"),
        ("可以给 tutorial 设计一个五分钟的小游戏热场。", "教学"),
        ("每月第一天把订阅过一遍，用不上的立刻退。", "理财"),
        ("导师说：好的论文不是写出来的，是改出来的。", "写作"),
        ("师兄说：读研是一场长跑，不要用冲刺的速度跑。", "生活"),
        ("补习的学生问我：数学学到最后有什么用？想了很久，下次好好回答他。", "教学"),
        ("《{书}》里有个观点值得再想想：把注意力当成最稀缺的资源来管理。", "读书"),
    ]
    private static let noteTails = ["记下来，以后用得上。", "值得试一周。", "先记着，周末细想。", "和上周的想法可以连起来看。", "今天突然想到的。"]
    private static let noteTitles = ["小技巧", "一个想法", "备忘", "随想", "写作", "研究方法", "效率"]

    private static let reviewGains = ["论文写了{字数}字。", "{章节}有了完整的初稿。", "补习课一节没落下。", "读完了《{书}》。", "和导师的会面很顺利。",
                                      "把拖了很久的{琐事}办完了。", "做了{次数}次饭，外卖少了。", "组会上的报告讲得比上次从容。"]
    private static let reviewLosses = ["周{星期}熬夜，第二天状态很差。", "外卖点多了。", "计划里的{事}没做完。", "刷手机的时间太长。",
                                       "运动只去了{次数}次。", "上午被邮件打断了好几次。"]
    private static let reviewNext = ["23:30 前收工。", "每天上午先写 90 分钟。", "把{章节}的图定稿。", "周三之前回复导师的邮件。", "至少运动三次。",
                                     "周末备餐，少点外卖。", "早上第一个小时不碰手机。", "把{事}补上。"]

    /// 把模板里的 {名字} 换成对应词表里随机一项
    private static func fill(_ template: String, _ rng: inout SplitMix64) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let name = String(rest[rest.index(after: open)..<close])
            out += slots[name].map { rng.pick($0) } ?? name
            rest = rest[rest.index(after: close)...]
        }
        return spaced(out + rest)
    }

    private static let hanThenLatin = try! NSRegularExpression(pattern: #"(\p{Han})([A-Za-z0-9])"#)
    private static let latinThenHan = try! NSRegularExpression(pattern: #"([A-Za-z0-9])(\p{Han})"#)

    /// 汉字与英文、数字之间留一个空格（“和 Mia 去吃了”“写了 2000 字”），与应用里其他文案的写法一致
    private static func spaced(_ text: String) -> String {
        var result = text
        for regex in [hanThenLatin, latinThenHan] {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1 $2")
        }
        return result
    }

    private static func themeWeights(_ day: LocalDay, _ cal: DemoCalendar) -> [Double] {
        //            研究 教学 运动 饮食 朋友 家人 读书 平静 低落 睡眠 理财 琐事 出游 回国
        if cal.isAway(day) { return [1, 0, 1, 0, 0, 10, 5, 4, 1, 2, 0, 0, 0, 50] }
        if day.weekdayIndex >= 5 { return [7, day.weekdayIndex == 5 ? 5 : 1, 10, 12, 12, 9, 9, 8, 4, 4, 3, 10, 14, 0] }
        return cal.isSemester(day) ? [30, 12, 8, 8, 4, 3, 6, 6, 5, 5, 2, 4, 1, 0] : [34, 6, 9, 9, 5, 4, 7, 7, 5, 5, 2, 4, 2, 0]
    }

    /// 每个主题在一篇里最多几句（运动、读书这类一篇只说一件，免得“跑了十公里”又“下雨没法跑步”）
    private static let themeLimits = [3, 2, 1, 1, 1, 2, 1, 2, 1, 1, 1, 1, 1, 3]

    private static func sentences(_ theme: Int, _ day: LocalDay, _ cal: DemoCalendar) -> [String] {
        var pool = themes[theme].sentences
        if theme == ThemeID.teaching.rawValue, cal.isSemester(day) { pool += tutorialSentences }
        if theme == ThemeID.away.rawValue {
            if day.month == 12, day.day <= 25 { pool += homecomingSentences }
            if day.month == 1, day.day >= 11 { pool += farewellSentences }
        }
        if theme == ThemeID.calm.rawValue || theme == ThemeID.low.rawValue, !cal.isAway(day) {
            if cal.isSummer(day) { pool += summerSentences }
            if cal.isWinter(day) { pool += winterSentences }
            if theme == ThemeID.calm.rawValue, [10, 11].contains(day.month) { pool += springSentences }
        }
        return pool
    }

    /// 一篇日记：主题按日子挑（工作日多写研究，周末多写生活，回国期间写家里），长短不一。
    /// 同一篇里每个句式最多用一次，每个主题最多 themeLimits 句，免得一篇里反复说同一件事。
    private static func diary(_ rng: inout SplitMix64, _ day: LocalDay, _ cal: DemoCalendar, night: Bool)
        -> (title: String, body: String, mood: Int, tags: [String], long: Bool) {
        let weights = themeWeights(day, cal)
        let primary = rng.weighted(weights)
        let roll = rng.unit()
        let long = roll > 0.93
        let count: Int
        if long {
            count = rng.int(5...8)
        } else if roll > 0.8 {
            count = rng.int(4...5)
        } else {
            count = roll > 0.55 ? 3 : roll > 0.22 ? 2 : 1
        }
        var used = Set<String>()
        var parts: [String] = []
        var themesUsed = [primary]
        var perTheme = [Int](repeating: 0, count: themes.count)
        var moodShift = 0
        for index in 0..<count {
            var theme = primary
            if index > 0, rng.chance(long ? 0.55 : 0.4) || perTheme[primary] >= themeLimits[primary] {
                theme = rng.weighted(weights)
                if perTheme[theme] >= themeLimits[theme] { continue }
                if !themesUsed.contains(theme) { themesUsed.append(theme) }
            }
            let fresh = sentences(theme, day, cal).filter { !used.contains($0) }
            guard !fresh.isEmpty else { continue }
            var template = rng.pick(fresh)
            used.insert(template)
            // 句首的 +/- 标记：这句让心境比主题的基调好一点 / 差一点（只看第一句）
            if let mark = template.first, mark == "+" || mark == "-" {
                if index == 0 { moodShift = mark == "+" ? 1 : -1 }
                template.removeFirst()
            }
            perTheme[theme] += 1
            parts.append(fill(template, &rng))
        }
        if rng.chance(0.35) { parts.append(rng.pick(night && rng.chance(0.4) ? nightClosers : closers)) }
        let body: String
        if long, parts.count >= 4 {
            let cut = parts.count / 2
            body = parts[..<cut].joined() + "\n\n" + parts[cut...].joined()
        } else {
            body = parts.joined()
        }
        let noise = rng.unit()
        let mood = max(1, min(5, themes[primary].mood + moodShift + (noise < 0.2 ? -1 : noise < 0.75 ? 0 : 1)))
        let title = rng.chance(long ? 0.7 : 0.28) ? rng.pick(themes[primary].titles) : ""
        var tags: [String] = []
        if rng.chance(0.85) {
            tags.append(themes[primary].tags[0])
            if themes[primary].tags.count > 1, rng.chance(0.3) { tags.append(themes[primary].tags[1]) }
            if themesUsed.count > 1, rng.chance(0.5), !tags.contains(themes[themesUsed[1]].tags[0]) { tags.append(themes[themesUsed[1]].tags[0]) }
        }
        return (title, body, mood, tags, long)
    }

    private static func habitLine(_ track: HabitTrack, from first: LocalDay, to last: LocalDay) -> (title: String, text: String, missed: Int) {
        let days = LocalDay.range(first, last).filter(track.scheduled)
        let done = days.filter { track.achieved.contains($0.jdn) }.count
        if track.def.frequency == .weekly {
            return (track.def.title, "\(track.def.title) \(done) 次", 0)
        }
        return (track.def.title, "\(track.def.title) \(done)/\(days.count) 天", days.count - done)
    }

    private static func seedJournal(_ context: ModelContext, _ cal: DemoCalendar, _ tracks: [HabitTrack], _ report: inout Report) {
        var rng = SplitMix64(stream: 6)
        // 偶尔几段空白（出门、生病、忙到忘记）：大约每 150 天一段 2–5 天
        var gaps: [ClosedRange<Int>] = []
        var block = cal.first.jdn
        while block < cal.today.jdn - 7 {
            if rng.chance(0.7) {
                let from = block + rng.int(0...140)
                gaps.append(from...(from + rng.int(1...4)))
            }
            block += 150
        }
        var monthDiaries = 0, monthNotes = 0, monthMood = 0

        func insert(_ kind: JournalKind, _ day: LocalDay, minute: Int?, title: String, body: String, mood: Int? = nil,
                    period: String = "", tags: [String], pinned: Bool) {
            let entry = JournalEntry(kind: kind, title: title, body: body, dateKey: day.key)
            entry.uid = rng.uuid()
            entry.minute = minute
            entry.mood = mood
            entry.period = period
            entry.tags = tags
            entry.pinned = pinned
            entry.createdAt = day.date(minutes: minute ?? 22 * 60)
            entry.updatedAt = entry.createdAt
            context.insert(entry)
            if pinned { report.pinned += 1 }
        }

        func review(_ gains: [String], _ losses: [String], _ insight: String, _ next: [String]) -> String {
            "【所得】\n" + gains.joined() + "\n\n【所失】\n" + losses.joined() + "\n\n【所悟】\n" + insight + "\n\n【下一步】\n" + next.joined()
        }

        for day in LocalDay.range(cal.first, cal.today) {
            let sunday = day.weekdayIndex == 6
            let monthEnd = day.adding(days: 1).day == 1
            let blank = !sunday && !monthEnd && (gaps.contains { $0.contains(day.jdn) } || rng.chance(0.03))

            if !blank {
                let roll = rng.unit()
                let count = roll < 0.55 ? 1 : roll < 0.87 ? 2 : 3
                var drafts: [(kind: JournalKind, minute: Int?, title: String, body: String, mood: Int?, tags: [String], pinned: Bool)] = []
                for index in 0..<count {
                    let isDiary = index == 0 ? rng.chance(0.78) : rng.chance(0.25)
                    if isDiary {
                        // 日记多在晚上写；今天的、补记的不记时刻
                        let r = rng.unit()
                        var minute: Int?
                        if day != cal.today, r < 0.75 {
                            minute = rng.int((20 * 60 + 30)...(23 * 60 + 50))
                        } else if day != cal.today, r < 0.9 {
                            minute = rng.int((12 * 60)...(20 * 60))
                        }
                        let d = diary(&rng, day, cal, night: minute.map { $0 >= 20 * 60 } ?? false)
                        drafts.append((.diary, minute, d.title, d.body, d.mood, d.tags, rng.chance(d.long ? 0.15 : 0.025)))
                        report.diaries += 1
                        monthDiaries += 1
                        monthMood += d.mood
                    } else {
                        let (text, tag) = rng.chance(0.6) ? rng.pick(insights) : rng.pick(ideas)
                        var body = fill(text, &rng)
                        if rng.chance(0.3) { body += rng.pick(noteTails) }
                        let minute: Int? = day == cal.today || rng.chance(0.3) ? nil : rng.int((7 * 60 + 30)...(23 * 60))
                        drafts.append((.note, minute, rng.chance(0.2) ? rng.pick(noteTitles) : "", body, nil, rng.chance(0.85) ? [tag] : [],
                                       rng.chance(0.03)))
                        report.notes += 1
                        monthNotes += 1
                    }
                }
                // 同一天按时刻先后落笔（没记时刻的排在最后）
                for item in drafts.sorted(by: { ($0.minute ?? 2000) < ($1.minute ?? 2000) }) {
                    insert(item.kind, day, minute: item.minute, title: item.title, body: item.body, mood: item.mood, tags: item.tags, pinned: item.pinned)
                }
            }

            if sunday {
                let monday = day.mondayOfWeek
                let active = tracks.filter { $0.start <= day && $0.last >= monday }
                let lines = rng.sample(active, 3).map { habitLine($0, from: monday, to: day) }
                var gains = ["功课：" + lines.map(\.text).joined(separator: "，") + "。"]
                gains.append(fill(rng.pick(reviewGains), &rng))
                var losses: [String] = []
                if let worst = lines.max(by: { $0.missed < $1.missed }), worst.missed >= 3 {
                    losses.append("\(worst.title)漏了 \(worst.missed) 天。")
                }
                losses.append(fill(rng.pick(reviewLosses), &rng))
                let next = rng.sample(reviewNext, 2).map { fill($0, &rng) }
                insert(.review, day, minute: rng.int(21 * 60...22 * 60 + 30), title: "第 \(DemoCalendar.isoWeek(day)) 周复盘",
                       body: review(gains, losses, rng.pick(insights).0, next), period: ReviewPeriod.week.rawValue, tags: ["复盘"],
                       pinned: rng.chance(0.04))
                report.weeklyReviews += 1
            }

            if monthEnd {
                let first = max(day.firstOfMonth, cal.first)
                let active = tracks.filter { $0.start <= day && $0.last >= first }
                let lines = rng.sample(active, 3).map { habitLine($0, from: first, to: day) }
                let average = monthDiaries > 0 ? Int((Double(monthMood) / Double(monthDiaries)).rounded()) : 3
                let gains = ["本月落笔 \(monthDiaries + monthNotes) 篇（日记 \(monthDiaries)、灵感 \(monthNotes)），心境多为「\(Mood.label(average))」。",
                             "功课：" + lines.map(\.text).joined(separator: "，") + "。", fill(rng.pick(reviewGains), &rng)]
                let losses = rng.sample(reviewLosses, 2).map { fill($0, &rng) }
                let next = rng.sample(reviewNext, 3).map { fill($0, &rng) }
                insert(.review, day, minute: 22 * 60 + rng.int(0...40), title: MonthKey.label(year: day.year, month: day.month) + "复盘",
                       body: review(gains, losses, rng.pick(insights).0, next), period: ReviewPeriod.month.rawValue, tags: ["复盘", "月度"],
                       pinned: rng.chance(0.15))
                report.monthlyReviews += 1
                monthDiaries = 0
                monthNotes = 0
                monthMood = 0
            }
        }
    }

    // MARK: - 灵石账簿

    private struct BankRow {
        var day: LocalDay
        var cents: Int
        var description: String
        var balance: Int
    }

    private struct Merchant {
        var description: String
        /// 用户心里的类别：银行规则认不出的商户，第一次出现时按它确认并记住
        var category: String
        var low: Int
        var high: Int
        var weight: Double = 1
    }

    private static let account = "CommBank 0456"

    private static let groceries = [
        Merchant(description: "COLES 0123 BROADWAY NS AUS", category: "超市与食品", low: 650, high: 6800, weight: 3),
        Merchant(description: "WOOLWORTHS 1253 TOWN HALL NS AUS", category: "超市与食品", low: 650, high: 6800, weight: 3),
        Merchant(description: "ALDI STORES - BROADWAY NS AUS", category: "超市与食品", low: 900, high: 5200, weight: 2),
        Merchant(description: "HMART EASTWOOD NS AUS", category: "超市与食品", low: 1200, high: 7500),
        Merchant(description: "WW METRO CENTRAL NS AUS", category: "超市与食品", low: 350, high: 2200, weight: 2),
        Merchant(description: "IGA HAYMARKET NS AUS", category: "超市与食品", low: 800, high: 4500),
    ]
    private static let dining = [
        Merchant(description: "UBER *EATS HELP.UBER.COM SYDNEY AU", category: "餐饮与外卖", low: 1800, high: 4600, weight: 4),
        Merchant(description: "HUNGRYPANDA SYDNEY NS AUS", category: "餐饮与外卖", low: 2000, high: 4200, weight: 2),
        Merchant(description: "MCDONALDS BROADWAY NS AUS", category: "餐饮与外卖", low: 750, high: 1650, weight: 2),
        Merchant(description: "KFC CHATSWOOD NS AUS", category: "餐饮与外卖", low: 1000, high: 1900),
        Merchant(description: "GUZMAN Y GOMEZ GEORGE ST NS AUS", category: "餐饮与外卖", low: 1500, high: 3200),
        Merchant(description: "STARBUCKS BROADWAY NS AUS", category: "餐饮与外卖", low: 800, high: 1500),
        Merchant(description: "SUSHI HUB BROADWAY NS AUS", category: "餐饮与外卖", low: 900, high: 1800, weight: 2),
        Merchant(description: "NANDOS HAYMARKET NS AUS", category: "餐饮与外卖", low: 1800, high: 4200),
        Merchant(description: "SUBWAY HAYMARKET NS AUS", category: "餐饮与外卖", low: 600, high: 1600),
        Merchant(description: "DOMINOS CHATSWOOD NS AUS", category: "餐饮与外卖", low: 450, high: 1200, weight: 2),
        // 银行规则认不出：第一次出现时手动归类并记住
        Merchant(description: "SQ *GONG CHA BROADWAY NS AUS", category: "餐饮与外卖", low: 650, high: 980, weight: 2),
        Merchant(description: "SP *MALATANG HOUSE HAYMARKET NS AUS", category: "餐饮与外卖", low: 1400, high: 2600),
        Merchant(description: "CHAT THAI HAYMARKET NS AUS", category: "餐饮与外卖", low: 1800, high: 3800),
        Merchant(description: "DOPA DONBURI DARLING SQUARE NS AUS", category: "餐饮与外卖", low: 1500, high: 2200),
        Merchant(description: "CAMPOS COFFEE NEWTOWN NS AUS", category: "餐饮与外卖", low: 450, high: 620, weight: 3),
    ]
    private static let shopping = [
        Merchant(description: "AMAZON AU SYDNEY SOUTH NS AUS", category: "购物", low: 1500, high: 12900, weight: 5),
        Merchant(description: "TAOBAO.COM HANGZHOU CHN", category: "购物", low: 1800, high: 8800, weight: 1.5),
        Merchant(description: "KMART TOWN HALL NS AUS", category: "购物", low: 400, high: 4500, weight: 3),
        Merchant(description: "UNIQLO PITT ST NS AUS", category: "购物", low: 2990, high: 7990),
        Merchant(description: "JB HI FI BROADWAY NS AUS", category: "购物", low: 3900, high: 34900, weight: 0.5),
        Merchant(description: "IKEA TEMPE NS AUS", category: "购物", low: 2500, high: 22000, weight: 0.3),
        Merchant(description: "DYMOCKS SYDNEY NS AUS", category: "教育与学费", low: 1999, high: 4999, weight: 0.7),
    ]
    private static let leisure = [
        Merchant(description: "EVENT CINEMAS GEORGE ST NS AUS", category: "娱乐", low: 1850, high: 2700, weight: 3),
        Merchant(description: "STEAMGAMES.COM 4259522985 WA USA", category: "娱乐", low: 995, high: 6995),
        Merchant(description: "TATTS ONLINE PTY LTD BRISBANE QL AUS", category: "彩票", low: 500, high: 2200),
        Merchant(description: "CHEMIST WAREHOUSE TOWN HALL NS AUS", category: "健康与健身", low: 699, high: 4250, weight: 5),
        Merchant(description: "UNIVERSITY PRINTING CAMPERDOWN NS AUS", category: "教育与学费", low: 200, high: 1500, weight: 2),
    ]
    /// 只在最近一个月第一次出现的商户：这个月还没导入后确认，留在“待确认”里
    private static let newcomers = [
        Merchant(description: "SP *LANZHOU BEEF NOODLE ULTIMO NS AUS", category: "餐饮与外卖", low: 1690, high: 2290),
        Merchant(description: "SQ *KOI DESSERT BAR CHIPPENDALE NS AUS", category: "餐饮与外卖", low: 1200, high: 2400),
    ]
    private static let manualItems: [(String, String, Int, Int)] = [
        ("早餐 煎饼", "餐饮与外卖", 600, 900), ("菜市场 水果蔬菜", "超市与食品", 500, 1800), ("朋友代付 奶茶", "餐饮与外卖", 650, 950),
        ("打印讲义", "教育与学费", 200, 800), ("咖啡", "餐饮与外卖", 450, 600), ("停车费", "交通出行", 400, 1500),
        ("电影票（朋友代买）", "娱乐", 1800, 2500), ("药店 感冒药", "健康与健身", 800, 2200), ("唐人街 烧腊饭", "餐饮与外卖", 1300, 1800),
    ]
    private static let reflections = ["外卖还是偏多，下个月试试每周自己做饭四次。", "这个月买了不少书，算是值得的投资。", "订阅过了一遍，用不上的已经退掉。",
                                      "回国前后开销大，属于计划内。", "整体平稳，继续保持。", "打车次数多了，多半是熬夜后不想坐公交。",
                                      "超市开销比上月高，囤了些日用品。", "娱乐支出超了预算，下个月收一收。"]

    private static func seedLedger(_ context: ModelContext, _ cal: DemoCalendar, _ report: inout Report) {
        var rng = SplitMix64(stream: 7)
        var intended: [String: String] = [:]
        for merchant in groceries + dining + shopping + leisure + newcomers { intended[merchant.description] = merchant.category }
        intended["SPOTIFY P2B7C1D3E4 SYDNEY AUS"] = "软件与会员"
        intended["CHINA EASTERN AIRLINES SYDNEY NS AUS"] = "交通出行"
        let notes = ["CHINA EASTERN AIRLINES SYDNEY NS AUS": "回国机票", "JB HI FI BROADWAY NS AUS": "降噪耳机", "IKEA TEMPE NS AUS": "书架和台灯"]

        // MARK: 逐日生成银行流水（同时记余额）与现金手记
        var months: [String] = []
        var bank: [String: [BankRow]] = [:]
        var manual: [String: [FinanceTransaction]] = [:]
        var balance = 480_000
        var refunds: [(day: LocalDay, cents: Int, description: String)] = []

        func post(_ day: LocalDay, _ cents: Int, _ description: String) {
            balance += cents
            bank[day.monthKey, default: []].append(BankRow(day: day, cents: cents, description: description, balance: balance))
        }
        func spend(_ day: LocalDay, _ merchant: Merchant, bigger: Bool = false) -> Int {
            let high = bigger ? merchant.high * 2 : merchant.high
            let cents = rng.int(merchant.low...max(merchant.low, high))
            post(day, -cents, merchant.description)
            return cents
        }
        func pick(_ merchants: [Merchant]) -> Merchant { merchants[rng.weighted(merchants.map(\.weight))] }

        // 最近一个月才出现的新商户：今天前三天和前一天各一笔（不跨月）
        let newcomerDays = [cal.today.adding(days: -3), cal.today.adding(days: -1)]
            .map { $0.monthKey == cal.today.monthKey && $0 >= cal.first ? $0 : cal.today }

        for day in LocalDay.range(cal.first, cal.today) {
            if day == cal.first || day.day == 1 { months.append(day.monthKey) }
            let away = cal.isAway(day)
            let semester = cal.isSemester(day)
            let weekend = day.weekdayIndex >= 5
            let t = cal.t(day)
            let week = day.jdn / 7

            for refund in refunds where refund.day == day { post(day, refund.cents, refund.description) }
            refunds.removeAll { $0.day <= day }

            // 收入：奖学金生活费（隔周周四）、助教工资（学期中隔周周三）、补习费（每月 1 日）
            if day.weekdayIndex == 3, week % 2 == 0 {
                post(day, day.year > cal.first.year + 1 ? 152_000 : 148_000, "DIRECT CREDIT 000318 UNIVERSITY STIPEND")
            }
            if semester, day.weekdayIndex == 2, week % 2 == 1 { post(day, rng.int(56_000...88_000), "DIRECT CREDIT 000527 UNIVERSITY CASUAL PAYROLL") }
            if day.day == 1, !away { post(day, rng.int(8...12) * 4_000, "FAST TRANSFER FROM CHEN FAMILY TUTORING FEE") }

            // 固定账单
            if day.day == 3 { post(day, -449, "GOOGLE*GOOGLE ONE G.CO/HELPPAY# NS AUS") }
            if day.day == 5, t >= 0.2, t < 0.45 { post(day, -999, "UBER *ONE MEMBERSHIP HELP.UBER.COM AU") }
            if day.day == 9 {
                let cents = Int(2000 * rng.double(1.48, 1.62))
                post(day, -cents, "OPENAI *CHATGPT SUBSCR OPENAI.COM CA USA")
                post(day, -Int((Double(cents) * 0.03).rounded()), "INTERNATIONAL TRANSACTION FEE")
            }
            if day.day == 12, t >= 0.1 { post(day, -1399, "SPOTIFY P2B7C1D3E4 SYDNEY AUS") }
            if day.day == 15 { post(day, t < 0.55 ? -3500 : -3900, "TELSTRA PREPAID MELBOURNE VI AUS") }
            if day.day == 21 { post(day, -999, "AMZNPRIME AU MEMBERSHIP SYDNEY SOUTH NS AUS") }
            if day.day == 27 { post(day, -449, "APPLE.COM/BILL SYDNEY NS AUS") }
            if day.weekdayIndex == 2, week % 2 == 0, t >= 0.3 { post(day, t < 0.7 ? -2795 : -2995, "DIRECT DEBIT 401763 ANYTIME FITNESS") }

            // 每月 2 日把多余的钱转去券商定投
            if day.day == 2, balance > 650_000 {
                post(day, -min(300_000, (balance - 450_000) / 10_000 * 10_000), "TRANSFER TO COMMSEC COMMBANK APP INVEST")
            }

            // 每年固定的大额：学生服务费、配眼镜、回国机票（8 月中旬订好年底的票）
            if (day.month == 2 || day.month == 7), day.day == 20 { post(day, -18_450, "UNIVERSITY SSAF CAMPERDOWN NS AUS") }
            if day.month == 8, day.day == 5 { post(day, -18_900, "SPECSAVERS BROADWAY NS AUS") }
            if day.month == 8, day.day == 12 { post(day, -rng.int(128_000...165_000), "CHINA EASTERN AIRLINES SYDNEY NS AUS") }

            if away {
                if rng.chance(0.04) { _ = spend(day, shopping[1]) }
            } else {
                // 超市：周末一次大采购
                if rng.chance(weekend ? 0.45 : 0.25) { _ = spend(day, pick(groceries), bigger: weekend) }
                // 吃饭：一天零到三笔
                for p in [0.55, 0.25, 0.08] where rng.chance(p) {
                    let merchant = pick(dining)
                    let cents = spend(day, merchant)
                    if merchant.description.hasPrefix("UBER *EATS"), rng.chance(0.03) {
                        refunds.append((day.adding(days: 1), rng.int(cents / 3...cents), "REFUND UBER *EATS HELP.UBER.COM SYDNEY AU"))
                    }
                }
                // 出行：Opal 公交为主，偶尔打车
                if rng.chance(weekend ? 0.3 : semester ? 0.68 : 0.45) {
                    post(day, -rng.int(320...890), "TRANSPORTFORNSW OPAL SYDNEY NS AUS")
                    if rng.chance(0.3) { post(day, -rng.int(320...890), "TRANSPORTFORNSW OPAL SYDNEY NS AUS") }
                }
                if rng.chance(0.045) { post(day, -rng.int(1100...3500), "DIDIMOBILITY SYDNEY NS AUS") }
                if rng.chance(0.035) { post(day, -rng.int(1300...3900), "UBER *TRIP HELP.UBER.COM SYDNEY AU") }
                // 购物、娱乐、药店、打印
                if rng.chance(0.12) {
                    let merchant = pick(shopping)
                    let cents = spend(day, merchant)
                    if merchant.description.hasPrefix("AMAZON"), rng.chance(0.08) {
                        refunds.append((day.adding(days: rng.int(4...12)), cents, "RETURN AMAZON AU SYDNEY SOUTH NS AUS"))
                    }
                }
                if rng.chance(0.09) {
                    let merchant = pick(leisure)
                    // 打印只在学期中
                    if semester || !merchant.description.contains("PRINTING") {
                        let cents = spend(day, merchant)
                        if merchant.description.hasPrefix("CHEMIST"), rng.chance(0.03) {
                            refunds.append((day.adding(days: 2), cents, "REVERSAL CHEMIST WAREHOUSE TOWN HALL NS AUS"))
                        }
                    }
                }
                // 转账：聚餐 AA、朋友还钱、取现
                if rng.chance(0.02) { post(day, -rng.int(1800...6000), "TRANSFER TO XIAOYU CHEN COMMBANK APP DINNER") }
                if rng.chance(0.015) { post(day, rng.int(1500...4500), "FAST TRANSFER FROM ZHE WANG HOTPOT AA") }
                if rng.chance(0.03) { post(day, -rng.pick([2000, 5000, 5000, 10_000]), "CASH WITHDRAWAL CBA ATM BROADWAY NS AUS") }
                // 现金、代付等手记
                if rng.chance(0.1) {
                    let item = rng.pick(manualItems)
                    let row = ManualExpense.transaction(id: "manual-" + rng.uuid(), day: day, cents: rng.int(item.2...item.3), category: item.1,
                                                        description: item.0, note: "", reason: rng.chance(0.3) ? "随手记" : "手动记账")
                    manual[day.monthKey, default: []].append(row)
                }
            }
            for (index, newcomerDay) in newcomerDays.enumerated() where newcomerDay == day {
                _ = spend(day, newcomers[index])
            }
            if day.adding(days: 1).day == 1 { post(day, max(30, balance / 2400), "CREDIT INTEREST") }
        }

        // MARK: 按月导入、确认分类
        do {
            var ledger = try FinanceService.load(context)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            /// 像用户那样处理一个月刚导入的待确认：新商户归类并记住（同商户批量归类），取现确认，AA 转账归到餐饮
            func confirm(_ sha: String) throws {
                let pending = ledger.transactions.filter { $0.sourceSha256 == sha && $0.needsReview }.map(\.id)
                for id in pending {
                    guard let row = ledger.transactions.first(where: { $0.id == id }), row.needsReview else { continue }
                    switch row.category {
                    case "待分类消费":
                        let category = intended[row.description] ?? "购物"
                        let remember = FinanceEngine.canRemember(row, category: category)
                        try FinanceEngine.updateTransaction(in: &ledger, id: id, category: category, note: notes[row.description] ?? "", remember: remember)
                        if remember, let updated = ledger.transactions.first(where: { $0.id == id }) {
                            let others = FinanceEngine.sameMerchant(in: ledger, as: updated, category: category)
                            FinanceEngine.batchClassify(in: &ledger, ids: Set(others.map(\.id)), category: category)
                        }
                    case "现金取款":
                        try FinanceEngine.updateTransaction(in: &ledger, id: id, category: "现金取款", note: "", remember: false)
                    case "转账待确认":
                        try FinanceEngine.updateTransaction(in: &ledger, id: id, category: "餐饮与外卖", note: "聚餐 AA", remember: false)
                    case "转入款待确认" where row.description.contains("HOTPOT"):
                        try FinanceEngine.updateTransaction(in: &ledger, id: id, category: "餐饮与外卖", note: "朋友还的聚餐 AA", remember: false)
                    default:
                        break
                    }
                }
                // 银行规则认得、但这次想写个备注的（大件）
                for index in ledger.transactions.indices where ledger.transactions[index].sourceSha256 == sha
                    && ledger.transactions[index].note.isEmpty {
                    let row = ledger.transactions[index]
                    if let note = notes[row.description] {
                        try FinanceEngine.updateTransaction(in: &ledger, id: row.id, category: row.category, note: note, remember: false)
                    }
                }
            }

            for (index, month) in months.enumerated() {
                ledger.transactions += manual[month] ?? []
                let rows = bank[month] ?? []
                guard let range = FinanceEngine.monthRange(month), let monthStart = LocalDay(key: range.0), let monthEnd = LocalDay(key: range.1) else { continue }
                let end = min(monthEnd, cal.today)
                let period = StatementPeriod(start: max(monthStart, cal.first).key, end: end.key)
                let csv = rows.map { row in
                    String(format: "%02d/%02d/%04d", row.day.day, row.day.month, row.day.year)
                        + ",\"\(money(row.cents))\",\"\(row.description)\",\"\(money(row.balance))\""
                }.joined(separator: "\n") + "\n"
                let preview = try FinanceEngine.previewImport(raw: csv, account: account, ledger: ledger, period: period, today: cal.today)
                FinanceEngine.applyImport(raw: csv, preview: preview, period: period, to: &ledger)
                // 最近一个月：刚导入，还没来得及确认（导入时间就是现在）
                guard index < months.count - 1 else { continue }
                // 更早的月份：月底后第二天晚上导入的
                let stamp = iso.string(from: end.adding(days: 1).date(minutes: 20 * 60 + rng.int(0...120)))
                if let source = ledger.sources.firstIndex(where: { $0.sha256 == preview.sha256 && $0.account == account }) {
                    ledger.sources[source].importedAt = stamp
                }
                for row in ledger.transactions.indices where ledger.transactions[row].sourceSha256 == preview.sha256 {
                    ledger.transactions[row].importedAt = stamp
                }
                try confirm(preview.sha256)
            }

            // 入账（奖学金、工资、补习费）只能留在“转入款待确认”：最近两个月的还没核对，更早的核对过、设为不计入统计
            let recent = months.suffix(2).first ?? ""
            let incomes = ledger.transactions.filter { $0.category == "转入款待确认" && $0.needsReview && $0.month < recent }.map(\.id)
            for id in incomes {
                try FinanceEngine.updateTransaction(in: &ledger, id: id, category: "转入款待确认", note: "收入，已核对", remember: false)
                try FinanceEngine.setIgnored(in: &ledger, id: id, ignored: true)
            }

            // 固定账单：常用的标记保留；最近九个月设了可选消费预算
            for key in ["chatgpt", "communications", "gym", "google_one", "apple"] { ledger.reviewPreferences[key] = "keep" }
            for month in months.suffix(9) { ledger.budgets[month] = ["dining": 60_000, "ride_hail": 8_000, "entertainment": 6_000] }

            // 最近一年已过完的月份各存一份月卷（存的是当时的快照，所以放在所有修改之后）
            for month in months.filter({ $0 < cal.today.monthKey }).suffix(12) {
                _ = FinanceEngine.saveReport(in: &ledger, month: month, reflection: rng.pick(reflections))
            }

            try FinanceService.save(ledger, context: context)
            report.transactions = ledger.transactions.count
            report.manual = ledger.transactions.filter(\.isManual).count
            report.refunds = ledger.transactions.filter { $0.kind == "退款" }.count
            report.pendingReview = ledger.transactions.filter(\.awaitingReview).count
            report.ignored = ledger.transactions.filter(\.isIgnored).count
            report.imports = ledger.sources.count
            report.rules = ledger.merchantRules.count
            report.monthlyReports = ledger.monthlyReports.count
        } catch {
            report.problems.append("账簿：\(error.localizedDescription)")
        }
    }

    /// CommBank CSV 的金额写法：“-12.50”“+1234.56”
    private static func money(_ cents: Int) -> String {
        let value = abs(cents)
        return (cents < 0 ? "-" : "+") + "\(value / 100)." + String(format: "%02d", value % 100)
    }
}
#endif
