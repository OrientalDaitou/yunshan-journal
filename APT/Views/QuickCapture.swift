import SwiftUI
import SwiftData
import AppKit
import Carbon.HIToolbox

/// 随手记：菜单栏小图标与全局快捷键 ⌥⌘J 都能唤出，不必打开主窗口就能记一句。
/// 默认“随心”：写一句话，自动认出是日记、灵感、记账、打卡还是日程（QuickParse），正文框下的预览签说清“此句将入”哪里，
/// 认错了点“不对？改作 ▾”一键换；“日记 / 灵感 / 复盘 / 记账”四个原来的写法也都还在。
/// 写到一半的内容存为草稿（`draft.quick.*`）：收起浮窗、按 Esc、退出应用都不丢，记好之后才清空；
/// 每次打开时草稿是空的就回到“随心”，写了一半的保持上次的类型（写到一半的账不丢）。
/// 记好后约 2.5 秒自动收起；这段时间里又开始写下一条或点了“撤销”就不收（撤销把记下的那条删掉、原话放回输入框）。
/// 随心的预览签上有一枚日期签（“今天 ⌄”）：补记昨天、前天或选一天，日记灵感复盘、记账、打卡都按这天记，日程按这天的钟点；
/// 只管这一条，记好、或下次打开时草稿是空的就回到“按句中日期”。“记账”的类别也一样：记好回到“餐饮与外卖”，不沿用上次。
struct QuickCaptureView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case auto, diary, note, review, expense
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: "随心"
            case .diary: "日记"
            case .note: "灵感"
            case .review: "复盘"
            case .expense: "记账"
            }
        }
        var journal: JournalKind? {
            switch self {
            case .diary: .diary
            case .note: .note
            case .review: .review
            case .auto, .expense: nil
            }
        }
    }

    /// 打开随手记时用哪一类：草稿是空的回到“随心”；写了一半的（正文或金额）保持上次的类型
    static func openingKind(stored: String, text: String, amount: String) -> Kind {
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return blank ? .auto : (Kind(rawValue: stored) ?? .auto)
    }

    /// 随心的正文框提示：一句引子，再是几种能认的说法（分两行写，免得在右下角的小印底下折行）
    static let autoPlaceholder = "写一句即可——\n午饭 18.5 · 冥想 10 分钟\n明天下午3点 组会 · #灵感 先完成再完美"

    /// “记账”的默认类别：草稿是空的打开、记好一笔之后都回到它（不沿用上次选的）
    static let defaultCategory = "餐饮与外卖"

    var onDone: () -> Void
    /// 全局快捷键没注册上时，底下用朱砂小字说明。菜单栏小窗传 false：小窗底栏已有同义的一句，不再写两遍
    var showsHotKeyHint: Bool = true
    @Environment(\.modelContext) private var context
    @AppStorage("quick.kind") private var kindRaw = Kind.auto.rawValue
    @AppStorage("draft.quick.text") private var text = ""
    @AppStorage("draft.quick.mood") private var mood: Int?
    @AppStorage("draft.quick.amount") private var amount = ""
    @AppStorage("draft.quick.category") private var category = QuickCaptureView.defaultCategory
    /// 随心：在“改作”里选定的类型（QuickParse.Choice.raw）、选定时的那句正文，与改过的记账类别。
    /// 清空正文、或全选重写了一句（见 QuickParse.keepsChoice）就回到自动认
    @AppStorage("draft.quick.choice") private var choiceRaw = ""
    @AppStorage("draft.quick.choiceText") private var choiceText = ""
    @AppStorage("draft.quick.autoCategory") private var autoCategory = ""
    /// 随心：日期签上选定的那天（LocalDay.key；空 = 按句中写的日子）
    @AppStorage("draft.quick.day") private var pinnedKey = ""
    /// 全局快捷键注册失败时的说明（由 QuickCapturePanel 写入）
    @AppStorage(QuickCaptureKeys.hotKeyError) private var hotKeyError = ""
    @State private var saved: String?
    @State private var error: String?
    /// 刚记下的那一条（可以立即撤销）：怎么撤，以及撤销时放回输入框的内容
    @State private var lastRecord: Recent?
    /// 撤销后放回输入框的内容：放回这一下不算“开始写下一条”，“已撤销”的提示留着
    @State private var restored: (amount: String, text: String)?
    /// 记好后延迟自动收起的凭据：这段时间里动了输入框（正文、金额、类别、类型、心境）或点了撤销就作废，不再收起
    @State private var autoCloseToken: UUID?
    /// 账上已有的、可能就是这一笔的银行扣款（前后 3 天内、金额相同）；只提醒，不拦着入账
    @State private var bankMatches: [FinanceTransaction] = []
    /// 随心认出的结果（打字后 150 毫秒再认；输入法还在组字时不认，预览签不闪）
    @State private var parsed: QuickParse.Result?
    @State private var parseTask: Task<Void, Never>?
    /// 认句子时用的功课（与 parsed 一一对应，打卡时按下标取）
    @State private var habitModels: [Habit] = []
    @State private var habitInfos: [QuickParse.Habit] = []
    @FocusState private var focused: Bool
    /// “记账”的金额框：切到记账时光标先落在这里
    @FocusState private var amountFocused: Bool
    /// 动效开关：浮窗拿不到主窗口的 EffectsCenter，直接看设置里的开关与系统“减少动态效果”（浮窗保存时一定在前台，不用管失焦）
    @Query private var settingsList: [AppSettings]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 记下时在正文框右下角就地盖的小印
    @State private var sealController = MiniSealController()

    /// 刚记下的一条：撤销的办法与要放回的东西
    struct Recent {
        var record: QuickCommit.Record
        var kind: String
        var text: String
        var amount: String
        var category: String
        var choice: String
        var choiceText: String
        var autoCategory: String
        var mood: Int?
        var pinnedKey: String = ""
    }

    private var kind: Kind { Kind(rawValue: kindRaw) ?? .auto }
    private var pinnedDay: LocalDay? { pinnedKey.isEmpty ? nil : LocalDay(key: pinnedKey) }
    private var motion: Bool { (settingsList.first?.motionEnabled ?? true) && !reduceMotion }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 金额规则与“手记一笔”、飞剑传书相同；没填或写错时为 nil
    private var cents: Int? { try? FinanceEngine.manualCents(amount) }
    private var canSave: Bool {
        switch kind {
        case .auto: !trimmed.isEmpty && (parsed?.canSave ?? true)
        case .expense: cents != nil && !trimmed.isEmpty
        default: !trimmed.isEmpty
        }
    }
    /// 认作日记（或正文还空着）时才显示心境；记好之后那一行留给“已入卷 · 撤销”
    private var showsMood: Bool {
        guard saved == nil else { return false }
        switch kind {
        case .diary: return true
        case .auto: return parsed == nil || parsed?.intent == .diary
        default: return false
        }
    }
    private var buttonTitle: String {
        switch kind {
        case .auto: parsed?.intent.button ?? "落笔入卷"
        case .expense: "入账"
        default: "落笔入卷"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SceneryImage(name: "yunshan-ornament-brush-v1").frame(width: 26, height: 26)
                Text("随手记").font(.ysHeading).tracking(2).foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                SegmentedTabs(options: Kind.allCases.map { ($0.rawValue, $0.label) }, selection: $kindRaw).fixedSize()
            }
            if kind == .expense {
                HStack(spacing: 8) {
                    QuickAmountBox(text: $amount, focus: $amountFocused).frame(width: 106)
                    ChipPicker(selection: $category, options: FinanceEngine.spendCategories.map { ($0, $0) })
                }
                if let problem = AmountField.problem(amount) {
                    AmountField.problemLabel(problem)
                } else if !bankMatches.isEmpty {
                    BankMatchHint(matches: bankMatches, compact: true)
                }
            }
            PaperEditor(text: $text, placeholder: placeholder, height: editorHeight, focus: $focused)
                // 记下时一方小印就地盖在正文框右下角（不占布局，浮窗高度不变；不接收点击）
                .overlay(alignment: .bottomTrailing) {
                    MiniSealView(controller: sealController)
                        .frame(width: 28, height: 52)
                        .padding(.trailing, 10)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            if kind == .auto {
                QuickIntentChip(result: trimmed.isEmpty ? nil : parsed, habits: habitInfos,
                                category: autoCategory.isEmpty ? nil : autoCategory, motion: motion,
                                onCategory: { autoCategory = $0 },
                                onChoose: { choice in
                                    choiceRaw = choice?.raw ?? ""
                                    // 记下选定时的这句：之后全选重写成别的话，锁定就不再算数
                                    choiceText = choice == nil ? "" : text
                                    reparse(now: true)
                                },
                                pinnedDay: pinnedDay,
                                onPinDay: { pinnedKey = $0?.key ?? "" })
                if parsed?.intent == .expense, !bankMatches.isEmpty {
                    BankMatchHint(matches: bankMatches, compact: true)
                }
            }
            HStack(spacing: 10) {
                if showsMood { MoodPicker(mood: $mood) }
                if let saved { Hint(saved, tone: .success, symbol: "checkmark.seal").lineLimit(1) }
                if saved != nil, let last = lastRecord {
                    // 就地撤销：不带“→”（那表示去别处）
                    Button(action: undo) { Label("撤销", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.inlineAction(Theme.warning))
                        .help(last.record.undoHelp)
                }
                if let error { Hint(error, tone: .error) }
                Spacer(minLength: 0)
                // 心境那一行已占满时（以前挤成两个小点），快捷键改写在按钮的悬停提示里
                if !showsMood { Text(KeyCommand.quickCaptureSubmit.display).font(.ysCaption).foregroundStyle(Theme.inkSoft) }
                Button(buttonTitle, action: save)
                    .buttonStyle(.yunshanPrimary)
                    .fixedSize()
                    .keyCommand(.quickCaptureSubmit)
                    .help(KeyCommand.quickCaptureSubmit.help(buttonTitle))
                    .disabled(!canSave)
            }
            if showsHotKeyHint, !hotKeyError.isEmpty {
                Hint(hotKeyError, tone: .warning)
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(Theme.card)
        .buttonStyle(.yunshan)
        .textFieldStyle(.yunshan)
        .tint(Theme.jade)
        .onAppear {
            kindRaw = Self.openingKind(stored: kindRaw, text: text, amount: amount).rawValue
            if trimmed.isEmpty { choiceRaw = ""; choiceText = ""; autoCategory = "" }
            // 草稿是空的：日期签回到“按句中日期”，记账类别回到默认（上回没记成的选择不带到这一回）
            if trimmed.isEmpty, amount.trimmingCharacters(in: .whitespaces).isEmpty {
                pinnedKey = ""
                category = Self.defaultCategory
            }
            focusField()
            reparse(now: true)
        }
        .onDisappear { parseTask?.cancel() }
        // 接着写下一条时，上一条的“已入卷”就不再显示，也不再自动收起
        // （save() 自己把输入框清空也会触发这里，所以只认非空的新输入）
        .onChange(of: text) { _, value in
            if !value.isEmpty, value != restored?.text { saved = nil; lastRecord = nil; autoCloseToken = nil }
            // 清空正文：回到自动认，改过的类别也不再沿用
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { choiceRaw = ""; choiceText = ""; autoCategory = "" }
            // ⌘A 全选后重写了一句（TextEditor 里是一步替换，正文从没空过）：改作的锁定跟着作废，回到自动认
            else if !choiceRaw.isEmpty, !QuickParse.keepsChoice(original: choiceText, current: value) { choiceRaw = ""; choiceText = "" }
            reparse(now: false)
        }
        .onChange(of: amount) { _, value in
            if !value.isEmpty, value != restored?.amount { saved = nil; lastRecord = nil; autoCloseToken = nil }
            refreshBankMatches()
        }
        // save() 入账后自己把类别放回默认也会触发这里：只认换成别的类别（与正文、金额一样），不然入账后不收起
        .onChange(of: category) { _, value in if value != Self.defaultCategory { autoCloseToken = nil } }
        // save() 入账后自己把改过的类别清空也会触发这里：只认非空的新选择（与正文、金额一样），不然入账后不收起
        .onChange(of: autoCategory) { _, value in
            if !value.isEmpty { autoCloseToken = nil }
            refreshBankMatches()
        }
        .onChange(of: kindRaw) { _, _ in autoCloseToken = nil; focusField(); reparse(now: true); refreshBankMatches() }
        // 选了日期签：重认一遍（打卡要那天已记的数量）；记好之后又选了日子是在记下一条，不再自动收起
        .onChange(of: pinnedKey) { _, value in
            if !value.isEmpty { autoCloseToken = nil }
            reparse(now: true)
            refreshBankMatches()
        }
        .onChange(of: mood) { _, value in if value != nil { autoCloseToken = nil } }
        .onChange(of: parsed?.expense) { _, _ in refreshBankMatches() }
        // Esc 只是收起，写了一半的内容留在草稿里
        .onExitCommand(perform: onDone)
        .keyNote(.quickCaptureClose)
    }

    /// 光标放哪：“记账”而金额还空着时放金额框（先写多少钱），其余放正文框。
    /// 记账那一行是切过去才出现的，等它挂上再放
    private func focusField() {
        if kind == .expense, amount.trimmingCharacters(in: .whitespaces).isEmpty {
            DispatchQueue.main.async { amountFocused = true }
        } else {
            focused = true
        }
    }

    private var placeholder: String {
        switch kind {
        case .auto: Self.autoPlaceholder
        case .expense: "说明，例如：午饭 拉面"
        default: kind.journal?.placeholder ?? ""
        }
    }

    private var editorHeight: CGFloat {
        switch kind {
        case .auto: 96
        case .expense: 54
        default: 110
        }
    }

    // MARK: 随心：认句子

    /// 输入法正在组字（拼音还没选字）：这时的字不算数，先不认
    private static var composing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }

    /// 重认一遍：now 为真时当场认（打开浮窗、选定类型、撤销放回时），否则停笔 150 毫秒再认
    private func reparse(now: Bool) {
        parseTask?.cancel()
        guard kind == .auto else { return }
        if now {
            parsed = currentParse()
            return
        }
        parseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            var waited = 0
            while !Task.isCancelled, Self.composing, waited < 40 {
                try? await Task.sleep(for: .milliseconds(150))
                waited += 1
            }
            guard !Task.isCancelled else { return }
            parsed = currentParse()
        }
    }

    /// 按现在的正文、功课与打卡认一遍（功课清单每次现取：功课页刚打了卡，这里也认得“今日已圆满”）
    private func currentParse() -> QuickParse.Result? {
        guard !trimmed.isEmpty else { return nil }
        let (ctx, models) = QuickCommit.parseContext(in: context, extraDay: pinnedDay)
        habitModels = models
        habitInfos = ctx.habits
        return QuickParse.parse(text, context: ctx, choice: QuickParse.Choice(raw: choiceRaw), day: pinnedDay)
    }

    // MARK: 记下

    private func save() {
        guard canSave else { return }
        error = nil
        restored = nil
        let backup = Recent(record: .none, kind: kindRaw, text: text, amount: amount, category: category, choice: choiceRaw,
                            choiceText: choiceText, autoCategory: autoCategory, mood: mood, pinnedKey: pinnedKey)
        let effects = AppHost.shared.effects
        var record: QuickCommit.Record
        var message: String
        if kind == .auto {
            // 按此刻的正文再认一遍（停笔不到 150 毫秒就按 ⌘↩ 时，预览签还没跟上）
            guard let result = currentParse() else { return }
            parsed = result
            // 只写了前缀、日程没写做什么……：签上已写明原因，不记
            guard result.canSave else { return }
            // 先盖印（同步建层并提交），再写库：主窗口开着、正在重取数据时小印也不卡。记账写坏了不盖，见下
            if result.intent != .expense { sealController.stamp(result.intent.seal, animated: motion) }
            do {
                record = try QuickCommit.apply(result, mood: mood, category: autoCategory.isEmpty ? nil : autoCategory,
                                               habits: habitModels, context: context, effects: effects)
            } catch {
                self.error = "没记上：\(error.localizedDescription)"
                return
            }
            if result.intent == .expense { sealController.stamp(result.intent.seal, animated: motion) }
            message = result.savedText
        } else if let journal = kind.journal {
            sealController.stamp(journal == .review ? "复盘" : "入卷", animated: motion)
            let entry = JournalEntry(kind: journal, body: trimmed)
            entry.minute = ClockTime.minutes(of: Date())
            entry.mood = journal == .diary ? mood : nil
            entry.period = journal == .review ? ReviewPeriod.day.rawValue : ""
            context.insert(entry)
            DataStore.save(context)
            record = .journal(uid: entry.uid)
            message = "已入卷"
        } else if let cents {
            let row = ManualExpense.transaction(day: .today(), cents: cents, category: category,
                                                description: trimmed, note: "", reason: "随手记")
            do {
                _ = try FinanceService.mutate(context) { $0.transactions.append(row) }
            } catch {
                self.error = "记账失败：\(error.localizedDescription)"
                return
            }
            sealController.stamp("入账", animated: motion)
            record = .expense(id: row.id)
            message = "已入账"
        } else {
            return
        }
        var recent = backup
        recent.record = record
        lastRecord = recent
        saved = message
        QuickCommit.markUsed()
        text = ""
        amount = ""
        mood = nil
        choiceRaw = ""
        choiceText = ""
        autoCategory = ""
        // 日期签只管这一条；记账的类别回到默认（随心改过的类别上面已清空，回到认出的那类）
        pinnedKey = ""
        category = Self.defaultCategory
        parsed = nil
        // 接着记下一笔账：光标回到金额框
        if kind == .expense { focusField() }
        // 记好后停约 2.5 秒，来得及点“撤销”；这段时间里又开始写下一条（先填金额也算）或撤销了，就不收起，
        // 免得浮窗突然收起、焦点切回原来的应用，后面敲的字落进别的应用里
        let token = UUID()
        autoCloseToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if autoCloseToken == token { onDone() }
        }
    }

    /// 撤销刚记的那一条：删掉（打卡恢复成改之前的样子），原话放回输入框，改好可以重新记
    private func undo() {
        guard let last = lastRecord else { return }
        autoCloseToken = nil
        do {
            try QuickCommit.undo(last.record, context: context, effects: AppHost.shared.effects)
        } catch {
            self.error = "撤销失败：\(error.localizedDescription)"
            return
        }
        lastRecord = nil
        error = nil
        restored = (last.amount, last.text)
        kindRaw = last.kind
        // 先放回选定时的那句，再放回正文：放回这一下不算“重写了一句”
        choiceText = last.choiceText
        choiceRaw = last.choice
        autoCategory = last.autoCategory
        category = last.category
        pinnedKey = last.pinnedKey
        mood = last.mood
        amount = last.amount
        text = last.text
        saved = last.record.undoneText
        reparse(now: true)
    }

    /// 金额变了就比一次账上已有的银行流水（与“手记一笔”一致）。当天的流水多半还没导入，通常没有提示
    private func refreshBankMatches() {
        var probe: (cents: Int, day: LocalDay, category: String)?
        if kind == .expense, let cents {
            probe = (cents, .today(), category)
        } else if kind == .auto, parsed?.intent == .expense, let e = parsed?.expense {
            probe = (e.cents, e.day, autoCategory.isEmpty ? e.category : autoCategory)
        }
        guard let probe, let ledger = try? FinanceService.load(context) else {
            bankMatches = []
            return
        }
        let row = ManualExpense.transaction(day: probe.day, cents: probe.cents, category: probe.category, description: "", note: "", reason: "")
        bankMatches = FinanceEngine.existingBankMatches(for: row, in: ledger)
    }
}

