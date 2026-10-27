import Foundation

// 今日洞府的三样新手小件（#8）：筑基三关（新手卡）、右栏顶上的“所向”目标细条、落笔卡底的“本月落笔 N 日”。
// 这里只放判定与写法（纯函数，不依赖 SwiftData，CoreCheck 逐条核对）；取数与界面在 Views/OnboardingCard、Views/GoalStrip、
// 首页的接法在 Views/DashboardView。不动数据模型：进度一律从现有记录现算，收起、落过的印、功成那天记在偏好设置里。

/// 筑基三关：一关立一项功课、二关落第一笔、三关随手一记或请 AI 代笔。
enum Onboarding {
    // MARK: 偏好键（AppPreferences.defaults；首页的 @AppStorage 读写同一份，离屏可用 APT_RENDER_DEFAULTS 预设）

    /// 点过“收起”：之后不再出现
    static let dismissedKey = "onboarding.dismissed"
    /// 三关全过的那一天（YYYY-MM-DD）：当天还留着写“筑基功成”，次日起不再出现
    static let doneDayKey = "onboarding.doneDay"
    /// 已经落过印的几关与功成的金光（“1,2,done”）；从没出现过时没有这个键（第一次出现时把已过的静默记下，不放动画）
    static let sealedKey = "onboarding.sealed"
    /// 用过一次随手记（随手记第一次记好时写下，见 QuickCommit.usedKey；三关读它）
    static let quickUsedKey = "onboarding.quickUsed"

    /// 有记录的日子（落笔或打卡）到这么多天就算老用户：筑基卡永不出现
    static let veteranDays = 30

    /// 三关的序号与写法
    enum Gate: Int, CaseIterable, Comparable {
        case habit = 1, write = 2, quick = 3

        static func < (a: Gate, b: Gate) -> Bool { a.rawValue < b.rawValue }

        /// 印文
        var seal: String { ["一", "二", "三"][rawValue - 1] }

        var title: String {
            switch self {
            case .habit: "一关 · 立一项功课"
            case .write: "二关 · 落第一笔"
            case .quick: "三关 · 随手一记，或请 AI 代笔"
            }
        }
    }

    /// 判三关要用的几样事实（都从现有记录现取：未归档的功课、修行录篇数、随手记标记、传书封数）
    struct Facts: Equatable {
        /// 未归档的功课名（按排序）
        var habitTitles: [String] = []
        var entries = 0
        var quickUsed = false
        var letters = 0
    }

    static let intro = "三件小事，各十息之功。过完三关，山门自开。"
    static let doneTitle = "筑基功成"
    static let doneLine = "三关已过，山门自开。明日起这张卡自行收起。"
    /// 三关的“复制例句”
    static let askExample = "帮我记一下午饭现金 18"
    /// 点了“复制例句”的提示与悬停说明：例句只是个样子，原样发出去会真的记下一笔现金 18，所以请换成今天真的一件事
    static let copiedHint = "已复制例句：到 Claude Code 里粘贴，换成你今天真的一件事再回车"
    static let copyHelp = "复制“\(askExample)”，到 Claude Code 里粘贴，换成你今天真的一件事再回车（原样发出去会真的记下一笔）"
    /// 标题行“收起”：永久收起，不再出现（点了之后提示一句；悬停说明同样讲清）
    static let dismissedHint = "筑基三关已收起，不再出现；立功课、落笔、随手记照常都在"
    static let dismissHelp = "收起筑基三关，之后不再出现（立功课、落笔、随手记照常都在）"

    static func passed(_ facts: Facts) -> Set<Gate> {
        var gates = Set<Gate>()
        if !facts.habitTitles.isEmpty { gates.insert(.habit) }
        if facts.entries > 0 { gates.insert(.write) }
        if facts.quickUsed || facts.letters > 0 { gates.insert(.quick) }
        return gates
    }

    /// 标题旁：“已过 1 / 3”
    static func progressText(_ passed: Set<Gate>) -> String { "已过 \(passed.count) / \(Gate.allCases.count)" }

    /// 每一关没过时的说明（一关后面接功法谱胶囊，三关后面接两颗按钮）。
    /// hotKeyFailed：全局热键 ⌥⌘J 没注册上（被别的应用占用，随手记记下的 quick.hotKeyError 不空）——三关改说点菜单栏的笔形小图标
    static func todo(_ gate: Gate, hotKeyFailed: Bool = false) -> String {
        switch gate {
        case .habit: "挑一式，点一下就立好："
        case .write: "在上面的落笔框写一句，⌘↩ 入卷。"
        case .quick:
            hotKeyFailed
                ? "点菜单栏的笔形小图标随手记一句；或在 Claude Code 里打开\(folderName)文件夹，说：“\(askExample)”。"
                : "在任何地方按 ⌥⌘J 写一句；或在 Claude Code 里打开「yunshan-journal」文件夹，说：“\(askExample)”。"
        }
    }

