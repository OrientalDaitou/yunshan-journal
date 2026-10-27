import Foundation

// 首页落笔卡随时辰多出的几样（#4）：晨课 · 立今日一愿、问心签、晚课 · 三省。
// 这里是纯函数：时段怎么分、晚课记到哪天、问心签题库与轮换、“答过”怎么记、三省怎么合成一篇日省。
// 只依赖 Foundation 与 Core 里的 LocalDay（CoreCheck 单独编译这个文件夹）；画法在 Views/DailyRitualViews.swift。
//
// 全都不进数据模型，记在偏好设置里（AppPreferences.defaults）：
// - `dashboard.vow.<日期>`：那天立的一愿（不是修行录条目）；`dashboard.vowDone.<日期>`：晚课里勾的“已成 1 / 未成 0”
// - `dashboard.nextFirst.<日期>`：那天晚课写的“明日第一件事”（次日晨课的“昨夜所定”）
// - `prompts.answered`：答过的签，签号 → 日期（最多留 400 条，半年内不再抽到）；`prompts.skip.<日期>`：那天“换一签”了几次
// - `dashboard.evening.open`：晚课三格的开关（"1" 开着：暮夜进页时正文框空着就自动打开）。哪天的晚课已毕不另记，
//   看那天修行录里有没有一篇“晚课 · 三省”（删掉那篇，签就回到“晚课 · 三省”）
// - 三格草稿 `draft.dashboard.evening.done / stuck / next`；立愿框写了一半的字 `draft.dashboard.vow.<日期>`

/// 一天的三段：晨 05:00–10:59 / 昼 11:00–17:59 / 暮夜 18:00–04:59
enum DailyRitePhase: String, CaseIterable {
    case morning, daytime, evening

    var label: String {
        switch self {
        case .morning: "晨"
        case .daytime: "昼"
        case .evening: "暮夜"
        }
    }
}

enum DailyRite {
    /// minute 是当天第几分钟（0–1439，超出时按天取模）
    static func phase(minute: Int) -> DailyRitePhase {
        let m = ((minute % 1440) + 1440) % 1440
        switch m {
        case 300..<660: return .morning     // 05:00–10:59
        case 660..<1080: return .daytime    // 11:00–17:59
        default: return .evening            // 18:00–04:59
        }
    }

    /// 晚课记到哪天：00:00–04:59 合成的日省记在前一天（熬夜写的还是“昨天”的三省），05:00 起记今天。
    /// 分界与时段同在 05:00：暮夜（到 04:59）里做的晚课、看到的一愿都是同一天的，05:00 晨课读的“昨夜所定”正是它
    static let dayStartMinute = 300

    static func ritualDay(minute: Int, today: LocalDay) -> LocalDay {
        let m = ((minute % 1440) + 1440) % 1440
        return m < dayStartMinute ? today.adding(days: -1) : today
    }

    // MARK: 偏好里的键

    static let vowPrefix = "dashboard.vow."
    static let vowDonePrefix = "dashboard.vowDone."
    static let nextFirstPrefix = "dashboard.nextFirst."
    static let skipPrefix = "prompts.skip."
    static let answeredKey = "prompts.answered"
    static let eveningOpenKey = "dashboard.evening.open"
    /// 立愿框里写了一半的字，按那天记（换了一天就不再预填，过一天清掉）
    static let vowDraftPrefix = "draft.dashboard.vow."

    static func vowKey(_ day: LocalDay) -> String { vowPrefix + day.key }
    static func vowDoneKey(_ day: LocalDay) -> String { vowDonePrefix + day.key }
    static func nextFirstKey(_ day: LocalDay) -> String { nextFirstPrefix + day.key }
    static func skipKey(_ day: LocalDay) -> String { skipPrefix + day.key }
    static func vowDraftKey(_ day: LocalDay) -> String { vowDraftPrefix + day.key }
    /// 晚课三格的草稿：done 今日所成、stuck 卡在何处、next 明日第一件事
    static func eveningDraftKey(_ field: String) -> String { "draft.dashboard.evening.\(field)" }

