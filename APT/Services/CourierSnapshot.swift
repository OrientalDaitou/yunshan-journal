import Foundation
import SwiftData

// 飞剑传书的“给 AI 看”的两份文件：数据快照 snapshot.md 与投递说明 README.md（以及命令行投递用的小抄）。
// 收件箱巡查、写入与撤销、命令行投递在 CourierService.swift。

@MainActor
extension CourierService {
    /// 上次写快照时的数据指纹：巡查时比较，变了才重建
    static var snapshotFingerprint = ""

    /// 一类记录的“条数:最近修改时间”：增删改都会让它变（只数条数、取最新一条，不整表取）
    private static func mark<T: PersistentModel>(_ type: T.Type, _ key: KeyPath<T, Date>, in context: ModelContext) -> String {
        var latest = FetchDescriptor<T>(sortBy: [SortDescriptor(key, order: .reverse)])
        latest.fetchLimit = 1
        let count = (try? context.fetchCount(FetchDescriptor<T>())) ?? -1
        let stamp = (try? context.fetch(latest))?.first.map { $0[keyPath: key].timeIntervalSince1970 } ?? 0
        return "\(count):\(stamp)"
    }

    /// 便宜的“数据有没有变”指纹：各类记录（含作息块）的条数与最近修改时间、账簿修改时间、修为设置的内容、今天的日期、收件箱里无法识别的文件。
    static func fingerprint(_ context: ModelContext) -> String {
        func mark<T: PersistentModel>(_ type: T.Type, _ key: KeyPath<T, Date>) -> String { Self.mark(type, key, in: context) }
        // 作息块：与其它表同法，只数条数、取最近新建的一条（不整表取，#21）；原地修改不动 createdAt，
        // 另记门铃（InboxWatcher）看保存通知记下的“作息最近一次随保存改动”的时刻。境界设置没有修改时间：直接把内容摘进指纹（只有一行）
        let routine = mark(RoutineBlock.self, \.createdAt) + ":\(InboxWatcher.routineSavedAt)"
        let settings = context.all(AppSettings.self).first.map {
            "\($0.realms.joined(separator: ","))/\($0.thresholds.map(String.init).joined(separator: ","))/\($0.dailyCap)/\($0.cultivationEnabled)"
        } ?? ""
        return [
            mark(JournalEntry.self, \.updatedAt), mark(ScheduleEvent.self, \.updatedAt), mark(HabitLog.self, \.updatedAt),
            mark(Habit.self, \.updatedAt), mark(Goal.self, \.updatedAt), mark(Profile.self, \.updatedAt),
            mark(FinanceStore.self, \.updatedAt), mark(CourierDelivery.self, \.receivedAt),
            String(routine.hashValue), String(settings.hashValue),
            LocalDay.today(in: timeZone).key, strayFiles().joined(separator: ","),
        ].joined(separator: "|")
    }

    private static let snapshotPreamble = """
    > 「云山修习录」自动生成的数据快照，供 AI 复盘、给建议时读取（只读；要写入请按同目录的 README.md 投递）。应用开着时数据一变几秒内刷新，应用没开时不更新。
    > 先核对下面的「今天」：和真实日期不同，说明快照是旧的，请提醒用户打开应用。
    > 先读「近况速览」，要细节再看后面各节。修行录只收近 \(SnapshotTrim.Limits().journalDays) 天、从新到旧，较早的条目只留开头。
    """

