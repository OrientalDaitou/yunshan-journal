import SwiftUI
import SwiftData

// 修行录的辅助部件：落笔草稿、删除快照（可撤销）、搜索索引、复盘“本期素材”。

// MARK: - 落笔草稿

/// 落笔框草稿存进偏好设置（键名 `draft.<页面>.<字段>`），切页、⌘数字切换、重启都不丢；入卷成功后清空。
/// 页面：`chronicle`（修行录落笔框）、`dashboard`（今日洞府落笔）、`quick`（随手记浮窗）。
/// 默认读写 `AppPreferences.defaults`，与页面上 @AppStorage 存的同一份（调试实例、离屏渲染各用各的，不碰正式应用的草稿）。
enum JournalDraft {
    static func key(_ page: String, _ field: String) -> String { "draft.\(page).\(field)" }

    /// 这个落笔框是否还没写东西（只套了模板、一个字没写也算空）
    static func isBlank(page: String, defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        let title = defaults.string(forKey: key(page, "title")) ?? ""
        let text = defaults.string(forKey: key(page, "text")) ?? ""
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isBlankBody(text, defaults: defaults)
    }

    /// 正文是否还没写东西：与“落笔入卷”点不点得动同一个判定（JournalTemplates.isSkeleton）——空白，或只有没动过的模板骨架
    /// （复盘四段、晚课三省、读书札记、一事一记，以及偏好里自存的只有段名的模板）
    static func isBlankBody(_ text: String, defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        JournalTemplates.isSkeleton(text, custom: JournalTemplateStore.load(defaults))
    }

    /// 在今日洞府写了几句、点“翻开修行录”想补标题和标签：修行录的落笔框是空的，就把草稿挪过去接着写。
    static func moveIfTargetBlank(from source: String, to target: String, defaults: UserDefaults = AppPreferences.defaults) {
        guard !isBlank(page: source, defaults: defaults), isBlank(page: target, defaults: defaults) else { return }
        // 标签、补记日期也以源页面为准（今日洞府没有这两项，等于清掉修行录里残留的），免得套到挪过来的正文上
        for field in ["kind", "title", "text", "mood", "tags", "day"] {
            if let value = defaults.object(forKey: key(source, field)) {
                defaults.set(value, forKey: key(target, field))
            } else {
                defaults.removeObject(forKey: key(target, field))
            }
        }
        // 复盘周期只对复盘有意义：挪过去的是复盘，就和源页面看到的一致；不是复盘，保留修行录原来选的周期
        if defaults.string(forKey: key(target, "kind")) == JournalKind.review.rawValue {
            if let value = defaults.object(forKey: key(source, "period")) {
                defaults.set(value, forKey: key(target, "period"))
            } else {
                defaults.removeObject(forKey: key(target, "period"))
            }
        }
        // 源页面整个复位：类型回到日记，以后在这里随手写的一句不会被当成复盘入卷
        defaults.set("", forKey: key(source, "title"))
        defaults.set("", forKey: key(source, "text"))
        for field in ["mood", "kind", "period"] {
            defaults.removeObject(forKey: key(source, field))
        }
    }

    /// 进页面时清掉“过期”的草稿设置（以前这些每次进页面都会重置）：落笔框什么都没写（标题、正文、标签都空）时，
    /// 补记日期回到今天；停在“复盘”却只剩空白模板的，类型回到日记。写了东西的草稿原样保留。
    /// - Parameter keepKind: 马上要按跳转请求设定类型（例如周复盘提醒）时传 true，类型和模板交给跳转处理
    static func resetIfBlank(page: String, keepKind: Bool = false, defaults: UserDefaults = AppPreferences.defaults) {
        let tags = defaults.string(forKey: key(page, "tags")) ?? ""
        guard isBlank(page: page, defaults: defaults), tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        defaults.removeObject(forKey: key(page, "day"))
        if !keepKind, defaults.string(forKey: key(page, "kind")) == JournalKind.review.rawValue {
            defaults.set(JournalKind.diary.rawValue, forKey: key(page, "kind"))
            defaults.set("", forKey: key(page, "text"))
        }
    }
}

// MARK: - 删除与撤销

/// 删除前给一条记录拍的值快照：撤销时原样插回（uid、来源、传书批次、创建时间都不变，传书撤销仍认得它）。
struct JournalSnapshot {
    var uid: String
    var kind: String
    var title: String
    var body: String
    var dateKey: String
    var minute: Int?
    var mood: Int?
    var period: String
    var tags: [String]
    var source: String
    var sourceNote: String
    var deliveryID: String
    var pinned: Bool
    var createdAt: Date
    var updatedAt: Date

    init(_ e: JournalEntry) {
        uid = e.uid
        kind = e.kind
        title = e.title
        body = e.body
        dateKey = e.dateKey
        minute = e.minute
        mood = e.mood
        period = e.period
        tags = e.tags
        source = e.source
        sourceNote = e.sourceNote
        deliveryID = e.deliveryID
        pinned = e.pinned
        createdAt = e.createdAt
        updatedAt = e.updatedAt
    }

    /// 提示里显示的名字
    var label: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return String(t.prefix(20)) }
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? (JournalKind(rawValue: kind)?.label ?? "记录") : String(firstLine.prefix(20))
    }

    @discardableResult
    func restore(into context: ModelContext) -> JournalEntry {
        let entry = JournalEntry(kind: JournalKind(rawValue: kind) ?? .note, title: title, body: body, dateKey: dateKey)
        entry.kind = kind
        entry.uid = uid
        entry.minute = minute
        entry.mood = mood
        entry.period = period
        entry.tags = tags
        entry.source = source
        entry.sourceNote = sourceNote
        entry.deliveryID = deliveryID
        entry.pinned = pinned
        entry.createdAt = createdAt
        entry.updatedAt = updatedAt
        context.insert(entry)
        return entry
    }
}

/// 页面底部“已删除 · 撤销删除”提示（约 8 秒）
struct DeletedEntryOffer: Identifiable, Equatable {
    let id = UUID()
    var snapshot: JournalSnapshot

    static func == (a: DeletedEntryOffer, b: DeletedEntryOffer) -> Bool { a.id == b.id }
}

// MARK: - 修行录摘要与搜索
// （这一节只用到数据模型和 Core，性能基准 .night/perfbench-chronicle 直接摘出这一节编译，和应用跑的是同一份代码）