    /// 按日期记的几样留多久：一愿、已成与否、明日第一件事留 60 天；“换一签”的次数只对当天有用；
    /// 立愿框的草稿留到第二天（凌晨看到的还是前一天的框），再往前的清掉
    static let keepDays = 60

    /// 哪些键已经过期可以删：只认上面几个按日期记的前缀，日期写坏的不动
    static func staleKeys<S: Sequence>(_ keys: S, today: LocalDay, keepDays: Int = keepDays) -> [String] where S.Element == String {
        let longPrefixes = [vowPrefix, vowDonePrefix, nextFirstPrefix]
        var stale: [String] = []
        for key in keys {
            if key.hasPrefix(skipPrefix) {
                if let day = LocalDay(key: String(key.dropFirst(skipPrefix.count))), day < today { stale.append(key) }
                continue
            }
            if key.hasPrefix(vowDraftPrefix) {
                if let day = LocalDay(key: String(key.dropFirst(vowDraftPrefix.count))), day.days(to: today) > 1 { stale.append(key) }
                continue
            }
            guard let prefix = longPrefixes.first(where: { key.hasPrefix($0) }),
                  let day = LocalDay(key: String(key.dropFirst(prefix.count))) else { continue }
            if day.days(to: today) > keepDays { stale.append(key) }
        }
        return stale.sorted()
    }

    // MARK: 晚课 · 三省

    /// 三格合成一篇日省（复盘，周期“日省”）的正文，空的段不写；三格全空时 nil（只有一愿不算）：
    /// ```
    /// 【今日一愿】写完第三章 3 页（已成）
    /// 【所得】…
    /// 【所失】…
    /// 【下一步】…
    /// ```
    /// 段名与复盘模板（ReviewPeriod.template）同一套，快照、复盘回访按【】切段都认得。vowDone：true 已成、false 未成、nil 没勾
    static func eveningReview(vow: String, vowDone: Bool?, done: String, stuck: String, next: String) -> String? {
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let sections = [("所得", clean(done)), ("所失", clean(stuck)), ("下一步", clean(next))].filter { !$0.1.isEmpty }
        guard !sections.isEmpty else { return nil }
        var lines: [String] = []
        let wish = clean(vow).replacingOccurrences(of: "\n", with: " ")
        if !wish.isEmpty {
            lines.append("【今日一愿】" + wish + (vowDone.map { $0 ? "（已成）" : "（未成）" } ?? ""))
        }
        lines += sections.map { "【\($0.0)】" + $0.1 }
        return lines.joined(separator: "\n")
    }

    /// 晚课入卷的标题（时间线、“今日已落”里一眼认得出是晚课合成的；“晚课已毕”也按这一篇在不在来认）
    static let eveningTitle = "晚课 · 三省"

    /// 晚课三格开不开：只在进页、换到暮夜、换了一天时判定一次（之后只由点签、“改写一段话”、入卷来开合，
    /// 正文清空的那一下不会突然换成三格）。返回三格记到哪一晚，nil 是收着。
    /// - 三格开着、里面正写着字（draftsBlank 为假）时原样留着：跨过 05:00 也不收，仍记到开始写的那一晚
    /// - 否则要暮夜、开关开着、正文框空着、这一晚还没合成入卷（saved 只在前几条都满足时才查）才打开
    static func eveningPanel(current: LocalDay?, draftsBlank: Bool, phase: DailyRitePhase, ritualDay: LocalDay,
                             switchOn: Bool, bodyWritten: Bool, saved: () -> Bool) -> LocalDay? {
        if let current, !draftsBlank { return current }
        guard phase == .evening, switchOn, !bodyWritten, !saved() else { return nil }
        return ritualDay
    }

    /// 首页落笔卡的类型不再悄悄沿用上次（上次记了灵感，下一句日记就成了灵感）：入卷之后、或打开时草稿是空的，
    /// 都回到日记；写了一半的草稿照旧保留它的类型
    static func composerKind(_ kind: JournalKind, draftBlank: Bool) -> JournalKind { draftBlank ? .diary : kind }

