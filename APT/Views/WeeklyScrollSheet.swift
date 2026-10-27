import SwiftUI
import SwiftData
import AppKit

/// 七日小卷（#11）：一周的小结。修行录“卷中气象”标题右侧“七日小卷 →”打开；`AppRouter.weeklyScroll` 为真时，在当前页的那一页打开并清零。
/// 默认本周（周一到今天），周一 12:00 之前默认上一整周；卷底可翻上一周 / 下一周（不超过本周）。
/// 各节没数据就不显示、节号按出现的重排：自己的话、心境七日、功课、灵石、一条洞见、上次许下的下一步（#14，只读列出）；
/// 卷尾“存为周复盘草稿”“请 AI 写一封周信”。首页周日晚的纸笺也打开这一卷（AppRouter.weeklyScroll，首页在当前页时由首页接）。
/// 取数只按两周的 dateKey 取修行录；功课统计借修为模型（CultivationModel）；花费用 FinanceService.load（有解码缓存）后按日期筛。
/// 口径全在 Core/WeeklyDigest（CoreCheck 覆盖）。打开时纸面从 0.94 展开、各节错峰浮现；动效关着时直接出现。
struct WeeklyScrollSheet: View {
    /// 整卷铺开、不放进滚动区（离屏渲染整幅长图用）
    var fullLength = false
    /// 在点开读全文的弹窗里删掉一篇：交给打开小卷的那一页删（修行录：先拍快照，页面底部约 8 秒“撤销删除”），小卷随之收起。
    /// 没交代时走首页旧笔新读同一套撤销（DashboardLookBackUndo）——总之不会删了找不回
    var onDelete: ((JournalEntry) -> Void)?
    /// 整卷空着时的主按钮“写下一句”：交给打开小卷的那一页（修行录：收起小卷后光标落进落笔框）；没交代时收起后找主窗口的落笔框
    var onCompose: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.spiritMotion) private var motion
    /// 有没有人在看（闲满 3 分钟、主窗口被挡住时为假）：背景的云与光点跟着停，与页面底一致（#20）
    @Environment(\.someoneWatching) private var watched
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(EffectsCenter.self) private var effects: EffectsCenter?
    @State private var week: WeeklyDigest.Week
    @State private var content: WeeklyScrollContent?
    /// 最早一条记录（落笔、打卡、功课开始、账目）那天：“‹ 上一周”翻到它所在的那一周为止；一条都没有时不能往前翻
    @State private var earliest: LocalDay?
    @State private var reading: JournalEntry?
    @State private var askDraft = false
    @State private var copied = false
    @State private var shown = false

    /// 默认本周 / 周一中午以前看上一周；week 传了就看那一周（自检、渲染用）
    init(week: WeeklyDigest.Week? = nil, fullLength: Bool = false,
         onDelete: ((JournalEntry) -> Void)? = nil, onCompose: (() -> Void)? = nil) {
        self.fullLength = fullLength
        self.onDelete = onDelete
        self.onCompose = onCompose
        let now = Date()
        let minute = SkyTime.fixedMinute.map { Int($0) } ?? ClockTime.minutes(of: now)
        _week = State(initialValue: week ?? WeeklyDigest.defaultWeek(today: LocalDay(date: now), minute: minute))
    }

    private var animate: Bool { motion && !reduceMotion && !RenderMode.offscreen }

    var body: some View {
        Group {
            if fullLength {
                VStack(spacing: 14) {
                    scroll
                    actions.padding(.horizontal, 26).padding(.bottom, 22)
                }
                .frame(width: 620)
            } else {
                // 卷尾的两个按钮钉在底下，卷再长也不用滚到底才看得到
                VStack(spacing: 0) {
                    ScrollView { scroll }
                        .scrollIndicators(.hidden)
                    actions
                        .padding(.horizontal, 26)
                        .padding(.top, 12)
                        .padding(.bottom, 18)
                        .background(alignment: .top) {
                            Rectangle().fill(Theme.gold.opacity(0.22)).frame(height: 0.75)
                        }
                }
                .frame(width: 620)
                .frame(minHeight: 520, idealHeight: 760, maxHeight: .infinity)
            }
        }
        .background { WeeklyScrollBackdrop(animated: animate && watched) }
        .foregroundStyle(Theme.text)
        .font(.ysBody)
        .buttonStyle(.yunshan)
        .onAppear {
            earliest = WeeklyScrollContent.earliestDay(context: context)
            reload()
            if animate {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { shown = true }
            } else {
                shown = true
            }
        }
        .onChange(of: week) { _, _ in
            // 剪贴板里是上一张卷的那句话（带那一周的日期）：翻了周就不再说“已复制”
            copied = false
            reload()
        }
        // 读全文时可能修订了、删掉了这一篇：关掉阅读弹窗就重取，卷上不留已删的那句
        .sheet(item: $reading, onDismiss: reload) { entry in
            JournalEditSheet(entry: entry, startReadOnly: true) { deleted in deleteFromReading(deleted) }
        }
        .confirmationDialog("落笔框里有一篇没写完的草稿", isPresented: $askDraft) {
            Button("接在后面") { saveDraft(.append) }
            Button("替换", role: .destructive) { saveDraft(.replace) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("接在后面：这一周的素材接在原稿之后，原稿一字不动。\n替换：原稿换成这一周的复盘，替换后原稿找不回。")
        }
    }

    private func reload() {
        content = WeeklyScrollContent.load(week: week, context: context)
    }

    /// 阅读弹窗里点了删除：小卷收起（页面底部的“撤销删除”才点得到），删除交给打开小卷的那一页；没交代就走首页那套撤销
    private func deleteFromReading(_ entry: JournalEntry) {
        dismiss()
        Self.delete(entry, onDelete: onDelete, context: context, effects: effects)
    }

    /// 删除的去处（自检直接调）：有 onDelete 交给它；没有就拍快照删、给约 8 秒撤销（DashboardLookBackUndo），不会直接删了找不回
    @MainActor
    static func delete(_ entry: JournalEntry, onDelete: ((JournalEntry) -> Void)?, context: ModelContext, effects: EffectsCenter?,
                       undo: DashboardLookBackUndo? = nil) {
        if let onDelete { onDelete(entry) } else { (undo ?? .shared).delete(entry, context: context, effects: effects) }
    }

    // MARK: 卷

    private var scroll: some View {
        VStack(spacing: 18) {
            header
            paper
                .scaleEffect(shown ? 1 : 0.94, anchor: .top)
                .opacity(shown ? 1 : 0)
            pager
        }
        .padding(.horizontal, 26)
        .padding(.top, 30)
        .padding(.bottom, fullLength ? 0 : 16)
    }

    private var header: some View {
        VStack(spacing: 7) {
            SceneryImage(name: "yunshan-ornament-scroll-v1")
                .frame(width: 50, height: 50)
                .background(SoftGlow(color: Theme.gold.opacity(0.28)).frame(width: 120, height: 110))
            Text("——　七日小卷").font(Theme.songti(TypeSize.caption, .medium)).tracking(4).foregroundStyle(Theme.gold)
            CardTitle<EmptyView>.styled(week.title, size: TypeSize.title, tracking: 2).foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            Text("一周功行，一卷收之").font(Theme.songti(TypeSize.callout)).tracking(3).foregroundStyle(Theme.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// 纸面：各节依次排下，节与节之间一道淡金发丝线
    private var paper: some View {
        let sections = content.map(sectionList) ?? []
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    Rectangle().fill(Theme.gold.opacity(0.22)).frame(height: 0.75).padding(.vertical, 16)
                }
                VStack(alignment: .leading, spacing: 10) {
                    WeeklySectionTitle(order: index, title: section.title)
                    section.view
                }
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 10)
                .animation(animate ? .easeOut(duration: 0.5).delay(0.18 + 0.09 * Double(index)) : nil, value: shown)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Theme.card.opacity(scheme == .dark ? 0.86 : 0.94))
                .overlay(alignment: .top) {
                    LinearGradient(colors: [Theme.goldSoft.opacity(scheme == .dark ? 0.35 : 0.7), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Theme.gold.opacity(0.32), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.06), radius: 14, y: 6)
    }

    private struct Section: Identifiable {
        var id: String
        var title: String
        var view: AnyView
    }

    private func sectionList(_ c: WeeklyScrollContent) -> [Section] {
        var list: [Section] = [Section(id: "words", title: "自己的话", view: AnyView(quotes(c)))]
        if c.hasEntries { list.append(Section(id: "mood", title: "心境七日", view: AnyView(moods(c)))) }
        if let h = c.habits { list.append(Section(id: "habits", title: "功课", view: AnyView(habits(h)))) }
        if let s = c.spend { list.append(Section(id: "spend", title: "灵石", view: AnyView(spend(s)))) }
        if let i = c.insight { list.append(Section(id: "insight", title: "一条洞见", view: AnyView(insight(i)))) }
        // 放在最后：读完这一周，正好接卷尾的“存为周复盘草稿”去逐条回访
        if let p = c.promise { list.append(Section(id: "promise", title: "上次许下的下一步", view: AnyView(promise(p, blank: c.isBlank)))) }
        return list
    }

    // MARK: 各节

    @ViewBuilder
    private func quotes(_ c: WeeklyScrollContent) -> some View {
        if c.quotes.isEmpty {
            // 本周整卷空着（新手的第一周）多一句这卷怎么写满；过去的空周只说“那一周没有留下记录。”
            let words = WeeklyDigest.emptyWords(week: week, hasEntries: c.hasEntries, blank: c.isBlank)
            VStack(alignment: .leading, spacing: 6) {
                Text(words.line).font(Theme.songti(TypeSize.body)).foregroundStyle(Theme.inkSoft)
                if let hint = words.hint {
                    Text(hint).font(.ysCaption).foregroundStyle(Theme.inkSoft)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(c.quotes, id: \.uid) { quote in
                    WeeklyQuoteRow(quote: quote, today: week.today) {
                        reading = c.entries[quote.uid]
                    }
                }
            }
        }
    }

    private func moods(_ c: WeeklyScrollContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(c.marks, id: \.day) { item in
                    WeeklyMoodCell(day: item.day, mark: item.mark)
                }
            }
            Text(WeeklyDigest.moodTally(c.marks)).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
        }
    }

    private func habits(_ h: WeeklyDigest.HabitWeek) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(WeeklyDigest.habitHeadline(h, week: week)).font(Theme.songti(TypeSize.body, .semibold)).foregroundStyle(Theme.ink)
            WeeklyRateBars(rate: h.rate, previous: h.previousRate, label: week.selfName, previousLabel: week.priorName, animate: animate, shown: shown)
            if let best = h.steadiest {
                Label { Text("最稳：\(best.title) \(best.fraction)").monospacedDigit() } icon: {
                    Image(systemName: "leaf.fill").foregroundStyle(Theme.jade)
                }
                .font(.ysCallout)
            }
            if let tend = h.tending {
                Label { Text("可再护持：\(tend.title) \(tend.fraction)").monospacedDigit() } icon: {
                    Image(systemName: "drop").foregroundStyle(Theme.inkSoft)
                }
                .font(.ysCallout)
                .foregroundStyle(Theme.inkSoft)
            }
        }
    }

    private func spend(_ s: WeeklyDigest.Spend) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(WeeklyDigest.spendHeadline(s, week: week)).font(.ysCallout).monospacedDigit()
            if let note = WeeklyDigest.spendNote(s, week: week) {
                Label(note, systemImage: "info.circle").font(.ysCaption).foregroundStyle(Theme.inkSoft)
            }
        }
    }

    private func insight(_ i: WeeklyDigest.Note) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.gold)
            VStack(alignment: .leading, spacing: 4) {
                Text(i.text).font(.ysCallout).fixedSize(horizontal: false, vertical: true)
                Text(i.basis).font(.ysMicro).foregroundStyle(Theme.inkSoft)
            }
        }
    }

    /// 上次许下的下一步：出自哪一篇、逐条只读列出（不打勾；回访在存为周复盘草稿后的素材里点）
    private func promise(_ p: ReviewThread.Promise, blank: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("出自 \(p.label)").font(.ysCaption).foregroundStyle(Theme.inkSoft)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(p.steps, id: \.self) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("·").font(Theme.songti(TypeSize.body, .semibold)).foregroundStyle(Theme.gold)
                        Text(step).font(.ysCallout).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !blank {
                Text("存为周复盘草稿后，可在本期素材里逐条回访：做到了 · 没做到 · 改主意了。")
                    .font(.ysMicro).foregroundStyle(Theme.inkSoft)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 卷尾

    /// 翻周：‹ 上一周　下一周 ›（往前翻到最早一条记录所在的那一周为止，往后不超过本周）；两头都翻不动（全新使用者）时不出这一行
    @ViewBuilder
    private var pager: some View {
        let canGoBack = week.hasPrevious(earliest: earliest)
        if canGoBack || week.next != nil {
            HStack {
                Button { week = week.previous } label: { Text("‹ 上一周") }
                    .buttonStyle(.inlineAction())
                    .disabled(!canGoBack)
                    .help(canGoBack ? "翻到 \(week.previous.compactLabel)" : "再往前没有记录了")
                Spacer()
                Button { if let next = week.next { week = next } } label: { Text("下一周 ›") }
                    .buttonStyle(.inlineAction())
                    .disabled(week.next == nil)
                    .help(week.next == nil ? "已是本周" : "翻到 \(week.next?.compactLabel ?? "")")
            }
            .padding(.horizontal, 4)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button("收起") { dismiss() }.keyCommand(.dialogCancel)
                Spacer(minLength: 8)
                if content?.isBlank == true {
                    // 整卷空着（新手、或翻到没有记录的周）：存周复盘只会得到一份空模板，请 AI 写周信也无从写起；先写下一句。
                    // 说明不点名哪一页：修行录打开时落进修行录的落笔框，首页纸笺打开时落进首页的落笔卡
                    Button { compose() } label: { Label("写下一句", systemImage: "pencil.line") }
                        .buttonStyle(.yunshanPrimary)
                        .help("收起小卷，光标落进落笔框")
                } else {
                    Button { copyPrompt() } label: { Label("请 AI 写一封周信", systemImage: "paperplane") }
                        .help("复制一句话，粘进 Claude Code：AI 读快照写这一周的小结，问你一两个问题后投成一篇周复盘")
                    Button { askOrSave() } label: { Label("存为周复盘草稿", systemImage: "square.and.pencil") }
                        .buttonStyle(.yunshanPrimary)
                        .help("跳到修行录的复盘落笔：四段模板里已插好这周的素材与摘句")
                }
            }
            if copied {
                Label("已复制，到 Claude Code 里粘贴", systemImage: "checkmark.circle")
                    .font(.ysCaption).foregroundStyle(Theme.positive)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity)
            }
        }
    }

    private func copyPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(WeeklyDigest.aiPrompt(week), forType: .string)
        withAnimation(animate ? Motion.standard : nil) { copied = true }
    }

    /// 落笔框已经是这一周的周复盘（上回存过）：不问、不再叠一份，直接回去接着写；
    /// 其余不空的草稿先问接在后面 / 替换 / 取消；空的直接写
    private func askOrSave() {
        if WeeklyDraft.holdsWeek(week) {
            AppRouter.shared.page = .chronicle
            dismiss()
        } else if JournalDraft.isBlank(page: WeeklyDraft.page) {
            saveDraft(.replace)
        } else {
            askDraft = true
        }
    }

    private func saveDraft(_ mode: WeeklyDraft.Mode) {
        WeeklyDraft.write(week: week, quotes: content?.quotes ?? [], context: context, mode: mode)
        AppRouter.shared.page = .chronicle
        dismiss()
    }

    /// 写下一句：收起小卷，光标落进落笔框（修行录自己接；没交代时收起后到主窗口里找落笔框）
    private func compose() {
        if let onCompose {
            onCompose()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { WeeklyCompose.focusMainWindow() }
        }
        dismiss()
    }
}

