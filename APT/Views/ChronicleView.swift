import SwiftUI
import SwiftData
import Charts

/// 修行录：日记、灵感、复盘的落笔与回看；AI 经“飞剑传书”送来的记录也在这里。
struct ChronicleView: View {
    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    @Environment(\.spiritMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 只取最近改过的 1 篇，很便宜：SwiftData 每次保存（以及还没保存的改动）之后都会重取 @Query、重算 body，
    /// 修行录摘要（JournalDigest）借这个时机核对要不要更新。页面不再挂整表的修行录（4000 篇约 0.4 秒，每次保存都要重取）。
    @Query(ChronicleView.latestChange) private var latest: [JournalEntry]
    @Query(sort: \CourierDelivery.receivedAt, order: .reverse) private var deliveries: [CourierDelivery]
    @AppStorage("chronicle.filter") private var filter = "all"
    @State private var search = ""
    @State private var tag: String?
    @State private var month: String?
    /// 只看某一天（往日回看里“查看当天全部”）
    @State private var day: String?
    /// 落笔类型也算草稿的一部分：切页、重启后接着写
    @AppStorage("draft.chronicle.kind") private var composerKind: JournalKind = .diary
    @Environment(AppRouter.self) private var router
    @State private var editing: JournalEntry?
    /// 往日回看打开的篇目：先只读，点“修订”再改
    @State private var reading: JournalEntry?
    @State private var limit = 60
    @State private var showExport = false
    /// 七日小卷（卷中气象标题右侧“七日小卷 →”，或 AppRouter.weeklyScroll）
    @State private var showWeekly = false
    /// 小卷里点了“写下一句”：小卷收起后光标落进落笔框
    @State private var composeAfterWeekly = false
    @State private var undoOffer: DeletedEntryOffer?
    /// 键盘选中的那一篇（↑↓ 切换，空格展开，回车修订）；点一下某篇也会移到那里，但只有用键盘移过才描金边
    @State private var cursor: PersistentIdentifier?
    @State private var cursorShown = false
    /// 展开着的篇目（单击或空格）
    @State private var expanded: Set<PersistentIdentifier> = []

    private var today: LocalDay { .today() }
    private var animate: Bool { motion && !reduceMotion }

    /// 最近改过的一篇（见 latest）
    private static var latestChange: FetchDescriptor<JournalEntry> {
        var descriptor = FetchDescriptor<JournalEntry>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return descriptor
    }

    var body: some View {
        // 摘要和筛选结果每次刷新只算一次，工具栏的篇数、时间线、导出共用
        let digest = JournalDigest.shared.sync(context)
        let list = digest.matching(filter: filter, day: day, tag: tag, month: month,
                                   query: search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        // 只把这一页（前 limit 篇）取成对象，按日分组；键盘上下切换也按这个次序走
        let groups = dayGroups(list)
        // 横幅不放按钮：落笔类型就在下面落笔卡的分段里切换
        PageScaffold(page: .chronicle) {
            ScrollViewReader { proxy in
                HStack(alignment: .top, spacing: PageLayout.gutter) {
                    // 左栏几张卡片只依赖全部记录：拆成独立视图，只在摘要变了时重算，搜索、筛选变化时不必重算
                    VStack(spacing: PageLayout.gutter) {
                        ChronicleStatsCard(digest: digest, onWeekly: { showWeekly = true }).equatable().ysEntrance(order: 1)
                        // 心境月历：点一天走的是同一个“只看某一天”筛选（再点同一格回到全部）
                        MoodCalendarCard(digest: digest, selected: day, onPick: pickDay).equatable().ysEntrance(order: 2)
                        // 一条记录都没有时整张卡连同外面的修饰一起不放，左栏卡距才一样大（不再空出一份卡距）
                        ChronicleInsightSlot()
                        LookBackCard(digest: digest, onRead: { reading = $0 }, onShowDay: showDay).equatable().ysEntrance(order: 4)
                        CourierPanel(deliveries: deliveries).ysEntrance(order: 5)
                    }
                    .frame(width: PageLayout.side)
                    VStack(alignment: .leading, spacing: PageLayout.gutter) {
                        JournalComposer(kind: $composerKind).xianCard(tier: .jade).ysEntrance(order: 0)
                        VStack(alignment: .leading, spacing: 4) {
                            // 一篇都没有时搜索、筛选、导出都无从下手（篇数全是 0）：不显示这一排，留白卡紧挨落笔框
                            if !digest.rows.isEmpty {
                                timelineToolbar(digest: digest, count: list.count)
                            }
                            timeline(list, groups: groups, isEmpty: digest.rows.isEmpty)
                        }
                        .ysEntrance(order: 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                // ↑↓ 上一篇 / 下一篇，空格展开或收起，回车修订（光标在落笔框、搜索框里时不接，见 PageKeys）
                .pageKeys([
                    .entryPrev: { moveCursor(-1, groups: groups, list: list, proxy: proxy) },
                    .entryNext: { moveCursor(1, groups: groups, list: list, proxy: proxy) },
                    .entryExpand: { toggleCursor(groups) },
                    .entryOpen: { openCursor(groups) },
                ])
            }
        }
        .overlay(alignment: .bottom) { undoBar }
        .sheet(item: $editing) { JournalEditSheet(entry: $0, onDelete: delete) }
        .sheet(item: $reading) { JournalEditSheet(entry: $0, startReadOnly: true, onDelete: delete) }
        .sheet(isPresented: $showExport) {
            ChronicleExportSheet(filtered: list.map(\.id), version: digest.version, filterDescription: filterDescription).equatable()
        }
        // 小卷里读全文时删掉一篇：小卷收起，走这一页的快照与底部“撤销删除”；“写下一句”：收起后光标落进落笔框
        .sheet(isPresented: $showWeekly, onDismiss: weeklyClosed) {
            WeeklyScrollSheet(onDelete: { entry in
                showWeekly = false
                delete(entry)
            }, onCompose: {
                composeAfterWeekly = true
                showWeekly = false
            })
        }
        .onAppear {
            // 先清掉空草稿里过期的补记日期 / 空白复盘类型，再处理跳转；有跳转要设类型（周复盘提醒）时类型交给跳转
            JournalDraft.resetIfBlank(page: "chronicle", keepKind: router.chronicleCompose != nil)
            applyRoute()
            resumeUndo()
        }
        .onChange(of: router.chronicleSearch) { _, _ in applyRoute() }
        .onChange(of: router.chronicleCompose) { _, _ in applyRoute() }
        .onChange(of: router.weeklyScroll) { _, _ in applyRoute() }
    }

    // MARK: 筛选
    // 筛选本身在修行录摘要上做（JournalDigest.Snapshot.matching），摘要已按新的在前排好，不必再排一遍

    private var filterDescription: String {
        let kindLabel: String? = switch filter {
        case "all": nil
        case "courier": "传书"
        case "pinned": "珍藏"
        default: JournalKind(rawValue: filter)?.label
        }
        return [kindLabel, day.map(dayLabel), tag.map { "#\($0)" }, month.map { MonthKey.label($0, relativeTo: today) }, search.isEmpty ? nil : "“\(search)”"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var hasFilter: Bool { tag != nil || month != nil || day != nil || !search.isEmpty || filter != "all" }

    private func clearFilters() {
        tag = nil; month = nil; day = nil; search = ""; filter = "all"
    }

    /// 往日回看“查看当天全部”、心境月历点一天：时间线只看那一天
    private func showDay(_ key: String) {
        clearFilters()
        day = key
        limit = 60
    }

    /// 心境月历：点一格只看那天；再点同一格只去掉日期这一项（与筛选行“只看 …”的 × 相同）
    private func pickDay(_ key: String?) {
        if let key { showDay(key) } else { day = nil }
    }

    /// 接收全局搜索 / 提醒通知带来的跳转请求：读到就清掉，不留到以后再生效
    private func applyRoute() {
        if let query = router.chronicleSearch {
            router.chronicleSearch = nil
            clearFilters()
            search = query
        }
        if let kind = router.chronicleCompose {
            router.chronicleCompose = nil
            // 落笔框里已经写了东西（例如正写着日记时点了周复盘提醒）就不强行换类型，免得日记被当成复盘入卷
            if JournalDraft.isBlank(page: "chronicle") { composerKind = kind }
        }
        // 七日小卷：修行录在当前页就由这里打开，读到即清零
        if router.weeklyScroll, router.weeklyScrollTarget == nil || router.weeklyScrollTarget == .chronicle {
            router.weeklyScroll = false
            router.weeklyScrollTarget = nil
            showWeekly = true
        }
    }

    /// 小卷收起后：点过“写下一句”就把光标放进落笔框（空着的落笔框先回到日记，免得一句话被当成复盘入卷）
    private func weeklyClosed() {
        guard composeAfterWeekly else { return }
        composeAfterWeekly = false
        if JournalDraft.isBlank(page: "chronicle") { composerKind = .diary }
        DispatchQueue.main.async { WeeklyCompose.focusMainWindow() }
    }

    private func dayLabel(_ key: String) -> String { LocalDay(key: key)?.label(relativeTo: today) ?? key }

    /// 类型筛选的各项与篇数（全部 / 日记 / 灵感 / 复盘 / 珍藏 / 传书）：总篇数、珍藏、飞剑代笔的条数都在这里看
    private func filterOptions(_ digest: JournalDigest.Snapshot) -> [(key: String, label: String, count: Int)] {
        let counts = digest.kindCounts()
        return [("all", "全部", digest.rows.count)]
            + JournalKind.allCases.map { ($0.rawValue, $0.label, counts.byKind[$0.rawValue] ?? 0) }
            + [("pinned", "珍藏", counts.pinned), ("courier", "传书", counts.courier)]
    }

    // MARK: 时间线

    /// 时间线正上方的工具栏：搜索、标签、月份、导出一行，类型一行；
    /// 按标签、月份、日期或关键词筛选时再多一行，列出当前条件（可逐项去掉），点了 #标签 记录不会“悄悄消失”。
    private func timelineToolbar(digest: JournalDigest.Snapshot, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ChronicleSearchField(text: $search)
                TagMonthMenus(digest: digest, tag: tag, month: month,
                              onTag: { tag = $0 }, onMonth: { month = $0 }).equatable()
                Button { showExport = true } label: {
                    Image(systemName: "square.and.arrow.up").frame(width: 14, height: 14)
                }
                .buttonStyle(.yunshanCompact)
                .help("导出修行录（Markdown / PDF）")
                .accessibilityLabel("导出")
                .disabled(digest.rows.isEmpty)
            }
            FlowLayout(spacing: 6) {
                ForEach(filterOptions(digest), id: \.key) { option in
                    FilterChip(text: option.label, count: option.count, on: filter == option.key) { filter = option.key }
                }
            }
            if hasOtherFilter {
                HStack(spacing: 6) {
                    Text("筛选").font(.ysCaption).foregroundStyle(Theme.inkSoft)
                    if let day {
                        FilterChip(text: "只看 \(dayLabel(day))", on: true, removable: true) { self.day = nil }
                    }
                    if let tag {
                        FilterChip(text: "#\(tag)", on: true, removable: true) { self.tag = nil }
                    }
                    if let month {
                        FilterChip(text: MonthKey.label(month, relativeTo: today), on: true, removable: true) { self.month = nil }
                    }
                    if !search.isEmpty {
                        FilterChip(text: "“\(search)”", on: true, removable: true) { search = "" }
                            .frame(maxWidth: 180)
                    }
                    Text("· \(count) 篇").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft).fixedSize()
                    Spacer(minLength: 8)
                    Button(action: clearFilters) {
                        Label("清除筛选", systemImage: "xmark").font(.ysCaption).foregroundStyle(Theme.gold).fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help("去掉全部筛选条件")
                }
            }
        }
        .padding(.bottom, 2)
    }

    /// 只把这一页（前 limit 篇）取成对象，按日分组（新的在前）
    private func dayGroups(_ list: [JournalDigest.Row]) -> [(key: String, value: [JournalEntry])] {
        let shown = JournalDigest.shared.entries(list.prefix(limit).map(\.id), in: context)
        return Dictionary(grouping: shown, by: \.dateKey).sorted { $0.key > $1.key }
    }

    /// 条目放进 LazyVStack，点了多次“展开更早”之后也只画看得到的几条
    private func timeline(_ list: [JournalDigest.Row], groups: [(key: String, value: [JournalEntry])], isEmpty: Bool) -> some View {
        let shownCount = groups.reduce(0) { $0 + $1.value.count }
        return VStack(alignment: .leading, spacing: 6) {
            if isEmpty {
                // 落笔框就在正上方，不另放按钮；请 AI 代记的说法在左栏“飞剑传书”卡里，这里不重复
                OrnamentEmpty(.chronicle)
                    .xianCard()
                    .padding(.top, 8)
            } else if list.isEmpty {
                EmptyHint(filter == "pinned" && !hasOtherFilter ? .noPinned : .noMatch)
                    .slipCard()
                    .padding(.top, 8)
            }
            if !groups.isEmpty {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(groups, id: \.key) { group in
                        DayHeader(dayKey: group.key, count: group.value.count)
                        ForEach(group.value) { entry in
                            let id = entry.persistentModelID
                            EntryRow(entry: entry, expanded: expanded.contains(id), current: cursorShown && cursor == id,
                                     onToggle: {
                                         cursor = id
                                         cursorShown = false
                                         toggleExpanded(id)
                                         PageKeys.endTyping()
                                     },
                                     onEdit: { editing = entry }, onTag: { tag = $0 }, onDelete: { delete(entry) })
                                .id(id)
                        }
                    }
                }
            }
            if list.count > shownCount {
                Button("展开更早的 \(list.count - shownCount) 条") { limit += 60 }
                    .buttonStyle(.yunshanCompact)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
    }

    private var hasOtherFilter: Bool { tag != nil || month != nil || day != nil || !search.isEmpty }

    // MARK: 键盘

    private func toggleExpanded(_ id: PersistentIdentifier) {
        withAnimation(animate ? Motion.standard : nil) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    /// ↑↓：按时间线的次序移到上一篇 / 下一篇（还没选时从最新一篇开始），滚进视野；
    /// 到了已展开部分的最后一篇再往下，就像点了“展开更早”，接着移到下一篇。到头了停在原处
    private func moveCursor(_ step: Int, groups: [(key: String, value: [JournalEntry])], list: [JournalDigest.Row], proxy: ScrollViewProxy) -> Bool {
        let ids = groups.flatMap { $0.value.map(\.persistentModelID) }
        guard !ids.isEmpty else { return false }
        let target = cursor.flatMap { ids.firstIndex(of: $0) }.map { $0 + step } ?? 0
        let next: PersistentIdentifier
        if target >= ids.count {
            guard list.count > ids.count else { return true }
            limit += 60
            next = list[ids.count].id
        } else {
            next = ids[max(0, target)]
        }
        withAnimation(animate ? Motion.hover : nil) {
            cursor = next
            cursorShown = true
        }
        // 刚展开更早的那几篇要等下一轮排版才在时间线里：滚动放到下一轮
        DispatchQueue.main.async {
            withAnimation(animate ? Motion.standard : nil) { proxy.scrollTo(next, anchor: nil) }
        }
        return true
    }

    /// 空格：展开或收起键盘选中的那一篇
    private func toggleCursor(_ groups: [(key: String, value: [JournalEntry])]) -> Bool {
        guard let cursor, groups.contains(where: { $0.value.contains { $0.persistentModelID == cursor } }) else { return false }
        cursorShown = true
        toggleExpanded(cursor)
        return true
    }

    /// 回车：修订键盘选中的那一篇（与双击相同）
    private func openCursor(_ groups: [(key: String, value: [JournalEntry])]) -> Bool {
        guard let cursor, let entry = groups.lazy.flatMap(\.value).first(where: { $0.persistentModelID == cursor }) else { return false }
        editing = entry
        return true
    }

    // MARK: 删除与撤销

    /// 删除一篇：先拍快照再删，页面底部给约 8 秒“撤销删除”（修为随之自然恢复）。
    /// 正“只看这天”、删完那天一篇都不剩了：日期这一项自动去掉（筛选行随之收起，时间线回到全部），不留一行空筛选；撤销删除不再恢复筛选
    private func delete(_ entry: JournalEntry) {
        let snapshot = JournalActions.delete(entry, context: context, effects: effects)
        let offer = DeletedEntryOffer(snapshot: snapshot)
        PendingUndo.offer = offer
        PendingUndo.expires = Date().addingTimeInterval(8)
        let keptDay = ChronicleDayFilter.afterDelete(day: day, context: context)
        withAnimation(animate ? .easeOut(duration: 0.25) : nil) {
            undoOffer = offer
            if keptDay != day { day = keptDay }
        }
        expireUndo(offer, after: 8)
    }

    /// 到点收起提示条，并清掉页面之外留着的那一份
    private func expireUndo(_ offer: DeletedEntryOffer, after seconds: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if PendingUndo.offer?.id == offer.id { PendingUndo.offer = nil }
            if undoOffer?.id == offer.id {
                withAnimation(animate ? .easeIn(duration: 0.25) : nil) { undoOffer = nil }
            }
        }
    }

    /// 页面重建（换日时整页按 .id 重建）或刚切回来：删除还没过 8 秒的，接着显示提示条，只给剩下的时间
    private func resumeUndo() {
        guard undoOffer == nil, let offer = PendingUndo.offer else { return }
        let remaining = PendingUndo.expires.timeIntervalSinceNow
        guard remaining > 0 else {
            PendingUndo.offer = nil
            return
        }
        undoOffer = offer
        expireUndo(offer, after: remaining)
    }

    private func restore(_ offer: DeletedEntryOffer) {
        if PendingUndo.offer?.id == offer.id { PendingUndo.offer = nil }
        withAnimation(animate ? .easeIn(duration: 0.2) : nil) { undoOffer = nil }
        JournalActions.restore(offer.snapshot, context: context, effects: effects)
    }

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
}

/// 修行录删掉篇目之后的“只看这天”：那天还剩篇目就照旧只看那天，一篇不剩就去掉日期这一项（标签、月份、关键词、类型不动）。
/// 只数那一天（dateKey 谓词交给数据库的一次 fetchCount），不取全表（自检直接调）
@MainActor
enum ChronicleDayFilter {
    /// 删完之后日期这一项该是什么：没在只看某天时原样；那天还剩几篇（remaining）大于 0 时原样；一篇不剩时 nil
    static func afterDelete(day: String?, remaining: Int) -> String? {
        remaining > 0 ? day : nil
    }

    /// 同上，那天还剩几篇由数据库数（删除已经存盘；数不出来时当作还有，宁可不动筛选）
    static func afterDelete(day: String?, context: ModelContext) -> String? {
        guard let key = day else { return nil }
        let remaining = (try? context.fetchCount(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.dateKey == key }))) ?? 1
        return afterDelete(day: key, remaining: remaining)
    }
}

/// 页面底部“撤销删除”的那一条，另在页面之外留一份：换日时整页按 .id 重建，页面里的 @State 会清空，
/// 以前提示条和删除前拍的快照随之丢失，这篇就再也找不回来（README 承诺删除后约 8 秒内可撤销）。
@MainActor
private enum PendingUndo {
    static var offer: DeletedEntryOffer?
    /// 过了这一刻就不再给撤销
    static var expires = Date.distantPast
}

// MARK: - 搜索框

/// 时间线工具栏的搜索框：停顿约 0.25 秒再把关键词交给页面，打字时不必每个字都把整页重算一遍。
private struct ChronicleSearchField: View {
    @Binding var text: String
    @State private var input: String
    @FocusState private var focused: Bool

    init(text: Binding<String>) {
        _text = text
        _input = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.ysCaption).foregroundStyle(Theme.inkSoft)
                .accessibilityHidden(true)
            // 占位字短一点：窄窗口里被标签、月份挤窄时也不会截成半句
            TextField("搜索记录", text: $input)
                .textFieldStyle(.plain)
                .font(.ysCallout)
                .focused($focused)
                .help("搜索标题、正文、标签")
            if !input.isEmpty {
                Button {
                    input = ""
                    text = ""
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkSoft.opacity(0.7)) }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                    .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: shape)
        .overlay(shape.strokeBorder(focused ? Theme.gold.opacity(0.6) : Theme.line, lineWidth: focused ? 1.3 : 1))
        // 外面改了（全局搜索跳转、清除筛选）就同步回来
        .onChange(of: text) { _, value in if value != input { input = value } }
        .task(id: input) {
            guard input != text else { return }
            if !input.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled else { return }
            text = input
        }
    }
}

/// 导出弹窗：打开时才把篇目取成对象。“全部”按原来的取法（日期倒序）整表取一次；“当前筛选”照摘要的次序（新的在前）。
/// 只在摘要或筛选变了时重取，弹窗开着时页面别的刷新不会每次都整表取。
private struct ChronicleExportSheet: View, Equatable {
    var filtered: [PersistentIdentifier]
    var version: Int
    var filterDescription: String
    @Environment(\.modelContext) private var context

    static func == (a: Self, b: Self) -> Bool {
        a.version == b.version && a.filterDescription == b.filterDescription && a.filtered == b.filtered
    }

    var body: some View {
        let all = (try? context.fetch(FetchDescriptor<JournalEntry>(sortBy: [JournalDigest.sorted(\.dateKey, .reverse)]))) ?? []
        let byID = Dictionary(all.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
        JournalExportSheet(filtered: filtered.compactMap { byID[$0] }, all: all, filterDescription: filterDescription)
    }
}

/// 标签、月份两个下拉（只依赖修行录摘要和当前所选：搜索打字时不重算）。
private struct TagMonthMenus: View, Equatable {
    var digest: JournalDigest.Snapshot
    var tag: String?
    var month: String?
    var onTag: (String?) -> Void
    var onMonth: (String?) -> Void

    static func == (a: Self, b: Self) -> Bool { a.digest == b.digest && a.tag == b.tag && a.month == b.month }

    var body: some View {
        let tags = digest.tagOptions()
        let months = digest.monthOptions()
        let today = LocalDay.today()
        HStack(spacing: 8) {
            FilterMenu(symbol: "number", placeholder: "标签", anyLabel: "不限标签", selection: tag,
                       options: tags.map { ($0.key, "#\($0.key)", $0.value) }, onPick: onTag)
            FilterMenu(symbol: "calendar", placeholder: "月份", anyLabel: "不限月份", selection: month,
                       options: months.map { ($0.key, MonthKey.label($0.key, relativeTo: today), $0.value) }, onPick: onMonth)
        }
    }
}

/// 标签 / 月份下拉：玉签按钮（选了条件时描边转金），点开是可滚动的选项列表，带篇数，第一项是“不限”。
private struct FilterMenu: View {
    var symbol: String
    var placeholder: String
    var anyLabel: String
    var selection: String?
    var options: [(key: String, label: String, count: Int)]
    var onPick: (String?) -> Void
    @State private var open = false

    var body: some View {
        let current = options.first { $0.key == selection }?.label
        Button { open.toggle() } label: {
            FieldChip(symbol: symbol, text: current ?? placeholder, active: open || selection != nil)
        }
        .buttonStyle(.plain)
        .disabled(options.isEmpty)
        .help(options.isEmpty ? "还没有可选的\(placeholder)" : "按\(placeholder)筛选")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(key: nil, label: anyLabel, count: nil)
                    ForEach(options, id: \.key) { option in
                        row(key: option.key, label: option.label, count: option.count)
                    }
                }
                .padding(8)
            }
            .frame(minWidth: 200, maxHeight: 360)
            .fixedSize(horizontal: true, vertical: options.count < 9)
            .background(Theme.card)
        }
    }

