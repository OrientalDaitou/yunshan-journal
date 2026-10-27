import SwiftUI
import AppKit
import Observation

/// 统一管理“+修为”飘字与“境界突破”动画。动效关闭或系统减少动态效果时只做静态提示。
@Observable
final class EffectsCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var color: Color
        /// 文字左边的小图标（成功的提示是玉色小勾）；nil 不显示
        var icon: String? = nil
        /// 修为飘字用宋体标题字号；一句话的提示用正文字号，轻一些
        var prominent = false
        /// 小图标的颜色；nil 时用玉色（成功的小勾）。得印时是朱砂小印
        var iconColor: Color? = nil
    }

    struct Seal: Identifiable, Equatable {
        let id = UUID()
        var text: String
        /// 落印处（窗口坐标，通常是刚点的“落笔入卷”按钮）；nil 时盖在窗口正中
        var anchor: CGRect? = nil
        /// 这方印由主窗口的仪式图层（Core Animation）来画：SwiftUI 的 SealStampOverlay 就不再画一遍
        var drawnByRitualHost = false
    }

    struct CourierNotice: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var detail: String
        var lines: [String]
        var deliveryID: String?
        var failed: Bool
        /// 是否先有一柄飞剑划入（撤销结果等提示不飞剑）
        var flies: Bool = true
        /// 笺头的图标；nil 时按成败用纸飞机 / 警示
        var symbol: String? = nil
        /// “查看”去哪一页（AppSection.rawValue）：整封只有目标时去修士名帖、只有新习惯和打卡时去每日功课；nil 时去修行录
        var openPage: String? = nil
    }

    var toasts: [Toast] = []
    var breakthrough: String?
    /// 突破到的境界序号（用来取徽记）：自定义境界名时按名字找不到默认徽记，按序号取才对；nil 时按名字找
    var breakthroughIndex: Int?
    var seal: Seal?
    var courier: CourierNotice?
    var motionEnabled = true
    /// 鼠标停在传书笺上：暂停自动收起
    var courierHeld = false

    /// 当前屏上挂了 `.sealAnchor()` 的按钮位置（窗口坐标）。滚动时会一直更新，不参与界面刷新
    @ObservationIgnored var sealAnchor: (id: UUID, rect: CGRect)?

    // —— 关键时刻的仪式（落笔入卷、功课圆满，见 Theme/RitualOverlay.swift 与 EffectsCenter+Ritual.swift）——
    /// 主窗口的仪式图层（RitualHostView）：触发时直接同步调用它，动画当场提交到渲染进程，不等界面刷新。主窗口关着时为 nil
    @ObservationIgnored weak var ritualPlayer: RitualPlayer?
    /// 挂了 `.ritualAnchor()` 的界面元素位置（窗口坐标）：落笔框、侧栏“修行录”、境界徽记。滚动时一直更新，不参与界面刷新
    @ObservationIgnored var ritualAnchors: [RitualAnchor: (id: UUID, rect: CGRect)] = [:]
    /// 最近一次交给图层播放的仪式（自检用）
    @ObservationIgnored var lastRitual: Ritual?
    /// 今天已经播过“功课圆满”：只记在内存里（不写偏好，自检不会污染正式偏好）；重启应用后当天可能再播一次
    @ObservationIgnored var perfectCelebratedDay: LocalDay?

    /// 落笔入卷：盖一方朱印。anchor 为落印处（窗口坐标）；不给时用屏上挂了 `.sealAnchor()` 的按钮，都没有时盖在窗口正中。
    /// inscription 是刚入卷的正文：动效开着、主窗口在时，另放“墨迹晕开、纸卷合拢、飞入修行录”的仪式（kind 决定纸笺细边与尾迹的颜色）
    @MainActor
    func stamp(_ text: String = "入卷", at anchor: CGRect? = nil, inscription: String? = nil, kind: JournalKind? = nil) {
        var seal = Seal(text: text, anchor: anchor ?? sealAnchor?.rect)
        // 动效开、仪式图层在：朱印改由 Core Animation 画（外观、时长与 SwiftUI 版相同），入卷后主线程忙着刷新时也不顿一下
        let player = motionEnabled ? ritualPlayer : nil
        seal.drawnByRitualHost = player != nil
        self.seal = seal
        if let player {
            player.playSeal(seal)
            if let inscription {
                let ritual = Ritual.inscription(Inscription(preview: RitualRules.inscriptionPreview(inscription), kind: kind,
                                                            slip: ritualAnchors[.composer]?.rect, seal: seal.anchor,
                                                            target: ritualAnchors[.chronicleNav]?.rect))
                lastRitual = ritual
                player.play(ritual)
            }
        }
        Task { @MainActor in
            // 落下、印痕停约 1 秒，再淡出
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self.seal?.id == seal.id { self.seal = nil }
        }
    }

    /// 打卡之后（HabitActions.apply）：今天由“未圆满”变为“圆满”、今天还没播过时，播“功课圆满”——
    /// 灵光从四方汇入侧栏的境界徽记，徽记旁展开一道金色符箓。关动效或主窗口不在时只飘一行金字“功课圆满”。
    /// 有弹窗挂着时（例如数量输入里点了“确定”）最多等 3 秒，还没关就改为飘字
    @MainActor
    func perfectDayChanged(day: LocalDay, wasPerfect: Bool, isPerfect: Bool) {
        guard RitualRules.shouldCelebratePerfectDay(day: day, today: .today(), wasPerfect: wasPerfect, isPerfect: isPerfect,
                                                    celebrated: perfectCelebratedDay) else { return }
        perfectCelebratedDay = day
        guard motionEnabled, ritualPlayer != nil else { return perfectDayToast() }
        let source = ritualClickPoint()
        guard Self.sheetOpen else { return playConsummation(source: source) }
        Task { @MainActor in
            var waited = 0.0
            while Self.sheetOpen, waited < 3 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                waited += 0.2
            }
            if Self.sheetOpen || !self.motionEnabled || self.ritualPlayer == nil {
                self.perfectDayToast()
            } else {
                self.playConsummation(source: source)
            }
        }
    }

    /// 关动效、主窗口不在、弹窗迟迟不关时：只飘一行金色的“功课圆满”（toast 自己会向读屏播报）
    @MainActor
    private func perfectDayToast() {
        toast(Toast(text: "功课圆满", color: Theme.precious, prominent: true), seconds: 2.0)
    }

    /// 单封传书到达：笺头图标与“查看”去哪一页按全部摘要行定（不只是显示的前 5 行）——整封只有目标是旗、去修士名帖；
    /// 只有新习惯和打卡是叶、去每日功课；其余仍是纸飞机、去修行录。
    /// 部分收录（有打卡按条退回）时副标题接“· 1 条未收”，退回的行留在最后（不折进“另有 N 条”），笺上用警示色
    @MainActor
    func courierArrived(_ delivery: CourierDelivery) {
        let lines = delivery.summary.split(separator: "\n").map(String.init)
        show(CourierNotice(title: "飞剑传书",
                           detail: CourierLineDecor.cardDetail(from: delivery.from, itemCount: delivery.itemCount, lines: lines),
                           lines: CourierLineDecor.cardLines(lines),
                           deliveryID: delivery.deliveryID, failed: false,
                           symbol: CourierLineDecor.symbol(lines), openPage: CourierLineDecor.page(lines)))
    }

    /// 一轮巡查的结果合并成一张传书笺：只有一封时可直接撤销
    @MainActor
    func courierBatch(deliveries: [CourierDelivery], failures: [(file: String, message: String)]) {
        if deliveries.count == 1, failures.isEmpty { return courierArrived(deliveries[0]) }
        if deliveries.isEmpty, failures.count == 1 { return courierFailed(file: failures[0].file, message: failures[0].message) }
        // 重复投递被跳过的也在 failures 里，但原件在 AI/processed/，单独计数
        let skipped = failures.filter { Self.isDuplicateSkip($0.message) }
        let rejected = failures.filter { !Self.isDuplicateSkip($0.message) }
        // 每封一行：部分收录的那封冒号前注“· 1 条未收”，副标题合计；整封没收录的那行（“未收录 · …”）笺上整行警示色
        var lines = deliveries.map { CourierLineDecor.batchLine(from: $0.from, itemCount: $0.itemCount, summary: $0.summary) }
        lines += rejected.map { CourierLineDecor.rejectedLine(file: $0.file, message: $0.message) }
        lines += skipped.map { "已跳过 · \($0.file)：\($0.message)" }
        let items = deliveries.reduce(0) { $0 + $1.itemCount }
        let unreceived = deliveries.reduce(0) { $0 + CourierLineDecor.skippedCount(summary: $1.summary) }
        var detail = "收录 \(items) 条"
        if unreceived > 0 { detail += " · \(unreceived) 条未收" }
        if !rejected.isEmpty { detail += " · \(rejected.count) 封未收录（原件在 AI/failed/）" }
        if !skipped.isEmpty { detail += " · \(skipped.count) 封重复已跳过" }
        if deliveries.count > 1 { detail += " · 可在修行录逐封撤销" }
        let title = !deliveries.isEmpty ? "飞剑传书 · \(deliveries.count) 封" : (rejected.isEmpty ? "传书已跳过" : "传书未能收录")
        show(CourierNotice(title: title, detail: detail,
                           lines: Array(lines.prefix(6)), deliveryID: deliveries.count == 1 ? deliveries[0].deliveryID : nil,
                           failed: deliveries.isEmpty && !rejected.isEmpty,
                           flies: !deliveries.isEmpty, symbol: deliveries.isEmpty && rejected.isEmpty ? "doc.on.doc" : nil))
    }

    @MainActor
    func courierFailed(file: String, message: String) {
        if Self.isDuplicateSkip(message) {
            // 内容与已收录的相同，这次没有写入；原件在 AI/processed/，不是出错
            show(CourierNotice(title: "传书已跳过", detail: file, lines: [message], deliveryID: nil, failed: false,
                               flies: false, symbol: "doc.on.doc"))
            return
        }
        show(CourierNotice(title: "传书未能收录", detail: file, lines: [message, "原件在 AI/failed/（或收件箱里改名为 .bad）"], deliveryID: nil, failed: true))
    }

    /// CourierService 把“重复投递被跳过”的传书也放进 failures，message 以“重复投递”开头
    private static func isDuplicateSkip(_ message: String) -> Bool { message.hasPrefix("重复投递") }

    /// 撤销一封传书之后的结果提示（由 RootView 调用）：删了几条记录、恢复了几个档案字段和目标（不是删除，分开说）、
    /// 保留了哪些收录后改过的，再接第一条保留原因；失败时给出原因。说法与修行录左栏的飞剑传书卡相同（CourierUndoWording）
    @MainActor
    func courierUndoResult(_ report: CourierUndoReport) {
        if let failure = report.failure {
            show(CourierNotice(title: "撤销未成", detail: "这封传书写入的记录都没有动", lines: [failure],
                               deliveryID: nil, failed: true, flies: false))
            return
        }
        let outcome = report.wording
        show(CourierNotice(title: "已撤销此书", detail: CourierUndoWording.resultDetail(outcome),
                           lines: CourierUndoWording.resultLines(outcome), deliveryID: nil, failed: false, flies: false,
                           symbol: "arrow.uturn.backward"))
    }

    /// 同上，只给几个数（removed 含 restored，与 CourierUndoReport 同一记法；自检用）
    @MainActor
    func courierUndoResult(removed: Int, keptEdited: Int, failure: String?, restored: Int = 0, superseded: Int = 0) {
        courierUndoResult(CourierUndoReport(removed: removed, keptEdited: keptEdited, failure: failure, restored: restored, superseded: superseded))
    }

    /// 传书笺停留约 12 秒后自动收起；只在应用处于前台、鼠标不在笺上时计时。
    /// AI 传书多在窗口不在前台时到达，等用户切回来笺还在，倒计时从那时才开始。
    @MainActor
    private func show(_ notice: CourierNotice) {
        courier = notice
        courierHeld = false
        AccessibilityNotification.Announcement("\(notice.title)：\(notice.detail)").post()
        Task { @MainActor in
            var remaining: Double = 12
            while remaining > 0 {
                guard self.courier?.id == notice.id else { return }
                if !Self.appActive {
                    await Self.untilAppActive()
                    continue
                }
                let step = min(0.5, remaining)
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                if self.courierHeld {
                    remaining = max(remaining, 4)   // 移开鼠标后至少再停 4 秒
                } else if Self.appActive {
                    remaining -= step
                }
            }
            if self.courier?.id == notice.id { self.courier = nil }
        }
    }

    @MainActor
    private static var appActive: Bool { NSApp?.isActive ?? true }

    /// 等到应用回到前台
    @MainActor
    private static func untilAppActive() async {
        guard !appActive else { return }
        let waiter = ActivationWaiter()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.continuation = continuation
            waiter.token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                  object: nil, queue: .main) { _ in waiter.finish() }
        }
    }

    @MainActor
    func gain(_ amount: Int) {
        guard amount != 0 else { return }
        let text = amount > 0 ? "+\(amount) 修为" : "\(amount) 修为"
        toast(Toast(text: text, color: amount > 0 ? Theme.gold : Theme.inkSoft, prominent: true), seconds: 1.6)
    }

    /// 一行不带修为的小提示（例如“未达标，请填写实际数量”），停留稍久一些。
    /// 成功的反馈（已复制、已保存、已导出、已备份……）传 icon: "checkmark.circle"，左边带一个玉色小勾。
    @MainActor
    func hint(_ text: String, icon: String? = nil) {
        toast(Toast(text: text, color: Theme.inkSoft, icon: icon), seconds: 2.6)
    }

    /// 印谱新得一枚（RootView 保存后约 1 秒看一眼，见 MilestoneWatcher）：一行金字“得印 · 七日不辍：连续落笔七日”，
    /// 左边一枚朱砂小印；停得比一般提示久一些。名帖印谱里那枚下次出现时另盖印亮起一次（SealBook）。
    /// 得的是“功成”、而“所向功成 · 目标名”正飘着（同一次保存）：并成一句，不再叠一行说同一件事
    @MainActor
    func sealEarned(_ milestone: Milestone) {
        if milestone == .goalDone, let showing = goalToast, toasts.contains(where: { $0.id == showing.id }) {
            return mergeGoalToast(into: showing.id, title: showing.title)
        }
        let toast = Toast(text: milestone.toast, color: Theme.precious, icon: "seal.fill", iconColor: Self.sealInk)
        if milestone == .goalDone { goalSealToast = toast.id }
        self.toast(toast, seconds: 3.4)
    }

    /// 目标功成（名帖里把进度拉到 100%、或状态改成“已完成”保存时）：飘一行宋体金字“所向功成 · 完成学位论文初稿”。
    /// 那一行掠过的金光与“功成”朱印由名帖自己放（关动效时只有这行字）。
    /// 这一次同时得了“功成”印、那句“得印 · 所向功成：…”正飘着：并成一句“所向功成 · 目标名 · 得「功成」印”
    @MainActor
    func goalAchieved(_ title: String) {
        if let id = goalSealToast, toasts.contains(where: { $0.id == id }) {
            return mergeGoalToast(into: id, title: title)
        }
        let toast = Toast(text: GoalListRules.achievedToast(title), color: Theme.precious, icon: "flag.checkered", prominent: true, iconColor: Theme.precious)
        goalToast = (toast.id, title)
        self.toast(toast, seconds: 2.8)
    }

    /// 正飘着的“所向功成 · 目标名”（随后得“功成”印时并进这一句）
    @ObservationIgnored private var goalToast: (id: UUID, title: String)?
    /// 正飘着的“得印 · 所向功成：第一个目标达成”（随后飘目标名时并进这一句）
    @ObservationIgnored private var goalSealToast: UUID?
    /// 每条飘字收起的时刻：并句后重新计时，旧的计时到点不收
    @ObservationIgnored private var toastDeadlines: [UUID: Date] = [:]

    /// 朱砂印泥（与印谱、落笔入卷的朱印同色）
    private static let sealInk = Color(red: 0.70, green: 0.20, blue: 0.16)

    /// 把“所向功成 · 目标名”与“得印 · 所向功成”并成正飘着的那一行：原地换字（不另起一行、不叠放），朱砂小印打头，从此刻起再停 3.4 秒
    @MainActor
    private func mergeGoalToast(into id: UUID, title: String) {
        goalToast = nil
        goalSealToast = nil
        guard let index = toasts.firstIndex(where: { $0.id == id }) else { return }
        toasts[index].text = GoalListRules.achievedToast(title, sealEarned: true)
        toasts[index].color = Theme.precious
        toasts[index].icon = "seal.fill"
        toasts[index].iconColor = Self.sealInk
        toasts[index].prominent = true
        AccessibilityNotification.Announcement(toasts[index].text).post()
        scheduleRemoval(id, seconds: 3.4)
    }

    @MainActor
    private func toast(_ toast: Toast, seconds: Double) {
        let text = toast.text
        toasts.append(toast)
        AccessibilityNotification.Announcement(text).post()
        scheduleRemoval(toast.id, seconds: seconds)
    }

    @MainActor
    private func scheduleRemoval(_ id: UUID, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        toastDeadlines[id] = deadline
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            // 期间并过句、重新计时的，等新的那次到点再收
            guard self.toastDeadlines[id] == deadline else { return }
            self.toastDeadlines[id] = nil
            self.toasts.removeAll { $0.id == id }
        }
    }

    @MainActor
    func celebrate(realm: String) {
        celebrate(realm: realm, index: nil)
    }

    /// 境界突破：index 是新境界的序号（徽记按序号取）；为 nil 时按默认境界名找徽记。
    /// 有弹窗开着（例如正在编辑习惯时飞剑传书让修为越过门槛）先不播：渡劫画面会被弹窗挡住，
    /// 按 Esc 关掉的是弹窗（丢掉未保存的修改），点击也到不了渡劫画面。等弹窗都关了再播，5.5 秒的自动收起从那时算起。
    @MainActor
    func celebrate(realm: String, index: Int?) {
        guard Self.sheetOpen else {
            pendingBreakthrough = nil   // 直接播最新的一境；还在等弹窗的旧一境不再补播
            return startBreakthrough(realm: realm, index: index)
        }
        let waiting = pendingBreakthrough != nil
        pendingBreakthrough = (realm, index)   // 等待期间又升了一境：只播最新的
        guard !waiting else { return }
        Task { @MainActor in
            while Self.sheetOpen {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            guard let next = self.pendingBreakthrough else { return }
            self.pendingBreakthrough = nil
            self.startBreakthrough(realm: next.realm, index: next.index)
        }
    }

    /// 等弹窗关闭后再播的渡劫
    @ObservationIgnored private var pendingBreakthrough: (realm: String, index: Int?)?

    @MainActor
    private func startBreakthrough(realm: String, index: Int?) {
        // 渡劫一来，正在放的落笔 / 圆满仪式 0.12 秒内淡掉，不和天雷抢画面
        ritualPlayer?.cancelAll()
        breakthroughIndex = index
        breakthrough = realm
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_500_000_000)
            if self.breakthrough == realm { self.breakthrough = nil }
        }
    }

    /// 是否有窗口正挂着弹窗（.sheet、提示框、存取面板都是挂在窗口上的弹窗；应用不在前台时也照样判断）
    @MainActor
    private static var sheetOpen: Bool {
        NSApp?.windows.contains { $0.isVisible && $0.attachedSheet != nil } ?? false
    }

    /// 渡劫画面用的徽记序号：优先用 celebrate 传入的序号，没有时按默认境界名找，再找不到用最高一档
    func breakthroughEmblemIndex(for realm: String) -> Int {
        breakthroughIndex ?? CultivationConfig.defaultRealms.firstIndex(of: realm) ?? CultivationConfig.defaultRealms.count - 1
    }
}

