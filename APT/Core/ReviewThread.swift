import Foundation

/// 复盘闭环（#12）的纯函数：从上一篇复盘里取【下一步】并拆成几条、回访的选择怎么存、按选择插回正文，
/// 素材里“本期花费”那一行，周一补写上周。
/// 取数（哪一篇算“上次”、参悟时的决定、账簿）在 Views/ChronicleSupport.swift 的 `ReviewThread` 扩展里。
enum ReviewThread {
    /// 回访一条“下一步”的三种答复：做到的进【所得】，没做到的进【所失】，改主意的进【所悟】
    enum Verdict: String, CaseIterable, Identifiable {
        case done, missed, changed

        var id: String { rawValue }

        var label: String {
            switch self {
            case .done: "做到了"
            case .missed: "没做到"
            case .changed: "改主意了"
            }
        }

        /// 插回正文时落在哪一段
        var section: String {
            switch self {
            case .done: "所得"
            case .missed: "所失"
            case .changed: "所悟"
            }
        }
    }

    /// 回访最多列几条
    static let maxSteps = 5
    /// 一条太长时只留这么多字（后面写“…”）
    static let maxStepLength = 60

    // MARK: 段名

    /// 认作段名的只有这几段（复盘模板四段，加晚课合成日省的【今日一愿】），而且要在行首（正文开头或换行之后，前面可有空格）。
    /// 正文里自己写的“读完【三体】”“先做【重要】那件事”不算段名，不会把一段从中间截断
    static let sectionNames = ["所得", "所失", "所悟", "下一步", "今日一愿"]
    /// 只当“段到这里为止”的界：落笔模板（Core/JournalTemplates）内置几套的其余段名——书名、摘句、所思、今日所成、卡在何处、
    /// 明日第一件事、事、感。复盘末尾接一套读书札记、一事一记时，【下一步】到【书名】【事】就截住，不把后面几段当成下一步。
    /// 同样只认行首；不拿来取段（section 只取 sectionNames 里的）
    static let boundaryNames: [String] = {
        var seen = Set(sectionNames)
        return JournalTemplates.builtins.flatMap { JournalTemplates.headings(in: $0.body) }.filter { seen.insert($0).inserted }
    }()
    private static let sectionMarker = try? NSRegularExpression(
        pattern: #"(?m)^[ \t\x{3000}]*【("# + (sectionNames + boundaryNames).map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")】"#)

    /// 正文里各段名（按出现先后，含只当界的 boundaryNames）：名字、【…】这几个字的范围、它所在那一行的行首（下一段从这里算起，上一段到这里为止）
    static func markers(in body: String) -> [(name: String, marker: Range<String.Index>, lineStart: String.Index)] {
        guard let regex = sectionMarker else { return [] }
        return regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match in
            guard let whole = Range(match.range, in: body), let name = Range(match.range(at: 1), in: body) else { return nil }
            return (String(body[name]), body.index(before: name.lowerBound)..<whole.upperBound, whole.lowerBound)
        }
    }

    /// 插进复盘正文的参考段的开头（ChronicleSupport 的 ReviewMaterial.block 用同一个）
    static let materialHead = "〔本期素材 · "

    // MARK: 取【下一步】

