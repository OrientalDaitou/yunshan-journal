import SwiftUI
import SwiftData
import AppKit
import Combine

/// 岁月长卷：选一年或一季，一页长卷看完这段时间的落笔、心境、功课、修为、灵石、珍藏与洞见（侧栏第 8 项，⌘8）。
/// 页面不挂任何全表 @Query：取数走 RecordCollector（只取所选时段本身的正文），统计交给 Core 的 AnnalsEngine，
/// 结果按（时段, 今天, 数据戳）缓存，数据没变时切回来就是查表。
struct AnnalsView: View {
    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    @Environment(\.spiritMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 所选时段：“2026” / “2026-Q4”；空或已失效时用默认（记录不满 90 天看本季，其余看今年；见 AnnalsPeriod.defaultScope）
    @AppStorage("annals.period") private var periodKey = ""
    /// 最早一条修行录 / 打卡的日子（定默认时段用）。先拿上次取到的（切回来第一帧就是对的时段），进页与数据变了再核对
    @State private var firstRecord: LocalDay?
    @State private var report: AnnalsReport?
    /// 当前 report 对应的“时段|今天|数据戳”：没变就不重新赋值（免得整卷重算）
    @State private var reportMark = ""
    /// 有记录的年份（旧 → 新）与每年篇数；nil = 还没取过
    @State private var years: [YearCount]?
    /// 只播一次的特效（节 id），切换时段时清空
    @State private var playLog = AnnalsPlayLog()
    /// 正在只读阅读的一篇
    @State private var reading: JournalEntry?
    @State private var undoOffer: DeletedEntryOffer?
    @State private var exporting = false
    @State private var exportError: String?
    /// 长卷的总宽（含两侧伸出的卷轴）：卷内宽度按它算
    @State private var scrollWidth: CGFloat = 0

    struct YearCount: Equatable {
        var year: Int
        var entries: Int
    }

    init() {
        _firstRecord = State(initialValue: AnnalsCache.lastFirstRecord)
    }

    private var animate: Bool { motion && !reduceMotion && !RenderMode.offscreen }

    var body: some View {
        let today = LocalDay.today()
        let period = Self.period(for: periodKey, today: today, firstRecord: firstRecord)
        PageScaffold(page: .annals) {
            if let years, years.isEmpty {
                // 全应用一条记录都没有：整页空状态，不显示工具条；按钮直接翻到修行录的落笔框（日记）
                OrnamentEmpty(.annals) {
                    Button {
                        AppRouter.shared.chronicleCompose = .diary
                        AppRouter.shared.page = .chronicle
                    } label: { Label("落下第一笔", systemImage: "square.and.pencil") }
                        .buttonStyle(.yunshanPrimary)
                        .help("翻到修行录写今天的日记")
                }
                .xianCard()
                .ysEntrance(order: 0)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    toolbar(period: period, today: today)
                    if let exportError {
                        Hint(exportError, tone: .error)
                    }
                }
                .ysEntrance(order: 0)
                scroll(period: period, today: today)
                    .ysEntrance(order: 1)
            }
        }
        .environment(\.annalsAnimate, animate)
        .environment(\.annalsPlayLog, playLog)
        .overlay(alignment: .bottom) { undoBar }
        .sheet(item: $reading, onDismiss: { refresh() }) { entry in
            JournalEditSheet(entry: entry, startReadOnly: true, onDelete: deleteEntry)
        }
        .onAppear {
            resumeUndo()
            // 默认时段要看最早一条记录：进页先同步取（两次只取几条的小查询），免得工具条先亮“全年”再跳到本季
            let first = Self.firstRecordDay(context: context)
            if first != firstRecord { firstRecord = first }
            // 离屏截图：同步算完（.task 赶不上截图）
            if RenderMode.offscreen { refresh() }
        }
        .task(id: period.storageKey + "|" + today.key) {
            // 先让切页转场动起来，再取数计算（合拢的卷轴顺便遮住取数时间）
            await Task.yield()
            refresh()
        }
        // 开着页面时数据变了（飞剑传书到达、在阅读弹窗里改了珍藏）：防抖 1 秒后按数据戳重算
        .onReceive(Self.saves) { _ in refresh() }
    }

