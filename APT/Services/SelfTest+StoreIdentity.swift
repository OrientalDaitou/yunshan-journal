import Foundation
import SwiftData

// “按数据库缓存”的钥匙（StoreIdentity）的运行时自检。
// 以前各处缓存拿容器的内存地址当钥匙、又不持有容器：用完即弃的内存库释放后，地址被下一个新库复用，
// 缓存就把旧库的结果当成新库的交出去；修为模型还会交出属于已销毁数据库的 context，一读就崩（自检偶发的 SIGTRAP）。
// 这里反复新建、丢弃内存库：每一轮的数据“形状”完全相同（各类条数一样，修改时间钉在同一刻），只有内容不同，
// 缓存只要认错一次库，读出来的内容就对不上。最后再回头把丢掉的那些库挨个读一遍：它们被 StoreIdentity 留着，读得到、也不串。

extension SelfTest {
    static func storeIdentityChecks(_ check: (Bool, String) -> Void) throws {
        try storeIdentityKeyChecks(check)
        try storeIdentityRoundChecks(check)
    }

    // MARK: 1. 钥匙本身

    private static func storeIdentityKeyChecks(_ check: (Bool, String) -> Void) throws {
        let a = try DataStore.makeContainer(inMemory: true)
        let b = try DataStore.makeContainer(inMemory: true)
        let neverAsked = StoreIdentity.existingKey(for: a) == nil
        let heldBefore = StoreIdentity.heldCount
        let ka = StoreIdentity.key(for: a)
        let kb = StoreIdentity.key(for: b)
        check(neverAsked && ka != kb && StoreIdentity.key(for: a.mainContext) == ka && StoreIdentity.key(for: ModelContext(a)) == ka
              && StoreIdentity.existingKey(for: a) == ka && StoreIdentity.existingKey(for: b) == kb && StoreIdentity.heldCount == heldBefore + 2,
              "StoreIdentity：同一个库（主 context、新开的 context）同一把钥匙，两个库两把；只查不领时不登记")

        // 对照：用完即弃、没领钥匙的库，地址常被下一个新库复用（只写进说明，不作判定：分配器怎么复用由系统决定）
        var addresses = Set<ObjectIdentifier>()
        for _ in 0..<12 { addresses.insert(ObjectIdentifier(try DataStore.makeContainer(inMemory: true))) }
        // 领过钥匙的库被留住：自己这边丢掉引用后仍在，钥匙个个不同
        weak var dropped: ModelContainer?
        var keys = Set<StoreIdentity.Key>()
        for _ in 0..<12 {
            let container = try DataStore.makeContainer(inMemory: true)
            keys.insert(StoreIdentity.key(for: container))
            dropped = container
        }
        check(keys.count == 12 && dropped != nil,
              "领过钥匙的库被留住、地址不再被复用：12 个库 12 把不同的钥匙（对照：12 个用完即弃的库只占了 \(addresses.count) 个不同地址）")
    }

    // MARK: 2. 反复新建、丢弃内存库，各缓存拿到的都是本库的数据