    /// 三关里要用户去 Claude Code 打开的那个文件夹名：名字里的空格换成不换行空格，窄窗口折行时整段折到下一行，
    /// 不会把“「②”单独挂在行尾（热键没注册上那一支用它；热键正常那一支的文案一字不改）
    static let folderName = "「yunshan-journal」"

    /// 三关“试一下”按钮的字：热键好好的写“试一下 ⌥⌘J”；没注册上时不再提 ⌥⌘J（按了没反应），写“试一下随手记”
    static func quickTryLabel(hotKeyFailed: Bool) -> String { hotKeyFailed ? "试一下随手记" : "试一下 ⌥⌘J" }

    /// 同一颗按钮的悬停说明（点了都是弹出随手记浮窗）
    static func quickTryHelp(hotKeyFailed: Bool) -> String {
        hotKeyFailed
            ? "弹出随手记浮窗：写一句、⌘↩ 记下（⌥⌘J 被别的应用占用了，平时点菜单栏的笔形小图标随手记）"
            : "弹出随手记浮窗：写一句、⌘↩ 记下（在别的应用里也能按 ⌥⌘J）"
    }

    /// 每一关过了之后的一句：已立「冥想」等 2 项 / 已落 3 篇 / 已用过随手记
    static func doneText(_ gate: Gate, _ facts: Facts) -> String {
        switch gate {
        case .habit:
            guard let first = facts.habitTitles.first else { return "已立功课" }
            return facts.habitTitles.count > 1 ? "已立「\(first)」等 \(facts.habitTitles.count) 项" : "已立「\(first)」"
        case .write:
            return "已落 \(facts.entries) 篇"
        case .quick:
            switch (facts.quickUsed, facts.letters > 0) {
            case (true, true): return "已用过随手记，也收到过 AI 传书"
            case (true, false): return "已用过随手记"
            default: return "已收到 \(facts.letters) 封 AI 传书"
            }
        }
    }

    // MARK: 出不出现

    /// 首页显示筑基卡：没收起、不是老用户（有记录的日子不到 30 天；还没数出来时先不出，免得老用户看见一闪），
    /// 且三关没全过、或全过的那天就是今天
    static func shows(dismissed: Bool, doneDay: String, today: LocalDay, recordDays: Int?) -> Bool {
        guard !dismissed, let recordDays, recordDays < veteranDays else { return false }
        return doneDay.isEmpty || doneDay == today.key
    }

    /// 有记录的日子：落笔的日子与打卡的日子合起来数（认不出的日期不算）
    static func recordDays(journal: [String], habits: [LocalDay]) -> Int {
        var days = Set(habits)
        for key in journal { if let day = LocalDay(key: key) { days.insert(day) } }
        return days.count
    }

    // MARK: 落印（每关只放一次）

    /// 卡片看到这一刻的三关之后要做的：哪几关落印（放动画）、要不要掠金光、写回的偏好
    struct SealStep: Equatable {
        /// 这一次新落印的几关（从小到大）
        var land: [Gate]
        /// 三关全过、这一次才看到：整卡掠一道金光、提示“筑基功成”（金光由卡片记在 @State 里放完，不看偏好）
        var celebrate: Bool
        /// 写回 onboarding.sealed（nil 表示不改：卡片看不见时先不记，等看得见了再落印）
        var sealed: String?
        /// 三关全过、还没记过功成那天：记成今天（nil 表示不改）
        var doneDay: String?
    }

    /// 记下的落印：数字是关的序号，“done”是功成的金光
    static func parseSealed(_ text: String) -> (gates: Set<Gate>, done: Bool) {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return (Set(parts.compactMap { Int($0).flatMap(Gate.init(rawValue:)) }), parts.contains("done"))
    }

    static func formatSealed(_ gates: Set<Gate>, done: Bool) -> String {
        (gates.sorted().map { String($0.rawValue) } + (done ? ["done"] : [])).joined(separator: ",")
    }

    /// 卡片出现、三关有变、或卡片重新看得见时：
    /// - 卡片看不见（visible 为假：主窗口在别的应用后面、上面挂着弹窗、或随手记浮窗正开着）：只记功成那天，
    ///   不写落印记录、不掠金光、不提示——等看得见了（主窗口重新成为键盘窗口）再调一次，那时才落印；
    /// - 从没出现过（sealed 为 nil）：已过的静默记下，不落印也不掠金光（老数据第一次看到卡，不一口气连放三下）；
    /// - 之后：已过、还没落过印的几关落印（一关只放一次，之后改回没过再过也不再放）；三关全过、还没掠过金光的掠一次；
    /// - 三关全过、还没记功成那天的，记成今天（当天留着“筑基功成”，次日不再出现）。
    static func step(passed: Set<Gate>, sealed: String?, doneDay: String, today: LocalDay, visible: Bool = true) -> SealStep {
        let all = passed.count == Gate.allCases.count
        let day = all && doneDay.isEmpty ? today.key : nil
        guard visible else { return SealStep(land: [], celebrate: false, sealed: nil, doneDay: day) }
        guard let sealed else {
            return SealStep(land: [], celebrate: false, sealed: formatSealed(passed, done: all), doneDay: day)
        }
        let old = parseSealed(sealed)
        let land = passed.subtracting(old.gates).sorted()
        let celebrate = all && !old.done
        return SealStep(land: land, celebrate: celebrate, sealed: formatSealed(old.gates.union(passed), done: old.done || all), doneDay: day)
    }