    // MARK: 工具条

    private func toolbar(period: AnnalsPeriod, today: LocalDay) -> some View {
        let year = period.scope.year
        let quarters = AnnalsLayout.quarters(year: year, today: today)
        let selection: Int = if case .quarter(_, let q) = period.scope { q } else { 0 }
        let options: [(value: Int, label: String)] = [(0, "全年")] + quarters.map { ($0, "\($0 * 3 - 2)–\($0 * 3)月") }
        // ←→：在“全年 / 各季”分段之间走一格（到头停住）
        func step(_ offset: Int) -> Bool {
            guard let index = options.firstIndex(where: { $0.value == selection }) else { return false }
            let q = options[min(max(0, index + offset), options.count - 1)].value
            pick(q == 0 ? .year(year) : .quarter(year, q), today: today)
            return true
        }
        return WrapTrailingRow {
            SegmentedTabs(options: options, selection: Binding(get: { selection }, set: { q in
                pick(q == 0 ? .year(year) : .quarter(year, q), today: today)
            }))
            HStack(spacing: 12) {
                YearStepper(year: year, years: years ?? [], today: today) { y in
                    pick(AnnalsLayout.move(period.scope, toYear: y, today: today), today: today)
                }
                exportMenu
            }
        }
        .pageKeys([
            .periodPrev: { step(-1) },
            .periodNext: { step(1) },
        ])
    }

