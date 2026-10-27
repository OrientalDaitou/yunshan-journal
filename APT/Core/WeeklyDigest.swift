import Foundation

/// 七日小卷（#11）：一周的小结——自己写的 1–3 句、心境七日、功课本周对上周、本周花费、一条洞见，
/// 以及“存为周复盘草稿”的标题与摘句、“请 AI 写一封周信”那句话。
/// 这里全是纯函数：取数（两周的修行录、修为模型里的功课统计、账簿）在 WeeklyScrollSheet，CoreCheck 覆盖这里的口径。
enum WeeklyDigest {
    /// 周一中午以前默认看上一整周（周末没来得及回看的那一周）；之后看本周
    static let mondayCutoffMinute = 12 * 60
    /// 摘句最多几句、每句最多几个字（超出的加“……”）
    static let quoteLimit = 3, quoteLength = 48

    // MARK: 周

    /// 一周：周一到周日。过去的周整周都算；本周只算到今天（还没到的日子不算缺）
    struct Week: Equatable {
        var monday: LocalDay
        var today: LocalDay

        var sunday: LocalDay { monday.adding(days: 6) }
        /// 这一周已经过到哪天：本周是今天，过去的周是周日
        var last: LocalDay { max(monday, min(sunday, today)) }
        var isCurrent: Bool { monday == today.mondayOfWeek }
        var days: [LocalDay] { LocalDay.range(monday, sunday) }
        var previous: Week { Week(monday: monday.adding(days: -7), today: today) }
        /// 下一周（不超过本周）
        var next: Week? { monday < today.mondayOfWeek ? Week(monday: monday.adding(days: 7), today: today) : nil }
        /// 还能不能往前翻：翻到最早一条记录所在的那一周为止；一条记录都没有时不能翻
        func hasPrevious(earliest: LocalDay?) -> Bool { earliest.map { monday > $0.mondayOfWeek } ?? false }

        /// 卷上这一周怎么称呼：本周就叫“本周”；看过去的周叫“那一周”（用户心里的“这周 / 上周”跟卷上的不是一回事，不用它们）
        var selfName: String { isCurrent ? "本周" : "那一周" }
        /// 拿来对比的前一周：本周的前一周就是“上周”；看过去的周时叫“前一周”
        var priorName: String { isCurrent ? "上周" : "前一周" }

        /// 小卷标题：`10月19日 – 25日`；跨月 `10月26日 – 11月1日`；跨年两头都带年份；整周不在今年的带年份
        var title: String { span(" – ") }
        /// 草稿标题、AI 那句话里用的紧凑写法：`10月19日–25日`
        var compactLabel: String { span("–") }

        private func span(_ separator: String) -> String {
            let a = monday, b = sunday
            if a.year != b.year {
                return "\(a.year)年\(a.month)月\(a.day)日\(separator)\(b.year)年\(b.month)月\(b.day)日"
            }
            let year = a.year == today.year ? "" : "\(a.year)年"
            if a.month != b.month { return "\(year)\(a.month)月\(a.day)日\(separator)\(b.month)月\(b.day)日" }
            return "\(year)\(a.month)月\(a.day)日\(separator)\(b.day)日"
        }
    }

    /// 打开小卷时默认看哪一周：周一 12:00 之前看上一整周，其余看本周
    static func defaultWeek(today: LocalDay, minute: Int) -> Week {
        let monday = today.mondayOfWeek
        if today.weekdayIndex == 0 && minute < mondayCutoffMinute { return Week(monday: monday.adding(days: -7), today: today) }
        return Week(monday: monday, today: today)
    }

    /// 两周取数的日期范围（上周一到这周已过的最后一天）：修行录按 dateKey 只取这一段
    static func fetchRange(_ week: Week) -> (from: LocalDay, to: LocalDay) { (week.previous.monday, week.last) }

    // MARK: 其一 · 自己的话

