import Foundation
import SwiftData

/// 岁月长卷、卷中洞见、问道灵枢“长期趋势与洞察”的取数桥：从 SwiftData 取出 RecordInput（值类型），统计全交给 Core。
/// 不挂全表 @Query、不整表取正文（5 年 4000 篇整表取一次约 0.4 秒，见 perf.md H1）：只有岁月长卷取正文
/// （text: true，按日期窗口用 #Predicate 取，且只取所选时段本身）；卡片、问道灵枢、快照只要日期 / 类型 / 心境等元数据，
/// 这些与全部落笔、全部打卡一起放在增量镜像（RecordMirror）里，数据没变时不再取数。
enum RecordCollector {
    /// 窗口内修行录（日期在 [from, min(to, today)]，晚于今天的不计）+ 全部落笔的（日期, 类型）+ 全部习惯与打卡（含已归档）+ 修为设置。
    /// text = false 时窗口内篇目只带 uid / 日期 / 时刻 / 类型 / 心境 / 标签 / 珍藏 / 复盘周期，不碰 title / body。
    /// 不带 @MainActor：以后快照挪到后台 ModelActor 也能用；账簿由调用方传入（nil = 没有账簿或读不出）。
    /// habits：调用方手上已有全部习惯与打卡（例如主线程的修为模型 CultivationModel 已经读好）时传进来，
    /// 镜像就不再读打卡（第一次读全部打卡在 5 年数据上要一秒多）；nil 时照常从镜像取。
    static func input(context: ModelContext, from: LocalDay, to: LocalDay, today: LocalDay, ledger: FinanceLedger?, text: Bool,
                      habits: [RecordHabit]? = nil) -> RecordInput {
        // 全部落笔的元数据与全部习惯打卡：读增量镜像，不每次整取
        let mirror = RecordMirror.snapshot(context, habits: habits == nil)
        let last = min(to, today)
        let entries: [RecordEntry]
        if text {
            let fromKey = from.key, toKey = last.key
            let window = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.dateKey >= fromKey && $0.dateKey <= toKey },
                                                       sortBy: [SortDescriptor(\.dateKey), SortDescriptor(\.createdAt)])
            // 取数出错时退回整表过滤（慢，但结果不会悄悄变成空的）
            let fetched = (try? context.fetch(window)) ?? context.all(JournalEntry.self).filter { $0.dateKey >= fromKey && $0.dateKey <= toKey }
            entries = fetched.compactMap { e in
                // 日期认不出的退回创建日（与修为一致），退回后不在窗口里的不要
                let day = e.day
                guard day >= from, day <= last else { return nil }
                return RecordEntry(uid: e.uid, day: day, minute: e.minute, kind: e.kindValue, title: e.title, body: e.body,
                                   mood: e.mood, tags: e.tags, pinned: e.pinned, period: e.period)
            }
        } else {
            // 只要元数据：镜像里就有，不再取数
            entries = mirror.entries.filter { $0.day >= from && $0.day <= last }
        }
        let config = context.all(AppSettings.self).first?.cultivation ?? CultivationConfig()
        return RecordInput(today: today, entries: entries, history: mirror.history, habits: habits ?? mirror.habits, cultivation: config, ledger: ledger)
    }

    /// 主线程便捷版：账簿用 FinanceService.load（有解码缓存）；读不出、或还没有任何账目时当作没有账簿
    @MainActor
    static func input(context: ModelContext, from: LocalDay, to: LocalDay, today: LocalDay = .today(), text: Bool,
                      habits: [RecordHabit]? = nil) -> RecordInput {
        input(context: context, from: from, to: to, today: today, ledger: ledger(context), text: text, habits: habits)
    }

    /// 便宜的数据戳（约 1–2 ms）：修行录 / 打卡 / 习惯 / 账簿的条数与最新修改时间，加修为设置的内容。
    /// 统计结果按“数据戳 + 今天”缓存：数据没变就是查表。也带上数据库本身（自检会换着用好几个临时库；
    /// 用 StoreIdentity 的钥匙，内存地址被新库复用也不会认错）
    static func stamp(context: ModelContext) -> String {
        let settings = context.all(AppSettings.self).first.map {
            "\($0.realms.joined(separator: ","))/\($0.thresholds.map(String.init).joined(separator: ","))/\($0.dailyCap)/\($0.cultivationEnabled)"
        } ?? ""
        return [
            StoreIdentity.key(for: context).description,
            mark(JournalEntry.self, \.updatedAt, in: context), mark(HabitLog.self, \.updatedAt, in: context),
            mark(Habit.self, \.updatedAt, in: context), mark(FinanceStore.self, \.updatedAt, in: context), settings,
        ].joined(separator: "|")
    }

    /// 有记录的年份（最早一条修行录 / 打卡 / 账簿交易所在年 … 今年，旧 → 新），附每年的修行录篇数。
    /// 一条记录都没有时为空（岁月长卷显示整页空状态）
    @MainActor
    static func years(context: ModelContext, today: LocalDay = .today()) -> [(year: Int, entries: Int)] {
        var earliest: [LocalDay] = []
        var firstEntry = FetchDescriptor<JournalEntry>(sortBy: [SortDescriptor(\.dateKey)])
        firstEntry.fetchLimit = 8
        firstEntry.propertiesToFetch = [\.dateKey, \.createdAt]
        if let day = ((try? context.fetch(firstEntry)) ?? []).compactMap({ LocalDay(key: $0.dateKey) }).min() { earliest.append(day) }
        var firstLog = FetchDescriptor<HabitLog>(sortBy: [SortDescriptor(\.dateKey)])
        firstLog.fetchLimit = 8
        if let day = ((try? context.fetch(firstLog)) ?? []).compactMap({ LocalDay(key: $0.dateKey) }).min() { earliest.append(day) }
        if let ledger = ledger(context),
           let day = ledger.transactions.lazy.map(\.date).filter({ $0.count == 10 }).min().flatMap(LocalDay.init(key:)) {
            earliest.append(day)
        }
        guard let start = earliest.min() else { return [] }
        let first = max(min(start.year, today.year), today.year - 100)
        return (first...today.year).map { year in
            let from = LocalDay(year: year, month: 1, day: 1).key
            let to = min(LocalDay(year: year, month: 12, day: 31), today).key
            let count = (try? context.fetchCount(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.dateKey >= from && $0.dateKey <= to }))) ?? 0
            return (year, count)
        }
    }

    /// 增量镜像整取过几次（落笔、打卡）：自检据此确认平常的增删改只取新改过的几条
    static var mirrorFullLoads: (journal: Int, habits: Int) { RecordMirror.fullLoads }

    // MARK: 内部

    @MainActor
    private static func ledger(_ context: ModelContext) -> FinanceLedger? {
        guard let ledger = try? FinanceService.load(context), !(ledger.transactions.isEmpty && ledger.sources.isEmpty) else { return nil }
        return ledger
    }

    /// 一类记录的“条数:最近修改时间”：增删改都会让它变（只数条数、取最新一条，不整表取）
    private static func mark<T: PersistentModel>(_ type: T.Type, _ key: KeyPath<T, Date>, in context: ModelContext) -> String {
        "\((try? context.fetchCount(FetchDescriptor<T>())) ?? -1):\(RecordMirror.newest(type, key, in: context)?.timeIntervalSince1970 ?? 0)"
    }
}

