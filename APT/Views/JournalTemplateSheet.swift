import SwiftUI

// 落笔模板的两个小弹窗（修行录落笔框“套用模板 ▾”菜单里打开）：
// “把当前正文存为模板…” → JournalTemplateSaveSheet；“管理模板…” → JournalTemplateSheet（改名、删除；内置的不能动）。
// 自存的模板在偏好设置 `templates.custom`，整理与校验都在 Core/JournalTemplates。

/// 自存模板的读写（偏好设置 `templates.custom`）
enum JournalTemplateStore {
    static func load(_ defaults: UserDefaults = AppPreferences.defaults) -> [JournalTemplate] {
        JournalTemplates.decode(defaults.string(forKey: JournalTemplates.customKey) ?? "")
    }

    static func save(_ list: [JournalTemplate], _ defaults: UserDefaults = AppPreferences.defaults) {
        defaults.set(JournalTemplates.encode(list), forKey: JournalTemplates.customKey)
    }
}

/// 存为模板：起个名字，正文原样存下（首尾空行去掉）。名称框空着时只是“保存”点不动，不先报红
struct JournalTemplateSaveSheet: View {
    /// 落笔框里此刻的正文
    var templateBody: String
    /// 存好之后（传回名称，落笔框飘一句“已存为模板”）
    var onSaved: (String) -> Void
    @AppStorage(JournalTemplates.customKey) private var customRaw = ""
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    static let size = CGSize(width: 460, height: 400)

    private var custom: [JournalTemplate] { JournalTemplates.decode(customRaw) }

    /// 底栏的说明：满了 20 套先说满了；名字写了才校验
    private var problem: String? {
        if JournalTemplates.isFull(custom) { return "已存满 \(JournalTemplates.limit) 套：先在“管理模板…”里删几套" }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return JournalTemplates.nameProblem(name, custom: custom)
    }

    var body: some View {
        EditorSheet(eyebrow: "落笔模板", title: "存为模板", size: Self.size,
                    canSave: JournalTemplates.adding(name: name, body: templateBody, to: custom) != nil,
                    problem: problem, onSave: save) {
            FormSection {
                FormRow(label: "名称") {
                    TextField("", text: $name, prompt: Text("例如：周末小结"))
                        .onChange(of: name) { _, value in
                            // 最多 12 字：多打的不收
                            if value.count > JournalTemplates.nameLimit { name = String(value.prefix(JournalTemplates.nameLimit)) }
                        }
                }
            }
            FormSection(title: "模板内容") {
                Text(JournalTemplates.cleanBody(templateBody).trimmingCharacters(in: .newlines))
                    .font(.ysCallout)
                    .lineSpacing(3)
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .textSelection(.enabled)
            }
            Hint("以后在“套用模板 ▾”里点它：正文空着直接放入，写了字就接在末尾。")
        }
    }

    private func save() {
        guard let list = JournalTemplates.adding(name: name, body: templateBody, to: custom) else { return }
        customRaw = JournalTemplates.encode(list)
        onSaved(JournalTemplates.cleanName(name))
        dismiss()
    }
}

/// 管理模板：自存的在前（可改名、删除），内置四套在后（灰字“内置”，不能改名、删除）
struct JournalTemplateSheet: View {
    @AppStorage(JournalTemplates.customKey) private var customRaw = ""
    /// 正在改名的那一套（原名）与框里的新名字
    @State private var renaming: String?
    @State private var draftName = ""
    @State private var confirmDelete: String?
    @FocusState private var nameFocused: Bool
    @State private var fade = 0.0
    @Environment(\.dismiss) private var dismiss

    static let size = CGSize(width: 520, height: 520)

    private var custom: [JournalTemplate] { JournalTemplates.decode(customRaw) }

