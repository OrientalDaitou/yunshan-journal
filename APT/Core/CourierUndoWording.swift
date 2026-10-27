import Foundation

/// 撤销一封飞剑传书时的说法：传书笺上的“撤销此书”（预览与结果）和修行录左栏「飞剑传书」卡的确认框、结果提示共用这一套，
/// 两处对同一个动作说的话一致（设计稿 P2 §1.4）。用词统一：
/// - 记录（日记、日程、打卡、账目、新立的目标、新建的习惯）：“删除 N 条记录”；
/// - 档案字段、目标的更新：不是删除，而是“恢复”成这封传书之前的内容——“恢复 M 个档案字段和 K 个目标”；
/// - 收录后你改过的：“保留你改过的 …”，按记录 / 档案字段 / 目标分开数，按钮与正文同一个说法；
///   目标按整个算：一封传书改了它的几项、你后来动过其中一项，这个目标就算“改过的 1 个目标”，保留时几项都不恢复；
/// - 撤销后传书摘要末尾记的“（撤销时保留了…）”也在这里（summaryNote），与结果提示同一个数法；
/// - 数为 0 的那一段不写（不出现“删除 0 条”），“删除后无法找回。”只在真有删除时出现，接在说明的最末；
///   传书笺上只有这一句用朱砂（splitWarning 把它从正文里切出来），其余是正文色；
/// - 保留原因（新建的习惯已有别的打卡、目标某项后来又被别的传书改过）接在后面：传书笺只接第一条，确认框列全（最多 3 条）。
/// 纯函数，CoreCheck 逐条核对。
enum CourierUndoWording {
    /// 撤销前的预览（由 CourierUndoPreview 换来）：各类现在还在的项数，其中几项收录后被你改过（默认保留）
    struct Plan: Equatable {
        var records = 0, editedRecords = 0
        var fields = 0, editedFields = 0
        var goals = 0, editedGoals = 0
        /// 之后又被别的（没撤销的）传书改过的档案字段：这次不动
        var superseded = 0
        var notes: [String] = []

        var edited: Int { editedRecords + editedFields + editedGoals }
    }

    /// 撤销之后的结果（由 CourierUndoReport 换来）
    struct Outcome: Equatable {
        var deleted = 0
        var restoredFields = 0, restoredGoals = 0
        var keptRecords = 0, keptFields = 0, keptGoals = 0
        var superseded = 0
        var notes: [String] = []

        var kept: Int { keptRecords + keptFields + keptGoals }
    }

    // MARK: 词组

