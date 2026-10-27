import Foundation

/// 随手记“随心”：写一句话，自动认出该记到哪里——修行录（日记 / 灵感 / 复盘）、灵石账簿（记账）、每日功课（打卡）、
/// 时辰卷（日程），并给出预览签上的那行字和“依据”。纯逻辑（不碰数据库），CoreCheck 用一百多句例句覆盖。
///
/// 认的次序（见 Decision.result）：
/// 1. 开头的前缀最优先：“灵感：”“#灵感”“想法：”→ 灵感；“复盘：”“日省：”→ 复盘；“日记：”；“记账：”“账：”；“打卡：”；“日程：”“提醒我”。
///    只写了前缀、标签或日期、没有正文的，不让记（“写上要记的话”）。
/// 2. 写得长（超过约 30 字）或写了几句（两个分句以上；“跑步 30 分钟，好累”这种后面跟一小句感受的不算）→ 日记，
///    只认前缀与标签，打卡 / 记账 / 日程留给“改作”。
/// 3. 一句里有两笔钱（“午饭 18.5 晚饭 30”）→ 日记，提醒分两句记。
/// 4. 带币种的金额（¥ $ A$ 元 块 刀……）→ 记账。
/// 5. 明确的钟点（下午3点、19:30、今晚七点半）→ 日程；只有钟点、已经过了 → 日记（备选日程）。
/// 6. 句首 / 句尾的裸数字（“午饭 18.5”）→ 记账；但这句说的是一项功课时（“喝水 3”“运动 50”）按打卡理解，
///    说的是体重、气温、分数或年份（“体重 65”“2026”）时不记账。
/// 7. 未来的日期、没写钟点、标题短而不带感受的（“后天交报告”）→ 全天日程；“周一好累”“周五的组会被取消”是感想 → 日记。
/// 8. 说到了一项功课名或同类说法（HabitAlias）→ 打卡；单位对不上、今日已圆满、写的是没做 / 想做 / 打算做（“没跑步”“待会冥想”），
///    或说到了两项功课时改记日记（备选打卡）。
/// 9. 其余 → 日记；句首“昨天 / 前天 / 上周五”→ 补记那天。
/// 饭点与时段词（午饭、中午、下午、晚上）本身不算钟点；数字后紧跟量词（分钟、杯、页、个……）不算钱；
/// 写了“了”的（“下午3点开了个会”“周一去了图书馆”）是在记已经发生的事，不当日程。
enum QuickParse {
    // MARK: 类型

    enum Intent: String, CaseIterable {
        case diary, note, review, expense, checkin, event

        var label: String {
            switch self {
            case .diary: "日记"
            case .note: "灵感"
            case .review: "复盘"
            case .expense: "记账"
            case .checkin: "打卡"
            case .event: "日程"
            }
        }

        /// 记到哪一页
        var destination: String {
            switch self {
            case .diary, .note, .review: "修行录"
            case .expense: "灵石账簿"
            case .checkin: "每日功课"
            case .event: "时辰卷"
            }
        }

        /// 那一页的小物（yunshan-ornament-<名>-v1）
        var ornament: String {
            switch self {
            case .diary, .note, .review: "journal"
            case .expense: "abacus"
            case .checkin: "lotus"
            case .event: "waterclock"
            }
        }

        /// 主按钮上的字
        var button: String {
            switch self {
            case .diary, .note, .review: "落笔入卷"
            case .expense: "入账"
            case .checkin: "打卡"
            case .event: "记入时辰卷"
            }
        }

        /// 记下后浮窗里盖的小印
        var seal: String {
            switch self {
            case .diary, .note: "入卷"
            case .review: "复盘"
            case .expense: "入账"
            case .checkin: "功课"
            case .event: "定时"
            }
        }

        var journalKind: JournalKind? {
            switch self {
            case .diary: .diary
            case .note: .note
            case .review: .review
            default: nil
            }
        }
    }

    /// 用户在“不对？改作 ▾”里选定的类型：锁定这一句，清空正文才回到自动。打卡带功课名（存草稿时按名字存，功课换了次序也认得）
    enum Choice: Equatable {
        case diary, note, expense, event
        case checkin(String)

        var raw: String {
            switch self {
            case .diary: "diary"
            case .note: "note"
            case .expense: "expense"
            case .event: "event"
            case .checkin(let title): "checkin:" + title
            }
        }

        init?(raw: String) {
            switch raw {
            case "diary": self = .diary
            case "note": self = .note
            case "expense": self = .expense
            case "event": self = .event
            default:
                guard raw.hasPrefix("checkin:"), raw.count > 8 else { return nil }
                self = .checkin(String(raw.dropFirst(8)))
            }
        }

        var intent: Intent {
            switch self {
            case .diary: .diary
            case .note: .note
            case .expense: .expense
            case .event: .event
            case .checkin: .checkin
            }
        }
    }

    /// 一项功课（只要认句子用得上的几样）
    struct Habit: Equatable {
        var title: String
        var unit: String = ""
        /// 数量目标；nil 或 ≤0 是只打卡的功课
        var target: Double? = nil
        /// 最近几天的打卡（调用方给今天、昨天、前天）：已记数量、是否已达标
        var days: [LocalDay: DayState] = [:]

        var isQuantity: Bool { (target ?? 0) > 0 }
    }

    struct DayState: Equatable {
        var quantity: Double?
        var done: Bool
    }

    struct Context {
        var today: LocalDay
        /// 现在是当天第几分钟（离屏截图按 APT_RENDER_CLOCK）
        var nowMinute: Int
        var habits: [Habit] = []
    }

    struct Journal: Equatable {
        var kind: JournalKind
        var body: String
        var day: LocalDay
        var tags: [String] = []
    }

    struct Expense: Equatable {
        var cents: Int
        /// 消费类别；认不出时是“待分类消费”
        var category: String
        /// 认出类别所凭的那个词（原句里的写法）
        var keyword: String?
        var description: String
        var day: LocalDay
        var note: String = ""
        /// 写的是未来的日子：仍记今天
        var movedFromFuture = false
    }

    struct Checkin: Equatable {
        /// 功课在 Context.habits 里的下标
        var habit: Int
        var title: String
        var unit: String
        var day: LocalDay
        /// 数量型：这次要记成的当天数量（已记的加上这句的；没写数量记满）；只打卡的功课为 nil
        var quantity: Double?
        /// 这句写的数量（已换算成功课的单位）；没写为 nil
        var added: Double?
        /// 当天原来记的数量
        var before: Double?
        var target: Double?
        /// 写进这条打卡备注的话（HabitLog.notes）
        var note: String = ""
        /// 按同类说法对上时，句子里的那个词（“跑步”→「运动」）
        var via: String?
        /// 单位换算的说明，例如“1 小时 → 60 分钟”
        var conversion: String?
    }

    struct Event: Equatable {
        var day: LocalDay
        /// nil 为全天
        var start: Int?
        var end: Int?
        var title: String
        /// “晚上12点 睡觉”：日程不跨夜，记成当天 23:59 截止（预览写“23:59 前”）
        var byMidnight = false
    }

    struct Result: Equatable {
        var intent: Intent
        /// 记成修行录时的内容（日记 / 灵感 / 复盘都从这里取）
        var journal: Journal
        var expense: Expense?
        var checkin: Checkin?
        var event: Event?
        /// “改作”里可以换成的类型（不含当前的；第一个是最可能的那个）
        var alternatives: [Intent] = []
        /// 改作打卡时最可能的那项功课（单位对不上、今日已圆满时就是它）
        var suggestedHabit: Int?
        /// 悬停预览签时显示的依据
        var evidence: String = ""
        /// 预览签下的一行提醒（今日已圆满、单位对不上、钟点已过……）
        var notice: String?
        /// 有这句话时不能记（按钮变灰，签上写出原因）
        var problem: String?
        /// 是用户在“改作”里选定的
        var chosen = false
        /// 认这句话时的“今天”
        var today: LocalDay

        var canSave: Bool { problem == nil }

        /// 这句记在哪一天（日期签上显示的那天）：修行录的、账的、打卡的或日程的日子
        var recordDay: LocalDay {
            switch intent {
            case .expense: expense?.day ?? journal.day
            case .checkin: checkin?.day ?? journal.day
            case .event: event?.day ?? journal.day
            case .diary, .note, .review: journal.day
            }
        }

        /// 预览签第一行：此句将入 · 灵石账簿（选定过写“已改作”）
        var headline: String { (chosen ? "已改作 · " : "此句将入 · ") + intent.destination }

        /// 预览签第二行（类别在界面上是可点的小签，这里一并写出，测试用）
        var detail: String {
            switch intent {
            case .diary:
                var parts = ["日记", QuickParse.dayPhrase(journal.day, today: today)]
                if !journal.tags.isEmpty { parts.append(journal.tags.map { "#" + $0 }.joined(separator: " ")) }
                return parts.joined(separator: " · ")
            case .note:
                var parts = ["灵感"]
                if journal.day != today { parts.append(QuickParse.dayPhrase(journal.day, today: today)) }
                if !journal.tags.isEmpty { parts.append(journal.tags.map { "#" + $0 }.joined(separator: " ")) }
                return parts.joined(separator: " · ")
            case .review:
                return journal.day == today ? "日省" : "日省 · " + QuickParse.dayPhrase(journal.day, today: today)
            case .expense:
                guard let e = expense else { return "记账（还没写金额）" }
                return [QuickParse.categoryLabel(e.category), FinanceEngine.money(e.cents), QuickParse.dayPhrase(e.day, today: today)]
                    .joined(separator: " · ")
            case .checkin:
                guard let c = checkin else { return "打卡（还没选功课）" }
                return QuickParse.checkinDetail(c, today: today)
            case .event:
                guard let e = event else { return "日程" }
                return QuickParse.eventDetail(e, today: today)
            }
        }

        /// 记好之后浮窗里那句“已入卷 / 已入账 / 已打卡 · 冥想 10/10 分钟 / 已记入时辰卷 · 10月23日 15:00”
        var savedText: String {
            switch intent {
            case .diary, .note, .review:
                return journal.day == today ? "已入卷" : "已入卷 · 补记 \(journal.day.label(relativeTo: today))"
            case .expense:
                guard let e = expense else { return "已入账" }
                return e.day == today ? "已入账" : "已入账 · \(e.day.label(relativeTo: today))"
            case .checkin:
                guard let c = checkin else { return "已打卡" }
                var text = "\(c.day == today ? "已打卡" : "已补卡") · \(c.title)"
                if let q = c.quantity, let t = c.target {
                    text += " \(QuickParse.number(q))/\(QuickParse.number(t))" + (c.unit.isEmpty ? "" : " \(c.unit)")
                }
                return c.day == today ? text : text + " · \(c.day.label(relativeTo: today))"
            case .event:
                guard let e = event else { return "已记入时辰卷" }
                return "已记入时辰卷 · \(e.day.label(relativeTo: today)) " + (e.byMidnight ? "23:59 前" : (e.start.map { ClockTime.text($0) } ?? "全天"))
            }
        }
    }

    // MARK: 入口

    /// 一句话最多这么多字（QuickParse.length 的数法）；更长的、写了几句或几行的是在写日记，只认前缀与标签，
    /// 不猜记账、打卡、日程（仍可改作）。“跑步 30 分钟，好累”这种后面跟一小句（不超过 shortTail 字）的仍按一句认
    static let sentenceLimit = 30
    static let shortTail = 6
    /// 再长就连改作的备选也不认了（长文每停笔一次都整篇扫一遍，没必要）
    static let scanLimit = 300

    /// 认一句话。choice 是用户在“改作”里选定的（nil 为自动）；day 是日期签上选定的那天（nil 按句中写的），
    /// 选了就当句中写的是这天：日记灵感复盘补记那天、记账记那天、打卡补那天的卡、日程按这天的钟点
    static func parse(_ raw: String, context: Context, choice: Choice? = nil, day: LocalDay? = nil) -> Result {
        let text = normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let (prefix, rest) = stripPrefix(text)
        var scan = Scan(rest, context: context)
        if rest.count <= scanLimit { scan.run() } else { scan.findTags() }
        if let day { scan.pin(day) }
        return Decision(scan: scan, context: context, prefix: prefix ?? (scan.noteMarker ? .note : nil), choice: choice).result()
    }