    /// 一愿的写法：去掉首尾空白，换行并成一行，最多 60 字
    static func cleanVow(_ text: String) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > 60 ? String(line.prefix(60)) : line
    }
}

// MARK: - 问心签

struct DailyPrompt: Equatable, Identifiable {
    /// 签号：类别 × 100 + 类别里的序号（从 1 数）。只往各类末尾加新题，已有的不改序号、不删：答过的记录按签号存
    let id: Int
    let category: DailyPrompts.Category
    let text: String
}

enum DailyPrompts {
    /// 七类：心境 / 精力 / 学业 / 关系 / 身体 / 灵石 / 感恩
    enum Category: Int, CaseIterable {
        case mood = 1, energy, study, people, body, money, gratitude

        var label: String {
            switch self {
            case .mood: "心境"
            case .energy: "精力"
            case .study: "学业"
            case .people: "关系"
            case .body: "身体"
            case .money: "灵石"
            case .gratitude: "感恩"
            }
        }
    }

    /// 答过的签多久内不再抽到（约半年）
    static let quietDays = 183
    /// 答过的签最多记多少条（多了丢最早的）
    static let answeredLimit = 400

    /// 题库：每类一句一问，问得具体（不问“你今天好吗”）。只往各类末尾追加
    private static let bank: [(Category, [String])] = [
        (.mood, [
            "今天哪一刻最专注？",
            "今天有没有一刻觉得“刚刚好”？",
            "今天卡住你的是事，还是心？",
            "最近反复想起的一件事是？",
            "今天对自己说过最好的一句话是？",
            "此刻心里最重的一件事是什么？",
            "今天哪件小事让你心情变好了？",
            "今天什么时候最想停下来歇一歇？",
            "今天有没有一个念头，让你想了很久？",
            "如果给今天的心境配一种天气，是什么？",
            "今天哪一刻你最像自己？",
            "今天有什么事，比想象中容易？",
            "今天让你烦躁的那一下，背后是什么？",
            "最近担心的事里，哪一件可以先放下？",
            "今天有没有一刻觉得安静？是在哪里？",
            "这几天最期待的一件事是？",
            "今天做的哪个决定，你现在还满意？",
            "如果今天重来一次，你会先做哪件事？",
            "此刻最想对明天的自己说什么？",
            "今天有什么让你笑出声的事？",
            "最近有什么事让你觉得自己在变好？",
            "今天有没有哪句话，让你想了又想？",
        ]),
        (.energy, [
            "今天精神最好的是哪个时段？",
            "今天什么事最耗你的精力？",
            "今天有没有一段时间，做事特别顺？",
            "明天想少做的一件事是？",
            "今天在手机上花的时间，哪一段最不值？",
            "今天最拖的那件事，卡在第一步还是中间？",
            "今天有没有被打断？被什么打断的？",
            "如果明天只能做成三件事，是哪三件？",
            "今天哪件事做到一半就想换别的？",
            "今天什么时候开始觉得累了？",
            "今天有没有做一件“其实可以不做”的事？",
            "今天最有效率的一个小时在做什么？",
            "今天开始一件事之前，你磨蹭了多久？",
            "什么事能让你下午重新打起精神？",
            "今天给自己留了空白的时间吗？",
            "今天有什么事，比计划多花了时间？",
            "今天哪一刻你感觉在“充电”？",
            "这周哪一天状态最好？那天有什么不同？",
            "今天的待办里，哪一件其实不急？",
            "今天的节奏是快了、慢了，还是刚好？",
            "明天醒来第一件事，想做什么？",
            "今天有没有一件事一气呵成？",
        ]),
        (.study, [
            "今天学到的一个小东西是？",
            "今天读到的哪一句话值得记下？",
            "论文或作业今天推进到了哪一步？",
            "今天有什么没弄懂的？打算问谁？",
            "今天哪道题、哪个概念让你卡了最久？",
            "今天学的东西，能用一句话讲给别人听吗？",
            "这周最想弄明白的一个问题是？",
            "今天有没有一个“原来如此”的瞬间？",
            "下次上课或组会前，最该准备的是什么？",
            "今天写下的哪一段，你最满意？",
            "今天学的哪部分最枯燥？能换个学法吗？",
            "最近在读的书，读到哪了？",
            "今天有没有把一个大任务拆小一点？",
            "如果明天就考今天学的，你最担心哪部分？",
            "今天从别人那里学到了什么？",
            "最近哪门课、哪个项目最让你有兴趣？",
            "今天查过的资料里，哪一条最有用？",
            "今天有什么想法，可以写进论文或作业？",
            "今天的笔记里，哪一条值得明天再看一遍？",
            "这周的学习计划，做到了几成？",
            "今天有没有一个问题，问出来就解决了？",
            "今天遇到的难处，换个角度看会怎样？",
        ]),
        (.people, [
            "今天和谁说话最舒服？",
            "今天最想感谢的一个人是谁？",
            "今天有没有谁让你觉得被理解？",
            "最近想联系却一直没联系的人是谁？",
            "今天和家人说上话了吗？聊了什么？",
            "今天有没有帮到谁，哪怕一点点？",
            "今天谁的一句话让你记住了？",
            "今天和别人意见不同时，你是怎么做的？",
            "最近见过的朋友里，最想跟谁再聊聊？",
            "今天有没有一刻觉得孤单？",
            "今天和谁一起吃饭了？聊到了什么？",
            "有没有一句话，想对某个人说却还没说？",
            "今天有没有谁的做法值得你学？",
            "今天你给了谁一点耐心？",
            "最近你最欣赏的一个人是谁？为什么？",
            "今天有没有和不认识的人说上话？",
            "今天收到的消息里，哪一条让你开心？",
            "这周有没有人帮了你？你回应了吗？",
            "今天你拒绝了什么？拒绝得舒服吗？",
            "最近哪段关系让你觉得轻松？",
            "今天和老师或同学的交流里，记住了哪句？",
            "明天想主动联系谁？",
        ]),
        (.body, [
            "今天身体哪里在提醒你？",
            "昨晚睡得怎么样？几点睡的？",
            "今天喝够水了吗？",
            "今天走的路里，最舒服的是哪一段？",
            "今天吃的哪一顿最让你满足？",
            "今天有没有出去晒晒太阳？",
            "今天肩颈和眼睛累不累？",
            "今天动了一动吗？做了什么？",
            "今天什么时候最困？那之前在做什么？",
            "今天有没有吃得太急或太晚？",
            "最近身体有什么变化，值得记一笔？",
            "今天坐了多久才站起来一次？",
            "今天有没有好好吃早饭？",
            "今晚想几点睡？",
            "今天呼吸最顺畅的是哪一刻？",
            "今天有没有哪里疼或不舒服？",
            "今天的饭里，有蔬菜和水果吗？",
            "最近一次运动完，身体有什么感觉？",
            "今天咖啡或茶喝了几杯？睡得着吗？",
            "今天有没有一段时间离开屏幕？",
            "这周睡得最好的是哪一晚？那天做了什么？",
            "身体今天最想要的是休息、活动，还是一顿好饭？",
        ]),
        (.money, [
            "这周花得最值的一笔钱是什么？",
            "今天有没有一笔可以不花的钱？",
            "今天花得最开心的一笔是？",
            "最近冲动买下的东西，现在还喜欢吗？",
            "这个月最大的一笔开销是什么？值得吗？",
            "今天的饭钱大概多少？",
            "有没有哪个订阅或会员，其实很少用？",
            "如果这周只能花一笔“想要”的钱，花在哪？",
            "今天有没有为将来的自己存下一点？",
            "最近一次为体验花钱，而不是买东西，是什么？",
            "今天买东西前，有没有犹豫一下？",
            "这周的交通费比平时多还是少？",
            "有没有一笔钱，花了之后让你更轻松？",
            "最近在攒钱买什么？",
            "今天有没有省下一笔钱？怎么省的？",
            "最近花钱最多的是哪一类？你满意吗？",
            "有什么东西，买回来之后天天在用？",
            "今天在吃上花了多少？比平时多吗？",
            "这周有没有一笔想收回的开销？下次怎么办？",
            "如果多出一百块，你最想用来做什么？",
            "最近一次请人吃饭或送礼，是什么时候？",
            "下个月有哪笔大开销要提前准备？",
        ]),
        (.gratitude, [
            "今天想感谢的一件小事是？",
            "今天有什么看似平常、其实很幸运的事？",
            "今天谁让你的一天变得好一点？",
            "今天哪一顿饭值得说声谢谢？",
            "今天看到的哪一处风景让你停下了脚步？",
            "今天有什么东西帮了你大忙？",
            "最近一次被善待，是什么时候？",
            "今天有什么事进展顺利，值得谢谢自己？",
            "今天听到的哪首歌、哪句话让你舒服？",
            "今天有什么天气、光线或声音让你喜欢？",
            "这周你最感激的一个时刻是？",
            "今天有什么烦恼，后来自己解开了？",
            "你身边有什么，是一年前还没有的？",
            "今天有谁回了你的消息，让你安心？",
            "今天的哪一件事，换作以前你做不到？",
            "今天有什么平常事让你觉得安稳？",
            "最近有什么书、视频或课程让你受益？",
            "今天谢谢身体帮你做到了什么？",
            "有什么事情，比你以为的要好？",
            "今天有没有一个人，值得你写一句谢谢？",
            "这段时间最想珍惜的是什么？",
            "今天最想记住的一个画面是？",
        ]),
    ]

