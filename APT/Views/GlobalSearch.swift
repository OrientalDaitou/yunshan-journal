import SwiftUI
import SwiftData
import AppKit
import Carbon.HIToolbox

/// 全局搜索（⌘F）：一次搜遍修行录、日程、功课、目标与灵石账簿，点结果直达对应页面。
/// 打字停顿片刻才搜索；↑↓ 选择结果，回车打开。
///
/// 打开时不取任何数据（以前一打开就整表取修行录、日程、功课、目标，约 0.6 秒）：
/// 修行录在修行录摘要（JournalDigest，与修行录页共用、已建好就不再整表取）里搜，只把前 8 条取成对象；
/// 日程、功课、目标在第一次搜索时取一次，连同转好小写的字段存起来，之后每个字只在内存里比；数据库有保存就作废、下次搜索重取。
struct GlobalSearchView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// 日程、功课、目标的搜索底本（见 SearchCorpus）；nil 表示还没取或已作废
    @State private var corpus: SearchCorpus?
    @State private var query = ""
    /// 已经搜出结果的关键词与结果（停顿后才更新，打字时不必每个字都把全部记录过一遍）
    @State private var searched = ""
    @State private var found: [SearchGroup] = []
    /// 键盘选中的结果（在全部结果里的序号）
    @State private var selected = 0
    @State private var keyMonitor: Any?
    @FocusState private var focused: Bool

    fileprivate struct Hit: Identifiable {
        /// 稳定的标识：同一条记录每次搜索都相同，列表不会整片重建
        let id: String
        var title: String
        var detail: String
        var symbol: String
        var action: () -> Void
    }

    fileprivate struct SearchGroup: Identifiable {
        var title: String
        var hits: [Hit]
        var total: Int
        var id: String { title }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var allHits: [Hit] { found.flatMap(\.hits) }

    /// 摘出关键词附近的一段，方便一眼看到上下文
    private func snippet(_ text: String, around q: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = flat.range(of: q, options: .caseInsensitive) else { return String(flat.prefix(60)) }
        let start = flat.index(range.lowerBound, offsetBy: -18, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: 40, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }

    private func search(_ q: String) -> [SearchGroup] {
        let router = AppRouter.shared
        let lowered = q.lowercased()
        func has(_ fields: String...) -> Bool { fields.contains { $0.lowercased().contains(lowered) } }
        /// 字段已经转好小写（搜索底本里存的）
        func hasLowered(_ fields: [String]) -> Bool { fields.contains { $0.contains(lowered) } }
        var result: [SearchGroup] = []
        let corpus = self.corpus ?? SearchCorpus(context)
        if self.corpus == nil { self.corpus = corpus }

        // 修行录：新的在前（摘要已排好）；全文用预先转好小写的索引；只把要显示的前 8 条取成对象
        let index = JournalSearchIndex.shared
        let journal = JournalDigest.shared.sync(context).rows.filter { index.matches($0, lowered: lowered) }
        let journalTop = JournalDigest.shared.entries(journal.prefix(8).map(\.id), in: context)
        result.append(SearchGroup(title: "修行录", hits: journalTop.map { e in
            Hit(id: "j-\(e.uid)", title: e.title.isEmpty ? snippet(e.body, around: q) : e.title,
                detail: "\(e.day.longLabel) · \(e.kindValue.label)" + (e.title.isEmpty ? "" : " · " + snippet(e.body, around: q)),
                symbol: e.kindValue.symbol) {
                router.chronicleSearch = q
                router.page = .chronicle
            }
        }, total: journal.count))

        // 时辰卷：即将发生的在前（按下一次的日期），已过去的按最近一次倒序；重复日程跳到它下一次（或最近一次）发生的那周
        let today = LocalDay.today()
        let schedule = corpus.events.filter { hasLowered($0.fields) }.map(\.event).map { e in
            let next = Occurrences.list(events: [e], from: today, to: today.adding(days: 400)).first
            let last = next == nil ? Occurrences.list(events: [e], from: today.adding(days: -400), to: today.adding(days: -1)).last : nil
            return (event: e, next: next, last: last)
        }
        .sorted { a, b in
            switch (a.next, b.next) {
            case let (x?, y?): return (x.day, x.startMinute ?? -1) < (y.day, y.startMinute ?? -1)
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return (a.last?.day ?? a.event.startDay) > (b.last?.day ?? b.event.startDay)
            }
        }
        result.append(SearchGroup(title: "时辰卷", hits: schedule.prefix(6).map { item in
            let e = item.event
            let occurrence = item.next ?? item.last
            let day = occurrence?.day ?? e.startDay
            let time = ClockTime.range(occurrence?.startMinute ?? e.startMinute, occurrence?.endMinute ?? e.endMinute)
            let when = (item.next != nil && e.recurrenceKind != .none ? "下次 " : "") + "\(day.longLabel) \(time)"
            return Hit(id: "e-\(e.persistentModelID.hashValue)", title: occurrence?.title ?? e.title,
                       detail: when + (e.recurrenceKind == .none ? "" : " · \(e.rule.summary)"), symbol: "calendar") {
                router.scheduleDay = day
                router.page = .schedule
            }
        }, total: schedule.count))

        let habitHits = corpus.habits.filter { hasLowered($0.fields) }.map(\.habit)
        result.append(SearchGroup(title: "每日功课", hits: habitHits.prefix(5).map { h in
            Hit(id: "h-\(h.persistentModelID.hashValue)", title: h.title, detail: h.spec.scheduleSummary, symbol: h.symbol) { router.page = .habits }
        }, total: habitHits.count))

        let goalHits = corpus.goals.filter { hasLowered($0.fields) }.map(\.goal)
        result.append(SearchGroup(title: "修士名帖 · 目标", hits: goalHits.prefix(5).map { g in
            Hit(id: "g-\(g.persistentModelID.hashValue)", title: g.title, detail: "\(g.statusLabel) · 进度 \(g.progress)%", symbol: "flag") { router.page = .profile }
        }, total: goalHits.count))

        let ledger = (try? FinanceService.load(context)) ?? FinanceLedger()
        let money = ledger.transactions.filter { has($0.description, $0.note, $0.category) }
            .sorted { $0.date > $1.date }
        result.append(SearchGroup(title: "灵石账簿", hits: money.prefix(6).map { t in
            Hit(id: "t-\(t.id)", title: FinanceEngine.merchantDisplay(t), detail: "\(LocalDay(key: t.date)?.label(relativeTo: .today()) ?? t.date) · \(t.category) · \(FinanceEngine.money(t.amountCents, sign: true))",
                symbol: "wallet.pass") {
                router.financeSearch = q
                router.page = .finance
            }
        }, total: money.count))

        return result.filter { !$0.hits.isEmpty }
    }

    var body: some View {
        let hits = allHits
        let selectedID = hits.indices.contains(selected) ? hits[selected].id : nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkSoft)
                TextField("", text: $query, prompt: Text("搜索日记、灵感、复盘、日程、功课、目标与账目"))
                    .textFieldStyle(.plain)
                    .font(.system(size: TypeSize.heading))
                    .focused($focused)
                    .onSubmit(openSelected)
                    .keyNote(.searchOpen)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkSoft) }
                        .buttonStyle(.plain)
                }
            }
            .padding(16)
            Rectangle().fill(LinearGradient(colors: [.clear, Theme.gold.opacity(0.4), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if trimmed.isEmpty {
                            EmptyHint(symbol: "sparkle.magnifyingglass", text: "输入关键词，例如“论文”“拉面”“导师”。↑↓ 选择，回车打开。")
                        } else if found.isEmpty && searched == trimmed {
                            EmptyHint(symbol: "wind", text: "没有找到“\(trimmed)”。")
                        }
                        ForEach(found) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 7) {
                                    Capsule().fill(Theme.gold.opacity(0.8)).frame(width: 1.5, height: 11)
                                    Text(group.title).font(Theme.songti(TypeSize.callout, .semibold)).tracking(2).foregroundStyle(Theme.gold)
                                    Text("\(group.total)").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                                }
                                ForEach(group.hits) { hit in
                                    SearchRow(title: hit.title, detail: hit.detail, symbol: hit.symbol, selected: hit.id == selectedID) {
                                        open(hit)
                                    }
                                    .id(hit.id)
                                }
                                if group.total > group.hits.count {
                                    Hint("另有 \(group.total - group.hits.count) 条，进入页面后可继续筛选").padding(.leading, 34)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .onChange(of: selected) { _, _ in
                    let hits = allHits
                    guard hits.indices.contains(selected) else { return }
                    proxy.scrollTo(hits[selected].id)
                }
            }
        }
        .frame(width: 640, height: 520)
        .yunshanSheet()
        .onAppear {
            focused = true
            installKeys()
        }
        .keyNote(.searchMove)
        .onDisappear(perform: removeKeys)
        // 数据库有保存（例如传书送来新日程）：搜索底本作废，下次搜索重取
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { note in
            if (note.object as? ModelContext) === context { corpus = nil }
        }
        .task(id: query) {
            let q = trimmed
            guard !q.isEmpty else {
                found = []; searched = ""; selected = 0
                return
            }
            // 停顿片刻再搜；第一次输入立即出结果
            if !searched.isEmpty { try? await Task.sleep(nanoseconds: 180_000_000) }
            guard !Task.isCancelled else { return }
            found = search(q)
            searched = q
            selected = 0
        }
    }

    private func open(_ hit: Hit) {
        hit.action()
        dismiss()
    }

    private func openSelected() {
        // 还没来得及搜（刚打完字就回车）：立即按当前关键词搜一次
        if searched != trimmed, !trimmed.isEmpty {
            found = search(trimmed)
            searched = trimmed
            selected = 0
        }
        let hits = allHits
        guard hits.indices.contains(selected) else { return }
        open(hits[selected])
    }

    private func move(_ step: Int) {
        let count = allHits.count
        guard count > 0 else { return }
        selected = min(max(0, selected + step), count - 1)
    }

    /// ↑↓ 选择结果：文本框会自己吃掉方向键，所以在窗口层面先截下来（输入法正在选字时不截）
    private func installKeys() {
        guard keyMonitor == nil, !RenderMode.offscreen else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.isSheet == true || event.window?.sheetParent != nil else { return event }
            if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            // ↑↓ 是一览里登记的“搜索里选结果”（KeyCommand.searchMove）
            guard let combo = KeyCombo(event: event), KeyCommand.searchMove.combos.contains(combo) else { return event }
            move(combo.key == .down ? 1 : -1)
            return nil
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// 日程、功课、目标的搜索底本：对象连同转好小写的各字段（每个字段单独比，与原来 has(...) 的规则相同）。
/// 都不排序，与原来不带排序的整表 @Query 取出的先后相同（日程排序时同分的几项先后不变）。
private struct SearchCorpus {
    var events: [(event: ScheduleEvent, fields: [String])]
    var habits: [(habit: Habit, fields: [String])]
    var goals: [(goal: Goal, fields: [String])]

    @MainActor init(_ context: ModelContext) {
        events = ((try? context.fetch(FetchDescriptor<ScheduleEvent>())) ?? []).map { e in
            (e, [e.title, e.location, e.notes, e.category].map { $0.lowercased() })
        }
        habits = ((try? context.fetch(FetchDescriptor<Habit>())) ?? []).map { h in
            (h, [h.title, h.category, h.notes].map { $0.lowercased() })
        }
        goals = ((try? context.fetch(FetchDescriptor<Goal>())) ?? []).map { g in
            (g, [g.title, g.detail, g.category, g.notes].map { $0.lowercased() })
        }
    }
}

private struct SearchRow: View {
    var title: String
    var detail: String
    var symbol: String
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            // 可点块：悬停淡玉底 + 金色细描边；键盘选中的那一条金边常亮
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(Theme.inkSoft).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(detail).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft).lineLimit(1)
                }
                Spacer(minLength: 0)
                OpenArrow(selected: selected)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .yunshanTile(selected: selected)
        }
        .buttonStyle(.plain)
    }
}

/// 结果行右侧的“打开”箭头：悬停或键盘选中时才显出
private struct OpenArrow: View {
    var selected: Bool
    @Environment(\.tileHovered) private var hovered

    var body: some View {
        Image(systemName: "arrow.turn.down.right").font(.ysCaption).foregroundStyle(Theme.gold)
            .opacity(selected || hovered ? 1 : 0)
            .accessibilityHidden(true)
    }
}