/// 等一次“应用回到前台”：只恢复一次，并注销观察者（全程在主线程）
private final class ActivationWaiter: @unchecked Sendable {
    var token: NSObjectProtocol?
    var continuation: CheckedContinuation<Void, Never>?

    func finish() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        continuation?.resume()
        continuation = nil
    }
}

struct XPToastOverlay: View {
    @Environment(EffectsCenter.self) private var effects

    var body: some View {
        VStack(spacing: 6) {
            ForEach(effects.toasts) { toast in
                FloatingToast(toast: toast, animated: effects.motionEnabled)
            }
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}

private struct FloatingToast: View {
    var toast: EffectsCenter.Toast
    var animated: Bool
    @State private var risen = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon = toast.icon {
                Image(systemName: icon).foregroundStyle(toast.iconColor ?? Theme.positive).accessibilityHidden(true)
            }
            Text(toast.text)
        }
            .font(toast.prominent ? .ysHeading : .ysBody)
            .foregroundStyle(toast.color)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Theme.card.opacity(0.9), in: Capsule())
            .overlay(Capsule().strokeBorder(toast.color.opacity(0.4)))
            .shadow(color: toast.color.opacity(0.35), radius: risen ? 12 : 2)
            .offset(y: animated ? (risen ? -10 : 12) : 0)
            .opacity(risen ? 1 : 0)
            .onAppear {
                withAnimation(animated ? Motion.standard : .linear(duration: 0.1)) { risen = true }
            }
    }
}