// MARK: - 写下一句

/// 收起小卷后把光标放进落笔框：主窗口里第一个可编辑的多行文本框就是落笔框（修行录、今日洞府都只有它一个 TextEditor）。
/// 不改落笔卡本身：落笔卡里的 FocusState 会跟着第一响应者同步
@MainActor
enum WeeklyCompose {
    /// 在这个窗口里找到落笔框并让它接住光标；找到了返回 true
    @discardableResult
    static func focus(in window: NSWindow?) -> Bool {
        guard let window, let root = window.contentView, let editor = firstEditor(in: root) else { return false }
        guard window.makeFirstResponder(editor) else { return false }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        // 落笔框在页面上方：滚进视野（页面本身的滚动区在落笔框外面一层）
        editor.enclosingScrollView?.scrollToVisible(editor.enclosingScrollView?.bounds ?? .zero)
        return true
    }

    /// 主窗口（不是浮窗、菜单栏小窗，也不是弹窗）；小卷还没完全收起时稍后再试一次
    static func focusMainWindow(retries: Int = 3) {
        let windows = ([NSApp.keyWindow, NSApp.mainWindow] + NSApp.windows).compactMap { $0 }
        let main = windows.first { !($0 is NSPanel) && $0.isVisible && $0.sheetParent == nil && $0.frame.width > 800 }
        if main?.attachedSheet == nil, focus(in: main) { return }
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focusMainWindow(retries: retries - 1) }
    }

    /// 深度优先找第一个可编辑、不是单行输入框字段编辑器、看得见的多行文本框
    static func firstEditor(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor, !text.isHiddenOrHasHiddenAncestor { return text }
        for sub in view.subviews { if let hit = firstEditor(in: sub) { return hit } }
        return nil
    }
}