    /// 重建快照、投递说明与小抄（内容没变的文件不重写）。
    /// 快照：开头「近况速览」（Core/SnapshotDigest），后面各节照旧但有收缩，全文 4 万字封顶（SnapshotTrim）。
    /// 不新增全量计算：修为与习惯统计读 CultivationModel 的缓存，速览另取的复盘、落笔都按日期 #Predicate 小范围取。
    /// recheck：记下的整表结果（最近的日程类别）一律重算——每 10 分钟的兜底刷新用，不带修改时间的改动也不会一直沿用旧值。
    static func refreshSnapshot(context: ModelContext, recheck: Bool = false) {
        prepareFolders()
        if recheck { memo.removeAll() }
        // 巡查用的是数据库的主 context（与界面同一个）：还没建修为模型时先建一份，界面出现时直接用它（每个数据库一份）。
        // 快照里的习惯一节、修为都借模型缓存的统计，不再重新取习惯、逐个读冷掉的打卡关系（5 年数据每次约 1.5 秒）
        if context === context.container.mainContext { _ = CultivationModel.shared(for: context) }
        let today = LocalDay.today(in: timeZone)
        let limits = SnapshotTrim.Limits()
        // 修为与习惯统计的缓存（与侧栏境界卡、今日洞府同一份）：指纹没变时约 1 ms，什么都不算。
        // 放在 build 之前：SummaryCollector 的习惯一节也借它算好的统计，不再把习惯重新取一遍
        let model = CultivationModel.shared(for: context)
        model.refresh()
        var options = SummaryCollector.Options()
        // 修为挪进开头的速览，正文不再重复；目标按快照的口径另取（进行中与暂停按期限排，已完成的只列 90 天内的）
        options.sections.remove(.cultivation)
        options.sections.remove(.goals)
        // 快照只给用户自己装的 apt-record 技能读，保留称呼（参悟页的“隐去姓名”管的是复制给外部 AI 的那份）
        options.hideIdentity = false
        options.upcomingDays = 14
        options.pastDays = 7
        options.journalDays = limits.journalDays
        options.journalNewestFirst = true
        options.journalFullDays = limits.fullDays
        options.journalBodyLimit = limits.fullBody
        // 更早的先按复盘的上限截；日记、灵感由 SnapshotTrim 再压短，篇幅预算也交给它
        options.journalOlderBodyLimit = limits.olderReviewBody
        options.journalCharBudget = 0
        var summary = SummaryCollector.build(context: context, options: options, today: today)
        // 近 12 个月逐月趋势与近 90 天统计洞察（与问道灵枢、修行录卷中洞见共用一份缓存；快照不隐去姓名）
        if options.sections.contains(.trends) { AIDigest.attach(&summary, context: context, today: today) }
        // 传书近况、投递说明、小抄共用一次取到的习惯、目标与收件箱遗留文件
        let stray = strayFiles()
        let habits = activeHabits(context)
        let goals = SnapshotDigestCollector.goalFacts(context)
        summary.goals = SnapshotTrim.goals(goals, today: today, limits: limits)
        summary.overview = overview(context: context, stray: stray, limit: limits.deliveries)
        if let m = summary.financeToDate { summary.financeToDate?.manual = Array(m.manual.prefix(limits.manualList)) }
        let digest = SnapshotDigest.lines(SnapshotDigestCollector.input(context: context, today: today, summary: summary,
                                                                         goals: goals, model: model))
        writeIfChanged(SnapshotTrim.compose(summary, preamble: snapshotPreamble, digest: digest, today: today, limits: limits),
                       to: snapshotURL)
        writeIfChanged(readme(context: context, habits: habits, stray: stray), to: readmeURL)
        writeIfChanged(courierState(habits: habits, roster: rosterState(goals: goals, model: model)), to: stateURL)
        snapshotFingerprint = fingerprint(context)
    }

    /// 用户刚做完的操作（例如撤销传书）之后要刷新快照：数据多时重建要好几秒，不在点按钮的这一下当场做，免得界面卡住。
    /// 巡查在跑就交给它，下一轮数据停稳后重建（3–6 秒内，与其他改动后的刷新同一节奏）；没在巡查时（离屏、命令行）照旧当场重建。
    static func refreshSnapshotSoon(context: ModelContext) {
        if patrolling { snapshotFingerprint = "" } else { refreshSnapshot(context: context) }
    }

    // MARK: 记下的整表结果

    /// 快照里要整表取数的结果（最近的日程类别），连同算它时那类记录的“条数:最近修改时间”：没变就直接用，变了才重算
    private static var memo: [String: (key: String, value: Any)] = [:]

    private static func memoized<T>(_ name: String, key: String, _ make: () -> T) -> T {
        if let hit = memo[name], hit.key == key, let value = hit.value as? T { return value }
        let value = make()
        memo[name] = (key, value)
        return value
    }

    /// 记下的结果只对同一个数据库有效（自检会换着用好几个临时库）：钥匙由 StoreIdentity 编号，内存地址被新库复用也不会认错
    private static func store(_ context: ModelContext) -> String { StoreIdentity.key(for: context).description }