/// 境界徽记：进度环 + 缓慢流转的灵光。
struct RealmBadge: View {
    var state: CultivationState
    var size: CGFloat = 64
    var animated: Bool

    static let emblems = ["lianqi", "zhuji", "jindan", "yuanying", "huashen", "lianxu", "heti", "dacheng", "dujie"]
    /// 境界徽记（九枚一套，超出九境时用最后一枚）
    static func emblem(for index: Int) -> String {
        let i = max(0, min(emblems.count - 1, index))
        return "yunshan-realm-0\(i + 1)-\(emblems[i])"
    }

    var body: some View {
        let emblem = Self.emblem(for: state.realmIndex)
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.gold.opacity(0.3), .clear], center: .center, startRadius: 0, endRadius: size * 0.75))
                .scaleEffect(1.12)
            if Scenery.image(emblem) != nil {
                SceneryImage(name: emblem)
                    .frame(width: size * 1.02, height: size * 1.02)
                    .shadow(color: Theme.gold.opacity(0.25), radius: size * 0.08)
            } else {
                Circle().stroke(Theme.line, lineWidth: size * 0.06)
                Text(String(state.realmName.prefix(1)))
                    .font(Theme.songti(size * 0.43, .bold))
                    .foregroundStyle(Theme.ink)
            }
            // 修为进度：徽记外一圈细金线
            Circle()
                .stroke(Theme.line.opacity(0.6), lineWidth: max(2, size * 0.035))
                .padding(-size * 0.09)
            Circle()
                .trim(from: 0, to: max(0.02, state.progress))
                .stroke(LinearGradient(colors: [Theme.jade, Theme.gold], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: max(2, size * 0.035), lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(-size * 0.09)
                .animation(animated ? Motion.gentle : nil, value: state.progress)
        }
        .frame(width: size, height: size)
        .help("\(state.title) · 修为 \(state.totalXP)")
    }
}

