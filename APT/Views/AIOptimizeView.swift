import SwiftUI
import SwiftData
import AppKit

/// 问 AI 的几种“问法”：各自决定带上哪些记录、看多长时间、怎么提问。
enum AskPreset: String, CaseIterable, Identifiable {
    case week, month, mood, money, plan, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "周复盘"
        case .month: "月度复盘"
        case .mood: "情绪与精力"
        case .money: "消费建议"
        case .plan: "目标与安排"
        case .custom: "自定义"
        }
    }

    var subtitle: String {
        switch self {
        case .week: "本周所得、所失、所悟与下一步"
        case .month: "一个月的走向、反复出现的问题"
        case .mood: "心境起伏和作息、习惯有什么关系"
        case .money: "钱花在哪、哪里可以收一收"
        case .plan: "日程、作息、习惯是否服务于目标"
        case .custom: "自己选内容、写提示语"
        }
    }

    var ornament: String {
        switch self {
        case .week: "yunshan-ornament-journal-v1"
        case .month: "yunshan-ornament-scroll-v1"
        case .mood: "yunshan-ornament-lotus-v1"
        case .money: "yunshan-ornament-abacus-v1"
        case .plan: "yunshan-ornament-astrolabe-v1"
        case .custom: "yunshan-ornament-brush-v1"
        }
    }

    var defaultDays: Int {
        switch self {
        case .week: 7
        case .money, .plan: 30
        case .month, .mood, .custom: 30
        }
    }

    var sections: Set<SummarySection> {
        switch self {
        // 六种问法都带“长期趋势与洞察”（一千多字：近 12 个月逐月表 + 近 90 天统计洞察），周复盘也带——AI 才知道“这周比平时如何”
        case .week: [.journal, .habits, .schedule, .finance, .cultivation, .goals, .trends]
        case .month: [.journal, .habits, .finance, .goals, .cultivation, .trends]
        case .mood: [.journal, .habits, .routine, .trends]
        case .money: [.finance, .journal, .profile, .trends]
        case .plan: [.profile, .goals, .schedule, .routine, .habits, .trends]
        case .custom: Set(SummarySection.allCases)
        }
    }

    var preamble: String {
        let tail = "\n请只根据下面的记录推断，不确定的地方直接说明；语气平实，不要空泛的鼓励；用中文回答。"
        switch self {
        case .week:
            return "你是一位真诚、务实的复盘伙伴。下面是我这一周的记录（日记、灵感、复盘、习惯、日程与消费）。请帮我做周复盘：\n1. 所得：这一周做成了什么，哪些值得肯定；\n2. 所失：哪里没做好、精力花在了哪里；\n3. 所悟：从记录里看出的规律（心境、作息、反复出现的问题）；\n4. 下一步：下周最值得做的三件事，每条附理由。" + tail
        case .month:
            return "你是一位真诚、务实的复盘伙伴。下面是我近一个月的记录。请帮我做月度复盘：\n1. 这个月的主线：主要在忙什么，和目标的关系；\n2. 反复出现的模式（好的与不好的）；\n3. 习惯与消费的变化；\n4. 下个月的三条调整建议，每条附理由。" + tail
        case .mood:
            return "你是一位细心的观察者。下面是我的日记（含心境评分）、习惯与作息。请帮我看：\n1. 心境的整体走势和明显的起伏；\n2. 心境与睡眠、作息、习惯、事件之间可能的关联；\n3. 哪些情况下我状态最好、最差；\n4. 两三个具体可试的调整。" + tail
        case .money:
            return "你是一位务实的理财顾问。下面是我的消费概况和相关日记。请帮我看：\n1. 钱主要花在哪里，和上月比有什么变化；\n2. 哪些支出可以收一收，大概能省多少；\n3. 结合我的情况，下个月可以设什么预算；\n4. 只给可执行的建议，不要推荐投资产品。" + tail
        case .plan:
            return SummaryRenderer.defaultPreamble
        case .custom:
            return SummaryRenderer.defaultPreamble
        }
    }

    var reviewPeriod: String {
        switch self {
        case .week: "week"
        case .month: "month"
        default: "event"
        }
    }
}