    /// 正文里 `【name】` 这一段：到下一个行首段名（或插进去的〔本期素材〕那一行）为止，去掉首尾空白。
    /// 同一段写了两次时取第一段有内容的；没有这一段、或都是空的返回 nil
    static func section(_ name: String, in body: String) -> String? {
        guard sectionNames.contains(name) else { return nil }
        let all = markers(in: body)
        for (index, item) in all.enumerated() where item.name == name {
            var end = index + 1 < all.count ? all[index + 1].lineStart : body.endIndex
            // 〔本期素材 · …〕这类插进来的参考段也算到头（只认在行首的）
            if let block = body[item.marker.upperBound..<end].range(of: "\n〔") { end = block.lowerBound }
            let content = body[item.marker.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { return content }
        }
        return nil
    }

    /// 【下一步】拆成几条：按换行、“；”“。”，以及“1. / 1、/（1）/ ① / · / - / •/ [ ]”这类条目记号拆开，
    /// 去掉记号和句末标点，重复的只留一条，最多 maxSteps 条。没有这一段（没用模板的复盘）、或写的是空的返回 []。
    /// 编号后面要跟着字才算编号（“读 20、30 页”“1.5 小时”不拆）；“下周：”这类冒号结尾的引子不算一条
    static func nextSteps(from body: String) -> [String] {
        guard let content = section("下一步", in: body) else { return [] }
        // 同一行里接着写的编号（“1. 跑步 2. 读书”“早睡2、跑步”“（1）…（2）…”“①…②…”“下周：1) …”）先断开
        var text = content
        for (regex, template) in inlineNumbering { text = replacing(regex, in: text, with: template) }
        let separators: Set<Character> = ["\n", "\r", "；", ";", "。", "！", "!"]
        var seen = Set<String>()
        var steps: [String] = []
        for piece in text.split(whereSeparator: { separators.contains($0) }) {
            var item = String(piece).trimmingCharacters(in: .whitespaces)
            // 冒号结尾的引子（“下周：”“接下来:”）只是领起下面几条
            if item.hasSuffix("：") || item.hasSuffix(":") { continue }
            item = replacing(leadingMarker, in: item, with: "")
            item = item.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "，,、：:")))
            guard !item.isEmpty, item.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if item.count > maxStepLength { item = String(item.prefix(maxStepLength)) + "…" }
            guard seen.insert(item).inserted else { continue }
            steps.append(item)
            if steps.count == maxSteps { break }
        }
        return steps
    }

    /// 编号：1. 1、 1) 1）（“1.5”这种小数不算）
    private static let number = #"\d{1,2}(?:[、)）]|[.．](?!\d))"#
    /// 编号后面跟着的得是字（或引号、书名号），“20、30 页”里的“20、”不算编号
    private static let numberThenWord = number + #"[ \t\x{3000}]*[\p{L}「“《]"#
    /// 同一行里接着写的编号断成新行；编出来存着，取“上次”时要连着看几十篇
    private static let inlineNumbering: [(NSRegularExpression, String)] = [
        // 空格后的编号：“1. 跑步 2. 读书”
        (#"\s+(?="# + numberThenWord + ")", "\n"),
        // 紧跟在汉字后的编号：“1、早睡2、跑步3、读书”（“第2、3章”的“第”后不拆）
        (#"(?<=[\p{Han}&&[^第]])(?="# + numberThenWord + ")", "\n"),
        // 括号编号：“（1）早睡（2）跑步”
        (#"\s*(?=[（(]\d{1,2}[)）])"#, "\n"),
        // 圈码：“①早睡②跑步”
        (#"\s*(?=[\x{2460}-\x{2473}])"#, "\n"),
        // 冒号引子后紧跟编号：“下周：1) 早睡 2) 跑步”（“23:30”不算）
        (#"([：:])[ \t\x{3000}]*(?=(?:"# + numberThenWord + #"|[（(]\d{1,2}[)）]|[\x{2460}-\x{2473}]))"#, "$1\n"),
    ].compactMap { pattern, template in (try? NSRegularExpression(pattern: pattern)).map { ($0, template) } }
    /// 行首记号（可叠用，如“- 1.”）：- · • * ・ 1. 1、 1） (1) 一、 ①，再加待办方框 [ ] / [x]
    private static let leadingMarker = try? NSRegularExpression(
        pattern: #"^(?:(?:[-–—·•*・●○■□☐☑✓✔]+|"# + number + #"|[（(]\d{1,2}[)）]|[一二三四五六七八九十][、.．]|[\x{2460}-\x{2473}])[ \t\x{3000}]*)*(?:\[[ xX]?\][ \t\x{3000}]*)?"#)

    private static func replacing(_ regex: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let regex else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    // MARK: 说法

    /// 一篇复盘管的是哪几天：周 = 那一周，月 = 那个月，日省、事后复盘、没填周期 = 那一天
    static func span(period: ReviewPeriod?, day: LocalDay) -> (first: LocalDay, last: LocalDay) {
        switch period {
        case .week: return (day.mondayOfWeek, day.mondayOfWeek.adding(days: 6))
        case .month: return (day.firstOfMonth, day.firstOfMonth.adding(days: 32).firstOfMonth.adding(days: -1))
        default: return (day, day)
        }
    }

    /// “10月18日”“10月12日–18日”“9月28日–10月4日”；不在今年的带上年份
    static func spanLabel(_ first: LocalDay, _ last: LocalDay, today: LocalDay) -> String {
        if first == last { return first.label(relativeTo: today) }
        guard first.year == last.year else { return "\(first.year)年\(first.shortLabel)–\(last.year)年\(last.shortLabel)" }
        let year = first.year == today.year ? "" : "\(first.year)年"
        if first.month == last.month { return "\(year)\(first.shortLabel)–\(last.day)日" }
        return "\(year)\(first.shortLabel)–\(last.shortLabel)"
    }

    /// 回访的小标题里那一篇：“10月12日–18日 周复盘”；没填周期写“复盘”。
    /// writing 是正在写的这一篇（周期、补记日期）：“上次”那篇管的正是同一周 / 同一个月时（例如 10月1日写的九月复盘、
    /// 周一没改日期写的上周复盘），按日期范围写会和正在写的这期同名，改写成“10月1日写的月复盘”
    static func promiseLabel(period raw: String, day: LocalDay, today: LocalDay,
                             writing: (period: ReviewPeriod, anchor: LocalDay)? = nil) -> String {
        let period = ReviewPeriod(rawValue: raw)
        let span = span(period: period, day: day)
        if let writing, let period, period == writing.period, period == .week || period == .month,
           span == self.span(period: writing.period, day: writing.anchor) {
            return "\(day.label(relativeTo: today))写的\(period.label)"
        }
        return spanLabel(span.first, span.last, today: today) + " " + (period?.label ?? "复盘")
    }

    // MARK: 回访的选择（存在草稿 draft.<页面>.followups）

    /// 每行“done\t跑三次步”；认不出的行跳过
    static func decode(_ raw: String) -> [String: Verdict] {
        var map: [String: Verdict] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let verdict = Verdict(rawValue: parts[0]), !parts[1].isEmpty else { continue }
            map[parts[1]] = verdict
        }
        return map
    }

    static func encode(_ map: [String: Verdict]) -> String {
        map.sorted { $0.key < $1.key }.map { "\($0.value.rawValue)\t\($0.key)" }.joined(separator: "\n")
    }

    /// 点一枚签：选上；再点同一枚是取消
    static func toggled(_ raw: String, key: String, verdict: Verdict) -> String {
        var map = decode(raw)
        map[key] = map[key] == verdict ? nil : verdict
        return encode(map)
    }

    /// 插进正文的一行：“· 跑三次步 —— 做到了”
    static func line(_ text: String, _ verdict: Verdict) -> String { "· \(text) —— \(verdict.label)" }

    /// 正文里已经插进去的：〔本期素材〕有没有、回访插过的各行（“· 跑三次步 —— 做到了”，可能后面又补了几个字）。
    /// 修行录落笔框每敲一个字算一次，只有这两样变了素材卡才跟着刷新
    struct Inserted: Equatable {
        var material = false
        var lines: Set<String> = []

        /// 这一条按这枚签插过没有（那一行后面自己补了字也算）
        func has(_ text: String, _ verdict: Verdict) -> Bool {
            let target = ReviewThread.line(text, verdict)
            return lines.contains { $0.hasPrefix(target) }
        }
    }

    static func inserted(in body: String) -> Inserted {
        var state = Inserted()
        for raw in body.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(materialHead) { state.material = true }
            if line.hasPrefix("· "), line.contains(" —— ") { state.lines.insert(line) }
        }
        return state
    }

    /// 点过签、还没进正文的几条（插入、入卷时补进去的就是这些）
    static func pending(_ items: [(text: String, verdict: Verdict)], in body: String) -> [(text: String, verdict: Verdict)] {
        let state = inserted(in: body)
        return items.filter { !state.has($0.text, $0.verdict) }
    }

    /// 按选择插回正文：做到的接在【所得】那段末尾，没做到的接【所失】，改主意的接【所悟】；
    /// 正文里没有那一段就在末尾补上段名；已经插过的同一行不再插（点两次“插入”不会重复）；
    /// 插过之后改了签（做到了 → 没做到），先删掉原样留着的旧那一行（后面自己补了字的不动），正文里不会两种说法并存
    static func insert(_ items: [(text: String, verdict: Verdict)], into body: String) -> String {
        var result = body
        // 同一条换了签：原样的旧行删掉
        let stale = Set(items.flatMap { item in Verdict.allCases.filter { $0 != item.verdict }.map { line(item.text, $0) } })
        if result.split(whereSeparator: \.isNewline).contains(where: { stale.contains($0.trimmingCharacters(in: .whitespaces)) }) {
            var kept = result.components(separatedBy: "\n")
            kept.removeAll { stale.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            result = kept.joined(separator: "\n")
        }
        for verdict in Verdict.allCases {
            let state = inserted(in: result)
            let lines = items.filter { $0.verdict == verdict && !state.has($0.text, verdict) }.map { line($0.text, verdict) }
            guard !lines.isEmpty else { continue }
            let joined = lines.joined(separator: "\n")
            let all = markers(in: result)
            guard let index = all.firstIndex(where: { $0.name == verdict.section }) else {
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                result = (trimmed.isEmpty ? "" : result + (result.hasSuffix("\n\n") ? "" : result.hasSuffix("\n") ? "\n" : "\n\n"))
                    + "【\(verdict.section)】\n" + joined + "\n"
                continue
            }
            let marker = all[index].marker
            // 到下一个行首段名为止（正文里自己写的【三体】不算）
            var end = index + 1 < all.count ? all[index + 1].lineStart : result.endIndex
            // 段里插过〔本期素材〕的，回访接在素材上面
            if let block = result[marker.upperBound..<end].range(of: "\n〔") { end = block.lowerBound }
            // 段里最后一个非空白字符之后：新行接在这里，原来的空行留在后面
            var cut = end
            while cut > marker.upperBound, result[result.index(before: cut)].isWhitespace { cut = result.index(before: cut) }
            let tail = String(result[cut..<end])
            result = String(result[..<cut]) + "\n" + joined + (tail.contains("\n") ? tail : "\n") + result[end...]
        }
        return result
    }

    // MARK: 周一补写上周

    /// 今天是周一、写的是周复盘、补记日期是今天（没改过）：问要不要改写上一周，返回上一周的首末两天；否则 nil
    static func lastWeekOffer(today: LocalDay, period: ReviewPeriod, picked: LocalDay?) -> (first: LocalDay, last: LocalDay)? {
        guard period == .week, today.weekdayIndex == 0, picked == nil || picked == today else { return nil }
        let sunday = today.adding(days: -1)
        return (sunday.adding(days: -6), sunday)
    }

    static func lastWeekOfferText(_ week: (first: LocalDay, last: LocalDay), today: LocalDay) -> String {
        "今天是周一：要写上一周（\(spanLabel(week.first, week.last, today: today))）的复盘吗？"
    }

    // MARK: 本期花费

    /// 计入消费的扣款合计与最多的一类（口径同灵石账簿：不含设为不计入的、转账取现等消费之外的类别）
    static func spending(_ rows: [FinanceTransaction], first: LocalDay, last: LocalDay) -> (cents: Int, top: (category: String, cents: Int)?) {
        let from = first.key, to = last.key
        var byCategory: [String: Int] = [:]
        for row in rows where row.date >= from && row.date <= to && FinanceEngine.isSpending(row) {
            byCategory[row.category, default: 0] -= row.amountCents
        }
        let total = byCategory.values.reduce(0, +)
        let top = byCategory.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
        return (total, top.map { ($0.key, $0.value) })
    }

    /// 银行流水导到哪天：各账户最后导入日里**最早**的那个（有一个账户没导到，合计就不全）。
    /// 只看还在用的账户（最后导入日不早于 activeSince），都停用了取最晚的那天；从没导入过银行流水（只有手记）时 nil。
    /// 规则只写这一份：七日小卷（WeeklyDigest.coveredThrough / bankThrough）也调这里
    static func bankThrough(_ ends: [(account: String, end: String)], activeSince: LocalDay) -> String? {
        var latest: [String: String] = [:]
        for (account, end) in ends { latest[account] = max(latest[account] ?? end, end) }
        let active = latest.values.filter { $0 >= activeSince.key }
        return active.min() ?? latest.values.max()
    }

    /// 同上，直接给账簿的导入记录（手记不算账单）。复盘素材与七日小卷都该用这一个口径，同一周两处说法才不会打架
    static func bankThrough(sources: [FinanceSource], activeSince: LocalDay) -> String? {
        bankThrough(sources.filter { $0.account != ManualExpense.account }
                        .compactMap { source in source.range.map { (account: source.account, end: $0.1) } },
                    activeSince: activeSince)
    }

    /// 只给了日期范围时猜周期（七日小卷存草稿只传首末两天）：周一起不满 7 天是周，1 日起同一个月是月，正好 7 天是事后复盘
    static func inferPeriod(first: LocalDay, last: LocalDay) -> ReviewPeriod? {
        let days = first.days(to: last)
        if days == 0 { return .day }
        if first.weekdayIndex == 0 && days <= 6 { return .week }
        if first.day == 1 && first.year == last.year && first.month == last.month { return .month }
        if days == 6 { return .event }
        return nil
    }

    /// 上一期（同样长的那几天）与它的叫法：周 → 上周，月 → 上月，事后复盘 → 前 7 天；这一期还没过完时比“同期”。日省不比
    static func previous(period: ReviewPeriod?, first: LocalDay, last: LocalDay) -> (first: LocalDay, last: LocalDay, name: String)? {
        switch period {
        case .week:
            let partial = last < first.adding(days: 6)
            return (first.adding(days: -7), last.adding(days: -7), partial ? "上周同期" : "上周")
        case .month:
            let monthEnd = first.firstOfMonth.adding(days: 32).firstOfMonth.adding(days: -1)
            let prevEnd = first.firstOfMonth.adding(days: -1)
            let prevFirst = prevEnd.firstOfMonth
            let partial = last < monthEnd
            let prevLast = partial ? min(prevFirst.adding(days: first.days(to: last)), prevEnd) : prevEnd
            return (prevFirst, prevLast, partial ? "上月同期" : "上月")
        case .event:
            return (first.adding(days: -7), last.adding(days: -7), "前 7 天")
        default:
            return nil
        }
    }

    /// 素材里的一行灵石：
    /// - `灵石：本期花费 $312.40（较上周 +12%），最多一类是 餐饮与外卖 $140.00。`（只有一类时：`…，全在 餐饮与外卖。`）
    /// - 银行流水没导到这一期的最后一天：`灵石：账单只导到 10月18日，本期花费不全：已知 $210.00。`
    /// 这一期没有任何花费时 nil（不写）；上一期也没导全、或上一期是 0 时不比
    static func spendingLine(rows: [FinanceTransaction], first: LocalDay, last: LocalDay, period: ReviewPeriod?,
                             bankThrough through: String?, today: LocalDay) -> String? {
        let current = spending(rows, first: first, last: last)
        guard current.cents > 0 else { return nil }
        if let through, through < last.key {
            let day = LocalDay(key: through).map { $0.label(relativeTo: today) } ?? through
            return "灵石：账单只导到 \(day)，本期花费不全：已知 \(FinanceEngine.money(current.cents))。"
        }
        var text = "灵石：本期花费 \(FinanceEngine.money(current.cents))"
        if let prev = previous(period: period, first: first, last: last), through.map({ $0 >= prev.last.key }) ?? true {
            let before = spending(rows, first: prev.first, last: prev.last).cents
            if let change = change(current.cents, from: before) {
                text += change == "持平" ? "（与\(prev.name)持平）" : "（较\(prev.name) \(change)）"
            }
        }
        if let top = current.top {
            // 只有一类时不把总额再写一遍
            text += top.cents == current.cents ? "，全在 \(top.category)" : "，最多一类是 \(top.category) \(FinanceEngine.money(top.cents))"
        }
        return text + "。"
    }

    /// “+12%”“−8%”“持平”；上一期是 0 时 nil
    static func change(_ current: Int, from previous: Int) -> String? {
        guard previous > 0 else { return nil }
        let percent = Int((Double(current - previous) / Double(previous) * 100).rounded())
        if percent == 0 { return "持平" }
        return percent > 0 ? "+\(percent)%" : "−\(-percent)%"
    }
}