    private func row(key: String?, label: String, count: Int?) -> some View {
        let on = key == selection
        return Button {
            onPick(key)
            open = false
        } label: {
            HStack(spacing: 8) {
                Text(label).font(.system(size: TypeSize.callout, weight: on ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 12)
                if let count { Text("\(count)").font(.ysCaption).monospacedDigit().opacity(0.75) }
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

// MARK: - 左栏卡片

/// 卷中气象：本月落笔、连续落笔、复盘三个数，下面接近 30 日心境曲线（横轴固定 30 天，相隔 3 天以上没有记录就断开）。
/// 总篇数在标题旁；珍藏、传书的篇数在时间线的类型筛选上；修为规则在侧栏境界卡里。
/// 标题行右侧“七日小卷 →”打开这一周的小结（WeeklyScrollSheet）。
/// 数字由修行录摘要算（JournalDigest.Snapshot.stats）：只走到本月和近 30 天为止，不再每篇都解析一次日期。
private struct ChronicleStatsCard: View, Equatable {
    var digest: JournalDigest.Snapshot
    var onWeekly: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.digest == b.digest }

    var body: some View {
        let today = LocalDay.today()
        let days = (0..<30).map { today.adding(days: -29 + $0) }
        let stats = digest.stats(today: today)
        let total = digest.rows.count
        var points: [(day: LocalDay, value: Double, segment: String)] = []
        var segment = 0
        for d in days {
            guard let values = stats.moods[d] else { continue }
            if let last = points.last?.day, last.days(to: d) > 3 { segment += 1 }
            points.append((d, Double(values.reduce(0, +)) / Double(values.count), "段\(segment)"))
        }
        // 横轴刻度显式给出、每 7 天一个：第 28 天（昨天）那个离右边界太近，标签会被截成“1”，不标
        let ticks = [0, 7, 14, 21].map { days[$0].date() }
        return VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "卷中气象", detail: total == 0 ? "" : "共 \(total) 篇") {
                Button("七日小卷", action: onWeekly)
                    .buttonStyle(.cardLink)
                    .help("这一周的小结：自己的话、心境、功课、花费；可存为周复盘草稿")
            }
            MetricRow(spacing: 10) {
                MetricTile(label: "本月落笔", value: "\(stats.thisMonth)", unit: "篇")
                MetricTile(label: "连续落笔", value: "\(stats.streak)", unit: "天")
                MetricTile(label: "复盘", value: "\(stats.reviews)", unit: "篇")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("心境").font(Theme.songti(TypeSize.callout, .semibold)).tracking(1).foregroundStyle(Theme.ink)
                    Text(points.isEmpty ? "近 30 日" : "近 30 日 · \(points.count) 天有记录").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                }
                if points.isEmpty {
                    Hint("写日记时选一个心境，这里会连成一条线。")
                } else {
                    Chart(points, id: \.day) { point in
                        AreaMark(x: .value("日期", point.day.date()), y: .value("心境", point.value),
                                 series: .value("段", point.segment), stacking: .unstacked)
                            .foregroundStyle(LinearGradient(colors: [Theme.gold.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("日期", point.day.date()), y: .value("心境", point.value), series: .value("段", point.segment))
                            .foregroundStyle(Theme.gold)
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("日期", point.day.date()), y: .value("心境", point.value))
                            .foregroundStyle(Theme.gold)
                            .symbolSize(22)
                    }
                    .chartXScale(domain: days[0].date() ... today.date())
                    .chartYScale(domain: 0.5...5.5)
                    .chartLegend(.hidden)
                    .chartYAxis {
                        AxisMarks(values: [1, 3, 5]) { value in
                            AxisGridLine()
                            AxisValueLabel { Text(Mood.label(value.as(Int.self))).font(.ysMicro) }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: ticks) { value in
                            AxisValueLabel { if let date = value.as(Date.self) { Text(LocalDay(date: date).axisLabel).font(.ysMicro) } }
                        }
                    }
                    .frame(height: 96)
                }
            }
            .padding(.top, 2)
        }
        .xianCard()
    }
}

/// 往日回看：一周、一月、半年、一年前的今天各写了什么（往前后各放宽一天，不必天天都写）。
/// 当天每一篇都能点开阅读；篇目多时可在时间线里只看那一天。
/// 只查那 12 个日期（JournalDigest.Snapshot.lookBack），再把这几天的篇目取成对象。
/// 卷中洞见的位置：修行录、打卡、账目任有一样才放这张卡（与卡片自己的判断一致）。
/// 卡片的入场修饰挂在这里的 if 里面：没有记录时这里什么都不出，左栏 VStack 不会为它多留一份卡距。
/// 三个只取 1 条的小查询，第一篇日记 / 第一次打卡 / 第一笔账写下后把卡片带出来
private struct ChronicleInsightSlot: View {
    @Environment(\.modelContext) private var context
    @Query(ChronicleInsightSlot.firstEntry) private var anyEntry: [JournalEntry]
    @Query(ChronicleInsightSlot.firstLog) private var anyLog: [HabitLog]
    @Query(ChronicleInsightSlot.firstLedger) private var anyLedger: [FinanceStore]

    private static var firstEntry: FetchDescriptor<JournalEntry> { probe() }
    private static var firstLog: FetchDescriptor<HabitLog> { probe() }
    private static var firstLedger: FetchDescriptor<FinanceStore> { probe() }
    private static func probe<T: PersistentModel>() -> FetchDescriptor<T> {
        var descriptor = FetchDescriptor<T>()
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// 账簿只在前两样都没有时才读（有解码缓存）
    private var hasRecords: Bool {
        if !anyEntry.isEmpty || !anyLog.isEmpty { return true }
        guard !anyLedger.isEmpty, let ledger = try? FinanceService.load(context) else { return false }
        return !ledger.transactions.isEmpty
    }

    var body: some View {
        if hasRecords {
            ChronicleInsightCard().equatable().ysEntrance(order: 3)
        }
    }
}

private struct LookBackCard: View, Equatable {
    var digest: JournalDigest.Snapshot
    var onRead: (JournalEntry) -> Void
    var onShowDay: (String) -> Void
    @Environment(\.modelContext) private var context

    static func == (a: Self, b: Self) -> Bool { a.digest == b.digest }

    private static let shownPerDay = 3

    private var items: [(label: String, day: LocalDay, entries: [JournalEntry])] {
        digest.lookBack(today: .today()).map { item in
            (item.label, item.day, JournalOrder.oldestFirst(JournalDigest.shared.entries(item.ids, in: context)))
        }
    }

    var body: some View {
        let items = self.items
        VStack(alignment: .leading, spacing: 10) {
            // 沙漏小物放在标题行右侧（衬在卡角时会压着下面的回看格）
            CardTitle(title: "往日回看", hint: "旧笔新读：一周、一月、半年、一年前的今天写过的") {
                SceneryImage(name: "yunshan-ornament-hourglass-v1")
                    .frame(width: 30, height: 30)
                    .opacity(0.7)
                    .padding(.vertical, -6)
            }
            if items.isEmpty {
                EmptyHint(.lookback)
            }
            ForEach(items, id: \.label) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.label).font(Theme.songti(TypeSize.callout, .semibold)).foregroundStyle(Theme.precious)
                        Text(item.day.shortLabel + " " + item.day.weekdayName).font(.ysCaption).foregroundStyle(Theme.inkSoft)
                        if item.entries.count > 1 { Text("\(item.entries.count) 篇").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft) }
                    }
                    ForEach(item.entries.prefix(Self.shownPerDay)) { entry in
                        // 整行可点：悬停泛淡玉底，点开阅读
                        Button { onRead(entry) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: entry.kindValue.symbol).font(.ysCaption).foregroundStyle(entry.kindValue.color)
                                Text(entry.title.isEmpty ? entry.body : entry.title)
                                    .font(.ysCallout)
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .yunshanTile(cornerRadius: Radius.inner)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, -6)
                        .help("阅读这一篇")
                    }
                    if item.entries.count > Self.shownPerDay {
                        Button("查看当天全部 \(item.entries.count) 篇") { onShowDay(item.day.key) }
                            .buttonStyle(.cardLink)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.mist.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
        }
        .xianCard()
    }
}

