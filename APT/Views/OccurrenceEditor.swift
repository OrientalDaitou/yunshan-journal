import SwiftUI
import SwiftData

/// 重复日程“仅修改这一次”：改动写进单次改期（overridesJSON，键是这一次按规则算出的原始日期），系列的其他发生不变。
/// 只记下与系列不同的字段，没改的字段以后仍跟随整个系列。
struct OccurrenceEditor: View {
    var item: OccurrenceItem

    private struct Slot: Equatable {
        var timed: Bool
        var start: Int
        var end: Int
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var dateKey = ""
    @State private var timed = false
    @State private var start = 9 * 60
    @State private var end = 10 * 60
    @State private var location = ""
    @State private var notes = ""
    /// 打开时的时间：没动过时间就不单独记
    @State private var original = Slot(timed: false, start: 0, end: 0)
    @State private var failure: String?

    /// 展开发生时只向外多扫 62 天，单次改期最多前后挪 60 天
    private static let maxShift = 60

    private var event: ScheduleEvent { item.event }

    private var validationMessage: String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return "请填写标题" }
        if timed && end <= start { return "结束时间要晚于开始时间" }
        let day = LocalDay(key: dateKey) ?? item.day
        if abs(item.sourceDay.days(to: day)) > Self.maxShift { return "这一次最多前后挪 \(Self.maxShift) 天；更远的请另建日程" }
        return nil
    }

    var body: some View {
        EditorSheet(eyebrow: "时辰卷", title: "仅修改这一次", size: CGSize(width: 520, height: 540),
                    canSave: validationMessage == nil, problem: failure ?? validationMessage, onSave: { write(makePatch()) }) {
            Text("原定 \(item.sourceDay.longLabel)。这里的改动只影响这一次；没改的字段仍跟随整个系列。")
                .font(.ysCaption).foregroundStyle(Theme.inkSoft)
            FormSection {
                FormRow(label: "标题") { TextField("", text: $title, prompt: Text(event.title)) }
                FormRow(label: "地点") { TextField("", text: $location, prompt: Text("可不填")) }
            }
            FormSection(title: "时间") {
                FormRow(label: "日期") { DayField(label: "", key: $dateKey) }
                // 全天的系列可以给这一次定时段；有时段的系列这一次不能改成全天（单次改期表示不了）
                if event.isAllDay {
                    FormRow(label: "全天") { Toggle("全天日程", isOn: Binding(get: { !timed }, set: { timed = !$0 })) }
                }
                if timed {
                    FormRow(label: "时段") {
                        HStack(spacing: 8) {
                            MinuteField(label: "", minutes: startBinding)
                            Text("至").foregroundStyle(Theme.inkSoft)
                            MinuteField(label: "", minutes: $end, allowMidnight: true)
                        }
                    }
                }
            }
            NotesSection(text: $notes, lines: 2...5)
        } extraActions: {
            if item.isOverride {
                Button("恢复为系列设置") { write(nil) }.help("撤掉这一次的单独修改")
            }
        }
        .onAppear(perform: load)
    }

    /// 用户改开始时间时整体平移、保持原时长（load() 直接写 start，不经过这里）
    private var startBinding: Binding<Int> {
        Binding(get: { start }, set: { new in
            let duration = end - start
            start = new
            end = min(24 * 60, new + (duration > 0 ? duration : 60))
        })
    }

    private func load() {
        let patch = event.rule.overrides[item.sourceDay.key]
        title = item.title
        dateKey = item.day.key
        timed = item.startMinute != nil
        start = item.startMinute ?? 9 * 60
        end = min(24 * 60, item.endMinute ?? (start + 60))
        location = item.location
        notes = patch?.notes ?? event.notes
        original = Slot(timed: timed, start: start, end: end)
    }

    private func makePatch() -> OccurrencePatch? {
        var patch = event.rule.overrides[item.sourceDay.key] ?? OccurrencePatch()
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        patch.title = cleanTitle == event.title ? nil : cleanTitle
        patch.date = dateKey == item.sourceDay.key ? nil : dateKey
        if Slot(timed: timed, start: start, end: end) != original {
            patch.start_time = timed ? ClockTime.text(start) : nil
            patch.end_time = timed ? ClockTime.text(end) : nil
        }
        // 与系列相同的时段不必单独记
        if patch.start_time == ClockTime.text(event.startMinute), patch.end_time == ClockTime.text(event.endMinute) {
            patch.start_time = nil
            patch.end_time = nil
        }
        patch.location = location == event.location ? nil : location
        patch.notes = notes == event.notes ? nil : notes
        return patch == OccurrencePatch() ? nil : patch
    }

    private func write(_ patch: OccurrencePatch?) {
        guard OccurrenceOverrides.write(patch, for: item.sourceDay.key, on: event) else {
            failure = "这个日程原有的单次改期数据无法解析，未作修改"
            return
        }
        event.updatedAt = Date()
        DataStore.save(context)
        dismiss()
    }
}

extension OccurrenceOverrides {
    /// 写入（patch 为 nil 时删除）这个日程某一次的单次改期；原有改期数据无法解析时返回 false、不作改动
    @discardableResult
    static func write(_ patch: OccurrencePatch?, for key: String, on event: ScheduleEvent) -> Bool {
        guard let json = write(patch, for: key, into: event.overridesJSON) else { return false }
        event.overridesJSON = json
        return true
    }
}
