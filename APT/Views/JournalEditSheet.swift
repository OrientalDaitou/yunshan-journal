import SwiftUI
import SwiftData

// MARK: - 阅读与修订

/// 修订弹窗编辑的是一份草稿副本：点“保存”才写回记录（并刷新 updatedAt），“取消”或 Esc 放弃。
/// 改了没保存的草稿另存一份到偏好设置（AppPreferences，`draft.edit.<uid>`）：弹窗被意外关掉（跨午夜页面重建、退出应用）时，
/// 下次打开同一篇会提示恢复；保存、放弃或删除后清掉。
private struct JournalEditDraft: Equatable, Codable {
    var kind: JournalKind = .diary
    var title = ""
    var body = ""
    var dateKey = ""
    var hasTime = false
    var minute = 12 * 60
    var mood: Int?
    var period = ""
    var tagsText = ""

    init() {}

    init(_ e: JournalEntry) {
        kind = e.kindValue
        title = e.title
        body = e.body
        dateKey = e.dateKey
        hasTime = e.minute != nil
        minute = e.minute ?? 12 * 60
        mood = e.mood
        period = e.period
        tagsText = e.tags.joined(separator: " ")
    }

    /// 与另一份草稿写回后的结果是否相同（只比较会写进记录的部分）
    func sameResult(as other: JournalEditDraft) -> Bool {
        kind == other.kind
            && title.trimmingCharacters(in: .whitespacesAndNewlines) == other.title.trimmingCharacters(in: .whitespacesAndNewlines)
            && body.trimmingCharacters(in: .whitespacesAndNewlines) == other.body.trimmingCharacters(in: .whitespacesAndNewlines)
            && dateKey == other.dateKey
            && (hasTime ? minute : nil) == (other.hasTime ? other.minute : nil)
            && (kind == .diary ? mood : nil) == (other.kind == .diary ? other.mood : nil)
            && (kind == .review ? period : "") == (other.kind == .review ? other.period : "")
            && TagText.parse(tagsText) == TagText.parse(other.tagsText)
    }

    // MARK: 未保存修订的备份

    private static func storeKey(_ uid: String) -> String { "draft.edit.\(uid)" }

    static func stored(uid: String) -> JournalEditDraft? {
        guard let data = AppPreferences.defaults.data(forKey: storeKey(uid)) else { return nil }
        return try? JSONDecoder().decode(JournalEditDraft.self, from: data)
    }

    static func store(_ draft: JournalEditDraft, uid: String) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        AppPreferences.defaults.set(data, forKey: storeKey(uid))
    }

    static func clearStored(uid: String) {
        AppPreferences.defaults.removeObject(forKey: storeKey(uid))
    }
}

struct JournalEditSheet: View {
    var entry: JournalEntry
    /// 从“往日回看”打开：先只读，点“修订”再进入编辑
    var startReadOnly = false
    /// 删除交给页面处理（页面底部可撤销）；为空时直接删除
    var onDelete: ((JournalEntry) -> Void)? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var draft = JournalEditDraft()
    @State private var original = JournalEditDraft()
    @State private var loaded = false
    @State private var reading = false
    @State private var isFromCourier = false
    @State private var sourceNote = ""
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    /// 这一篇的 uid（打开时记下，备份未保存的修订用）
    @State private var uid = ""
    /// 上次没保存就被关掉的修订：等用户选“恢复”或“丢弃”
    @State private var recovered: JournalEditDraft?

    init(entry: JournalEntry, startReadOnly: Bool = false, onDelete: ((JournalEntry) -> Void)? = nil) {
        self.entry = entry
        self.startReadOnly = startReadOnly
        self.onDelete = onDelete
        _reading = State(initialValue: startReadOnly)
    }

