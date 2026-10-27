import Foundation
import SwiftData
import CryptoKit

/// 把旧版快照写入 SwiftData。
/// 原则：
/// 1. 每一行、每个设置项先原样存档（LegacyRecord），按“类别 + ID + 更新时间”去重，旧记录更新过会另存一个版本；
/// 2. 结构化记录按 legacyID 去重，已经导入过的跳过，绝不覆盖新版里做过的修改；
///    以前导入过（旧版行已有存档）、但在新版里已经删掉的目标 / 日程 / 习惯 / 打卡 / 作息，也不再重建；
/// 3. 个人档案只补全新版中仍为空、且以前没有导入过的字段（导入后又被你清空的不会被填回）。
@MainActor
enum LegacyImporter {
    struct Report {
        var archived = 0
        var archiveSkipped = 0
        var profileFieldsFilled = 0
        var profileCreated = false
        var goals = 0
        var events = 0
        var habits = 0
        var habitLogs = 0
        var routine = 0
        var skipped = 0
        /// 以前导入过、已在新版里删掉，因此不再重建的记录数
        var deletedSkipped = 0
        var financeTransactions = 0
        var financeReports = 0
        var settingsApplied: [String] = []
        var warnings: [String] = []

        var lines: [String] {
            var out = [
                "原样存档：新增 \(archived) 条（已存在 \(archiveSkipped) 条）",
                profileCreated ? "个人档案：新建，填入 \(profileFieldsFilled) 个字段" : "个人档案：补全 \(profileFieldsFilled) 个空字段",
                "目标 \(goals)、日程 \(events)、习惯 \(habits)、打卡 \(habitLogs)、作息 \(routine)",
                "已导入过而跳过：\(skipped) 条",
            ]
            if deletedSkipped > 0 { out.append("已在新版中删除、不再重建：\(deletedSkipped) 条") }
            if financeTransactions + financeReports > 0 {
                out.append("灵石账簿：新增 \(financeTransactions) 笔交易、\(financeReports) 份月报")
            }
            if !settingsApplied.isEmpty { out.append("设置：" + settingsApplied.joined(separator: "、")) }
            out += warnings.map { "注意：" + $0 }
            return out
        }

        var hasChanges: Bool {
            archived + profileFieldsFilled + goals + events + habits + habitLogs + routine + financeTransactions + financeReports > 0
                || !settingsApplied.isEmpty
        }
    }

