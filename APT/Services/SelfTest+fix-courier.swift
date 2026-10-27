import Foundation
import SwiftData

// fix-courier 的运行时自检：一封传书改了同一个目标的几项（进度、期限），撤销时按“整个目标”算——
// 用户之后只动了其中一项，“撤销（保留改过的）”整个目标都不动、计入保留；没动过就几项一起恢复；“全部撤销”也几项一起恢复。
// 撤销预览（传书笺与左栏确认框）、确认框按钮、实际结果、结果说法（传书笺、左栏提示、传书摘要）四者一致，说法都出自 CourierUndoWording。
// 隐去姓名的拆分（括号、间隔号）在 Tools/CoreCheck 里测。

extension SelfTest {
    static func fixCourierChecks(_ check: (Bool, String) -> Void) throws {
        let c = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: c)
        DataStore.profile(in: c)
        DataStore.save(c)
        typealias W = CourierUndoWording
        func deliver(_ items: [[String: Any]], _ name: String) throws -> CourierDelivery {
            let data = try JSONSerialization.data(withJSONObject: ["from": "自检", "items": items])
            return try CourierService.apply(try CourierParser.parse(data), fileName: name, context: c)
        }
        /// AI 投的更新：进度 70、期限 2026-12-31
        func update(_ goal: Goal) -> [String: Any] {
            ["type": "goal", "action": "update", "title": goal.title, "progress": 70, "target_date": "2026-12-31"]
        }
        /// 用户收录后只把进度改成 75（修改时间比收录时刻晚 10 秒）
        func userEdits(_ goal: Goal, after d: CourierDelivery) {
            goal.progress = 75
            goal.updatedAt = d.receivedAt.addingTimeInterval(10)
            DataStore.save(c)
        }
        func reset(_ goal: Goal, progress: Int, deadline: String) {
            goal.progress = progress
            goal.targetDate = deadline
            DataStore.save(c)
        }
        let thesis = Goal(title: "自检·fix 论文初稿")
        c.insert(thesis)
        reset(thesis, progress: 40, deadline: "2026-11-30")
        let effects = EffectsCenter()

        // 1. 部分改过：传书改了进度和期限，用户之后只改了进度 → 保留改过的时整个目标不动（期限也不恢复），计入保留
        let d1 = try deliver([update(thesis)], "fix-courier-partial.json")
        check(thesis.progress == 70 && thesis.targetDate == "2026-12-31" && d1.itemCount == 1, "目标更新写入：进度 70、期限 2026-12-31，两项计 1 条")
        userEdits(thesis, after: d1)
        let p1 = CourierService.undoPreviewDetail(d1, context: c)
        let plan1 = RootView.courierUndoPlan(p1)
        let panel1 = W.panelLines(p1.wording)
        check(p1.goals == 1 && p1.editedGoals == 1 && p1.total == 1
              && plan1 == "不会删除或恢复任何内容，只把这封标记为已撤销；保留你改过的 1 个目标"
              && W.buttons(p1.wording) == ("撤销（保留改过的 1 个目标）", "全部撤销（含改过的 1 个目标）")
              && panel1.contains("保留你改过的 1 个目标；选“全部撤销”则目标换回传书之前的内容（你后来改的会被覆盖）。")
              && panel1.contains("目标只要有一项是你后来改的，就整个按现在的样子保留。"),
              "部分改过的目标：预览与按钮都说保留 1 个目标、不恢复任何内容（\(plan1)）")
        let r1 = CourierService.undo(d1, context: c, refresh: false)
        effects.courierUndoResult(r1)
        check(thesis.progress == 75 && thesis.targetDate == "2026-12-31"
              && r1.failure == nil && r1.restoredGoals == 0 && r1.removed == 0 && r1.keptGoals == 1 && r1.keptEdited == 1 && d1.undone,
              "部分改过的目标，撤销（保留改过的）：进度 75 与期限 2026-12-31 都不动，计为保留 1 个目标（恢复 \(r1.restoredGoals)、保留 \(r1.keptGoals)）")
        check(effects.courier?.detail == "保留 1 项" && effects.courier?.lines == ["保留了你改过的 1 个目标"]
              && W.resultSentence(r1.wording) == "已撤销：保留了你改过的 1 个目标。"
              && d1.summary.hasSuffix("\n（撤销时保留了收录后改过的 1 个目标）"),
              "部分改过的目标：传书笺、左栏提示、传书摘要都只说保留 1 个目标，不说恢复（\(effects.courier?.lines ?? [])）")