    private var exportMenu: some View {
        Menu {
            Button("Markdown（给 AI / 存档）…") { if let report { exportMarkdown(report) } }
            Button("PDF（打印 / 收藏）…") { if let report { exportPDF(report) } }
        } label: {
            Label(exporting ? "排版中…" : "导出", systemImage: exporting ? "hourglass" : "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(.yunshanCompact)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(exporting || report == nil)
        .help("导出这一卷：Markdown 给 AI 或存档；A4 PDF 打印或收藏（长卷之后附珍藏与长篇全文）")
    }

    private func pick(_ scope: AnnalsScope, today: LocalDay) {
        guard let period = AnnalsPeriod.make(scope, today: today),
              period.storageKey != Self.period(for: periodKey, today: today, firstRecord: firstRecord).storageKey else { return }
        playLog.reset()
        exportError = nil
        withAnimation(animate ? .easeInOut(duration: 0.3) : nil) { periodKey = period.storageKey }
    }

    // MARK: 长卷

    @ViewBuilder
    private func scroll(period: AnnalsPeriod, today: LocalDay) -> some View {
        let inner = max(320, scrollWidth - ScrollPalette.overhang * 2 - 64)
        Group {
            if let report, report.period.storageKey == period.storageKey {
                AnnalsScroll {
                    AnnalsBody(report: report, onRead: read)
                }
                .id(period.storageKey)
                .transition(.opacity.animation(animate ? .easeInOut(duration: 0.3) : nil))
            } else {
                ClosedScroll()
                    .padding(.vertical, 30)
                    .transition(.opacity.animation(animate ? .easeInOut(duration: 0.2) : nil))
            }
        }
        .environment(\.annalsInnerWidth, inner)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { scrollWidth = $0 }
    }

    // MARK: 取数与缓存

    /// 用户选过的时段照旧记住；没选过（或已失效）时按最早一条记录定默认（见 AnnalsPeriod.defaultScope）
    static func period(for key: String, today: LocalDay, firstRecord: LocalDay? = nil) -> AnnalsPeriod {
        if let period = AnnalsPeriod(storageKey: key, today: today) { return period }
        // 默认时段一定已经开始（本季、上一季、今年或上一年），make 不会是 nil；万一是，退回今年
        return AnnalsPeriod.make(AnnalsPeriod.defaultScope(today: today, firstRecord: firstRecord), today: today)
            ?? AnnalsPeriod.make(.year(today.year), today: today)!
    }

    /// 最早一条修行录 / 打卡的日子（按 dateKey 升序各取几条，日期写坏的跳过）；一条都没有时 nil。
    /// 账目不算：导入的银行账单常常一导就是一两年，不代表已经在这里修行了这么久
    static func firstRecordDay(context: ModelContext) -> LocalDay? {
        var entries = FetchDescriptor<JournalEntry>(sortBy: [SortDescriptor(\.dateKey)])
        entries.fetchLimit = 8
        entries.propertiesToFetch = [\.dateKey]
        var logs = FetchDescriptor<HabitLog>(sortBy: [SortDescriptor(\.dateKey)])
        logs.fetchLimit = 8
        logs.propertiesToFetch = [\.dateKey]
        let days = ((try? context.fetch(entries)) ?? []).compactMap { LocalDay(key: $0.dateKey) }
            + ((try? context.fetch(logs)) ?? []).compactMap { LocalDay(key: $0.dateKey) }
        let first = days.min()
        AnnalsCache.lastFirstRecord = first
        return first
    }

    /// 先比数据戳：没变就用缓存；变了才取数重算（只取所选时段本身的正文）
    private func refresh() {
        let today = LocalDay.today()
        let stamp = RecordCollector.stamp(context: context)
        let yearList = AnnalsCache.years(stamp: stamp, today: today) {
            RecordCollector.years(context: context, today: today).map { YearCount(year: $0.year, entries: $0.entries) }
        }
        if years != yearList { years = yearList }
        // 数据变了（第一篇日记、导入了旧打卡）：最早一条可能变了，默认时段跟着变
        if reportMark.hasSuffix("|" + stamp) == false {
            let first = Self.firstRecordDay(context: context)
            if first != firstRecord { firstRecord = first }
        }
        let period = Self.period(for: periodKey, today: today, firstRecord: firstRecord)
        let mark = period.storageKey + "|" + today.key + "|" + stamp
        guard mark != reportMark || report?.period.storageKey != period.storageKey else { return }
        let made = AnnalsCache.report(key: period.storageKey + "|" + today.key, stamp: stamp) {
            Self.makeReport(period, today: today, context: context)
        }
        report = made
        reportMark = mark
    }

    /// 取数并算出一卷（页面、空闲预热、自检同一条路）。习惯与打卡借修为模型（侧栏那一份）已经读好的，
    /// 与问道灵枢的长期摘要同样借法（AIDigest.borrowedHabits）：RecordCollector 的镜像就不必第一次再整读全部打卡
    /// （5 年数据上要一秒多，长卷第一次打开会卡住）。别的 context（自检的临时库）借不到时照常由镜像读
    static func makeReport(_ period: AnnalsPeriod, today: LocalDay, context: ModelContext) -> AnnalsReport {
        let input = RecordCollector.input(context: context, from: period.first, to: period.last, today: today, text: true,
                                          habits: AIDigest.borrowedHabits(context))
        return AnnalsEngine.report(period, input: input)
    }

    /// 数据库保存后防抖 1 秒（连续保存只算一次）
    private static let saves = NotificationCenter.default.publisher(for: ModelContext.didSave)
        .debounce(for: .seconds(1), scheduler: RunLoop.main)

    // MARK: 阅读与删除

    private func read(_ uid: String) {
        let target = uid
        var descriptor = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.uid == target })
        descriptor.fetchLimit = 1
        if let entry = (try? context.fetch(descriptor))?.first {
            reading = entry
        } else {
            // 这一篇刚被删了（或改了日期）：按数据戳重算一次
            refresh()
        }
    }

    /// 照修行录的做法：先拍快照再删，页面底部给约 8 秒“撤销删除”（修为随之扣回 / 恢复）
    private func deleteEntry(_ entry: JournalEntry) {
        let snapshot = JournalActions.delete(entry, context: context, effects: effects)
        let offer = DeletedEntryOffer(snapshot: snapshot)
        AnnalsPendingUndo.offer = offer
        AnnalsPendingUndo.expires = Date().addingTimeInterval(8)
        withAnimation(animate ? .easeOut(duration: 0.25) : nil) { undoOffer = offer }
        expireUndo(offer, after: 8)
        refresh()
    }