    /// dryRun = true 时只计算会发生什么，不写入。
    static func run(_ snapshot: LegacySnapshot, context: ModelContext, dryRun: Bool) -> Report {
        var report = Report()
        let mapped = LegacyMapper.map(snapshot)
        report.warnings = mapped.warnings
        let receipt = ImportReceipt(sourceKind: snapshot.source.rawValue, sourcePath: snapshot.path, sha256: snapshot.sha256, summary: "")

        // 1. 原样存档
        let priorArchive = context.all(LegacyRecord.self)
        var archiveKeys = Set(priorArchive.map { $0.kind + "|" + $0.legacyID + "|" + $0.legacyUpdatedAt })
        // 以前导入时建过的记录：若现在不在了，就是你在新版里删掉的，不再重建。
        let prior = PriorImport(priorArchive, source: snapshot.source)
        func archive(kind: String, id: String, json: String, created: String, updated: String) {
            let key = kind + "|" + id + "|" + updated
            guard !archiveKeys.contains(key) else { report.archiveSkipped += 1; return }
            archiveKeys.insert(key)
            report.archived += 1
            if !dryRun {
                context.insert(LegacyRecord(kind: kind, legacyID: id, json: json, createdAt: created, updatedAt: updated, receiptID: receipt.receiptID))
            }
        }
        for (kind, rows) in snapshot.collections.sorted(by: { $0.key < $1.key }) {
            for row in rows { archive(kind: kind, id: row.id, json: row.json, created: row.createdAt, updated: row.updatedAt) }
        }
        for (key, value) in snapshot.settings.sorted(by: { $0.key < $1.key }) {
            archive(kind: "settings", id: key, json: value, created: "", updated: digest(value))
        }
        for (table, items) in snapshot.extras.sorted(by: { $0.key < $1.key }) {
            for item in items { archive(kind: table, id: digest(item), json: item, created: "", updated: "") }
        }

        // 2. 个人档案
        if let legacy = mapped.profiles.first {
            let existing = context.all(Profile.self).sorted { $0.createdAt < $1.createdAt }.first
            if let profile = existing {
                // 以前导入过的档案版本里已经有值的字段：现在为空，说明是你在新版里清空的，不再填回。
                let importedFields = prior.profileFields[legacy.legacyID] ?? []
                for (key, value) in legacy.fields where !value.isEmpty && profile[key].isEmpty && !importedFields.contains(key) {
                    report.profileFieldsFilled += 1
                    if !dryRun { profile[key] = value }
                }
                if !dryRun, profile.legacyID == nil { profile.legacyID = legacy.legacyID }
            } else {
                report.profileCreated = true
                report.profileFieldsFilled = legacy.fields.values.filter { !$0.isEmpty }.count
                if !dryRun {
                    let profile = Profile(fields: legacy.fields, legacyID: legacy.legacyID)
                    profile.createdAt = legacy.createdAt ?? Date()
                    profile.updatedAt = legacy.updatedAt ?? Date()
                    context.insert(profile)
                }
            }
        }

        // 3. 目标
        let goalIDs = Set(context.all(Goal.self).compactMap(\.legacyID))
        for dto in mapped.goals {
            guard !goalIDs.contains(dto.legacyID) else { report.skipped += 1; continue }
            guard !prior.goals.contains(dto.legacyID) else { report.deletedSkipped += 1; continue }
            report.goals += 1
            guard !dryRun else { continue }
            let goal = Goal(title: dto.title)
            goal.legacyID = dto.legacyID
            goal.detail = dto.detail
            goal.category = dto.category
            goal.priority = dto.priority
            goal.status = dto.status
            goal.targetDate = dto.targetDate
            goal.progress = min(100, max(0, dto.progress))
            goal.notes = dto.notes
            goal.createdAt = dto.createdAt ?? Date()
            context.insert(goal)
        }

        // 4. 日程
        let eventIDs = Set(context.all(ScheduleEvent.self).compactMap(\.legacyID))
        for dto in mapped.events {
            guard !eventIDs.contains(dto.legacyID) else { report.skipped += 1; continue }
            guard !prior.events.contains(dto.legacyID) else { report.deletedSkipped += 1; continue }
            report.events += 1
            guard !dryRun else { continue }
            let event = ScheduleEvent(title: dto.title, dateKey: dto.dateKey)
            event.legacyID = dto.legacyID
            event.startMinute = dto.startMinute
            event.endMinute = dto.endMinute
            event.category = dto.category
            event.location = dto.location
            event.notes = dto.notes
            event.priority = dto.priority
            event.timezoneID = dto.timezoneID
            event.recurrenceKind = dto.recurrence
            event.interval = dto.interval
            event.weekdays = dto.weekdays
            event.repeatUntil = dto.repeatUntil
            event.stopBefore = dto.stopBefore
            event.excludedDates = dto.excludedDates
            event.overridesJSON = dto.overridesJSON
            event.extraJSON = dto.extraJSON
            event.createdAt = dto.createdAt ?? Date()
            context.insert(event)
        }

        // 5. 习惯与打卡
        var habitsByLegacyID: [String: Habit] = [:]
        for habit in context.all(Habit.self) { if let id = habit.legacyID { habitsByLegacyID[id] = habit } }
        var plannedHabitIDs = Set(habitsByLegacyID.keys)
        var deletedHabitIDs = Set<String>()
        for (index, dto) in mapped.habits.enumerated() {
            guard !plannedHabitIDs.contains(dto.legacyID) else { report.skipped += 1; continue }
            guard !prior.habits.contains(dto.legacyID) else {
                deletedHabitIDs.insert(dto.legacyID)
                report.deletedSkipped += 1
                continue
            }
            plannedHabitIDs.insert(dto.legacyID)
            report.habits += 1
            guard !dryRun else { continue }
            let habit = Habit(title: dto.title)
            habit.legacyID = dto.legacyID
            habit.category = dto.category
            habit.frequencyKind = dto.frequency
            habit.targetPerWeek = dto.targetPerWeek
            habit.weekdays = dto.weekdays
            habit.targetValue = dto.targetValue
            habit.unit = dto.unit
            habit.startDate = dto.startDate
            habit.archived = dto.archived
            habit.notes = dto.notes
            habit.sortOrder = index
            habit.createdAt = dto.createdAt ?? Date()
            context.insert(habit)
            habitsByLegacyID[dto.legacyID] = habit
        }
        let logIDs = Set(context.all(HabitLog.self).compactMap(\.legacyID))
        var occupied = Set(context.all(HabitLog.self).compactMap { log in log.habit?.legacyID.map { $0 + "|" + log.dateKey } })
        for dto in mapped.habitLogs {
            guard !logIDs.contains(dto.legacyID) else { report.skipped += 1; continue }
            // 整个习惯已删掉（打卡随之删除）：不再重建
            guard !deletedHabitIDs.contains(dto.habitLegacyID) else { report.deletedSkipped += 1; continue }
            guard plannedHabitIDs.contains(dto.habitLegacyID) else {
                report.warnings.append("有打卡记录找不到对应习惯（已保留在旧版存档中）")
                continue
            }
            let slot = dto.habitLegacyID + "|" + dto.dateKey
            guard !occupied.contains(slot) else { report.skipped += 1; continue }
            // 取消过的打卡：习惯还在、这一天也空着，却在以前的存档里——才算你在新版里删掉的，不再重建。
            // 必须放在“找不到习惯”“这一天已有打卡”之后：存档里有、但当时因此没建成的行，不能被误报成“已删除”。
            guard !prior.habitLogs.contains(dto.legacyID) else { report.deletedSkipped += 1; continue }
            occupied.insert(slot)
            report.habitLogs += 1
            guard !dryRun, let habit = habitsByLegacyID[dto.habitLegacyID] else { continue }
            let log = HabitLog(dateKey: dto.dateKey, completed: dto.completed, quantity: dto.quantity)
            log.legacyID = dto.legacyID
            log.durationMinutes = dto.durationMinutes
            log.notes = dto.notes
            log.habit = habit
            context.insert(log)
        }

        // 6. 作息（旧版“可安排时段”）
        let routineIDs = Set(context.all(RoutineBlock.self).compactMap(\.legacyID))
        for dto in mapped.routine {
            let id = routineID(dto)
            guard !routineIDs.contains(id) else { report.skipped += 1; continue }
            guard !prior.routine.contains(id) else { report.deletedSkipped += 1; continue }
            report.routine += 1
            guard !dryRun else { continue }
            let block = RoutineBlock(title: dto.title, kind: dto.kind, weekday: dto.weekday, startMinute: dto.startMinute, endMinute: dto.endMinute)
            block.legacyID = id
            context.insert(block)
        }

        // 7. 灵石账簿：按交易 ID 合并，已有记录（含新版里的修改）一律保留。
        if let ledgerJSON = snapshot.settings["finance_ledger_v1"] {
            do {
                let merged = try FinanceService.mergeLegacy(json: ledgerJSON, context: context, dryRun: dryRun)
                report.financeTransactions = merged.transactions
                report.financeReports = merged.reports
            } catch {
                report.warnings.append("灵石账簿未能读取（原文已存档）：\(error.localizedDescription)")
            }
        }

        // 8. 设置：只在新版仍是默认值时采用旧版设置，不覆盖你在新版中的修改。
        let settings = context.all(AppSettings.self).first
        let currentTZ = settings?.timezoneID ?? TimeZone.current.identifier
        if let tz = mapped.settings.timezoneID, tz != currentTZ, currentTZ == TimeZone.current.identifier {
            report.settingsApplied.append("时区 \(tz)")
            if !dryRun { DataStore.settings(in: context).timezoneID = tz }
        }
        if let config = mapped.settings.cultivation,
           (settings?.cultivation ?? CultivationConfig()) == CultivationConfig(), config != CultivationConfig() {
            report.settingsApplied.append("境界设置")
            if !dryRun { DataStore.settings(in: context).cultivation = config }
        }
        if let before = mapped.settings.bufferBefore, let after = mapped.settings.bufferAfter, before + after > 0,
           (settings?.bufferBeforeMinutes ?? 0) + (settings?.bufferAfterMinutes ?? 0) == 0 {
            report.settingsApplied.append("日程前后缓冲")
            if !dryRun {
                let s = DataStore.settings(in: context)
                s.bufferBeforeMinutes = before
                s.bufferAfterMinutes = after
            }
        }

        if !dryRun {
            receipt.summary = report.lines.joined(separator: "\n")
            context.insert(receipt)
            DataStore.save(context)
        }
        return report
    }

