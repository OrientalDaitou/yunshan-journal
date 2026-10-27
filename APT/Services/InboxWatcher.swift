import AppKit
import SwiftData

/// 飞剑传书巡查的“门铃”（#21 能耗）：收件箱里一有文件进出、数据库一保存、应用回到前台，就叫醒巡查当场看一眼；
/// 平时巡查按 CourierPace 的节奏睡（前台 3 秒；不在前台、门铃装好了就 60 秒兜底），后台静置时不再每 3 秒醒一次。
///
/// - 收件箱：`DispatchSource.makeFileSystemObjectSource` 盯着 `AI/inbox` 这个目录（投进、改名、移走都会响）；
///   目录被删掉重建、换了数据目录时，巡查每轮调 `watch` 会认出来并重新盯上。
/// - 保存：`ModelContext.didSave`。顺带记下作息块最近一次随保存改动的时刻（作息块没有修改时间，快照指纹靠它认出原地修改）。
/// - 回到前台：切回每 3 秒的节奏。
///
/// 只由 CourierService.run 建（离屏渲染、命令行、自检都不跑巡查，也就不监视）；自检另用临时目录单独测它。
@MainActor
final class InboxWatcher {
    /// 作息块最近一次随保存改动（增、删、原地修改）的时刻（1970 起的秒数；没见过就是 0）：快照指纹里作息那一段用它
    private(set) static var routineSavedAt: Double = 0
    /// 正盯着目录的门铃个数（自检看：离屏、命令行、自检模式下应为 0）
    private(set) static var openSources = 0

    private var source: DispatchSourceFileSystemObject?
    private var watched: (path: String, device: dev_t, node: ino_t)?
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var sleeper: Task<Void, Never>?
    private var rang = false
    private var lastRound = Date.distantPast
    /// 响过几次（自检看）
    private(set) var rings = 0

    /// 目录监视开着没有：开不起来时巡查在后台退回每 10 秒
    var watching: Bool { source != nil }

    /// 应用在不在前台（主窗口、随手记浮窗、菜单栏小窗在前都算）
    static var appInFront: Bool { NSApp?.isActive ?? true }

    /// observing：要不要听保存与回到前台（自检只测目录时传 false）
    init(observing: Bool = true) {
        guard observing else { return }
        listen(ModelContext.didSave) { note in
            let info = note.userInfo ?? [:]
            let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
            let touched = info[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue] != nil
                || keys.contains { key in ((info[key.rawValue] as? [PersistentIdentifier]) ?? []).contains { $0.entityName == "RoutineBlock" } }
            return { watcher in
                if touched { Self.routineSavedAt = max(Date().timeIntervalSince1970, Self.routineSavedAt + 0.001) }
                watcher.ring()
            }
        }
        listen(NSApplication.didBecomeActiveNotification) { _ in { $0.ring() } }
    }

    /// 通知在哪个线程发出就在哪儿先把要的东西取出来（userInfo 不跨线程），再回主线程办
    private func listen(_ name: Notification.Name, _ take: @escaping (Notification) -> (@MainActor (InboxWatcher) -> Void)) {
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
            let act = take(note)
            if Thread.isMainThread {
                MainActor.assumeIsolated { if let self { act(self) } }
            } else {
                Task { @MainActor in if let self { act(self) } }
            }
        }
        tokens.append((.default, token))
    }

    /// 盯着这个目录；已经盯着同一个（同路径、同一个目录节点）就什么都不做。目录不在时返回 false（巡查会先建好再来）
    @discardableResult
    func watch(_ directory: URL) -> Bool {
        var info = stat()
        guard stat(directory.path, &info) == 0 else {
            closeSource()
            return false
        }
        if source != nil, let watched, watched.path == directory.path, watched.device == info.st_dev, watched.node == info.st_ino { return true }
        closeSource()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.ring() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        watched = (directory.path, info.st_dev, info.st_ino)
        Self.openSources += 1
        return true
    }

    private func closeSource() {
        guard let source else { return }
        source.cancel()
        self.source = nil
        watched = nil
        Self.openSources -= 1
    }

    /// 不再盯目录、不再听通知（巡查结束时调）
    func stop() {
        closeSource()
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        sleeper?.cancel()
    }

    /// 叫醒巡查：正睡着就当场醒；正在巡查的这一轮里响的，下一轮不睡（隔 minimumGap）直接再看
    func ring() {
        rings += 1
        rang = true
        sleeper?.cancel()
    }

    /// 睡到点或被叫醒。被叫醒时离上一轮不到 minimumGap 就补足：一连串保存、一次投几个文件只多看一次
    func wait(_ pace: CourierPace.Wait) async {
        if !rang {
            let nap = Task { _ = try? await Task.sleep(for: .seconds(pace.seconds), tolerance: .seconds(pace.tolerance)) }
            sleeper = nap
            await withTaskCancellationHandler { await nap.value } onCancel: { nap.cancel() }
            sleeper = nil
        }
        if rang {
            let gap = CourierPace.gapLeft(since: lastRound, now: Date())
            if gap > 0 { try? await Task.sleep(for: .seconds(gap)) }
        }
        rang = false
        lastRound = Date()
    }
}