    /// 全部签，按类别、类别里按序号
    static let all: [DailyPrompt] = bank.flatMap { category, texts in
        texts.enumerated().map { DailyPrompt(id: category.rawValue * 100 + $0.offset + 1, category: category, text: $0.element) }
    }

    /// 轮换次序：七类轮流（每类的第 1 题、再第 2 题……），相邻两天不是同一类；一轮 all.count 天，轮内不重复
    static let rotation: [DailyPrompt] = {
        let groups = Category.allCases.map { category in all.filter { $0.category == category } }
        let longest = groups.map(\.count).max() ?? 0
        return (0..<longest).flatMap { index in groups.compactMap { index < $0.count ? $0[index] : nil } }
    }()

    private static let byID: [Int: DailyPrompt] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    private static let byText: [String: DailyPrompt] = Dictionary(all.map { ($0.text, $0) }, uniquingKeysWith: { first, _ in first })

    static func prompt(id: Int) -> DailyPrompt? { byID[id] }

    /// 轮换的起点：2024-01-01 起第几天
    private static let epoch = LocalDay(year: 2024, month: 1, day: 1)
    /// “换一签”一次往后跳几格：与题数互质（跳一圈走遍每一格），且每跳一次换一类（37 除以 7 余 2）
    static let skipStride = 37

