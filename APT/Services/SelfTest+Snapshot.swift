import Foundation
import SwiftData

// 快照 snapshot.md 改版（开头「近况速览」、各节收缩、全文封顶）与投递说明 goal / habit 两节、命令行小抄新键的自检。
// 速览每一行怎么算在 Tools/CoreCheck 里测；这里测取数与接线：真的写出了文件、取的是缓存里的那份、收缩与封顶生效。
// 只在临时数据目录里运行（快照、README、小抄都写在数据目录的 AI/ 下）。

extension SelfTest {
    static func snapshotDigestChecks(_ check: (Bool, String) -> Void) throws {
        guard DataStore.customDirectory != nil else { return }
        try snapshotBasicChecks(check)
        #if DEBUG
        try snapshotDemoChecks(check)
        try snapshotSample(check)
        #endif
    }

    // MARK: 小库：三个习惯、几个目标、几篇复盘

    private static func snapshotBasicChecks(_ check: (Bool, String) -> Void) throws {
        let c = try snapshotContext()
        let today = LocalDay.today()
        let profile = DataStore.profile(in: c)
        profile["nickname"] = "自检青岚"
        profile["main_tasks"] = "写完论文第三章\n  周三助教辅导课\n\n周末补习数学"
        profile["city"] = "悉尼"

        // 功课：每天（带数量目标）、每周 3 次、指定星期；另有一个已归档的
        let read = Habit(title: "自检晨读")
        read.category = "学习"
        read.targetValue = 20
        read.unit = "分钟"
        read.startDate = today.adding(days: -40).key
        read.sortOrder = 0
        let run = Habit(title: "自检运动")
        run.category = "健康"
        run.frequencyKind = .weekly
        run.targetPerWeek = 3
        run.startDate = today.adding(days: -40).key
        run.sortOrder = 1
        let piano = Habit(title: "自检练琴")
        piano.frequencyKind = .weekdays
        piano.weekdays = [1, 3, 5]
        piano.startDate = today.adding(days: -40).key
        piano.sortOrder = 2
        let rope = Habit(title: "自检跳绳")
        rope.archived = true
        rope.archivedAt = today.adding(days: -5).key
        rope.sortOrder = 3
        for habit in [read, run, piano, rope] { c.insert(habit) }
        for offset in 1...30 {
            let log = HabitLog(dateKey: today.adding(days: -offset).key, completed: true, quantity: 20)
            c.insert(log)
            log.habit = read
        }

        // 目标：进行中（有期限、必须）、暂停、近期完成、很久以前完成、已放弃
        func goal(_ title: String, status: String, progress: Int, deadline: Int?, created: Int, updated: Int) {
            let g = Goal(title: title)
            g.status = status
            g.progress = progress
            g.priority = title.contains("论文") ? "must" : "should"
            g.category = "自检"
            g.targetDate = deadline.map { today.adding(days: $0).key }
            g.createdAt = today.adding(days: -created).date()
            g.updatedAt = today.adding(days: -updated).date()
            c.insert(g)
        }
        goal("自检论文初稿", status: "active", progress: 40, deadline: 30, created: 90, updated: 3)
        goal("自检卡农", status: "paused", progress: 25, deadline: nil, created: 80, updated: 20)
        goal("自检应急金", status: "completed", progress: 100, deadline: nil, created: 120, updated: 10)
        goal("自检旧目标", status: "completed", progress: 100, deadline: nil, created: 400, updated: 200)
        goal("自检放弃的", status: "cancelled", progress: 10, deadline: nil, created: 70, updated: 60)

        // 修行录：两篇复盘（较新的一篇在后插入）、一篇 AI 建议（最新，速览里不算）、今天一篇日记
        func entry(_ kind: JournalKind, _ title: String, _ body: String, daysAgo: Int, tags: [String] = [], mood: Int? = nil) {
            let e = JournalEntry(kind: kind, title: title, body: body, dateKey: today.adding(days: -daysAgo).key)
            e.tags = tags
            e.mood = mood
            e.period = kind == .review ? "week" : ""
            c.insert(e)
        }
        entry(.review, "自检第一篇", "【所得】写了两千字。\n【所悟】早睡比熬夜有用。\n【下一步】周三前交初稿。", daysAgo: 9)
        entry(.review, "自检第二篇", "【所得】跑步三次。\n【所失】外卖多了。\n【所悟】先写后改更快；其余不提。\n【下一步】每天上午先写 90 分钟。", daysAgo: 2)
        entry(.review, "AI 建议 · 周复盘", "【所悟】这条是 AI 写的建议", daysAgo: 0, tags: [SnapshotDigestCollector.adviceTag])
        entry(.diary, "", "自检今天的日记", daysAgo: 0, mood: 4)
        entry(.diary, "", "自检未来的补记", daysAgo: -3, mood: 1)
        // 六封传书：传书近况只列最近 5 封
        for index in 0..<6 {
            let d = CourierDelivery(fileName: "selftest-\(index).json", from: "自检", note: "")
            d.receivedAt = Date().addingTimeInterval(Double(index - 10) * 60)
            d.summary = "灵感 · 自检传书 \(index)"
            d.itemCount = 1
            c.insert(d)
        }
        DataStore.save(c)

        CourierService.refreshSnapshot(context: c)
        let snapshot = (try? String(contentsOf: CourierService.snapshotURL, encoding: .utf8)) ?? ""
        let readme = (try? String(contentsOf: CourierService.readmeURL, encoding: .utf8)) ?? ""
        let stateData = FileManager.default.contents(atPath: CourierService.stateURL.path) ?? Data()
        let state = (try? JSONSerialization.jsonObject(with: stateData)) as? [String: Any] ?? [:]

        let digest = section(snapshot, "## 近况速览")
        let courier = section(snapshot, "## 传书近况")
        let digestAt = snapshot.range(of: "## 近况速览")?.lowerBound, courierAt = snapshot.range(of: "## 传书近况")?.lowerBound
        check(digestAt != nil && courierAt != nil && digestAt! < courierAt!, "快照：「## 近况速览」排在「## 传书近况」之前")
        check(snapshot.count <= SnapshotTrim.Limits().totalCap, "快照全文 \(snapshot.count) 字，不超过 4 万字")
        let digestLines = digest.split(separator: "\n").map(String.init)
        check(!digestLines.isEmpty && digestLines.count <= 30 && digest.count <= 2_000,
              "近况速览 \(digestLines.count) 行、\(digest.count) 字（≤ 30 行、≤ 2,000 字）")
        let model = CultivationModel.shared(for: c)
        let last7 = (0..<7).reduce(0) { $0 + (model.state.perDay[today.adding(days: -$1)] ?? 0) }
        check(model.state.totalXP > 0 && digestLines.first?.hasPrefix("- 境界：\(model.state.title)，累计修为 \(SnapshotDigest.grouped(model.state.totalXP))") == true
              && digestLines.first?.contains("；近 7 日 +\(SnapshotDigest.grouped(last7))（") == true,
              "速览境界一行与修为模型（侧栏境界卡同一份）一致：\(digestLines.first ?? "")")
        check(!courier.contains("修为") && !snapshot.contains("## 修为进度"), "修为只在速览里，不在传书近况、也不另起一节")
        check(courier.components(separatedBy: "\n  - ").count - 1 == 5 && courier.contains("自检传书 5") && !courier.contains("自检传书 0"),
              "传书近况只列最近 5 封（新→旧）")
        check(digest.contains("本周功课") || digest.contains("上周功课"), "速览有功课一行")
        check(digest.contains("自检第二篇") && digest.contains("所悟：先写后改更快；下一步：每天上午先写 90 分钟")
              && !digest.contains("AI 写的建议"), "最近复盘取所悟与下一步的第一句，AI 建议不算")
        if let second = digest.range(of: "自检第二篇"), let first = digest.range(of: "自检第一篇") {
            check(second.lowerBound < first.lowerBound, "最近复盘新的在前")
        } else {
            check(false, "最近复盘两篇都列出")
        }
        check(digest.contains("- 落笔：近 7 天 3 篇") && digest.contains("心境多「晴」"),
              "落笔一行：近 7 天 3 篇（未来日期的补记不算），心境取日记")
        check(digest.contains("- 目标（进行中 1 · 暂停 1）：") && digest.contains("自检论文初稿 40%") && digest.contains("［必须］")
              && digest.contains("近 30 天完成：自检应急金"), "速览目标：进行中、暂停、近 30 天完成")
        check(digest.contains("- 消费：还没有账目"), "没有账目时速览写明“还没有账目”")
        let goals = section(snapshot, "## 目标")
        check(goals.contains("自检论文初稿") && goals.contains("自检卡农") && goals.contains("自检应急金")
              && !goals.contains("自检旧目标") && !goals.contains("自检放弃的"),
              "快照目标一节：进行中与暂停全列，已完成只列 90 天内的，已放弃的不列")
        check(snapshot.contains("- 主要任务：\n  写完论文第三章\n  周三助教辅导课\n  周末补习数学\n"), "快照档案多行字段逐行缩进列出（空行去掉）")
        check(snapshot.contains("- 昵称：自检青岚"), "快照保留称呼")
        var plain = SummaryCollector.Options()
        plain.hideIdentity = false
        let advisor = SummaryRenderer.markdown(SummaryCollector.build(context: c, options: plain, today: today), preamble: "")
        check(advisor.contains("- 主要任务：写完论文第三章；") && !advisor.contains("  周末补习数学") && !advisor.contains("## 近况速览"),
              "问道灵枢的摘要不受影响：多行档案仍用“；”连成一行、没有速览")
        check(snapshot.contains("修行录：最近 \(SnapshotTrim.Limits().journalDays) 天"), "修行录只收近 60 天")

        // 投递说明：goal / habit 两节、实时的现有目标表、习惯类别
        check(readme.contains("### goal（") && readme.contains("### habit（") && readme.contains("现有目标（不含已放弃的 1 个"),
              "README 有 goal、habit 两节与“现有目标”")
        check(readme.contains("| 自检论文初稿 | 进行中 | 40% | \(today.adding(days: 30).key) | 自检 |") && readme.contains("| 自检应急金 | 已完成 |")
              && !readme.contains("| 自检放弃的 |"), "README 现有目标表：进行中、暂停、已完成，不列已放弃的")
        check(readme.contains("尽量沿用已有的：学习、健康") && readme.contains("brain.head.profile 冥想"), "README habit 一节列出已用的习惯类别与 15 个图标")
        if let goalAt = readme.range(of: "### goal（")?.lowerBound, let otherAt = readme.range(of: "## 其他")?.lowerBound,
           let profileAt = readme.range(of: "### profile")?.lowerBound {
            check(profileAt < goalAt && goalAt < otherAt, "README 两节插在 profile 之后、「## 其他」之前")
        } else {
            check(false, "README 两节插在 profile 之后、「## 其他」之前")
        }
        check(readme.contains("`goal` 目标 · `habit` 新习惯") && readme.contains("`date`（profile、goal、habit 不用）"), "README 类型表与 date 说明加上 goal、habit")

        // 命令行小抄：已归档习惯、全部目标（含已放弃）
        let rosterGoals = (state["goals"] as? [[String: Any]]) ?? []
        check(state["archivedHabits"] as? [String] == ["自检跳绳"] && (state["habits"] as? [String])?.contains("自检跳绳") == false,
              "小抄 archivedHabits 只列已归档的习惯")
        check(rosterGoals.count == 5 && rosterGoals.contains { $0["title"] as? String == "自检放弃的" && $0["status"] as? String == "cancelled" }
              && rosterGoals.first?["title"] as? String == "自检旧目标" && rosterGoals.last?["progress"] as? Int == 10,
              "小抄 goals 列全部目标（含已放弃），按创建先后，带状态与进度")

        // 数据没变时再刷新：修为模型什么都不算（快照不新增全量计算）
        let before = model.work
        CourierService.refreshSnapshot(context: c)
        check(model.work == before, "数据没变时再刷新快照，修为与习惯统计都不重算")
        let again = (try? String(contentsOf: CourierService.snapshotURL, encoding: .utf8)) ?? ""
        check(again == snapshot, "数据没变时快照内容不变")

        // 设置里关了修为
        DataStore.settings(in: c).cultivationEnabled = false
        DataStore.save(c)
        CourierService.refreshSnapshot(context: c)
        let off = (try? String(contentsOf: CourierService.snapshotURL, encoding: .utf8)) ?? ""
        check(section(off, "## 近况速览").hasPrefix("- 境界：修为已在设置里关闭"), "关了修为时速览写“修为已在设置里关闭”")
        DataStore.settings(in: c).cultivationEnabled = true
        DataStore.save(c)

        // 空库：每组都有一句“还没有…”，不缺组
        let empty = try snapshotContext()
        CourierService.refreshSnapshot(context: empty)
        let blank = section((try? String(contentsOf: CourierService.snapshotURL, encoding: .utf8)) ?? "", "## 近况速览")
        check(blank.contains("- 境界：炼气 · 初期") && blank.contains("- 功课：还没有习惯") && blank.contains("- 目标：还没有设立具体目标")
              && blank.contains("- 最近复盘：还没有写过复盘") && blank.contains("- 落笔：还没有写过") && blank.contains("- 消费：还没有账目"),
              "空库的速览六组各有一句")
        let emptyReadme = (try? String(contentsOf: CourierService.readmeURL, encoding: .utf8)) ?? ""
        check(emptyReadme.contains("现有目标：（暂无目标）") && emptyReadme.contains("尽量沿用已有的：（暂无）"), "空库的 README 写明暂无目标、暂无类别")

        // 写得极多：60 天里每天三篇三千字的日记，外加更早的。全文仍封顶 4 万字，近 14 天每篇 ≤ 1,500 字，最早的省略并注明
        let heavy = try snapshotContext()
        let paragraph = String(repeating: "今天写了很多字，记下所思所感。", count: 200)
        for offset in 0..<75 {
            for index in 0..<3 {
                heavy.insert(JournalEntry(kind: index == 2 ? .review : .diary, title: "长文 \(offset)-\(index)", body: paragraph,
                                          dateKey: today.adding(days: -offset).key))
            }
        }
        DataStore.save(heavy)
        CourierService.refreshSnapshot(context: heavy)
        let long = (try? String(contentsOf: CourierService.snapshotURL, encoding: .utf8)) ?? ""
        let journal = section(long, "## 修行录（最近 60 天")
        let newest = journal.components(separatedBy: "\n### ").dropFirst().first ?? ""
        check(long.count <= SnapshotTrim.Limits().totalCap && long.contains("因篇幅未列出") && !long.contains("长文 74-")
              && newest.count < SnapshotTrim.Limits().fullBody + 120,
              "大量长文：快照 \(long.count) 字仍不超过 4 万，近 14 天每篇截到 1,500 字，60 天以前的不收、更早的省略并注明")
    }