/// 全部落笔的元数据（日期、类型、心境、标签、珍藏……不含标题正文）与全部习惯打卡的增量镜像。
/// 整取一遍很贵：5 年数据约 3 千篇落笔、1 万多条打卡，SwiftData 把它们变成对象要 1 秒上下（习惯一经重新抓取，
/// 它的打卡关系也会作废、下次读要逐个习惯重取）。所以只在第一次、换了数据库、或习惯的设置变了时整取，
/// 之后每次只按 updatedAt 取新写、改过的几条，再按条数与标识找出删掉的和“带着旧时间插回来的”（撤销删除）。
/// 结果与整取完全相同（自检逐条比对）。只记一个数据库，换了库就重建；加锁，后台上下文也能用。
private enum RecordMirror {
    struct HabitInfo: Equatable {
        var id: PersistentIdentifier
        var title: String
        var symbol: String
        var spec: HabitSpec
        var archived: Bool
    }

    struct State {
        /// 镜像的是哪个数据库（StoreIdentity 的钥匙）
        var store: StoreIdentity.Key
        var journalLatest = Date.distantPast
        var journal: [PersistentIdentifier: RecordEntry] = [:]
        /// 按日期、时刻排好的全部篇目（元数据）与全部落笔的（日期, 类型）；journal 变了才重排
        var entries: [RecordEntry] = []
        var history: [(day: LocalDay, kind: JournalKind)]?
        var habitMark = ""
        var habitList: [HabitInfo] = []
        var logLatest = Date.distantPast
        /// owner 为 nil：没有挂在习惯上的打卡；value 为 nil：日期认不出。都留着，好让条数对得上
        var logs: [PersistentIdentifier: (owner: PersistentIdentifier?, value: HabitLogValue?)] = [:]
        var habits: [RecordHabit]?
    }