    /// 日期签上的字：今天 / 昨天 / 前天 / 明天 / 后天，其余写“10月25日”（不是今年的带年份）
    static func daySignLabel(_ day: LocalDay, today: LocalDay) -> String {
        switch today.days(to: day) {
        case 0: "今天"
        case -1: "昨天"
        case -2: "前天"
        case 1: "明天"
        case 2: "后天"
        default: day.label(relativeTo: today)
        }
    }

    /// 字数：汉字与标点一个算一个，一串字母数字（18.5、Uber、14:00）算一个，空白不算
    static func length(_ text: String) -> Int {
        var n = 0
        var inRun = false
        for ch in text {
            if ch.isWhitespace { inRun = false; continue }
            if ch.isASCII, ch.isLetter || ch.isNumber || ".,:$%".contains(ch) {
                if !inRun { n += 1 }
                inRun = true
            } else {
                n += 1
                inRun = false
            }
        }
        return n
    }

    /// 按句读（，。！？；）分开的几句；数字里的逗号（1,200、18,5）不算
    static func clauses(_ text: String) -> [String] {
        let chars = Array(text)
        var parts: [String] = []
        var current = ""
        for (i, ch) in chars.enumerated() {
            let inNumber = ch == "," && i > 0 && i + 1 < chars.count && chars[i - 1].isASCII && chars[i - 1].isNumber
                && chars[i + 1].isASCII && chars[i + 1].isNumber
            if "，。！？；!?;\n".contains(ch) || (ch == "," && !inNumber) {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts.map(tidy).filter { !$0.isEmpty }
    }

    /// 改作锁定之后正文又改了：还是在改那一句（开头两个字没变、原来那句至少还留着一半）就继续锁着；
    /// 全选重写了一句（开头变了）或删得只剩一点，就回到自动认
    static func keepsChoice(original: String, current: String) -> Bool {
        let a = Array(original.trimmingCharacters(in: .whitespacesAndNewlines))
        let b = Array(current.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !a.isEmpty, !b.isEmpty else { return false }
        let head = min(2, a.count)
        guard b.count >= head, Array(b[0..<head]) == Array(a[0..<head]) else { return false }
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return (prefix + suffix) * 2 >= a.count
    }

    /// 日期的说法：今天 / 补记 10月21日 / 10月25日
    static func dayPhrase(_ day: LocalDay, today: LocalDay) -> String {
        if day == today { return "今天" }
        return day < today ? "补记 \(day.label(relativeTo: today))" : day.label(relativeTo: today)
    }

    /// 预览签上的类别名：“待分类消费”写成“待分类”
    static func categoryLabel(_ category: String) -> String { category == "待分类消费" ? "待分类" : category }

    /// 数量的写法：整数不带小数点，其余最多两位小数
    static func number(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e12 { return String(Int(value)) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// 日程那一行：“10月23日 周五 15:00–16:00 · 组会”（不是今年的日子带年份）
    static func eventDetail(_ e: Event, today: LocalDay) -> String {
        let time = e.byMidnight ? "23:59 前" : (e.start.map { ClockTime.range($0, e.end) } ?? "全天")
        let title = e.title.isEmpty ? "日程（还没写做什么）" : e.title
        return "\(e.day.label(relativeTo: today)) \(e.day.weekdayName) \(time) · \(title)"
    }

    static func checkinDetail(_ c: Checkin, today: LocalDay) -> String {
        let unit = c.unit.isEmpty ? "" : " \(c.unit)"
        guard let total = c.quantity, let target = c.target else {
            return c.day == today ? "\(c.title) · 打卡" : "\(c.title) · 打卡 · 补记 \(c.day.label(relativeTo: today))"
        }
        let amount = c.added.map { number($0) + unit } ?? "记满"
        let dayText = c.day == today ? "今日" : c.day.label(relativeTo: today)
        return "\(c.title) · \(amount)（\(dayText) \(number(c.before ?? 0)) → \(number(total)) / \(number(target))\(c.added == nil ? unit : "")）"
    }

    // MARK: 文字预处理

    /// 全角数字、字母与几个符号换成半角（一个字换一个字，长度不变）；中文标点不动
    static func normalize(_ text: String) -> String {
        String(text.map { ch -> Character in
            guard ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first else { return ch }
            switch scalar.value {
            case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
                return UnicodeScalar(scalar.value - 0xFEE0).map(Character.init) ?? ch
            case 0xFF0E: return "."
            case 0xFF03: return "#"
            case 0xFF04: return "$"
            case 0xFFE5: return "¥"
            case 0x3000: return " "
            case 0xFF05: return "%"
            case 0xFF0D: return "-"
            default: return ch
            }
        })
    }

    /// 开头的前缀（去掉后再认）。“#灵感”写在句中任何地方都算灵感，在 Scan.findTags 里认
    private static let prefixes: [(String, Intent)] = [
        ("灵感：", .note), ("灵感:", .note), ("想法：", .note), ("想法:", .note),
        ("复盘：", .review), ("复盘:", .review), ("日省：", .review), ("日省:", .review),
        ("日记：", .diary), ("日记:", .diary),
        ("记账：", .expense), ("记账:", .expense), ("账：", .expense), ("账:", .expense),
        ("打卡：", .checkin), ("打卡:", .checkin), ("打卡 ", .checkin),
        ("日程：", .event), ("日程:", .event), ("提醒我", .event),
    ]

    static func stripPrefix(_ text: String) -> (Intent?, String) {
        for (word, intent) in prefixes where text.hasPrefix(word) {
            return (intent, String(text.dropFirst(word.count)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (nil, text)
    }

    /// 去掉首尾的空白与标点，中间连续的空格并成一个（换行保留）
    static func tidy(_ text: String) -> String {
        var out = ""
        var lastSpace = false
        for ch in text {
            if ch == " " || ch == "\t" {
                if !lastSpace { out.append(" ") }
                lastSpace = true
            } else {
                out.append(ch)
                lastSpace = false
            }
        }
        return out.trimmingCharacters(in: tidyEdges)
    }

    private static let tidyEdges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,、;；:：·-—"))

    // MARK: 词表

    /// 消费类别的关键词（不分大小写）。最长的词优先；“买”太宽，只在别的词都没对上时才用
    static let categoryKeywords: [(category: String, words: [String])] = [
        ("餐饮与外卖", ["早餐", "早饭", "午饭", "午餐", "晚饭", "晚餐", "夜宵", "宵夜", "外卖", "咖啡", "奶茶", "饭", "面", "火锅", "烧烤", "寿司",
                    "拉面", "饺子", "甜品", "饮料", "麦当劳", "肯德基", "早茶", "便当", "食堂",
                    "uber eats", "ubereats", "menulog", "doordash", "饿了么", "美团"]),
        ("超市与食品", ["超市", "买菜", "水果", "零食", "牛奶", "coles", "woolworths", "woolies", "aldi", "iga"]),
        ("交通出行", ["打车", "滴滴", "uber", "出租", "地铁", "公交", "火车", "opal", "加油", "停车", "机票", "高铁"]),
        ("健康与健身", ["药", "看病", "医院", "牙医", "体检", "健身房", "诊所"]),
        ("娱乐", ["电影", "游戏", "唱歌", "ktv", "演出", "门票", "演唱会"]),
        ("教育与学费", ["书", "课", "教材", "学费", "打印"]),
        ("通讯与网络", ["话费", "流量", "宽带"]),
        ("软件与会员", ["会员", "订阅"]),
        ("购物", ["衣服", "鞋", "淘宝", "京东", "amazon", "买"]),
    ]

    /// 说到这些时不自动记账（是进账、转账，不是花出去的钱）；要记仍可“改作 → 记账”
    static let incomeWords = ["收入", "工资", "收到", "进账", "退款", "报销", "转账", "还款", "还钱", "借给", "赚", "奖学金"]

    /// 说到这些时句尾的数不是钱（“体重 65”“气温 25”“考了 92”）：记日记，要记账仍可改作
    static let notMoneyWords = ["体重", "气温", "温度", "体温", "分数", "考了", "考试", "成绩", "排名", "血压", "心率", "血糖", "身高", "腰围"]

    /// 说到这些时数字就是价钱（“雨伞 35 好贵”）：句子带感受也照记账
    static let priceWords = ["贵", "便宜", "划算", "值", "省", "买", "花", "付"]

    /// 带着这些的标题像是感想，不是要去做的事（“周一好累”“周五的组会被取消”）：没写钟点时不自动记成全天日程
    static let feelingWords = ["很", "真", "太", "有点", "有些", "烦", "累", "困", "是", "被", "的", "吗", "呢", "吧", "啊", "呀", "哈", "嘛",
                               "!", "！", "?", "？", "～", "不错", "开心", "难过", "无聊", "安静", "喜欢", "讨厌", "感觉", "觉得", "心情", "又"]

    /// 功课说法前面（3 个字以内）有这些：没做（“没跑步”“今天没冥想”“不想运动”）
    static let negationWords = ["没", "不", "别", "未", "忘了", "懒得", "差点"]
    /// 这些“不”不是没做（“心情不错，跑步了”）
    static let notNegation = ["不错", "不少", "不久", "不过", "不但", "不仅", "不光", "不如", "不同", "不断", "不停"]
    /// 句里有这些：想做、打算做，还没做（“想去跑步”“等会冥想”“今天要跑步”）
    static let intentWords = ["要", "想", "打算", "准备", "计划", "等会", "待会", "一会儿", "晚点", "稍后", "回头"]
    /// 这些“要 / 想”不是打算（“很重要”“感想”“冥想”）；“了一会儿”是做了一阵
    static let notIntent = ["重要", "主要", "只要", "要是", "不要紧", "感想", "理想", "思想", "想法", "回想", "冥想", "没想到", "想到", "了一会儿"]
    /// 时段词与它开始的时刻：说“晚上跑步”而现在还是中午，就是还没做
    static let periodStarts: [(String, Int)] = [
        ("清晨", 5 * 60), ("早上", 5 * 60), ("早晨", 5 * 60), ("上午", 5 * 60), ("中午", 11 * 60), ("午后", 12 * 60), ("下午", 12 * 60),
        ("傍晚", 17 * 60), ("晚上", 18 * 60), ("夜里", 18 * 60), ("夜间", 18 * 60), ("深夜", 21 * 60),
    ]

    /// 数字后面的量词 / 单位：(写法, 规范写法)。量词后的数不当钱；功课的数量按规范写法比对、换算
    static let unitSpellings: [(String, String)] = {
        let list: [(String, String)] = [
            ("分钟", "分钟"), ("分", "分钟"), ("minutes", "分钟"), ("minute", "分钟"), ("mins", "分钟"), ("min", "分钟"),
            ("个小时", "小时"), ("小时", "小时"), ("个钟头", "小时"), ("钟头", "小时"), ("hours", "小时"), ("hour", "小时"),
            ("hrs", "小时"), ("hr", "小时"), ("h", "小时"), ("刻钟", "刻钟"), ("秒钟", "秒"), ("秒", "秒"),
            ("公里", "公里"), ("千米", "公里"), ("km", "公里"), ("米", "米"), ("m", "米"),
            ("步", "步"), ("毫升", "毫升"), ("ml", "毫升"), ("升", "升"),
            ("杯", "杯"), ("页", "页"), ("章", "章"), ("本", "本"), ("字", "字"), ("个", "个"), ("次", "次"), ("集", "集"),
            ("道题", "题"), ("题", "题"), ("篇", "篇"), ("遍", "遍"), ("组", "组"), ("下", "下"), ("首", "首"), ("节", "节"),
            // 下面这些只是量词：不当钱，也不当功课的数量
            ("天", "天"), ("周", "周"), ("星期", "周"), ("岁", "岁"), ("个月", "月"), ("月", "月"), ("年", "年"), ("点", "点"), ("号", "号"),
            ("楼", "楼"), ("层", "层"), ("人", "人"), ("位", "位"), ("名", "名"), ("斤", "斤"), ("公斤", "公斤"), ("kg", "公斤"),
            ("克", "克"), ("度", "度"), ("%", "%"), ("℃", "度"), ("张", "张"), ("件", "件"), ("部", "部"), ("场", "场"), ("门", "门"),
            ("份", "份"), ("瓶", "瓶"), ("包", "包"), ("盒", "盒"), ("袋", "袋"), ("碗", "碗"), ("顿", "顿"), ("条", "条"), ("只", "只"),
            ("双", "双"), ("套", "套"), ("台", "台"), ("辆", "辆"), ("家", "家"), ("局", "局"), ("盘", "盘"), ("把", "把"), ("支", "支"),
            ("课", "课"), ("讲", "讲"), ("期", "期"), ("届", "届"), ("季", "季"), ("倍", "倍"), ("轮", "轮"), ("圈", "圈"), ("口", "口"),
        ]
        // 长的写法先比（“个小时”先于“个”，“min”先于“m”）
        return list.sorted { $0.0.count > $1.0.count }
    }()

    /// 能互相换算的单位：(类, 折合成这类基本单位的倍数)
    static let unitFamilies: [String: (family: String, factor: Double)] = [
        "分钟": ("时长", 1), "小时": ("时长", 60), "刻钟": ("时长", 15), "秒": ("时长", 1.0 / 60),
        "公里": ("距离", 1000), "米": ("距离", 1),
        "毫升": ("容量", 1), "升": ("容量", 1000),
    ]

    /// 只是量词（天、岁、楼……）：这样的数既不是钱，也不当功课的数量
    static let countOnlyUnits: Set<String> = ["天", "周", "岁", "月", "年", "点", "号", "楼", "层", "人", "位", "名", "斤", "公斤", "克", "度", "%",
                                              "张", "件", "部", "场", "门", "份", "瓶", "包", "盒", "袋", "碗", "顿", "条", "只", "双",
                                              "套", "台", "辆", "家", "局", "盘", "把", "支", "课", "讲", "期", "届", "季", "倍", "轮", "圈", "口"]

    /// 功课的单位写成规范写法（“min”→“分钟”、“km”→“公里”）；认不出的原样
    static func canonicalUnit(_ unit: String) -> String {
        let k = unit.trimmingCharacters(in: .whitespaces).lowercased()
        return unitSpellings.first { $0.0 == k }?.1 ?? k
    }

    /// 把 value（单位 from，规范写法）换成功课的单位；换不了时 nil。功课没写单位时照收
    static func convert(_ value: Double, from: String, to habitUnit: String) -> Double? {
        let to = canonicalUnit(habitUnit)
        if to.isEmpty || from == to { return value }
        guard let a = unitFamilies[from], let b = unitFamilies[to], a.family == b.family else { return nil }
        return value * a.factor / b.factor
    }

    // MARK: 中文数字

    static let chineseDigits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    static let chineseUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "万": 10000]

    /// “三十五”→ 35、“十二”→ 12、“一百零五”→ 105、“两千”→ 2000、“二〇二六”→ 2026；认不出 nil
    static func chineseValue(_ chars: [Character]) -> Int? {
        guard !chars.isEmpty else { return nil }
        if chars.allSatisfy({ chineseDigits[$0] != nil }) {
            return chars.count <= 6 ? chars.reduce(0) { $0 * 10 + chineseDigits[$1]! } : nil
        }
        var total = 0, section = 0
        var digit: Int?
        for ch in chars {
            if let d = chineseDigits[ch] {
                digit = d
            } else if let unit = chineseUnits[ch] {
                if unit == 10000 {
                    total += (section + (digit ?? 0)) * unit
                    section = 0
                } else {
                    section += (digit ?? 1) * unit
                }
                digit = nil
            } else {
                return nil
            }
        }
        return total + section + (digit ?? 0)
    }

    // MARK: 扫描到的东西

    enum Period { case dawn, morning, noon, afternoon, evening }

    struct DateHit {
        var range: Range<Int>
        var day: LocalDay
        /// 相对今天的天数（“昨天”−1、“明天”+1）
        var offset: Int
        /// 早 / 晚（“今晚”“明早”）：后面的钟点按它理解
        var period: Period?
        /// 在句首（前面只有空白）
        var leading = false
        /// 日期签上选定的（覆盖了句中写的日子；句中没写日子时 range 是空的）
        var pinned = false
        /// 被日期签盖过之前句中写的那天（句中没写日子、或没被签盖过时为 nil）
        var written: LocalDay?
    }

    struct TimeHit {
        var range: Range<Int>
        /// 开始时刻；bare 为真时是上午的写法，要看现在几点再定（见 Decision.eventGuess）
        var start: Int
        var end: Int?
        /// 没写上午下午、7–11 点（1–6 点按下午，已经换好）
        var bare: Bool
        var text: String
        /// “晚上12点”：日程不跨夜，start 记成 23:59
        var midnight = false
    }

    struct NumberHit {
        var range: Range<Int>
        var value: Double
        /// 阿拉伯数字的原文（记账按 manualCents 再读一遍）；中文数字为 nil
        var arabic: String?
        /// 后面跟的单位（规范写法）
        var unit: String?
        /// 前后有币种（¥ $ 元 块 刀……）
        var money: Bool
    }

    struct HabitHit: Equatable {
        var range: Range<Int>
        /// nil：这个说法能对上不止一项功课
        var index: Int?
        var word: String
        var viaAlias: Bool
        /// 按同类说法对上时是哪一组（HabitAlias.groups 的下标）
        var group: Int? = nil
        /// 按功课名的核心词对上（功课叫“晨读二十分钟”，句子里写“晨读”）
        var core = false
    }

    /// 句子里说到的功课
    enum Mentions: Equatable {
        case none
        /// 只说到一项（可能说了几次）
        case one(HabitHit)
        /// 几项功课各被点了名（按句中先后，功课下标）
        case several([Int])
        /// 有个说法能对上不止一项功课（这个说法原文）
        case ambiguous(String)

        var hit: HabitHit? { if case .one(let h) = self { h } else { nil } }
    }
}

// MARK: - 扫描

extension QuickParse {
    struct Scan {
        let text: String
        let chars: [Character]
        let lower: [Character]
        let context: Context
        var used: [Bool]
        var tags: [String] = []
        var tagRanges: [Range<Int>] = []
        var noteMarker = false
        var dates: [DateHit] = []
        var times: [TimeHit] = []
        var numbers: [NumberHit] = []
        var habitHits: [HabitHit] = []
        var category: (category: String, word: String, range: Range<Int>)?
        var income = false

        init(_ text: String, context: Context) {
            self.text = text
            chars = Array(text)
            lower = chars.map { ch in
                let l = ch.lowercased()
                return l.count == 1 ? Character(l) : ch
            }
            self.context = context
            used = Array(repeating: false, count: chars.count)
        }

        mutating func run() {
            findTags()
            findDates()
            findTimes()
            findNumbers()
            findCategory()
            findHabits()
            income = incomeWords.contains { text.contains($0) }
        }

        // MARK: 小工具

        func matches(_ word: String, at i: Int) -> Bool { matches(Array(word.lowercased()), at: i) }

        func matches(_ w: [Character], at i: Int) -> Bool {
            guard i >= 0, i + w.count <= lower.count, !w.isEmpty else { return false }
            for (k, ch) in w.enumerated() where lower[i + k] != ch { return false }
            return true
        }

        func occurrences(of word: String) -> [Range<Int>] {
            let w = Array(word.lowercased())
            let n = w.count
            guard n > 0, n <= chars.count else { return [] }
            return (0...(chars.count - n)).filter { matches(w, at: $0) }.map { $0..<($0 + n) }
        }

        mutating func use(_ range: Range<Int>) { for i in range where i < used.count { used[i] = true } }

        /// 日期签选了某天：句中写了日子的，把第一个日子换成这天（“今晚七点半”的“晚”照旧）；没写的当句首写了这天。
        /// 选今天而句中没写日子：与不选一样
        mutating func pin(_ day: LocalDay) {
            let offset = context.today.days(to: day)
            if dates.isEmpty {
                guard offset != 0 else { return }
                dates.append(DateHit(range: 0..<0, day: day, offset: offset, period: nil, leading: true, pinned: true))
            } else {
                dates[0].written = dates[0].day
                dates[0].day = day
                dates[0].offset = offset
                dates[0].pinned = true
            }
        }

        func char(_ i: Int) -> Character? { i >= 0 && i < chars.count ? chars[i] : nil }

        static func isDigit(_ c: Character?) -> Bool { c.map { $0.isASCII && $0.isNumber } ?? false }
        static func isLatin(_ c: Character?) -> Bool { c.map { $0.isASCII && $0.isLetter } ?? false }
        static func isChineseNumeral(_ c: Character?) -> Bool {
            c.map { QuickParse.chineseDigits[$0] != nil || QuickParse.chineseUnits[$0] != nil } ?? false
        }
        static let connectors: Set<Character> = ["到", "至", "-", "–", "—", "~", "～"]
        static let separators: Set<Character> = ["，", ",", "、", "。", ";", "；", ":", "：", "!", "！", "?", "？", "~", "～", "."]

        /// 跳过空格（不跨行）
        func skipSpaces(_ i: Int) -> Int {
            var j = i
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            return j
        }

        /// 去掉这些范围后剩下的字（空白合并成一个空格，首尾的空白与标点去掉）
        func remaining(removing ranges: [Range<Int>]) -> String {
            var drop = Array(repeating: false, count: chars.count)
            for r in ranges { for i in r where i < drop.count { drop[i] = true } }
            return QuickParse.tidy(String(chars.indices.filter { !drop[$0] }.map { chars[$0] }))
        }

        // MARK: 标签

        /// #词 进标签（“#灵感”不是标签，是“记成灵感”）；纯数字的不算（“#1”）
        mutating func findTags() {
            let stops = Set(" \t\n#,，、;；。.!！?？:：()（）《》<>“”\"'‘’[]【】")
            var i = 0
            while i < chars.count {
                guard chars[i] == "#" else { i += 1; continue }
                var j = i + 1
                while j < chars.count, !stops.contains(chars[j]) { j += 1 }
                let word = String(chars[(i + 1)..<j])
                if word == "灵感" {
                    noteMarker = true
                    use(i..<j)
                    tagRanges.append(i..<j)
                } else if !word.isEmpty, !word.allSatisfy(\.isNumber) {
                    if !tags.contains(word) { tags.append(word) }
                    use(i..<j)
                    tagRanges.append(i..<j)
                }
                i = max(j, i + 1)
            }
        }

        // MARK: 日期

        static let relativeDays: [(String, Int, Period?)] = [
            ("大后天", 3, nil), ("大前天", -3, nil), ("后天", 2, nil), ("前天", -2, nil),
            ("明天", 1, nil), ("明日", 1, nil), ("明早", 1, .morning), ("明晨", 1, .morning), ("明晚", 1, .evening),
            ("今天", 0, nil), ("今日", 0, nil), ("今早", 0, .morning), ("今晨", 0, .morning), ("今晚", 0, .evening), ("今夜", 0, .evening),
            ("昨天", -1, nil), ("昨日", -1, nil), ("昨晚", -1, .evening), ("昨夜", -1, .evening),
        ]

        static let weekdayChars: [Character: Int] = ["一": 0, "二": 1, "三": 2, "四": 3, "五": 4, "六": 5, "日": 6, "天": 6, "七": 6,
                                                     "1": 0, "2": 1, "3": 2, "4": 3, "5": 4, "6": 5, "7": 6]
        /// “周一共”“这周一直”：“一”在这里是“一共 / 一直”的“一”，不是星期一
        static let notWeekday: Set<Character> = ["共", "直", "起", "样", "定", "般", "些", "下", "点", "次", "切", "会", "边", "路", "天", "周"]
        /// “周天”后面跟着这些：是“这周天气”“这周天天”，不是星期天
        static let notSunday: Set<Character> = ["气", "天", "空"]
        /// “上周”前面是这些字时，“上”属于前一个词（马上、早上、晚上、楼上……）
        static let notLastWeek: Set<Character> = ["马", "早", "晚", "楼", "网", "线", "路", "身", "手", "桌", "晨"]

        mutating func findDates() {
            var i = 0
            while i < chars.count {
                guard !used[i], var hit = date(at: i) else { i += 1; continue }
                hit.leading = chars[0..<i].allSatisfy(\.isWhitespace)
                dates.append(hit)
                use(hit.range)
                i = hit.range.upperBound
            }
        }

        private func date(at i: Int) -> DateHit? {
            let today = context.today
            func hit(_ length: Int, _ day: LocalDay, _ period: Period? = nil) -> DateHit {
                DateHit(range: i..<(i + length), day: day, offset: today.days(to: day), period: period)
            }
            for (word, offset, period) in Self.relativeDays where matches(word, at: i) {
                return hit(word.count, today.adding(days: offset), period)
            }
            // 下周一 / 下星期三 / 这周五 / 本周日 / 上周五 / 上个星期三 / 上上周日 / 周五 / 星期六 / 礼拜天 / 周末
            var j = i
            // 0：没说哪周（已过的星期按下周）；1：下周；2：下下周；-1：明说了这周；-2：上周；-3：上上周
            var week = 0
            if matches("下下", at: j) { j += 2; week = 2 } else if matches("下个", at: j) { j += 2; week = 1 } else if matches("下", at: j) { j += 1; week = 1 }
            else if matches("上上", at: j) { j += 2; week = -3 } else if matches("上个", at: j) { j += 2; week = -2 }
            else if matches("上", at: j) { j += 1; week = -2 }
            else if matches("这个", at: j) { j += 2; week = -1 } else if matches("这", at: j) || matches("本", at: j) { j += 1; week = -1 }
            // “马上周末了”“早上周会”：“上”是前一个词的字
            if week <= -2, let before = char(i - 1), Self.notLastWeek.contains(before) {
                j = i
                week = 0
            }
            for marker in ["星期", "礼拜", "周"] where matches(marker, at: j) {
                let k = j + marker.count
                var weekday: Int?
                if let c = char(k), let w = Self.weekdayChars[c], !(c == "一" && char(k + 1).map(Self.notWeekday.contains) == true),
                   // “这周天气不错”“这周天天加班”：“周天”后面紧跟气 / 天 / 空，不是星期天
                   !(c == "天" && char(k + 1).map(Self.notSunday.contains) == true) {
                    weekday = w
                } else if matches("末", at: k) {
                    weekday = 5
                }
                guard let weekday else { break }
                // “一周一次”“每周五”“两周”：前面是数字或“每”的不算日期
                if week == 0, let before = char(i - 1), before == "每" || Self.isChineseNumeral(before) || Self.isDigit(before) { return nil }
                var day = today.mondayOfWeek.adding(days: weekday)
                if week > 0 { day = day.adding(days: 7 * week) }
                else if week <= -2 { day = day.adding(days: 7 * (week + 1)) }
                else if week == 0, day < today { day = day.adding(days: 7) }
                return hit(k + 1 - i, day)
            }
            if let explicit = monthDay(at: i, today: today) { return explicit }
            // X号（本月；已过的按下月）
            if let (value, end) = smallNumber(at: i), char(end) == "号", (1...31).contains(value) {
                let notDates: Set<Character> = ["楼", "线", "床", "房", "门", "位", "车", "机", "店", "馆", "厅", "窗", "口", "桌", "码", "球", "字", "院", "台", "坑"]
                if let next = char(end + 1), notDates.contains(next) { return nil }
                if let before = char(i - 1), before == "月" || Self.isDigit(before) || Self.isChineseNumeral(before) { return nil }
                var first = today.firstOfMonth
                for _ in 0..<2 {
                    let day = LocalDay(year: first.year, month: first.month, day: value)
                    if day.month == first.month, day >= today { return hit(end + 1 - i, day) }
                    first = first.adding(days: 32).firstOfMonth
                }
                return nil
            }
            return nil
        }

        /// 0–9999 的小数字（阿拉伯或中文，中文须以数字或“十”开头），返回值与结束位置
        func smallNumber(at i: Int) -> (Int, Int)? {
            var j = i
            if Self.isDigit(char(i)) {
                while Self.isDigit(char(j)) { j += 1 }
                guard j - i <= 4, let v = Int(String(chars[i..<j])) else { return nil }
                return (v, j)
            }
            guard let c = char(i), QuickParse.chineseDigits[c] != nil || c == "十" else { return nil }
            while Self.isChineseNumeral(char(j)) { j += 1 }
            guard let v = QuickParse.chineseValue(Array(chars[i..<j])), v < 10000 else { return nil }
            return (v, j)
        }

        /// X月X日 / X月X号 / 2026年10月25日 / 十月二十五日；没写年份、比今天早半年以上的按明年
        private func monthDay(at i: Int, today: LocalDay) -> DateHit? {
            var j = i
            var year: Int?
            if let (y, end) = smallNumber(at: j), char(end) == "年", (2000...2100).contains(y) {
                year = y
                j = end + 1
            }
            guard let (m, mEnd) = smallNumber(at: j), char(mEnd) == "月", (1...12).contains(m),
                  let (d, dEnd) = smallNumber(at: mEnd + 1), (1...31).contains(d) else { return nil }
            var end = dEnd
            if let c = char(end), c == "日" || c == "号" { end += 1 }
            var day = LocalDay(year: year ?? today.year, month: m, day: d)
            guard day.month == m else { return nil }
            if year == nil, today.days(to: day) < -180 {
                day = LocalDay(year: today.year + 1, month: m, day: d)
                guard day.month == m else { return nil }
            }
            return DateHit(range: i..<end, day: day, offset: today.days(to: day), period: nil)
        }

        // MARK: 钟点

        static let periodWords: [(String, Period)] = [
            ("凌晨", .dawn), ("清晨", .morning), ("早上", .morning), ("早晨", .morning), ("上午", .morning), ("中午", .noon),
            ("午后", .afternoon), ("下午", .afternoon), ("傍晚", .afternoon), ("晚上", .evening), ("夜里", .evening),
            ("夜间", .evening), ("深夜", .evening), ("早", .morning), ("晚", .evening),
        ]

        mutating func findTimes() {
            var i = 0
            while i < chars.count {
                guard !used[i], let hit = time(at: i) else { i += 1; continue }
                times.append(hit)
                use(hit.range)
                i = hit.range.upperBound
            }
        }

        /// 紧挨在 i 前面（中间只隔空格）的“今晚 / 明早”这类日期带出的时段
        private func periodFromDate(before i: Int) -> Period? {
            var j = i - 1
            while j >= 0, chars[j] == " " { j -= 1 }
            return dates.first { $0.range.upperBound == j + 1 }?.period
        }

        /// 时段词 + 钟点，或钟点本身（从这个位置开始）
        private func periodAndClock(at i: Int) -> (period: Period?, clock: Clock, start: Int)? {
            for (word, p) in Self.periodWords where matches(word, at: i) {
                // 时段词后面要紧跟钟点才算（“中午和同学”“晚饭”不算）
                let k = skipSpaces(i + word.count)
                guard let c = clock(at: k) else { return nil }
                return (p, c, k)
            }
            guard let c = clock(at: i) else { return nil }
            return (nil, c, i)
        }

        private func time(at i: Int) -> TimeHit? {
            if Self.isDigit(char(i)) || Self.isChineseNumeral(char(i)) {
                // 从数字的头上开始认（“十七点”不从“七”认起）；紧挨字母的不认（“A3点”）
                if Self.isDigit(char(i - 1)) || Self.isChineseNumeral(char(i - 1)) || Self.isLatin(char(i - 1)) { return nil }
                // 前面是时段词而没认成钟点（“晚上12点”）：不再单把数字当钟点
                var b = i - 1
                while b >= 0, chars[b] == " " { b -= 1 }
                if b >= 0, !dates.contains(where: { $0.range.contains(b) }),
                   Self.periodWords.contains(where: { matches($0.0, at: b + 1 - $0.0.count) }) { return nil }
            }
            guard let (ownPeriod, first, _) = periodAndClock(at: i) else { return nil }
            let period = ownPeriod ?? periodFromDate(before: i)
            // 没写时段的中文“一点”多是“有一点累”的一点：只在它单独成词（前面是句首或空格、后面是空格或带了分钟）时当钟点
            if period == nil, !first.arabic, first.hour == 1, !first.colon {
                let alone = i == 0 || char(i - 1)?.isWhitespace == true
                let after = char(first.end)
                guard alone, first.minutes > 0 || after == nil || after?.isWhitespace == true else { return nil }
            }
            var start = first.minute(with: period)
            var end: Int?
            var upper = first.end
            // 到 / 至 / - / ~ 接一个结束时刻：“下午3点到5点”“14:00-16:00”“3-5点”
            let k = skipSpaces(first.end)
            if let c = char(k), Self.connectors.contains(c), let (p2, second, _) = periodAndClock(at: skipSpaces(k + 1)),
               second.hasPoint || second.colon {
                var e = second.minute(with: p2 ?? period)
                if !first.hasPoint, !first.colon, p2 != nil || period != nil {
                    // “下午3-5点”：前一个数跟着时段走
                    start = first.minute(with: p2 ?? period)
                }
                if e <= start, e + 12 * 60 > start, e + 12 * 60 < 24 * 60 { e += 12 * 60 }
                if e > start, e <= 24 * 60 {
                    end = min(e, 23 * 60 + 59)
                    upper = second.end
                }
            }
            // 单独一个数（“3-5”而没有“点”）不是钟点
            if !first.hasPoint, !first.colon, end == nil { return nil }
            // “晚上12点 睡觉”：日程不跨夜，按当天 23:59 截止
            if start == 24 * 60, end == nil {
                return TimeHit(range: i..<upper, start: 23 * 60 + 59, end: nil, bare: false, text: String(chars[i..<upper]), midnight: true)
            }
            guard start < 24 * 60 else { return nil }
            // 没写时段：1–6 点按下午；7–11 点留给 Decision 看现在几点再定；12–23 点原样
            var bare = false
            if period == nil, !first.colon24, (1...11).contains(start / 60) {
                if start / 60 <= 6 {
                    start += 12 * 60
                    if let e = end, e < start { end = min(e + 12 * 60, 23 * 60 + 59) }
                } else {
                    bare = true
                }
            }
            return TimeHit(range: i..<upper, start: start, end: end, bare: bare, text: String(chars[i..<upper]))
        }

        struct Clock {
            var hour: Int
            var minutes: Int
            var end: Int
            var arabic: Bool
            var colon: Bool
            /// 写的是“点 / 时”
            var hasPoint: Bool
            /// 13:00 这类一看就是 24 小时制的
            var colon24: Bool { colon && hour >= 13 }

            func minute(with period: Period?) -> Int {
                var h = hour
                switch period {
                case .dawn: if h == 12 { h = 0 }
                case .morning, .none: break
                case .noon: if h <= 3 { h += 12 }
                case .afternoon: if h < 12 { h += 12 }
                case .evening: if h < 12 { h += 12 } else if h == 12 { h = 24 }
                }
                return h * 60 + minutes
            }
        }

        /// 一个钟点：H点[半|一刻|三刻|整|钟|M分]、H:MM；“3-5点”的“3”也返回（hasPoint、colon 都为假）
        func clock(at i: Int) -> Clock? {
            guard let (h, hEnd) = smallNumber(at: i), h <= 24 else { return nil }
            let arabic = Self.isDigit(char(i))
            var j = hEnd
            if arabic, let c = char(j), c == ":" || c == "：", Self.isDigit(char(j + 1)), Self.isDigit(char(j + 2)), !Self.isDigit(char(j + 3)),
               let m = Int(String(chars[(j + 1)...(j + 2)])), m < 60, h < 24 {
                return Clock(hour: h, minutes: m, end: j + 3, arabic: true, colon: true, hasPoint: false)
            }
            if char(j) == " ", let c = char(j + 1), c == "点" || c == "點" { j += 1 }
            guard let c = char(j), c == "点" || c == "點" || c == "时" else {
                if let c = char(skipSpaces(j)), Self.connectors.contains(c), h < 24 {
                    return Clock(hour: h, minutes: 0, end: j, arabic: arabic, colon: false, hasPoint: false)
                }
                return nil
            }
            guard h <= 23 else { return nil }
            j += 1
            var minutes = 0
            if matches("半", at: j) { minutes = 30; j += 1 }
            else if matches("一刻", at: j) { minutes = 15; j += 2 }
            else if matches("三刻", at: j) { minutes = 45; j += 2 }
            else if matches("整", at: j) || matches("钟", at: j) { j += 1 }
            else if let (m, mEnd) = smallNumber(at: j) {
                // “三点五公里”“3点5小时”：是小数，不是钟点
                if !matches("分", at: mEnd) || matches("分钟", at: mEnd), unit(at: mEnd) != nil { return nil }
                guard m < 60 else { return nil }
                minutes = m
                j = mEnd
                if matches("分", at: j), !matches("分钟", at: j) { j += 1 }
            }
            if matches("赞", at: j) { return nil }   // “3点赞”
            return Clock(hour: h, minutes: minutes, end: j, arabic: arabic, colon: false, hasPoint: true)
        }

        // MARK: 数字、金额、数量

        static let currencyPrefixes = ["au$", "a$", "us$", "aud", "rmb", "$", "¥"]
        static let currencySuffixes = ["块钱", "块", "元", "刀", "澳元", "澳币", "美元", "美金", "人民币", "rmb", "aud", "dollars", "dollar", "bucks"]

        mutating func findNumbers() {
            var i = 0
            while i < chars.count {
                guard !used[i], let hit = number(at: i) else { i += 1; continue }
                numbers.append(hit)
                use(hit.range)
                i = hit.range.upperBound
            }
        }

        /// 单位：最多隔一个空格，最长的写法优先；英文单位后面不能再跟字母
        func unit(at i: Int) -> (String, Int)? {
            let j = skipSpaces(i)
            guard j < chars.count, j - i <= 1 else { return nil }
            for (spelling, canonical) in QuickParse.unitSpellings where matches(spelling, at: j) {
                let end = j + spelling.count
                if Self.isLatin(spelling.first), Self.isLatin(char(end)) { continue }
                return (canonical, end)
            }
            return nil
        }

        /// 币种写在数字后面（最多隔一个空格）。“块”后面跟着别的字（“一块蛋糕”）是量词，不是钱
        func currencySuffix(at i: Int) -> Int? {
            let j = skipSpaces(i)
            guard j - i <= 1 else { return nil }
            for s in Self.currencySuffixes where matches(s, at: j) {
                let end = j + s.count
                if Self.isLatin(s.first), Self.isLatin(char(end)) { continue }
                if s == "块", let next = char(end), !(next.isWhitespace || Self.separators.contains(next) || Self.isDigit(next) || next == "的") {
                    return nil
                }
                return end
            }
            return nil
        }

        /// 数字前面说了“花了 / 付了 / 一共”：后面的数是钱
        static let moneyVerbs = ["一共花了", "总共花了", "共花了", "花了", "花费", "付了", "一共", "总共", "交了", "充了", "充值", "花"]

        /// i 前面（隔着空格）是不是这些词之一
        func preceded(by words: [String], at i: Int) -> Bool {
            var b = i - 1
            while b >= 0, chars[b] == " " { b -= 1 }
            return words.contains { matches($0, at: b + 1 - $0.count) }
        }

        private func number(at i: Int) -> NumberHit? {
            // 前面紧挨字母或数字的不读（“iPhone15”“M3”）；“第 3”是名次，不是数
            if Self.isLatin(char(i - 1)) || Self.isDigit(char(i - 1)) || Self.isChineseNumeral(char(i - 1)) { return nil }
            if preceded(by: ["第"], at: i) { return nil }
            var money = false
            var j = i
            // 币种在前：$18、A$18、¥18、AUD 18
            for p in Self.currencyPrefixes where matches(p, at: i) {
                let k = skipSpaces(i + p.count)
                if Self.isDigit(char(k)), !Self.isLatin(char(i + p.count)) || p.last == "$" { money = true; j = k }
                break
            }
            if Self.isLatin(char(i)), !money { return nil }
            var value: Double
            var arabic: String?
            if Self.isDigit(char(j)) {
                var k = j
                while Self.isDigit(char(k)) { k += 1 }
                // 千分位 1,200
                var grouped = false
                while char(k) == ",", Self.isDigit(char(k + 1)), Self.isDigit(char(k + 2)), Self.isDigit(char(k + 3)), !Self.isDigit(char(k + 4)) {
                    k += 4
                    grouped = true
                }
                if char(k) == ".", Self.isDigit(char(k + 1)) {
                    k += 1
                    while Self.isDigit(char(k)) { k += 1 }
                } else if !grouped, char(k) == ",", Self.isDigit(char(k + 1)), !Self.isDigit(char(k + 3)) {
                    // 18,5 / 18,50：逗号当小数点（与 manualCents 一致）
                    k += Self.isDigit(char(k + 2)) ? 3 : 2
                }
                let raw = String(chars[j..<k])
                let plain = grouped ? raw.replacingOccurrences(of: ",", with: "") : raw.replacingOccurrences(of: ",", with: ".")
                guard let v = Double(plain) else { return nil }
                value = v
                arabic = raw
                j = k
                // 后面紧跟字母（“15pro”“3d”）而又不是单位、币种：不读
                if Self.isLatin(char(j)), unit(at: j) == nil, currencySuffix(at: j) == nil { return nil }
            } else if !money, let c = char(j), QuickParse.chineseDigits[c] != nil || c == "十" || c == "半" {
                var k = j
                if c == "半" {
                    value = 0.5
                    k += 1
                } else {
                    while Self.isChineseNumeral(char(k)) { k += 1 }
                    guard let v = QuickParse.chineseValue(Array(chars[j..<k])) else { return nil }
                    value = Double(v)
                }
                let word = String(chars[j..<k])
                // 中文数字后面必须跟单位、币种（或“个半”）才算数：单说“一”“三”不当数字
                guard unit(at: k) != nil || currencySuffix(at: k) != nil || matches("个半", at: k) else { return nil }
                // “一下”“一点”“一些”“十分”：是口头语，不是数量
                if word == "一", ["下", "点", "些", "分"].contains(where: { matches($0, at: k) }), !matches("分钟", at: k) { return nil }
                if word == "十", matches("分", at: k), !matches("分钟", at: k) { return nil }
                j = k
            } else {
                return nil
            }
            // 千 / 万：8千步、1.2万步、1.2 万步（中间最多隔一个空格）
            let w = skipSpaces(j)
            if w - j <= 1, matches("千", at: w) || matches("万", at: w), unit(at: w + 1) != nil || currencySuffix(at: w + 1) != nil {
                value *= matches("千", at: w) ? 1000 : 10000
                j = w + 1
                arabic = nil
            }
            // 一个半小时、1个半小时
            if matches("个半", at: j), let (u, end) = unit(at: j + 2), QuickParse.unitFamilies[u] != nil {
                return NumberHit(range: i..<end, value: value + 0.5, arabic: nil, unit: u, money: false)
            }
            if !money, let end = currencySuffix(at: j) {
                var finish = end
                // 5块5、18块50：“块”后面的一两位是角分
                if arabic != nil, matches("块", at: skipSpaces(j)), Self.isDigit(char(end)) {
                    var k = end
                    while Self.isDigit(char(k)), k - end < 2 { k += 1 }
                    if !Self.isDigit(char(k)), let d = Double("0." + String(chars[end..<k])) {
                        value += d
                        arabic = QuickParse.number(value)
                        finish = k
                    }
                }
                return NumberHit(range: i..<finish, value: value, arabic: arabic, unit: nil, money: true)
            }
            if money { return NumberHit(range: i..<j, value: value, arabic: arabic, unit: nil, money: true) }
            if let (u, end) = unit(at: j) { return NumberHit(range: i..<end, value: value, arabic: arabic, unit: u, money: false) }
            if arabic != nil, preceded(by: Self.moneyVerbs, at: i) { return NumberHit(range: i..<j, value: value, arabic: arabic, unit: nil, money: true) }
            // 中文数字只在带单位时才算（上面已拦），走到这里的都是阿拉伯数字
            return NumberHit(range: i..<j, value: value, arabic: arabic, unit: nil, money: false)
        }

        // MARK: 类别与功课

        mutating func findCategory() {
            var best: (category: String, word: String, range: Range<Int>)?
            var fallback: (category: String, word: String, range: Range<Int>)?
            for (category, words) in QuickParse.categoryKeywords {
                for word in words {
                    for r in occurrences(of: word) where !tagRanges.contains(where: { $0.overlaps(r) }) {
                        if word == "买" {
                            if fallback == nil { fallback = (category, word, r) }
                            continue
                        }
                        if let b = best, b.word.count > word.count || (b.word.count == word.count && b.range.lowerBound <= r.lowerBound) { continue }
                        best = (category, word, r)
                    }
                }
            }
            category = best ?? fallback
        }

        static let thingSuffixes: Set<Character> = ["机", "鞋", "池", "馆", "卡", "场", "拍", "垫", "服", "衣", "裤", "会", "课", "班", "店",
                                                    "房", "室", "包", "杯", "瓶", "器", "证", "费", "票", "群", "圈"]

        mutating func findHabits() {
            let habits = context.habits
            guard !habits.isEmpty else { return }
            let units = Set(numbers.compactMap(\.unit))
            func free(_ r: Range<Int>) -> Bool { !tagRanges.contains { $0.overlaps(r) } }
            let whole = QuickParse.tidy(text).lowercased()
            for (index, habit) in habits.enumerated() {
                let key = HabitAlias.key(habit.title)
                // 一个字的功课名太容易撞上（“读”“跑”），只在整句就是它时才认
                guard key.count >= 2 || (!key.isEmpty && key == whole) else { continue }
                for r in occurrences(of: key) where free(r) {
                    habitHits.append(HabitHit(range: r, index: index, word: String(chars[r]), viaAlias: false))
                }
                // 功课名带着数量、括号（“晨读二十分钟”“早睡（23:30 前）”）：说核心词“晨读”也认
                if let core = HabitAlias.coreKey(habit.title) {
                    for r in occurrences(of: core) where free(r) {
                        habitHits.append(HabitHit(range: r, index: index, word: String(chars[r]), viaAlias: false, core: true))
                    }
                }
            }
            let titles = habits.map(\.title)
            let titleGroups = titles.map(HabitAlias.groups(ofTitle:))
            for (g, group) in HabitAlias.groups.enumerated() {
                let owners = titleGroups.indices.filter { titleGroups[$0].contains(g) }
                guard !owners.isEmpty else { continue }
                var words = group.words
                if !group.weakUnits.isDisjoint(with: units), group.weakNeeds.isEmpty || group.weakNeeds.contains(where: { text.contains($0) }) {
                    words += group.weak
                }
                for word in words {
                    for r in occurrences(of: word) where free(r) {
                        // 同组对上几项功课：“撸铁”找「力量训练」、“跑步”找名字就是“运动”的那项，还挑不出才算分不清
                        let index = HabitAlias.preferred(word: word, group: g, owners: owners, titles: titles)
                        habitHits.append(HabitHit(range: r, index: index, word: String(chars[r]), viaAlias: true, group: g))
                    }
                }
            }
            // 后面紧跟“机、鞋、馆、会……”的是个东西或场合，不是做了这件事（跑步机、游泳馆、读书会、运动会）
            let chars = self.chars
            habitHits.removeAll { h in h.range.upperBound < chars.count && Self.thingSuffixes.contains(chars[h.range.upperBound]) }
            // 落在更长的消费词里的不算（“健身房”里的“健身”）
            if let c = category {
                habitHits.removeAll { h in
                    c.range.lowerBound <= h.range.lowerBound && h.range.upperBound <= c.range.upperBound && c.range.count > h.range.count
                }
            }
        }

        /// 句子里说到了哪些功课。叠在一起的命中（“喝水”既是功课名又是同类说法）是同一处说法：取最长的，
        /// 同样长时功课名优先于核心词、核心词优先于同类说法。不叠的几处各指一项功课时是“说到了几项”，
        /// 某一处说法能对上几项而挑不出时是“分不清”
        func habitMentions() -> Mentions {
            guard !habitHits.isEmpty else { return .none }
            let sorted = habitHits.sorted { ($0.range.lowerBound, -$0.range.count) < ($1.range.lowerBound, -$1.range.count) }
            var clusters: [[HabitHit]] = []
            var upper = -1
            for h in sorted {
                if h.range.lowerBound < upper, !clusters.isEmpty {
                    clusters[clusters.count - 1].append(h)
                    upper = max(upper, h.range.upperBound)
                } else {
                    clusters.append([h])
                    upper = h.range.upperBound
                }
            }
            func rank(_ h: HabitHit) -> Int { h.viaAlias ? 0 : (h.core ? 1 : 2) }
            var picks: [HabitHit] = []
            var unclear: String?
            for cluster in clusters {
                let longest = cluster.map(\.range.count).max() ?? 0
                let tier = cluster.filter { $0.range.count == longest }
                let best = tier.map(rank).max() ?? 0
                let top = tier.filter { rank($0) == best }
                if Set(top.map { $0.index ?? -1 }).count == 1, let only = top.first, only.index != nil {
                    picks.append(only)
                } else if unclear == nil, let first = top.first {
                    unclear = String(chars[first.range])
                }
            }
            var seen: [Int] = []
            for p in picks { if let i = p.index, !seen.contains(i) { seen.append(i) } }
            if seen.count >= 2 { return .several(seen) }
            if let unclear { return .ambiguous(unclear) }
            // 同一项说了几次：取最长的那处（“晨读二十分钟”的整名优先于“晨读”）
            guard let first = picks.max(by: { ($0.range.count, rank($0)) < ($1.range.count, rank($1)) }) else { return .none }
            return .one(first)
        }
    }
}

// MARK: - 判定

extension QuickParse {
    struct Decision {
        let scan: Scan
        let context: Context
        let prefix: Intent?
        let choice: Choice?

        var today: LocalDay { context.today }
        var date: DateHit? { scan.dates.first }

        func text(_ r: Range<Int>) -> String { String(scan.chars[r]) }

        /// 可以不管的字：空白、标点、日期、标签
        func ignorable(_ i: Int) -> Bool {
            scan.chars[i].isWhitespace || Scan.separators.contains(scan.chars[i])
                || scan.tagRanges.contains { $0.contains(i) } || scan.dates.contains { $0.range.contains(i) }
        }

        /// 带币种的金额
        var strongMoney: NumberHit? { scan.numbers.first { $0.money } }

        /// 句首或句尾的裸数字（前面或后面只有空白、标点、日期、标签）
        var bareAmount: NumberHit? {
            scan.numbers.first { n in
                guard n.unit == nil, !n.money, n.arabic != nil else { return false }
                return (0..<n.range.lowerBound).allSatisfy(ignorable) || (n.range.upperBound..<scan.chars.count).allSatisfy(ignorable)
            }
        }

        /// 像钱的数：带币种的，或没跟量词的阿拉伯数字（紧跟在英文词后面的“iPhone 15”是型号，不算）
        var moneyLike: [NumberHit] {
            scan.numbers.filter { n in
                if n.money { return true }
                guard n.unit == nil, n.arabic != nil else { return false }
                var b = n.range.lowerBound - 1
                while b >= 0, scan.chars[b] == " " { b -= 1 }
                return !(b >= 0 && Scan.isLatin(scan.chars[b]))
            }
        }

        /// 改作记账时用的金额：一句里有两笔钱时按第一笔；否则带币种的、句首句尾的，再不然句中任一个没跟量词的数
        var anyAmount: NumberHit? {
            let likely = moneyLike
            if likely.count >= 2 { return likely.first }
            return strongMoney ?? bareAmount ?? scan.numbers.first { $0.unit == nil && $0.arabic != nil }
        }

        func cents(_ n: NumberHit) -> Int? {
            if let raw = n.arabic, let c = try? FinanceEngine.manualCents(raw) { return c }
            // 中文数字、“8千”这类：先看范围再换成整数（太大的数换整数会出错）
            guard n.arabic == nil, n.value.isFinite, n.value > 0, n.value < 1_000_000 else { return nil }
            return Int((n.value * 100).rounded())
        }

        func amountText(_ n: NumberHit) -> String { n.arabic ?? QuickParse.number(n.value) }

        /// 写了“了”（不算“了解”“为了”“除了”）：在记已经发生的事
        func narrative(_ title: String) -> Bool {
            var t = title
            for word in ["了解", "为了", "除了", "了不起", "受不了", "少不了"] { t = t.replacingOccurrences(of: word, with: "") }
            return t.contains("了")
        }

        /// 像感想不像要做的事（“好累”“早上很安静”“组会被取消”）
        func soundsLikeFeeling(_ t: String) -> Bool {
            var s = t
            for word in ["好友", "好好"] { s = s.replacingOccurrences(of: word, with: "") }
            return s.contains("好") || QuickParse.feelingWords.contains { s.contains($0) }
        }

        /// 裸数字像年份（2026）：没说是买了什么时不当钱
        func looksLikeYear(_ n: NumberHit) -> Bool {
            // 先按小数比范围再说：订单号这类 19 位以上的长数字换成整数会溢出，直接让应用崩溃
            n.money == false && n.value.rounded() == n.value && (1900.0...2100.0).contains(n.value) && scan.category == nil
        }

        // MARK: 日程

        struct EventGuess {
            var event: Event
            /// 钟点已过（或日子已过 / 今天全天 / 写了“了”）：不自动当日程
            var passed: Bool
            var timed: Bool
            var evidence: String
            /// 没写钟点、标题太长或像感想（“周一好累”）：不自动记成全天日程
            var unsure = false
        }

        /// 有日期或钟点时，这句话作为日程的样子。forced：用户选定了日程（没写上午下午、已过的 7–11 点按晚上）
        func eventGuess(forced: Bool) -> EventGuess? {
            let time = scan.times.first
            guard time != nil || date != nil else { return nil }
            let day = date?.day ?? today
            var evidence: [String] = []
            if let date { evidence.append("\(dateWord(date))→ \(date.day.label(relativeTo: today))") }
            var title = eventTitle()
            guard let time else {
                let raw = scan.remaining(removing: eventRemovals())
                let unsure = QuickParse.length(title) > 12 || soundsLikeFeeling(raw)
                return EventGuess(event: Event(day: day, start: nil, end: nil, title: title),
                                  passed: day <= today || narrative(title), timed: false,
                                  evidence: (evidence + ["没写钟点，记为全天"]).joined(separator: "，"), unsure: unsure)
            }
            if time.midnight {
                // “晚上12点 睡觉”：日程不跨夜，记成当天 23:59 截止
                let last = 23 * 60 + 59
                let passed = day < today || (day == today && last <= context.nowMinute) || ((date?.offset ?? 0) <= 0 && narrative(title))
                evidence.append("“\(time.text)”→ 23:59 前（日程不跨夜）")
                return EventGuess(event: Event(day: day, start: last, end: nil, title: title, byMidnight: true), passed: passed, timed: true,
                                  evidence: evidence.joined(separator: "，"))
            }
            var start = time.start
            var passed = day < today || (day == today && start <= context.nowMinute)
            if time.bare {
                // 没写上午下午的 7–11 点：以后的日子、今天上午还没到 → 上午；已过了而现在是傍晚以后 → 晚上；
                // 其余（例如中午说“9点 开会”）算已过，先记日记（选定日程时按晚上）
                let evening = start + 12 * 60
                if day > today || start > context.nowMinute {
                    passed = day < today
                } else if (context.nowMinute >= 17 * 60 || forced), evening > context.nowMinute {
                    start = evening
                    passed = false
                } else {
                    passed = true
                }
            }
            if (date?.offset ?? 0) <= 0, narrative(title) { passed = true }
            var end = time.end.map { $0 + (start - time.start) }
            var lasting = false
            if end == nil, let duration = durationMinutes() {
                end = start + duration.minutes
                title = duration.title
                lasting = true
            }
            evidence.append("“\(time.text)”→ \(ClockTime.text(start))")
            if time.end == nil, !lasting { evidence.append("没写结束，按 1 小时") }
            let last = 23 * 60 + 59
            let finalEnd = start >= last ? nil : min(max(end ?? start + 60, start + 1), last)
            return EventGuess(event: Event(day: day, start: start, end: finalEnd, title: title), passed: passed, timed: true,
                              evidence: evidence.joined(separator: "，"))
        }

        /// 写了时长（“组会 2小时”“跑步 30 分钟”）：日程按它定结束，标题去掉这段
        func durationMinutes() -> (minutes: Int, title: String)? {
            guard let n = scan.numbers.first(where: { $0.unit.flatMap { QuickParse.unitFamilies[$0] }?.family == "时长" }),
                  let u = n.unit, let f = QuickParse.unitFamilies[u] else { return nil }
            let raw = n.value * f.factor
            guard raw.isFinite, raw >= 1, raw <= 24 * 60 else { return nil }
            let minutes = Int(raw.rounded())
            return (minutes, cleanTitle(scan.remaining(removing: eventRemovals() + [n.range])))
        }

        func eventRemovals() -> [Range<Int>] { scan.dates.map(\.range) + scan.times.map(\.range) + scan.tagRanges }

        func eventTitle() -> String { cleanTitle(scan.remaining(removing: eventRemovals())) }

        func cleanTitle(_ raw: String) -> String {
            var t = raw
            // 时段词本身（“明天早上 跑步”的“早上”）不进标题
            for word in ["早上", "上午", "中午", "下午", "傍晚", "晚上", "早晨", "清晨", "凌晨"] where t.hasPrefix(word) {
                t = QuickParse.tidy(String(t.dropFirst(word.count)))
            }
            // “11 点前睡觉”“周五前交论文”：钟点、日期后面的“前”
            for word in ["之前", "以前", "前"] where t.hasPrefix(word) && t.count > word.count {
                t = QuickParse.tidy(String(t.dropFirst(word.count)))
                break
            }
            for word in ["记得要", "记得", "有个", "要", "得", "的"] where t.hasPrefix(word) && t.count > word.count {
                t = QuickParse.tidy(String(t.dropFirst(word.count)))
                break
            }
            // “组会改到下午4点”：改期的说法
            for word in ["改到", "改成", "改在", "挪到", "推到"] where t.hasSuffix(word) && t.count > word.count {
                t = QuickParse.tidy(String(t.dropLast(word.count)))
                break
            }
            return t
        }

        // MARK: 修行录

        /// 句首写了“昨天 / 前天 / 上周五”（或往前不远的日子）：补记那天，正文去掉这个词。
        /// 日期签选了以前的哪天都算（句中写的日子不在句首时照留在正文里）
        var backdate: DateHit? {
            guard let d = date, d.offset < 0 else { return nil }
            if d.pinned { return d }
            guard d.leading, d.offset >= -60 else { return nil }
            return d
        }

        /// 日期签选的是以后的日子（修行录与打卡不记以后的日子；记账仍记今天，见 expense）
        var pinnedFuture: Bool { date.map { $0.pinned && $0.offset > 0 } ?? false }

        /// 依据里怎么说这个日子：句中写的照引原文；日期签选的写“日期签”
        func dateWord(_ d: DateHit) -> String { d.pinned ? "日期签 " : "“\(text(d.range))”" }

        /// 句中写的这个日子算不算这一条的日子标记（可以从正文 / 备注里去掉）：没被日期签盖过的算；
        /// 被盖过的，只有原来就指签上这天、或原来写的是今天（“今天 / 今晚 / 今早”）才算——
        /// 补记时写的“周五的组会”“明天要考试”是话的一部分，一字不动
        func marksRecordDay(_ d: DateHit) -> Bool {
            guard d.pinned, let written = d.written else { return true }
            return written == d.day || written == today
        }

        func journal(_ kind: JournalKind) -> Journal {
            if let d = backdate {
                let removed = d.leading && marksRecordDay(d) ? [d.range] : []
                return Journal(kind: kind, body: scan.remaining(removing: scan.tagRanges + removed), day: d.day, tags: scan.tags)
            }
            return Journal(kind: kind, body: scan.remaining(removing: scan.tagRanges), day: today, tags: scan.tags)
        }

        // MARK: 记账

        /// 记账说明里只剩这些虚字（“花了 50”“一共 120”）时改用类别名
        static let emptyDescriptions: Set<String> = ["了", "一", "共", "的", "花", "付", "用", "交", "充", "总", "就", "也", "又", "吧", "啊", "呀"]

        func expense(_ n: NumberHit) -> Expense? {
            guard let cents = cents(n) else { return nil }
            var day = today
            var moved = false
            if let d = date {
                if d.day > today { moved = true } else if d.offset >= -60 || d.pinned { day = d.day }
            }
            // 一句里写了两笔钱（改作记账时按第一笔）：另一笔的数字也不留在说明里
            let others = moneyLike.filter { $0.range != n.range }.map(\.range)
            var description = scan.remaining(removing: [n.range] + others + scan.dates.map(\.range) + scan.tagRanges)
            let verbs = ["一共花了", "总共花了", "共花了", "花了", "花费", "用了", "付了", "一共", "总共", "共", "花"]
            if verbs.contains(description) || Scan.moneyVerbs.contains(description) { description = "" }
            for word in verbs where description.hasSuffix(word) && description.count > word.count {
                description = QuickParse.tidy(String(description.dropLast(word.count)))
                break
            }
            for word in Scan.moneyVerbs where description.hasPrefix(word) && description.count > word.count {
                description = QuickParse.tidy(String(description.dropFirst(word.count)))
                break
            }
            if Self.emptyDescriptions.contains(description) { description = "" }
            let category = scan.category?.category ?? "待分类消费"
            if description.isEmpty { description = category }
            return Expense(cents: cents, category: category, keyword: scan.category.map { text($0.range) }, description: description, day: day,
                           note: scan.tags.map { "#" + $0 }.joined(separator: " "), movedFromFuture: moved)
        }

        func expenseEvidence(_ e: Expense, _ n: NumberHit) -> String {
            var parts = ["认出：金额 \(amountText(n))"]
            if let k = e.keyword { parts.append("“\(k)”→ \(e.category)") } else { parts.append("没认出类别，先记“待分类”（可点类别改）") }
            if e.movedFromFuture { parts.append("未来的日子不能记账，先记在今天") }
            else if e.day != today, let d = date { parts.append("\(dateWord(d))→ \(e.day.label(relativeTo: today))") }
            return parts.joined(separator: "，")
        }

        // MARK: 打卡

        struct CheckinGuess {
            var checkin: Checkin
            /// 记不成打卡的原因（单位对不上、数量是 0、数量太大）；选定打卡时只作提醒
            var mismatch: String?
            /// 这句写的数量是 0
            var zero = false
            var done: Bool
            var evidence: String
        }

        static let fillers = ["打卡", "已经", "刚刚", "完成", "做了", "一下", "今天", "了", "过", "刚", "完", "已", "啦", "呀", "哦", "的", "我", "去"]

        func checkin(habit index: Int, hit: HabitHit?, forced: Bool) -> CheckinGuess {
            let habit = context.habits[index]
            var day = today
            if let d = date, d.day < today { day = d.day }
            let state = habit.days[day]
            let unit = habit.unit.trimmingCharacters(in: .whitespaces)
            let viaAlias = hit?.viaAlias ?? false
            var c = Checkin(habit: index, title: habit.title, unit: unit, day: day, quantity: nil, added: nil, before: state?.quantity,
                            target: habit.isQuantity ? habit.target : nil, via: viaAlias ? hit.map { text($0.range) } : nil)
            var evidence: [String] = []
            if let hit {
                evidence.append(viaAlias ? "“\(text(hit.range))”→「\(habit.title)」（同类说法）" : "“\(text(hit.range))”→ 功课「\(habit.title)」")
            } else {
                evidence.append("改作打卡「\(habit.title)」")
            }
            if day != today, let d = date { evidence.append("\(dateWord(d))→ 补 \(day.label(relativeTo: today))") }
            var mismatch: String?
            var zero = false
            var quantityRange: Range<Int>?
            let withUnits = scan.numbers.filter { n in n.unit.map { !QuickParse.countOnlyUnits.contains($0) } ?? false }
            if habit.isQuantity, let target = habit.target {
                var added: Double?
                var tooBig = false
                for n in withUnits {
                    guard let u = n.unit, let v = QuickParse.convert(n.value, from: u, to: unit), v.isFinite else { continue }
                    if v <= 0 { zero = true; quantityRange = n.range; continue }
                    if v >= 1_000_000 { tooBig = true; continue }
                    added = v
                    quantityRange = n.range
                    let canonical = QuickParse.canonicalUnit(unit)
                    if u != canonical, !canonical.isEmpty {
                        c.conversion = "\(QuickParse.number(n.value)) \(u) → \(QuickParse.number(v)) \(unit)"
                    }
                    break
                }
                if added == nil, withUnits.isEmpty, let bare = scan.numbers.first(where: { $0.unit == nil && !$0.money && $0.value < 1_000_000 }) {
                    if bare.value <= 0 { zero = true } else { added = bare.value }
                    quantityRange = bare.range
                }
                if added == nil {
                    if zero {
                        mismatch = "数量写的是 0，先记成日记"
                    } else if tooBig {
                        mismatch = "数量太大，先记成日记"
                    } else if let first = withUnits.first, let u = first.unit {
                        mismatch = "单位对不上：「\(habit.title)」按“\(unit.isEmpty ? "次" : unit)”记，这句写的是“\(u)”"
                    }
                }
                c.added = added
                let before = state?.quantity ?? 0
                c.quantity = added.map { before + $0 } ?? max(before, target)
                if let added { evidence.append("\(QuickParse.number(added)) \(unit)" + (c.conversion.map { "（\($0)）" } ?? "")) }
                else if mismatch == nil { evidence.append("没写数量，记满 \(QuickParse.number(target)) \(unit)") }
            }
            // 备注照原话：只去掉功课名、记下的数量、标签和句首的日期钟点（那是这条打卡的日子），句中的“明天”“晚上”照留；
            // 按同类说法对上的，那个说法也留在备注里（“跑步 30 分钟”记在「运动」下）
            var removals = scan.tagRanges + leadingDateTimes()
            if let quantityRange { removals.append(quantityRange) }
            if let hit, !viaAlias { removals.append(hit.range) }
            var note = scan.remaining(removing: removals)
            if note.hasPrefix("打卡") { note = QuickParse.tidy(String(note.dropFirst(2))) }
            // 去掉功课名后剩在开头的“了 / 过 / 完”（“冥想了一会儿”→“一会儿”）
            while let first = note.first, "了过完的".contains(first) { note = QuickParse.tidy(String(note.dropFirst())) }
            // 算“还有没有别的话”时，句中的日期钟点也不算
            var core = scan.remaining(removing: removals + scan.dates.map(\.range) + scan.times.map(\.range))
            if core.hasPrefix("打卡") { core = String(core.dropFirst(2)) }
            if viaAlias, let hit { core = core.replacingOccurrences(of: text(hit.range), with: "") }
            for filler in Self.fillers { core = core.replacingOccurrences(of: filler, with: "") }
            core = core.filter { !$0.isWhitespace && !Scan.separators.contains($0) }
            // 只剩一个字（“喝了两杯水”剩个“水”）不算多余的话
            let booleanWithNumber = !habit.isQuantity && scan.numbers.contains { !$0.money }
            if core.count >= 2 || booleanWithNumber {
                c.note = note
                if !note.isEmpty { evidence.append("“\(note)”写进备注") }
            }
            return CheckinGuess(checkin: c, mismatch: mismatch, zero: zero, done: state?.done ?? false, evidence: evidence.joined(separator: "，"))
        }

        /// 句首连着的日期、钟点（“昨天下午3点 跑步”的“昨天”“下午3点”）
        func leadingDateTimes() -> [Range<Int>] {
            let ranges = (scan.dates.map(\.range) + scan.times.map(\.range)).sorted { $0.lowerBound < $1.lowerBound }
            var out: [Range<Int>] = []
            var pos = 0
            for r in ranges {
                guard (pos..<max(pos, r.lowerBound)).allSatisfy({ i in
                    scan.chars[i].isWhitespace || Scan.separators.contains(scan.chars[i]) || scan.tagRanges.contains { $0.contains(i) }
                }) else { break }
                // 被日期签盖过、又不是指那天的日子（“周五开完组会 冥想 10 分钟”补在昨天）：是话的一部分，
                // 连同后面紧跟的钟点都留在备注里
                if let d = date, r == d.range, !marksRecordDay(d) { break }
                out.append(r)
                pos = max(pos, r.upperBound)
            }
            return out
        }

        /// 说的是没做、想做或还没到的时段（“没跑步”“不想运动”“待会冥想”“今晚冥想”而现在才中午）：返回原因（写进依据），否则 nil
        func notYet(_ hit: HabitHit, day: LocalDay) -> String? {
            let chars = scan.chars
            // 1. 说法前 3 个字以内的否定
            var before = String(chars[max(0, hit.range.lowerBound - 3)..<hit.range.lowerBound])
            for word in QuickParse.notNegation { before = before.replacingOccurrences(of: word, with: "") }
            if let word = QuickParse.negationWords.first(where: { before.contains($0) }) { return "前面写了“\(word)”" }
            // 2. 句里写了打算（功课说法、钟点本身不算：“冥想”的“想”）
            var free = chars
            for h in scan.habitHits { for i in h.range where i < free.count { free[i] = " " } }
            for t in scan.times { for i in t.range where i < free.count { free[i] = " " } }
            var rest = String(free)
            for word in QuickParse.notIntent { rest = rest.replacingOccurrences(of: word, with: " ") }
            if let word = QuickParse.intentWords.first(where: { rest.contains($0) }) { return "写了“\(word)”" }
            // 3. 今天的“今晚 / 晚上 / 下午……”还没到
            guard day == today else { return nil }
            if let d = date, d.offset == 0, let p = d.period {
                let start = p == .evening ? 17 * 60 : 5 * 60
                if context.nowMinute < start { return "“\(text(d.range))”还没到" }
            }
            if let (word, _) = QuickParse.periodStarts.first(where: { rest.contains($0.0) && context.nowMinute < $0.1 }) {
                return "“\(word)”还没到"
            }
            return nil
        }

        func habitNames(_ list: [Int]) -> String {
            list.prefix(3).map { "「\(context.habits[$0].title)」" }.joined()
        }

        func countWord(_ n: Int) -> String { n == 2 ? "两" : "\(n) " }

        // MARK: 合起来

        func result() -> Result {
            var r = Result(intent: .diary, journal: journal(.diary), today: today)
            let mentions = scan.habitMentions()
            let hasHabits = !context.habits.isEmpty

            func finish(_ intent: Intent, suggested: Intent? = nil) -> Result {
                var out = r
                out.intent = intent
                if let kind = intent.journalKind {
                    out.journal = journal(kind)
                    // 只写了前缀、标签或日期（“复盘：”“#灵感”“昨天”）：没有要记的话，不让记
                    if out.journal.body.isEmpty, out.problem == nil { out.problem = "写上要记的话" }
                    if pinnedFuture, out.problem == nil { out.problem = "修行录只记今天和以前：日期签改个日子，或改作日程" }
                }
                let order: [Intent] = (suggested.map { [$0] } ?? []) + [.diary, .note, .expense, .checkin, .event]
                out.alternatives = order.reduce(into: [Intent]()) { list, i in
                    guard i != intent, !list.contains(i) else { return }
                    switch i {
                    case .expense: if let n = anyAmount, cents(n) != nil { list.append(i) }
                    case .checkin: if hasHabits { list.append(i) }
                    case .event: if date != nil || !scan.times.isEmpty { list.append(i) }
                    case .review: break
                    default: list.append(i)
                    }
                }
                return out
            }

            func asExpense(_ n: NumberHit, chosen: Bool) -> Result? {
                guard let e = expense(n) else { return nil }
                r.expense = e
                r.evidence = expenseEvidence(e, n)
                r.notice = e.movedFromFuture ? "未来的日子不能记账，先记在今天" : nil
                r.chosen = chosen
                return finish(.expense)
            }

            func asEvent(_ g: EventGuess, chosen: Bool) -> Result {
                r.event = g.event
                r.evidence = "认出：" + g.evidence
                r.chosen = chosen
                if g.event.title.isEmpty { r.problem = "写上要做什么" }
                return finish(.event)
            }

            func asCheckin(_ index: Int, hit: HabitHit?, chosen: Bool) -> Result {
                let g = checkin(habit: index, hit: hit, forced: chosen)
                let title = context.habits[index].title
                let dayText = g.checkin.day == today ? "今日" : g.checkin.day.label(relativeTo: today)
                r.suggestedHabit = index
                // 日期签选了以后的日子：不能先打卡（自动认时走不到这里，见第 9 步）
                if pinnedFuture {
                    r.checkin = g.checkin
                    r.chosen = chosen
                    r.problem = "以后的日子不能打卡：日期签改选今天或以前"
                    r.evidence = (chosen ? "改作打卡「\(title)」" : "认出：" + g.evidence) + "；日期签选的是以后的日子"
                    return finish(.checkin)
                }
                if !chosen, let mismatch = g.mismatch {
                    r.evidence = "认出：" + g.evidence + "；" + (g.zero ? "数量是 0" : "单位对不上") + "，按日记记"
                    r.notice = mismatch
                    return finish(.diary, suggested: .checkin)
                }
                if chosen, g.zero, g.checkin.added == nil {
                    r.checkin = g.checkin
                    r.chosen = true
                    r.problem = "数量写的是 0：写上这次的数量"
                    r.evidence = "改作打卡「\(title)」"
                    return finish(.checkin)
                }
                // 按只是相关的同类说法对上数量型功课、又没写数量（“晚饭后散步”对「步数 8000」）：不替他记满，先记日记
                if !chosen, let via = g.checkin.via, let group = hit?.group, !HabitAlias.groups[group].fillsTarget,
                   !HabitAlias.key(title).contains(HabitAlias.key(via)), g.checkin.target != nil, g.checkin.added == nil {
                    r.evidence = "认出：“\(via)”→「\(title)」（同类说法）；没写数量，按日记记"
                    r.notice = "说到「\(title)」但没写数量，先记成日记"
                    return finish(.diary, suggested: .checkin)
                }
                // 已圆满：只打卡的功课不能再打（再点就是取消），数量型选定了且写了数量可以接着加
                if g.done, !(chosen && g.checkin.added != nil) {
                    if chosen {
                        r.checkin = g.checkin
                        r.chosen = true
                        r.problem = "「\(title)」\(dayText)已圆满"
                        r.evidence = "改作打卡「\(title)」"
                        return finish(.checkin)
                    }
                    r.evidence = "认出：" + g.evidence + "；\(dayText)已圆满，按日记记"
                    r.notice = "「\(title)」\(dayText)已圆满"
                    return finish(.diary, suggested: .checkin)
                }
                r.checkin = g.checkin
                r.evidence = "认出：" + g.evidence
                r.chosen = chosen
                // 选定打卡而单位对不上（“喝水 500ml”对“杯”）：照记满，签上说清楚
                if chosen, let mismatch = g.mismatch, g.checkin.added == nil, g.checkin.target != nil {
                    r.notice = mismatch + "；将按记满"
                }
                return finish(.checkin)
            }

            func asJournal(_ intent: Intent, evidence: String, chosen: Bool = false, suggested: Intent? = nil) -> Result {
                r.evidence = evidence
                r.chosen = chosen
                return finish(intent, suggested: suggested)
            }

            var diaryEvidence: String {
                var parts: [String] = []
                if let d = backdate { parts.append((d.pinned ? "日期签 " : "句首“\(text(d.range))”") + "→ 补记 \(d.day.label(relativeTo: today))") }
                if !scan.tags.isEmpty { parts.append(scan.tags.map { "#" + $0 }.joined(separator: " ") + " 记为标签") }
                return parts.isEmpty ? "没认出金额、钟点或功课，按日记记" : "认出：" + parts.joined(separator: "，")
            }

            // 1. 用户选定的
            if let choice {
                switch choice {
                case .diary: return asJournal(.diary, evidence: "已改作日记", chosen: true)
                case .note: return asJournal(.note, evidence: "已改作灵感", chosen: true)
                case .expense:
                    if let n = anyAmount, let out = asExpense(n, chosen: true) { return out }
                case .event:
                    if let g = eventGuess(forced: true) { return asEvent(g, chosen: true) }
                case .checkin(let title):
                    if let index = context.habits.firstIndex(where: { $0.title == title }) {
                        return asCheckin(index, hit: mentions.hit?.index == index ? mentions.hit : nil, chosen: true)
                    }
                }
            }

            // 2. 前缀
            if let prefix {
                switch prefix {
                case .diary, .note, .review:
                    let what = prefix == .note && scan.noteMarker ? "写了“#灵感”" : "开头写了“\(prefix.label)”"
                    return asJournal(prefix, evidence: "\(what)，记为\(prefix == .review ? "日省" : prefix.label)")
                case .expense:
                    if let n = anyAmount, let out = asExpense(n, chosen: false) { return out }
                    r.problem = "没认出金额：写上金额，例如“午饭 18.5”"
                    r.evidence = "开头写了“记账”"
                    return finish(.expense)
                case .checkin:
                    if let hit = mentions.hit, let index = hit.index { return asCheckin(index, hit: hit, chosen: false) }
                    if case .several(let list) = mentions {
                        r.suggestedHabit = list.first
                        r.problem = "说到了\(habitNames(list))\(countWord(list.count))项功课：分两句各打一次卡，或点“改作 ▾”选一项"
                    } else {
                        r.problem = hasHabits ? "没认出是哪项功课：点“改作 ▾”选一项" : "还没有功课：先去每日功课立一项"
                    }
                    r.evidence = "开头写了“打卡”"
                    return finish(.checkin)
                case .event:
                    // “提醒我买牛奶”：没写日期记今天全天
                    let g = eventGuess(forced: true)
                        ?? EventGuess(event: Event(day: today, start: nil, end: nil, title: eventTitle()), passed: false, timed: false,
                                      evidence: "没写日期，记在今天全天")
                    return asEvent(g, chosen: false)
                }
            }

            // 3. 写得长、写了几句或几行：是在写日记（“跑步 30 分钟，好累”这种后面跟一小句的不算）
            let plain = scan.remaining(removing: scan.tagRanges)
            let parts = QuickParse.clauses(plain)
            let tooLong = scan.text.contains("\n") || QuickParse.length(plain) > QuickParse.sentenceLimit
            if tooLong || parts.count >= 3 || (parts.count == 2 && QuickParse.length(parts[1]) > QuickParse.shortTail) {
                r.suggestedHabit = mentions.hit?.index
                let tags = scan.tags.isEmpty ? "" : "；" + scan.tags.map { "#" + $0 }.joined(separator: " ") + " 记为标签"
                return asJournal(.diary, evidence: (tooLong ? "写得较长，按日记记" : "写了几句话，按日记记") + tags)
            }
            // 4. 一句里有两笔钱：分不清记哪笔，先记日记（说到了两项功课时先说功课）
            let money = moneyLike
            if money.count >= 2, !scan.income {
                if case .several(let list) = mentions {
                    r.suggestedHabit = list.first
                    r.notice = "说到了\(habitNames(list))\(countWord(list.count))项功课，先记成日记；分两句各打一次卡"
                    return asJournal(.diary, evidence: "认出：说到了\(habitNames(list))，一次只打一项，按日记记", suggested: .checkin)
                }
                r.notice = "这句有\(countWord(money.count))笔钱（\(money.prefix(3).map(amountText).joined(separator: "、"))），分两句记更准"
                return asJournal(.diary, evidence: diaryEvidence + "；认出\(countWord(money.count))笔钱，没有记账", suggested: .expense)
            }
            // 5. 带币种的金额
            if let n = strongMoney, !scan.income, let out = asExpense(n, chosen: false) { return out }
            // 6. 明确的钟点
            let guess = eventGuess(forced: false)
            if let g = guess, g.timed, !g.passed { return asEvent(g, chosen: false) }
            // 7. 句首句尾的裸数字：这句说的是一项功课时按打卡（只打卡的功课又认出了消费类别时仍记账）；
            //    说的是体重、气温、分数，或像年份（2026）时不记账
            let habitIndex = mentions.hit?.index
            let habitDay = date?.day ?? today
            let notMoney = QuickParse.notMoneyWords.first { scan.text.contains($0) }
            var several = false
            if case .several = mentions { several = true }
            var feelingNumber = false
            if let n = bareAmount, !scan.income, notMoney == nil, !looksLikeYear(n) {
                // “打球 场地费 20”：说到了“费 / 钱”也按记账
                let spoken = scan.category != nil || scan.text.contains("费") || scan.text.contains("钱")
                let isHabit = several || (habitIndex.map { habitDay <= today && (context.habits[$0].isQuantity || !spoken) } ?? false)
                // 没认出买了什么、又像在说感受（“今天好累 不想动 1”）：这个数多半不是钱（说到贵、便宜的仍记账）
                let rest = scan.remaining(removing: [n.range] + scan.dates.map(\.range) + scan.tagRanges)
                feelingNumber = !spoken && soundsLikeFeeling(rest) && !QuickParse.priceWords.contains { rest.contains($0) }
                if !isHabit, !feelingNumber, let out = asExpense(n, chosen: false) { return out }
            }
            // 8. 未来的日子、没写钟点、标题短而不像感想：全天日程
            if let g = guess, !g.timed, !g.passed, !g.unsure { return asEvent(g, chosen: false) }
            // 9. 功课（没做 / 想做 / 时段还没到的先记日记；补很久以前的卡留给改作）
            if let hit = mentions.hit, let index = hit.index, habitDay <= today {
                if let why = notYet(hit, day: habitDay) {
                    r.suggestedHabit = index
                    r.notice = "像是还没做，先记成日记；做了要打卡点“改作”"
                    return asJournal(.diary, evidence: "认出：“\(text(hit.range))”→「\(context.habits[index].title)」，但\(why)，按日记记",
                                     suggested: .checkin)
                }
                // 日期签选定的那天不论多远都补（那天的打卡由调用方带进 Context，见 QuickCommit.parseContext）
                if habitDay >= today.adding(days: -2) || date?.pinned == true { return asCheckin(index, hit: hit, chosen: false) }
                r.suggestedHabit = index
                return asJournal(.diary, evidence: diaryEvidence + "；日子较远，没有补卡", suggested: .checkin)
            }
            // 10. 日记（钟点已过、说到了几项功课、说法对上多项功课、像感想的日子、写的是进账或体重这类时给出备选）
            if let g = guess, g.timed, g.passed, g.event.day >= today {
                r.notice = "\(g.event.byMidnight ? "23:59" : ClockTime.text(g.event.start ?? 0)) 已过，先记成日记；要记成日程点“改作”"
                return asJournal(.diary, evidence: diaryEvidence, suggested: .event)
            }
            if case .several(let list) = mentions {
                r.suggestedHabit = list.first
                r.notice = "说到了\(habitNames(list))\(countWord(list.count))项功课，先记成日记；分两句各打一次卡"
                return asJournal(.diary, evidence: "认出：说到了\(habitNames(list))，一次只打一项，按日记记", suggested: .checkin)
            }
            if case .ambiguous(let word) = mentions {
                r.notice = "“\(word)”能对上几项功课，没有打卡；要打卡点“改作”选一项"
                return asJournal(.diary, evidence: "认出：“\(word)”能对上几项功课，按日记记", suggested: .checkin)
            }
            if let g = guess, !g.timed, !g.passed, g.unsure {
                r.notice = "说到了 \(g.event.day.label(relativeTo: today))；要记成日程点“改作”"
                return asJournal(.diary, evidence: diaryEvidence + "；像是感想，没有记成日程", suggested: .event)
            }
            if scan.income, anyAmount != nil {
                return asJournal(.diary, evidence: diaryEvidence + "；说的是进账或转账，不自动记账", suggested: .expense)
            }
            if let word = notMoney, anyAmount != nil {
                return asJournal(.diary, evidence: diaryEvidence + "；说的是“\(word)”，这个数不是钱", suggested: .expense)
            }
            if let n = bareAmount, looksLikeYear(n) {
                return asJournal(.diary, evidence: diaryEvidence + "；\(amountText(n)) 像是年份，没有记账", suggested: .expense)
            }
            if feelingNumber {
                return asJournal(.diary, evidence: diaryEvidence + "；像在说感受，这个数不当钱", suggested: .expense)
            }
            return asJournal(.diary, evidence: diaryEvidence)
        }
    }
}