/// 问道灵枢：从上到下两步。一、想问什么（选问法、回看、复制 / 在 Claude Code 里问 / 导出，预览默认收起）；
/// 二、存下 AI 的建议。“已复制”这类一句话的反馈走窗口顶部的纸色小胶囊（effects.hint），出错时就地显示。
struct AIOptimizeView: View {
    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    @Environment(\.spiritMotion) private var motion
    // SwiftData 每次保存（以及未保存的改动）之后都会重取 @Query、重算 body：refreshKey 随之重新核对条数和最近修改时间，
    // 相关数据一变，摘要就重新生成。以前为此另挂 7 个整表 @Query（修行录 4000 篇一次约 0.4 秒，每次保存都要重取），
    // 现在只做十几次很小的查询（见 refreshKey）。
    @Query private var settingsList: [AppSettings]
    @Query(sort: \AdviceRecord.createdAt, order: .reverse) private var records: [AdviceRecord]

    @AppStorage("ai.preset") private var presetRaw = AskPreset.week.rawValue
    @AppStorage("ai.days") private var days = 7
    @AppStorage("ai.hideIdentity") private var hideIdentity = true
    @AppStorage("ai.excluded") private var excludedRaw = ""
    @State private var focusQuestion = ""
    /// 预览默认收起：想核对内容时再展开
    @State private var showPreview = false
    /// 粘贴进来、还没保存的 AI 回复：切页、重启都不丢，保存后清空
    @AppStorage("draft.ai.response") private var response = ""
    @State private var saveToJournal = true
    /// 出错的说明（写入、发送失败）：就地显示在操作按钮下面，下次操作成功时清掉
    @State private var problem: String?
    @State private var sending = false
    @State private var summary: PlannerSummary?
    /// 发给 AI 的 Markdown（复制、预览、字数都用它；JSON 只在导出时现生成）
    @State private var output = ""
    /// 自定义提示语的草稿：打字只改这里，不碰设置（以前每敲一个字都改设置，挂着 @Query 的视图都要跟着重算）。
    /// 停笔约 1 秒、切页、切走应用、退出前写回设置并保存；预览、复制、导出用的都是草稿（与以前即时生效一样）
    @State private var preambleDraft: String?

    private var preset: AskPreset { AskPreset(rawValue: presetRaw) ?? .week }
    private var settings: AppSettings? { settingsList.first }
    private var sections: Set<SummarySection> {
        guard preset == .custom else { return preset.sections }
        let excluded = Set(excludedRaw.split(separator: ",").map(String.init))
        return Set(SummarySection.allCases.filter { !excluded.contains($0.rawValue) })
    }
    private var preamble: String { preset == .custom ? (preambleDraft ?? settings?.aiPreamble ?? SummaryRenderer.defaultPreamble) : preset.preamble }
    private var advisor: any AIAdvisor { AIAdvisorRegistry.advisor(id: settings?.aiProvider ?? "export") }

    /// 任何会影响摘要的输入变化，都会改变这个键，从而触发重新生成。
    /// 数据部分与以前相同：档案、目标、日程、作息、习惯、修行录各几条，加上这些表（作息除外，另加账簿）里最近的一次修改时间；
    /// 只是改成直接数条数、取最新的一条，不再把整表取出来。
    private var refreshKey: String {
        func count<T: PersistentModel>(_ type: T.Type) -> Int { (try? context.fetchCount(FetchDescriptor<T>())) ?? 0 }
        func latest<T: PersistentModel>(_ keyPath: KeyPath<T, Date>) -> Date? {
            var descriptor = FetchDescriptor<T>(sortBy: [SortDescriptor(keyPath, order: .reverse)])
            descriptor.fetchLimit = 1
            return (try? context.fetch(descriptor))?.first?[keyPath: keyPath]
        }
        let counts: [Int] = [count(Profile.self), count(Goal.self), count(ScheduleEvent.self), count(RoutineBlock.self), count(Habit.self), count(JournalEntry.self)]
        let dates: [Date] = [latest(\Habit.updatedAt), latest(\ScheduleEvent.updatedAt), latest(\Profile.updatedAt),
                             latest(\Goal.updatedAt), latest(\JournalEntry.updatedAt), latest(\FinanceStore.updatedAt)].compactMap { $0 }
        let stamps: Double = dates.max()?.timeIntervalSince1970 ?? 0
        return "\(counts)|\(stamps)|\(presetRaw)|\(days)|\(excludedRaw)|\(hideIdentity)|\(focusQuestion)|\(preamble.hashValue)|\(LocalDay.today().key)"
    }

