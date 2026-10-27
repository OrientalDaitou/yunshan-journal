import SwiftUI
import SwiftData

struct ProfileView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]
    @Query(sort: \Goal.createdAt) private var goals: [Goal]
    @Environment(EffectsCenter.self) private var effects
    @Environment(\.spiritMotion) private var motion
    @State private var editingGoal: Goal?
    @State private var creatingGoal = false
    /// 已完成、暂停、已放弃的目标收在“已完成 · 2 项”里，默认收起
    @State private var showFolded = false
    /// 这次在页上、从进行中那一列刚功成的目标：照旧留在那一列（原位不动），金光掠过时看得见；下次进页才收进折叠区
    @State private var justDone: Set<PersistentIdentifier> = []
    /// 这次在折叠区里刚功成的目标（暂停、已放弃改成已完成）→ 改之前的状态：留在折叠区原位（按原来的状态排），不跳到上面那一列
    @State private var foldedPlace: [PersistentIdentifier: String] = [:]
    /// 正掠过金光的那一行
    @State private var sweeping: PersistentIdentifier?
    /// 右键菜单里“删除”的目标（先确认）
    @State private var pendingDeleteGoal: Goal?
    /// 点了“＋ 补写”展开的空字段，以及编辑过的字段：在这页上写空了也不会立刻收回成小签
    @State private var expanded: Set<String> = []
    /// 正在写、还没写回名帖的字段（键 → 内容）。打字只改这里，不碰数据模型：
    /// 以前每敲一个字都改名帖，侧栏境界卡等挂着 @Query 的视图都要跟着重算一遍。停笔约 1 秒、切页、切走应用、退出前写回并保存
    @State private var drafts: [String: String] = [:]
    @FocusState private var focusedKey: String?

    /// 并进“目标”卡、作为“方向”小节的那一组（key 不变，旧版导入照常）
    private static let directionsSection = "目标"

    var body: some View {
        PageScaffold(page: .profile) {
            if let profile = profiles.first {
                // 最上面一张印谱（八枚里程碑，见 SealBook）
                SealBook().ysEntrance(order: 0)
                // 可追踪进度的目标排在印谱之后，并和“目标”组的 6 个方向合成一张卡
                goalsCard(profile).ysEntrance(order: 1)
                ForEach(Array(ProfileCatalog.sections.filter { $0.title != Self.directionsSection }.enumerated()), id: \.element.id) { index, section in
                    sectionCard(section, profile: profile).ysEntrance(order: index + 2)
                }
                let extras = fields(profile).keys.filter { !ProfileCatalog.knownKeys.contains($0) }.sorted()
                if !extras.isEmpty { extraCard(extras, profile: profile) }
            } else {
                // 名帖还没建好（第一次打开）：建好后自动换成正文
                ProgressView().onAppear {
                    DataStore.profile(in: context)
                    DataStore.save(context)
                }
            }
        }
        .sheet(item: $editingGoal) { goal in GoalEditor(goal: goal, onAchieved: { achieved($0, before: $1) }) }
        .sheet(isPresented: $creatingGoal) { GoalEditor(goal: nil, onAchieved: { achieved($0, before: $1) }) }
        .confirmationDialog("删除这个目标？", isPresented: Binding(isPresent: $pendingDeleteGoal), presenting: pendingDeleteGoal) { goal in
            Button("删除", role: .destructive) {
                context.delete(goal)
                DataStore.save(context)
                pendingDeleteGoal = nil
            }
        } message: { _ in
            Text("删除后无法恢复。也可以在编辑里把状态改成“已放弃”来保留记录。")
        }
        // 正在写的字段记进 expanded：写空了也留在原处，不会一下收回成小签、丢了光标
        .onChange(of: focusedKey) { _, key in
            if let key { expanded.insert(key) }
        }
        // 名帖随写随存：停笔约 1 秒后写回名帖并落盘
        .task(id: drafts) {
            guard !drafts.isEmpty else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            commitDrafts()
        }
        // 切页、关窗时写回；切走应用、退出前也写回（这两个通知在主线程上同步发出，退出前来得及存）
        .onDisappear(perform: commitDrafts)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            if !drafts.isEmpty { commitDrafts() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            if !drafts.isEmpty { commitDrafts() }
        }
    }

    /// 把草稿写回名帖并保存（没有草稿时只保存，与原来切页时一样）
    private func commitDrafts() {
        if !drafts.isEmpty, let profile = profiles.first {
            for (key, value) in drafts { profile[key] = value }
            drafts = [:]
        }
        DataStore.save(context)
    }

    /// 名帖当前的全部字段（草稿盖在已存的内容上）：完整度、铺开哪些字段都按它算，打字时和以前一样即时变化
    private func fields(_ profile: Profile) -> [String: String] {
        drafts.isEmpty ? profile.fields : profile.fields.merging(drafts) { _, draft in draft }
    }

    /// 档案完整度：放在第一组字段（基本信息）的标题行右侧——横幅里只留文字，数据不进横幅
    private func completeness(_ profile: Profile) -> some View {
        let value = ProfileCatalog.completeness(fields(profile))
        let missing = ProfileCatalog.allFields.filter { !isFilled(profile, $0.key) }.count
        let stage = value >= 0.8 ? "道基稳固" : value >= 0.4 ? "初具轮廓" : "尚待补全"
        return HStack(spacing: 8) {
            Text(missing == 0 ? "\(stage) · 已全部写下" : "\(stage) · 还有 \(missing) 项未填")
                .font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
            ZStack {
                Circle().stroke(Theme.line, lineWidth: 3)
                Circle().trim(from: 0, to: value).stroke(Theme.gold, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
            Text(value.percentText).font(Theme.figure(TypeSize.callout, .semibold)).foregroundStyle(Theme.ink)
        }
        .help("档案完整度")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("档案完整度 \(value.percentText)，\(missing == 0 ? "已全部写下" : "还有 \(missing) 项未填")")
    }

    /// 输入框读草稿（没有就读名帖），写只进草稿
    private func binding(_ profile: Profile, _ key: String) -> Binding<String> {
        Binding(get: { drafts[key] ?? profile[key] }, set: { drafts[key] = $0 })
    }

    private func isFilled(_ profile: Profile, _ key: String) -> Bool {
        !(drafts[key] ?? profile[key]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 铺开显示：写过的，或这次在页上点开 / 编辑过的
    private func isShown(_ profile: Profile, _ key: String) -> Bool {
        isFilled(profile, key) || expanded.contains(key)
    }

    // MARK: 字段

    private func sectionCard(_ section: ProfileSection, profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: section.title, hint: section.subtitle) {
                // 完整度挂在第一组（基本信息）的标题行
                if section.id == ProfileCatalog.sections.first(where: { $0.title != Self.directionsSection })?.id {
                    completeness(profile)
                }
            }
            fieldsBlock(section.fields, profile: profile)
        }
        .xianCard()
    }

    /// 一组字段：只铺陈已经写下的（和刚点开补写的）；空的收成卡底一行“＋ 补写”小签，点哪个展开哪个并把光标放进去。
    /// 每个字段都是“标签在上、输入框在下”的同一种格子（“希望被称呼为”紧跟在昵称后面），两栏对齐
    @ViewBuilder
    private func fieldsBlock(_ fields: [ProfileField], profile: Profile) -> some View {
        let shown = fields.filter { isShown(profile, $0.key) }
        let empty = fields.filter { !isShown(profile, $0.key) }
        let single = Self.nicknameFirst(shown.filter { !$0.multiline })
        let multi = shown.filter(\.multiline)
        if !single.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .topLeading), GridItem(.flexible(), spacing: 16, alignment: .topLeading)],
                      alignment: .leading, spacing: 12) {
                ForEach(single) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.label).font(.ysCaption).foregroundStyle(Theme.inkSoft)
                        input(field, profile: profile, prompt: field.key == "preferred_name" ? "留空即用昵称" : nil)
                        if field.key == "timezone" {
                            Hint("仅供 AI 摘要参考，日程以设置里的时区为准")
                        }
                    }
                }
            }
        }
        ForEach(multi) { field in
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label).font(.ysCaption).foregroundStyle(Theme.inkSoft)
                input(field, profile: profile)
            }
        }
        if !empty.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(empty) { field in addChip(field.label, key: field.key) }
            }
            .padding(.top, shown.isEmpty ? 0 : 4)
        }
    }

    /// “希望被称呼为”紧挨着昵称（字段表里它在姓名后面；key 与字段表不改，只在显示时调一下次序）
    private static func nicknameFirst(_ fields: [ProfileField]) -> [ProfileField] {
        var fields = fields
        if let p = fields.firstIndex(where: { $0.key == "preferred_name" }), let n = fields.firstIndex(where: { $0.key == "nickname" }), p > n + 1 {
            fields.insert(fields.remove(at: p), at: n + 1)
        }
        return fields
    }

    /// 输入框：外观同 YunshanFieldStyle，但焦点由页面自己控制（点开补写时把光标放进去），所以不叠用那个样式
    private func input(_ field: ProfileField, profile: Profile, prompt: String? = nil) -> some View {
        let focused = focusedKey == field.key
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        let hint = prompt ?? field.placeholder
        let promptText = hint.isEmpty ? nil : Text(hint)
        return Group {
            if field.multiline {
                TextField("", text: binding(profile, field.key), prompt: promptText, axis: .vertical).lineLimit(1...6)
            } else {
                TextField("", text: binding(profile, field.key), prompt: promptText)
            }
        }
        .textFieldStyle(.plain)
        .focused($focusedKey, equals: field.key)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.paper.opacity(0.6), in: shape)
        .overlay(shape.strokeBorder(focused ? Theme.gold.opacity(0.6) : Theme.line, lineWidth: focused ? 1.3 : 1))
        .accessibilityLabel(field.label)
    }

    /// “＋ 重要项目”小签：点开补写
    private func addChip(_ label: String, key: String) -> some View {
        Button {
            expanded.insert(key)
            // 等输入框出现后再把光标放进去
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                focusedKey = key
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                Text(label)
            }
            .font(.ysCaption)
            .foregroundStyle(Theme.inkSoft)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.mist.opacity(0.7), in: Capsule())
            .yunshanTile(cornerRadius: Radius.pill)
        }
        .buttonStyle(.plain)
        .help("补写\(label)")
        .accessibilityLabel("补写\(label)")
    }

    private func extraCard(_ keys: [String], profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "其他字段", hint: "从旧版导入、新版暂无专门位置的字段")
            ForEach(keys, id: \.self) { key in
                VStack(alignment: .leading, spacing: 4) {
                    // 字段名是机器信息，保留等宽
                    Text(key).font(.ysCaption.monospaced()).foregroundStyle(Theme.inkSoft)
                    TextField(key, text: binding(profile, key), axis: .vertical).lineLimit(1...4).textFieldStyle(.yunshan)
                }
            }
        }
        .xianCard()
    }

    // MARK: 目标

    /// 目标卡（玉简主卡）：上面是可追踪进度的具体目标，下面“方向”小节是 6 个长远方向
    private func goalsCard(_ profile: Profile) -> some View {
        // 进行中的按创建先后排在上面；已完成 → 暂停 → 已放弃收进折叠区（M5）。以状态为准（GoalListRules）；
        // 这次刚功成的留在原处：原在进行中那一列的这次照旧在那一列，原在折叠区的照旧在折叠区原位
        let parts = GoalListRules.partition(goals.map { (id: $0.persistentModelID, status: $0.status) }, keepShown: justDone, foldedPlace: foldedPlace)
        let shown = parts.shown.map { goals[$0] }
        let folded = parts.folded.map { goals[$0] }
        let activeCount = goals.filter { $0.status == "active" }.count
        let directions = ProfileCatalog.sections.first { $0.title == Self.directionsSection }
        return VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "目标", detail: activeCount > 0 ? "\(activeCount) 项进行中" : "",
                      hint: "上面是可追踪进度的目标；下面的“方向”写长远的道心所向") {
                Button { creatingGoal = true } label: { Label("新立目标", systemImage: "plus") }
                    .buttonStyle(.yunshanCompact)
                    .keyCommand(.newGoal)
                    .help(KeyCommand.newGoal.help("新立目标"))
            }
            if goals.isEmpty {
                EmptyHint(.noGoals)
            } else if shown.isEmpty {
                EmptyHint(.noActiveGoals)
            }
            // 整行可点编辑；右键有“编辑 / 删除”
            if !shown.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, goal in
                        goalRow(goal, dividerAbove: index > 0, inFold: false)
                    }
                }
            }
            if !folded.isEmpty {
                DisclosureGroup(isExpanded: $showFolded) {
                    VStack(spacing: 0) {
                        ForEach(Array(folded.enumerated()), id: \.element.id) { index, goal in
                            goalRow(goal, dividerAbove: index > 0, inFold: true)
                        }
                    }
                } label: {
                    Text(GoalListRules.foldedLabel(statuses: folded.map(\.status))).font(.ysCaption).foregroundStyle(Theme.inkSoft)
                }
            }
            if let directions {
                SectionLabel(text: "方向").padding(.top, 4)
                    .help(directions.subtitle)
                fieldsBlock(directions.fields, profile: profile)
            }
        }
        .xianCard(tier: .jade)
    }

    /// 一行目标（M5）：标题在前、“必须”的朱砂小点跟在标题后（有无小点标题都左对齐）；
    /// 进度条占满剩下的宽度，百分比 / 期限 / 类别是右侧三列定宽，各行上下对齐。
    /// 收进折叠区的（已完成、暂停、已放弃）进度条改淡墨细条，不再是全卡最醒目的满格金条
    private func goalRow(_ goal: Goal, dividerAbove: Bool, inFold: Bool) -> some View {
        let isCancelled = goal.status == "cancelled"
        let id = goal.persistentModelID
        // 折叠区里的画淡墨细条；这次从进行中那一列刚功成、还留在那一列的照旧画满格金条
        let quiet = inFold
        let today = LocalDay.today()
        return EditableRow(dividerAbove: dividerAbove, onDelete: { pendingDeleteGoal = goal }, action: { editingGoal = goal }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(goal.title).font(.ysBody.weight(.medium)).foregroundStyle(isCancelled ? Theme.inkSoft : Theme.ink)
                        .strikethrough(isCancelled)
                        .lineLimit(1)
                    // 优先级只在“必须”时点一个朱砂小点
                    if goal.priority == EventPriority.must.rawValue {
                        Circle().fill(Theme.warning).frame(width: 6, height: 6)
                            .help("优先级：\(goal.priorityLabel)")
                            .accessibilityLabel("优先级\(goal.priorityLabel)")
                    }
                    // “进行中”是默认状态，不挂签；暂停、完成、放弃才标出
                    if goal.status != "active" {
                        Chip(text: goal.statusLabel, color: goal.status == "completed" ? Theme.positive : Theme.inkSoft)
                    }
                }
                HStack(spacing: 12) {
                    if quiet {
                        ProgressBar(value: Double(goal.progress) / 100, color: Theme.inkSoft.opacity(0.45), height: 4, solid: true)
                            .frame(maxWidth: .infinity)
                    } else {
                        ProgressBar(value: Double(goal.progress) / 100, height: 6).frame(maxWidth: .infinity)
                    }
                    Text("\(goal.progress)%").font(Theme.figure(TypeSize.callout, .medium)).foregroundStyle(quiet ? Theme.inkSoft : Theme.ink)
                        .frame(width: 44, alignment: .trailing)
                    Group {
                        if let key = goal.targetDate, let text = GoalListRules.deadlineText(key, today: today), let date = LocalDay(key: key) {
                            Text(text).foregroundStyle(date < today && goal.status == "active" ? Theme.warning : Theme.inkSoft)
                        } else {
                            Text(verbatim: "")
                        }
                    }
                    .font(.ysCaption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
                    .frame(width: 128, alignment: .leading)
                    Text(goal.category).font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(1)
                        .frame(width: 72, alignment: .leading)
                }
            }
        }
        // 刚功成：金光自左向右掠过这一行，“功成”朱印落在右侧（关动效时不放，只飘字）
        .overlay {
            if sweeping == id {
                GoalAchievedSweep { rect in
                    effects.stamp("功成", at: CGRect(x: rect.maxX - 150, y: rect.minY, width: 44, height: rect.height))
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// 编辑弹窗里保存后“刚功成”（状态改成已完成；拉到 100% 时状态会自动跟着改）：这一行留在原处，等弹窗收起后
    /// 掠过一道金光、盖一方“功成”朱印，并飘“所向功成 · 目标名”（关动效只飘字）。
    /// before 是保存前库里的状态：原在进行中那一列的这次照旧留在那一列；原在折叠区的（暂停、已放弃）留在折叠区原位、
    /// 折叠区展开着好让金光看得见；新建时就是已完成的也放进折叠区并展开
    private func achieved(_ goal: Goal, before: String?) {
        let id = goal.persistentModelID
        let title = goal.title
        // 同一行这次进页里来回改过几回的，以最近这一次功成时它在哪一列为准
        if before == "active" {
            justDone.insert(id)
            foldedPlace[id] = nil
        } else {
            justDone.remove(id)
            if let before { foldedPlace[id] = before }
            showFolded = true
        }
        Task { @MainActor in
            // 等弹窗收起（最多约 2 秒），金光和朱印才不会被弹窗挡住
            var waited = 0.0
            repeat {
                try? await Task.sleep(nanoseconds: 250_000_000)
                waited += 0.25
            } while NSApp.windows.contains(where: { $0.isVisible && $0.attachedSheet != nil }) && waited < 2
            effects.goalAchieved(title)
            guard motion else { return }
            sweeping = id
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if sweeping == id { sweeping = nil }
        }
    }
}

/// 刚功成的那一行：一道金光自左向右掠过（约 1.1 秒），描边亮一下再淡去。出现时把这一行在窗口里的位置交给 onStart（落“功成”印）
private struct GoalAchievedSweep: View {
    var onStart: (CGRect) -> Void
    @State private var progress = -0.35
    @State private var edge = 0.0

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            ZStack {
                LinearGradient(colors: [Theme.gold.opacity(0), Theme.gold.opacity(0.42), Color.white.opacity(0.35), Theme.gold.opacity(0.42), Theme.gold.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(80, width * 0.32))
                    .offset(x: width * progress - width * 0.16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                shape.strokeBorder(Theme.gold.opacity(0.7 * edge), lineWidth: 1.2)
                shape.fill(Theme.gold.opacity(0.08 * edge))
            }
            .clipShape(shape)
            .onAppear {
                onStart(proxy.frame(in: .global))
                withAnimation(.easeInOut(duration: 1.1)) { progress = 1.35 }
                withAnimation(.easeOut(duration: 0.3)) { edge = 1 }
                withAnimation(.easeIn(duration: 0.8).delay(0.9)) { edge = 0 }
            }
        }
    }
}

struct GoalEditor: View {
    var goal: Goal?
    /// 这次保存让目标“刚功成”（状态改成已完成；完成度拉到 100% 时状态自动跟着改）时调用，第二个参数是保存前库里的状态
    /// （新建为 nil）：名帖那一行放金光、飘“所向功成”，并按原来在哪一列决定留在哪里
    var onAchieved: ((Goal, String?) -> Void)? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var detail = ""
    @State private var category = ""
    @State private var priority = "should"
    @State private var status = "active"
    @State private var hasDeadline = false
    @State private var deadline = LocalDay.today().adding(days: 30).key
    @State private var progress = 0.0
    @State private var notes = ""
    @State private var confirmDelete = false
    /// 点“已完成”把完成度补到 100 之前的数：再改回别的状态时还原（GoalEditorLink）
    @State private var progressBeforeDone: Int?
    /// 打开时的原值：保存时只写回改过的字段。弹窗开着时飞剑传书可能更新了这个目标（进度、状态、期限、备注），
    /// 没动过的字段不能用打开时的旧值把它盖掉
    @State private var original: Values?

    private struct Values: Equatable {
        var title, detail, category, priority, status: String
        var targetDate: String?
        var progress: Int
        var notes: String
    }

    private var edited: Values {
        Values(title: title.trimmingCharacters(in: .whitespaces), detail: detail, category: category, priority: priority, status: status,
               targetDate: hasDeadline ? deadline : nil, progress: Int(progress), notes: notes)
    }

    var body: some View {
        // 高 560 → 620：备注一节不再被按钮栏切在一半（1180×780 的窗口里放得下）
        EditorSheet(eyebrow: "修士名帖", title: goal == nil ? "新建目标" : "编辑目标", size: CGSize(width: 480, height: 620),
                    canSave: !title.trimmingCharacters(in: .whitespaces).isEmpty, onSave: save,
                    onDelete: goal == nil ? nil : { confirmDelete = true }) {
            FormSection {
                FormRow(label: "目标") { TextField("", text: $title, prompt: Text("例如：完成毕业论文初稿")) }
                FormRow(label: "说明", top: true) { TextField("", text: $detail, prompt: Text("可不填"), axis: .vertical).lineLimit(2...4) }
                FormRow(label: "类别") { TextField("", text: $category, prompt: Text("学业 / 职业 / 健康…")) }
            }
            FormSection(title: "进度") {
                FormRow(label: "优先级") {
                    ChipPicker(selection: $priority, options: EventPriority.allCases.map { ($0.rawValue, $0.label) })
                }
                FormRow(label: "状态") {
                    ChipPicker(selection: Binding(get: { status }, set: { value in link { $0.pick(value) } }),
                               options: ["active", "paused", "completed", "cancelled"].map { ($0, Goal.statusLabels[$0] ?? $0) })
                }
                FormRow(label: "期限") {
                    HStack(spacing: 10) {
                        Toggle("设定期限", isOn: $hasDeadline)
                        if hasDeadline { DayField(label: "", key: $deadline) }
                    }
                }
                FormRow(label: "完成度") {
                    HStack {
                        // 拉到 100% 时状态跟着改成“已完成”，从 100% 拉回去又改回“进行中”（暂停、已放弃不动）；改完仍可再点状态改回
                        Slider(value: Binding(get: { progress }, set: { value in link { $0.slide(to: Int(value.rounded())) } }), in: 0...100, step: 5)
                        Text("\(Int(progress))%").font(Theme.figure(TypeSize.body, .semibold)).foregroundStyle(Theme.ink).frame(width: 48)
                    }
                }
            }
            NotesSection(text: $notes, lines: 2...4)
        }
        .onAppear(perform: load)
        .confirmationDialog("删除这个目标？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                if let goal { context.delete(goal) }
                DataStore.save(context)
                dismiss()
            }
        } message: { Text("删除后无法恢复。也可以把状态改成“已放弃”来保留记录。") }
    }

    /// 完成度与状态一起改（只在用户拖滑块、点状态时调用；打开时载入原值不经过这里，不会把传书写的“进行中 100%”悄悄改掉）
    private func link(_ change: (inout GoalEditorLink) -> Void) {
        var value = GoalEditorLink(status: status, progress: Int(progress.rounded()), progressBeforeDone: progressBeforeDone)
        change(&value)
        status = value.status
        progress = Double(value.progress)
        progressBeforeDone = value.progressBeforeDone
    }

    private func load() {
        guard let goal else { return }
        title = goal.title
        detail = goal.detail
        category = goal.category
        priority = goal.priority
        status = goal.status
        hasDeadline = goal.targetDate != nil
        deadline = goal.targetDate ?? deadline
        progress = Double(goal.progress)
        notes = goal.notes
        original = edited
    }

    private func save() {
        // 保存前的状态取库里现在的（弹窗开着时传书可能已经改过），不取打开时的旧值
        let before = goal?.status
        let target = goal ?? Goal(title: title)
        if goal == nil { context.insert(target) }
        let new = edited
        // 新建时 original 为空，全部写入；编辑时只写回与打开时不同的字段
        let old = original
        if new.title != old?.title { target.title = new.title }
        if new.detail != old?.detail { target.detail = new.detail }
        if new.category != old?.category { target.category = new.category }
        if new.priority != old?.priority { target.priority = new.priority }
        if new.status != old?.status { target.status = new.status }
        if old == nil || new.targetDate != old?.targetDate { target.targetDate = new.targetDate }
        if new.progress != old?.progress { target.progress = new.progress }
        if target.status == "completed" { target.progress = 100 }
        if new.notes != old?.notes { target.notes = new.notes }
        target.updatedAt = Date()
        DataStore.save(context)
        if GoalListRules.justAchieved(before: before, after: target.status) { onAchieved?(target, before) }
        dismiss()
    }
}