// MARK: - 记下与撤销

/// 随手记把认好的一句话写进库、以及撤销（不碰界面，自检直接调）。
/// 修行录照原来的写法插入；记账走灵石账簿手记；打卡走 HabitActions（修为、功课圆满照常）；日程新建一条（类别留空）。
@MainActor
enum QuickCommit {
    /// 怎么撤销刚记的这一条
    enum Record {
        case none
        case journal(uid: String)
        case expense(id: String)
        /// 打卡：哪项功课、哪一天、改之前那条打卡的样子（nil = 原来没有）
        case checkin(habit: PersistentIdentifier, day: LocalDay, before: LogSnapshot?)
        case event(PersistentIdentifier)

        var undoHelp: String {
            switch self {
            case .none, .journal: "删掉刚记的这一篇，原话放回输入框"
            case .expense: "删掉刚记的这笔账，金额和说明放回输入框"
            case .checkin: "把这次打卡恢复成记之前的样子，原话放回输入框"
            case .event: "删掉刚记的这条日程，原话放回输入框"
            }
        }

        var undoneText: String {
            switch self {
            case .none, .journal: "已撤销，原话放回输入框"
            case .expense: "已撤销这笔账"
            case .checkin: "已撤销这次打卡"
            case .event: "已撤销这条日程"
            }
        }
    }