    /// 旧版“可安排时段”没有 ID，按星期与起止时间合成一个。
    nonisolated private static func routineID(_ dto: LegacyMapper.RoutineDTO) -> String {
        "planning:\(dto.weekday):\(dto.startMinute)-\(dto.endMinute)"
    }

    /// 以前各次导入时建过哪些记录：把本次之前的原样存档按同样的映射规则重新展开（存档里旧版行的每个版本都在）。
    /// 只算当时映射得出来的行——例如当时日期无效、没能建成日程的行，旧版里修好后再导入仍会照常建。
    /// 打卡映射时不看习惯在不在、那一天有没有卡，所以打卡循环里要先排除这两种情况，最后才查这里。
    private struct PriorImport {
        var goals = Set<String>()
        var events = Set<String>()
        var habits = Set<String>()
        var habitLogs = Set<String>()
        var routine = Set<String>()
        /// 档案 legacyID → 以前导入过、当时有值的字段
        var profileFields: [String: Set<String>] = [:]

        init(_ records: [LegacyRecord], source: LegacySnapshot.Source) {
            let kinds: Set<String> = ["profile", "goals", "calendar", "habits", "habit_logs"]
            var rows = LegacySnapshot(source: source, path: "", sha256: "", schemaVersion: 0)
            var planning: [String] = []
            for record in records {
                if kinds.contains(record.kind) {
                    rows.collections[record.kind, default: []].append(
                        LegacyRow(id: record.legacyID, createdAt: record.legacyCreatedAt, updatedAt: record.legacyUpdatedAt, json: record.json))
                } else if record.kind == "settings" && record.legacyID == "planning_preferences" {
                    planning.append(record.json)
                }
            }
            let mapped = LegacyMapper.map(rows)
            goals = Set(mapped.goals.map(\.legacyID))
            events = Set(mapped.events.map(\.legacyID))
            habits = Set(mapped.habits.map(\.legacyID))
            habitLogs = Set(mapped.habitLogs.map(\.legacyID))
            for profile in mapped.profiles {
                profileFields[profile.legacyID, default: []].formUnion(profile.fields.filter { !$0.value.isEmpty }.keys)
            }
            // 作息来自设置项 planning_preferences：存档里每个版本各展开一次
            for json in planning {
                let old = LegacySnapshot(source: source, path: "", sha256: "", schemaVersion: 0, settings: ["planning_preferences": json])
                routine.formUnion(LegacyMapper.map(old).routine.map(LegacyImporter.routineID))
            }
        }
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
