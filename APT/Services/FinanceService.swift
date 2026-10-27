import Foundation
import SwiftData

@MainActor
enum FinanceService {
    /// 当前账本的存储对象。抓取失败时抛错——不能当成“还没有账本”，否则会另插一个新账本把原账本遮蔽掉。
    static func fetchStore(_ context: ModelContext) throws -> FinanceStore? {
        try context.fetch(FetchDescriptor<FinanceStore>()).sorted { $0.updatedAt > $1.updatedAt }.first
    }

    /// 不关心失败原因的只读场合（例如备份导出）用：抓取失败时返回 nil。写入路径一律走 fetchStore。
    static func store(_ context: ModelContext) -> FinanceStore? {
        try? fetchStore(context)
    }

    /// 缓存里的账本是哪一本的哪一版：哪个数据库（StoreIdentity 的钥匙）、哪一条存储记录、它的更新时间
    /// （所有写入都经 save 同时更新 data 与 updatedAt，所以同一条记录、同一个更新时间就是同一份数据）。
    /// 以前认的是存储对象的内存地址：对象释放后地址会被新对象（甚至别的数据库里的账本）复用，更新时间再恰好相同就会拿错账本
    private struct Version: Equatable {
        var store: StoreIdentity.Key
        var row: PersistentIdentifier
        var stamp: Date

        init(_ object: FinanceStore, in context: ModelContext, stamp: Date? = nil) {
            store = StoreIdentity.key(for: context)
            row = object.persistentModelID
            self.stamp = stamp ?? object.updatedAt
        }
    }

    /// 最近一次解码的账本（按版本判断是否过期，见 Version）
    private static var cached: (version: Version, ledger: FinanceLedger)?

    /// 读取账本。读不出来（抓取失败、数据缺失、解码失败）时抛错，调用方不得用空账本覆盖。
    /// 只有确实还没有账本时才返回空账本。同一版本只解码一次（约 240 KB JSON）。
    static func load(_ context: ModelContext) throws -> FinanceLedger {
        guard let store = try fetchStore(context) else { return FinanceLedger() }
        return try ledger(of: store, in: context)
    }

    private static func ledger(of store: FinanceStore, in context: ModelContext) throws -> FinanceLedger {
        guard !store.data.isEmpty else {
            throw FinanceError.invalid("账本数据缺失（恢复或复制数据时可能漏了隐藏的 .APT_SUPPORT 文件夹），为避免覆盖已停止读写")
        }
        let version = Version(store, in: context)
        if let c = cached, c.version == version { return c.ledger }
        let ledger = try FinanceLedger.decode(store.data)
        cached = (version, ledger)
        return ledger
    }

    /// 最近一次的账本派生数据（与上面的账本同一个版本）
    private static var cachedIndex: (version: Version, index: FinanceLedgerIndex)?
    private static let emptyIndex = FinanceLedgerIndex(FinanceLedger())

    /// 读取账本并给出它的派生数据（各月账目、月卷草稿、交易明细的排序与搜索文字……）。账本没变时一直是同一个对象，
    /// 里面算过的都记着：账簿页切月份、开关弹窗、拖窗口改宽度都只是查表。读不出来时与 load 一样抛错。
    static func loadIndex(_ context: ModelContext) throws -> FinanceLedgerIndex {
        guard let store = try fetchStore(context) else { return emptyIndex }
        let ledger = try ledger(of: store, in: context)
        let version = Version(store, in: context)
        if let c = cachedIndex, c.version == version { return c.index }
        // 换了新版账本：只取决于银行描述的结果（账单分组、商户名）沿用上一版的
        let index = FinanceLedgerIndex(ledger, reusing: cachedIndex?.index)
        cachedIndex = (version, index)
        return index
    }

    /// 整本写回。保存失败时把存储对象恢复成原样再抛错，内存里不会留下“看似已保存”的账本；
    /// 成功后直接把刚编码的账本放进缓存，下一次读取不必再整本解码。
    static func save(_ ledger: FinanceLedger, context: ModelContext) throws {
        let data = try ledger.encoded()
        let stamp = Date()
        if let store = try fetchStore(context) {
            let (oldData, oldStamp) = (store.data, store.updatedAt)
            store.data = data
            store.updatedAt = stamp
            do {
                try context.save()
            } catch {
                store.data = oldData
                store.updatedAt = oldStamp
                throw error
            }
            cached = (Version(store, in: context, stamp: stamp), ledger)
        } else {
            // 只有“抓取成功且确实一条都没有”才新建
            let created = FinanceStore(data: data)
            created.updatedAt = stamp
            context.insert(created)
            do {
                try context.save()
            } catch {
                context.delete(created)
                throw error
            }
            // 保存之后才取记录 ID（插入时的临时 ID 保存后会换成正式的）
            cached = (Version(created, in: context, stamp: stamp), ledger)
        }
    }

    /// 修改账本：读取 → 修改 → 保存，出错时不写入。
    static func mutate(_ context: ModelContext, _ body: (inout FinanceLedger) throws -> Void) throws -> FinanceLedger {
        var ledger = try load(context)
        try body(&ledger)
        try save(ledger, context: context)
        return ledger
    }

    /// 把旧版账本（JSON 文本）并入新版。dryRun 时只计算会新增多少。
    static func mergeLegacy(json: String, context: ModelContext, dryRun: Bool) throws -> FinanceEngine.MergeResult {
        let legacy = try FinanceLedger.decode(Data(json.utf8))
        var ledger = try load(context)
        let result = FinanceEngine.merge(legacy, into: &ledger)
        if !dryRun, result.transactions + result.sources + result.reports + result.rules > 0 {
            try save(ledger, context: context)
        }
        return result
    }

    /// 已经导入过旧版、但当时还没有账簿功能：从旧版存档里取出账本并入（只在新版还没有账本时执行一次）。
    /// 抓取账本失败时什么都不做——否则会用旧版存档新建一本更“新”的账，把现有账本遮蔽掉。
    @discardableResult
    static func migrateArchivedLedgerIfNeeded(_ context: ModelContext) -> FinanceEngine.MergeResult? {
        let existing: FinanceStore?
        do { existing = try fetchStore(context) } catch { return nil }
        guard existing == nil else { return nil }
        let records = context.all(LegacyRecord.self).filter { $0.kind == "settings" && $0.legacyID == "finance_ledger_v1" }
        guard let latest = records.sorted(by: { $0.importedAt > $1.importedAt }).first else { return nil }
        return try? mergeLegacy(json: latest.json, context: context, dryRun: false)
    }
}