    /// 一条打卡改之前的样子（含数量与备注）
    struct LogSnapshot {
        var completed: Bool
        var quantity: Double?
        var durationMinutes: Int?
        var targetAtLog: Double?
        var notes: String
        var updatedAt: Date

        init(_ log: HabitLog) {
            completed = log.completed
            quantity = log.quantity
            durationMinutes = log.durationMinutes
            targetAtLog = log.targetAtLog
            notes = log.notes
            updatedAt = log.updatedAt
        }
    }

    /// 记不上 / 撤不了的原因（一句话，直接显示在随手记里）
    struct Problem: LocalizedError {
        var text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }

    /// 记过随手记的标记（筑基三关的第三关读它）
    static let usedKey = "onboarding.quickUsed"

    static func markUsed(in defaults: UserDefaults = AppPreferences.defaults) {
        if !defaults.bool(forKey: usedKey) { defaults.set(true, forKey: usedKey) }
    }

    /// 认句子用的上下文：未归档的功课（按排序），带今天、昨天、前天的打卡（日期签选了更早的那天也带上）；
    /// 现在的时刻离屏时按 APT_RENDER_CLOCK
    static func parseContext(in context: ModelContext, now: Date = Date(), extraDay: LocalDay? = nil) -> (QuickParse.Context, [Habit]) {
        let today = LocalDay.today()
        let models = context.allHabits().filter { !$0.archived }.sorted { ($0.sortOrder, $0.title) < ($1.sortOrder, $1.title) }
        var infos = models.map { h in
            QuickParse.Habit(title: h.title, unit: h.unit, target: (h.targetValue ?? 0) > 0 ? h.targetValue : nil)
        }
        if !models.isEmpty {
            var days = (0...2).map { today.adding(days: -$0) }
            if let extraDay, extraDay < today, !days.contains(extraDay) { days.append(extraDay) }
            for day in days {
                let logs = HabitDayLogs(day: day, context: context)
                for (i, habit) in models.enumerated() {
                    guard let log = logs.log(of: habit) else { continue }
                    let target = HabitQuantity.target(habit, atLog: log.targetAtLog)
                    let done = target.map { (log.quantity ?? 0) >= $0 } ?? log.completed
                    infos[i].days[day] = QuickParse.DayState(quantity: log.quantity, done: done)
                }
            }
        }
        let minute = SkyTime.fixedMinute.map { Int($0) } ?? ClockTime.minutes(of: now)
        return (QuickParse.Context(today: today, nowMinute: minute, habits: infos), models)
    }