    /// 快照的「传书近况」：最近的飞剑传书（limit 封）、收件箱里的遗留文件。修为挪进了开头的速览
    private static func overview(context: ModelContext, stray: [String], limit: Int) -> [String] {
        var lines: [String] = []
        // 只让数据库按收录时间取最近几封
        var recent = FetchDescriptor<CourierDelivery>(sortBy: [SortDescriptor(\.receivedAt, order: .reverse)])
        recent.fetchLimit = limit
        let deliveries = (try? context.fetch(recent)) ?? Array(context.all(CourierDelivery.self).sorted { $0.receivedAt > $1.receivedAt }.prefix(limit))
        if deliveries.isEmpty {
            lines.append("- 还没有收到过飞剑传书")
        } else {
            lines.append("- 最近的飞剑传书（新→旧）：")
            for d in deliveries {
                let first = d.summary.split(separator: "\n").first.map { "：" + $0 } ?? ""
                lines.append("  - \(DateText.stamp(d.receivedAt)) 来自 \(d.from)，\(d.itemCount) 条\(d.undone ? "（已撤销）" : "")\(first)")
            }
        }
        if !stray.isEmpty {
            lines.append("- 收件箱里有 \(stray.count) 个应用不会处理的文件：\(stray.prefix(5).joined(separator: "、"))\(stray.count > 5 ? " 等" : "")")
        }
        return lines
    }