    /// 把提示语草稿写回设置并保存
    private func commitPreamble() {
        guard let draft = preambleDraft else { return }
        preambleDraft = nil
        settings?.aiPreamble = draft
        DataStore.save(context)
    }

    /// 复制、导出、发送、存档时当场重算，保证拿到的是最新数据（预览区的自动刷新可能还没跟上）
    private func freshOutput() -> String {
        regenerate()
        return output
    }

    @discardableResult
    private func regenerate() -> PlannerSummary {
        var options = SummaryCollector.Options(sections: sections, hideIdentity: hideIdentity, focusQuestion: focusQuestion)
        options.journalDays = days
        options.upcomingDays = min(14, max(7, days))
        // 周复盘要看“这一周已经发生的事”：过去几天的日程与逐日打卡
        options.pastDays = min(14, days)
        let built = SummaryCollector.build(context: context, options: options)
        // 带上长期趋势与洞察（按数据戳缓存，打字、切问法只是查表）；开着“隐去姓名”时整份摘要与提示语里的档案称呼都换成〔姓名〕。
        // 换在结构体这一层：预览、复制、导出的 Markdown 与 JSON、发给 AI 的结构体、存档的摘要都是换过的
        let prepared = AIDigest.prepare(built, preamble: preamble, sections: sections, hideIdentity: hideIdentity, context: context)
        summary = prepared.summary
        output = SummaryRenderer.markdown(prepared.summary, preamble: prepared.preamble)
        return prepared.summary
    }