    /// 记下认好的这一句。mood 只给日记；category 是记账时改过的类别；habits 与认句子时的 Context.habits 一一对应
    static func apply(_ result: QuickParse.Result, mood: Int?, category: String?, habits: [Habit], context: ModelContext,
                      effects: EffectsCenter) throws -> Record {
        // 签上写明了记不成的（空正文、没写做什么、日期签选了以后的日子去落笔或打卡……）：界面上按钮已变灰，这里再拦一道
        if let problem = result.problem { throw Problem(problem) }
        switch result.intent {
        case .diary, .note, .review:
            let j = result.journal
            // 只写了前缀、标签或日期：没有要记的话（界面上按钮已变灰，这里再拦一道，免得空篇也加修为）
            guard !j.body.isEmpty else { throw Problem("写上要记的话") }
            let entry = JournalEntry(kind: j.kind, body: j.body, dateKey: j.day.key)
            // 补记往日的不写时刻（写的是“现在”，放在那天不对）
            entry.minute = j.day == .today() ? ClockTime.minutes(of: Date()) : nil
            entry.mood = j.kind == .diary ? mood : nil
            entry.period = j.kind == .review ? ReviewPeriod.day.rawValue : ""
            entry.tags = j.tags
            context.insert(entry)
            DataStore.save(context)
            return .journal(uid: entry.uid)
        case .expense:
            guard let e = result.expense else { throw Problem("没认出金额") }
            let row = ManualExpense.transaction(day: e.day, cents: e.cents, category: category ?? e.category,
                                                description: e.description, note: e.note, reason: "随手记")
            _ = try FinanceService.mutate(context) { $0.transactions.append(row) }
            return .expense(id: row.id)
        case .checkin:
            guard let c = result.checkin, habits.indices.contains(c.habit) else { throw Problem("没认出是哪项功课") }
            return checkin(c, habit: habits[c.habit], context: context, effects: effects)
        case .event:
            guard let e = result.event, !e.title.isEmpty else { throw Problem("写上要做什么") }
            let event = ScheduleEvent(title: e.title, dateKey: e.day.key)
            event.startMinute = e.start
            event.endMinute = e.start == nil ? nil : e.end
            context.insert(event)
            DataStore.save(context)
            return .event(event.persistentModelID)
        }
    }