    private func expireUndo(_ offer: DeletedEntryOffer, after seconds: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if AnnalsPendingUndo.offer?.id == offer.id { AnnalsPendingUndo.offer = nil }
            if undoOffer?.id == offer.id {
                withAnimation(animate ? .easeIn(duration: 0.25) : nil) { undoOffer = nil }
            }
        }
    }

    /// 刚切走又切回来：删除还没过 8 秒的，接着显示提示条，只给剩下的时间
    private func resumeUndo() {
        guard undoOffer == nil, let offer = AnnalsPendingUndo.offer else { return }
        let remaining = AnnalsPendingUndo.expires.timeIntervalSinceNow
        guard remaining > 0 else {
            AnnalsPendingUndo.offer = nil
            return
        }
        undoOffer = offer
        expireUndo(offer, after: remaining)
    }

    private func restore(_ offer: DeletedEntryOffer) {
        if AnnalsPendingUndo.offer?.id == offer.id { AnnalsPendingUndo.offer = nil }
        withAnimation(animate ? .easeIn(duration: 0.2) : nil) { undoOffer = nil }
        JournalActions.restore(offer.snapshot, context: context, effects: effects)
        refresh()
    }

    /// 与修行录同样的“已删除「…」 · 撤销删除”胶囊（修行录那条是私有的，照样式另写）
    @ViewBuilder
    private var undoBar: some View {
        if let offer = undoOffer {
            HStack(spacing: 12) {
                Image(systemName: "trash").foregroundStyle(Theme.inkSoft)
                Text("已删除「\(offer.snapshot.label)」").foregroundStyle(Theme.ink).lineLimit(1)
                Button("撤销删除") { restore(offer) }.buttonStyle(.yunshanCompact)
            }
            .font(.ysCallout)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.45)))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.bottom, 26)
            .transition(animate ? .move(edge: .bottom).combined(with: .opacity) : .opacity)
        }
    }

    // MARK: 导出

    /// 附录用的篇目（珍藏与长篇）：按 uid 现取
    private func appendixItems(_ r: AnnalsReport) -> [JournalExport.Item] {
        let uids = r.highlights.pinned.map(\.uid) + r.highlights.longest.map(\.uid)
        guard !uids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<JournalEntry>(predicate: #Predicate { uids.contains($0.uid) })
        return JournalExport.items((try? context.fetch(descriptor)) ?? [])
    }

    private func exportMarkdown(_ r: AnnalsReport) {
        exportError = nil
        let text = AnnalsPDF.markdown(r, appendix: appendixItems(r))
        if let url = FilePanels.save(data: Data(text.utf8), suggestedName: AnnalsLayout.fileName(r.period) + ".md", allowedExtensions: ["md"]) {
            effects.hint("已导出到 \(url.lastPathComponent)", icon: "checkmark.circle")
        }
    }

    private func exportPDF(_ r: AnnalsReport) {
        exportError = nil
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AnnalsLayout.fileName(r.period) + ".pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let items = appendixItems(r)
        exporting = true
        Task { @MainActor in
            // 先让一帧：按钮来得及换成“排版中…”
            try? await Task.sleep(nanoseconds: 30_000_000)
            do {
                try AnnalsPDF.write(r, appendix: items, to: url)
                effects.hint("已导出到 \(url.lastPathComponent)", icon: "checkmark.circle")
            } catch {
                exportError = "导出 PDF 失败：\(error.localizedDescription)"
            }
            exporting = false
        }
    }
}

/// 页面底部“撤销删除”的那一条另在页面之外留一份：刚删完就切走、又切回来时还能撤销
@MainActor
private enum AnnalsPendingUndo {
    static var offer: DeletedEntryOffer?
    static var expires = Date.distantPast
}