// MARK: - 取数

/// 小卷一次取好的东西（换周时重取）
struct WeeklyScrollContent {
    var entries: [String: JournalEntry]
    var hasEntries: Bool
    var quotes: [WeeklyDigest.Quote]
    var marks: [(day: LocalDay, mark: WeeklyDigest.MoodMark)]
    var habits: WeeklyDigest.HabitWeek?
    var spend: WeeklyDigest.Spend?
    var insight: WeeklyDigest.Note?
    /// 上次许下的下一步（这周一之前、或周一当天写的最近一篇**周复盘**的【下一步】；日省、月复盘不算；隔了 35 天以上的不翻出来）
    var promise: ReviewThread.Promise? = nil

    /// 整卷没有任何数据（没落笔、没功课、没花费）：主按钮换成“写下一句”
    var isBlank: Bool { !hasEntries && habits == nil && spend == nil }

    /// 最早一条记录那天：修行录、打卡各按日期升序只取 1 条，功课取最早的开始日（修为模型已缓存），账目在已解码的账簿里找最早一笔。
    /// 一条都没有时 nil（小卷不能往前翻）
    @MainActor
    static func earliestDay(context: ModelContext) -> LocalDay? {
        var firstEntry = FetchDescriptor<JournalEntry>(sortBy: [SortDescriptor(\.dateKey)])
        firstEntry.fetchLimit = 1
        var firstLog = FetchDescriptor<HabitLog>(sortBy: [SortDescriptor(\.dateKey)])
        firstLog.fetchLimit = 1
        var days: [LocalDay] = []
        if let key = (try? context.fetch(firstEntry))?.first?.dateKey, let day = LocalDay(key: key) { days.append(day) }
        if let key = (try? context.fetch(firstLog))?.first?.dateKey, let day = LocalDay(key: key) { days.append(day) }
        let model = CultivationModel.shared(for: context)
        model.refresh()
        if let start = model.rows.map(\.stats.spec.startDay).min() { days.append(start) }
        if let ledger = try? FinanceService.load(context),
           let key = ledger.transactions.lazy.map(\.date).min(), let day = LocalDay(key: key) {
            days.append(day)
        }
        return days.min()
    }