    /// 打卡：数量型按当天已记的现算（加上这句的，没写数量记满），只打卡的功课没打过才打（打过再点就是取消）；
    /// 备注接在这条打卡原有的备注后面
    private static func checkin(_ c: QuickParse.Checkin, habit: Habit, context: ModelContext, effects: EffectsCenter) -> Record {
        let existing = HabitDayLogs(day: c.day, context: context).log(of: habit)
        let before = existing.map(LogSnapshot.init)
        let all = CultivationModel.existing(for: context).map { model in
            model.refresh()
            return model.habits
        } ?? context.allHabits()
        let config = context.all(AppSettings.self).first?.cultivation ?? CultivationConfig()
        if let target = HabitQuantity.target(habit, atLog: existing?.targetAtLog) {
            let had = existing?.quantity ?? 0
            let quantity = c.added.map { had + $0 } ?? max(had, target)
            HabitActions.setQuantity(habit, on: c.day, quantity: quantity, context: context, effects: effects, allHabits: all, config: config)
        } else if existing?.completed != true {
            HabitActions.toggle(habit, on: c.day, context: context, effects: effects, allHabits: all, config: config)
        }
        if !c.note.isEmpty, let log = HabitDayLogs(day: c.day, context: context).log(of: habit) {
            log.notes = log.notes.isEmpty ? c.note : log.notes + "；" + c.note
            DataStore.save(context)
        }
        return .checkin(habit: habit.persistentModelID, day: c.day, before: before)
    }