    private var isDirty: Bool { !draft.sameResult(as: original) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let saved = recovered { recoveryBanner(saved) }
            if reading { readingView } else { editingView }
        }
        .padding(24)
        .frame(width: 720)
        .yunshanSheet()
        .onAppear(perform: load)
        .onChange(of: draft) { _, value in backup(value) }
        .confirmationDialog("放弃这次修订？", isPresented: $confirmDiscard) {
            Button("放弃修改", role: .destructive, action: discard)
            Button("继续修订", role: .cancel) {}
        } message: { Text("改动还没有保存，放弃后恢复成修订前的样子。") }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        original = JournalEditDraft(entry)
        draft = original
        isFromCourier = entry.isFromCourier
        sourceNote = entry.sourceNote
        uid = entry.uid
        if let saved = JournalEditDraft.stored(uid: uid) {
            if saved.sameResult(as: original) { JournalEditDraft.clearStored(uid: uid) } else { recovered = saved }
        }
    }

    /// 改了没保存就备份一份，改回原样就清掉；提示恢复期间先不动备份，等用户选
    private func backup(_ value: JournalEditDraft) {
        guard loaded, recovered == nil, !uid.isEmpty else { return }
        if value.sameResult(as: original) {
            JournalEditDraft.clearStored(uid: uid)
        } else {
            JournalEditDraft.store(value, uid: uid)
        }
    }

    private func recoveryBanner(_ saved: JournalEditDraft) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.gold)
            Text("上次修订到一半弹窗就关了，那次的改动还没保存。")
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("恢复修订") {
                recovered = nil
                draft = saved
                reading = false
            }
            .buttonStyle(.yunshanCompact)
            Button("丢弃") {
                recovered = nil
                JournalEditDraft.clearStored(uid: uid)
            }
            .buttonStyle(.yunshanCompact)
        }
        .font(.ysCallout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.gold.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.gold.opacity(0.35)))
    }

    // MARK: 阅读

    private var readingView: some View {
        let day = LocalDay(key: draft.dateKey)
        let meta = [day?.longLabel, draft.hasTime ? ClockTime.text(draft.minute) : nil, draft.kind.label,
                    draft.kind == .diary ? draft.mood.map { "心境「\(Mood.label($0))」" } : nil,
                    draft.kind == .review && !draft.period.isEmpty ? ReviewPeriod.label(for: draft.period) : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let tags = TagText.parse(draft.tagsText)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("阅读此篇").font(.ysTitle).tracking(2).foregroundStyle(Theme.ink)
                Spacer()
                Label(draft.kind.label, systemImage: draft.kind.symbol).font(.ysCaption).foregroundStyle(draft.kind.color)
            }
            Text(meta).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
            if !draft.title.isEmpty {
                CardTitle<EmptyView>.styled(draft.title).foregroundStyle(Theme.ink).textSelection(.enabled)
            }
            ScrollView {
                Text(draft.body.isEmpty ? "（没有正文）" : draft.body)
                    .font(.ysBody)
                    .lineSpacing(4)
                    .foregroundStyle(draft.body.isEmpty ? Theme.inkSoft : Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: readingHeight)
            .background(Theme.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.line))
            if !tags.isEmpty {
                Text(tags.map { "#" + $0 }.joined(separator: "  ")).font(.ysCaption).foregroundStyle(Theme.jade)
            }
            if isFromCourier {
                Hint("此篇由 \(sourceNote) 经飞剑传书代记。", symbol: "paperplane")
            }
            HStack {
                deleteButton
                Button("复制正文") { FilePanels.copyToClipboard(draft.title.isEmpty ? draft.body : draft.title + "\n" + draft.body) }
                Spacer()
                Button { reading = false } label: { Label("修订", systemImage: "pencil") }
                Button("关闭") { dismiss() }.buttonStyle(.yunshanPrimary).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// 正文区高度：短文不留大片空白，长文最多 420 后滚动
    private var readingHeight: CGFloat {
        let lines = draft.body.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, ($1.count + 43) / 44) }
        return min(420, max(120, CGFloat(lines) * 24 + 28))
    }

    // MARK: 修订

    private var editingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("修订此篇").font(.ysTitle).tracking(2).foregroundStyle(Theme.ink)
                Spacer()
                SegmentedTabs(options: JournalKind.allCases.map { ($0, $0.label) }, selection: $draft.kind)
            }
            TextField("标题", text: $draft.title).textFieldStyle(.yunshan).font(Theme.songti(TypeSize.heading, .medium))
            PaperEditor(text: $draft.body, height: 260, accent: draft.kind.color)
            // 日期与时刻一行，心境 / 复盘周期另起一行，避免一行太宽把弹窗撑破
            HStack(spacing: 14) {
                DayField(label: "日期", key: $draft.dateKey).fixedSize()
                Toggle("时刻", isOn: $draft.hasTime)
                if draft.hasTime {
                    MinuteField(label: "", minutes: $draft.minute)
                        .labelsHidden().fixedSize()
                }
                Spacer(minLength: 0)
            }
            if draft.kind == .diary {
                HStack(spacing: 10) {
                    Text("心境").font(.ysCaption).foregroundStyle(Theme.inkSoft).fixedSize()
                    MoodPicker(mood: $draft.mood)
                }
            }
            if draft.kind == .review {
                HStack(spacing: 10) {
                    Text("周期").font(.ysCaption).foregroundStyle(Theme.inkSoft)
                    SegmentedTabs(options: [("", "不注明")] + ReviewPeriod.allCases.map { ($0.rawValue, $0.label) }, selection: $draft.period)
                }
            }
            TextField("标签（空格或逗号分隔）", text: $draft.tagsText).textFieldStyle(.yunshan)
            if isFromCourier {
                Hint("此篇由 \(sourceNote) 经飞剑传书代记；修改后仍保留来源标记，日后撤销那封传书时，你修订过的篇目会保留。", symbol: "paperplane")
            }
            HStack {
                deleteButton
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("保存", action: save).buttonStyle(.yunshanPrimary).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var deleteButton: some View {
        Button("删除", role: .destructive) { confirmDelete = true }
            .confirmationDialog("删除这条记录？", isPresented: $confirmDelete) {
                Button("删除", role: .destructive, action: performDelete)
            } message: { Text(JournalActions.deleteNotice) }
    }

    private func cancel() {
        if isDirty { confirmDiscard = true } else { close() }
    }

    private func discard() {
        draft = original
        // 还在提示恢复的那份是更早的修订，留给用户另行决定
        if recovered == nil { JournalEditDraft.clearStored(uid: uid) }
        close()
    }

    /// 从阅读进入的修订：取消 / 保存后回到阅读；否则关闭弹窗
    private func close() {
        if startReadOnly { reading = true } else { dismiss() }
    }

    private func save() {
        if isDirty {
            entry.kindValue = draft.kind
            entry.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.dateKey = draft.dateKey
            entry.minute = draft.hasTime ? draft.minute : nil
            entry.mood = draft.kind == .diary ? draft.mood : nil
            entry.period = draft.kind == .review ? draft.period : ""
            entry.tags = TagText.parse(draft.tagsText)
            entry.updatedAt = Date()
            DataStore.save(context)
            original = JournalEditDraft(entry)
        }
        draft = original
        recovered = nil
        JournalEditDraft.clearStored(uid: uid)
        close()
    }

    private func performDelete() {
        let entry = self.entry
        let onDelete = self.onDelete
        let context = self.context
        recovered = nil
        JournalEditDraft.clearStored(uid: uid)
        dismiss()
        // 等弹窗先收起再删，免得收起过程中还去读已删除的记录
        DispatchQueue.main.async {
            if let onDelete {
                onDelete(entry)
            } else {
                JournalActions.delete(entry, context: context, effects: nil)
            }
        }
    }
}
