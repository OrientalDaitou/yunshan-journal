import Foundation
import SwiftData
import Observation

/// 应用级的修为模型：侧栏境界卡、今日洞府共用同一份修为，不再各自 @Query 全表、各自全量重算。
///
/// 什么时候看一眼：数据库保存之后（监听 ModelContext.didSave；同一轮里的几次保存合并，主线程下一轮再看），
/// 跨午夜（侧栏收到新的 dayKey）、侧栏与今日洞府出现时。看的时候先比一枚便宜的指纹：修行录、打卡各自的
/// 条数与最新修改时间，习惯的条数与各项设置，加上修为设置、今天、时区（约 1–2 毫秒）。指纹没变、保存里也没有
/// 修行录与打卡，就什么都不算——名帖打字、记账、改日程这类与修为无关的保存，不会再触发全量计算。
///
/// 变了也只重算变了的那部分：保存通知里列着这次增删改了哪几篇落笔、哪几条打卡，只按 ID 把这几条取回来更新；
/// 条数对不上、或指纹变了却说不清是哪几条时，才整表重建。只改了标题、正文、珍藏的，修为不重算；
/// 打一次卡只更新那一条打卡、只重算那一个习惯的统计。
///
/// 为什么打卡不从 `habit.logs` 读：SwiftData 里任何一次重新取习惯（界面上 @Query 习惯的页面每次保存都会重取）
/// 都会让这些习惯的打卡关系变“冷”，之后再读 `habit.logValues` 要把两万条打卡逐条从库里补回来（5 年数据约 2.6 秒）。
/// 所以这里不重新取习惯（只在新增习惯时按 ID 取新的那几个），打卡一律按 ID 或整表直接取。
///
/// 算法与全量计算 `CultivationService.fullState(context:)` 完全相同，只是不重复取数（自检里随机增删改后逐次对照）。
/// 同一习惯同一天只会有一条打卡（打卡、传书、旧版导入都先看当天有没有），所以打卡的先后次序一般不影响结果；
/// 旧数据里真有同一天两条的习惯，统计“以最后一条为准”，先后要与原来一样取自 `habit.logValues`，这样的习惯单独从关系里读。
///
/// 各习惯的统计（含已归档的）也给每日功课页用（`stats(for:today:)`）；改习惯设置前的修为预估借 `totals(replacing:…)`。
/// 打卡（HabitActions）保存后会当场让模型看一眼，不等下一轮。
/// 界面里用 `CultivationModel.shared(for:)`，传数据库的主 context：每个数据库一份，主窗口关了再开还是同一份。
@MainActor
@Observable
final class CultivationModel {
    /// 今日洞府功课卡的一行：未归档的习惯及其统计
    struct HabitRow: Identifiable {
        var habit: Habit
        var stats: HabitStats
        var id: PersistentIdentifier { habit.persistentModelID }
    }

    /// 修为与境界（侧栏境界卡、近 14 日图）
    private(set) var state = CultivationState.empty
    /// 算这份修为用的设置（开关、境界与门槛、每日上限）
    private(set) var config = CultivationConfig()
    /// 今天是否“功课圆满”：与修为引擎同一个判定，提示与实际加的修为一致
    private(set) var perfectToday = false
    /// 全部习惯（含已归档的），按 sortOrder：打卡时交给 HabitActions 算当天的修为差
    private(set) var habits: [Habit] = []
    /// 未归档的习惯及其统计，按 sortOrder（今日洞府的功课卡、AI 摘要的习惯一节）
    private(set) var rows: [HabitRow] = []
    /// 全部习惯（含已归档的）的统计，按习惯 ID：每日功课页读它（见 stats(for:today:)）
    private(set) var habitStats: [PersistentIdentifier: HabitStats] = [:]
    /// 这份结果是按哪一天算的
    private(set) var today = LocalDay.today()