    @MainActor
    static func load(week: WeeklyDigest.Week, context: ModelContext) -> WeeklyScrollContent {
        // 修行录：只取上周一到这周已过的最后一天（5 年数据也只取两周）
        let range = WeeklyDigest.fetchRange(week)
        let from = range.from.key, to = range.to.key
        let fetched = (try? context.fetch(FetchDescriptor<JournalEntry>(
            predicate: #Predicate { $0.dateKey >= from && $0.dateKey <= to },
            sortBy: [SortDescriptor(\.dateKey), SortDescriptor(\.createdAt)]))) ?? []
        let records = fetched
            .map { e in
                RecordEntry(uid: e.uid, day: e.day, minute: e.minute, kind: e.kindValue, title: e.title, body: e.body,
                            mood: e.mood, tags: e.tags, pinned: e.pinned, period: e.period)
            }
            .sorted { ($0.day, $0.minute ?? 24 * 60) < ($1.day, $1.minute ?? 24 * 60) }
        let thisWeek = records.filter { $0.day >= week.monday && $0.day <= week.last }
        var byUid: [String: JournalEntry] = [:]
        for e in fetched { byUid[e.uid] = e }

        // 功课：借修为模型已缓存的统计（未归档的功课，按功课页的次序）
        let model = CultivationModel.shared(for: context)
        model.refresh()
        let habits = WeeklyDigest.habits(model.rows.map { ($0.habit.title, $0.stats) }, week: week)

        // 灵石：账簿有解码缓存；按日期筛这一周
        let ledger = try? FinanceService.load(context)
        let spend = ledger.flatMap { WeeklyDigest.spend($0.transactions, sources: $0.sources, week: week) }

        // 洞见：先看这一周自己的正向变化（比前一周多动笔、心境更明朗、功课完成率更高）；
        // 只有看本周时才退回卷中洞见（近 90 日，按数据戳缓存）里正向的一条——翻到过去的周不说那一周之后的事
        var insight: WeeklyDigest.Note?
        if !records.isEmpty || habits != nil || spend != nil {
            let own = WeeklyDigest.weekNote(records, habits: habits, week: week)
            let rolling = own == nil && week.isCurrent ? AIDigest.digest(context: context, today: week.today).insights : []
            insight = WeeklyDigest.insight(own: own, rolling: rolling, week: week, windowDays: LongTermDigest.windowDays)
        }
        // 上次许下的下一步：只认周复盘（latest 找不到同周期时会退回任意复盘，这里不要日省、月复盘），只取最近几十篇复盘
        // （ReviewThread.latest）；太久以前的不翻出来
        let promise = ReviewThread.latest(before: WeeklyDigest.promiseBefore(week), period: .week, context: context, today: week.today)
            .flatMap { WeeklyDigest.promiseFits(period: $0.period, day: $0.day, week: week) ? $0 : nil }
        return WeeklyScrollContent(entries: byUid, hasEntries: !thisWeek.isEmpty,
                                   quotes: WeeklyDigest.quotes(thisWeek, week: week),
                                   marks: WeeklyDigest.moodMarks(thisWeek, week: week),
                                   habits: habits, spend: spend, insight: insight, promise: promise)
    }
}