// MARK: - 时间线条目

private struct DayHeader: View {
    var dayKey: String
    var count: Int

    var body: some View {
        let today = LocalDay.today()
        let day = LocalDay(key: dayKey) ?? today
        let offset = day.days(to: today)
        let relative = offset == 0 ? "今天" : offset == 1 ? "昨天" : offset == 2 ? "前天" : ""
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "diamond.fill").font(.ysMicro).imageScale(.small).foregroundStyle(Theme.gold)
                .accessibilityHidden(true)
            CardTitle<EmptyView>.styled("\(day.month)月\(day.day)日").foregroundStyle(Theme.ink)
            Text(day.weekdayName + (day.year != today.year ? " · \(day.year)" : "")).font(.ysCallout).foregroundStyle(Theme.inkSoft)
            // “今天 / 昨天”用金色小字，不用胶囊
            if !relative.isEmpty { Text(relative).font(.ysCaption).foregroundStyle(Theme.precious) }
            Rectangle().fill(LinearGradient(colors: [Theme.gold.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 1)
            // 一天只有一篇时不写“1 篇”
            if count > 1 { Text("\(count) 篇").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft) }
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }
}

/// 时间线的一条：纸笺（纸色底、发丝细边，悬停时边框转淡金），不带回纹、不浮起。
/// 单击展开 / 收起长文，双击修订；类型色只留在节点和小图标上，元信息一律次要墨色。
private struct EntryRow: View {
    @Bindable var entry: JournalEntry
    /// 展开全文（单击或键盘空格；由修行录页记着）
    var expanded: Bool
    /// 键盘选中的那一篇：描一圈金边，左侧节点亮起
    var current: Bool
    var onToggle: () -> Void
    var onEdit: () -> Void
    var onTag: (String) -> Void
    var onDelete: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.spiritMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmDelete = false