    /// 某个习惯的统计（含已归档的），与 `habit.stats(today:)` 相同，但不读 habit.logs（功课页每次保存都会重取习惯，
    /// 打卡关系随之变冷，13 个习惯各读一遍要 1 秒多）。
    /// 模型还没看到这次保存时（保存通知的下一轮才看；打卡会当场看），习惯的设置若已经改了（频率、开始日期、归档……），
    /// 就用新设置和缓存的打卡现算；today 与模型那天不同（刚过午夜）时同样现算。
    /// 模型里还没有这个习惯（刚新建、还没看到）时返回 nil，由调用方退回 habit.stats(today:)。
    func stats(for habit: Habit, today: LocalDay) -> HabitStats? {
        guard let stats = habitStats[habit.persistentModelID] else { return nil }
        let spec = habit.spec
        if stats.spec == spec && stats.today == today { return stats }
        // stats.logs 是按天去重后的打卡（同一天已按原来的规则取了最后一条），用它重建与用原始打卡重建相同
        return HabitStats(spec: spec, logs: Array(stats.logs.values), today: today)
    }

    // MARK: 共享

    /// 每个数据库（ModelContainer）一份：正式应用只有一份；离屏截图、自检各用各的内存库。
    /// 钥匙是 StoreIdentity 编的号（一库一把、不会因内存地址被新库复用而认错，见 StoreIdentity）
    private static var registry: [StoreIdentity.Key: CultivationModel] = [:]

    /// 这个数据库的那一份（没有就用这个 context 建一份，建的时候完整算一次）。界面里传的是主 context，
    /// 与界面上 @Query、打卡、落笔用的是同一批对象。
    static func shared(for context: ModelContext) -> CultivationModel {
        let key = StoreIdentity.key(for: context)
        // 再核对一次：登记着的模型确实属于这个数据库，才交出去
        if let model = registry[key], model.container === context.container { return model }
        let model = CultivationModel(context: context)
        registry[key] = model
        return model
    }

    /// 已经为这个 context 建好的那一份（没有就是 nil，不新建）：落笔算当天修为差、AI 摘要借它的习惯与统计，
    /// 不必再把习惯整个重新取一遍（重新取会让打卡关系变冷，见上）。只查不领钥匙：没登记过的库一定没有模型
    static func existing(for context: ModelContext) -> CultivationModel? {
        guard let key = StoreIdentity.existingKey(for: context.container), let model = registry[key],
              model.context === context, model.container === context.container else { return nil }
        return model
    }

    // MARK: 内部状态（不参与界面刷新）

    /// 一张表的指纹：条数 + 最新修改时间
    private struct TableMark: Equatable {
        var count: Int
        var latest: Date?

        init<T: PersistentModel>(_ type: T.Type, _ key: KeyPath<T, Date>, in context: ModelContext) {
            var newest = FetchDescriptor<T>(sortBy: [SortDescriptor(key, order: .reverse)])
            newest.fetchLimit = 1
            count = (try? context.fetchCount(FetchDescriptor<T>())) ?? -1
            latest = (try? context.fetch(newest))?.first?[keyPath: key]
        }
    }

    private struct Fingerprint: Equatable {
        var today: LocalDay
        /// 习惯的创建日、落笔日期写坏时的回退日期都按当前时区换算：换了时区就全部重建
        var zone: String
        var config: CultivationConfig
        var journal: TableMark
        var logs: TableMark
        /// 习惯只数条数（取最新修改时间要取习惯对象，会让打卡关系变冷）；设置的变化逐个比 HabitKey
        var habitCount: Int
        var habitKeys: [HabitKey]
    }

    /// 一篇落笔对修为有用的只有这两样
    private struct JournalItem: Equatable {
        var day: LocalDay
        var kind: JournalKind
        init(_ entry: JournalEntry) {
            day = entry.day
            kind = entry.kindValue
        }
    }

    /// 一条打卡：属于哪个习惯，换算成的值（日期写坏的记 nil，与 Habit.logValues 一样不计）
    private struct LogItem {
        var habit: PersistentIdentifier?
        var value: HabitLogValue?

        init(_ log: HabitLog) {
            habit = log.habit?.persistentModelID
            value = LocalDay(key: log.dateKey).map {
                HabitLogValue(day: $0, completed: log.completed, quantity: log.quantity, target: log.targetAtLog)
            }
        }