// MARK: - 存为周复盘草稿

/// 把一周的素材写成修行录落笔框的草稿（draft.chronicle.*）：类型复盘、周期周、补记日期 = 这周最后一天（不晚于今天）、
/// 标题“10月19日–25日 周复盘”、正文 = 四段模板，【所悟】之前插好本期素材（ReviewMaterial）与〔本周摘句〕。
/// 落笔框里已有不空的草稿时由调用方先问：接在后面（原标题不空就留着；原稿是别的周期的复盘时周期、日期、标题都不动）或替换。
/// 落笔框里已经是这一周的周复盘时不再写（holdsWeek）。
@MainActor
enum WeeklyDraft {
    enum Mode { case replace, append }
    static let page = "chronicle"

    /// 落笔框草稿现在的头部（偏好里没有的按落笔框的默认：类型日记、周期周、补记日期今天）
    static func head(defaults: UserDefaults = AppPreferences.defaults) -> WeeklyDigest.DraftHead {
        func value(_ field: String) -> String? { defaults.string(forKey: JournalDraft.key(page, field)) }
        return WeeklyDigest.DraftHead(kind: value("kind") ?? JournalKind.diary.rawValue, period: value("period") ?? ReviewPeriod.week.rawValue,
                                      day: value("day"), title: value("title") ?? "")
    }