    #if DEBUG
    // MARK: 演示库

    /// 演示数据（1 年）种进内存库：快照不超过 4 万字，修行录只收 60 天；第二次刷新的耗时打印出来（不设门槛，给以后对照）
    private static func snapshotDemoChecks(_ check: (Bool, String) -> Void) throws {
        let c = try snapshotContext()
        let report = DemoSeeder.seed(into: c, years: 1)
        check(report.problems.isEmpty, "演示库（1 年）种好了")
        var started = Date()
        CourierService.refreshSnapshot(context: c)
        let firstMs = Int(Date().timeIntervalSince(started) * 1000)
        started = Date()
        CourierService.refreshSnapshot(context: c)
        let secondMs = Int(Date().timeIntervalSince(started) * 1000)
        let snapshot = (try? String(contentsOf: CourierService.snapshotURL, encoding: .utf8)) ?? ""
        let digest = section(snapshot, "## 近况速览")
        let digestLines = digest.split(separator: "\n").count
        check(snapshot.count <= SnapshotTrim.Limits().totalCap && snapshot.contains("## 修行录（最近 60 天"),
              "演示库快照 \(snapshot.count) 字（≤ 4 万），修行录一节写“最近 60 天”")
        check(digestLines <= 30 && digest.count <= 2_000 && digest.contains("- 境界：") && digest.contains("- 消费："),
              "演示库速览 \(digestLines) 行、\(digest.count) 字")
        print("  快照刷新耗时（演示库 1 年，内存库）：第一次 \(firstMs) ms，数据没变的第二次 \(secondMs) ms")
    }

