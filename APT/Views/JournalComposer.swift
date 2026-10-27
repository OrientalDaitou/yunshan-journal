import SwiftUI
import SwiftData

// MARK: - 落笔

@MainActor
enum JournalActions {
    /// 删除确认框的说明（时间线与修订弹窗共用）
    static let deleteNotice = "对应的修为会同时扣回。删除后页面底部会出现“撤销删除”，约 8 秒内可以找回。"

    /// 刚删过一篇、“撤销删除”还能点的这段时间（约 8 秒）里先不换日：换日会整页重建，页面上的撤销提示和删除时拍的快照
    /// 会一起丢掉，那篇就再也找不回来了（见 RootView.refreshDay）。
    private(set) static var undoWindowEnds: Date?
    static var undoWindowOpen: Bool { (undoWindowEnds ?? .distantPast) > Date() }

    /// 落笔入卷：只改动这一篇所在的那一天，修为差只算那一天（见 CultivationService.withGain）。返回修为差。
    @discardableResult
    static func save(_ entry: JournalEntry, context: ModelContext, effects: EffectsCenter) -> Int {
        CultivationService.withGain(on: entry.day, dateKey: entry.dateKey, context: context, effects: effects) {
            context.insert(entry)
            DataStore.save(context)
            // 动效开时另放“墨迹晕开、纸卷合拢、飞入修行录”的仪式（Core Animation，在这里同步提交，之后界面再忙也不卡）
            effects.stamp(entry.kindValue == .review ? "复盘" : "入卷", inscription: entry.body, kind: entry.kindValue)
        }
    }

    /// 删除一篇，返回值快照（撤销时用 `restore` 原样插回）。
    @discardableResult
    static func delete(_ entry: JournalEntry, context: ModelContext, effects: EffectsCenter?) -> JournalSnapshot {
        let snapshot = JournalSnapshot(entry)
        // 页面底部的“撤销删除”停约 8 秒，再留一点收起动画的时间
        undoWindowEnds = Date().addingTimeInterval(8.5)
        CultivationService.withGain(on: entry.day, dateKey: entry.dateKey, context: context, effects: effects) {
            context.delete(entry)
            DataStore.save(context)
        }
        return snapshot
    }

    /// 撤销删除：用快照重建这一篇（修为随之恢复）。返回修为差。
    @discardableResult
    static func restore(_ snapshot: JournalSnapshot, context: ModelContext, effects: EffectsCenter?) -> Int {
        undoWindowEnds = nil
        // 与 JournalEntry.day 相同：日期写坏了时按创建日
        let day = LocalDay(key: snapshot.dateKey) ?? LocalDay(date: snapshot.createdAt)
        return CultivationService.withGain(on: day, dateKey: snapshot.dateKey, context: context, effects: effects) {
            snapshot.restore(into: context)
            DataStore.save(context)
        }
    }
}

