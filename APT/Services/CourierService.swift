import Foundation
import SwiftData

/// 撤销一封传书的结果：删了几条、保留了几条收录后被用户改过的；failure 不为空时表示没有撤销（什么都没动）。
struct CourierUndoReport {
    /// 撤回的项数：删掉的记录，加上恢复成原内容的档案字段（restored）
    var removed: Int
    var keptEdited: Int
    var failure: String?
    /// removed 里有几项是档案字段：不是删除，而是恢复成传书之前的内容
    var restored: Int = 0
    /// 之后又被别的传书改写过、这次没动的档案字段
    var superseded: Int = 0
    /// removed 里有几个是目标：不是删除，而是把传书的更新恢复成更新前的值（一个目标改了几项也只算 1 个）
    var restoredGoals: Int = 0
    /// 保留原因（例如新建的习惯已有别的打卡、目标的某项后来又被别的传书改过），最多 3 条
    var notes: [String] = []
    /// keptEdited 里有几项是档案字段、几个是目标（其余是记录）：结果提示按这三类分开说
    var keptFields: Int = 0
    var keptGoals: Int = 0

    /// 结果提示的说法（传书笺与修行录左栏共用，见 CourierUndoWording）
    var wording: CourierUndoWording.Outcome {
        CourierUndoWording.Outcome(deleted: max(0, removed - restored - restoredGoals), restoredFields: restored, restoredGoals: restoredGoals,
                                   keptRecords: max(0, keptEdited - keptFields - keptGoals), keptFields: keptFields, keptGoals: keptGoals,
                                   superseded: superseded, notes: notes)
    }
}

/// 撤销前的预览：这封传书写入、现在还在的记录与改写过的档案字段，其中各有几项收录后被用户改过（撤销时默认保留）。
/// 已被用户删掉的记录不计入。
struct CourierUndoPreview {
    /// 修行录、日程、打卡、账目：撤销时删除
    var records = 0
    var editedRecords = 0
    /// 档案字段：撤销时恢复成传书之前的内容（选“全部撤销”时，用户后来改的内容也会被换回去）
    var fields = 0
    var editedFields = 0
    /// 之后又被别的（没撤销的）传书改写过的档案字段：这次不动，以后来的为准
    var superseded = 0
    /// 目标更新：撤销时恢复成更新前的值（一个目标改了几项合计 1 项；被后来的传书改过的不计，只进 notes）
    var goals = 0
    var editedGoals = 0
    /// 保留原因，最多 3 条：新建的习惯已有别的打卡（撤销也保留，不计入 total）、目标某项以后来的传书为准
    var notes: [String] = []

    var total: Int { records + fields + goals }
    var edited: Int { editedRecords + editedFields + editedGoals }

    /// 撤销说明的说法（传书笺与修行录左栏共用，见 CourierUndoWording）
    var wording: CourierUndoWording.Plan {
        CourierUndoWording.Plan(records: records, editedRecords: editedRecords, fields: fields, editedFields: editedFields,
                                goals: goals, editedGoals: editedGoals, superseded: superseded, notes: notes)
    }
}

/// 飞剑传书：AI（或任何脚本）把 JSON 放进收件箱，应用几秒内收录；每次收录都可以整批撤销。
///
/// 目录结构（`~/Library/Application Support/APT-SwiftUI/AI/`）：
/// - `inbox/`      投递处：放 `*.json`（先写临时名再改名，或直接写入均可；刚写入 1 秒内的文件会等下一轮）
/// - `processed/`  已收录的原件，以及“收录时间-原名.result.txt”回执（重复投递被跳过的也在这里）
/// - `failed/`     校验失败的原件，以及“收录时间-原名.error.txt”（说明哪一条、哪个字段有问题）
/// - `snapshot.md` 应用自动维护的数据快照，供 AI 读取后复盘、给建议
/// - `README.md`   给 AI 看的投递格式说明（含当前的习惯、消费类别与日程类别）
///
/// 只有应用本身写数据库：AI 从不直接碰 SwiftData，避免两个进程同时写入。
/// 写入的记录如何标记（撤销、界面区分来源都靠它）：
/// - 修行录：`source = "courier"`、`deliveryID`；日程与打卡：`legacyID = "courier:<UUID>"`；账目：`id = "courier-<UUID>"`、账户“手记”。
/// - 档案：改写原有字段，引用里记下字段 key 与改写前后的内容，撤销时恢复原内容。
/// - 目标：新立的 `legacyID = "courier:<UUID>"`；更新时给用户建的目标补 `legacyID = "apt-goal:<UUID>"`，每个改了的字段记一条 goalset 引用（改写前后的值）。
/// - 习惯：新建的 `legacyID = "courier:<UUID>"`。目标与习惯的写入、撤销在 CourierGoalHabitStore.swift。
@MainActor
enum CourierService {
    static var root: URL { DataStore.directory.appendingPathComponent("AI", isDirectory: true) }
    static var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    static var processed: URL { root.appendingPathComponent("processed", isDirectory: true) }
    static var failed: URL { root.appendingPathComponent("failed", isDirectory: true) }
    static var snapshotURL: URL { root.appendingPathComponent("snapshot.md") }
    static var readmeURL: URL { root.appendingPathComponent("README.md") }
    /// 给命令行投递看的小抄（现有习惯名），刷新快照时顺带写出
    nonisolated static var stateURL: URL { DataStore.directory.appendingPathComponent("AI/.courier-state.json") }

    /// 单个投递文件的大小上限：超过就不读，直接移到 failed/
    nonisolated static let maxFileSize = 1_000_000
    /// processed/、failed/ 里的归档保留天数
    static let archiveDays = 90
    /// “收录后被用户改过”的判定：修改时间比收录时刻晚这么多秒以上
    static let editedAfter: TimeInterval = 2
    /// 同样的内容在这段时间内已收录（且未撤销），再投就视为重复投递
    static let duplicateWindow: TimeInterval = 7 * 86_400
    /// 判断“今天”、换算相对日期用的时区：与应用其余部分一致（LocalDay.today() 用的也是本机时区）
    nonisolated static var timeZone: TimeZone { .current }

    /// before / after：档案字段与目标更新（goalset）记改写前后的内容；新立的目标（goal）、新建的习惯（habit）的 after 记值指纹，
    /// 撤销时比对“用户改没改过”。其余类型不写，旧传书照常解码
    struct Ref: Codable { var t: String; var r: String; var before: String? = nil; var after: String? = nil }