        func same(as other: LogItem) -> Bool {
            guard habit == other.habit else { return false }
            switch (value, other.value) {
            case (nil, nil): return true
            case let (a?, b?): return a.day == b.day && a.completed == b.completed && a.quantity == b.quantity && a.target == b.target
            default: return false
            }
        }
    }

    /// 习惯的设置（决定 HabitSpec 与是否归档）：这些都没变，统计就可以沿用
    private struct HabitKey: Equatable {
        var id: PersistentIdentifier
        var frequency: String
        var targetPerWeek: Int
        var weekdays: [Int]
        var targetValue: Double?
        var startDate: String
        var createdAt: Date
        var archived: Bool
        var archivedAt: String?

        init(_ habit: Habit) {
            id = habit.persistentModelID
            frequency = habit.frequency
            targetPerWeek = habit.targetPerWeek
            weekdays = habit.weekdays
            targetValue = habit.targetValue
            startDate = habit.startDate
            createdAt = habit.createdAt
            archived = habit.archived
            archivedAt = habit.archivedAt
        }
    }

    private struct HabitEntry {
        var key: HabitKey
        var spec: HabitSpec
        var logs: [HabitLogValue]
        var stats: HabitStats
    }

    /// 两次检查之间攒下的保存通知：增删改了哪些落笔、打卡，增删了哪些习惯
    private struct Pending {
        var journalUpserts = Set<PersistentIdentifier>()
        var journalDeletes = Set<PersistentIdentifier>()
        var logUpserts = Set<PersistentIdentifier>()
        var logDeletes = Set<PersistentIdentifier>()
        var habitInserts = Set<PersistentIdentifier>()
        var habitDeletes = Set<PersistentIdentifier>()
        /// 某次保存通知里没有增删改清单（正常不会发生）：只能按指纹判断，变了就整块重建
        var unknown = false

        var touchesJournal: Bool { !journalUpserts.isEmpty || !journalDeletes.isEmpty }
        var touchesLogs: Bool { !logUpserts.isEmpty || !logDeletes.isEmpty }
        var touchesHabits: Bool { !habitInserts.isEmpty || !habitDeletes.isEmpty }
    }

    /// 保存通知里与修为有关的内容（在发通知的线程上取出来，只带可跨线程的 ID）
    private struct SavedChanges: Sendable {
        var journalUpserts: [PersistentIdentifier] = []
        var journalDeletes: [PersistentIdentifier] = []
        var logUpserts: [PersistentIdentifier] = []
        var logDeletes: [PersistentIdentifier] = []
        var habitInserts: [PersistentIdentifier] = []
        var habitDeletes: [PersistentIdentifier] = []
        var unknown = false

        static let journalEntity = String(describing: JournalEntry.self)
        static let logEntity = String(describing: HabitLog.self)
        static let habitEntity = String(describing: Habit.self)

        init(_ info: [AnyHashable: Any]?) {
            guard let inserted = info?[ModelContext.NotificationKey.insertedIdentifiers.rawValue] as? [PersistentIdentifier],
                  let updated = info?[ModelContext.NotificationKey.updatedIdentifiers.rawValue] as? [PersistentIdentifier],
                  let deleted = info?[ModelContext.NotificationKey.deletedIdentifiers.rawValue] as? [PersistentIdentifier] else {
                unknown = true
                return
            }
            for id in inserted + updated {
                switch id.entityName {
                case Self.journalEntity: journalUpserts.append(id)
                case Self.logEntity: logUpserts.append(id)
                default: break
                }
            }
            habitInserts = inserted.filter { $0.entityName == Self.habitEntity }
            for id in deleted {
                switch id.entityName {
                case Self.journalEntity: journalDeletes.append(id)
                case Self.logEntity: logDeletes.append(id)
                case Self.habitEntity: habitDeletes.append(id)
                default: break
                }
            }
        }
    }

    /// 不随模型释放而残留的通知监听（模型释放时一并移除）
    private final class SaveObserver {
        let token: NSObjectProtocol
        init(_ token: NSObjectProtocol) { self.token = token }
        deinit { NotificationCenter.default.removeObserver(token) }
    }