/// 打卡按钮：完成时有一次灵光迸发。
/// 迸发等这次点击真的打上卡（done 由未完成变为完成）才放：数量未达标时点击只飘提示或改为弹出数量输入，不会误放。
struct CheckInButton: View {
    var done: Bool
    var size: CGFloat = 26
    var animated: Bool
    /// 键盘打卡（功课页按空格）：换成新的值时当作点了一下（迸发照放）
    var keyPress: UUID? = nil
    var action: () -> Void
    @State private var showBurst = false
    @State private var burst = false
    /// 最近一次在“未完成”时点击的时刻：约 1 秒内 done 变为完成才算这次点击打上的卡
    @State private var tappedAt: Date?

    var body: some View {
        Button(action: press) {
            ZStack {
                if showBurst {
                    Circle()
                        .strokeBorder(Theme.gold, lineWidth: 2)
                        .scaleEffect(burst ? 1.9 : 1)
                        .opacity(burst ? 0 : 0.9)
                    ForEach(0..<6) { index in
                        Circle()
                            .fill(Theme.gold)
                            .frame(width: 4, height: 4)
                            .offset(x: burst ? size * 0.95 : size * 0.3)
                            .rotationEffect(.degrees(Double(index) * 60))
                            .opacity(burst ? 0 : 1)
                    }
                }
                Circle()
                    .fill(done ? AnyShapeStyle(Theme.jadeFill) : AnyShapeStyle(Color.clear))
                    .overlay(Circle().strokeBorder(done ? Theme.jade : Theme.inkSoft.opacity(0.6), lineWidth: 1.5))
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(Theme.onJadeFill)
                    .opacity(done ? 1 : 0)
                    .scaleEffect(done ? 1 : 0.4)
            }
            .frame(width: size, height: size)
            .animation(animated ? Motion.quick : nil, value: done)
        }
        .buttonStyle(.plain)
        .help(done ? "取消打卡" : "打卡")
        .accessibilityLabel(done ? "已打卡，点击取消" : "打卡")
        .onChange(of: done) { wasDone, isDone in
            guard !wasDone, isDone, let tapped = tappedAt else { return }
            tappedAt = nil
            if animated, Date().timeIntervalSince(tapped) < 1 { fireBurst() }
        }
        .onChange(of: keyPress) { _, press in
            if press != nil { self.press() }
        }
    }