/// 修行录摘要：每篇只留筛选、排序、计数要用的几个值（外加拼好的原文，供搜索），按“新的在前”排好。修行录页和全局搜索共用。
///
/// 为什么要它：SwiftData 每取出一篇约 0.1 ms，整表 @Query（4000 篇约 0.3–0.4 秒）在任何一次保存之后都要整表重取。
/// 摘要只在修行录真的变了时才动：保存通知里带着改了哪几篇，就只重取那几篇；
/// 篇数或最近的修改时间对不上（例如还没保存的改动），或者改过的那篇和别的篇三个排序键完全相同（先后说不准），才整表重建一次。
/// 页面只把正要显示的那几十篇取成对象。
@MainActor
final class JournalDigest {
    static let shared = JournalDigest()

    struct Row {
        let id: PersistentIdentifier
        var dateKey: String
        /// 解析好的日期；认不出的写法为 nil
        var day: LocalDay?
        /// 没记时刻为 -1（与 JournalOrder.newestFirst 相同）
        var minute: Int
        var createdAt: Date
        var updatedAt: Date
        var kind: String
        var mood: Int?
        var pinned: Bool
        var isFromCourier: Bool
        var tags: [String]
        /// 标题、正文、标签拼成的原文（搜索时由 JournalSearchIndex 转小写并缓存）
        var text: String

        init(_ e: JournalEntry) {
            id = e.persistentModelID
            dateKey = e.dateKey
            day = LocalDay(key: e.dateKey)
            minute = e.minute ?? -1
            createdAt = e.createdAt
            updatedAt = e.updatedAt
            kind = e.kind
            mood = e.mood
            pinned = e.pinned
            isFromCourier = e.isFromCourier
            tags = e.tags
            text = e.title + "\n" + e.body + "\n" + e.tags.joined(separator: " ")
        }

        /// 新的在前：日期、时刻、创建时间（与 JournalOrder.newestFirst 的比较完全相同）
        static func newer(_ a: Row, _ b: Row) -> Bool {
            if a.dateKey != b.dateKey { return a.dateKey > b.dateKey }
            if a.minute != b.minute { return a.minute > b.minute }
            return a.createdAt > b.createdAt
        }

        /// 三个排序键都相同（谁先谁后只取决于库里的存放次序）
        func ties(_ other: Row) -> Bool { dateKey == other.dateKey && minute == other.minute && createdAt == other.createdAt }
    }

    /// 某一刻的摘要。rows 已按新的在前排好；version 每次内容有变就加一，视图拿它判断要不要重算。
    struct Snapshot: Equatable {
        let rows: [Row]
        let version: Int
        /// 所有日期都是规范的 YYYY-MM-DD：这时字符串的先后就是日期的先后，统计可以在越过所需日期后提前停下
        let ordered: Bool

        static func == (a: Snapshot, b: Snapshot) -> Bool { a.version == b.version }
    }

    private var rows: [Row] = []
    private var version = 0
    private var ordered = true
    /// 摘要的是哪个数据库（StoreIdentity 的钥匙：一库一把，内存地址被新库复用也不会认错）
    private var containerID: StoreIdentity.Key?
    private var built = false
    /// 重建时库里还有没保存的改动：这时取出来的结果里，三个排序键完全相同的几篇先后不固定（原来的 @Query 也一样），
    /// 等改动存进去以后再整表重建一次，先后就和原来保存后重取的一致
    private var provisional = false
    /// 保存通知里记下的、还没并进摘要的改动
    private var changed = Set<PersistentIdentifier>()
    private var deleted = Set<PersistentIdentifier>()
    private var token: NSObjectProtocol?

    private init() {
        // 只记下改了哪几篇，等页面下次刷新（sync）时再并进来；保存通知在保存的那个线程上发出
        token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { note in
            // 没领过钥匙的库一定不是摘要的那个（只查不领，不因此留住别的库）
            guard let saved = note.object as? ModelContext, let container = StoreIdentity.existingKey(for: saved.container) else { return }
            let info = note.userInfo ?? [:]
            func ids(_ key: ModelContext.NotificationKey) -> [PersistentIdentifier] {
                ((info[key.rawValue] as? [PersistentIdentifier]) ?? []).filter { $0.entityName == "JournalEntry" }
            }
            let changed = ids(.insertedIdentifiers) + ids(.updatedIdentifiers)
            let deleted = ids(.deletedIdentifiers)
            let everything = info[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue] != nil
            guard everything || !changed.isEmpty || !deleted.isEmpty else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    JournalDigest.shared.record(container: container, changed: changed, deleted: deleted, everything: everything)
                }
            } else {
                Task { @MainActor in
                    JournalDigest.shared.record(container: container, changed: changed, deleted: deleted, everything: everything)
                }
            }
        }
    }

    private func record(container: StoreIdentity.Key, changed: [PersistentIdentifier], deleted: [PersistentIdentifier], everything: Bool) {
        guard built, container == containerID else { return }
        if everything { built = false; return }
        self.changed.formUnion(changed)
        self.deleted.formUnion(deleted)
    }

    /// 页面刷新时调用：核对并更新摘要。没有变化时只花两次很小的查询（篇数、最近修改的一篇）。
    func sync(_ context: ModelContext) -> Snapshot {
        let container = StoreIdentity.key(for: context)
        if container != containerID {
            containerID = container
            built = false
        }
        let count = (try? context.fetchCount(FetchDescriptor<JournalEntry>())) ?? -1
        var latest = FetchDescriptor<JournalEntry>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        latest.fetchLimit = 1
        let stamp = (try? context.fetch(latest))?.first?.updatedAt
        if built && provisional && !context.hasChanges { built = false }
        if built {
            if (!changed.isEmpty || !deleted.isEmpty) && !merge(context) { built = false }
            if built && (rows.count != count || rows.lazy.map(\.updatedAt).max() != stamp) { built = false }
        }
        if !built { rebuild(context) }
        return Snapshot(rows: rows, version: version, ordered: ordered)
    }

    /// 整表重建：取法与原来修行录页的 @Query 相同（按日期倒序），再按 JournalOrder.newestFirst 的规则稳定排序
    private func rebuild(_ context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<JournalEntry>(sortBy: [Self.sorted(\.dateKey, .reverse)]))) ?? []
        rows = all.map(Row.init).sorted(by: Row.newer)
        ordered = rows.allSatisfy { $0.day?.key == $0.dateKey }
        changed = []
        deleted = []
        built = true
        provisional = context.hasChanges
        version += 1
        JournalSearchIndex.shared.prune(keeping: Set(rows.map(\.id)))
    }

    /// 只并入保存通知里记下的几篇。返回 false 表示这次说不准先后，要整表重建。
    private func merge(_ context: ModelContext) -> Bool {
        let gone = deleted
        let ids = Array(changed.subtracting(gone))
        changed = []
        deleted = []
        let fetched = ids.isEmpty ? [] : ((try? context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { ids.contains($0.persistentModelID) }))) ?? [])
        // 通知里有、库里已经取不到的（之后又删了）也去掉
        let removed = gone.union(Set(ids).subtracting(fetched.map(\.persistentModelID)))
        if !removed.isEmpty { rows.removeAll { removed.contains($0.id) } }
        var position = Dictionary(rows.indices.map { (rows[$0].id, $0) }, uniquingKeysWith: { a, _ in a })
        // 新增的、或者排序键变了的：要看它落到哪里。只改了别的（例如珍藏、正文）的原地替换，先后不变
        var moved = Set<PersistentIdentifier>()
        for entry in fetched {
            let row = Row(entry)
            if let index = position[row.id] {
                if !rows[index].ties(row) { moved.insert(row.id) }
                rows[index] = row
            } else {
                position[row.id] = rows.count
                rows.append(row)
                moved.insert(row.id)
            }
        }
        if !moved.isEmpty { rows.sort(by: Row.newer) }
        // 挪动过的那几篇和相邻的某篇三个键完全相同时，先后要按库里的存放次序，只能整表重建
        for index in rows.indices where moved.contains(rows[index].id) {
            if index > 0 && rows[index].ties(rows[index - 1]) { return false }
            if index + 1 < rows.count && rows[index].ties(rows[index + 1]) { return false }
        }
        ordered = rows.allSatisfy { $0.day?.key == $0.dateKey }
        version += 1
        return true
    }

    /// 把要显示的几篇取成对象：已在内存里的直接用，其余一次取回；按 ids 的次序返回（取不到的略过）。
    func entries(_ ids: [PersistentIdentifier], in context: ModelContext) -> [JournalEntry] {
        var found: [PersistentIdentifier: JournalEntry] = [:]
        var missing: [PersistentIdentifier] = []
        for id in ids {
            if let entry: JournalEntry = context.registeredModel(for: id), !entry.isDeleted { found[id] = entry } else { missing.append(id) }
        }
        if !missing.isEmpty {
            let fetched = (try? context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { missing.contains($0.persistentModelID) }))) ?? []
            for entry in fetched { found[entry.persistentModelID] = entry }
        }
        return ids.compactMap { found[$0] }
    }

    /// 用 Comparable 的那个初始化方法建排序（与 @Query(sort:order:) 相同；字符串不走 localizedStandard 的重载）
    static func sorted<Value: Comparable>(_ keyPath: KeyPath<JournalEntry, Value>, _ order: SortOrder) -> SortDescriptor<JournalEntry> {
        SortDescriptor(keyPath, order: order)
    }
}