    /// 撤销：修行录删掉这一篇（修为跟着扣回）、记账删掉这笔、打卡恢复改之前的那条（含数量与备注）、日程删掉
    static func undo(_ record: Record, context: ModelContext, effects: EffectsCenter) throws {
        switch record {
        case .none:
            return
        case .journal(let uid):
            let found = try? context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate<JournalEntry> { $0.uid == uid }))
            guard let entry = found?.first else { throw Problem("这一篇已经不在了") }
            context.delete(entry)
            DataStore.save(context)
        case .expense(let id):
            _ = try FinanceService.mutate(context) { try FinanceEngine.deleteTransaction(in: &$0, id: id) }
        case .event(let id):
            guard let event = context.model(for: id) as? ScheduleEvent, !event.isDeleted else { throw Problem("这条日程已经不在了") }
            context.delete(event)
            DataStore.save(context)
        case .checkin(let id, let day, let before):
            guard let habit = context.model(for: id) as? Habit, !habit.isDeleted else { throw Problem("这项功课已经不在了") }
            CultivationService.withGain(on: day, dateKey: day.key, context: context, effects: effects) {
                let log = HabitDayLogs(day: day, context: context).log(of: habit)
                if let before {
                    let target = log ?? {
                        let created = HabitLog(dateKey: day.key)
                        context.insert(created)
                        created.habit = habit
                        return created
                    }()
                    target.completed = before.completed
                    target.quantity = before.quantity
                    target.durationMinutes = before.durationMinutes
                    target.targetAtLog = before.targetAtLog
                    target.notes = before.notes
                    target.updatedAt = before.updatedAt
                } else if let log {
                    log.habit = nil
                    context.delete(log)
                }
                habit.updatedAt = Date()
                DataStore.save(context)
            }
            CultivationModel.existing(for: context)?.refresh()
        }
    }
}