    /// 落笔框里已经是这一周的周复盘草稿（上回存过、还没写完）
    static func holdsWeek(_ week: WeeklyDigest.Week, defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        WeeklyDigest.isSameWeekDraft(head(defaults: defaults), week: week)
    }

    static func body(week: WeeklyDigest.Week, quotes: [WeeklyDigest.Quote], context: ModelContext) -> String {
        let lines = ReviewMaterial.lines(context: context, first: week.monday, last: week.last)
        let label = ReviewMaterial.range(period: .week, anchor: week.last, today: week.today).label
        var block = ReviewMaterial.block(lines: lines, label: label)
        let picked = WeeklyDigest.quoteBlock(quotes, today: week.today)
        if !picked.isEmpty { block += "\n\n" + picked }
        return ReviewMaterial.insert(block, into: ReviewPeriod.template)
    }

    static func write(week: WeeklyDigest.Week, quotes: [WeeklyDigest.Quote], context: ModelContext, mode: Mode,
                      defaults: UserDefaults = AppPreferences.defaults) {
        func key(_ field: String) -> String { JournalDraft.key(page, field) }
        let text = body(week: week, quotes: quotes, context: context)
        let title = WeeklyDigest.draftTitle(week)
        var next = WeeklyDigest.DraftHead(kind: JournalKind.review.rawValue, period: ReviewPeriod.week.rawValue,
                                          day: WeeklyDigest.draftDay(week).key, title: title)
        switch mode {
        case .replace:
            defaults.set(text, forKey: key("text"))
            defaults.set("", forKey: key("tags"))
            defaults.removeObject(forKey: key("mood"))
        case .append:
            let oldText = defaults.string(forKey: key("text")) ?? ""
            // 原稿是“复盘 · 月”这类别的周期：周期、补记日期、标题都按原稿，只把这一周的素材接在后面
            next = WeeklyDigest.appendedHead(head(defaults: defaults), week: week)
            // 原文只是空白模板时不再叠一份模板
            defaults.set(JournalDraft.isBlankBody(oldText, defaults: defaults) ? text : WeeklyDigest.appended(oldText, text), forKey: key("text"))
        }
        defaults.set(next.title, forKey: key("title"))
        defaults.set(next.period, forKey: key("period"))
        if let day = next.day { defaults.set(day, forKey: key("day")) } else { defaults.removeObject(forKey: key("day")) }
        // 类型最后写：落笔框看到类型变成复盘时正文已经不空，不会再套一份空白模板
        defaults.set(next.kind, forKey: key("kind"))
    }
}