/// 卷中气象要的几个数（修行录左栏）
struct JournalStats: Equatable {
    var thisMonth = 0
    var reviews = 0
    var streak = 0
    /// 近 30 日每天的心境（只含那 30 天里记了心境的日子）
    var moods: [LocalDay: [Int]] = [:]
}

@MainActor
extension JournalDigest.Snapshot {
    /// 时间线的筛选（类型 / 珍藏 / 传书、某一天、标签、月份、关键词），次序不变。query 须已转小写、去掉首尾空白。
    func matching(filter: String, day: String?, tag: String?, month: String?, query: String) -> [JournalDigest.Row] {
        let index = JournalSearchIndex.shared
        return rows.filter { r in
            switch filter {
            case "courier": guard r.isFromCourier else { return false }
            case "pinned": guard r.pinned else { return false }
            case "all": break
            default: guard r.kind == filter else { return false }
            }
            if let day, r.dateKey != day { return false }
            if let tag, !r.tags.contains(tag) { return false }
            if let month, !r.dateKey.hasPrefix(month) { return false }
            if !query.isEmpty, !index.matches(r, lowered: query) { return false }
            return true
        }
    }

    /// 类型筛选各项的篇数
    func kindCounts() -> (byKind: [String: Int], pinned: Int, courier: Int) {
        var byKind: [String: Int] = [:]
        var pinned = 0, courier = 0
        for r in rows {
            byKind[r.kind, default: 0] += 1
            if r.pinned { pinned += 1 }
            if r.isFromCourier { courier += 1 }
        }
        return (byKind, pinned, courier)
    }

    /// 标签下拉：多的在前，同样多的按字排
    func tagOptions() -> [(key: String, value: Int)] {
        Dictionary(rows.flatMap(\.tags).map { ($0, 1) }, uniquingKeysWith: +)
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
    }

    /// 月份下拉：新的在前
    func monthOptions() -> [(key: String, value: Int)] {
        Dictionary(rows.map { (String($0.dateKey.prefix(7)), 1) }, uniquingKeysWith: +)
            .sorted { $0.key > $1.key }
    }

    /// 卷中气象：本月落笔、复盘篇数、连续落笔天数、近 30 日心境。
    /// 日期都规范时（ordered），越过本月和 30 天窗口就停，连续天数也顺着倒序往回数；否则按原来的办法整表走一遍。
    func stats(today: LocalDay) -> JournalStats {
        var stats = JournalStats()
        let monthKey = String(today.key.prefix(7))
        let first = today.adding(days: -29)
        stats.reviews = rows.reduce(0) { $0 + ($1.kind == JournalKind.review.rawValue ? 1 : 0) }
        // 字符串小于这两个界的，都不在本月、也不在 30 天里
        let floor = min(first.key, monthKey)
        for r in rows {
            if ordered && r.dateKey < floor { break }
            if r.dateKey.hasPrefix(monthKey) { stats.thisMonth += 1 }
            if let m = r.mood, let d = r.day, d >= first, d <= today { stats.moods[d, default: []].append(m) }
        }
        stats.streak = streak(today: today)
        return stats
    }

    /// 连续落笔：今天写了从今天数，没写从昨天数，往回数到第一个空白日
    private func streak(today: LocalDay) -> Int {
        guard ordered else {
            let days = Set(rows.map(\.dateKey))
            var day = days.contains(today.key) ? today : today.adding(days: -1)
            var count = 0
            while days.contains(day.key) {
                count += 1
                day = day.adding(days: -1)
            }
            return count
        }
        // 倒序走：先越过今天以后的，再逐日对上；同一天的几篇跳过，对不上就停
        let todayKey = today.key
        var index = rows.startIndex
        while index < rows.endIndex, rows[index].dateKey > todayKey { index += 1 }
        var day = index < rows.endIndex && rows[index].dateKey == todayKey ? today : today.adding(days: -1)
        var key = day.key
        var count = 0
        while index < rows.endIndex {
            let k = rows[index].dateKey
            if k > key {
                index += 1
            } else if k == key {
                count += 1
                day = day.adding(days: -1)
                key = day.key
                index += 1
            } else {
                break
            }
        }
        return count
    }