    /// 标识对不上时，缺几条以内就逐条补取，再多就整取
    static let patchLimit = 300
    private static let lock = NSLock()
    private static var state: State?
    private(set) static var fullLoads = (journal: 0, habits: 0)

    /// habits = false：调用方自带习惯与打卡，这次不碰打卡（返回的 habits 是上次同步的，调用方不用）
    static func snapshot(_ context: ModelContext, habits includeHabits: Bool = true)
        -> (entries: [RecordEntry], history: [(day: LocalDay, kind: JournalKind)], habits: [RecordHabit]) {
        lock.lock()
        defer { lock.unlock() }
        let store = StoreIdentity.key(for: context)
        var s = state?.store == store ? state! : State(store: store)
        syncJournal(&s, context)
        if includeHabits { syncHabits(&s, context) }
        state = s
        return (s.entries, s.history ?? [], s.habits ?? [])
    }

    static func newest<T: PersistentModel>(_ type: T.Type, _ key: KeyPath<T, Date>, in context: ModelContext) -> Date? {
        var latest = FetchDescriptor<T>(sortBy: [SortDescriptor(key, order: .reverse)])
        latest.fetchLimit = 1
        return (try? context.fetch(latest))?.first.map { $0[keyPath: key] }
    }

    // MARK: 落笔