/// 随手记“记账”的金额框：外观与 AmountField 一样（“$”加输入框，聚焦时描边转金），焦点由随手记自己管——
/// 切到“记账”时光标先落在这里。不套 .yunshan 输入框样式：样式里自带一层 .focused，两层叠着程序控制不了焦点
private struct QuickAmountBox: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        let on = focus.wrappedValue
        HStack(spacing: 6) {
            Text("$").font(Theme.money(TypeSize.body, .semibold)).foregroundStyle(Theme.inkSoft)
            TextField("", text: $text, prompt: Text("金额"))
                .textFieldStyle(.plain)
                .focused(focus)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.paper.opacity(0.6), in: shape)
                .overlay(shape.strokeBorder(on ? Theme.gold.opacity(0.6) : Theme.line, lineWidth: on ? 1.3 : 1))
        }
    }
}

enum QuickCaptureKeys {
    static let hotKeyError = "quick.hotKeyError"
}

/// 随手记浮窗：全局快捷键唤出，居中浮在所有窗口之上，按 Esc 或写完后自动收起。
@MainActor
final class QuickCapturePanel {
    static let shared = QuickCapturePanel()
    private var panel: NSPanel?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// 唤出浮窗前在前台的别的应用：收起后把焦点还给它
    private var previousApp: NSRunningApplication?
    var container: ModelContainer?

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        /// 浮窗自己做主窗口：激活本应用时只把浮窗带到前面，不把主窗口也拉到当前应用之上
        override var canBecomeMain: Bool { true }
    }

    func toggle() {
        if let panel, panel.isVisible { close() } else { show() }
    }

    func show() {
        guard let container else { return }
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                             backing: .buffered, defer: false)
        // 只收起“自己”这一个浮窗：保存后延迟收起时，用户可能已经又唤出了一个新的
        let view = QuickCaptureView { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.close()
        }
            .modelContainer(container)
            // 浮窗是自己建的窗口，不在 APTApp 的场景里：偏好设置（随手记草稿）也要自己注入，见 AppPreferences
            .defaultAppStorage(AppPreferences.defaults)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Theme.gold.opacity(0.4)))
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        panel.setContentSize(host.frame.size)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - host.frame.width / 2, y: screen.midY + screen.height * 0.12))
        }
        // 记下当时在前台的应用（不是本应用时），收起后回到它
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = NSApp.isActive || front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        self.panel?.close()
        self.panel = panel
        // 先让浮窗成为主窗口与键盘窗口，再激活本应用：激活只带出主窗口与键盘窗口，也就是浮窗本身。
        // 仍然激活应用，保证输入法、⌘↩ 与类别弹出菜单都照常工作。
        panel.makeKeyAndOrderFront(nil)
        panel.makeMain()
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        guard let panel else { return }
        // 浮窗还是当前焦点（期间没有自己点进主窗口、也没切去别的应用）
        let wasFocused = NSApp.isActive && (NSApp.keyWindow == nil || NSApp.keyWindow === panel)
        panel.orderOut(nil)
        self.panel = nil
        // 唤出前在用别的应用：收起后回到那个应用
        if wasFocused, let previous = previousApp, !previous.isTerminated {
            previous.activate(options: [])
        }
        previousApp = nil
    }

    /// 全局热键的组合键（一览里的“随手记”，默认 ⌥⌘J）
    static var hotKeyCombo: KeyCombo {
        KeyBindingLog.note(.quickCapture)
        return KeyCommand.quickCapture.combo
    }

    /// 组合键换成 Carbon 热键的按键码与修饰键（字母键；认不出时 nil）
    static func carbonHotKey(for combo: KeyCombo) -> (code: UInt32, modifiers: UInt32)? {
        let letters: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
            "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
            "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
            "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        ]
        guard case .character(let c) = combo.key, let code = letters[c], !combo.mods.isEmpty else { return nil }
        var modifiers = 0
        if combo.mods.contains(.command) { modifiers |= cmdKey }
        if combo.mods.contains(.option) { modifiers |= optionKey }
        if combo.mods.contains(.shift) { modifiers |= shiftKey }
        if combo.mods.contains(.control) { modifiers |= controlKey }
        return (UInt32(code), UInt32(modifiers))
    }

    /// 注册全局快捷键 ⌥⌘J（Carbon 热键，不需要辅助功能权限；组合键登记在 KeyCommand.quickCapture）。返回是否注册成功；失败时记日志，并在随手记里提示。
    @discardableResult
    func registerHotKey() -> Bool {
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { QuickCapturePanel.shared.toggle() }
                return noErr
            }, 1, &spec, nil, &handler)
            guard status == noErr else {
                handler = nil
                reportHotKeyFailure("APT 随手记：安装快捷键处理失败（OSStatus \(status)）")
                return false
            }
        }
        guard hotKey == nil else { return true }
        let combo = Self.hotKeyCombo
        guard let key = Self.carbonHotKey(for: combo) else {
            reportHotKeyFailure("APT 随手记：\(combo.display) 不是能注册的全局热键")
            return false
        }
        let id = EventHotKeyID(signature: OSType(0x4150_5451), id: 1)   // 'APTQ'
        let status = RegisterEventHotKey(key.code, key.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr, hotKey != nil else {
            hotKey = nil
            reportHotKeyFailure("APT 随手记：注册 \(combo.display) 失败（OSStatus \(status)），可能已被其他应用占用")
            return false
        }
        AppPreferences.defaults.removeObject(forKey: QuickCaptureKeys.hotKeyError)
        return true
    }

    private func reportHotKeyFailure(_ log: String) {
        NSLog("%@", log)
        AppPreferences.defaults.set("全局快捷键 \(Self.hotKeyCombo.display) 没能注册（可能被其他应用占用），请从菜单栏的笔形图标随手记。",
                                    forKey: QuickCaptureKeys.hotKeyError)
    }
}