    /// 往日回看：一周、一月、半年、一年前的今天（往前后各放宽一天），那天每篇的 ID（摘要的次序）
    func lookBack(today: LocalDay) -> [(label: String, day: LocalDay, ids: [PersistentIdentifier])] {
        let spans: [(String, LocalDay)] = [
            ("一周前", today.adding(days: -7)),
            ("一月前", Self.monthAgo(1, today: today)),
            ("半年前", Self.monthAgo(6, today: today)),
            ("一年前", Self.monthAgo(12, today: today)),
        ]
        // 只要这 12 个日期：一次走过摘要，按日期分组
        let wanted = Set(spans.flatMap { [$0.1, $0.1.adding(days: -1), $0.1.adding(days: 1)].map(\.key) })
        var byDay: [String: [PersistentIdentifier]] = [:]
        for r in rows where wanted.contains(r.dateKey) { byDay[r.dateKey, default: []].append(r.id) }
        return spans.compactMap { label, day in
            let found = [day, day.adding(days: -1), day.adding(days: 1)].lazy.compactMap { d in byDay[d.key].map { (d, $0) } }.first
            return found.map { (label, $0.0, $0.1) }
        }
    }

    static func monthAgo(_ months: Int, today: LocalDay) -> LocalDay {
        var y = today.year, m = today.month - months
        while m <= 0 { m += 12; y -= 1 }
        let lastDay = LocalDay(year: m == 12 ? y + 1 : y, month: m == 12 ? 1 : m + 1, day: 1).adding(days: -1).day
        return LocalDay(year: y, month: m, day: min(today.day, lastDay))
    }
}

/// 修行录搜索用的小写全文：每篇只在内容变化（updatedAt 变了）后才重新转小写，
/// 打字搜索时不再把所有正文重复转一遍。修行录页和全局搜索共用（原文取自修行录摘要）。
@MainActor
final class JournalSearchIndex {
    static let shared = JournalSearchIndex()
    private var cache: [PersistentIdentifier: (stamp: Date, text: String)] = [:]

    func text(of row: JournalDigest.Row) -> String {
        if let hit = cache[row.id], hit.stamp == row.updatedAt { return hit.text }
        let text = row.text.lowercased()
        cache[row.id] = (row.updatedAt, text)
        return text
    }

    /// `lowered` 须已转小写、去掉首尾空白
    func matches(_ row: JournalDigest.Row, lowered: String) -> Bool {
        lowered.isEmpty || text(of: row).contains(lowered)
    }

    /// 摘要整表重建时顺手清掉已删除的篇目（以前只增不删）
    func prune(keeping ids: Set<PersistentIdentifier>) {
        cache = cache.filter { ids.contains($0.key) }
    }
}

enum JournalOrder {
    /// 新的在前：日期、时刻、创建时间（先取出排序键，排序时不必反复读 SwiftData 属性）
    static func newestFirst(_ list: [JournalEntry]) -> [JournalEntry] {
        list.map { (entry: $0, day: $0.dateKey, minute: $0.minute ?? -1, created: $0.createdAt) }
            .sorted { a, b in
                if a.day != b.day { return a.day > b.day }
                if a.minute != b.minute { return a.minute > b.minute }
                return a.created > b.created
            }
            .map(\.entry)
    }

    /// 同一天内按时间先后（往日回看用）
    static func oldestFirst(_ list: [JournalEntry]) -> [JournalEntry] {
        list.map { (entry: $0, minute: $0.minute ?? -1, created: $0.createdAt) }
            .sorted { ($0.minute, $0.created) < ($1.minute, $1.created) }
            .map(\.entry)
    }
}

// MARK: - 复盘素材

/// 写复盘时的“本期素材”：按所选周期汇总这段时间的落笔、心境、灵感、功课、日程与花费，只读，不改任何数据。
/// 最上面是“上次许下的下一步”和近 14 天参悟时的决定（不随素材折叠，收起素材也看得到），每条点“做到了 / 没做到 / 改主意了”
/// （选择存在草稿 `draft.<页面>.followups`）；点过的签入卷时自动记进正文，也可以先点“现在插入”或下方“插入复盘正文”。
/// 素材默认展开（`chronicle.reviewMaterial.open`），展开时才去读这段时间的数据。
/// 周一写周复盘、补记日期没改过时，卡顶多一行“要写上一周的吗？[改写上一周]”。
struct ReviewMaterialCard: View {
    var period: ReviewPeriod
    /// 复盘落在哪一天（补记日期；默认今天）
    var anchor: LocalDay
    /// 补记日期改过没有（nil 是今天、没改过）：周一补写上周那一行只在没改过时出现
    var picked: LocalDay?
    /// 回访的选择存在哪个草稿键
    var followupsKey: String
    /// 正文里已经插进去的（〔本期素材〕、回访各行）：按钮与提示按它改说法，插过的不会引着再插一遍
    var inserted: ReviewThread.Inserted
    @Binding var open: Bool
    /// “改写上一周”：把补记日期改到上周日
    var onPickDay: (LocalDay) -> Void
    var onInsert: (ReviewInsertion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mondayOffer
            // 落笔框每敲一个字都会重建本卡片：周期、日期、开合、正文里插过什么都没变就不重算
            ReviewMaterialBody(period: period, anchor: anchor, open: open, inserted: inserted, followupsKey: followupsKey,
                               onToggle: { open.toggle() }, onInsert: onInsert)
                .equatable()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.info.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.info.opacity(0.18)))
    }

    /// 周一写周复盘：要不要改写上一周（点了补记日期改到上周日，素材、回访都跟着换成上一周的）
    @ViewBuilder
    private var mondayOffer: some View {
        let today = LocalDay.today()
        if let week = ReviewThread.lastWeekOffer(today: today, period: period, picked: picked) {
            WrapTrailingRow(spacing: 10, rowSpacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "calendar.badge.clock").font(.ysCaption).foregroundStyle(Theme.gold)
                    Text(ReviewThread.lastWeekOfferText(week, today: today))
                        .font(.ysCaption).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { onPickDay(week.last) } label: { Label("改写上一周", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.inlineAction(Theme.gold))
                    .help("补记日期改为 \(week.last.shortLabel)（上周日），本期素材换成上一周的")
            }
            .padding(.bottom, 2)
        }
    }
}