    private let context: ModelContext
    /// 这份模型属于哪个数据库。留住它：主 context（container.mainContext）并不持有容器，
    /// 只留着 context 的话，数据库一释放，这个 context 就读不得了
    private let container: ModelContainer
    /// 同一个数据库的钥匙（保存通知按它认库，见 StoreIdentity）
    private let store: StoreIdentity.Key
    @ObservationIgnored private var saveObserver: SaveObserver?
    @ObservationIgnored private var fingerprint: Fingerprint?
    @ObservationIgnored private var pending = Pending()
    @ObservationIgnored private var scheduled = false
    /// 每篇落笔（按 ID）的日期与类型；nil 表示还没建
    @ObservationIgnored private var journal: [PersistentIdentifier: JournalItem]?
    @ObservationIgnored private var journalSources: [XPSource] = []
    /// 每条打卡（按 ID）；nil 表示还没建
    @ObservationIgnored private var logItems: [PersistentIdentifier: LogItem]?
    /// 每个习惯的打卡（习惯 ID → 打卡 ID → 值）
    @ObservationIgnored private var logsByHabit: [PersistentIdentifier: [PersistentIdentifier: HabitLogValue]] = [:]
    @ObservationIgnored private var habitEntries: [PersistentIdentifier: HabitEntry] = [:]
    /// 与 habits 一一对应（含已归档的）。长期摘要（AIDigest）借它的打卡，不必再把全部打卡从库里读一遍
    @ObservationIgnored private(set) var habitInputs: [(spec: HabitSpec, logs: [HabitLogValue], archived: Bool)] = []
    @ObservationIgnored private var habitSources: [XPSource] = []

    /// 做过的活（自检用来确认与修为无关的保存真的没有重算、打一次卡只重算一个习惯）
    struct Work: Equatable {
        /// 整表重建修行录的次数
        var journalRebuilds = 0
        /// 整表重建打卡的次数
        var logRebuilds = 0
        /// 重新取习惯列表的次数（不含按 ID 取新增的）
        var habitFetches = 0
        /// 重算统计的习惯个数
        var habitRereads = 0
        /// 从打卡关系里读的次数（只有同一天不止一条打卡的习惯才这样读，见 updateHabits）
        var relationshipReads = 0
        /// 算修为的次数
        var computes = 0
    }
    @ObservationIgnored private(set) var work = Work()