// MARK: - 部件

/// 节标题：“其一 · 自己的话”（节号按出现的次序）
private struct WeeklySectionTitle: View {
    var order: Int
    var title: String
    private static let numerals = ["其一", "其二", "其三", "其四", "其五", "其六"]

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(LinearGradient(colors: [Theme.gold.opacity(0.9), Theme.gold.opacity(0.2)], startPoint: .top, endPoint: .bottom))
                .frame(width: 1.5, height: 15)
            Text(Self.numerals[min(order, Self.numerals.count - 1)]).font(Theme.songti(TypeSize.callout, .semibold)).foregroundStyle(Theme.gold)
            Text("·").foregroundStyle(Theme.gold.opacity(0.7))
            Text(title).font(Theme.songti(TypeSize.callout, .semibold)).tracking(1).foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 一句摘句：宋体引文，右下小字日期；点开只读全文。悬停泛起一层淡金
private struct WeeklyQuoteRow: View {
    var quote: WeeklyDigest.Quote
    var today: LocalDay
    var onOpen: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .trailing, spacing: 4) {
                Text("「\(quote.text)」")
                    .font(Theme.songti(15, .medium))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(quote.day.label(relativeTo: today)) \(quote.day.weekdayName)")
                    .font(.ysMicro).monospacedDigit().foregroundStyle(Theme.inkSoft)
            }
            .padding(.leading, 12)
            .padding(.vertical, 6)
            .padding(.trailing, 8)
            .background {
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .fill(Theme.goldSoft.opacity(hover ? 0.55 : 0))
            }
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.gold.opacity(hover ? 0.9 : 0.55)).frame(width: 2).padding(.vertical, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("点开读全文")
        .accessibilityLabel("\(quote.text)，\(quote.day.shortLabel)")
    }
}

/// 心境七日的一格：心境图标 + 按心境深浅的淡金底（与卷中气象同一套金色，不用朱砂）；写了没记心境画墨点；没写只描边；还没到的虚线
private struct WeeklyMoodCell: View {
    var day: LocalDay
    var mark: WeeklyDigest.MoodMark