        // 2. 没改过：几项一起恢复，说法是“恢复 1 个目标”，没有“全部撤销”按钮
        reset(thesis, progress: 40, deadline: "2026-11-30")
        let d2 = try deliver([update(thesis)], "fix-courier-clean.json")
        let p2 = CourierService.undoPreviewDetail(d2, context: c)
        check(p2.goals == 1 && p2.editedGoals == 0 && RootView.courierUndoPlan(p2) == "将恢复 1 个目标"
              && W.buttons(p2.wording) == ("撤销传书", nil) && W.panelLines(p2.wording) == ["将恢复 1 个目标（换回这封传书之前的内容）。"],
              "没改过的目标更新：预览说恢复 1 个目标，只有“撤销传书”一个按钮")
        let r2 = CourierService.undo(d2, context: c, refresh: false)
        effects.courierUndoResult(r2)
        check(thesis.progress == 40 && thesis.targetDate == "2026-11-30" && r2.restoredGoals == 1 && r2.keptGoals == 0 && r2.keptEdited == 0
              && effects.courier?.detail == "恢复 1 个目标" && effects.courier?.lines == ["已恢复 1 个目标，回到传书之前的内容"]
              && W.resultSentence(r2.wording) == "已撤销：恢复 1 个目标。" && !d2.summary.contains("撤销时保留"),
              "没改过的目标更新，撤销：进度回到 40、期限回到 2026-11-30，结果说恢复 1 个目标")

        // 3. 部分改过，选“全部撤销”：几项一起恢复（用户后来改的进度也换回去）
        let d3 = try deliver([update(thesis)], "fix-courier-all.json")
        userEdits(thesis, after: d3)
        let p3 = CourierService.undoPreviewDetail(d3, context: c)
        let r3 = CourierService.undo(d3, context: c, refresh: false, keepEdited: false)
        effects.courierUndoResult(r3)
        check(p3.editedGoals == 1 && W.buttons(p3.wording).all == "全部撤销（含改过的 1 个目标）"
              && thesis.progress == 40 && thesis.targetDate == "2026-11-30" && r3.restoredGoals == 1 && r3.keptGoals == 0 && r3.keptEdited == 0
              && effects.courier?.detail == "恢复 1 个目标" && W.resultSentence(r3.wording) == "已撤销：恢复 1 个目标。" && !d3.summary.contains("撤销时保留"),
              "部分改过的目标，全部撤销：进度、期限都回到传书之前（40、2026-11-30），结果说恢复 1 个目标")

        // 4. 同一封改了两个目标，只有一个被用户动过：动过的整个保留，另一个照常恢复；预览、按钮、结果对得上
        let reading = Goal(title: "自检·fix 读完 24 本书")
        c.insert(reading)
        reset(reading, progress: 10, deadline: "2026-12-01")
        let d4 = try deliver([update(thesis), ["type": "goal", "action": "update", "title": reading.title, "progress": 30]], "fix-courier-mixed.json")
        userEdits(thesis, after: d4)
        let p4 = CourierService.undoPreviewDetail(d4, context: c)
        let plan4 = RootView.courierUndoPlan(p4)
        let r4 = CourierService.undo(d4, context: c, refresh: false)
        effects.courierUndoResult(r4)
        check(p4.goals == 2 && p4.editedGoals == 1 && plan4 == "将恢复 1 个目标；保留你改过的 1 个目标"
              && W.buttons(p4.wording).keep == "撤销（保留改过的 1 个目标）"
              && thesis.progress == 75 && thesis.targetDate == "2026-12-31" && reading.progress == 10 && reading.targetDate == "2026-12-01"
              && r4.restoredGoals == 1 && r4.keptGoals == 1
              && effects.courier?.detail == "恢复 1 个目标 · 保留 1 项"
              && effects.courier?.lines == ["已恢复 1 个目标，回到传书之前的内容", "保留了你改过的 1 个目标"]
              && W.resultSentence(r4.wording) == "已撤销：恢复 1 个目标；保留了你改过的 1 个目标。",
              "两个目标只动过一个：动过的整个保留、没动过的恢复，预览“\(plan4)”与结果“\(effects.courier?.detail ?? "")”一致")
    }
}