    /// 生成样例：设 APT_SNAPSHOT_STORE=<数据库副本所在的文件夹> 时，打开那里的 APT.store 刷新一次快照，
    /// 把 snapshot.md、README.md、小抄复制到那个文件夹的 snapshot-out/ 里，并打印耗时。
    /// 只给开发时看样例用（例如 cp -R .night/demo-store 到临时目录再指过去）；不许指向正式数据目录
    private static func snapshotSample(_ check: (Bool, String) -> Void) throws {
        guard let path = ProcessInfo.processInfo.environment["APT_SNAPSHOT_STORE"], !path.isEmpty else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        if let official = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("APT-SwiftUI", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath(),
           folder.path == official.path {
            check(false, "APT_SNAPSHOT_STORE 指向的是正式数据目录，已拒绝")
            return
        }
        let url = folder.appendingPathComponent("APT.store")
        guard FileManager.default.fileExists(atPath: url.path) else {
            check(false, "APT_SNAPSHOT_STORE 里没有 APT.store：\(url.path)")
            return
        }
        let schema = Schema(APTSchema.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let c = ModelContext(container)
        var started = Date()
        CourierService.refreshSnapshot(context: c)
        let firstMs = Int(Date().timeIntervalSince(started) * 1000)
        started = Date()
        CourierService.refreshSnapshot(context: c)
        let secondMs = Int(Date().timeIntervalSince(started) * 1000)
        let out = folder.appendingPathComponent("snapshot-out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for source in [CourierService.snapshotURL, CourierService.readmeURL, CourierService.stateURL] {
            let target = out.appendingPathComponent(source.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
        // 速览自己新增的取数与计算（目标整表、近 60 天复盘、近 14 天落笔，修为与习惯读缓存）单独计时
        let today = LocalDay.today()
        var bare = SummaryCollector.Options()
        bare.sections = []
        let summary = SummaryCollector.build(context: c, options: bare, today: today)
        let model = CultivationModel.shared(for: c)
        started = Date()
        let lines = SnapshotDigest.lines(SnapshotDigestCollector.input(context: c, today: today, summary: summary,
                                                                       goals: SnapshotDigestCollector.goalFacts(c), model: model))
        let digestMs = Double(Date().timeIntervalSince(started) * 1000)
        let snapshot = (try? String(contentsOf: CourierService.snapshotURL, encoding: .utf8)) ?? ""
        let digest = section(snapshot, "## 近况速览")
        check(snapshot.count <= SnapshotTrim.Limits().totalCap && !lines.isEmpty,
              "样例快照 \(snapshot.count) 字（≤ 4 万），速览 \(digest.split(separator: "\n").count) 行、\(digest.count) 字")
        print("  样例快照已复制到 \(out.path)；刷新耗时：第一次 \(firstMs) ms（含修为模型首次建立），第二次 \(secondMs) ms，"
              + "其中速览的取数与计算 \(String(format: "%.1f", digestMs)) ms")
    }
    #endif

    // MARK: 工具

    /// 某一节：行首是 heading（可以只写标题的开头）的那一行之后，到下一个“## ”标题之前，去掉首尾空行。
    /// 从行首找，“## 目标”不会误认成档案里的“### 目标”
    private static func section(_ text: String, _ heading: String) -> String {
        guard let start = text.range(of: "\n" + heading) else { return "" }
        let line = text[start.upperBound...]
        let rest = line[(line.firstIndex(of: "\n") ?? line.endIndex)...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return rest[..<end].trimmingCharacters(in: .newlines)
    }

    private static func snapshotContext() throws -> ModelContext {
        let context = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        DataStore.save(context)
        return context
    }
}