    static func prepareFolders() {
        for url in [inbox, processed, failed] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: 常驻巡查

    /// 常驻巡查正在运行（离屏渲染、命令行、自检时不运行）：用户操作后的快照刷新交给它，见 refreshSnapshotSoon
    private(set) static var patrolling = false

    /// 由 AppHost 在应用启动时启动（主窗口关着也运行；离屏 / 命令行模式不启动）：收件箱一有文件就醒来收录（约 1–3 秒）；
    /// 数据一有变化（停稳 3 秒后）就刷新快照，另每 10 分钟兜底刷新一次。
    /// 节奏见 CourierPace（#21）：前台每 3 秒看一眼；不在前台时靠门铃（InboxWatcher：收件箱有文件进出、数据库保存、回到前台）叫醒，另 60 秒兜底。
    static func run(context: ModelContext, effects: EffectsCenter) async {
        patrolling = true
        defer { patrolling = false }
        prepareFolders()
        cleanArchives()
        refreshSnapshot(context: context)
        let bell = InboxWatcher()
        defer { bell.stop() }
        var calm = SnapshotCalm(fingerprint(context))
        var lastRecheck = Date()
        var lastClean = Date()
        while !Task.isCancelled {
            // 收件箱被删掉、换了数据目录：先建好再重新盯上
            if !bell.watch(inbox) {
                prepareFolders()
                bell.watch(inbox)
            }
            if !pendingFiles().isEmpty {
                let delivered = processInbox(context: context, effects: effects)
                if delivered > 0 { refreshSnapshot(context: context) }
            }
            // 数据变了、且停稳约 3 秒没再变才重建：边打字边自动保存时不会每 3 秒重算一遍；
            // 按钟点算（SnapshotCalm），门铃中途把两轮隔得只有 0.5 秒时也不提前重建
            let current = fingerprint(context)
            let now = Date()
            let settled = calm.settled(current, now: now)
            if current != snapshotFingerprint, settled { refreshSnapshot(context: context) }
            // 珍藏等不带修改时间的改动，靠这里兜底（内容没变不会重写文件）；记下的修为、日程类别也一并重算
            if CourierPace.due(since: lastRecheck, now: now, every: CourierPace.recheckEvery) {
                refreshSnapshot(context: context, recheck: true)
                lastRecheck = now
            }
            if CourierPace.due(since: lastClean, now: now, every: CourierPace.cleanEvery) {
                cleanArchives()
                lastClean = now
            }
            let unsettled = current != snapshotFingerprint
            let pace = CourierPace.next(foreground: InboxWatcher.appInFront, watching: bell.watching,
                                        unsettled: unsettled, settlingAge: settlingAge())
            // 还没停稳：最多睡到改动后满 3 秒那一刻再确认
            await bell.wait(unsettled ? calm.pace(pace, now: Date()) : pace)
        }
    }

    static func pendingFiles(now: Date = Date()) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: keys)) ?? []
        return files.filter { url in
            guard url.pathExtension.lowercased() == "json", !url.lastPathComponent.hasPrefix(".") else { return false }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return false }
            return now.timeIntervalSince(values?.contentModificationDate ?? now) >= 1
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 收件箱里应用不会处理的文件：改名失败留下的 `.bad`、扩展名不对的文件、写了一半被丢下的 `.tmp`。
    static func strayFiles(now: Date = Date()) -> [String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: keys)) ?? []
        return files.compactMap { url -> String? in
            let ext = url.pathExtension.lowercased()
            guard !url.lastPathComponent.hasPrefix("."), ext != "json" else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return nil }
            // 刚写的临时文件（还没来得及改名）不算
            if ext == "tmp", now.timeIntervalSince(values?.contentModificationDate ?? now) < 600 { return nil }
            return url.lastPathComponent
        }
        .sorted()
    }

    /// 移不走、也改不了名的文件（例如被锁定）：记住它们，不再重复收录
    private static var stuckFiles: Set<String> = []

    /// 收录收件箱里的所有文件，返回成功收录的份数。
    @discardableResult
    static func processInbox(context: ModelContext, effects: EffectsCenter?) -> Int {
        prepareFolders()
        // 同一时刻只让一个进程收录（例如 Xcode 调试版和已安装的版本同时开着），免得同一封写两遍
        let lock = open(root.appendingPathComponent(".inbox.lock").path, O_CREAT | O_RDWR, 0o644)
        if lock >= 0, flock(lock, LOCK_EX | LOCK_NB) != 0 {
            close(lock)
            return 0
        }
        defer {
            if lock >= 0 {
                flock(lock, LOCK_UN)
                close(lock)
            }
        }

        let now = Date()
        let latest = LocalDay(date: now, timeZone: timeZone)
        var deliveries: [CourierDelivery] = []
        var failures: [(file: String, message: String)] = []
        for url in pendingFiles(now: now) {
            let identity = fileIdentity(url)
            guard !stuckFiles.contains(identity) else { continue }
            let stamp = DateText.fileStamp(Date())
            let name = url.lastPathComponent
            func reject(_ message: String) {
                failures.append((name, message))
                if !move(url, to: failed, stamp: stamp, note: message, noteExtension: "error.txt") { stuckFiles.insert(identity) }
            }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if let size = values?.fileSize, size > maxFileSize {
                reject("文件太大（约 \(sizeText(size))，上限 \(sizeText(maxFileSize))），没有读取。一封传书只放要记的内容；内容多就拆成几个文件投递。")
                continue
            }
            // 相对日期（today / 省略等）按文件写入的时刻换算：应用没开、隔天才收录时也不会记错日子
            let written = min(values?.contentModificationDate ?? now, now)
            let base = LocalDay(date: written, timeZone: timeZone)
            // 解析错误与写入无关，不碰数据库；只有写入失败才撤回本次写入
            let payload: CourierPayload
            do {
                payload = try CourierParser.parse(try Data(contentsOf: url), relativeTo: base, latest: latest)
            } catch {
                reject(error.localizedDescription)
                continue
            }
            // 同样的内容已经收录过（AI 重投、两个进程抢收、收录后来不及移走就退出）：不再写入
            if let earlier = duplicate(of: contentHash(payload), context: context, now: now) {
                let note = "重复投递，已跳过：内容与 \(DateText.stamp(earlier.receivedAt)) 收录的传书（\(earlier.fileName)，\(earlier.itemCount) 条）完全相同，"
                    + "这次没有写入任何记录。请不要告诉用户“已记好”。\n" + duplicateAdvice(payload, earlier: earlier, context: context)
                if !move(url, to: processed, stamp: stamp, note: note, noteExtension: "result.txt") { stuckFiles.insert(identity) }
                // 也放进传书笺：用户能看到这封被跳过了（原件在 processed/，不在 failed/）
                failures.append((name, "重复投递，已跳过：与 \(DateText.stamp(earlier.receivedAt)) 收录的传书内容相同，这次没有写入（原件在 AI/processed/）。"
                                 + "如确是另一笔，请让 AI 在条目里写明区别后重投。"))
                NSLog("APT 飞剑传书：\(name) 与已收录的内容相同，已跳过")
                continue
            }
            // 先保存用户正在编辑的内容，撤回时就只会撤掉本次传书写入的部分
            if context.hasChanges { DataStore.save(context) }
            do {
                let remark = payload.relativeDates > 0 && base != latest ? "（相对日期按写入那天 \(base.shortLabel) 计算）" : ""
                // 收件箱按条退回：打卡的习惯名 / 单位对不上只退那一条，其余照收（整封全是这类才进 failed/）
                let applied = try applyCore(payload, fileName: name, context: context, remark: remark, partial: true)
                let delivery = applied.delivery
                let receipt = receiptText(delivery, payload: payload, written: written, base: base, latest: latest, notices: applied.notices,
                                          skipped: applied.skipped)
                if !move(url, to: processed, stamp: stamp, note: receipt, noteExtension: "result.txt") {
                    stuckFiles.insert(identity)
                }
                deliveries.append(delivery)
            } catch {
                context.rollback()
                reject(error.localizedDescription)
            }
        }
        // 一轮收到多封时合并成一张传书笺
        if !deliveries.isEmpty || !failures.isEmpty {
            effects?.courierBatch(deliveries: deliveries, failures: failures)
        }
        return deliveries.count
    }

    private static func fileIdentity(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(url.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
    }

    /// 回执：写了哪几条、相对日期按哪天换算、有哪些提醒（按别名理解的字段、忽略的字段、可疑的日期）。
    /// notices：收录时发现、只给 AI 看的提醒（例如记账条目可能与账上已有的银行流水是同一笔）。
    /// skipped：按条退回的打卡。有退回时首行写“已收录 N 条，另有 M 条没有收录（见下）”，末尾逐条列出原因
    static func receiptText(_ delivery: CourierDelivery, payload: CourierPayload, written: Date, base: LocalDay, latest: LocalDay,
                            notices: [String] = [], skipped: [(index: Int, skip: CourierRoster.Skip)] = []) -> String {
        let source = "来自 \(delivery.from)；用户可在应用「修行录 → 飞剑传书」整批撤销"
        // 摘要里的“未收 ·”行是给传书笺看的短说法，回执末尾另有完整原因，这里不重复
        let summary = delivery.summary.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !CourierLineDecor.isSkipped($0) }.joined(separator: "\n")
        var lines = skipped.isEmpty
            ? ["已收录 \(delivery.itemCount) 条（\(source)）", summary]
            : ["已收录 \(delivery.itemCount) 条，另有 \(skipped.count) 条没有收录（见下）", "（\(source)收下的这些）", summary]
        if payload.relativeDates > 0 {
            var line = "其中 \(payload.relativeDates) 条的日期是相对写法（today / yesterday / tomorrow / 省略），"
            line += "已按文件写入时刻 \(DateText.stamp(written))（\(timeZone.identifier)）换算"
            if base != latest { line += "；应用是 \(latest.shortLabel) 才收录的" }
            lines += ["", line + "。"]
        }
        let reminders = payload.warnings + notices
        if !reminders.isEmpty {
            lines += ["", "提醒："] + reminders.map { "- " + $0 }
        }
        if !skipped.isEmpty {
            lines += ["", "没有收录（其余已经记好：请只把下面这几条改好后另投一封，不要整封重投，否则会重复记录）："]
            lines += skipped.map { "- 未收录 · 第 \($0.index + 1) 条：\($0.skip.receipt)" }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 去重

    /// 内容指纹：解析后的各条内容规范化再取 SHA-256（与字段顺序、多余空白、文件名、from/note 无关）。
    /// 打卡写了单位的把单位接在后面（“冥想 1 小时”与“冥想 1 分钟”不是同一封）；没写单位的与原来的指纹相同
    static func contentHash(_ payload: CourierPayload) -> String {
        let parts = payload.items.enumerated().map { index, item in
            payload.checkinUnits[index].map { item.canonical + "\u{1F}" + $0 } ?? item.canonical
        }
        return FinanceEngine.sha256(parts.sorted().joined(separator: "\u{1E}"))
    }

    /// 7 天内收录过同样内容、而且它写入的记录现在至少还有一条在的传书。
    /// 一条都没写入的（例如打卡因当天已有记录被跳过），或写入的记录已被用户删光的，不算：否则会挡住之后正当的重投。
    private static func duplicate(of hash: String, context: ModelContext, now: Date) -> CourierDelivery? {
        var ledgerLoaded = false
        var ledgerIDs: Set<String>?
        // 只让数据库取 7 天内（多留一分钟余量）、没撤销、写入过记录的传书，下面再按原条件精确筛一遍
        let since = now.addingTimeInterval(-duplicateWindow - 60)
        let recent = (try? context.fetch(FetchDescriptor<CourierDelivery>(predicate: #Predicate { !$0.undone && $0.itemCount > 0 && $0.receivedAt > since })))
            ?? context.all(CourierDelivery.self)
        return recent
            .filter { !$0.undone && $0.itemCount > 0 && now.timeIntervalSince($0.receivedAt) < duplicateWindow }
            .sorted { $0.receivedAt > $1.receivedAt }
            .first { delivery in
                guard refs(of: delivery).contains(where: { $0.t == "hash" && $0.r == hash }) else { return false }
                let w = written(by: delivery, context: context)
                if !w.entries.isEmpty || !w.events.isEmpty || !w.logs.isEmpty { return true }
                if goalHabitStillPresent(goalHabitWritten(refs(of: delivery), context: context)) { return true }
                if w.profileRefs.contains(where: { !isEdited($0, in: w.profile) }) { return true }
                guard !w.expenseIDs.isEmpty else { return false }
                // 账本只在需要时读一次；读不出来时按“还在”算，宁可跳过也不重复记账
                if !ledgerLoaded {
                    ledgerIDs = (try? FinanceService.load(context)).map { Set($0.transactions.map(\.id)) }
                    ledgerLoaded = true
                }
                guard let ids = ledgerIDs else { return true }
                return !w.expenseIDs.isDisjoint(with: ids)
            }
    }

    /// 重复投递被跳过时，按条目类型给 AI 的补救建议。
    /// earlier 是内容相同的上一封：它有按条退回的打卡时，先说清那几条其实没收（“上次那封第 2 条没有收录…”），
    /// 也不再说“已为这一天打过卡”——那几条从没记下，AI 照那句告诉用户“已经打过卡了”就错了
    static func duplicateAdvice(_ payload: CourierPayload, earlier: CourierDelivery, context: ModelContext) -> String {
        var has = Set<String>()
        for item in payload.items {
            switch item {
            case .entry: has.insert("entry")
            case .expense: has.insert("expense")
            case .event: has.insert("event")
            case .checkin: has.insert("checkin")
            case .profile: has.insert("profile")
            case .goal(let g): has.insert(g.action == .create ? "goal-create" : "goal-update")
            case .habit: has.insert("habit")
            }
        }
        // 上一封按条退回的打卡：摘要里的“未收 ·”行（按顺序）与 refs 里记的条号（旧版没记条号时只列说法）
        let missed = earlier.summary.split(separator: "\n").map(String.init).filter(CourierLineDecor.isSkipped)
        let numbers = refs(of: earlier).filter { $0.t == "skip" }.compactMap { Int($0.r) }
        let checkins = payload.items.filter { if case .checkin = $0 { true } else { false } }.count
        var lines: [String] = []
        if !missed.isEmpty {
            let which = numbers.count == missed.count ? "第 " + numbers.map(String.init).joined(separator: "、") + " 条" : "有 \(missed.count) 条打卡"
            lines.append("注意：上次那封\(which)没有收录（\(missed.joined(separator: "；"))），其余已记好。"
                         + "现在要补，请只把这几条改好（习惯名、数量或单位）单独投一封；整封原样重投会再次被当作重复跳过。")
        }
        lines.append(missed.isEmpty ? "多半是同一封投了两次，不要再投；如果用户确实又有一笔一模一样的："
                                    : "其余条目多半是同一封投了两次，不要再投；如果用户确实又有一笔一模一样的：")
        if has.contains("expense") { lines.append("- 消费：在 note 里写明区别（例如“第二杯”）后换个文件名重投") }
        if has.contains("event") { lines.append("- 日程：在 notes 里写明区别后重投") }
        if has.contains("entry") { lines.append("- 日记 / 灵感 / 复盘：内容完全相同，通常不用再记；确要另记一条请改写正文") }
        // 打卡全是上次退回的那几条时不说“已打过卡”；还有别的打卡时只说“其余打卡”
        if has.contains("checkin"), checkins > missed.count {
            let which = missed.isEmpty ? "打卡" : "其余打卡"
            lines.append("- \(which)：之前那封已为这一天打过卡，通常无需重投（同一习惯一天只记一条）；若那条打卡已被删掉、确要重打，请把打卡单独投一封")
        }
        if has.contains("profile") { lines.append(profileAdvice(payload, context: context)) }
        if has.contains("goal-create") { lines.append(#"- 新立目标：这个目标已经建好了，无需重投；要改进度请写 "action": "update""#) }
        if has.contains("goal-update") { lines.append("- 更新目标：这些值现在就是这个内容，无需重投") }
        if has.contains("habit") { lines.append("- 新建习惯：这个习惯已经建好了，无需重投；要打卡请用 checkin") }
        lines.append("回复用户时如实说明这封被跳过的原因。")
        return lines.joined(separator: "\n")
    }

    /// 档案的补救建议要看现在的实际内容：之前那封收录后，用户可能又改过其中的字段，不能一概说“现在就是这个内容”
    private static func profileAdvice(_ payload: CourierPayload, context: ModelContext) -> String {
        // 这封想写的内容（同一封里多条 profile 写同一字段时以后面的为准，与收录时一致）
        var wanted: [String: String] = [:]
        for case let .profile(fields) in payload.items { wanted.merge(fields) { _, later in later } }
        let profile = context.all(Profile.self).sorted { $0.createdAt < $1.createdAt }.first
        let differ = ProfileCatalog.allFields.filter { field in
            wanted[field.key].map { (profile?[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) != $0 } ?? false
        }
        guard !differ.isEmpty else { return "- 档案：这些字段现在就是这个内容，无需重投" }
        let names = differ.map { "\($0.key)（\($0.label)）" }.joined(separator: "、")
        return "- 档案：\(names) 现在不是这封里的内容（之前那封收录后又被改过），这次也没有改动；"
            + "如果用户确实要改成这封里的内容，请只把这几个字段单独投一封"
    }

    static func refs(of delivery: CourierDelivery) -> [Ref] {
        (try? JSONDecoder().decode([Ref].self, from: Data(delivery.refsJSON.utf8))) ?? []
    }

    // MARK: 写入与撤销

    /// 先整体校验（例如习惯是否存在），全部通过才写入，避免半份文件落库。
    /// remark：附在传书摘要末尾的一行说明（例如相对日期按哪天换算）。
    static func apply(_ payload: CourierPayload, fileName: String, context: ModelContext, remark: String = "") throws -> CourierDelivery {
        try applyWithNotices(payload, fileName: fileName, context: context, remark: remark).delivery
    }

    /// 同 apply，另外返回只写进回执给 AI 看的提醒：记账条目与账上已有的银行流水金额相同、日期相差 3 天内时
    /// （AI 补记过去的消费、而银行流水已经导入），照常收录，但请 AI 向用户确认是不是同一笔。
    static func applyWithNotices(_ payload: CourierPayload, fileName: String, context: ModelContext,
                                 remark: String = "") throws -> (delivery: CourierDelivery, notices: [String]) {
        let applied = try applyCore(payload, fileName: fileName, context: context, remark: remark, partial: false)
        return (applied.delivery, applied.notices)
    }

    /// 写入的本体。partial 为真（收件箱收录）时，打卡的习惯名 / 单位对不上只退回那一条：不写入、不进撤销引用（撤销只撤收下的），
    /// 摘要末尾记一行“未收 · 打卡「游泳」：没有这项功课”，skipped 交给回执逐条说明；为假时与原来一样整封拒收。
    /// 去重指纹仍按整封算
    static func applyCore(_ payload: CourierPayload, fileName: String, context: ModelContext, remark: String = "",
                          partial: Bool) throws -> (delivery: CourierDelivery, notices: [String], skipped: [(index: Int, skip: CourierRoster.Skip)]) {
        // 整封预检：打卡的习惯、新建的习惯、要更新的目标对不对得上现有数据（与 --add 用同一个 CourierRoster.resolve、同一套报错原文）
        let plan = try goalHabitPlan(payload, context: context, partial: partial)
        let skipped = plan.skipped.keys.sorted().compactMap { i in plan.skipped[i].map { (index: i, skip: $0) } }

        // 有记账条目时先确认账本可读，读不了就整份拒收（在写入任何记录之前）；读到的账本顺带用来查疑似重复的银行流水
        let ledger: FinanceLedger? = payload.items.contains(where: { if case .expense = $0 { true } else { false } })
            ? try FinanceService.load(context) : nil
        var notices: [String] = []
        let profile: Profile? = payload.items.contains(where: { if case .profile = $0 { true } else { false } })
            ? DataStore.profile(in: context) : nil

        let from = payload.from.isEmpty ? "AI" : payload.from
        let delivery = CourierDelivery(fileName: fileName, from: from, note: payload.note)
        var refs: [Ref] = []
        var lines: [String] = []
        var expenses: [FinanceTransaction] = []
        // 同一封里多条 profile 写同一字段时合并成一项、摘要只占一行：撤销预览与实际撤销才一致，条数也不会多算。
        // profileRefAt / profileLineAt：字段 key → 它在 refs、lines 里的位置；netZero：合并后又写回了原内容、等于没改的项（最后去掉）
        var profileRefAt: [String: Int] = [:]
        var profileLineAt: [String: Int] = [:]
        var netZero = Set<Int>()
        let today = LocalDay.today(in: timeZone)

        // 新建的习惯在主循环前统一插入：同一封里排在它前面的打卡也能挂上
        insertNewHabits(plan, context: context)
        for (index, item) in payload.items.enumerated() {
            let uid = UUID().uuidString
            switch item {
            case let .entry(kind, day, minute, title, body, mood, period, tags):
                let entry = JournalEntry(kind: kind, title: title, body: body, dateKey: day.key)
                entry.minute = minute
                entry.mood = mood
                entry.period = period
                entry.tags = tags
                entry.source = "courier"
                entry.sourceNote = from
                entry.deliveryID = delivery.deliveryID
                context.insert(entry)
                refs.append(Ref(t: "entry", r: entry.uid))
                lines.append(item.summary)
            case let .expense(day, cents, category, description, note):
                let id = "courier-" + uid
                let row = ManualExpense.transaction(id: id, day: day, cents: cents, category: category, description: description,
                                                    note: note, reason: "飞剑传书 · \(from)")
                // 只提醒、不阻止：账上已有金额相同、日期相差 3 天内的银行扣款，多半是同一笔刷卡消费
                if let ledger, let bank = FinanceEngine.existingBankMatches(for: row, in: ledger).first {
                    notices.append("第 \(index + 1) 条 expense 与账上已有银行流水 \(bank.date.suffix(5)) \(FinanceEngine.merchantKey(bank)) "
                                   + "\(FinanceEngine.money(bank.amountCents)) 金额相同、日期相差 3 天内，可能重复，请向用户确认"
                                   + "（已照常收录；确是同一笔可在「灵石账簿 → 交易明细」删掉这笔手记，或整批撤销这封传书）")
                }
                expenses.append(row)
                refs.append(Ref(t: "expense", r: id))
                lines.append(item.summary)
            case let .event(day, start, end, title, location, category, notes):
                let event = ScheduleEvent(title: title, dateKey: day.key)
                event.startMinute = start
                event.endMinute = end
                event.location = location
                event.category = category
                event.notes = notes
                event.legacyID = "courier:" + uid
                context.insert(event)
                refs.append(Ref(t: "event", r: "courier:" + uid))
                lines.append(item.summary)
            case let .checkin(_, day, written):
                // 退回的这一条不写（摘要末尾另记一行）；换算过单位的按功课的单位记
                guard plan.skipped[index] == nil, let habit = plan.checkinHabits[index] else { continue }
                let quantity = plan.checkinQuantities[index] ?? written
                // 当天已有记录（无论是否达标）都不覆盖，免得冲掉用户手动记的数量、撤销后又无法还原。
                // 这天的打卡按日期直接取（含这封里前面刚记、还没保存的），不读 habit.logs
                if HabitDayLogs(day: day, context: context).log(of: habit) != nil {
                    lines.append("打卡 · \(day.shortLabel) · \(habit.title)（当天已有记录，跳过）")
                    continue
                }
                let target = habit.targetValue.flatMap { $0 > 0 ? $0 : nil }
                let log = HabitLog(dateKey: day.key, completed: true, quantity: quantity ?? target)
                log.legacyID = "courier:" + uid
                log.notes = "飞剑传书 · \(from)"
                context.insert(log)
                log.habit = habit
                habit.updatedAt = Date()
                refs.append(Ref(t: "checkin", r: "courier:" + uid))
                lines.append("打卡 · \(day.shortLabel) · \(habit.title)" + (quantity.map { "（\(format($0))\(habit.unit)）" } ?? ""))
            case let .goal(g):
                applyGoal(g, index: index, plan: plan, context: context, today: today, refs: &refs, lines: &lines)
            case let .habit(h):
                applyHabit(h, index: index, plan: plan, today: today, refs: &refs, lines: &lines)
            case let .profile(fields):
                guard let profile else { continue }
                for field in ProfileCatalog.allFields {
                    guard let value = fields[field.key] else { continue }
                    let old = profile[field.key]
                    /// 这个字段在摘要里的那一行：本封已经列过就改写那一行，不再多列
                    func show(_ line: String) {
                        if let at = profileLineAt[field.key] { lines[at] = line } else { profileLineAt[field.key] = lines.count; lines.append(line) }
                    }
                    let skipped = "档案 · \(field.label)（已是这个内容，跳过）"
                    if old.trimmingCharacters(in: .whitespacesAndNewlines) == value {
                        // 前面的条目已经列过这个字段（例如刚写过同样的内容）就不再多列一行
                        if profileLineAt[field.key] == nil { show(skipped) }
                        continue
                    }
                    profile[field.key] = value
                    if let at = profileRefAt[field.key] {
                        // 本封前面已改写过这个字段：并进那一项，before 仍是收录前的原内容
                        let before = refs[at].before ?? ""
                        if before.trimmingCharacters(in: .whitespacesAndNewlines) == value {
                            // 又写回了原内容：等于没改，字段还原成收录前的样子，这一项不记
                            profile[field.key] = before
                            netZero.insert(at)
                            show(skipped)
                        } else {
                            refs[at].after = value
                            netZero.remove(at)
                            show(profileLine(field.label, value))
                        }
                    } else {
                        profileRefAt[field.key] = refs.count
                        refs.append(Ref(t: "profile", r: field.key, before: old, after: value))
                        show(profileLine(field.label, value))
                    }
                }
            }
        }

        // 先登记传书（含撤销所需的引用与内容指纹），再记账；最后一次保存失败会抛出，由调用方整体撤回
        if !netZero.isEmpty { refs = refs.indices.filter { !netZero.contains($0) }.map { refs[$0] } }
        // 收录条数：一个目标改了几项只算 1 条（goalset 按目标合并），其余每条 1
        delivery.itemCount = CourierRefCount.items(refs.map { ($0.t, $0.r) })
        notices += plan.notices
        refs.append(Ref(t: "hash", r: contentHash(payload)))
        // 按条退回的打卡记下条号（不算收录条数、撤销不看）：AI 之后整封原样重投被当作重复跳过时，回执据此说清哪几条其实没收
        refs += skipped.map { Ref(t: "skip", r: String($0.index + 1)) }
        delivery.refsJSON = (try? String(data: JSONEncoder().encode(refs), encoding: .utf8)) ?? "[]"
        let skippedLines = skipped.map { CourierLineDecor.skippedLine($0.skip.short) }
        delivery.summary = (lines + skippedLines + (remark.isEmpty ? [] : [remark])).joined(separator: "\n")
        context.insert(delivery)
        if !expenses.isEmpty {
            _ = try FinanceService.mutate(context) { $0.transactions.append(contentsOf: expenses) }
        }
        try context.save()
        return (delivery, notices, skipped)
    }

    /// 档案字段写进传书摘要的一行：多行内容压成一行（用“；”隔开），超过 24 字截断
    private static func profileLine(_ label: String, _ value: String) -> String {
        let text = CourierItem.oneLine(value, separator: "；")
        return "档案 · \(label)：\(text.count > 24 ? String(text.prefix(24)) + "…" : text)"
    }

    /// 一封传书写入、而且现在还在的记录
    private struct Written {
        var entries: [JournalEntry] = []
        var events: [ScheduleEvent] = []
        var logs: [HabitLog] = []
        var expenseIDs: Set<String> = []
        /// 改写过的档案字段，每个字段一项（含收录后又被用户改掉的；档案没了时为空）
        var profileRefs: [Ref] = []
        var profile: Profile?
    }

    /// 只按 ID 取这封写入的记录（整表取再过滤的话，打卡一多要好几秒）；查询出错时退回整表过滤
    private static func written(by delivery: CourierDelivery, context: ModelContext) -> Written {
        let refs = refs(of: delivery)
        let entryIDs = Array(Set(refs.filter { $0.t == "entry" }.map(\.r)))
        // legacyID 是可选的，ID 数组也写成可选：写成 `$0.legacyID ?? ""` 的话 SwiftData 生成不了 SQL，会直接崩溃
        let legacyIDs: [String?] = Set(refs.filter { $0.t == "event" || $0.t == "checkin" }.map(\.r)).map { $0 }
        var w = Written()
        w.expenseIDs = Set(refs.filter { $0.t == "expense" }.map(\.r))
        if !entryIDs.isEmpty {
            w.entries = (try? context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { entryIDs.contains($0.uid) })))
                ?? context.all(JournalEntry.self).filter { entryIDs.contains($0.uid) }
        }
        if !legacyIDs.isEmpty {
            w.events = (try? context.fetch(FetchDescriptor<ScheduleEvent>(predicate: #Predicate { legacyIDs.contains($0.legacyID) })))
                ?? context.all(ScheduleEvent.self).filter { legacyIDs.contains($0.legacyID) }
            w.logs = (try? context.fetch(FetchDescriptor<HabitLog>(predicate: #Predicate { legacyIDs.contains($0.legacyID) })))
                ?? context.all(HabitLog.self).filter { legacyIDs.contains($0.legacyID) }
        }
        let profileRefs = profileRefs(in: refs)
        if !profileRefs.isEmpty, let profile = context.all(Profile.self).sorted(by: { $0.createdAt < $1.createdAt }).first {
            w.profile = profile
            w.profileRefs = profileRefs
        }
        return w
    }

    /// 档案引用按字段合并成一项：before 取第一次改写前的内容，after 取最后写进去的内容。
    /// 旧版收录时，同一封里两条 profile 改同一字段会各记一项（后一项的 before 正是前一项的 after），合并后与现在的记法一致。
    private static func profileRefs(in refs: [Ref]) -> [Ref] {
        var merged: [Ref] = []
        for ref in refs where ref.t == "profile" {
            if let i = merged.firstIndex(where: { $0.r == ref.r }) { merged[i].after = ref.after } else { merged.append(ref) }
        }
        return merged
    }

    /// 档案字段收录之后被用户改过：现在的内容不再是传书写进去的那份
    private static func isEdited(_ ref: Ref, in profile: Profile?) -> Bool {
        (profile?[ref.r] ?? "") != (ref.after ?? "")
    }

    /// 撤销时一个档案字段怎么处理
    private enum FieldAction {
        /// 恢复成传书之前的内容
        case restore
        /// 收录后被用户改过（现在的内容不是这封写进去的那份）：默认保留
        case edited
        /// 之后又有没撤销的传书改写过这个字段（next 是紧接着的那封）：现在的内容以后来的为准，这次不动，也不算“你改过的”
        case superseded(next: CourierDelivery)
    }

    /// 这封传书改写的档案字段各怎么处理。预览与撤销共用这一套判断，提示与实际结果才一致。
    private static func profilePlan(_ delivery: CourierDelivery, _ w: Written, context: ModelContext) -> [(ref: Ref, action: FieldAction)] {
        guard let profile = w.profile, !w.profileRefs.isEmpty else { return [] }
        let received = delivery.receivedAt
        let later = (try? context.fetch(FetchDescriptor<CourierDelivery>(predicate: #Predicate { !$0.undone && $0.receivedAt > received },
                                                                         sortBy: [SortDescriptor(\.receivedAt)])))
            ?? context.all(CourierDelivery.self).filter { !$0.undone && $0.receivedAt > received }.sorted { $0.receivedAt < $1.receivedAt }
        let laterKeys = later.compactMap { next -> (next: CourierDelivery, keys: Set<String>)? in
            let keys = Set(refs(of: next).filter { $0.t == "profile" }.map(\.r))
            return keys.isEmpty ? nil : (next, keys)
        }
        return w.profileRefs.map { ref in
            if let next = laterKeys.first(where: { $0.keys.contains(ref.r) })?.next { return (ref, .superseded(next: next)) }
            return (ref, isEdited(ref, in: profile) ? .edited : .restore)
        }
    }

    /// 撤销的这封夹在中间、后一封直接写在它的内容之上（后一封记的“改写前”正是这封写进去的）：
    /// 把后一封的“改写前”接回这封之前的内容，以后撤销那封时恢复成最初的样子，而不是这封已经撤销的内容。
    /// 中间被用户改过的（“改写前”是用户写的）不接，撤销那封时照旧恢复成用户写的。
    private static func relink(_ next: CourierDelivery, over ref: Ref) {
        var nextRefs = refs(of: next)
        guard let i = nextRefs.firstIndex(where: { $0.t == "profile" && $0.r == ref.r }), (nextRefs[i].before ?? "") == (ref.after ?? "") else { return }
        nextRefs[i].before = ref.before
        if let json = try? String(data: JSONEncoder().encode(nextRefs), encoding: .utf8) { next.refsJSON = json }
    }

    /// 收录之后被用户改过：修改时间比收录时刻晚 2 秒以上（修行录条目被珍藏也算）
    private static func isEdited(_ updatedAt: Date, after delivery: CourierDelivery) -> Bool {
        updatedAt.timeIntervalSince(delivery.receivedAt) > editedAfter
    }

    private static func isEdited(_ entry: JournalEntry, after delivery: CourierDelivery) -> Bool {
        entry.pinned || isEdited(entry.updatedAt, after: delivery)
    }

    /// 撤销前预览：这封传书写入的记录里，现在还在的有几条（total），其中几条收录后被用户改过（edited，撤销时默认保留）。
    /// 已被用户删掉的记录不计入。账目“改过”指在账簿里确认过类别或备注。档案字段的细分见 undoPreviewDetail。
    static func undoPreview(_ delivery: CourierDelivery, context: ModelContext) -> (total: Int, edited: Int) {
        let preview = undoPreviewDetail(delivery, context: context)
        return (preview.total, preview.edited)
    }

    /// 撤销前预览，记录与档案字段分开计数（档案字段撤销时是恢复原内容，不是删除）
    static func undoPreviewDetail(_ delivery: CourierDelivery, context: ModelContext) -> CourierUndoPreview {
        guard !delivery.undone else { return CourierUndoPreview() }
        let w = written(by: delivery, context: context)
        var p = CourierUndoPreview()
        p.records = w.entries.count + w.events.count + w.logs.count
        p.editedRecords = w.entries.filter { isEdited($0, after: delivery) }.count
            + w.events.filter { isEdited($0.updatedAt, after: delivery) }.count
            + w.logs.filter { isEdited($0.updatedAt, after: delivery) }.count
        for field in profilePlan(delivery, w, context: context) {
            switch field.action {
            case .restore: p.fields += 1
            case .edited: p.fields += 1; p.editedFields += 1
            case .superseded: p.superseded += 1
            }
        }
        if !w.expenseIDs.isEmpty {
            if let rows = (try? FinanceService.load(context))?.transactions.filter({ w.expenseIDs.contains($0.id) }) {
                p.records += rows.count
                p.editedRecords += rows.filter { $0.revision > 0 }.count
            } else {
                p.records += w.expenseIDs.count
            }
        }
        // 新立的目标、新建的习惯（计入记录）与目标更新（单列）
        let gh = goalHabitPreview(delivery, refs: refs(of: delivery), context: context)
        p.records += gh.records
        p.editedRecords += gh.editedRecords
        p.goals = gh.goals
        p.editedGoals = gh.editedGoals
        p.notes = gh.notes
        return p
    }

    /// 整批撤销一次传书：删除它写入的记录，改写过的档案字段恢复成原内容。
    /// keepEdited 为真时，收录之后被用户改过的日记、日程、打卡、档案字段（以及在账簿里确认过的账目）保留不动；
    /// 为假时一并撤回——档案字段会换回传书之前的内容，用户后来写的会被覆盖。
    /// 之后又被别的传书改写过的档案字段，无论哪种都不动。
    /// 账本读写失败时什么都不动，返回 failure，传书保持“未撤销”以便重试。
    @discardableResult
    static func undo(_ delivery: CourierDelivery, context: ModelContext, refresh: Bool = true, keepEdited: Bool = true) -> CourierUndoReport {
        guard !delivery.undone else { return CourierUndoReport(removed: 0, keptEdited: 0, failure: "这封传书已经撤销过了") }
        let w = written(by: delivery, context: context)
        var removed = 0, kept = 0, restored = 0, superseded = 0, keptFields = 0
        // 先撤账目：失败就整体不动，保留“未撤销”状态以便重试
        if !w.expenseIDs.isEmpty {
            do {
                let rows = try FinanceService.load(context).transactions.filter { w.expenseIDs.contains($0.id) }
                let keep = Set(rows.filter { keepEdited && $0.revision > 0 }.map(\.id))
                let drop = Set(rows.map(\.id)).subtracting(keep)
                if !drop.isEmpty {
                    _ = try FinanceService.mutate(context) { $0.transactions.removeAll { drop.contains($0.id) } }
                }
                removed += drop.count
                kept += keep.count
            } catch {
                NSLog("APT 撤销传书失败（账本）：\(error)")
                return CourierUndoReport(removed: 0, keptEdited: 0,
                                         failure: "灵石账簿读写失败，这封传书没有撤销，任何记录都没有删除（\(error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "。. ")))）。可以稍后再试。")
            }
        }
        for entry in w.entries {
            if keepEdited, isEdited(entry, after: delivery) { kept += 1; continue }
            context.delete(entry)
            removed += 1
        }
        for event in w.events {
            if keepEdited, isEdited(event.updatedAt, after: delivery) { kept += 1; continue }
            context.delete(event)
            removed += 1
        }
        for log in w.logs {
            if keepEdited, isEdited(log.updatedAt, after: delivery) { kept += 1; continue }
            // 先从习惯上摘下来再删：与原来 log.habit?.logs?.removeAll { $0 === log } 结果相同，但不改写整个 habit.logs
            // （关系冷的时候那样要把这个习惯的打卡逐条补回来，每条约 0.2 秒），见 HabitActions.apply
            log.habit = nil
            context.delete(log)
            removed += 1
        }
        // 目标与新习惯：在打卡之后撤（新习惯的“别的打卡”只数不是本封写的）
        let gh = undoGoalHabit(delivery, refs: refs(of: delivery), context: context, keepEdited: keepEdited)
        removed += gh.removed
        kept += gh.kept
        // 档案字段恢复成改写前的内容（每个字段一项，同一封里先后改写同一字段时 before 就是最初的内容）
        if let profile = w.profile {
            for field in profilePlan(delivery, w, context: context) {
                switch field.action {
                case let .superseded(next):
                    relink(next, over: field.ref)
                    superseded += 1
                case .edited where keepEdited:
                    kept += 1
                    keptFields += 1
                case .edited, .restore:
                    profile[field.ref.r] = field.ref.before ?? ""
                    removed += 1
                    restored += 1
                }
            }
        }
        delivery.undone = true
        let report = CourierUndoReport(removed: removed, keptEdited: kept, failure: nil, restored: restored, superseded: superseded,
                                       restoredGoals: gh.restoredGoals, notes: gh.notes, keptFields: keptFields, keptGoals: gh.keptGoals)
        // 保留了改过的就在摘要末尾记一句：档案字段、目标与记录分开数（与撤销提示同一个说法，见 CourierUndoWording.summaryNote）
        if let note = CourierUndoWording.summaryNote(report.wording) { delivery.summary += "\n" + note }
        DataStore.save(context)
        if refresh { refreshSnapshotSoon(context: context) }
        return report
    }

    static func match(habit name: String, in habits: [Habit]) -> Habit? {
        matchIndex(name, titles: habits.map(\.title)).map { habits[$0] }
    }

    /// 按名称找习惯：先找完全相同的（不分大小写），再找唯一一个互相包含的。
    nonisolated static func matchIndex(_ name: String, titles: [String]) -> Int? {
        NameMatch.index(name, titles: titles)
    }

    // MARK: 文件

    /// 数量的写法：整数不带小数点（回执、给 AI 的说明共用）
    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    /// 文件大小统一按十进制 MB 写（上限 1,000,000 字节就是“1 MB”），免得出现“977 KB，上限 1000 KB”这种前后单位不一的话。
    /// 小数向上取到两位：刚超出上限的 1,000,001 字节写成 1.01 MB，而不是看上去没超的 1.00 MB。
    nonisolated private static func sizeText(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb.rounded() == mb ? "\(Int(mb)) MB" : String(format: "%.2f MB", (mb * 100).rounded(.up) / 100)
    }

    /// 把原件移到 processed / failed；移不走就原地改名为 .bad。两者都失败返回 false（绝不删除原件）。
    /// 先移原件、再写回执：原件已被别的进程收走时，不会留下一份误导人的回执。
    @discardableResult
    private static func move(_ url: URL, to folder: URL, stamp: String, note: String, noteExtension: String) -> Bool {
        let base = "\(stamp)-\(url.deletingPathExtension().lastPathComponent)"
        let target = folder.appendingPathComponent(base + ".json")
        try? FileManager.default.removeItem(at: target)
        guard (try? FileManager.default.moveItem(at: url, to: target)) != nil
                || (try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("bad"))) != nil else { return false }
        try? note.write(to: folder.appendingPathComponent(base + "." + noteExtension), atomically: true, encoding: .utf8)
        return true
    }

    /// 清理 processed/、failed/ 里超过 90 天的归档（按文件名开头的收录时间判断；认不出时间的文件不动）。
    static func cleanArchives(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(archiveDays) * 86_400)
        for folder in [processed, failed] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                guard name.count > 16, name.dropFirst(15).first == "-", let date = DateText.date(fileStamp: String(name.prefix(15))), date < cutoff else { continue }
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }

    // MARK: 命令行投递

    /// `APT --add '<json>'` / `APT --add 文件.json` / `APT --add -`（读标准输入）：校验后投进收件箱。
    /// 退出码：0 已投递（其中打卡的习惯名 / 单位对不上的几条会被应用退回，打印“提醒：第 N 条不会收录：…”，其余照收）；
    /// 1 格式错误、找不到文件或读写失败；2 与应用里现有的习惯或目标对不上（找不到、重名、能对上多个），或整封全是对不上的打卡——这时不投。
    nonisolated static func commandLineAdd(_ argument: String) -> Int32 {
        let data: Data
        let path = (argument as NSString).expandingTildeInPath
        if argument == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else if FileManager.default.fileExists(atPath: path) {
            guard let fileData = FileManager.default.contents(atPath: path) else { print("读不了文件：\(argument)"); return 1 }
            data = fileData
        } else if looksLikePath(argument) {
            print("找不到文件：\(argument)")
            return 1
        } else {
            data = Data(argument.utf8)
        }
        guard data.count <= maxFileSize else { print("投递失败：内容太大（约 \(sizeText(data.count))，上限 \(sizeText(maxFileSize))）"); return 1 }
        let state = courierStateFile()
        // 按应用写出的时区算“今天”（读不到就用本进程的时区，并把“不能为未来打卡”放宽一天，最终由应用收录时把关）
        let zone = state?.timeZone ?? timeZone
        let today = LocalDay(date: Date(), timeZone: zone)
        let latest = state?.timeZone == nil ? today.adding(days: 1) : today
        do {
            let payload = try CourierParser.parse(data, relativeTo: today, latest: latest)
            // 先按应用上次写出的小抄预检（打卡的习惯、新习惯重名、要更新的目标）：对不上就不投（应用收录时也会整份拒收，报错原文相同）
            var rosterNotices: [String] = []
            var skippedNotices: [String] = []
            if let roster = cliRoster() {
                do {
                    // 与应用收录同一套按条退回：对不上的打卡只提醒“不会收录”，照投；整封全是这类才不投
                    let resolution = try roster.resolve(payload.items, units: payload.checkinUnits, partial: true)
                    rosterNotices = resolution.notices
                    skippedNotices = resolution.skipped.keys.sorted().compactMap { i in
                        resolution.skipped[i].map { "第 \(i + 1) 条不会收录：\($0.receipt)" }
                    }
                } catch {
                    print("投递失败：\(error.localizedDescription)")
                    return 2
                }
            }
            // 原样写入，不改写相对日期：应用收录时按文件写入时刻和应用的时区换算，结果相同，也不受这个 shell 的 TZ 影响
            let folder = DataStore.directory.appendingPathComponent("AI/inbox", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "cli-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
            let temp = folder.appendingPathComponent(name + ".tmp")
            try data.write(to: temp)
            try FileManager.default.moveItem(at: temp, to: folder.appendingPathComponent(name))
            print("已投递 \(payload.items.count) 条 → \(folder.path)/\(name)")
            payload.items.forEach { print("  · " + $0.summary) }
            (skippedNotices + payload.warnings + rosterNotices).forEach { print("  提醒：" + $0) }
            print("应用运行时约 3 秒内收录；未运行则下次打开时收录。回执在 AI/processed/（或 AI/failed/），文件名形如“收录时间-\(name.dropLast(5)).result.txt”。")
            return 0
        } catch {
            print("投递失败：\(error.localizedDescription)")
            return 1
        }
    }

    /// 参数像是文件路径（但文件不存在）：报“找不到文件”，而不是“不是合法的 JSON”
    nonisolated private static func looksLikePath(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{") || t.hasPrefix("[") { return false }
        return t.hasPrefix("/") || t.hasPrefix("~") || t.hasPrefix("./") || t.hasPrefix("../") || t.lowercased().hasSuffix(".json")
    }

    /// 应用上次写出的小抄里的时区（旧版小抄没有这一项时为 nil）；习惯、目标的核对见 cliRoster（CourierGoalHabitStore.swift）
    nonisolated private static func courierStateFile() -> (habits: [String]?, timeZone: TimeZone?)? {
        guard let data = FileManager.default.contents(atPath: stateURL.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["habits"] as? [String], (object["timeZone"] as? String).flatMap(TimeZone.init(identifier:)))
    }
}