    /// “2 条记录”“1 个档案字段”“1 个目标”按有的连起来：“2 条记录和 1 个档案字段”“2 条记录、1 个档案字段和 1 个目标”；都为 0 时为 nil
    static func items(records: Int = 0, fields: Int = 0, goals: Int = 0) -> String? {
        var parts: [String] = []
        if records > 0 { parts.append("\(records) 条记录") }
        if fields > 0 { parts.append("\(fields) 个档案字段") }
        if goals > 0 { parts.append("\(goals) 个目标") }
        switch parts.count {
        case 0: return nil
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: "、") + "和 " + parts[parts.count - 1]
        }
    }

    /// 要做的事：“删除 2 条记录，恢复 1 个档案字段和 1 个目标”；既不删也不恢复时为 nil
    static func actions(deleted: Int, fields: Int, goals: Int) -> String? {
        var parts: [String] = []
        if deleted > 0 { parts.append("删除 \(deleted) 条记录") }
        if let restore = items(fields: fields, goals: goals) { parts.append("恢复 " + restore) }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }

    // MARK: 删除的警示

    /// 真有删除时接在说明最末的一句（传书笺与左栏确认框同一句）；传书笺上只有它用朱砂
    static let deletionWarning = "删除后无法找回。"

    /// 把说明拆成正文与末尾的警示句：以 deletionWarning 结尾时切开（正文正文色、警示朱砂），否则整段都是正文。
    /// 传书笺“再点一次即撤销：…”那段用它上色
    static func splitWarning(_ text: String) -> (body: String, warning: String?) {
        guard text.hasSuffix(deletionWarning) else { return (text, nil) }
        return (String(text.dropLast(deletionWarning.count)), deletionWarning)
    }

    // MARK: 撤销前

    /// 传书笺上第一次点“撤销此书”时的说明（一段，接在“再点一次即撤销：”之后；传书笺上只有“保留改过的”这一种撤销）。
    /// 真有删除时句末加“。删除后无法找回。”（传书笺上只有这一句用朱砂）
    static func cardPreview(_ p: Plan) -> String {
        var sentences: [String] = []
        let deleted = max(0, p.records - p.editedRecords)
        let action = actions(deleted: deleted, fields: max(0, p.fields - p.editedFields), goals: max(0, p.goals - p.editedGoals))
        if let action { sentences.append("将" + action) }
        if let kept = items(records: p.editedRecords, fields: p.editedFields, goals: p.editedGoals) { sentences.append("保留你改过的 " + kept) }
        if p.superseded > 0 { sentences.append("另有 \(p.superseded) 个档案字段以之后的传书为准，不动") }
        if let note = p.notes.first { sentences.append(note) }
        if sentences.isEmpty { return "它写入的内容都已不在，只会把这封标记为已撤销" }
        if action == nil { sentences.insert("不会删除或恢复任何内容，只把这封标记为已撤销", at: 0) }
        return sentences.joined(separator: "；") + (deleted > 0 ? "。" + deletionWarning : "")
    }

    /// 修行录左栏确认框里的说明：几行短句（不含“来自…”一行和传书摘要）
    static func panelLines(_ p: Plan) -> [String] {
        var lines: [String] = []
        let deleted = max(0, p.records - p.editedRecords)
        let fields = max(0, p.fields - p.editedFields), goals = max(0, p.goals - p.editedGoals)
        if let action = actions(deleted: deleted, fields: fields, goals: goals) {
            lines.append("将" + action + (fields + goals > 0 ? "（换回这封传书之前的内容）" : "") + "。" + (deleted > 0 ? deletionWarning : ""))
        } else if p.edited > 0 || p.superseded > 0 || !p.notes.isEmpty {
            lines.append("这次撤销不会删除或恢复任何内容，只会把这封标记为已撤销。")
        } else {
            lines.append("它写入的内容都已不在，撤销只会把这封标记为已撤销。")
        }
        if let kept = items(records: p.editedRecords, fields: p.editedFields, goals: p.editedGoals) {
            var all: [String] = []
            let restorable = [p.editedFields > 0 ? "档案字段" : nil, p.editedGoals > 0 ? "目标" : nil].compactMap { $0 }
            if p.editedRecords > 0 { all.append(restorable.isEmpty ? "一并删除" : "记录一并删除") }
            if !restorable.isEmpty { all.append(restorable.joined(separator: "和") + "换回传书之前的内容（你后来改的会被覆盖）") }
            lines.append("保留你改过的 \(kept)；选“全部撤销”则\(all.joined(separator: "，"))。")
            // 目标按整个算：传书改了进度和期限、你只动过进度，保留时期限也不恢复
            if p.editedGoals > 0 { lines.append(goalKeptWhole) }
        }
        if p.superseded > 0 { lines.append("另有 \(p.superseded) 个档案字段之后又被别的传书改过，以后来的为准，这次不动。") }
        lines += p.notes.prefix(3).map { $0 + "。" }
        return lines
    }

    /// 确认框的两个按钮：没有改过的只有“撤销传书”；有改过的时按记录 / 档案字段 / 目标分开数，与正文同一个说法
    static func buttons(_ p: Plan) -> (keep: String, all: String?) {
        guard let kept = items(records: p.editedRecords, fields: p.editedFields, goals: p.editedGoals) else { return ("撤销传书", nil) }
        return ("撤销（保留改过的 \(kept)）", "全部撤销（含改过的 \(kept)）")
    }

    /// 确认框里说明“改过的目标整个保留”的一句（撤销按整个目标算，见 CourierGoalHabitStore 的 FieldGroup）
    static let goalKeptWhole = "目标只要有一项是你后来改的，就整个按现在的样子保留。"

    // MARK: 撤销后

    /// 撤销后接在传书摘要末尾的一句（修行录左栏悬停可见）：保留了哪些收录后改过的；什么都没保留时为 nil。
    /// 只保留了记录时说“N 条收录后改过的记录”，有档案字段或目标时按三类分开数（与结果提示同一个说法）
    static func summaryNote(_ o: Outcome) -> String? {
        guard o.kept > 0 else { return nil }
        guard o.keptFields + o.keptGoals > 0 else { return "（撤销时保留了 \(o.keptRecords) 条收录后改过的记录）" }
        return "（撤销时保留了收录后改过的 \(items(records: o.keptRecords, fields: o.keptFields, goals: o.keptGoals) ?? "\(o.kept) 项")）"
    }

    /// 传书笺上撤销结果的几行
    static func resultLines(_ o: Outcome) -> [String] {
        var lines: [String] = []
        if o.deleted > 0 { lines.append("已删除这封传书写入的 \(o.deleted) 条记录") }
        if let restored = items(fields: o.restoredFields, goals: o.restoredGoals) { lines.append("已恢复 \(restored)，回到传书之前的内容") }
        if let kept = items(records: o.keptRecords, fields: o.keptFields, goals: o.keptGoals) { lines.append("保留了你改过的 " + kept) }
        if o.superseded > 0 { lines.append("另有 \(o.superseded) 个档案字段以之后的传书为准，没有动") }
        if let note = o.notes.first { lines.append(note) }
        return lines.isEmpty ? ["它写入的内容都已不在，只把这封标记为已撤销"] : lines
    }

    /// 传书笺标题下的一行，一眼看完：“删除 1 条 · 恢复 2 个档案字段 · 保留 1 条”。为 0 的段省掉；
    /// 档案字段和目标都恢复了时合成“恢复 N 项”，保留的不只是记录时也说“项”（逐类的数在下面几行里）
    static func resultDetail(_ o: Outcome) -> String {
        var parts: [String] = []
        if o.deleted > 0 { parts.append("删除 \(o.deleted) 条") }
        if o.restoredFields > 0, o.restoredGoals > 0 {
            parts.append("恢复 \(o.restoredFields + o.restoredGoals) 项")
        } else if let restored = items(fields: o.restoredFields, goals: o.restoredGoals) {
            parts.append("恢复 " + restored)
        }
        if o.kept > 0 { parts.append("保留 \(o.kept) \(o.keptFields + o.keptGoals > 0 ? "项" : "条")") }
        return parts.isEmpty ? "已标记为撤销" : parts.joined(separator: " · ")
    }

    /// 修行录左栏撤销后的一句提示
    static func resultSentence(_ o: Outcome) -> String {
        var parts: [String] = []
        if let action = actions(deleted: o.deleted, fields: o.restoredFields, goals: o.restoredGoals) { parts.append(action) }
        if let kept = items(records: o.keptRecords, fields: o.keptFields, goals: o.keptGoals) { parts.append("保留了你改过的 " + kept) }
        if o.superseded > 0 { parts.append("另有 \(o.superseded) 个档案字段以之后的传书为准，没有动") }
        let head = parts.isEmpty ? "它写入的内容都已不在，只把这封标记为已撤销" : parts.joined(separator: "；")
        return "已撤销：" + head + "。" + (o.notes.first.map { $0 + "。" } ?? "")
    }
}