    /// 界面里请用 `shared(for:)`；自检可以直接给一个 context。建的时候就完整算一次，第一次显示就是准确的修为。
    init(context: ModelContext) {
        self.context = context
        container = context.container
        store = StoreIdentity.key(for: context)
        let token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] note in
            // 只认同一个数据库的保存（没领过钥匙的库一定不是这个）；这个应用只在主线程上保存，万一来自别的线程，就把取出的钥匙交给主线程处理
            let saver = (note.object as? ModelContext).flatMap { StoreIdentity.existingKey(for: $0.container) }
            let changes = SavedChanges(note.userInfo)
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.noteSaved(by: saver, changes) }
            } else {
                Task { @MainActor in self?.noteSaved(by: saver, changes) }
            }
        }
        saveObserver = SaveObserver(token)
        refresh()
    }

    private func noteSaved(by saver: StoreIdentity.Key?, _ changes: SavedChanges) {
        guard saver == store else { return }
        pending.unknown = pending.unknown || changes.unknown
        // 后来删掉的，不再按“增改”去取
        for id in changes.journalDeletes {
            pending.journalUpserts.remove(id)
            pending.journalDeletes.insert(id)
        }
        for id in changes.journalUpserts where !pending.journalDeletes.contains(id) { pending.journalUpserts.insert(id) }
        for id in changes.logDeletes {
            pending.logUpserts.remove(id)
            pending.logDeletes.insert(id)
        }
        for id in changes.logUpserts where !pending.logDeletes.contains(id) { pending.logUpserts.insert(id) }
        for id in changes.habitDeletes {
            pending.habitInserts.remove(id)
            pending.habitDeletes.insert(id)
        }
        pending.habitInserts.formUnion(changes.habitInserts)
        // 同一轮里的几次保存（例如启动时连着存设置、名帖）合并成一次检查
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.refresh()
        }
    }

    // MARK: 检查与重算

    /// 比一下指纹，变了才重算（没变时约 1–2 毫秒）。保存之后会自动调用；跨午夜、页面出现时也可以直接调。
    func refresh() {
        let today = LocalDay.today()
        let zone = TimeZone.current.identifier
        let config = context.all(AppSettings.self).first?.cultivation ?? CultivationConfig()
        let changes = pending
        pending = Pending()
        let old = fingerprint
        let zoneChanged = old?.zone != zone
        let dayChanged = old?.today != today
        let journalMark = TableMark(JournalEntry.self, \.updatedAt, in: context)
        let logMark = TableMark(HabitLog.self, \.updatedAt, in: context)
        let habitCount = (try? context.fetchCount(FetchDescriptor<Habit>())) ?? -1

        // 习惯列表：只在增删习惯时变；新增的按 ID 取，条数对不上才整个重新取
        let listChanged = updateHabitList(changes, expected: habitCount)
        let keys = habits.map(HabitKey.init)
        let mark = Fingerprint(today: today, zone: zone, config: config, journal: journalMark, logs: logMark,
                               habitCount: habitCount, habitKeys: keys)
        guard mark != old || changes.touchesJournal || changes.touchesLogs || listChanged else { return }
        fingerprint = mark

        let journalChanged = updateJournal(changes, markChanged: old?.journal != journalMark, rebuild: zoneChanged, expected: journalMark.count)
        if journalChanged || dayChanged {
            journalSources = CultivationEngine.journalSources((journal ?? [:]).values.map { ($0.day, $0.kind) }, today: today)
        }
        let dirty = updateLogs(changes, markChanged: old?.logs != logMark, expected: logMark.count)
        let habitsChanged = updateHabits(today: today, dirty: dirty, rebuild: zoneChanged, listChanged: listChanged || dayChanged)

        guard old == nil || journalChanged || habitsChanged || dayChanged || old?.config != config else { return }
        let newState = CultivationEngine.compute(sources: habitSources + journalSources, config: config, today: today)
        work.computes += 1
        // 传全部习惯（含已归档的，由引擎按归档日过滤）；每周 N 次的习惯不影响圆满
        let perfect = config.enabled && CultivationEngine.isPerfectDay(today, habits: habitInputs)
        // 值没变就不写：写一次就会让读它的视图刷新
        if self.today != today { self.today = today }
        if self.config != config { self.config = config }
        if state != newState { state = newState }
        if perfectToday != perfect { perfectToday = perfect }
    }

    /// 维护习惯对象列表（不重新取已有的习惯）。返回列表（成员）是否变了。
    private func updateHabitList(_ changes: Pending, expected: Int) -> Bool {
        var list = habits
        let before = list.map(\.persistentModelID)
        if fingerprint != nil, changes.touchesHabits {
            list.removeAll { changes.habitDeletes.contains($0.persistentModelID) }
            let known = Set(list.map(\.persistentModelID))
            let ids = Array(changes.habitInserts.subtracting(known))
            if !ids.isEmpty {
                list += (try? context.fetch(FetchDescriptor<Habit>(predicate: #Predicate { ids.contains($0.persistentModelID) }))) ?? []
            }
        }
        // 已删掉的（保存后不再属于任何 context）不留
        list.removeAll { $0.modelContext == nil || $0.isDeleted }
        if fingerprint == nil || list.count != expected {
            work.habitFetches += 1
            list = (try? context.fetch(FetchDescriptor<Habit>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? context.all(Habit.self)
        }
        // 与 @Query(sort: \Habit.sortOrder) 相同的次序（同序号的保持原来的先后）
        list = list.enumerated().sorted { ($0.element.sortOrder, $0.offset) < ($1.element.sortOrder, $1.offset) }.map(\.element)
        let changed = list.map(\.persistentModelID) != before
        if changed || fingerprint == nil { habits = list }
        return changed
    }

    /// 更新每篇落笔的日期与类型；返回修为是否可能变了（只改了标题、正文、珍藏的不算）。
    private func updateJournal(_ changes: Pending, markChanged: Bool, rebuild force: Bool, expected: Int) -> Bool {
        var rebuild = force || journal == nil
        // 指纹变了却没有对应的保存通知（例如还没保存的改动），或通知里没有清单：说不清是哪几篇，整表重建
        if markChanged && (changes.unknown || !changes.touchesJournal) { rebuild = true }
        var changed = false
        if !rebuild, var items = journal, markChanged || changes.touchesJournal {
            for id in changes.journalDeletes where items.removeValue(forKey: id) != nil { changed = true }
            if !changes.journalUpserts.isEmpty {
                // 按 ID 把这几篇取回来（保存后没人引用的对象会从 context 里放掉，不能只在已登记的对象里找）；
                // 取不回来的就是后来删掉了
                let ids = Array(changes.journalUpserts)
                if let found = try? context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { ids.contains($0.persistentModelID) })) {
                    var present = Set<PersistentIdentifier>()
                    for entry in found where !entry.isDeleted {
                        let id = entry.persistentModelID
                        present.insert(id)
                        let item = JournalItem(entry)
                        if items[id] != item {
                            items[id] = item
                            changed = true
                        }
                    }
                    for id in ids where !present.contains(id) && items.removeValue(forKey: id) != nil { changed = true }
                } else {
                    rebuild = true
                }
            }
            // 篇数对不上（漏了哪次增删）：整表重建
            if items.count != expected { rebuild = true }
            if !rebuild { journal = items }
        }
        if rebuild {
            work.journalRebuilds += 1
            let entries = context.all(JournalEntry.self)
            journal = Dictionary(entries.map { ($0.persistentModelID, JournalItem($0)) }, uniquingKeysWith: { _, new in new })
            return true
        }
        return changed
    }

    /// 更新打卡；返回打卡变了的习惯（整表重建时返回 nil，表示全部习惯都要重算）。
    private func updateLogs(_ changes: Pending, markChanged: Bool, expected: Int) -> Set<PersistentIdentifier>? {
        var rebuild = logItems == nil
        // 删习惯时连带删掉（级联删除）的打卡不一定列在保存通知里：习惯删掉了，它的打卡也就都没了，按习惯一并去掉，
        // 不必为此把全部打卡整表重取一遍
        let explained = changes.touchesLogs || !changes.habitDeletes.isEmpty
        if markChanged && (changes.unknown || !explained) { rebuild = true }
        var dirty = Set<PersistentIdentifier>()
        if !rebuild, var items = logItems, markChanged || explained {
            func remove(_ id: PersistentIdentifier) {
                guard let old = items.removeValue(forKey: id) else { return }
                if let habit = old.habit {
                    logsByHabit[habit]?.removeValue(forKey: id)
                    dirty.insert(habit)
                }
            }
            for id in changes.logDeletes { remove(id) }
            if !changes.habitDeletes.isEmpty {
                let orphaned = items.filter { $0.value.habit.map(changes.habitDeletes.contains) == true }.map(\.key)
                for id in orphaned { remove(id) }
                for habit in changes.habitDeletes { logsByHabit.removeValue(forKey: habit) }
            }
            if !changes.logUpserts.isEmpty {
                let ids = Array(changes.logUpserts)
                if let found = try? context.fetch(FetchDescriptor<HabitLog>(predicate: #Predicate { ids.contains($0.persistentModelID) })) {
                    var present = Set<PersistentIdentifier>()
                    for log in found where !log.isDeleted {
                        let id = log.persistentModelID
                        present.insert(id)
                        let item = LogItem(log)
                        if let old = items[id], old.same(as: item) { continue }
                        remove(id)
                        items[id] = item
                        if let habit = item.habit {
                            if let value = item.value { logsByHabit[habit, default: [:]][id] = value }
                            dirty.insert(habit)
                        }
                    }
                    for id in ids where !present.contains(id) { remove(id) }
                } else {
                    rebuild = true
                }
            }
            // 条数对不上（例如删习惯时连带删掉的打卡没在通知里）：整表重建
            if items.count != expected { rebuild = true }
            if !rebuild { logItems = items }
        }
        guard rebuild else { return dirty }
        work.logRebuilds += 1
        // 一次把全部打卡取出来（比逐个习惯读 habit.logs 快，也不受打卡关系冷热影响）
        let logs = context.all(HabitLog.self)
        var items: [PersistentIdentifier: LogItem] = [:]
        var byHabit: [PersistentIdentifier: [PersistentIdentifier: HabitLogValue]] = [:]
        for log in logs {
            let id = log.persistentModelID
            let item = LogItem(log)
            items[id] = item
            if let habit = item.habit, let value = item.value { byHabit[habit, default: [:]][id] = value }
        }
        logItems = items
        logsByHabit = byHabit
        return nil
    }

    /// 重算设置或打卡变了的习惯的统计，其余沿用。返回修为是否可能变了。
    private func updateHabits(today: LocalDay, dirty: Set<PersistentIdentifier>?, rebuild: Bool, listChanged: Bool) -> Bool {
        var changed = listChanged || rebuild || dirty == nil
        var entries: [HabitEntry] = []
        for habit in habits {
            let id = habit.persistentModelID
            let key = HabitKey(habit)
            if !rebuild, dirty?.contains(id) == false, var entry = habitEntries[id], entry.key == key {
                if entry.stats.today != today { entry.stats = HabitStats(spec: entry.spec, logs: entry.logs, today: today) }
                entries.append(entry)
            } else {
                let spec = habit.spec
                var logs = Array((logsByHabit[id] ?? [:]).values)
                // 同一天有不止一条打卡（旧数据才可能出现）：统计以“最后一条”为准，先后要与原来一样取自 habit.logValues，
                // 这里按 ID 存的打卡没有那个先后，所以这样的习惯照原来的写法从关系里读（只有这样的习惯才多花这一下）。
                // 刚保存完时关系里的先后是临时的，重新取一次习惯之后才稳定下来（之后怎么重取都不变）；原来的功课页、侧栏
                // 都是 @Query 重取习惯之后才读，所以这里也先按 ID 把这个习惯重新取一次再读，先后与它们读到的相同
                if Set(logs.map(\.day)).count != logs.count {
                    _ = try? context.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.persistentModelID == id }))
                    logs = habit.logValues
                    work.relationshipReads += 1
                }
                entries.append(HabitEntry(key: key, spec: spec, logs: logs, stats: HabitStats(spec: spec, logs: logs, today: today)))
                work.habitRereads += 1
                changed = true
            }
        }
        guard changed else { return false }
        habitEntries = Dictionary(zip(habits.map(\.persistentModelID), entries), uniquingKeysWith: { _, new in new })
        habitInputs = zip(habits, entries).map { (spec: $1.spec, logs: $1.logs, archived: $0.archived) }
        habitSources = CultivationEngine.sources(habits: habitInputs, stats: entries.map(\.stats), today: today)
        rows = zip(habits, entries).filter { !$0.0.archived }.map { HabitRow(habit: $0, stats: $1.stats) }
        habitStats = habitEntries.mapValues(\.stats)
        return true
    }

    /// 把 habit 的设定换成 spec / archived 前后的总修为（改习惯设置前预估用，见 HabitXPChange.preview）：
    /// 只按新设定重算这一个习惯的统计，其余习惯与落笔沿用模型里的。结果与全部取出来、换设定前后各全量算一次相同（自检里对照）。
    /// 先看一眼最新的数据；结果不是今天的、或模型里没有这个习惯时返回 nil，由调用方全量算。
    func totals(replacing habit: Habit, spec: HabitSpec, archived: Bool) -> (before: Int, after: Int)? {
        refresh()
        let id = habit.persistentModelID
        guard today == LocalDay.today(), let index = habits.firstIndex(where: { $0.persistentModelID == id }),
              habitInputs.count == habits.count else { return nil }
        let allStats = habits.compactMap { habitEntries[$0.persistentModelID]?.stats }
        guard allStats.count == habits.count else { return nil }
        var inputs = habitInputs
        var stats = allStats
        inputs[index] = (spec: spec, logs: inputs[index].logs, archived: archived)
        stats[index] = HabitStats(spec: spec, logs: inputs[index].logs, today: today)
        let after = CultivationEngine.compute(sources: CultivationEngine.sources(habits: inputs, stats: stats, today: today) + journalSources,
                                              config: config, today: today).totalXP
        return (state.totalXP, after)
    }
}