/// 交给落笔框插进正文的：素材一段（正文里已有〔本期素材〕或只插回访时为 nil），
/// 加上点过签的回访（做到的进【所得】，没做到的进【所失】，改主意的进【所悟】）
struct ReviewInsertion {
    var block: String?
    var followups: [(text: String, verdict: ReviewThread.Verdict)]

    /// 回访照签插（插过的跳过，改过签的换掉旧行）；素材只在正文里还没有〔本期素材〕时插，再点一次不会整段重复
    /// （七日小卷存的周复盘草稿里已经插好素材，这里只补回访）
    @MainActor
    func applied(to text: String) -> String {
        let result = ReviewThread.insert(followups, into: text)
        guard let block, !ReviewThread.inserted(in: result).material else { return result }
        return ReviewMaterial.insert(block, into: result)
    }
}

/// 只比较周期、日期、开合与正文里插过什么：上层带来的重建（落笔框每敲一个字、新的闭包）跳过。
/// 不挂整表 @Query：回访（上次的下一步、参悟的决定）按日期取一次、算好存起来；素材展开时才取；之后数据库有保存（例如传书送来新记录）才重算。
/// 被跳过时保留的旧闭包也没问题：它们改的是落笔框的 @AppStorage（正文、开合），读写的总是当前值。
/// 回访点签只改草稿里的选择（本视图自己的 @AppStorage），不重算。
private struct ReviewMaterialBody: View, Equatable {
    var period: ReviewPeriod
    var anchor: LocalDay
    var open: Bool
    var inserted: ReviewThread.Inserted
    var onToggle: () -> Void
    var onInsert: (ReviewInsertion) -> Void
    @Environment(\.modelContext) private var context
    @AppStorage private var followups: String
    /// 算好的回访与素材。放在引用里：body 里读写它不算改状态，不会引起再刷新
    @State private var cache = ReviewMaterialCache()
    /// 挂上以来数据库保存过几次：变了就重算
    @State private var saves = 0

    init(period: ReviewPeriod, anchor: LocalDay, open: Bool, inserted: ReviewThread.Inserted, followupsKey: String,
         onToggle: @escaping () -> Void, onInsert: @escaping (ReviewInsertion) -> Void) {
        self.period = period
        self.anchor = anchor
        self.open = open
        self.inserted = inserted
        self.onToggle = onToggle
        self.onInsert = onInsert
        _followups = AppStorage(wrappedValue: "", followupsKey)
    }

    static func == (a: Self, b: Self) -> Bool {
        a.period == b.period && a.anchor == b.anchor && a.open == b.open && a.inserted == b.inserted
    }

    var body: some View {
        let range = ReviewMaterial.range(period: period, anchor: anchor)
        let thread = cache.thread(key: "\(period.rawValue)|\(anchor.key)|\(saves)") {
            ReviewMaterial.Recall(promise: ReviewThread.latest(before: anchor, period: period, context: context),
                                  decision: ReviewThread.decision(near: anchor, context: context))
        }
        let picked = thread.picked(ReviewThread.decode(followups))
        let pending = picked.filter { !inserted.has($0.text, $0.verdict) }
        VStack(alignment: .leading, spacing: 8) {
            if thread.promise != nil || thread.decision != nil {
                ReviewFollowupBlock(promise: thread.promise, decision: thread.decision, chosen: ReviewThread.decode(followups),
                                    picked: picked.count, pending: pending.count,
                                    onPick: { key, verdict in followups = ReviewThread.toggled(followups, key: key, verdict: verdict) },
                                    onInsert: { onInsert(ReviewInsertion(block: nil, followups: picked)) })
                    .padding(.bottom, 2)
            }
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: TypeSize.micro, weight: .bold)).foregroundStyle(Theme.inkSoft)
                    Image(systemName: "tray.full").font(.ysCaption).foregroundStyle(Theme.info)
                    Text("本期素材").font(Theme.songti(TypeSize.callout, .semibold)).foregroundStyle(Theme.ink)
                    Text(range.label).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("这段时间的落笔、心境、灵感、功课、日程与花费，写【所得】【所失】时参考")
            if open {
                materialLines(range: range, picked: picked, pending: pending.count)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { note in
            if (note.object as? ModelContext) === context { saves += 1 }
        }
    }

    /// 素材各行与“插入复盘正文”：正文里已有〔本期素材〕时按钮改成“补插回访 N 条”，都插过了就灰掉
    private func materialLines(range: (first: LocalDay, last: LocalDay, label: String),
                               picked: [(text: String, verdict: ReviewThread.Verdict)], pending: Int) -> some View {
        let lines = cache.lines(key: "\(period.rawValue)|\(range.first.key)|\(range.last.key)|\(saves)") {
            ReviewMaterial.lines(context: context, first: range.first, last: range.last, period: period)
        }
        let label: (String, String) = !inserted.material ? ("插入复盘正文", "text.insert")
            : pending > 0 ? ("补插回访 \(pending) 条", "text.insert") : ("素材已在正文里", "checkmark")
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(lines.indices, id: \.self) { index in
                Text("· " + lines[index])
                    .font(.ysCallout)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            WrapTrailingRow(spacing: 10, rowSpacing: 6) {
                Hint(!inserted.material && pending > 0 ? "回访 \(pending) 条会一起插进去；只读汇总，不改任何记录。" : "只读汇总，不改任何记录。")
                Button {
                    onInsert(ReviewInsertion(block: inserted.material ? nil : ReviewMaterial.block(lines: lines, label: range.label),
                                             followups: picked))
                } label: { Label(label.0, systemImage: label.1) }
                    .buttonStyle(.yunshanCompact)
                    .disabled(inserted.material && pending == 0)
                    .help(inserted.material ? (pending > 0 ? "素材已在正文里，只把还没插的回访 \(pending) 条接进【所得】【所失】【所悟】"
                                                           : "本期素材和点过的回访都已在正文里")
                                            : pending > 0 ? "素材插在【所得】【所失】下方；回访的 \(pending) 条分别接在【所得】【所失】【所悟】里"
                                                          : "插在【所得】【所失】下方，作为写复盘时的参考")
            }
            .padding(.top, 2)
        }
    }
}