    private static func wrap(_ value: Int, _ count: Int) -> Int { ((value % count) + count) % count }

    /// 每一类的签，按轮换次序：某一格的签半年内答过时，只在这一类里顺延
    private static let byCategory: [Category: [DailyPrompt]] = Dictionary(grouping: rotation, by: \.category)

    /// 同一类里顺延一次隔几道：与这一类的题数互质（顺延一圈走遍这一类），尽量接近一半——
    /// 22 道时隔 9 道，顺延到的那道本来要 9 周后（或 9 周前）才出，不会撞上下周、下下周的签
    static func categoryStride(_ count: Int) -> Int {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        var stride = max(1, count / 2)
        while stride > 1 && gcd(stride, count) != 1 { stride -= 1 }
        return stride
    }

    /// 某天在轮换里落到哪一格：不换签时就是按日期排的那一格（相邻两天的格不同类）。
    /// “换一签”k 次：从那一格起每次往后跳 skipStride 格，跳过和昨天、明天那一格同类的格，换来换去也不会撞上前后两天的类
    static func slot(on day: LocalDay, skips: Int = 0) -> Int {
        let list = rotation
        let count = list.count
        let base = wrap(epoch.days(to: day), count)
        guard skips > 0, count > 1 else { return base }
        let neighbours: Set<Category> = [list[wrap(base - 1, count)].category, list[wrap(base + 1, count)].category]
        // 跳 count 次走遍每一格（最后一跳回到原格）；题库只剩前后两天那两类时就不挑类
        let landings = (1...count).filter { !neighbours.contains(list[wrap(base + $0 * skipStride, count)].category) }
        let jumps = landings.isEmpty ? Array(1...count) : landings
        return wrap(base + jumps[(skips - 1) % jumps.count] * skipStride, count)
    }