    var body: some View {
        VStack(spacing: 5) {
            Text(LocalDay.weekdayShortNames[day.weekdayIndex]).font(.ysMicro).foregroundStyle(Theme.inkSoft)
            ZStack {
                switch mark {
                case .mood(let value):
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.gold.opacity(0.1 + 0.08 * Double(value)))
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.gold.opacity(0.45), lineWidth: 0.75)
                    Image(systemName: Mood.symbol(value)).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink.opacity(0.85))
                case .ink:
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line, lineWidth: 1)
                    Circle().fill(Theme.ink.opacity(0.6)).frame(width: 6, height: 6)
                case .blank:
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line, lineWidth: 1)
                case .today:
                    // 今天还没过完：淡金描边、底下写“今天”，不算“未记”
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.goldSoft.opacity(0.35))
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.gold.opacity(0.6), lineWidth: 1)
                case .future:
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.line.opacity(0.7), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                }
            }
            .frame(height: 40)
            .frame(maxWidth: 58)
            switch mark {
            case .mood(let value): Text(Mood.label(value)).font(.ysMicro).foregroundStyle(Theme.ink)
            case .today: Text("今天").font(.ysMicro).foregroundStyle(Theme.gold)
            default: Text(verbatim: " ").font(.ysMicro)
            }
        }
        .frame(maxWidth: .infinity)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }

    private var help: String {
        let head = "\(day.shortLabel) \(day.weekdayName)"
        switch mark {
        case .mood(let value): return "\(head) · \(Mood.label(value))"
        case .ink: return "\(head) · 写了，没记心境"
        case .blank: return "\(head) · 没有落笔"
        case .today: return "\(head) · 今天，还没落笔"
        case .future: return "\(head) · 还没到"
        }
    }
}

/// 这一周对前一周的两道细条：这一周金色（打开时从左长出来），前一周淡墨。
/// 标签与正文同一套叫法：本周 / 上周；看过去的周时 那一周 / 前一周
private struct WeeklyRateBars: View {
    var rate: Double
    var previous: Double?
    var label: String
    var previousLabel: String
    var animate: Bool
    var shown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            bar(label, rate, fill: AnyShapeStyle(LinearGradient(colors: [Theme.gold.opacity(0.65), Theme.gold], startPoint: .leading, endPoint: .trailing)))
            if let previous {
                bar(previousLabel, previous, fill: AnyShapeStyle(Theme.inkSoft.opacity(0.35)))
            }
        }
        .accessibilityHidden(true)
    }

    /// 两道细条的标签同宽，条才对齐：两个字 26，三个字（那一周 / 前一周）38
    private var labelWidth: CGFloat { max(label.count, previousLabel.count) > 2 ? 38 : 26 }

    private func bar(_ title: String, _ value: Double, fill: AnyShapeStyle) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.ysMicro).foregroundStyle(Theme.inkSoft).lineLimit(1).frame(width: labelWidth, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line.opacity(0.6))
                    Capsule().fill(fill)
                        .frame(width: max(4, geo.size.width * CGFloat(min(1, max(0, value))) * (shown ? 1 : 0)))
                        .animation(animate ? .easeOut(duration: 0.8).delay(0.4) : nil, value: shown)
                }
            }
            .frame(height: 5)
            Text(RecordStats.percent(value)).font(.ysMicro).monospacedDigit().foregroundStyle(Theme.inkSoft).frame(width: 34, alignment: .trailing)
        }
    }
}

/// 小卷的底：宣纸 / 墨夜底色，上方一抹淡金，飘雾与灵气光点（动效关着时静止），四周压一圈暗角
private struct WeeklyScrollBackdrop: View {
    var animated: Bool
    @Environment(\.colorScheme) private var scheme
    private static let vignette = Color(red: 0.03, green: 0.07, blue: 0.06)

    var body: some View {
        ZStack {
            Theme.paper
            LinearGradient(colors: [Theme.goldSoft.opacity(scheme == .dark ? 0.25 : 0.55), .clear], startPoint: .top, endPoint: .center)
            MistDrift(animated: animated)
            SpiritField(count: 16, animated: animated, meteors: scheme == .dark)
            RadialGradient(colors: [.clear, Self.vignette.opacity(scheme == .dark ? 0.4 : 0.07)], center: .center, startRadius: 240, endRadius: 620)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
