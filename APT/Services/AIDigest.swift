import Foundation
import SwiftData

/// “长期摘要”（近 12 个月逐月趋势 + 近 90 天洞见，见 Core/LongTermDigest）的取数与缓存。
/// 修行录「卷中洞见」卡、问道灵枢“长期趋势与洞察”、snapshot.md 三处共用同一份静态缓存，键 = 数据戳 + 今天：
/// 问道灵枢里打字、切问法、改回看天数，快照每次数据变化后的重建，每次切到修行录，都只是查表（数据戳约几毫秒）。
/// 只取元数据（RecordCollector.input 的 text: false：日期、类型、心境、全部打卡与账簿），不取修行录正文。
@MainActor
enum AIDigest {
    typealias Digest = LongTermDigest

    private struct Entry {
        /// 哪个数据库（StoreIdentity 的钥匙：一库一把，内存地址被新库复用也不会认错）
        var store: StoreIdentity.Key
        var day: String
        var stamp: String
        var digest: LongTermDigest
    }

    /// 最近算过的几份（新的在前）：同一个库通常只有一份；快照按应用时区取“今天”，与界面不同时也各有一份
    private static var cache: [Entry] = []
    private static let cacheLimit = 4
    /// 真正重算过几次（自检据此确认数据没变时只是查表）
    private(set) static var computeCount = 0

    /// 近 12 个月逐月趋势 + 近 90 天洞见。数据戳与今天都没变时直接返回上次的结果
    static func digest(context: ModelContext, today: LocalDay = .today()) -> LongTermDigest {
        let store = StoreIdentity.key(for: context)
        let stamp = RecordCollector.stamp(context: context)
        if let hit = cache.first(where: { $0.store == store && $0.day == today.key && $0.stamp == stamp }) { return hit.digest }
        computeCount += 1
        let digest = LongTermDigest.make(input(context: context, today: today, habits: borrowedHabits(context)), today: today)
        cache.removeAll { $0.store == store && $0.day == today.key }
        cache.insert(Entry(store: store, day: today.key, stamp: stamp, digest: digest), at: 0)
        if cache.count > cacheLimit { cache.removeLast(cache.count - cacheLimit) }
        return digest
    }

    /// 长期摘要的取数：近 12 个月（本月往前 11 个月的 1 日起）的元数据 + 全部落笔、习惯与打卡、账簿。
    /// habits 传修为模型手上现成的（见 borrowedHabits），nil 时由 RecordCollector 的镜像去读
    static func input(context: ModelContext, today: LocalDay, habits: [RecordHabit]?) -> RecordInput {
        RecordCollector.input(context: context, from: LongTermDigest.fetchStart(today: today), to: today, today: today, text: false, habits: habits)
    }

    /// 借修为模型（侧栏境界卡与今日洞府共用的那一份）读好的全部习惯与打卡：第一次读全部打卡在 5 年数据上要一秒多，
    /// 模型已经读过一遍，不必再读第二遍。主窗口的 context（数据库的 mainContext，传书巡查用的也是它）还没有模型时
    /// 就先建好——侧栏随后用的正是这一份（应用启动时快照可能比侧栏先算）。先 refresh 跟上刚保存的改动（没变时约 1–2 毫秒）。
    /// 别的 context（自检的临时库、命令行）不建模型，返回 nil，照常由 RecordCollector 的镜像读
    static func borrowedHabits(_ context: ModelContext) -> [RecordHabit]? {
        if CultivationModel.existing(for: context) == nil, context === context.container.mainContext {
            _ = CultivationModel.shared(for: context)
        }
        // shared 按数据库登记：登记的若是同库的另一个 context，existing 仍为 nil，不借
        guard let model = CultivationModel.existing(for: context) else { return nil }
        model.refresh()
        return model.recordHabits
    }

    /// 只查表、不碰数据库：今天最近算过的一份（可能比数据稍旧，随后再用 digest 核对数据戳）。
    /// 修行录卡片建出来的第一帧用它，切回修行录时直接显示结果，不必先空一下
    static func latest(today: LocalDay = .today()) -> LongTermDigest? {
        cache.first { $0.day == today.key }?.digest
    }

    /// 把长期摘要填进 trends / trendsManualOnly / insights（“正文（依据）”）/ insightWindowDays = 90；
    /// 一条记录都没有（两段都空）时不动摘要
    static func attach(_ summary: inout PlannerSummary, context: ModelContext, today: LocalDay = .today()) {
        digest(context: context, today: today).attach(to: &summary)
    }

    /// 档案里的称呼：姓名、昵称、希望的称呼（键沿用 SummaryCollector.identityKeys），经 IdentityRedactor.names 拆分整理
    static func identityNames(context: ModelContext) -> [String] {
        guard let profile = context.all(Profile.self).sorted(by: { $0.createdAt < $1.createdAt }).first else { return [] }
        return IdentityRedactor.names(from: SummaryCollector.identityKeys.sorted().map { profile[$0] })
    }

    /// 问道灵枢 regenerate() 在 SummaryCollector.build 之后的两步（自检走的也是这一条路）：
    /// 1. 勾了“长期趋势与洞察”时带上长期摘要；
    /// 2. 开着“隐去姓名”时，把档案里的称呼在**整份摘要**（日记正文、目标 / 日程标题、手记备注……）与提示语里都换成〔姓名〕——
    ///    在结构体这一层换，Markdown、导出的 JSON、发给 AI 的结构体、存档的摘要就全是换过的。
    ///    提示语也换：自定义提示语是用户自己写的，可能写了名字。快照不走这里（只给用户自己的 apt-record 读，保留称呼）
    static func prepare(_ built: PlannerSummary, preamble: String, sections: Set<SummarySection>, hideIdentity: Bool,
                        context: ModelContext, today: LocalDay = .today()) -> (summary: PlannerSummary, preamble: String) {
        var summary = built
        if sections.contains(.trends) { attach(&summary, context: context, today: today) }
        guard hideIdentity else { return (summary, preamble) }
        let names = identityNames(context: context)
        guard !names.isEmpty else { return (summary, preamble) }
        return (IdentityRedactor.redact(summary, names: names), IdentityRedactor.redact(preamble, names: names))
    }
}

extension CultivationModel {
    /// 全部习惯（含已归档的，次序同 habits）与各自的打卡，写成长期摘要要的值类型。
    /// 打卡按日期排好（同一天几条时记了完成、数量多的在后，与 RecordCollector 镜像同一排法：HabitStats 以最后一条为准）。
    /// 习惯与打卡对不上（理论上不会）时为 nil，由调用方改走镜像
    var recordHabits: [RecordHabit]? {
        guard habits.count == habitInputs.count else { return nil }
        return zip(habits, habitInputs).map { habit, input in
            RecordHabit(title: habit.title, symbol: habit.symbol, spec: input.spec,
                        logs: input.logs.sorted { ($0.day, $0.completed ? 1 : 0, $0.quantity ?? 0) < ($1.day, $1.completed ? 1 : 0, $1.quantity ?? 0) },
                        archived: input.archived)
        }
    }
}