    private static func storeIdentityRoundChecks(_ check: (Bool, String) -> Void) throws {
        let today = LocalDay.today()
        // 每一轮的修改时间都钉在这一刻：各类数据戳（条数 + 最新修改时间）轮轮相同，只剩“哪个库”能把它们分开
        let pinned = today.adding(days: -3).date(minutes: 9 * 60)
        let rounds = 10
        let heldBefore = StoreIdentity.heldCount

        /// 往库里写这一轮的数据：3 篇日记（心境随轮次变）、1 个习惯 3 条打卡、1 条日程、1 笔手记
        func fill(_ c: ModelContext, round: Int) throws {
            DataStore.settings(in: c)
            DataStore.profile(in: c)
            for offset in 0..<3 {
                let entry = JournalEntry(kind: .diary, title: "", body: "第\(round)库·日记\(offset)", dateKey: today.adding(days: -offset).key)
                entry.mood = 1 + round % 5
                entry.createdAt = pinned
                entry.updatedAt = pinned
                c.insert(entry)
            }
            let habit = Habit(title: "第\(round)库·功课")
            habit.startDate = today.adding(days: -10).key
            habit.createdAt = pinned
            habit.updatedAt = pinned
            c.insert(habit)
            for offset in 1...3 {
                let log = HabitLog(dateKey: today.adding(days: -offset).key)
                log.createdAt = pinned
                log.updatedAt = pinned
                c.insert(log)
                log.habit = habit
            }
            let event = ScheduleEvent(title: "第\(round)库·日程", dateKey: today.adding(days: 1).key)
            event.category = "第\(round)库类别"
            event.createdAt = pinned
            event.updatedAt = pinned
            c.insert(event)
            DataStore.save(c)
            _ = try FinanceService.mutate(c) {
                $0.transactions.append(ManualExpense.transaction(id: "manual-store-identity", day: today, cents: 1200, category: "餐饮与外卖",
                                                                 description: "第\(round)库·账", note: "", reason: "自检"))
            }
            try FinanceService.fetchStore(c)?.updatedAt = pinned
            DataStore.save(c)
        }

        struct Tally {
            var ok = 0
            var bad: [Int] = []
            mutating func note(_ pass: Bool, _ round: Int) { if pass { ok += 1 } else { bad.append(round) } }
            func line(_ total: Int) -> String { bad.isEmpty ? "\(ok)/\(total) 轮" : "第 \(bad.map(String.init).joined(separator: "、")) 轮对不上" }
        }
        var model = Tally(), journal = Tally(), mirror = Tally(), ledger = Tally(), digest = Tally(), memo = Tally()
        var seenModels = Set<ObjectIdentifier>()
        var previousDigest: LongTermDigest?
        var kept: [(round: Int, context: ModelContext)] = []

        /// 读这个库的各缓存，看拿到的是不是这一轮写的内容
        func verify(_ c: ModelContext, round: Int, revisit: Bool) {
            let uids = Set(c.all(JournalEntry.self).map(\.uid))
            // 修为模型：一库一份，交出来的是这个库的（习惯名对得上、修为与全量算的相同），没有拿到别的库留下的
            let m = CultivationModel.shared(for: c)
            m.refresh()
            let fresh = revisit ? seenModels.contains(ObjectIdentifier(m)) : seenModels.insert(ObjectIdentifier(m)).inserted
            model.note(fresh && m.habits.map(\.title) == ["第\(round)库·功课"] && CultivationModel.existing(for: c) === m
                       && m.state == CultivationService.fullState(context: c), round)
            // 修行录页的摘要（JournalDigest）：篇目就是这个库的那 3 篇
            let rows = JournalDigest.shared.sync(c).rows
            journal.note(Set(rows.map(\.id)) == Set(c.all(JournalEntry.self).map(\.persistentModelID)) && rows.count == 3, round)
            // 记录镜像与数据戳（RecordCollector）：篇目、心境、习惯、账簿都是这个库的
            let input = RecordCollector.input(context: c, from: today.adding(days: -30), to: today, today: today, text: false)
            mirror.note(Set(input.entries.map(\.uid)) == uids && input.entries.allSatisfy { $0.mood == 1 + round % 5 }
                        && input.habits.map(\.title) == ["第\(round)库·功课"]
                        && input.ledger?.transactions.map(\.description) == ["第\(round)库·账"]
                        && RecordCollector.stamp(context: c).hasPrefix(StoreIdentity.key(for: c).description + "|"), round)
            // 账簿的解码缓存（FinanceService）：读到的是这个库的账
            let index = try? FinanceService.loadIndex(c)
            ledger.note((try? FinanceService.load(c))?.transactions.map(\.description) == ["第\(round)库·账"]
                        && index?.ledger.transactions.map(\.description) == ["第\(round)库·账"], round)
            // 长期摘要（AIDigest）：这一轮第一次读时真的算了一次（没拿别的库的），结果与不经缓存现算的相同；心境不同的两轮结果不同。
            // 回头再读时只比结果（缓存只留最近 4 份，早几轮的已被挤掉、要重算）
            let computed = AIDigest.computeCount
            let d = AIDigest.digest(context: c, today: today)
            let recomputed = revisit || AIDigest.computeCount == computed + 1
            let direct = LongTermDigest.make(AIDigest.input(context: c, today: today, habits: nil), today: today)
            digest.note(recomputed && d == direct && (revisit || previousDigest.map { $0 != d } ?? true), round)
            if !revisit { previousDigest = d }
            // 快照里记下的整表结果（最近的日程类别）：投递说明里列的是这个库的类别
            if DataStore.customDirectory != nil {
                let readme = CourierService.readme(context: c)
                memo.note(readme.contains("第\(round)库类别") && !readme.contains("第\(round == 1 ? 2 : round - 1)库类别"), round)
            } else {
                memo.note(true, round)
            }
        }

        for round in 1...rounds {
            // 单数轮用 ModelContext(容器)，双数轮用库的主 context——主 context 不持有容器，以前容器一释放，
            // 登记着的修为模型里的 context 就读不得，下一轮新库落在同一地址上时正好被交出去（偶发崩溃就是这样）
            let container = try DataStore.makeContainer(inMemory: true)
            let c = round.isMultiple(of: 2) ? container.mainContext : ModelContext(container)
            try fill(c, round: round)
            verify(c, round: round, revisit: false)
            kept.append((round, c))
            // 这一轮结束：自己这边不再引用这个库（只留着 context）
        }
        let firstPass = (model, journal, mirror, ledger, digest, memo)
        // 回头再读一遍丢掉的那些库（倒着读，各缓存来回换库）：库被留着，读得到，也不串
        model = Tally(); journal = Tally(); mirror = Tally(); ledger = Tally(); digest = Tally(); memo = Tally()
        for (round, c) in kept.reversed() { verify(c, round: round, revisit: true) }
        let held = StoreIdentity.heldCount - heldBefore

        func line(_ first: Tally, _ again: Tally) -> String { "\(first.line(rounds))，回头再读 \(again.line(rounds))" }
        check(firstPass.0.bad.isEmpty && model.bad.isEmpty,
              "反复新建、丢弃内存库：修为模型每个库一份，交出的都是本库的（\(line(firstPass.0, model))）")
        check(firstPass.1.bad.isEmpty && journal.bad.isEmpty, "反复新建、丢弃内存库：修行录摘要拿到的都是本库的篇目（\(line(firstPass.1, journal))）")
        check(firstPass.2.bad.isEmpty && mirror.bad.isEmpty, "反复新建、丢弃内存库：记录镜像与数据戳都是本库的（\(line(firstPass.2, mirror))）")
        check(firstPass.3.bad.isEmpty && ledger.bad.isEmpty, "反复新建、丢弃内存库：账簿解码缓存读到的都是本库的账（\(line(firstPass.3, ledger))）")
        check(firstPass.4.bad.isEmpty && digest.bad.isEmpty, "反复新建、丢弃内存库：长期摘要每个库各算各的（\(line(firstPass.4, digest))）")
        check(firstPass.5.bad.isEmpty && memo.bad.isEmpty, "反复新建、丢弃内存库：快照记下的日程类别是本库的（\(line(firstPass.5, memo))）")
        check(held == rounds, "领过钥匙的 \(held)/\(rounds) 个库都被留住（丢掉引用后修为模型里的 context 仍读得到）")
    }
}