    struct Quote: Equatable {
        var uid: String
        var day: LocalDay
        var text: String
    }

    /// 本周 1–3 句：珍藏的优先，其次心境最好那天的第一篇，其次最长一篇（还没选上的里最长的）；各取第一句，按日期、时刻先后排。
    /// 后两样只从日记和灵感里挑：复盘里多是统计句（“功课：早睡 6/7 天……”），不算“自己的话”；复盘只有珍藏了才入选。
    /// entries 是这一周的篇目（调用方按日期、时刻排好；不在这周的会被滤掉）
    static func quotes(_ entries: [RecordEntry], week: Week, limit: Int = quoteLimit) -> [Quote] {
        let inWeek = entries.filter { $0.day >= week.monday && $0.day <= week.last }
        let order = Dictionary(inWeek.enumerated().map { ($0.element.uid, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var picked: [Quote] = []
        func take(_ entry: RecordEntry?) {
            guard let entry, picked.count < limit, !picked.contains(where: { $0.uid == entry.uid }) else { return }
            let text = firstSentence(entry)
            guard !text.isEmpty else { return }
            picked.append(Quote(uid: entry.uid, day: entry.day, text: text))
        }
        for entry in inWeek where entry.pinned { take(entry) }
        let own = inWeek.filter { $0.kind != .review && !firstSentence($0).isEmpty }
        // 心境最好的那天（同分取较晚的一天）：那天第一篇
        let moods = RecordStats.moodByDay(inWeek)
        if let best = moods.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key {
            take(own.first { $0.day == best })
        }
        // 还没选上的里最长的一篇（同长取较晚的）
        take(own.filter { entry in !picked.contains { $0.uid == entry.uid } }.max { ($0.chars, $0.day) < ($1.chars, $1.day) })
        return picked.sorted { ($0.day, order[$0.uid] ?? 0) < ($1.day, order[$1.uid] ?? 0) }
    }

    /// 一篇的第一句：去掉复盘的【所得】等小标题、插进去的〔本期素材〕段与列表记号，取到第一个句号 / 问号 / 叹号或换行为止；
    /// 太短（不到 6 个字）就接上下一行（上一行没以标点收尾才补一个“，”）；超长截断加“……”。正文空了用标题
    static func firstSentence(_ entry: RecordEntry) -> String {
        let text = cleaned(entry.body)
        let source = text.isEmpty ? entry.title.trimmingCharacters(in: .whitespacesAndNewlines) : text
        guard !source.isEmpty else { return "" }
        var sentence = ""
        for ch in source {
            if ch == "\n" {
                if sentence.count >= 6 { break }
                if let last = sentence.last, !"，,、：:；;。！？!?…".contains(last) { sentence.append("，") }
                continue
            }
            sentence.append(ch)
            if "。！？!?".contains(ch), sentence.count >= 6 { break }
        }
        sentence = sentence.trimmingCharacters(in: .whitespaces)
        if sentence.count > quoteLength { sentence = String(sentence.prefix(quoteLength)) + "……" }
        return sentence
    }

    /// 去掉复盘模板的小标题与〔…〕起头的素材段（到空行为止）；各行去掉首尾空白和行首的列表 / 标题记号（“- ”“* ”“· ”“### ”“1. ”“> ”），
    /// 跳过空行和复盘回访行（“· 跑三次步 —— 做到了”）
    static func cleaned(_ body: String) -> String {
        var lines: [String] = []
        var skipping = false
        for raw in body.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { skipping = false; continue }
            if line.hasPrefix("〔") { skipping = true; continue }
            if skipping { continue }
            while line.hasPrefix("【"), let close = line.firstIndex(of: "】") {
                line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            // 回访、素材那种“· …… —— 做到了”的行不是自己的话
            if (line.hasPrefix("·") || line.hasPrefix("•")) && line.contains("——") { continue }
            line = strippedMarker(line)
            if !line.isEmpty { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    /// 行首的列表 / 标题 / 引用记号：“- ”“* ”“+ ”“· ”“• ”“### ”“> ”“1. ”“2、”“3）”“(4)”；“#标签”“-5 度”这类不动
    static func strippedMarker(_ line: String) -> String {
        var rest = Substring(line)
        func drop(_ count: Int) { rest = rest.dropFirst(count).drop { $0 == " " || $0 == "\u{3000}" } }
        if let first = rest.first {
            if "·•".contains(first) {
                drop(1)
            } else if "-*+>".contains(first), rest.dropFirst().first == " " {
                drop(1)
            } else if first == "#" {
                let hashes = rest.prefix { $0 == "#" }.count
                if hashes <= 6, rest.dropFirst(hashes).first == " " { drop(hashes) }
            } else if first == "(" || first == "（" {
                let digits = rest.dropFirst().prefix { $0.isASCII && $0.isNumber }.count
                if (1...2).contains(digits), let close = rest.dropFirst(1 + digits).first, ")）".contains(close) { drop(2 + digits) }
            } else if first.isASCII && first.isNumber {
                let digits = rest.prefix { $0.isASCII && $0.isNumber }.count
                if digits <= 2, let mark = rest.dropFirst(digits).first, ".、)）".contains(mark),
                   mark != "." || rest.dropFirst(digits + 1).first == " " {
                    drop(digits + 1)
                }
            }
        }
        return String(rest)
    }

    // MARK: 其二 · 心境七日

    enum MoodMark: Equatable {
        /// 当天日记心境的平均（四舍五入到 1–5）
        case mood(Int)
        /// 写了，没记心境
        case ink
        /// 没写
        case blank
        /// 今天，还没落笔：今天还没过完，不算“未记”（与功课“今天还没打不算缺”同一个口径）
        case today
        /// 还没到
        case future
    }

    static func moodMarks(_ entries: [RecordEntry], week: Week) -> [(day: LocalDay, mark: MoodMark)] {
        let inWeek = entries.filter { $0.day >= week.monday && $0.day <= week.last }
        let moods = RecordStats.moodByDay(inWeek)
        let written = Set(inWeek.map(\.day))
        return week.days.map { day in
            if day > week.last { return (day, .future) }
            if let value = moods[day] { return (day, .mood(max(1, min(5, Int(value.rounded()))))) }
            if written.contains(day) { return (day, .ink) }
            return (day, day == week.today ? .today : .blank)
        }
    }

    /// `晴 3 · 平 2 · 未记 2`：心境从好到差，再加没记心境（含没写）的日子；还没到的日子、今天还没写都不算
    static func moodTally(_ marks: [(day: LocalDay, mark: MoodMark)]) -> String {
        var counts = [Int](repeating: 0, count: 6)
        var unmarked = 0
        for (_, mark) in marks {
            switch mark {
            case .mood(let value): counts[value] += 1
            case .ink, .blank: unmarked += 1
            case .today, .future: break
            }
        }
        var parts = (1...5).reversed().compactMap { counts[$0] > 0 ? "\(Mood.label($0)) \(counts[$0])" : nil }
        if unmarked > 0 { parts.append("未记 \(unmarked)") }
        return parts.joined(separator: " · ")
    }

    // MARK: 其三 · 功课

    struct HabitLine: Equatable {
        var title: String
        var done: Int
        var expected: Int
        var rate: Double { expected > 0 ? Double(done) / Double(expected) : 0 }
        var fraction: String { "\(done)/\(expected)" }
    }

    struct HabitWeek: Equatable {
        /// 本周整体完成率（各项完成次数之和 / 应做次数之和）
        var rate: Double
        /// 上周的同一口径（上周还没有功课时为 nil）
        var previousRate: Double?
        /// 最稳的一项（完成率最高、至少做到一次）
        var steadiest: HabitLine?
        /// 可再护持的一项（完成率最低、没做满；只有一项功课时不写）
        var tending: HabitLine?
        var lines: [HabitLine]
    }

    /// 一项功课在这一周做了几次、应做几次。每天 / 指定星期：数到这周已过的最后一天，今天还没打不算缺；
    /// 每周 N 次：过完的周应做 N 次（这周中途立的按天数折算），本周按已过的天数折算、做到的不扣。这一周还轮不到它时为 nil
    static func tally(_ stats: HabitStats, week: Week) -> HabitLine? {
        let spec = stats.spec
        let first = max(week.monday, spec.startDay)
        let last = week.last
        guard first <= last else { return nil }
        switch spec.frequency {
        case .daily, .weekdays:
            var expected = 0, done = 0
            for day in LocalDay.range(first, last) where spec.isScheduled(day) {
                let ok = stats.isAchieved(day)
                if day == stats.today && !ok { continue }
                expected += 1
                if ok { done += 1 }
            }
            return expected == 0 ? nil : HabitLine(title: "", done: done, expected: expected)
        case .weekly:
            let target = max(1, spec.targetPerWeek)
            let count = LocalDay.range(first, last).filter(stats.isAchieved).count
            // 这一周里轮得到它的天数（本周数到今天，中途立的从开始那天起）
            let span = first.days(to: last) + 1
            let share = week.last < week.sunday || first > week.monday
                ? Int((Double(target) * Double(span) / 7).rounded(week.last < week.sunday ? .down : .up)) : target
            let expected = min(target, max(min(count, target), share))
            return expected == 0 ? nil : HabitLine(title: "", done: min(count, target), expected: expected)
        }
    }

    static func habits(_ items: [(title: String, stats: HabitStats)], week: Week) -> HabitWeek? {
        func lines(_ week: Week) -> [HabitLine] {
            items.compactMap { item in
                guard var line = tally(item.stats, week: week) else { return nil }
                line.title = item.title
                return line
            }
        }
        func rate(_ lines: [HabitLine]) -> Double? {
            let expected = lines.reduce(0) { $0 + $1.expected }
            return expected == 0 ? nil : Double(lines.reduce(0) { $0 + $1.done }) / Double(expected)
        }
        let now = lines(week)
        guard let thisRate = rate(now) else { return nil }
        // 同分时取完成次数多的、再取排在前面的（items 的次序就是功课页的次序）
        let indexed = Array(now.enumerated())
        let steadiest = indexed.filter { $0.element.done > 0 }
            .max { ($0.element.rate, $0.element.done, -$0.offset) < ($1.element.rate, $1.element.done, -$1.offset) }?.element
        var tending: HabitLine?
        if now.count >= 2, let low = indexed.min(by: { ($0.element.rate, -$0.element.expected, $0.offset) < ($1.element.rate, -$1.element.expected, $1.offset) })?.element,
           low.rate < 1, low != steadiest {
            tending = low
        }
        return HabitWeek(rate: thisRate, previousRate: rate(lines(week.previous)), steadiest: steadiest, tending: tending, lines: now)
    }

    /// `本周完成 71%（上周 58%）`；看过去的周写 `那一周完成 61%（前一周 56%）`
    static func habitHeadline(_ h: HabitWeek, week: Week) -> String {
        let previous = h.previousRate.map { "（\(week.priorName) \(RecordStats.percent($0))）" } ?? ""
        return "\(week.selfName)完成 \(RecordStats.percent(h.rate))\(previous)"
    }

    // MARK: 其四 · 灵石

    struct Spend: Equatable {
        var cents: Int
        var topCategory: String?
        var topCents: Int
        /// 银行账单导到哪天（还在导入的账户都导到的最后一天，见 bankThrough）；只有手记、没导过账单时为 nil
        var coveredThrough: LocalDay?
        /// 账单没导到这周已过的最后一天：本周花费不全
        var incomplete: Bool
    }

    /// 停了多久不导的账户算“停用的旧卡”，不再拖累“导到哪天”：与复盘素材的本期花费同一个口径（从这一期第一天往前 45 天）
    static let activeAccountDays = 45

    /// 这周已过的日子里计入消费的扣款合计、最多的一类；没有一笔时为 nil（整节不显示）
    /// 合计与最多的一类直接用复盘素材“本期花费”的那一份（ReviewThread.spending，#12）：存草稿时卷面和素材的数对得上
    static func spend(_ transactions: [FinanceTransaction], sources: [FinanceSource], week: Week) -> Spend? {
        let sum = ReviewThread.spending(transactions, first: week.monday, last: week.last)
        guard sum.cents > 0 else { return nil }
        let covered = coveredThrough(sources, activeSince: week.monday.adding(days: -activeAccountDays))
        return Spend(cents: sum.cents, topCategory: sum.top?.category, topCents: sum.top?.cents ?? 0, coveredThrough: covered,
                     incomplete: covered.map { $0 < week.last } ?? false)
    }

    /// 银行账单导到哪天（手记不算账单；一份都没导过时为 nil）：就是复盘素材用的 ReviewThread.bankThrough(sources:activeSince:)，
    /// 两边对同一周说法一致（存草稿时卷面和素材不打架）
    static func coveredThrough(_ sources: [FinanceSource], activeSince: LocalDay) -> LocalDay? {
        ReviewThread.bankThrough(sources: sources, activeSince: activeSince).flatMap { LocalDay(key: $0) }
    }

    /// 银行流水导到哪天（规则只在 ReviewThread.bankThrough 写一份，这里转过去）
    static func bankThrough(_ ends: [(account: String, end: String)], activeSince: LocalDay) -> String? {
        ReviewThread.bankThrough(ends, activeSince: activeSince)
    }

    /// `本周花费 $312.40 · 最多一类：餐饮与外卖 $140.00`；看过去的周写“那一周花费”
    static func spendHeadline(_ s: Spend, week: Week) -> String {
        var text = "\(week.selfName)花费 \(FinanceEngine.money(s.cents))"
        if let top = s.topCategory { text += " · 最多一类：\(top) \(FinanceEngine.money(s.topCents))" }
        return text
    }

    /// `账单只导到 10月20日，本周不全`（过去的周“那一周不全”）；导全了为 nil
    static func spendNote(_ s: Spend, week: Week) -> String? {
        guard s.incomplete, let day = s.coveredThrough else { return nil }
        return "账单只导到 \(day.label(relativeTo: week.today))，\(week.selfName)不全"
    }

    // MARK: 其五 · 一条洞见

    /// 洞见一节的一句话与小字依据
    struct Note: Equatable {
        var text: String
        var basis: String
    }

    /// 卷中洞见里正向的几类，按这个次序挑第一条
    static let positiveKinds: [Insight.Kind] = [.writingStreak, .moodHabits, .moodWeekday, .habitWeekday]

    static func pickInsight(_ insights: [Insight]) -> Insight? {
        for kind in positiveKinds { if let hit = insights.first(where: { $0.kind == kind }) { return hit } }
        return nil
    }

    /// 这一周自己的一条正向变化（只报喜，挑第一条）：动笔天数比前一周多 → 心境比前一周明朗 → 功课完成率比前一周高 5 个百分点以上
    static func weekNote(_ entries: [RecordEntry], habits: HabitWeek? = nil, week: Week) -> Note? {
        let me = week.selfName, prior = week.priorName
        let basis = "\(me)对\(prior)"
        func inside(_ w: Week) -> [RecordEntry] { entries.filter { $0.day >= w.monday && $0.day <= w.last } }
        let now = inside(week), before = inside(week.previous)
        // 动笔天数
        let days = Set(now.map(\.day)).count, daysBefore = Set(before.map(\.day)).count
        if days >= 2, days > daysBefore {
            let text = daysBefore == 0 ? "\(me)动笔 \(days) 天，\(prior)还一篇没有。" : "\(me)动笔 \(days) 天，比\(prior)多 \(days - daysBefore) 天。"
            return Note(text: text, basis: "\(basis) · 动笔天数")
        }
        // 心境：两周各至少 2 天记了心境，平均起来高一档才说
        let moods = RecordStats.moodByDay(now), moodsBefore = RecordStats.moodByDay(before)
        if moods.count >= 2, moodsBefore.count >= 2 {
            let a = Int((moods.values.reduce(0, +) / Double(moods.count)).rounded())
            let b = Int((moodsBefore.values.reduce(0, +) / Double(moodsBefore.count)).rounded())
            if a > b { return Note(text: "\(me)心境平均「\(Mood.label(a))」，\(prior)是「\(Mood.label(b))」。", basis: "\(basis) · 日记心境") }
        }
        // 功课完成率（按卷上显示的百分数比）
        if let h = habits, let previous = h.previousRate {
            let a = Int((h.rate * 100).rounded()), b = Int((previous * 100).rounded())
            if a - b >= 5 { return Note(text: "\(me)功课完成 \(a)%，比\(prior)高 \(a - b) 个百分点。", basis: "\(basis) · 功课完成率") }
        }
        return nil
    }

    /// 其五取哪一条：先看这一周自己的正向变化；只有看本周时，才退回卷中洞见（近 90 日，说的是到今天为止的事）——
    /// 翻到过去的周不用它，免得那一周的卷上出现那一周之后才发生的事
    static func insight(own: Note?, rolling: [Insight], week: Week, windowDays: Int) -> Note? {
        if let own { return own }
        guard week.isCurrent, let hit = pickInsight(rolling) else { return nil }
        return Note(text: hit.text, basis: "卷中洞见 · 近 \(windowDays) 日 · \(hit.basis)")
    }

    // MARK: 其一没有摘句时

    /// 其一没有摘句时写什么。blank：整卷没有任何数据（没落笔、没功课、没花费）。
    /// 本周整卷空着（新手的第一周）多一句这卷怎么写满；过去的周只说那一周没有记录，不说“慢慢写满”
    static func emptyWords(week: Week, hasEntries: Bool, blank: Bool) -> (line: String, hint: String?) {
        if hasEntries { return (week.isCurrent ? "这一周的落笔都还没有成句的话。" : "那一周的落笔都没有成句的话。", nil) }
        if !week.isCurrent { return (blank ? "那一周没有留下记录。" : "那一周没有落笔。", nil) }
        return ("这一周还没有落笔。", blank ? "写下一句、打一次卡、记一笔账，这一卷就会慢慢写满。" : nil)
    }

    // MARK: 卷尾

    /// 周复盘草稿的标题：`10月19日–25日 周复盘`
    static func draftTitle(_ week: Week) -> String { "\(week.compactLabel) 周复盘" }

    /// 修行录落笔框草稿的头部：类型、复盘周期、补记日期（nil 是“今天”）、标题（都是偏好里存的原样字符串）
    struct DraftHead: Equatable {
        var kind: String
        var period: String
        var day: String?
        var title: String
    }

    /// 落笔框里已经是这一周的周复盘（上回存过、还没写完）：再点“存为周复盘草稿”不用问、也不再叠一份，直接回去接着写
    static func isSameWeekDraft(_ head: DraftHead, week: Week) -> Bool {
        head.kind == JournalKind.review.rawValue && head.title.trimmingCharacters(in: .whitespacesAndNewlines) == draftTitle(week)
    }

    /// “接在后面”时草稿头部怎么定：
    /// - 原稿是日记 / 灵感：改成复盘 · 周、补记日期 = 这周最后一天，空标题补上本周标题（正文原样留在前面）；
    /// - 原稿是这一周的周复盘：同上（只补空标题，不改用户写的标题）；
    /// - 原稿是别的周期（如“复盘 · 月”）或别的周的周复盘：周期、补记日期、标题一概不动，只把素材接在后面——不悄悄把月复盘改成周复盘
    static func appendedHead(_ old: DraftHead, week: Week) -> DraftHead {
        let title = old.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? draftTitle(week) : old.title
        let retargeted = DraftHead(kind: JournalKind.review.rawValue, period: ReviewPeriod.week.rawValue, day: draftDay(week).key, title: title)
        guard old.kind == JournalKind.review.rawValue else { return retargeted }
        guard old.period == ReviewPeriod.week.rawValue else { return old }
        let day = old.day.flatMap { LocalDay(key: $0) } ?? week.today
        return day >= week.monday && day <= week.sunday ? retargeted : old
    }

    /// 草稿的补记日期：这周最后一天，不晚于今天
    static func draftDay(_ week: Week) -> LocalDay { week.last }

    /// 插进草稿的〔本周摘句〕一段；没有摘句时为空
    static func quoteBlock(_ quotes: [Quote], today: LocalDay) -> String {
        guard !quotes.isEmpty else { return "" }
        return (["〔本周摘句〕"] + quotes.map { "· 「\($0.text)」（\($0.day.label(relativeTo: today))）" }).joined(separator: "\n")
    }

    /// 落笔框里已有没写完的草稿时，“接在后面”：原文去掉末尾空白，空一行接上
    static func appended(_ existing: String, _ addition: String) -> String {
        var head = existing
        while let last = head.last, last.isWhitespace { head.removeLast() }
        return head.isEmpty ? addition : head + "\n\n" + addition
    }

    /// 请 AI 写一封周信：可直接粘进 Claude Code 的一句话
    static func aiPrompt(_ week: Week) -> String {
        "用 apt-record 技能读我的快照，给我写这一周（\(week.compactLabel)）的小结，问我一两个问题后投成一篇周复盘。"
    }

    // MARK: 上次许下的下一步（#14）

    /// 这一周的“上次许下的下一步”从哪天之前找（不含当天）：这周一之前写的复盘，再加周一当天补写的上周复盘（周一写、没改日期的那篇）。
    /// 这一周自己的周复盘（周六、周日写的）许的是下一周的事，不算
    static func promiseBefore(_ week: Week) -> LocalDay { week.monday.adding(days: 1) }

    /// 许下的事隔了太久（一直没再写复盘）就不翻出来：那一篇不早于这周一往前 promiseDays 天
    static let promiseDays = 35

    static func promiseFresh(_ day: LocalDay, week: Week) -> Bool {
        day >= week.monday.adding(days: -promiseDays) && day < promiseBefore(week)
    }

    /// 小卷这一节只认**周复盘**（周期 week）：只写晚课日省的人，日省里的【下一步】是“明日第一件事”，不是给这一周许的，
    /// 翻出来会是周一那篇（6 天前给周二定的事），也和存草稿后素材卡（从周日起算）列的对不上。找不到同周期的就整节不出
    static func promiseFits(period: String, day: LocalDay, week: Week) -> Bool {
        period == ReviewPeriod.week.rawValue && promiseFresh(day, week: week)
    }
}

// MARK: - 首页回看入口（#14）

/// 今日洞府的三处回看入口（口径都在这里，CoreCheck 覆盖；画法与取数在 Views/DashboardHooks.swift）：
/// - 七日小卷纸笺：周日 18:00 到周一 12:00、那一周有记录时，正文最上面一条纸笺，点开就是七日小卷；× 掉本周不再出；
/// - 出关：最近一条记录（落笔或打卡）在 3 天以前、今天还没有记录时，落笔框下面一行“闭关 5 日，今日出关——从一句开始。”；
/// - 今日小结：20:00 起落笔卡底一行“今日：功课 3/5 · 已落 1 篇 · 心境未记”。
enum DashboardCues {
    /// 纸笺 × 掉的那一周（存周一的 dateKey）：同一周不再出
    static let stripDismissedKey = "weekly.strip.dismissed"
    /// 周日从几点起、周一到几点止出纸笺
    static let stripFromMinute = 18 * 60
    static let stripUntilMinute = WeeklyDigest.mondayCutoffMinute

    /// 这一刻首页该不该出纸笺、出的话是哪一周：周日 18:00 起是本周，周一 12:00 前是刚过完的上一周（与小卷默认打开的同一周）；其余时候 nil
    static func stripWeek(today: LocalDay, minute: Int) -> WeeklyDigest.Week? {
        switch today.weekdayIndex {
        case 6 where minute >= stripFromMinute: return WeeklyDigest.Week(monday: today.mondayOfWeek, today: today)
        case 0 where minute < stripUntilMinute: return WeeklyDigest.defaultWeek(today: today, minute: minute)
        default: return nil
        }
    }

    /// 纸笺上那一句：`七日已过 · 这一周落笔 9 篇、功课 71%`（周一上午看的是上一周，写“上一周”）。
    /// 那一周既没落笔、也没打过一次卡时 nil（不出纸笺）；没有功课、或一次卡都没打只写落笔（不写“功课 0%”），没落笔只写功课
    static func stripLine(week: WeeklyDigest.Week, entries: Int, habits: WeeklyDigest.HabitWeek?) -> String? {
        let practiced = habits.map { $0.lines.contains { $0.done > 0 } } ?? false
        guard entries > 0 || practiced else { return nil }
        var parts: [String] = []
        if entries > 0 { parts.append("落笔 \(entries) 篇") }
        if practiced, let habits { parts.append("功课 \(RecordStats.percent(habits.rate))") }
        let name = week.isCurrent ? "这一周" : "上一周"
        return "七日已过 · \(name)" + parts.joined(separator: "、")
    }

    /// 隔了几天算“闭关”：最近一条记录在这么多天以前（含）
    static let retreatDays = 3

    /// 闭关了几日：最近一条记录（落笔或打卡，不晚于今天的）那天到今天隔了几天；没到 retreatDays、今天已有记录、从没记录过时 nil
    static func retreat(lastRecord: LocalDay?, today: LocalDay) -> Int? {
        guard let lastRecord, lastRecord < today else { return nil }
        let days = lastRecord.days(to: today)
        return days >= retreatDays ? days : nil
    }

    /// `闭关 5 日，今日出关——从一句开始。`
    static func retreatLine(_ days: Int) -> String { "闭关 \(days) 日，今日出关——从一句开始。" }

    /// 今日小结从几点起出（到午夜为止，过了午夜就是新的一天）
    static let tonightFromMinute = 20 * 60

    static func showsTonight(minute: Int) -> Bool { minute >= tonightFromMinute }

    /// 今日小结那一行：`今日：功课 3/5 · 已落 1 篇 · 心境未记`。
    /// 今天没有要做的功课就不写功课；还没落笔写“尚未落笔”（不再说心境）；今天的落笔记了心境就写“心境 晴”（几篇取平均）。
    /// 没有功课、也没落笔时 nil（没什么可小结的，不出这一行）
    static func tonightLine(habitsDone: Int, habitsDue: Int, entries: Int, moods: [Int]) -> String? {
        guard habitsDue > 0 || entries > 0 else { return nil }
        var parts: [String] = []
        if habitsDue > 0 { parts.append("功课 \(habitsDone)/\(habitsDue)") }
        if entries == 0 {
            parts.append("尚未落笔")
        } else {
            parts.append("已落 \(entries) 篇")
            if moods.isEmpty {
                parts.append("心境未记")
            } else {
                let average = Double(moods.reduce(0, +)) / Double(moods.count)
                parts.append("心境 \(Mood.label(max(1, min(5, Int(average.rounded())))))")
            }
        }
        return "今日：" + parts.joined(separator: " · ")
    }
}