/// 长卷的缓存：键 = 时段 + 今天（跨午夜整页重建后不会拿昨天算的“今年至今”），值带数据戳；最多 8 份
@MainActor
enum AnnalsCache {
    private static var reports: [String: (stamp: String, report: AnnalsReport)] = [:]
    private static var order: [String] = []
    private static var yearList: (key: String, value: [AnnalsView.YearCount])?
    /// 上次取到的最早一条记录的日子：页面重建时先用它，第一帧的默认时段就是对的
    static var lastFirstRecord: LocalDay?
    static let limit = 8
    /// 算过几次（自检用：数据没变时第二次应当命中缓存）
    private(set) static var computed = 0

    static func report(key: String, stamp: String, make: () -> AnnalsReport) -> AnnalsReport {
        if let hit = reports[key], hit.stamp == stamp { return hit.report }
        let made = make()
        computed += 1
        reports[key] = (stamp, made)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit { reports[order.removeFirst()] = nil }
        return made
    }

    static func years(stamp: String, today: LocalDay, make: () -> [AnnalsView.YearCount]) -> [AnnalsView.YearCount] {
        let key = stamp + "|" + today.key
        if let hit = yearList, hit.key == key { return hit.value }
        let made = make()
        yearList = (key, made)
        return made
    }
}

// MARK: - 年份切换

/// “‹ 2026年 ›”：照灵石账簿的月份切换另写一份（那边是私有的）。两侧切到上 / 下一年，点中间列出有记录的年份
/// （“2025年 · 645 篇”）；最早一年 ‹ 置灰，今年 › 置灰
private struct YearStepper: View {
    var year: Int
    var years: [AnnalsView.YearCount]
    var today: LocalDay
    var onPick: (Int) -> Void
    @State private var open = false

    var body: some View {
        let earliest = min(years.first?.year ?? today.year, year)
        HStack(spacing: 2) {
            arrow("chevron.left", label: "上一年", target: year > earliest ? year - 1 : nil, command: .yearPrev)
            Button { open.toggle() } label: {
                FieldChip(symbol: "calendar", text: "\(year)年", active: open)
            }
            .buttonStyle(.plain)
            .help("选年份")
            .popover(isPresented: $open, arrowEdge: .bottom) { list }
            arrow("chevron.right", label: "下一年", target: year < today.year ? year + 1 : nil, command: .yearNext)
        }
        .fixedSize()
    }

    private var list: some View {
        let rows = years.isEmpty ? [AnnalsView.YearCount(year: today.year, entries: 0)] : years
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows.reversed(), id: \.year) { row in
                    let on = row.year == year
                    Button {
                        open = false
                        onPick(row.year)
                    } label: {
                        HStack(spacing: 8) {
                            Text(verbatim: "\(row.year)年").font(.system(size: TypeSize.callout, weight: on ? .semibold : .regular)).monospacedDigit()
                            Text(verbatim: "· \(RecordStats.grouped(row.entries)) 篇").font(.ysCaption).monospacedDigit()
                                .foregroundStyle(on ? Theme.onJadeFill.opacity(0.85) : Theme.inkSoft)
                            Spacer(minLength: 16)
                            if on { Image(systemName: "checkmark").font(.system(size: TypeSize.micro, weight: .bold)) }
                        }
                        .foregroundStyle(on ? Theme.onJadeFill : Theme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(on ? AnyShapeStyle(Theme.jadeFill) : AnyShapeStyle(Color.clear),
                                    in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(8)
        }
        .frame(minWidth: 190, maxHeight: 360)
        .fixedSize(horizontal: true, vertical: rows.count <= 9)
        .background(Theme.card)
    }

    private func arrow(_ symbol: String, label: String, target: Int?, command: KeyCommand) -> some View {
        Button { if let target { onPick(target) } } label: {
            Image(systemName: symbol)
                .font(.system(size: TypeSize.caption, weight: .semibold))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.inkSoft.opacity(target == nil ? 0.3 : 1))
        .keyCommand(command)
        .disabled(target == nil)
        .help(command.help(label))
        .accessibilityLabel(label)
    }
}