    var body: some View {
        // 横幅只留诗意短句（场景默认题词）；操作都在下面第一张卡的底部
        PageScaffold(page: .ai) {
            askCard.ysEntrance(order: 0)
            adviceCard.ysEntrance(order: 1)
            if !records.isEmpty { historyCard.ysEntrance(order: 2) }
        }
        .task(id: refreshKey) {
            // 首次立即生成；之后（例如打字）停顿 0.3 秒再生成，避免每个字都重算整份摘要
            if !output.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled else { return }
            regenerate()
        }
        // 提示语停笔约 1 秒后写回设置并落盘（不必等到切走应用或退出）；放在页面上，切换问法收起编辑框也照样写回
        .task(id: preambleDraft) {
            guard preambleDraft != nil else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            commitPreamble()
        }
        // 切页、关窗、切走应用、退出前写回（后两个通知在主线程上同步发出，退出前来得及存）
        .onDisappear(perform: commitPreamble)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in commitPreamble() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in commitPreamble() }
    }

    // MARK: 一、想问什么

    private var askCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardTitle(title: "一、想问什么", hint: "选一种问法，自动带上对应的记录")
            // 一条记录都没有时多一行“先去落笔”（有记录时不占地方）
            NothingToAskNotice()
            // 宽窗口三列、窄窗口两列，六种问法总能排齐
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(AskPreset.allCases) { item in
                    PresetTile(preset: item, on: item == preset) {
                        withAnimation(motion ? Motion.standard : nil) {
                            presetRaw = item.rawValue
                            days = item.defaultDays
                        }
                    }
                }
            }
            // 选“自定义”时，就地展开内容勾选和提示语
            if preset == .custom {
                customPanel.transition(.opacity)
            }
            HStack(spacing: 14) {
                Text("回看").font(.ysCallout).foregroundStyle(Theme.inkSoft)
                SegmentedTabs(options: [(7, "近 7 天"), (30, "近 30 天"), (90, "近 90 天")], selection: $days)
                    .fixedSize()
                Toggle("隐去姓名", isOn: $hideIdentity)
                    .help("发给外部 AI 前建议开启")
                Spacer(minLength: 0)
                // 自定义时上面已列出勾选的内容，这里不再重复
                if preset != .custom {
                    let included = "包含：" + SummarySection.allCases.filter { sections.contains($0) }.map(\.label).joined(separator: "、")
                    // 窄窗口会截成“…”：悬停看全文
                    Text(included)
                        .font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(1).truncationMode(.tail)
                        .help(included)
                }
            }
            TextField("", text: $focusQuestion, prompt: Text("这次最想弄清楚的一件事（可选），例如：为什么这周总是拖到很晚才开始写论文？"), axis: .vertical)
                .lineLimit(1...3)
            Divider().opacity(0.6)
            actionRow
            if let problem { Hint(problem, tone: .error) }
            if showPreview { preview.transition(.opacity) }
            Hint("AI 只读你选中的内容，不会改动任何记录。", symbol: "lock")
        }
        .xianCard(tier: .jade)
    }

    /// 唯一的一组操作：复制给 AI（主按钮）· 在 Claude Code 里问 · 导出文件…；右侧是字数与预览开关。
    /// 窗口窄（或多了“发送给 …”）放不下一行时，预览开关换到按钮下面一行
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                actionButtons
                Spacer(minLength: 8)
                previewToggle
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) { actionButtons }
                previewToggle
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            FilePanels.copyToClipboard(freshOutput())
            done("已复制，粘贴到任意 AI 对话即可")
        } label: { Label("复制给 AI", systemImage: "doc.on.doc") }
        .buttonStyle(.yunshanPrimary)
        .keyCommand(.copyForAI)
        .help("复制后粘贴到 ChatGPT、Claude 等任意 AI 对话（\(KeyCommand.copyForAI.display)）")
        Button(action: askInClaudeCode) { Label("在 Claude Code 里问", systemImage: "terminal") }
            .help("把这份记录写进 AI 文件夹，再复制一句话；发给 Claude Code，它会直接读取作答，也能顺手把结论记进修行录")
        Menu {
            Button("Markdown（给 AI / 人看）…") { export(json: false) }
            Button("JSON（给程序用）…") { export(json: true) }
        } label: { Label("导出文件…", systemImage: "square.and.arrow.down") }
        .menuStyle(.button)
        .fixedSize()
        .help("存成文件：Markdown 给 AI 或人看，JSON 给程序用")
        if advisor.isConfigured {
            Button {
                Task { await send() }
            } label: { Label(sending ? "发送中…" : "发送给 \(advisor.displayName)", systemImage: "paperplane") }
            .disabled(sending)
        }
    }

    /// “约 3,126 字 · 预览 ▾”：预览默认收起
    private var previewToggle: some View {
        Button {
            withAnimation(motion ? Motion.standard : nil) { showPreview.toggle() }
        } label: {
            HStack(spacing: 5) {
                Text("约 \(output.count) 字 · 预览")
                Image(systemName: "chevron.down")
                    .font(.system(size: TypeSize.micro, weight: .semibold))
                    .rotationEffect(.degrees(showPreview ? 180 : 0))
            }
            .font(.ysCaption)
            .foregroundStyle(Theme.inkSoft)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(showPreview ? "收起预览" : "展开看看这次会发给 AI 的全部内容")
        .accessibilityLabel(showPreview ? "收起预览" : "预览发给 AI 的内容，约 \(output.count) 字")
    }

    /// 发给 AI 的内容：正文字体、1.5 倍行距（不是等宽原文）
    private var preview: some View {
        ScrollView {
            // 不开放文字选取：大段可选文字在滚动时会拖慢光标追踪；需要内容请用“复制给 AI”
            Text(output.isEmpty ? "正在整理……" : output)
                .font(.ysBody)
                .lineSpacing(TypeSize.body * 0.5)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .frame(height: 420)
        .background(Theme.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.line))
    }

    /// 自定义问法：自己挑内容、改提示语
    private var customPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("带上哪些内容").font(.ysCaption).foregroundStyle(Theme.inkSoft)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(SummarySection.allCases) { section in
                    Toggle(section.label, isOn: Binding(
                        get: { sections.contains(section) },
                        set: { on in
                            var excluded = Set(excludedRaw.split(separator: ",").map(String.init))
                            if on { excluded.remove(section.rawValue) } else { excluded.insert(section.rawValue) }
                            excludedRaw = excluded.sorted().joined(separator: ",")
                        }))
                }
            }
            if let settings {
                HStack {
                    Text("提示语").font(.ysCaption).foregroundStyle(Theme.inkSoft)
                    Spacer()
                    Button("恢复默认提示语") {
                        preambleDraft = nil
                        settings.aiPreamble = SummaryRenderer.defaultPreamble
                        DataStore.save(context)
                    }
                    .buttonStyle(.yunshanCompact)
                }
                .padding(.top, 4)
                // 打字只进草稿（preambleDraft），停笔后由页面写回设置
                PaperEditor(text: Binding(get: { preambleDraft ?? settings.aiPreamble }, set: { preambleDraft = $0 }), font: .ysCallout, height: 140)
            }
        }
        .xianCard(padding: 16, tier: .inset)
    }

    // MARK: 二、存下 AI 的建议

    private var adviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "二、存下 AI 的建议", hint: "把 AI 的回复粘贴到这里，可同时存成一篇复盘，日后回看是否采纳")
            PaperEditor(text: $response, placeholder: "把 AI 的回复粘贴到这里……", font: .ysCallout, height: 150)
            HStack {
                Toggle("同时存进修行录（一篇“\(preset.title)”复盘）", isOn: $saveToJournal)
                Spacer()
                Button("保存这条建议", action: saveAdvice)
                    .buttonStyle(.yunshanPrimary)
                    .disabled(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .xianCard()
    }

    private func saveAdvice() {
        let reply = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        let question = focusQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = question.isEmpty ? "\(LocalDay.today().shortLabel) · \(preset.title)" : question
        context.insert(AdviceRecord(title: title, summary: freshOutput(), response: reply))
        if saveToJournal {
            let entry = JournalEntry(kind: .review, title: "AI 建议 · \(preset.title)", body: (question.isEmpty ? "" : "问：\(question)\n\n") + reply)
            entry.period = preset.reviewPeriod
            entry.tags = ["AI建议"]
            entry.minute = ClockTime.minutes(of: Date())
            JournalActions.save(entry, context: context, effects: effects)
        } else {
            DataStore.save(context)
        }
        response = ""
        done(saveToJournal ? "已保存，并存进修行录" : "已保存")
    }

    /// 导出成文件：Markdown 带提示语（给 AI / 人看），JSON 是结构化数据（给程序用）
    private func export(json: Bool) {
        let built = regenerate()
        let ext = json ? "json" : "md"
        let text = json ? SummaryRenderer.json(built) : output
        if let url = FilePanels.save(data: Data(text.utf8), suggestedName: "APT-\(preset.title)-\(LocalDay.today().key).\(ext)", allowedExtensions: [ext]) {
            done("已导出到 \(url.lastPathComponent)")
        }
    }

    /// 把当前这份内容写进 AI 文件夹，复制一句话给 Claude Code：让它直接读文件作答。
    /// 文件用带提示语的 Markdown，Claude 才看得到“文件开头的要求”。
    private func askInClaudeCode() {
        let text = freshOutput()
        let url = CourierService.root.appendingPathComponent("question.md")
        do {
            CourierService.prepareFolders()
            try text.write(to: url, atomically: true, encoding: .utf8)
            var sentence = "请读取 \(url.path)，按文件开头的要求帮我做「\(preset.title)」。"
            sentence += "回答后，如果我说要存档，就用 apt-record 把结论作为一篇复盘投递进云山修习录。"
            FilePanels.copyToClipboard(sentence)
            done("已复制一句话，发给 Claude Code 即可")
        } catch {
            fail("写入失败：\(error.localizedDescription)")
        }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "参悟记录", detail: "\(records.count) 条")
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                if index > 0 { Divider().opacity(0.4) }
                AdviceRow(record: record)
            }
        }
        .xianCard()
    }

    /// 一句话的成功反馈：窗口顶部的纸色小胶囊（左边一个玉色小勾）；顺手清掉之前的出错说明
    private func done(_ text: String) {
        problem = nil
        effects.hint(text, icon: "checkmark.circle")
    }

    /// 出错：就地显示在操作按钮下面
    private func fail(_ text: String) {
        withAnimation(motion ? Motion.quick : nil) { problem = text }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            let prompt = freshOutput()
            // freshOutput() 刚重算过；万一没有，也走同一条路（带长期摘要、隐去姓名），不另起一份没换过称呼的
            let current = summary ?? regenerate()
            let reply = try await advisor.requestAdvice(prompt: prompt, summary: current)
            response = reply
            done("已收到建议，确认后可保存")
        } catch {
            fail(error.localizedDescription)
        }
    }
}