    var body: some View {
        let custom = custom
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(eyebrow: "落笔模板", title: "管理模板").padding([.top, .horizontal], 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FormSection(title: "自存") {
                        if custom.isEmpty {
                            Text("还没有自存的模板。在落笔框里写好一段骨架，点“套用模板 ▾”里的“把当前正文存为模板…”。")
                                .font(.ysCallout)
                                .foregroundStyle(Theme.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 6)
                        }
                        ForEach(Array(custom.enumerated()), id: \.element.id) { index, template in
                            if index > 0 { rowDivider }
                            if renaming == template.name {
                                renameRow(template, custom: custom)
                            } else {
                                row(template) { customActions(template) }
                            }
                        }
                    }
                    FormSection(title: "内置") {
                        ForEach(Array(JournalTemplates.builtins.enumerated()), id: \.element.id) { index, template in
                            if index > 0 { rowDivider }
                            row(template) {
                                Text("内置").font(.ysCaption).foregroundStyle(Theme.inkSoft.opacity(0.8))
                                    .help("内置的模板不能改名、删除")
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .measuresHiddenBelow($fade)
            }
            // 与编辑弹窗一样：下面还有时底部一段纸色渐隐
            .bottomFade(fade)
            Rectangle().fill(Theme.line).frame(height: 0.5).accessibilityHidden(true)
            HStack {
                Text("自存 \(custom.count) / \(JournalTemplates.limit) 套").font(.ysCaption).foregroundStyle(Theme.inkSoft)
                Spacer()
                if renaming == nil {
                    // Esc 也是收起（隐形按钮，只为挂键）
                    Button("关闭") { dismiss() }
                        .keyCommand(.dialogCancel)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                    Button("完成") { dismiss() }
                        .buttonStyle(.yunshanPrimary)
                        .keyCommand(.dialogConfirm)
                } else {
                    // 改名框开着时回车留给“好”，这里只收 Esc
                    Button("完成") { commitRename(); dismiss() }
                        .buttonStyle(.yunshanPrimary)
                }
            }
            .padding(20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .yunshanSheet()
        .confirmationDialog(confirmDelete.map { "删除模板「\($0)」？" } ?? "", isPresented: Binding(isPresent: $confirmDelete)) {
            Button("删除", role: .destructive) {
                if let name = confirmDelete { save(JournalTemplates.removing(name, from: JournalTemplates.decode(customRaw))) }
                confirmDelete = nil
            }
            Button("取消", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("只删这套模板，已经写进修行录的不受影响。")
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 0.5).accessibilityHidden(true)
    }

    /// 一行：名称（宋体）+ 下面一行段名，右侧是“内置”或改名、删除
    private func row<Trailing: View>(_ template: JournalTemplate, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(template.name).font(Theme.songti(TypeSize.callout, .semibold)).foregroundStyle(Theme.ink)
                if !template.summary.isEmpty {
                    Text(template.summary).font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 7)
        .help(template.body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func customActions(_ template: JournalTemplate) -> some View {
        HStack(spacing: 4) {
            Button {
                draftName = template.name
                renaming = template.name
                nameFocused = true
            } label: { Label("改名", systemImage: "pencil") }
                .buttonStyle(.inlineAction())
            Button { confirmDelete = template.name } label: { Label("删除", systemImage: "trash") }
                .buttonStyle(.inlineAction())
        }
    }

    /// 改名：名称框 + “好 / 取消”；名字有问题时下面一行说明（框空着不先报红）
    private func renameRow(_ template: JournalTemplate, custom: [JournalTemplate]) -> some View {
        let problem = draftName.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : JournalTemplates.nameProblem(draftName, custom: custom, replacing: template.name)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("", text: $draftName, prompt: Text("新名字"))
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onChange(of: draftName) { _, value in
                        if value.count > JournalTemplates.nameLimit { draftName = String(value.prefix(JournalTemplates.nameLimit)) }
                    }
                Button("取消") { renaming = nil }.keyCommand(.dialogCancel)
                Button("好", action: commitRename)
                    .buttonStyle(.yunshanPrimary)
                    .keyCommand(.dialogConfirm)
                    .disabled(JournalTemplates.renaming(template.name, to: draftName, in: custom) == nil)
            }
            if let problem { Hint(problem, tone: .error, symbol: "") }
        }
        .padding(.vertical, 7)
    }

    /// 改名生效（名字有问题时不动，框留着改）；回车与“好”都走这里，第二次进来时已收起，不会重复改
    private func commitRename() {
        guard let old = renaming else { return }
        guard let list = JournalTemplates.renaming(old, to: draftName, in: JournalTemplates.decode(customRaw)) else { return }
        save(list)
        renaming = nil
    }

    private func save(_ list: [JournalTemplate]) {
        customRaw = JournalTemplates.encode(list)
    }
}