/// “上次许下的下一步 · 10月12日–18日 周复盘”：逐条三枚小签；下面一行参悟时的决定，同样三枚签；
/// 卡底一行说清点过的签什么时候进正文（入卷时自动记进去），还没进正文的可以“现在插入”
private struct ReviewFollowupBlock: View {
    var promise: ReviewThread.Promise?
    var decision: ReviewThread.Decision?
    var chosen: [String: ReviewThread.Verdict]
    /// 点过签的几条、其中还没进正文的几条
    var picked: Int
    var pending: Int
    var onPick: (String, ReviewThread.Verdict) -> Void
    var onInsert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let promise {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.uturn.backward.circle").font(.ysCaption).foregroundStyle(Theme.gold)
                    Text("上次许下的下一步").font(Theme.songti(TypeSize.callout, .semibold)).foregroundStyle(Theme.ink)
                        .fixedSize()
                    Text("· " + promise.label).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                        .lineLimit(1)
                        .help(promise.title.isEmpty ? promise.label : "「\(promise.title)」")
                }
                ForEach(promise.steps, id: \.self) { step in
                    row(key: promise.key(step)) {
                        Text("· " + step).font(.ysCallout).foregroundStyle(Theme.text)
                    }
                }
            }
            if let decision {
                row(key: decision.key) {
                    (Text("参悟时的决定 · \(decision.day.shortLabel)：").foregroundStyle(Theme.inkSoft) + Text(decision.text).foregroundStyle(Theme.text))
                        .font(.ysCallout)
                }
                .padding(.top, promise == nil ? 0 : 2)
            }
            footer
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        // 左侧一道金线：与“旧笔新读”的引文同一种写法，表示这是自己从前写下的话
        .overlay(alignment: .leading) {
            Capsule().fill(Theme.gold.opacity(0.55)).frame(width: 2).padding(.vertical, 8).padding(.leading, 4)
        }
    }

    /// 没点：说清点了会怎样；有没进正文的：入卷时自动记进去，也可现在插入；都进了：说一声
    @ViewBuilder
    private var footer: some View {
        if picked == 0 {
            Hint("点过的签，入卷时自动记进正文：做到的进【所得】，没做到的进【所失】，改主意的进【所悟】。")
        } else if pending > 0 {
            WrapTrailingRow(spacing: 10, rowSpacing: 4) {
                Hint("\(pending) 条还没进正文，入卷时自动记进去：做到的进【所得】，没做到的进【所失】，改主意的进【所悟】。")
                Button(action: onInsert) { Label("现在插入", systemImage: "text.insert") }
                    .buttonStyle(.inlineAction(Theme.gold))
                    .help("把这 \(pending) 条先接进正文，好在后面接着写几句；改过签的会换掉原来那一行")
            }
        } else {
            Hint("点过的 \(picked) 条都已在正文里。", symbol: "checkmark")
        }
    }

    private func row<Content: View>(key: String, @ViewBuilder label: () -> Content) -> some View {
        WrapTrailingRow(spacing: 10, rowSpacing: 4) {
            label()
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                ForEach(ReviewThread.Verdict.allCases) { verdict in
                    FollowupChip(verdict: verdict, on: chosen[key] == verdict) { onPick(key, verdict) }
                }
            }
            .fixedSize()
        }
    }
}

/// 回访的一枚小签：做到了（玉色）/ 没做到（墨色）/ 改主意了（金色）。都不用朱砂：没做到不是警示。
/// 选上时实底、前面亮一个小勾、微微一圈柔光；悬停底色与描边加深一档（动效开时淡入，关时直接变）。
/// 选上的实底：做到了是玉色实底（深色下是一块温玉）；没做到、改主意了在深色下用中等明度的墨、金底配浅字，
/// 不比“做到了”更亮——先报喜，“没做到”不是整块最先跳出来的那枚
private struct FollowupChip: View {
    var verdict: ReviewThread.Verdict
    var on: Bool
    var action: () -> Void
    @Environment(\.spiritMotion) private var motion
    @State private var hover = false

    private var tint: Color {
        switch verdict {
        case .done: Theme.positive
        case .missed: Theme.inkSoft
        case .changed: Theme.gold
        }
    }

    /// 选上时的实底（浅色与原来相同：墨 / 金实色；深色压暗到与玉色实底同一档）
    private static let missedFill = Color.adaptive(light: 0x627367, dark: 0x3E5651)
    private static let changedFill = Color.adaptive(light: 0x9B7951, dark: 0x6A5638)