    private func press() {
        tappedAt = !done && animated ? Date() : nil
        action()
    }

    private func fireBurst() {
        burst = false
        showBurst = true
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.6)) { burst = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { showBurst = false }
    }
}

struct ProgressBar: View {
    var value: Double
    var color: Color = Theme.jade
    var height: CGFloat = 8
    /// true：纯色（分类条、作息时长这类只表示多少的条）；false：玉色渐入淡金（修为、目标进度）
    var solid = false
    @Environment(\.spiritMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line.opacity(0.7))
                Capsule()
                    .fill(solid ? AnyShapeStyle(color) : AnyShapeStyle(LinearGradient(colors: [color, Theme.gold], startPoint: .leading, endPoint: .trailing)))
                    .frame(width: max(height, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
        // 关闭动效或系统“减少动态效果”时直接跳到新长度
        .animation(motion && !reduceMotion ? Motion.gentle : nil, value: value)
    }
}

/// 给“落笔入卷”这类会盖印的按钮登记位置：落笔后朱印盖在它旁边（见 EffectsCenter.stamp）。
/// 离开屏幕时自动注销；不在 RootView 里（没有 EffectsCenter）时什么也不做。
struct SealAnchorModifier: ViewModifier {
    @Environment(EffectsCenter.self) private var effects: EffectsCenter?
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
                effects?.sealAnchor = (id, rect)
            }
            .onDisappear {
                if effects?.sealAnchor?.id == id { effects?.sealAnchor = nil }
            }
    }
}

extension View {
    /// 落印处：挂在“落笔入卷”按钮上
    func sealAnchor() -> some View { modifier(SealAnchorModifier()) }
}