    /// 内容没变就不重写；“生成时间”不参与比较，否则每次都会重写
    private static func writeIfChanged(_ text: String, to url: URL) {
        if let old = try? String(contentsOf: url, encoding: .utf8), comparable(old) == comparable(text) { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func comparable(_ text: String) -> String {
        text.replacingOccurrences(of: #"生成时间：\d{4}-\d{2}-\d{2} \d{2}:\d{2}"#, with: "", options: .regularExpression)
    }

    /// 命令行投递用的小抄：现有习惯名与各自的单位（`APT --add` 投递前先对一遍，单位与 habits 一一对应），以及应用换算日期用的时区
    /// （命令行可能跑在设了别的 TZ 的 shell 里，显示日期、判断“未来”时以应用的时区为准）。
    /// roster：goal / habit 预检用的已归档习惯与全部目标（rosterState，见 CourierReadmeGoalHabit.swift），并进同一份
    private static func courierState(habits: [Habit], roster: [String: Any] = [:]) -> String {
        let titles = habits.map(\.title)
        // habitTargets：每次的数量目标（0 = 打卡即完成），--add 预检“只是相关的同类说法没写数量”用
        var object: [String: Any] = ["habits": titles, "habitUnits": habits.map(\.unit),
                                     "habitTargets": habits.map { $0.targetValue.flatMap { $0 > 0 ? $0 : nil } ?? 0 },
                                     "timeZone": timeZone.identifier]
        object.merge(roster) { current, _ in current }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// 没归档的习惯，按界面上的顺序（投递说明的习惯表、命令行小抄共用）。
    /// 只取 ID 再拿已登记的对象（与 all(Habit.self) 同样的对象与次序）：不重新取习惯，不让界面上的打卡关系变冷
    private static func activeHabits(_ context: ModelContext) -> [Habit] {
        context.allHabits().filter { !$0.archived }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 最近用过的日程类别（给 AI 参考，免得同一类被写成几种叫法）。
    /// 要整表取日程，所以记下来：日程的条数与最近修改时间都没变就沿用（改类别会更新修改时间）
    private static func recentEventCategories(_ context: ModelContext) -> [String] {
        memoized("eventCategories", key: store(context) + "|" + mark(ScheduleEvent.self, \.updatedAt, in: context)) {
            var seen = Set<String>()
            return context.all(ScheduleEvent.self).sorted { $0.updatedAt > $1.updatedAt }
                .map { $0.category.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .prefix(12).map { $0 }
        }
    }

    static func readme(context: ModelContext) -> String {
        readme(context: context, habits: activeHabits(context), stray: strayFiles())
    }

    private static func readme(context: ModelContext, habits: [Habit], stray: [String]) -> String {
        // “也能对上的说法”：按同类说法（HabitAlias）还能对上这项功课的词；一组对上几项功课时不列（传书时不猜）
        let aliasWords = HabitAlias.readmeWords(titles: habits.map(\.title))
        let habitRows: [String] = habits.enumerated().map { i, h in
            let target = h.targetValue.flatMap { $0 > 0 ? $0 : nil }
            let goal = target.map { format($0) + (h.unit.isEmpty ? "" : " " + h.unit) } ?? "无数量目标（打卡即完成）"
            let unit = target == nil ? "可不写" : (h.unit.isEmpty ? "与目标相同" : h.unit)
            // 只是相关的说法（散步之于「步数」）对有数量目标的功课注明“需写数量”：不写 quantity 不会替用户记满
            let words = HabitAlias.readmeCell(aliasWords.indices.contains(i) ? aliasWords[i] : [], title: h.title, hasTarget: target != nil)
            return "| \(h.title) | \(h.spec.scheduleSummary) | \(goal) | \(unit) | \(words) |"
        }
        let habitTable = habitRows.isEmpty ? "（暂无习惯：现在不能打卡）" : """
            | 习惯 | 频率 | 每次目标 | quantity 单位 | 也能对上的说法 |
            |---|---|---|---|---|
            \(habitRows.joined(separator: "\n"))
            """
        let categories = recentEventCategories(context)
        let profile = context.all(Profile.self).sorted { $0.createdAt < $1.createdAt }.first
        let profileRows = ProfileCatalog.sections.map { section in
            section.fields.map { f in
                let filled = !(profile?[f.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return "| `\(f.key)` | \(f.label) | \(section.title == "目标" ? "方向" : section.title) | \(f.multiline ? "可多句" : "一行") | \(filled ? "已填" : "空") |"
            }.joined(separator: "\n")
        }.joined(separator: "\n")
        let zone = timeZone.identifier
        var text = """
        # 云山修习录 · 飞剑传书（给 AI 的投递说明）

        这是用户的个人记录应用 APT（云山修习录）。你可以替用户把日记、灵感、复盘、消费、日程、习惯打卡写进去，也可以补写、更新个人档案，新立或更新目标，新建习惯：
        把一个 UTF-8 编码的 JSON 文件放进收件箱
        `\(inbox.path)`
        应用运行时约 3 秒内收录；没运行时文件会留在收件箱，下次打开应用再收录。用户可以在应用里整批撤销任何一次传书。

        读取用户现状（复盘、给建议时用）：`\(snapshotURL.path)`（先核对开头的「今天」和「生成时间」）

        ## 投递步骤

        1. 文件名带上时间和随机串，例如 `claude-20261014-213005-a1b2c3d4.json`
           （`claude-$(date +%Y%m%d-%H%M%S)-$(uuidgen | cut -c1-8).json`）。不带随机串的话，同一秒投两封会互相覆盖。
        2. 先写成 `名字.json.tmp`，写完再用 `mv -n` 改名为 `名字.json`。应用只收 `.json`，其他扩展名不会处理。
        3. 一个文件不超过 1 MB、最多 200 条；任一条校验失败，整份都不写入——只有打卡的习惯名或单位对不上例外：只退回那一条，其余照收（见下面 checkin 一节）。
        4. 等 5–10 秒查看回执。回执文件名是「收录时间-原名」，**不是原名**：
           - 成功：`processed/20261014-213008-claude-20261014-213005-a1b2c3d4.result.txt`（原件也移到旁边）。
             首行是“已收录 N 条（…）”；有打卡被退回时首行是“已收录 N 条，另有 M 条没有收录（见下）”，末尾逐条写明原因
           - 失败：`failed/20261014-213008-claude-…-a1b2c3d4.error.txt`，写明第几条、哪个字段有问题；改好后换一个新文件名重投。
           查找：`ls "\(processed.path)" "\(failed.path)" | grep 原名去掉.json`。
           文件从收件箱消失就说明应用已经处理过，**不要因为找不到同名回执就重投**；还在收件箱里说明应用没开，告诉用户下次打开应用时会自动收录。
        5. 同样的内容 7 天内已经收录过（没撤销、写入的记录也还在），再投会被跳过：回执同样是 `.result.txt`，但开头写“重复投递，已跳过”，
           这时什么都没写入，**不要告诉用户已记好**。确实是另一笔一模一样的（比如同一天两杯同样的咖啡），请在条目里写明区别
           （消费写在 note，例如“第二杯”）后换个文件名重投；打卡被跳过说明那天已经打过，无需重投。如实告诉用户。

        ## 文件格式

        ```json
        {
          "from": "Claude",
          "note": "可选：这批内容的来由",
          "items": [
            {"type": "diary",   "date": "today", "time": "22:10", "title": "可选", "body": "第一段\\n第二段", "mood": 4, "tags": ["论文"]},
            {"type": "note",    "date": "today", "title": "灵感标题", "body": "内容", "tags": ["读书"]},
            {"type": "review",  "date": "2026-10-11", "period": "week", "title": "第 41 周复盘", "body": "【所得】…\\n【所失】…\\n【所悟】…\\n【下一步】…"},
            {"type": "expense", "date": "today", "amount": 18.5, "category": "餐饮与外卖", "description": "午饭 拉面", "note": "现金"},
            {"type": "event",   "date": "tomorrow", "start": "14:00", "end": "15:30", "title": "导师会议", "location": "", "category": "学业"},
            {"type": "checkin", "date": "today", "habit": "晨读二十分钟", "quantity": 20},
            {"type": "profile", "fields": {"career_goals": "毕业后……", "rest_preferences": "……"}},
            {"type": "goal",    "title": "完成学位论文初稿", "target_date": "2027-02-17", "category": "学业", "priority": "must"},
            {"type": "goal",    "action": "update", "title": "完成学位论文初稿", "progress": 70, "notes": "第三章初稿完成"},
            {"type": "habit",   "title": "冥想", "target": 10, "unit": "分钟", "start_date": "today"}
          ]
        }
        ```

        单条也可以直接写成 `{"type": …}`，或者写成数组 `[{…}, {…}]`。`from`（例如 "Claude"）和 `note` 可选。
        日期照上面写 `today` / `yesterday` / `tomorrow` 即可；review 那条的 `"2026-10-11"` 是“别的日子”（例如上周日）的写法 `YYYY-MM-DD`。

        ### 所有类型都有的字段

        - `type`（必填）：`diary` 日记 · `note` 灵感 · `review` 复盘 · `expense` 消费 · `event` 日程 · `checkin` 打卡 · `profile` 档案 · `goal` 目标 · `habit` 新习惯
        - `date`（profile、goal、habit 不用）：今天、昨天、明天直接写 `today` / `yesterday` / `tomorrow`（省略即 `today`），**不用先跑 `date`**——
          应用按**文件写入的时刻**、用户所在时区 \(zone) 换算，不是按应用收录的时刻，隔天才收录也不会记错日子。
          “上周五”“10 号”这类才换算成 `YYYY-MM-DD`（以时区 \(zone) 为准，例如 `TZ=\(zone) date +%F` 取今天的日期再推算）。
          60 天以前或一年以后的日期照收，但回执会提醒，请核对年份。
        - JSON 字符串里的换行要写成 `\\n`、双引号写成 `\\"`，不能在引号里直接换行。写完可以先用 `plutil -convert json -o /dev/null 文件` 检查语法。
        - 数字字段（mood、amount、quantity、progress、target、times_per_week）写成数字；`null` 等于没写；不要写 `true` / `false`。

        ### diary / note / review（进修行录）

        | 字段 | 必填 | 说明 |
        |---|---|---|
        | `title` | 与 body 至少一个 | 标题 |
        | `body` | 与 title 至少一个 | 正文（也认 `content` / `text`） |
        | `time` | 否 | 当天的时刻 `HH:MM`（00:00–23:59） |
        | `mood` | 否，只用于 diary | 心境，1–5 的整数：1 雨 · 2 阴 · 3 平 · 4 晴 · 5 霁 |
        | `period` | 否，只用于 review | `day` / `week` / `month` / `event` |
        | `tags` | 否 | 字符串数组，例如 `["论文", "读书"]`（也认逗号分隔的字符串，或单数 `tag`） |

        复盘正文建议分【所得】【所失】【所悟】【下一步】四段。

        ### expense（进灵石账簿，账户记为“手记”）

        | 字段 | 必填 | 说明 |
        |---|---|---|
        | `amount` | 是 | 金额，单位元（澳元），正数，例如 `18.5` |
        | `description` | 是 | 花在什么上，例如“午饭 拉面”（也认 `title`） |
        | `category` | 否 | 只能从下面的类别里选，否则记为「待分类消费」 |
        | `note` | 否 | 备注，例如支付方式 |

        消费类别：\(FinanceEngine.spendCategories.joined(separator: "、"))

        **消费**：用户说了花了多少就照常记，**不必追问现金还是刷卡**。没说支付方式时 `note` 写“未说明支付方式”；说了是刷卡的写“刷卡”。
        用户的银行卡消费之后会随 CommBank 账单 CSV 导入应用，导入时应用会列出可能与手记重复的流水，由用户决定删不删手记那笔。
        补记过去的消费时，如果账上已有金额相同、日期相差 3 天内的银行流水，照常收录，但回执“提醒”里会指出那笔流水：请向用户确认是不是同一笔。

        ### event（进日程，只能建单次日程）

        | 字段 | 必填 | 说明 |
        |---|---|---|
        | `title` | 是 | 标题 |
        | `start` | 否 | 开始时间 `HH:MM`；不写就是全天（也认 `time` / `start_time`） |
        | `end` | 否 | 结束时间 `HH:MM`，要晚于 start；到当天结束写 `24:00`（也认 `end_time`） |
        | `location` | 否 | 地点 |
        | `category` | 否 | 类别，尽量沿用已有的：\(categories.isEmpty ? "（暂无）" : categories.joined(separator: "、")) |
        | `notes` | 否 | 备注（也认 `note`） |

        日程不能跨夜：22:00 到次日 01:00 请拆成两条（当天 22:00–24:00、次日 00:00–01:00）。重复日程请让用户在应用里设置。

        ### checkin（习惯打卡）

        | 字段 | 必填 | 说明 |
        |---|---|---|
        | `habit` | 是 | 习惯名称，按名称匹配（写全称最稳；也认下表“也能对上的说法”，例如“跑步”对上“运动”，回执会注明。标了“需写数量”的说法只是相关——例如“散步”之于“步数”——必须同时写 quantity，否则这一条不收） |
        | `quantity` | 否 | 这次实际完成的数量（正数）。不写就按“达标”记成目标值——用户只做了一部分时一定要写实际数量 |
        | `unit` | 写了 quantity 时请写 | quantity 的单位，例如 `"分钟"`、`"公里"`、`"杯"`（也认 `单位`）。和下表的单位不同时自动换算（小时↔分钟、公里↔米、千步↔步、升↔毫升），回执会注明“1 小时按 60 分钟记” |

        不能给未来的日子打卡；那一天已经有记录的不会覆盖（回执里注明“跳过”）。

        **打卡对不上只退这一条**：习惯名对不上（同类说法也对不上，或能对上好几项；标了“需写数量”的说法没写 quantity）、
        单位换算不了（“步数”写成“公里”）或换算后不到 0.01（“1 米”记到按公里计的习惯上）的打卡不写入，
        同一封里其余条目照收。回执首行写“已收录 N 条，另有 M 条没有收录（见下）”，末尾“未收录 · 第 N 条：…”写明原因与候选。
        这时**只把没收录的那几条改好另投一封，不要整封重投**（其余已经记好，整封重投会重复记账）。整封全是这类打卡时整封不收（进 `failed/`）。
        用户说的说法拿不准对哪项功课，先问用户。

        现有习惯：

        \(habitTable)

        ### profile（写进「修士名帖 · 个人档案」）

        | 字段 | 必填 | 说明 |
        |---|---|---|
        | `fields` | 是 | 对象：字段 key（也认下表的中文名）→ 内容（字符串）。只写要补写或更新的字段 |

        写进去的内容会**替换**该字段原有的内容（回执里逐项列出），撤销时恢复成原来的内容；收录后用户在应用里又改过的字段，撤销时默认保留。
        空字符串不会清掉已有内容；认不出的字段整份拒收。“一行”的字段里写了换行，会改成“；”。单个字段最多 \(CourierParser.profileValueLimit) 字。
        现有内容见 `snapshot.md` 的「个人档案」：更新已填的字段前先读一遍，保留仍然成立的部分，只依据用户说过的话，不要编造。
        多行字段在快照里逐行缩进列出；改写时照原样保留换行（JSON 里写 \\n），不要把几行并成一行。

        | key | 名称 | 分组 | 长度 | 现在 |
        |---|---|---|---|---|
        \(profileRows)

        \(goalHabitReadme(context: context, habitCategories: habits.map(\.category)))

        ## 其他

        - 不认识的字段不会写入，回执的“提醒”里会列出来；常见的别名会自动换算，也会注明。
        - 照用户的原话记录，不要编造用户没说过的事实；拿不准的日期、金额、习惯名先问用户。
        - `processed/` 和 `failed/` 里的归档保留 \(archiveDays) 天后自动清理。
        """
        if !stray.isEmpty {
            text += "\n- 收件箱里有 \(stray.count) 个应用不会处理的文件：\(stray.prefix(10).joined(separator: "、"))\(stray.count > 10 ? " 等" : "")。"
            text += "请和用户确认后改成 `.json` 重投，或者删掉。"
        }
        return text + "\n"
    }
}
