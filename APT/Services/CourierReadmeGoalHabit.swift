import Foundation
import SwiftData

// 给 AI 的投递说明（AI/README.md）里 goal、habit 两节，以及命令行小抄里给 `--add` 预检用的两个键。
// 表格内容实时取数：现有目标、习惯已用过的类别。解析规则在 Core/CourierGoalHabit.swift，这里只照着写说明。

@MainActor
extension CourierService {
    /// README 目标表里已完成的目标最多列这么多（按最近更新）：五年下来已完成的会越积越多，这份说明每次投递前都要读
    static let readmeCompletedGoals = 10

    /// AI README 里 goal / habit 两节（插在「## 其他」之前）。habitCategories：习惯已用过的类别（按界面顺序，可重复，这里去重）
    static func goalHabitReadme(context: ModelContext, habitCategories: [String]) -> String {
        goalHabitReadme(goals: SnapshotDigestCollector.goalFacts(context), habitCategories: habitCategories)
    }

    static func goalHabitReadme(goals: [SnapshotDigest.GoalFact], habitCategories: [String]) -> String {
        let icons = zip(HabitIcons.all, HabitIcons.labels).map { "\($0) \($1)" }.joined(separator: " · ")
        var seen = Set<String>()
        let categories = habitCategories.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(12)
        return """
        ### goal（修士名帖 · 目标：新立，或更新进度）

        新立一个目标（不写 action 即新立）：

        | 字段 | 必填 | 说明 |
        |---|---|---|
        | `title` | 是 | 目标名称（≤ \(CourierParser.goalTitleLimit) 字）。已有同名、未放弃的目标时整份拒收 |
        | `target_date` | 否 | 期限 `YYYY-MM-DD`（也认 `deadline`） |
        | `category` | 否 | 类别，尽量沿用下表已有的 |
        | `priority` | 否 | `must` 必须 · `should` 应该（默认）· `could` 可以 |
        | `progress` | 否 | 0–100 的整数，默认 0 |
        | `status` | 否 | `active` 进行中（默认）· `paused` 暂停 · `completed` 已完成 |
        | `detail` | 否 | 说明（≤ \(CourierParser.goalTextLimit) 字） |
        | `notes` | 否 | 备注 |

        更新已有目标：写 `"action": "update"`，用 `title` 找目标（先找完全相同的，再找唯一一个名字互相包含的；**写全称最稳**），只改写到的这几项：

        | 字段 | 说明 |
        |---|---|
        | `progress` | 0–100 的整数（也认 `"70%"`）。照用户说的写，不要自己估算 |
        | `status` | `active` / `paused` / `completed` / `cancelled`（已放弃）；写 completed 时进度自动记为 100 |
        | `target_date` | 新期限 `YYYY-MM-DD`；写 `"none"` 取消期限 |
        | `notes` | **追加**到目标备注末尾，自动带上日期（不替换原有备注，≤ \(CourierParser.goalTextLimit) 字） |

        至少写其中一项；update 里写的其他字段不会改，回执会提醒。找不到目标、能对上多个目标、同一封里对同一个目标写两条，都会整份拒收。
        撤销：新立的目标会被删除（收录后用户改过的默认保留）；更新会恢复成更新前的值（收录后用户又改过这个目标任一项的，整个目标默认保留）——之后又有别的传书改过同一项的，以后来的为准。

        \(goalTable(goals))

        ### habit（每日功课：新建一个习惯）

        | 字段 | 必填 | 说明 |
        |---|---|---|
        | `title` | 是 | 习惯名称（≤ \(CourierParser.habitTitleLimit) 字）。和现有习惯（含已归档的）完全同名会整份拒收 |
        | `frequency` | 否 | `daily` 每天（默认）· `weekly` 每周 N 次 · `weekdays` 指定星期；写了 times_per_week 或 weekdays 时可省略 |
        | `times_per_week` | weekly 时必填 | 每周几次，1–7 |
        | `weekdays` | weekdays 时必填 | 数组，例如 `["周一", "周三", "周五"]`（也认 `"mon"`…`"sun"`，或 1–7：1 = 周一、7 = 周日；不要写 0） |
        | `target` | 否 | 每次的数量目标（正数），例如 `30`；不写就是“打卡即完成” |
        | `unit` | 有 target 时写 | 单位，例如“分钟”“页”“公里”（≤ \(CourierParser.habitUnitLimit) 字） |
        | `start_date` | 否 | 开始日期 `YYYY-MM-DD`，默认今天；早于今天时，那之后没打卡的应做日都会算漏打 |
        | `category` | 否 | 类别，尽量沿用已有的：\(categories.isEmpty ? "（暂无）" : categories.joined(separator: "、")) |
        | `icon` | 否 | 图标：\(icons)（写中文也认；不写就按名称猜） |
        | `notes` | 否 | 备注 |

        只能新建，不能改已有习惯的设置（请用户在「每日功课」里改）。同一封里可以先建习惯、再给它打卡（checkin 写同样的名字；带数量时 unit 按这里的 unit 核对）。
        要建的习惯多半已有同类的（用户说“跑步”而已有“运动”）：先看 checkin 一节习惯表的“也能对上的说法”，对得上就直接打卡，别另建一个。
        撤销：新建的习惯会被删除；已经有打卡的（用户在应用里打的，或别的传书打的）会保留，撤销提示里会说明。
        """
    }