    /// 某天的签：先按日期（与“换一签”的次数）在轮换里取一格；那一格半年内答过（今天以前），就在**同一类**里
    /// 隔 categoryStride 道往后找没答过的——不挪到下一格（那是明天的格，挪过去明天就会再出同一道）。
    /// 所以无论答过哪些，相邻两天都不同类、不同题。今天答的仍算今天的签（卡上写“今日已答”，不会一答就换掉）。
    /// 这一类半年里都答过了：取这一类里最久以前答过的那一签
    static func pick(on day: LocalDay, skips: Int = 0, answered: [Int: LocalDay] = [:]) -> DailyPrompt {
        let first = rotation[slot(on: day, skips: max(0, skips))]
        func quiet(_ prompt: DailyPrompt) -> Bool {
            guard let when = answered[prompt.id], when < day else { return false }
            return when.days(to: day) < quietDays
        }
        guard quiet(first) else { return first }
        let peers = byCategory[first.category] ?? [first]
        let at = peers.firstIndex(of: first) ?? 0
        let stride = categoryStride(peers.count)
        let order = (0..<peers.count).map { peers[wrap(at + $0 * stride, peers.count)] }
        if let free = order.first(where: { !quiet($0) }) { return free }
        // 同一天答的按上面的顺延次序
        return order.enumerated().min { a, b in
            let da = answered[a.element.id] ?? day, db = answered[b.element.id] ?? day
            return da != db ? da < db : a.offset < b.offset
        }?.element ?? first
    }

    // MARK: 答签

    /// 签文在正文开头的写法：「今天哪一刻最专注？」
    static func quoted(_ prompt: DailyPrompt) -> String { "「\(prompt.text)」" }

    /// 正文是不是在答某一签：去掉开头空白后以「签文」开头（换签前插进去的也认）
    static func answered(in body: String) -> DailyPrompt? {
        let text = body.drop { $0.isWhitespace || $0.isNewline }
        guard text.hasPrefix("「"), let close = text.firstIndex(of: "」") else { return nil }
        return byText[String(text[text.index(after: text.startIndex)..<close])]
    }

    /// “答此签”：在正文开头插「签文」加换行。开头已是这一签就不动；开头是别的签（换签前插的）就换成这一签
    static func insertingAnswer(_ prompt: DailyPrompt, into text: String) -> String {
        guard let old = answered(in: text) else { return quoted(prompt) + "\n" + text }
        if old == prompt { return text }
        // 换掉旧签：去掉开头空白与「旧签文」，再去掉紧跟的一个换行，后面写的字原样留着
        var rest = text.drop { $0.isWhitespace || $0.isNewline }.dropFirst(quoted(old).count)
        if rest.first == "\n" { rest = rest.dropFirst() }
        return quoted(prompt) + "\n" + rest
    }

    /// 偏好里存的“答过的签”（签号字符串 → 日期）读成 签号 → 日期；写坏的条目跳过
    static func decodeAnswered(_ raw: [String: Any]?) -> [Int: LocalDay] {
        var result: [Int: LocalDay] = [:]
        for (key, value) in raw ?? [:] {
            guard let id = Int(key), let text = value as? String, let day = LocalDay(key: text) else { continue }
            result[id] = day
        }
        return result
    }

    /// 记下某天答了某一签，返回要写回偏好的字典；超过 answeredLimit 条时丢掉最早答的
    static func recording(_ id: Int, on day: LocalDay, into raw: [String: Any]?, limit: Int = answeredLimit) -> [String: String] {
        var map = decodeAnswered(raw)
        map[id] = day
        let kept = map.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(max(0, limit))
        return Dictionary(uniqueKeysWithValues: kept.map { (String($0.key), $0.value.key) })
    }
}