/// 落笔框：今日洞府与修行录共用。写到一半的内容存为草稿（`draft.<页面>.*`），切页、重启都不丢，入卷后清空。
/// 输入框随内容长高（今日洞府 2 行起、最高约 120pt；修行录 80 起、最高 260），再多就在框里滚动。
/// 修行录的标题框平时收起（第一屏要露出时间线），点进正文、写过标题或写复盘时才出现。
/// 今日洞府（compact）另随时辰多出晨课一愿、问心签、晚课三省（见 DailyRitualViews.swift），类型入卷后回到日记；修行录的完整落笔框不变。
/// 修行录的完整落笔框另有“套用模板 ▾”：内置四套 + 自存的（见 Core/JournalTemplates、Views/JournalTemplateSheet）；首页的小落笔框没有。
struct JournalComposer: View {
    @Binding var kind: JournalKind
    var compact = false
    /// 今日洞府：标题行右侧的“翻开修行录 →”（把写了一半的草稿带过去补标题和标签）；nil 时不显示
    var onOpenChronicle: (() -> Void)?
    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    @AppStorage private var title: String
    @AppStorage private var text: String
    @AppStorage private var tagsText: String
    @AppStorage private var mood: Int?
    @AppStorage private var period: ReviewPeriod
    /// nil 表示“今天”（随日期自动变化，避免应用跨夜开着时记到昨天）
    @AppStorage private var pickedDay: String?
    /// 复盘“本期素材”默认展开（上次许下的下一步在最上面，写复盘时第一眼就看到）；收起过就记住
    @AppStorage("chronicle.reviewMaterial.open") private var showMaterial = true
    /// 复盘回访点过的签（“做到了 / 没做到 / 改主意了”）：入卷时还没进正文的自动补插进去，入卷后清空；键见 ReviewMaterialCard
    @AppStorage private var followups: String
    /// 草稿存在哪个页面名下（回访的签与正文同一页）
    private let draftPage: String
    @Environment(\.spiritMotion) private var motion
    @FocusState private var editorFocused: Bool
    /// 修行录：点进过正文后标题框展开，入卷后再收起
    @State private var titleOpen = false
    /// 今日洞府：晚课三格的开关（"1" 开着：暮夜进页时正文框空着就自动打开；键见 DailyRite）
    @AppStorage(DailyRite.eveningOpenKey) private var eveningOpen = ""
    /// 晚课三格此刻开着、记到哪一晚：只在进页、换到暮夜、换了一天时判定一次（decideEvening），
    /// 之后只由点签、“改写一段话”、合成入卷来开合——正文清空的那一下不会突然换成三格
    @State private var eveningDay: LocalDay?
    /// ⌘N 落笔、刚点开三格时 +1：光标进晚课第一格
    @State private var eveningFocusTick = 0
    /// 今日问心签与它今天答过没有：进页、跨日、换签、入卷后重取，不在每次打字时读偏好
    @State private var slip: DailyPrompt?
    @State private var slipAnswered = false
    /// 自存的落笔模板（JSON，见 Core/JournalTemplates）：“套用模板 ▾”菜单列出它们，入卷前判断正文是不是只有模板骨架也要用
    @AppStorage(JournalTemplates.customKey) private var customTemplatesRaw = ""
    /// 修行录：“把当前正文存为模板…”“管理模板…”两个小弹窗
    @State private var savingTemplate = false
    @State private var managingTemplates = false

    /// - Parameter draftPage: 草稿存在哪个页面名下；默认今日洞府用 `dashboard`、修行录用 `chronicle`
    init(kind: Binding<JournalKind>, compact: Bool = false, draftPage: String? = nil, onOpenChronicle: (() -> Void)? = nil) {
        _kind = kind
        self.compact = compact
        self.onOpenChronicle = onOpenChronicle
        let page = draftPage ?? (compact ? "dashboard" : "chronicle")
        self.draftPage = page
        _followups = AppStorage(wrappedValue: "", JournalDraft.key(page, "followups"))
        _title = AppStorage(wrappedValue: "", JournalDraft.key(page, "title"))
        _text = AppStorage(wrappedValue: "", JournalDraft.key(page, "text"))
        _tagsText = AppStorage(wrappedValue: "", JournalDraft.key(page, "tags"))
        _mood = AppStorage(JournalDraft.key(page, "mood"))
        _period = AppStorage(wrappedValue: ReviewPeriod.week, JournalDraft.key(page, "period"))
        _pickedDay = AppStorage(JournalDraft.key(page, "day"))
    }

    /// 只套了模板、还没写内容的不算有内容（复盘四段之外，晚课三省、读书札记、一事一记和自存的只有段名的模板骨架也一样）。
    /// 与草稿“是否为空”（JournalDraft.isBlankBody）同一个判定：JournalTemplates.isSkeleton
    private var canSave: Bool {
        !(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && JournalTemplates.isSkeleton(text, custom: customTemplates))
    }