    private static func syncJournal(_ s: inout State, _ context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<JournalEntry>())) ?? -1
        let latest = newest(JournalEntry.self, \.updatedAt, in: context) ?? .distantPast
        if s.history != nil, count == s.journal.count, latest == s.journalLatest { return }
        // 日期用 entry.day（dateKey 认不出时退回 createdAt），与 CultivationService.journalSources 逐条一致；不碰标题正文
        func item(_ e: JournalEntry) -> RecordEntry {
            RecordEntry(uid: e.uid, day: e.day, minute: e.minute, kind: e.kindValue, mood: e.mood, tags: e.tags, pinned: e.pinned, period: e.period)
        }
        let fields: [PartialKeyPath<JournalEntry>] = [\.uid, \.dateKey, \.minute, \.kind, \.mood, \.tags, \.pinned, \.period, \.createdAt, \.updatedAt]
        var patched = false
        if s.history != nil, count >= 0 {
            let since = s.journalLatest
            var changed = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.updatedAt >= since })
            changed.propertiesToFetch = fields
            if let rows = try? context.fetch(changed) {
                for e in rows { s.journal[e.persistentModelID] = item(e) }
                patched = reconcile(JournalEntry.self, &s.journal, count: count, context: context) { (context.model(for: $0) as? JournalEntry).map(item) }
            }
        }
        if !patched {
            fullLoads.journal += 1
            var all = FetchDescriptor<JournalEntry>()
            all.propertiesToFetch = fields
            let rows = (try? context.fetch(all)) ?? context.all(JournalEntry.self)
            s.journal = Dictionary(rows.map { ($0.persistentModelID, item($0)) }, uniquingKeysWith: { $1 })
        }
        s.journalLatest = latest
        s.entries = s.journal.values.sorted { ($0.day, $0.minute ?? -1, $0.uid) < ($1.day, $1.minute ?? -1, $1.uid) }
        s.history = s.entries.map { ($0.day, $0.kind) }
    }

    // MARK: 习惯与打卡

    private static func syncHabits(_ s: inout State, _ context: ModelContext) {
        let habitMark = "\((try? context.fetchCount(FetchDescriptor<Habit>())) ?? -1):\(newest(Habit.self, \.updatedAt, in: context)?.timeIntervalSince1970 ?? 0)"
        let count = (try? context.fetchCount(FetchDescriptor<HabitLog>())) ?? -1
        let latest = newest(HabitLog.self, \.updatedAt, in: context) ?? .distantPast
        if s.habits != nil, habitMark == s.habitMark, count == s.logs.count, latest == s.logLatest { return }
        // 按标识取上下文里已有的习惯对象：重新 fetch 会把它们的打卡关系作废，下次读要逐个习惯重取。
        // 打卡时 HabitActions 也会动 habit.updatedAt，所以设置变没变要逐项比，不能只看修改时间
        let ids = (try? context.fetchIdentifiers(FetchDescriptor<Habit>())) ?? []
        let habits = (ids.isEmpty ? context.all(Habit.self) : ids.compactMap { context.model(for: $0) as? Habit })
            .map { (habit: $0, order: ($0.sortOrder, $0.createdAt)) }.sorted { $0.order < $1.order }.map(\.habit)
        let list = habits.map { HabitInfo(id: $0.persistentModelID, title: $0.title, symbol: $0.symbol, spec: $0.spec, archived: $0.archived) }
        func value(_ log: HabitLog) -> HabitLogValue? {
            LocalDay(key: log.dateKey).map { HabitLogValue(day: $0, completed: log.completed, quantity: log.quantity, target: log.targetAtLog) }
        }
        var patched = false
        // 习惯的设置（含数量目标）变了：改目标前补记的旧目标不动 updatedAt，打卡要整取
        if s.habits != nil, count >= 0, list.map(\.spec) == s.habitList.map(\.spec), list.map(\.id) == s.habitList.map(\.id) {
            let since = s.logLatest
            var changed = FetchDescriptor<HabitLog>(predicate: #Predicate { $0.updatedAt >= since })
            changed.relationshipKeyPathsForPrefetching = [\.habit]
            if let rows = try? context.fetch(changed) {
                for log in rows { s.logs[log.persistentModelID] = (log.habit?.persistentModelID, value(log)) }
                patched = reconcile(HabitLog.self, &s.logs, count: count, context: context) { id in
                    (context.model(for: id) as? HabitLog).map { ($0.habit?.persistentModelID, value($0)) }
                }
            }
        }
        if !patched {
            fullLoads.habits += 1
            // 整取：读各习惯的打卡关系（界面已经读过的话就在内存里，不必再取数）
            s.logs = [:]
            for habit in habits {
                for log in habit.logs ?? [] { s.logs[log.persistentModelID] = (habit.persistentModelID, value(log)) }
            }
            // 没挂在习惯上的打卡也记下（条数才对得上，下次不必再整取）
            _ = reconcile(HabitLog.self, &s.logs, count: count, context: context) { id in
                (context.model(for: id) as? HabitLog).map { ($0.habit?.persistentModelID, value($0)) }
            }
        }
        s.habitMark = habitMark
        s.habitList = list
        s.logLatest = latest
        var byOwner: [PersistentIdentifier: [HabitLogValue]] = [:]
        for (owner, value) in s.logs.values {
            if let owner, let value { byOwner[owner, default: []].append(value) }
        }
        // 按日期排出固定顺序。同一天有不止一条记录（只有旧数据会有）时 HabitStats 以最后一条为准：
        // 关系里的先后本来就不固定，这里让记了完成、数量多的排在后面
        s.habits = list.map { h in
            let logs = (byOwner[h.id] ?? []).sorted {
                ($0.day, $0.completed ? 1 : 0, $0.quantity ?? 0) < ($1.day, $1.completed ? 1 : 0, $1.quantity ?? 0)
            }
            return RecordHabit(title: h.title, symbol: h.symbol, spec: h.spec, logs: logs, archived: h.archived)
        }
    }

    /// 条数对不上时按标识对账：删掉已经不在的；缺的（新插入、带旧时间插回来的、保存后换了正式标识的）不多就逐条补取。
    /// 对上了返回 true；对不上（取数出错、缺得太多）返回 false，由调用方整取
    private static func reconcile<T: PersistentModel, V>(_ type: T.Type, _ values: inout [PersistentIdentifier: V], count: Int,
                                                        context: ModelContext, fetch: (PersistentIdentifier) -> V?) -> Bool {
        if values.count == count { return true }
        guard let ids = try? context.fetchIdentifiers(FetchDescriptor<T>()) else { return false }
        let alive = Set(ids)
        values = values.filter { alive.contains($0.key) }
        let missing = ids.filter { values[$0] == nil }
        guard missing.count <= patchLimit else { return false }
        for id in missing {
            guard let value = fetch(id) else { return false }
            values[id] = value
        }
        return values.count == count
    }
}