/// 全应用一条记录都没有时，“想问什么”卡标题下的一行：摘要里几乎没有东西可读，先去落笔（行尾“去落笔 →”翻到修行录的落笔框）。
/// 修行录、打卡、日程、目标、账目各一个只取 1 条的小查询（保存后 SwiftData 会重取，很便宜）；有任何一样就什么都不显示。
struct NothingToAskNotice: View {
    @Environment(\.modelContext) private var context
    @Query(NothingToAskNotice.firstEntry) private var entries: [JournalEntry]
    @Query(NothingToAskNotice.firstLog) private var logs: [HabitLog]
    @Query(NothingToAskNotice.firstEvent) private var events: [ScheduleEvent]
    @Query(NothingToAskNotice.firstGoal) private var goals: [Goal]
    @Query(NothingToAskNotice.firstLedger) private var ledger: [FinanceStore]

    private static var firstEntry: FetchDescriptor<JournalEntry> { probe() }
    private static var firstLog: FetchDescriptor<HabitLog> { probe() }
    private static var firstEvent: FetchDescriptor<ScheduleEvent> { probe() }
    private static var firstGoal: FetchDescriptor<Goal> { probe() }
    private static var firstLedger: FetchDescriptor<FinanceStore> { probe() }
    private static func probe<T: PersistentModel>() -> FetchDescriptor<T> {
        var descriptor = FetchDescriptor<T>()
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// 账簿只在前几样都没有时才读（有解码缓存）
    private var blank: Bool {
        guard entries.isEmpty, logs.isEmpty, events.isEmpty, goals.isEmpty else { return false }
        guard !ledger.isEmpty, let loaded = try? FinanceService.load(context) else { return true }
        return loaded.transactions.isEmpty
    }

    var body: some View {
        if blank {
            EmptyHint(.nothingToAsk) {
                Button("去落笔") {
                    AppRouter.shared.chronicleCompose = .diary
                    AppRouter.shared.page = .chronicle
                }
                .buttonStyle(.cardLink)
                .help("翻到修行录写今天的日记")
            }
        }
    }
}

/// 问法块：小物插画 + 标题 + 一句说明。悬停时自己泛起淡玉底和金色细边（.yunshanTile），选中时金边常亮。
private struct PresetTile: View {
    var preset: AskPreset
    var on: Bool
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                SceneryImage(name: preset.ornament)
                    .frame(width: 40, height: 40)
                    .saturation(on ? 1.05 : 0.75)
                    .tileOrnament()
                // 文字区固定两行说明的高度、顶端对齐：说明折行与否，同一排的标题都在同一条线上
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.title).font(Theme.songti(TypeSize.body, .semibold)).tracking(1).foregroundStyle(Theme.ink)
                    Text(preset.subtitle).font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(2)
                }
                .frame(minHeight: 50, alignment: .topLeading)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            // 平时是一块浅底的内嵌格，看得出是一块。深色下雾色和卡底几乎一样，改用一层淡白再加一圈细边
            .background(scheme == .dark ? AnyShapeStyle(Color.white.opacity(0.05)) : AnyShapeStyle(Theme.mist.opacity(0.6)), in: shape)
            .overlay(shape.strokeBorder(Theme.line.opacity(scheme == .dark ? 0.7 : 0)))
            // 悬停 / 选中的金边盖在细边上面
            .yunshanTile(selected: on)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct AdviceRow: View {
    @Bindable var record: AdviceRecord
    @Environment(\.modelContext) private var context
    @State private var expanded = false
    @State private var confirmDelete = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(record.response).textSelection(.enabled).font(.ysCallout).frame(maxWidth: .infinity, alignment: .leading)
                TextField("我的决定 / 采纳情况", text: $record.decision, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.yunshan)
                HStack {
                    Button("复制当时的摘要") { FilePanels.copyToClipboard(record.summary) }
                        .buttonStyle(.yunshanCompact)
                    Spacer()
                    Button("删除", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.yunshanCompact)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text(record.title).foregroundStyle(Theme.ink)
                if !record.decision.isEmpty { Chip(text: "已记录决定", color: Theme.positive) }
                Spacer()
                Text(DateText.display(record.createdAt)).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
            }
        }
        .confirmationDialog("删除这条记录？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                context.delete(record)
                DataStore.save(context)
            }
        }
    }
}