    var body: some View {
        let kind = entry.kindValue
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: kind.symbol).foregroundStyle(kind.color)
                    Text(kind.label).foregroundStyle(Theme.inkSoft)
                }
                .font(.system(size: TypeSize.caption, weight: .semibold))
                if let m = entry.minute { Text(ClockTime.text(m)).font(.ysCaption.monospacedDigit()).foregroundStyle(Theme.inkSoft) }
                if let mood = entry.mood {
                    Label(Mood.label(mood), systemImage: Mood.symbol(mood)).font(.ysCaption).foregroundStyle(Theme.inkSoft)
                }
                if !entry.period.isEmpty { Text(ReviewPeriod.label(for: entry.period)).font(.ysCaption).foregroundStyle(Theme.inkSoft) }
                Spacer()
                if entry.isFromCourier {
                    Label("传书 · \(entry.sourceNote)", systemImage: "paperplane")
                        .font(.ysCaption)
                        .foregroundStyle(Theme.info)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.info.opacity(0.1), in: Capsule())
                        .help("由 AI 经飞剑传书代记")
                }
                if entry.pinned { Image(systemName: "pin.fill").font(.ysCaption).foregroundStyle(Theme.precious).help("已珍藏") }
                Menu {
                    Button("编辑", action: onEdit)
                    Button(entry.pinned ? "取消珍藏" : "珍藏") {
                        entry.pinned.toggle()
                        // 珍藏也算用户动过：撤销那封传书时会保留它
                        entry.updatedAt = Date()
                        DataStore.save(context)
                    }
                    Button("复制正文") { FilePanels.copyToClipboard(entry.title.isEmpty ? entry.body : entry.title + "\n" + entry.body) }
                    Divider()
                    Button("删除…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Theme.inkSoft) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("编辑、珍藏、复制、删除")
            }
            if !entry.title.isEmpty {
                CardTitle<EmptyView>.styled(entry.title).foregroundStyle(Theme.ink)
            }
            if !entry.body.isEmpty {
                Text(entry.body)
                    .font(.ysBody)
                    .lineSpacing(4)
                    .foregroundStyle(Theme.text)
                    .lineLimit(expanded ? nil : 5)
                    // 时间线里不开放选取（长列表滚动更顺）；要复制正文用右上角菜单，或双击进入修订
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !entry.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(entry.tags, id: \.self) { t in
                        Button { onTag(t) } label: { Text("#" + t).font(.ysCaption).foregroundStyle(Theme.jade) }
                            .buttonStyle(.plain)
                            .help("只看 #\(t)")
                    }
                }
            }
        }
        .slipCard(interactive: true)
        .overlay {
            // 键盘选中：金边带一层淡淡的金光
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Theme.gold.opacity(0.7), lineWidth: 1.2)
                .shadow(color: Theme.gold.opacity(0.35), radius: 6)
                .opacity(current ? 1 : 0)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .onTapGesture(perform: onToggle)
        .animation(motion && !reduceMotion ? Motion.hover : nil, value: current)
        .accessibilityAddTraits(current ? .isSelected : [])
        .padding(.leading, 34)
        .padding(.bottom, 10)
        // 灵线与节点（7pt 实心点）垫在左侧：高度跟着这一条走（卡片 + 下方 10pt 间距），
        // 短条目下面不会多拖出一截空线，各日之间的节奏一致
        .background(alignment: .topLeading) {
            VStack(spacing: 0) {
                Circle().fill(kind.color).frame(width: 7, height: 7)
                    // 键盘选中时节点外亮一圈金环
                    .background {
                        ZStack {
                            SoftGlow(color: Theme.gold.opacity(0.55)).frame(width: 26, height: 26)
                            Circle().strokeBorder(Theme.gold.opacity(0.85), lineWidth: 1.2).frame(width: 13, height: 13)
                        }
                        .opacity(current ? 1 : 0)
                    }
                    .padding(.top, 22)
                    .padding(.bottom, 6)
                Rectangle()
                    .fill(LinearGradient(colors: [kind.color.opacity(0.35), Theme.line.opacity(0.3)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 20)
            .accessibilityHidden(true)
        }
        .confirmationDialog("删除这条记录？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive, action: onDelete)
        } message: { Text(JournalActions.deleteNotice) }
    }
}
