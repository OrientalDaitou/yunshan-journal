import Foundation
import SwiftData

/// 新版完整数据导出（JSON）：全部记录（含修行录、灵石账簿、传书记录、导入记录）与旧版存档，每个模型的存储字段都导出。
/// 用于备份或以后迁移；真正的恢复用备份里的 APT.store（设置 → 数据与备份 → 从备份恢复）。
@MainActor
enum DataExporter {
    enum ExportError: LocalizedError {
        case serialization(String)
        var errorDescription: String? {
            switch self { case .serialization(let message): "导出失败：\(message)" }
        }
    }

    /// 2：补齐了各模型的 created_at / updated_at / legacy_id / sort_order、打卡当时的目标、归档日期与导入记录
    static let formatVersion = 2

    static func fullExport(context: ModelContext) throws -> Data {
        let iso = ISO8601DateFormatter()
        func t(_ date: Date) -> String { iso.string(from: date) }

        let profiles: [[String: Any]] = context.all(Profile.self).map {
            ["legacy_id": $0.legacyID ?? NSNull(), "fields": $0.fields, "created_at": t($0.createdAt), "updated_at": t($0.updatedAt)]
        }
        let goals: [[String: Any]] = context.all(Goal.self).map {
            ["legacy_id": $0.legacyID ?? NSNull(), "title": $0.title, "detail": $0.detail, "category": $0.category,
             "priority": $0.priority, "status": $0.status, "target_date": $0.targetDate ?? NSNull(),
             "progress": $0.progress, "notes": $0.notes, "created_at": t($0.createdAt), "updated_at": t($0.updatedAt)]
        }
        let events: [[String: Any]] = context.all(ScheduleEvent.self).map {
            ["legacy_id": $0.legacyID ?? NSNull(), "title": $0.title, "date": $0.dateKey,
             "start_time": $0.startMinute.map { ClockTime.text($0) } ?? NSNull(),
             "end_time": $0.endMinute.map { ClockTime.text($0) } ?? NSNull(),
             "category": $0.category, "location": $0.location, "notes": $0.notes, "priority": $0.priority,
             "timezone": $0.timezoneID, "recurrence": $0.recurrence, "interval": $0.interval, "weekdays": $0.weekdays,
             "repeat_until": $0.repeatUntil ?? NSNull(), "stop_before": $0.stopBefore ?? NSNull(),
             "excluded_dates": $0.excludedDates, "occurrence_overrides_json": $0.overridesJSON, "extra_json": $0.extraJSON,
             "created_at": t($0.createdAt), "updated_at": t($0.updatedAt)]
        }
        let routine: [[String: Any]] = context.all(RoutineBlock.self).map {
            ["legacy_id": $0.legacyID ?? NSNull(), "title": $0.title, "kind": $0.kind, "weekday": $0.weekday,
             "start_time": ClockTime.text($0.startMinute), "end_time": ClockTime.text($0.endMinute), "note": $0.note,
             "created_at": t($0.createdAt)]
        }
        let habits: [[String: Any]] = context.all(Habit.self).sorted { $0.sortOrder < $1.sortOrder }.map { habit in
            ["legacy_id": habit.legacyID ?? NSNull(), "title": habit.title, "category": habit.category, "symbol": habit.symbol,
             "frequency": habit.frequency, "target_per_week": habit.targetPerWeek, "weekdays": habit.weekdays,
             "target_value": habit.targetValue ?? NSNull(), "unit": habit.unit, "start_date": habit.startDate,
             "archived": habit.archived, "archived_at": habit.archivedAt ?? NSNull(), "notes": habit.notes,
             "sort_order": habit.sortOrder, "created_at": t(habit.createdAt), "updated_at": t(habit.updatedAt),
             "logs": (habit.logs ?? []).sorted { $0.dateKey < $1.dateKey }.map { log -> [String: Any] in
                 ["legacy_id": log.legacyID ?? NSNull(), "date": log.dateKey, "completed": log.completed,
                  "quantity": log.quantity ?? NSNull(), "target_at_log": log.targetAtLog ?? NSNull(),
                  "duration_minutes": log.durationMinutes ?? NSNull(), "notes": log.notes,
                  "created_at": t(log.createdAt), "updated_at": t(log.updatedAt)]
             }]
        }
        let advice: [[String: Any]] = context.all(AdviceRecord.self).map {
            ["created_at": t($0.createdAt), "title": $0.title, "summary": $0.summary, "response": $0.response,
             "source": $0.source, "decision": $0.decision]
        }
        let legacy: [[String: Any]] = context.all(LegacyRecord.self).map {
            ["kind": $0.kind, "legacy_id": $0.legacyID, "json": $0.json,
             "legacy_created_at": $0.legacyCreatedAt, "legacy_updated_at": $0.legacyUpdatedAt,
             "imported_at": t($0.importedAt), "receipt_id": $0.receiptID]
        }
        let receipts: [[String: Any]] = context.all(ImportReceipt.self).sorted { $0.importedAt < $1.importedAt }.map {
            ["receipt_id": $0.receiptID, "imported_at": t($0.importedAt), "source_kind": $0.sourceKind,
             "source_path": $0.sourcePath, "sha256": $0.sha256, "summary": $0.summary]
        }
        let journal: [[String: Any]] = context.all(JournalEntry.self).sorted { $0.createdAt < $1.createdAt }.map {
            ["uid": $0.uid, "kind": $0.kind, "title": $0.title, "body": $0.body, "date": $0.dateKey,
             "time": $0.minute.map { ClockTime.text($0) } ?? NSNull(), "mood": $0.mood ?? NSNull(), "period": $0.period,
             "tags": $0.tags, "source": $0.source, "source_note": $0.sourceNote, "delivery_id": $0.deliveryID,
             "pinned": $0.pinned, "created_at": t($0.createdAt), "updated_at": t($0.updatedAt)]
        }
        let deliveries: [[String: Any]] = context.all(CourierDelivery.self).sorted { $0.receivedAt < $1.receivedAt }.map {
            ["delivery_id": $0.deliveryID, "received_at": t($0.receivedAt), "file_name": $0.fileName, "from": $0.from,
             "note": $0.note, "summary": $0.summary, "refs_json": $0.refsJSON, "item_count": $0.itemCount, "undone": $0.undone]
        }
        // 灵石账簿按旧版同格式原样嵌入（解析失败时退回原始文本，绝不丢）
        var ledger: Any = NSNull()
        var ledgerUpdatedAt: Any = NSNull()
        if let store = FinanceService.store(context), !store.data.isEmpty {
            ledger = (try? JSONSerialization.jsonObject(with: store.data)) ?? (String(data: store.data, encoding: .utf8) ?? store.data.base64EncodedString())
            ledgerUpdatedAt = t(store.updatedAt)
        }
        var settings: [String: Any] = [:]
        if let s = context.all(AppSettings.self).first {
            settings = ["timezone": s.timezoneID, "realms": s.realms, "thresholds": s.thresholds, "daily_cap": s.dailyCap,
                        "cultivation_enabled": s.cultivationEnabled, "motion_enabled": s.motionEnabled,
                        "buffer_before_minutes": s.bufferBeforeMinutes, "buffer_after_minutes": s.bufferAfterMinutes,
                        "ai_preamble": s.aiPreamble, "ai_provider": s.aiProvider, "created_at": t(s.createdAt)]
        }
        let root: [String: Any] = [
            "app": "APT-SwiftUI", "format_version": formatVersion, "exported_at": t(Date()),
            "profile": profiles, "goals": goals, "schedule_events": events, "routine_blocks": routine,
            "habits": habits, "advice": advice, "settings": settings, "legacy_archive": legacy,
            "import_receipts": receipts, "journal": journal, "finance_ledger": ledger,
            "finance_ledger_updated_at": ledgerUpdatedAt, "courier_deliveries": deliveries,
        ]
        // 无穷大 / NaN 不是合法 JSON：JSONSerialization 遇到会抛 Objective-C 异常直接让应用崩溃（do/catch 接不住），
        // 所以先统一换成 null，再用 isValidJSONObject 把关。
        let clean = sanitized(root)
        guard JSONSerialization.isValidJSONObject(clean) else {
            throw ExportError.serialization("数据里有无法写成 JSON 的值")
        }
        do {
            return try JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw ExportError.serialization(error.localizedDescription)
        }
    }

    /// 递归把非有限的数（inf、-inf、NaN）换成 null；以后新增的字段也一并受保护。
    static func sanitized(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { sanitized($0) }
        case let array as [Any]:
            return array.map { sanitized($0) }
        case let number as NSNumber:
            // Swift 的 Int / Double / Bool 都会桥接成 NSNumber；Bool（以及账簿 JSON 里的 true/false）原样保留
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number }
            return number.doubleValue.isFinite ? number : NSNull()
        default:
            return value
        }
    }
}