    private var fill: AnyShapeStyle {
        switch verdict {
        case .done: AnyShapeStyle(Theme.jadeFill)
        case .missed: AnyShapeStyle(Self.missedFill)
        case .changed: AnyShapeStyle(Self.changedFill)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if on {
                    Image(systemName: "checkmark").font(.system(size: TypeSize.micro - 1, weight: .bold))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                Text(verdict.label).lineLimit(1)
            }
            .font(.system(size: TypeSize.caption, weight: on ? .semibold : .regular))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            // 实底上的字：浅色白字，深色浅米色（三枚一致）
            .foregroundStyle(on ? Theme.onJadeFill : (hover ? tint : Theme.inkSoft))
            .background(on ? fill : AnyShapeStyle(tint.opacity(hover ? 0.14 : 0.06)), in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color.clear : tint.opacity(hover ? 0.5 : 0.28)))
            .shadow(color: on ? tint.opacity(0.3) : .clear, radius: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .animation(motion ? Motion.quick : nil, value: on)
        .animation(motion ? Motion.hover : nil, value: hover)
        .onHover { hover = $0 }
        .help(on ? "再点一次取消" : "\(verdict.label)：入卷（或插入）时接在【\(verdict.section)】里")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 回访与素材的缓存：键（周期、日期、第几次保存）没变就直接用上次算好的；素材只在展开时算
private final class ReviewMaterialCache {
    private var threadKey: String?
    private var threadValue = ReviewMaterial.Recall(promise: nil, decision: nil)
    private var linesKey: String?
    private var linesValue: [String] = []

    func thread(key: String, _ make: () -> ReviewMaterial.Recall) -> ReviewMaterial.Recall {
        if key != threadKey {
            threadValue = make()
            threadKey = key
        }
        return threadValue
    }

    func lines(key: String, _ make: () -> [String]) -> [String] {
        if key != linesKey {
            linesValue = make()
            linesKey = key
        }
        return linesValue
    }
}

// MARK: - 复盘回访的取数（纯函数在 Core/ReviewThread.swift）

extension ReviewThread {
    /// 上一次许下的“下一步”
    struct Promise: Equatable {
        var day: LocalDay
        /// 那一篇的周期（rawValue，没填为空）
        var period: String
        var title: String
        var steps: [String]
        /// “10月12日–18日 周复盘”
        var label: String

        /// 回访选择的键：带上那一篇的日期，换了一篇（下周写着同样一句）不会沿用这次点的签
        func key(_ step: String) -> String { "\(day.key) \(step)" }
    }

    /// 参悟时写下的“我的决定”（第一行，过长截断）
    struct Decision: Equatable {
        var day: LocalDay
        var text: String
        /// 回访选择的键
        var key: String { "\(day.key) 决定 \(text)" }
        /// 插进正文的那一句
        var line: String { "\(text)（参悟时的决定）" }
    }

    /// before 那天（正在写的这篇的补记日期）之前（不含当天）最近一篇写了【下一步】的同周期复盘；同周期的都没写时，
    /// 取最近一篇写了的任意复盘。都没有时 nil。
    /// 不从“这一期开始之前”算起：10月1日写的九月复盘、周一没改日期写的上周复盘，落在正在写的这一期里，许下的正是这一期要做的，
    /// 这时小标题写“10月1日写的月复盘”，不与这期同名（见 ReviewThread.promiseLabel）。
    /// 先按周期单独取最近 30 篇同周期的（每天写日省的人，同周期那篇也不会被几十篇日省挤出去），没有再取最近 60 篇任意复盘；
    /// 5 年数据也只取这几十篇。首页、七日小卷也可以用它
    @MainActor
    static func latest(before day: LocalDay, period: ReviewPeriod, context: ModelContext, today: LocalDay = .today()) -> Promise? {
        let kind = JournalKind.review.rawValue, key = day.key, raw = period.rawValue
        func newest(_ predicate: Predicate<JournalEntry>, limit: Int) -> (entry: JournalEntry, steps: [String])? {
            var descriptor = FetchDescriptor<JournalEntry>(predicate: predicate, sortBy: [SortDescriptor(\.dateKey, order: .reverse)])
            descriptor.fetchLimit = limit
            return JournalOrder.newestFirst((try? context.fetch(descriptor)) ?? []).lazy
                .map { (entry: $0, steps: ReviewThread.nextSteps(from: $0.body)) }.first { !$0.steps.isEmpty }
        }
        guard let found = newest(#Predicate { $0.kind == kind && $0.period == raw && $0.dateKey < key }, limit: 30)
                ?? newest(#Predicate { $0.kind == kind && $0.dateKey < key }, limit: 60) else { return nil }
        let entry = found.entry
        return Promise(day: entry.day, period: entry.period, title: entry.title, steps: found.steps,
                       label: promiseLabel(period: entry.period, day: entry.day, today: today, writing: (period, day)))
    }

    /// 近 14 天（anchor 往前 13 天到 anchor 当天）参悟时写下的决定，取最近的一条；没有时 nil
    @MainActor
    static func decision(near anchor: LocalDay, context: ModelContext) -> Decision? {
        let since = anchor.adding(days: -13).date(), until = anchor.adding(days: 1).date()
        var descriptor = FetchDescriptor<AdviceRecord>(predicate: #Predicate { $0.createdAt >= since && $0.createdAt < until },
                                                       sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 30
        for record in (try? context.fetch(descriptor)) ?? [] {
            let line = record.decision.split(whereSeparator: \.isNewline).lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            guard !line.isEmpty else { continue }
            let text = line.count > 40 ? String(line.prefix(40)) + "…" : line
            return Decision(day: LocalDay(date: record.createdAt), text: text)
        }
        return nil
    }
}

@MainActor
enum ReviewMaterial {
    /// 周期对应的日期范围：日 = 当天；周 = 当周周一起；月 = 当月 1 日起；事后复盘 = 近 7 天。
    /// 补记过去的复盘时取完整的那一周 / 那个月，但不超过今天。
    static func range(period: ReviewPeriod, anchor: LocalDay, today: LocalDay = .today()) -> (first: LocalDay, last: LocalDay, label: String) {
        let first: LocalDay
        let end: LocalDay
        switch period {
        case .day:
            first = anchor; end = anchor
        case .week:
            first = anchor.mondayOfWeek; end = first.adding(days: 6)
        case .month:
            first = anchor.firstOfMonth
            end = LocalDay(year: first.month == 12 ? first.year + 1 : first.year, month: first.month == 12 ? 1 : first.month + 1, day: 1).adding(days: -1)
        case .event:
            first = anchor.adding(days: -6); end = anchor
        }
        let last = max(first, min(end, today))
        // 与回访小标题同一种写法：“10月19日–22日”“9月28日–10月4日”，不在今年的带年份
        return (first, last, ReviewThread.spanLabel(first, last, today: today))
    }

    /// 素材卡算好的回访：上次许下的下一步、参悟时的决定
    struct Recall {
        var promise: ReviewThread.Promise?
        var decision: ReviewThread.Decision?

        /// 能回访的各条（与卡上显示的次序相同）：选择的键、插进正文的那一句
        var followups: [(key: String, text: String)] {
            (promise.map { p in p.steps.map { (p.key($0), $0) } } ?? []) + (decision.map { [($0.key, $0.line)] } ?? [])
        }

        /// 点过签的几条（插进正文的那一句与签）
        func picked(_ chosen: [String: ReviewThread.Verdict]) -> [(text: String, verdict: ReviewThread.Verdict)] {
            followups.compactMap { item in chosen[item.key].map { (text: item.text, verdict: $0) } }
        }
    }

    /// 入卷前补插回访：点过签、还没进正文的几条照签接进【所得】【所失】【所悟】（插过的跳过，改过签的换掉旧行）。
    /// 回访按补记日期重新取一次（与素材卡上显示的同一篇），签对不上现在这几条的（换过周期、日期）不插
    static func withFollowups(_ raw: String, into text: String, period: ReviewPeriod, anchor: LocalDay, context: ModelContext) -> String {
        let chosen = ReviewThread.decode(raw)
        guard !chosen.isEmpty else { return text }
        let thread = Recall(promise: ReviewThread.latest(before: anchor, period: period, context: context),
                            decision: ReviewThread.decision(near: anchor, context: context))
        let picked = thread.picked(chosen)
        return picked.isEmpty ? text : ReviewThread.insert(picked, into: text)
    }

    /// 按日期取数再汇总（七日小卷存草稿也调用它，只给首末两天：周期按日期猜，见 ReviewThread.inferPeriod）
    static func lines(context: ModelContext, first: LocalDay, last: LocalDay) -> [String] {
        lines(context: context, first: first, last: last, period: ReviewThread.inferPeriod(first: first, last: last))
    }

    /// 修行录只取这段日期的，日程只取可能落在这段日期里的（ScheduleWindow），习惯照旧全部取；末尾一行本期花费（账簿读缓存）。
    /// 都不排序（日程、修行录）或按同样的键排序（习惯），取出的先后与原来整表 @Query 的相同。
    /// period 只用来定花费和“上一期”怎么比（周比上周、月比上月；没过完的比同期）
    static func lines(context: ModelContext, first: LocalDay, last: LocalDay, period: ReviewPeriod?) -> [String] {
        let from = first.key, to = last.key
        let entries = (try? context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.dateKey >= from && $0.dateKey <= to }))) ?? []
        // 习惯不重新取（重新取会让打卡关系变冷，5 年数据下每次要 1 秒多）：只取 ID 再拿已登记的对象，按 sortOrder 稳定排序；
        // 统计借修为模型已缓存的那份，模型里还没有的（刚新建）才退回 habit.stats
        let habits = context.allHabits().enumerated()
            .sorted { ($0.element.sortOrder, $0.offset) < ($1.element.sortOrder, $1.offset) }.map(\.element)
        let events = (try? context.fetch(ScheduleWindow.descriptor(from: first, to: last))) ?? []
        let model = CultivationModel.existing(for: context)
        var result = lines(entries: entries, habits: habits, events: events, first: first, last: last) { habit, today in
            model?.stats(for: habit, today: today) ?? habit.stats(today: today)
        }
        if let money = spendingLine(context: context, first: first, last: last, period: period) { result.append(money) }
        return result
    }

    /// 本期花费一行：账簿读不出来、一笔账都没有、这一期没有花费时 nil。
    /// 银行流水没导到这一期最后一天时写“不全：已知 …”（只看近一个半月还在导的账户，早已停用的旧账户不拖累）
    static func spendingLine(context: ModelContext, first: LocalDay, last: LocalDay, period: ReviewPeriod?, today: LocalDay = .today()) -> String? {
        guard let ledger = try? FinanceService.load(context), !ledger.transactions.isEmpty else { return nil }
        let through = ReviewThread.bankThrough(sources: ledger.sources, activeSince: first.adding(days: -45))
        return ReviewThread.spendingLine(rows: ledger.transactions, first: first, last: last, period: period, bankThrough: through, today: today)
    }

    static func lines(entries: [JournalEntry], habits: [Habit], events: [ScheduleEvent], first: LocalDay, last: LocalDay,
                      stats statsOf: (Habit, LocalDay) -> HabitStats = { $0.stats(today: $1) }) -> [String] {
        var lines: [String] = []
        let from = first.key, to = last.key
        let inRange = entries.filter { $0.dateKey >= from && $0.dateKey <= to }
        let byKind = Dictionary(grouping: inRange, by: \.kindValue)
        let diary = byKind[.diary] ?? [], notes = byKind[.note] ?? [], reviews = byKind[.review] ?? []

        // 落笔
        if inRange.isEmpty {
            lines.append("这段时间还没有落笔。")
        } else {
            let parts = [("日记", diary.count), ("灵感", notes.count), ("复盘", reviews.count)].filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
            let days = Set(inRange.map(\.dateKey)).count
            lines.append("落笔 \(inRange.count) 篇（\(parts.joined(separator: "、"))），共 \(days) 天动笔。")
        }

        // 心境
        let moods = inRange.compactMap(\.mood)
        if !moods.isEmpty {
            let average = Double(moods.reduce(0, +)) / Double(moods.count)
            let spread = (1...5).reversed().compactMap { value -> String? in
                let n = moods.filter { $0 == value }.count
                return n > 0 ? "\(Mood.label(value)) \(n)" : nil
            }
            lines.append("心境 \(moods.count) 次，平均「\(Mood.label(Int(average.rounded())))」：\(spread.joined(separator: "、"))。")
        }

        // 灵感
        if !notes.isEmpty {
            let titles = JournalOrder.oldestFirst(notes).prefix(5).map { "「\($0.displayTitle)」" }
            lines.append("灵感 \(notes.count) 条：\(titles.joined(separator: ""))" + (notes.count > 5 ? " 等" : "") + "。")
        }

        // 功课：期间内应打卡的习惯各完成几次、完成率
        let today = LocalDay.today()
        var habitParts: [String] = []
        for habit in habits where !habit.archived {
            let stats = statsOf(habit, today)
            // 单日复盘里的“每周 N 次”：一天的完成率没有意义（按整周折算会出现“0 次（100%）”），改为显示这一周已完成几次
            if stats.spec.frequency == .weekly && first == last {
                guard first >= stats.spec.startDay, first <= today else { continue }
                let monday = first.mondayOfWeek
                let n = LocalDay.range(monday, min(monday.adding(days: 6), today)).filter(stats.isAchieved).count
                let week = monday == today.mondayOfWeek ? "本周" : "当周"
                habitParts.append("\(habit.title) \(week) \(n)/\(max(1, stats.spec.targetPerWeek)) 次")
                continue
            }
            let done = LocalDay.range(first, last).filter(stats.isAchieved).count
            guard let rate = stats.rate(from: first, to: last) else { continue }
            habitParts.append("\(habit.title) \(done) 次（\(rate.percentText)）")
        }
        if !habitParts.isEmpty {
            lines.append("功课：" + habitParts.joined(separator: "；") + "。")
        }

        // 日程
        let items = Occurrences.list(events: events, from: first, to: last)
        if !items.isEmpty {
            var seen = Set<String>()
            let titles = items.map(\.title).filter { seen.insert($0).inserted }
            lines.append("日程 \(items.count) 项：" + titles.prefix(6).joined(separator: "、") + (titles.count > 6 ? " 等" : "") + "。")
        }
        return lines
    }

    /// 插进复盘正文的一段参考文字
    static func block(lines: [String], label: String) -> String {
        (["\(ReviewThread.materialHead)\(label)，仅供参考〕"] + lines.map { "· " + $0 }).joined(separator: "\n")
    }

    /// 插在【所悟】之前（即【所得】【所失】下方）；没有模板就接在末尾。
    static func insert(_ block: String, into text: String) -> String {
        /// 前文与素材之间空一行
        func spaced(_ head: String) -> String {
            if head.isEmpty || head.hasSuffix("\n\n") { return head }
            return head + (head.hasSuffix("\n") ? "\n" : "\n\n")
        }
        // 只认行首的【所悟】（正文里自己写的“【所悟】”字样不算）
        guard let marker = ReviewThread.markers(in: text).first(where: { $0.name == "所悟" }).map({ $0.lineStart..<$0.marker.upperBound }) else {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return block + "\n" }
            return spaced(text) + block + "\n"
        }
        return spaced(String(text[..<marker.lowerBound])) + block + "\n\n" + text[marker.lowerBound...]
    }
}