@MainActor
extension CourierService {
    /// 收件箱里还在等写稳（写入不满 1 秒）的传书里，写得最早那封已过了多少秒；没有就是 nil。
    /// 门铃一响，文件往往还没写稳：巡查按它算出再等多久（CourierPace.next），不必干等一整轮
    static func settlingAge(in directory: URL? = nil, now: Date = Date()) -> Double? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory ?? inbox, includingPropertiesForKeys: keys)) ?? []
        return files.compactMap { url -> Double? in
            guard url.pathExtension.lowercased() == "json", !url.lastPathComponent.hasPrefix(".") else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, let written = values?.contentModificationDate else { return nil }
            let age = now.timeIntervalSince(written)
            return age >= 0 && age < CourierPace.settle ? age : nil
        }
        .max()
    }
}

/// 数据“停稳”的判定（#21）：快照指纹最近一次变了之后，满约 3 秒没再变才重建快照。
///
/// 按钟点算，不按“相邻两轮指纹一样”：门铃（保存、回到前台）能把两轮隔得只有 0.5 秒，
/// 改一块作息、紧接着点一下不进指纹的缓冲步进器（或切走再切回），按轮次算就会在用户还在点的时候当场重建（2 年数据约 0.2 秒、5 年约 0.45 秒的一顿）。
/// 现在不管被哪种铃叫醒，都是改动后约 3 秒才重建，与以前固定 3 秒一轮时同一节奏。
struct SnapshotCalm {
    /// 指纹满这么久没变才算停稳（与前台一轮同长）
    static let quiet = CourierPace.foreground.seconds
    /// 判定时留的余量：掐着 3 秒醒来时差几毫秒，不必再多等一轮
    static let margin = 0.1

    private(set) var fingerprint: String
    /// 最近一次看到指纹变了的时刻。起步时是很久以前：起步后第一轮指纹没变就算停稳（与以前一样）
    private(set) var changedAt: Date

    init(_ fingerprint: String, changedAt: Date = .distantPast) {
        self.fingerprint = fingerprint
        self.changedAt = changedAt
    }

    /// 记下这一轮看到的指纹，返回数据停稳了没有：变了就从现在重新计时；钟面倒拨（变的时刻在未来）算停稳，免得一直不重建
    mutating func settled(_ current: String, now: Date) -> Bool {
        if current != fingerprint {
            fingerprint = current
            changedAt = now
            return false
        }
        let still = now.timeIntervalSince(changedAt)
        return still >= Self.quiet - Self.margin || still < 0
    }

    /// 还没停稳时的下一觉：取“离改动满 3 秒还剩的时间”和常规节奏中较短的那个。
    /// 被门铃中途叫醒看过一眼，也照样在改动后约 3 秒回来确认，不会多等一整轮
    func pace(_ wait: CourierPace.Wait, now: Date) -> CourierPace.Wait {
        let still = now.timeIntervalSince(changedAt)
        guard still >= 0 else { return wait }
        let rest = Self.quiet - still
        guard rest > 0, rest < wait.seconds else { return wait }
        return CourierPace.Wait(seconds: rest, tolerance: min(wait.tolerance, rest / 3))
    }
}