    /// 画的时候按“已过”画的几关：卡片看不见时，刚过、还没落过印的几关先按没过画（印位仍是虚线圆、标题不换“筑基功成”），
    /// 等看得见了再一起落印；看得见、或从没出现过（sealed 为 nil，第一次出现静默盖上）时就是实际已过的几关
    static func shown(passed: Set<Gate>, sealed: String?, visible: Bool) -> Set<Gate> {
        guard !visible, let sealed else { return passed }
        return passed.intersection(parseSealed(sealed).gates)
    }

    /// 画的时候：这一关的印是不是“刚过、还没落过”（卡片可见时才放落印动画）。从没出现过时一律不算
    static func isFresh(_ gate: Gate, passed: Set<Gate>, sealed: String?) -> Bool {
        guard let sealed, passed.contains(gate) else { return false }
        return !parseSealed(sealed).gates.contains(gate)
    }

    // MARK: 本月落笔

    /// 本月（与今天同年同月、不晚于今天）落笔的日子数；同一天几篇算一日
    static func monthDays(_ keys: [String], today: LocalDay) -> Int {
        let first = today.firstOfMonth
        var days = Set<LocalDay>()
        for key in keys { if let day = LocalDay(key: key), day >= first, day <= today { days.insert(day) } }
        return days.count
    }

    /// “今日已落 2 篇 · 本月落笔 9 日”（本月一日都没有时只写前半句）
    static func todayLine(todayCount: Int, monthDays: Int) -> String {
        "今日已落 \(todayCount) 篇" + (monthDays > 0 ? " · 本月落笔 \(monthDays) 日" : "")
    }

    /// 今天还没写、本月写过时落笔卡底单独一行“本月已落笔 9 日”；其余时候不写
    static func monthOnlyLine(todayCount: Int, monthDays: Int) -> String? {
        todayCount == 0 && monthDays > 0 ? "本月已落笔 \(monthDays) 日" : nil
    }
}

// MARK: - 所向（右栏顶上的目标细条）

/// 首页右栏最上面的“所向”：进行中的目标最多两行（必须 > 应该 > 可以，再按期限近），每行进度与“还剩 58 天”。
enum GoalStripRules {
    /// 一个目标的值拷贝（界面从 Goal 取来）
    struct Item: Equatable {
        var title: String
        /// must / should / could
        var priority: String
        var progress: Int
        var targetDate: String?
        var createdAt: Date = .distantPast
    }

    static let limit = 2

    /// 优先级的先后：必须、应该、可以，认不出的排最后
    static func rank(_ priority: String) -> Int { ["must": 0, "should": 1, "could": 2][priority] ?? 3 }

    /// 排好的前两个与其余几个（只给进行中的）
    static func pick(_ items: [Item]) -> (shown: [Item], more: Int) {
        let sorted = items.sorted { a, b in
            if rank(a.priority) != rank(b.priority) { return rank(a.priority) < rank(b.priority) }
            // 有期限的在前，期限近的在前；都没有期限按先立的在前
            let da = a.targetDate.flatMap(LocalDay.init(key:)), db = b.targetDate.flatMap(LocalDay.init(key:))
            switch (da, db) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.title < b.title
        }
        return (Array(sorted.prefix(limit)), max(0, sorted.count - limit))
    }

    /// 期限的说法与是不是要警示：还剩 58 天 / 今日到期 / 期限已过 3 天（警示）/ 未定期限
    static func deadline(_ targetDate: String?, today: LocalDay) -> (text: String, overdue: Bool) {
        guard let key = targetDate, let day = LocalDay(key: key) else { return ("未定期限", false) }
        let days = today.days(to: day)
        if days > 0 { return ("还剩 \(days) 天", false) }
        if days == 0 { return ("今日到期", false) }
        return ("期限已过 \(-days) 天", true)
    }

    /// 进度的写法（0–100 之外的夹回去）
    static func percent(_ progress: Int) -> String { "\(min(100, max(0, progress)))%" }

    /// 卡内链接：“另有 3 个”
    static func moreText(_ more: Int) -> String? { more > 0 ? "另有 \(more) 个" : nil }
}