    /// 入卷按钮的悬停说明：正文里只有没动过的模板骨架、按钮因此点不动时说一句为什么
    private var submitHelp: String {
        if !canSave, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "只套了模板，写几个字再入卷" }
        return KeyCommand.composeSubmit.help("落笔入卷")
    }

    private var customTemplates: [JournalTemplate] { JournalTemplates.decode(customTemplatesRaw) }

    /// 落笔卡的滚动定位（⌘N 落笔时把它滚进视野）
    private static let anchor = "journal-composer"

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if compact {
                    // 今日洞府：时辰每分钟报一次（离屏按 APT_RENDER_CLOCK），只有这张卡跟着重算
                    DailyRiteClock { moment in compactCard(moment) }
                } else {
                    card
                }
            }
            .id(Self.anchor)
            .background { focusShortcut(proxy) }
        }
    }

    /// ⌘N 落笔：光标跳进正文框，落笔卡滚进视野（隐形按钮，只为挂快捷键）
    private func focusShortcut(_ proxy: ScrollViewProxy) -> some View {
        Button("落笔") {
            editorFocused = true
            // 今日洞府晚课三格开着时：光标进第一格（三格不在屏上时这一下什么都不做）
            if compact { eveningFocusTick += 1 }
            withAnimation(motion ? Motion.standard : nil) { proxy.scrollTo(Self.anchor, anchor: .top) }
        }
        .keyCommand(.composeFocus)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题旁不再写“写一句也好 / ⌘↩ 入卷”：快捷键写在入卷按钮上
            // 标题行：“套用模板 ▾”在类型签左边（日记、灵感、复盘都能套；窄窗口里也和类型签同一行，不另占一行）
            CardTitle(title: "落笔") {
                HStack(spacing: 12) {
                    chronicleLink
                    templateMenu
                    kindTabs
                }
            }
            if showsTitle {
                TextField(kind == .review ? "复盘标题，例如：第 42 周复盘" : "标题（可不填）", text: $title)
                    .font(Theme.songti(TypeSize.heading, .medium))
                    .transition(.opacity)
            }
            editor
            // （今日洞府的落笔卡另见 compactCard；这里只是修行录的完整落笔框）
            if kind != .note { kindOptions }
            // 复盘：上次许下的下一步与这段时间的素材（只在修行录的完整落笔框里显示）
            if kind == .review {
                let picked = pickedDay.flatMap { LocalDay(key: $0) }
                ReviewMaterialCard(period: period, anchor: picked ?? .today(), picked: picked,
                                   followupsKey: JournalDraft.key(draftPage, "followups"),
                                   inserted: ReviewThread.inserted(in: text), open: $showMaterial,
                                   onPickDay: { day in pickedDay = day == LocalDay.today() ? nil : day.key },
                                   onInsert: { insertion in text = insertion.applied(to: text) })
            }
            // 底部工具栏：标签、日期、落笔入卷一行；窗口窄时按钮换到下一行
            WrapTrailingRow {
                HStack(spacing: 10) {
                    tagField.frame(minWidth: 110, idealWidth: 260, maxWidth: 260)
                    dayChip
                }
                submitButton
            }
        }
        // 进复盘时空着就填复盘四段；离开复盘时只清掉进复盘时填的那份（日记、灵感里从“套用模板 ▾”套的复盘四段，换类型不清）
        .onChange(of: kind) { oldKind, newKind in
            if newKind == .review, text.isEmpty { text = ReviewPeriod.template }
            if oldKind == .review, newKind != .review, text == ReviewPeriod.template { text = "" }
        }
        .onChange(of: editorFocused) { _, focused in
            guard focused, !compact, !titleOpen else { return }
            withAnimation(motion ? Motion.standard : nil) { titleOpen = true }
        }
        .sheet(isPresented: $savingTemplate) {
            JournalTemplateSaveSheet(templateBody: text) { name in effects.hint("已存为模板「\(name)」", icon: "doc.text") }
                .defaultAppStorage(AppPreferences.defaults)
        }
        .sheet(isPresented: $managingTemplates) {
            JournalTemplateSheet().defaultAppStorage(AppPreferences.defaults)
        }
    }

    // MARK: 修行录：落笔模板

    /// “套用模板 ▾”：内置四套、自存的（照存的先后），分隔线后“把当前正文存为模板…”“管理模板…”
    private var templateMenu: some View {
        let custom = customTemplates
        return Menu {
            ForEach(JournalTemplates.builtins) { template in
                Button(template.menuTitle) { applyTemplate(template) }
            }
            if !custom.isEmpty {
                Divider()
                ForEach(custom) { template in
                    Button(template.menuTitle) { applyTemplate(template) }
                }
            }
            Divider()
            // 正文空着（或只有没动过的模板骨架）时没什么可存
            Button("把当前正文存为模板…") { savingTemplate = true }
                .disabled(JournalTemplates.isSkeleton(text, custom: custom))
            Button("管理模板…") { managingTemplates = true }
        } label: {
            // 带 ⌄：这是一个菜单（选一套模板 / 存 / 管理），不是点一下就套用
            HStack(spacing: 8) {
                Label("套用模板", systemImage: "doc.text")
                Image(systemName: "chevron.down").font(.system(size: TypeSize.micro, weight: .bold)).foregroundStyle(Theme.inkSoft)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.yunshanCompact)
        .fixedSize()
        .help("套用一套落笔模板：正文空着直接放入，写了字就接在末尾；也可以把当前正文存成自己的模板")
    }

    /// 套用：正文空（或只有没动过的骨架）直接换成模板；写了字就接在末尾、空一行，并飘一句提示。光标回到正文框
    private func applyTemplate(_ template: JournalTemplate) {
        let result = JournalTemplates.applying(template, to: text, custom: customTemplates)
        text = result.text
        if result.appended { effects.hint("「\(template.name)」接在正文末尾", icon: "text.append") }
        editorFocused = true
    }

    @ViewBuilder
    private var chronicleLink: some View {
        if let onOpenChronicle {
            Button("翻开修行录", action: onOpenChronicle)
                .buttonStyle(.cardLink)
                .help("到修行录接着写：写了一半的草稿会一起带过去，补上标题和标签")
        }
    }

    private var kindTabs: some View {
        SegmentedTabs(options: JournalKind.allCases.map { ($0, $0.label) }, selection: $kind)
            .fixedSize()
    }

    // MARK: 今日洞府：晨课、问心签、晚课

    /// 今日洞府的落笔卡：晨里标题下“晨课 · 立今日一愿”（立了之后全天一行“今日一愿”），写日记时正文框上一行问心签，
    /// 暮夜标题下一行多一枚“晚课 · 三省”签，开着时正文框换成三格。各段自带上边距（不显示的不占空隙）
    private func compactCard(_ moment: DailyRiteMoment) -> some View {
        let evening = eveningDay
        let asking = kind == .diary && slip != nil
        return VStack(alignment: .leading, spacing: 0) {
            // 标题行三个时段都一样（翻开修行录 + 类型签）：晚课的签在下一行，窄窗口也不会把“翻开修行录”挤掉，开合三格时标题不跳
            CardTitle(title: "落笔") {
                HStack(spacing: 14) {
                    chronicleLink
                    compactKindTabs(locked: evening != nil)
                }
            }
            if moment.phase == .evening || evening != nil {
                EveningRiteRow(day: evening ?? moment.ritualDay, open: evening != nil) { open in toggleEvening(moment, open: open) }
            }
            if let evening {
                EveningRitePanel(day: evening, today: moment.today, focusTick: eveningFocusTick, onClose: closeEvening) {
                    // 合成入卷后：三格收起（签上写“晚课已毕”），类型回到日记
                    kind = DailyRite.composerKind(kind, draftBlank: true)
                    withAnimation(motion ? Motion.standard : nil) { eveningDay = nil }
                }
                .id(evening.key)
                .padding(.top, 12)
                .transition(.opacity)
            } else {
                DailyVowStrip(moment: moment).id(moment.ritualDay.key)
                if asking, let slip {
                    AskSlipLine(prompt: slip, bodyEmpty: text.isEmpty, answeredToday: slipAnswered,
                                onSkip: { skipSlip(moment.today) }, onAnswer: answerSlip)
                        .padding(.top, 12)
                }
                editor.padding(.top, asking ? 8 : 12)
                // 心境（或复盘周期）与“落笔入卷”同一行；放不下时按钮换到下一行
                WrapTrailingRow {
                    kindOptions
                    submitButton
                }
                .padding(.top, 12)
            }
        }
        .onChange(of: kind) { _, newKind in
            if newKind == .review, text.isEmpty { text = ReviewPeriod.template }
            if newKind != .review, text == ReviewPeriod.template { text = "" }
        }
        .onAppear {
            // 类型不再悄悄沿用上次：草稿是空的就回到日记（写了一半的保留原类型）
            let next = DailyRite.composerKind(kind, draftBlank: !canSave)
            if next != kind { kind = next }
            refreshSlip(moment.today)
            decideEvening(moment)
        }
        .onChange(of: moment.today) { _, day in refreshSlip(day) }
        .onChange(of: moment.phase) { _, _ in decideEvening(moment) }
        .onChange(of: moment.ritualDay) { _, _ in decideEvening(moment) }
    }

    /// 首页的类型签：晚课三格开着时淡下去、点不动（这时入卷的是日省），但仍占着位置，标题行高度不变
    @ViewBuilder
    private func compactKindTabs(locked: Bool) -> some View {
        if locked {
            kindTabs
                .disabled(true)
                .opacity(0.4)
                .help("晚课三格开着：点“改写一段话”回到普通正文框，再选日记、灵感或复盘")
        } else {
            kindTabs
        }
    }

    /// 晚课三格开不开，只在进页、换到暮夜、换了一天时判定一次：开关开着、这一晚还没合成入卷、正文框空着才自动打开
    /// （正文里写了字就不自动换成三格，点签才换）。三格里正写着字时跨过 05:00 也不收，仍记到开始写的那一晚
    private func decideEvening(_ moment: DailyRiteMoment) {
        let day = moment.ritualDay
        let next = DailyRite.eveningPanel(current: eveningDay, draftsBlank: DailyRiteStore.eveningDraftBlank(), phase: moment.phase,
                                          ritualDay: day, switchOn: eveningOpen == "1", bodyWritten: canSave,
                                          saved: { DailyRiteStore.eveningSaved(on: day, context: context) })
        if next != eveningDay { eveningDay = next }
    }

    /// 点晚课的签：开（已毕时就是“再写一篇”——已毕看修行录里那一篇，等第二篇真的入卷才算数）或收（三格写的留在草稿里）
    private func toggleEvening(_ moment: DailyRiteMoment, open: Bool) {
        withAnimation(motion ? Motion.standard : nil) {
            eveningDay = open ? (eveningDay ?? moment.ritualDay) : nil
            eveningOpen = open ? "1" : ""
        }
        if open { eveningFocusTick += 1 }
    }

    /// “改写一段话”：回到普通正文框（三格写的留在草稿里）
    private func closeEvening() {
        withAnimation(motion ? Motion.standard : nil) {
            eveningOpen = ""
            eveningDay = nil
        }
        editorFocused = true
    }

    private func refreshSlip(_ day: LocalDay) {
        let prompt = DailyRiteStore.slip(on: day)
        slip = prompt
        slipAnswered = DailyRiteStore.isAnswered(prompt, on: day)
    }

    private func skipSlip(_ day: LocalDay) {
        DailyRiteStore.skip(on: day)
        refreshSlip(day)
    }

    /// 答此签：正文开头插「签文」加换行，光标进正文框接着写
    private func answerSlip() {
        guard let slip else { return }
        text = DailyPrompts.insertingAnswer(slip, into: text)
        editorFocused = true
    }

    /// 标题框（只在修行录）：写复盘、草稿里已有标题，或点进过正文时才显示
    private var showsTitle: Bool {
        !compact && (titleOpen || kind == .review || !title.isEmpty)
    }

    /// 正文输入框：随内容长高（今日洞府 60–120，修行录 80–260），到上限后在框里滚动；聚焦时描边和柔光是这一类的颜色
    private var editor: some View {
        PaperEditor(text: $text, placeholder: placeholder, height: compact ? 60...120 : 80...260,
                    accent: kind.color, glow: true, focus: $editorFocused)
            // 入卷时纸笺铺在这里，卷成小卷飞走
            .ritualAnchor(.composer)
    }

    /// 今日洞府写日记时，空着的正文框里提示语是今日问心签（原来的提示语兜底）；修行录照旧
    private var placeholder: String {
        compact && kind == .diary ? (slip?.text ?? kind.placeholder) : kind.placeholder
    }

    /// 心境（日记）/ 复盘周期（复盘；首页另带“套用模板”）；灵感没有，占一个空位
    @ViewBuilder
    private var kindOptions: some View {
        switch kind {
        case .diary:
            HStack(spacing: 10) {
                Text("心境").font(.ysCaption).foregroundStyle(Theme.inkSoft).fixedSize()
                MoodPicker(mood: $mood)
            }
        case .review:
            HStack(spacing: 10) {
                SegmentedTabs(options: ReviewPeriod.allCases.map { ($0, $0.label) }, selection: $period).fixedSize()
                // 今日洞府的小落笔框照旧一颗“套用模板”（复盘四段）；修行录的完整落笔框换成标题行的“套用模板 ▾”菜单
                if compact {
                    Button("套用模板") { text = text.isEmpty ? ReviewPeriod.template : text + "\n" + ReviewPeriod.template }
                        .buttonStyle(.yunshanCompact)
                }
            }
        case .note:
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private var tagField: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return HStack(spacing: 6) {
            Image(systemName: "number").font(.system(size: TypeSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSoft)
                .accessibilityHidden(true)
            TextField("标签，空格分隔", text: $tagsText).textFieldStyle(.plain).font(.ysCallout)
        }
        .padding(.horizontal, 12)
        // 与日期签、“落笔入卷”同高，底部工具栏上下对齐
        .frame(height: Self.toolbarHeight)
        .background(Theme.paper.opacity(0.6), in: shape)
        .overlay(shape.strokeBorder(Theme.line))
    }

    /// 底部工具栏一行的控件高度（与主按钮同高）
    private static let toolbarHeight: CGFloat = 38

    private var dayChip: some View {
        DayField(label: "", key: Binding(get: { pickedDay ?? LocalDay.today().key }, set: { pickedDay = $0 == LocalDay.today().key ? nil : $0 }),
                 height: Self.toolbarHeight)
    }

    private var submitButton: some View {
        Button(action: save) {
            HStack(spacing: 8) {
                Label("落笔入卷", systemImage: "seal").lineLimit(1)
                // 快捷键提示（修行录）：次要一档的小字
                if !compact { Text(KeyCommand.composeSubmit.display).font(.ysCaption).opacity(0.65) }
            }
        }
        .buttonStyle(.yunshanPrimary)
        .fixedSize()
        .keyCommand(.composeSubmit)
        // 朱印盖在这颗按钮旁边
        .sealAnchor()
        .help(submitHelp)
        .disabled(!canSave)
    }

    private func save() {
        guard canSave else { return }
        let today = LocalDay.today().key
        let dayKey = compact ? today : (pickedDay ?? today)
        // 复盘：回访点过签、还没点“插入”的，入卷时照签补进【所得】【所失】【所悟】（不会悄悄丢掉）
        var body = text
        if kind == .review, !followups.isEmpty {
            body = ReviewMaterial.withFollowups(followups, into: body, period: period, anchor: LocalDay(key: dayKey) ?? .today(), context: context)
        }
        let entry = JournalEntry(kind: kind, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                 body: body.trimmingCharacters(in: .whitespacesAndNewlines), dateKey: dayKey)
        entry.tags = TagText.parse(tagsText)
        entry.mood = kind == .diary ? mood : nil
        entry.period = kind == .review ? period.rawValue : ""
        if dayKey == today { entry.minute = ClockTime.minutes(of: Date()) }
        JournalActions.save(entry, context: context, effects: effects)
        // 正文以「签文」开头：记下今天答过这一签（半年内不再抽到）。修行录里入卷也算——
        // 首页点了“答此签”再“翻开修行录”，草稿带过去在那边写完入卷的
        let answeredDay = LocalDay.today()
        DailyRiteStore.noteAnswer(body: entry.body, day: answeredDay)
        if compact {
            // 卡上改写“今日已答”
            refreshSlip(answeredDay)
            // 类型不再悄悄沿用：记完灵感、复盘都回到日记
            kind = DailyRite.composerKind(kind, draftBlank: true)
        }
        // 入卷成功才清空草稿（标题框随之收起）
        titleOpen = false
        title = ""
        text = kind == .review ? ReviewPeriod.template : ""
        tagsText = ""
        mood = nil
        pickedDay = nil
        followups = ""
    }
}

struct MoodPicker: View {
    @Binding var mood: Int?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { value in
                let on = mood == value
                Button { mood = on ? nil : value } label: {
                    HStack(spacing: 5) {
                        Image(systemName: Mood.symbol(value)).font(.system(size: TypeSize.caption, weight: .medium))
                        Text(Mood.label(value)).font(Theme.songti(TypeSize.callout, .medium))
                    }
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(on ? Theme.onJade : Theme.inkSoft)
                    // 柔光只加在底色胶囊上，底与描边都用按路径画的 PathCapsule：系统胶囊连着阴影交给图层画时两侧会多出两截细竖线
                    // （离屏渲染里可复现，compositingGroup 压不掉）；也不再用 .drawingGroup()——它会逼应用起一套 Metal 渲染、启动内存暴涨（#21）
                    .background {
                        PathCapsule()
                            .fill(on ? AnyShapeStyle(LinearGradient(colors: [Theme.gold, Theme.gold.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                                     : AnyShapeStyle(Theme.mist.opacity(0.7)))
                            // 只有选中的那枚才有金色柔光
                            .shadow(color: on ? Theme.gold.opacity(0.35) : .clear, radius: on ? 6 : 0)
                    }
                    .overlay(PathCapsule().strokeBorder(on ? Theme.gold.opacity(0.6) : Theme.line.opacity(0.7)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("心境：\(Mood.label(value))")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}