    /// “现有目标”表：进行中、暂停的全列（各按期限近→远，无期限的在后）；已完成的只列最近更新的 10 个；已放弃的不列，只在表头说个数
    static func goalTable(_ goals: [SnapshotDigest.GoalFact]) -> String {
        let cancelled = goals.filter { $0.status == "cancelled" }.count
        let open = SnapshotDigest.byDeadline(goals.filter { $0.status == "active" })
            + SnapshotDigest.byDeadline(goals.filter { $0.status == "paused" })
        let completed = goals.enumerated().filter { $0.element.status == "completed" }
            .sorted { $0.element.updatedDay != $1.element.updatedDay ? $0.element.updatedDay > $1.element.updatedDay : $0.offset > $1.offset }
            .map(\.element)
        // 状态写坏了（不是这四种）的也列出来，免得 AI 找不到
        let other = goals.filter { !GoalCatalog.statuses.contains($0.status) }
        let rows = open + Array(completed.prefix(readmeCompletedGoals)) + other
        let head = cancelled > 0 ? "现有目标（不含已放弃的 \(cancelled) 个；update 用全称也能找到已放弃的）：" : "现有目标："
        guard !rows.isEmpty else { return head + "（暂无目标）" }
        var lines = [head, "", "| 目标 | 状态 | 进度 | 期限 | 类别 |", "|---|---|---|---|---|"]
        lines += rows.map { g in
            "| \(cell(g.title)) | \(GoalCatalog.statusLabel(g.status)) | \(g.progress)% | \(g.targetDate?.key ?? "无") | \(cell(g.category)) |"
        }
        if completed.count > readmeCompletedGoals {
            lines.append("")
            lines.append("另有 \(completed.count - readmeCompletedGoals) 个较早完成的目标未列出，update 写全称仍能找到。")
        }
        return lines.joined(separator: "\n")
    }

    /// 表格单元格：竖线会把表拆错，换成全角
    private static func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "｜") }

    /// 命令行小抄里给 `--add` 预检用的两个键（与 CourierService.cliRoster 读的键名一致）：
    /// - `archivedHabits`：已归档的习惯名（新习惯与它们同名会被拒收）。取自修为模型已有的习惯列表，不重新取习惯；
    /// - `goals`：全部目标（含已放弃、已完成：update 的第 2、4 层要能找到已放弃的），按创建先后。
    static func rosterState(goals: [SnapshotDigest.GoalFact], model: CultivationModel) -> [String: Any] {
        ["archivedHabits": model.habits.filter { $0.archived && $0.modelContext != nil && !$0.isDeleted }.map(\.title),
         "goals": goals.map { ["title": $0.title, "status": $0.status, "progress": $0.progress] as [String: Any] }]
    }
}
