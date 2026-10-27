import Foundation

/// 习惯的“同类说法”：跑步、游泳都算“运动”，打坐算“冥想”，看书算“读书”……
/// 随手记认打卡（QuickParse）用它；飞剑传书打卡对不上习惯名时，也用 match 找同类说法。纯逻辑，CoreCheck 可测。
///
/// 一组词就是“同一件事的几种说法”。功课名里含有某组的词（“运动”“晨跑打卡”“每日冥想”），这项功课就属于那一组；
/// 传入的名字（或随手记的一句话）里含有同一组的词、且这组只对上一项功课，就算对上。对上两项及以上时不猜，当作对不上。
/// 词组可以增补：照下面的样子加一行即可。
enum HabitAlias {
    struct Group {
        /// 这组的说法（第一个是这组的名字）
        var words: [String]
        /// 只有跟着数量一起出现才算的弱说法（“走了 5 公里”算步数，单说“他走了”不算）
        var weak: [String] = []
        /// 弱说法要跟着的数量单位（单位写法见 QuickParse 的单位表）
        var weakUnits: Set<String> = []
        /// 弱说法还要句子里有这些字之一（“喝了两杯水”算喝水，“喝了 3 杯咖啡”不算）；空 = 不要求
        var weakNeeds: [String] = []
        /// 这组的说法与功课是同一回事（打坐就是冥想）：随手记没写数量时可以替他记满；
        /// 只是相关（散步之于“步数 8000”、英语之于“背单词 30 个”）时不替他记满，先记日记
        var fillsTarget = true
        /// 组里更近的几小撮（撸铁就是力量、夜跑就是跑步）：同一组对上几项功课时，先找名字里有这一撮说法的那项
        var close: [[String]] = []
    }

    static let groups: [Group] = [
        Group(words: ["运动", "锻炼", "健身", "跑步", "慢跑", "晨跑", "夜跑", "游泳", "骑车", "骑行", "打球", "篮球", "羽毛球", "瑜伽", "撸铁", "举铁", "力量"],
              weak: ["跑了", "游了", "骑了"], weakUnits: ["公里", "米", "分钟", "小时"],
              close: [["力量", "撸铁", "举铁"], ["跑步", "慢跑", "晨跑", "夜跑", "跑了"], ["游泳", "游了"], ["骑车", "骑行", "骑了"],
                      ["打球", "篮球", "羽毛球"]]),
        Group(words: ["步数", "走路", "散步", "步行", "万步"], weak: ["走了", "走"], weakUnits: ["步", "公里", "米"], fillsTarget: false),
        Group(words: ["冥想", "打坐", "静坐", "正念"]),
        Group(words: ["读书", "阅读", "看书", "晨读", "早读", "夜读"], weak: ["看了", "读了"], weakUnits: ["页", "章", "本"]),
        Group(words: ["喝水", "饮水", "补水"], weak: ["喝了"], weakUnits: ["杯", "毫升", "升"], weakNeeds: ["水"]),
        Group(words: ["早睡", "入睡", "不熬夜"]),
        Group(words: ["早起", "起床"]),
        Group(words: ["背单词", "单词", "背词", "英语"], fillsTarget: false),
        Group(words: ["写作", "码字", "写论文"], fillsTarget: false),
        Group(words: ["拉伸", "伸展"]),
    ]

    /// 同类对上的结果：index 是对上的那项功课在 titles 里的下标，via 是传入的名字里认出的那个同类词
    /// （传入“晨跑”、功课叫“运动” → index 指向“运动”，via = “晨跑”）
    struct Match: Equatable {
        var index: Int
        var via: String
    }

    /// 比较用的写法：与 NameMatch 相同（去掉首尾空白再转小写）
    static func key(_ text: String) -> String { NameMatch.key(text) }

    /// 功课名的核心词：去掉括号里的话、开头的“每天 / 每日”、末尾的数量与单位（“晨读二十分钟”→“晨读”、“早睡（23:30 前）”→“早睡”、
    /// “每天喝水 8 杯”→“喝水”）。去完不到 2 个字、或与整名一样时为 nil（随手记说“晨读”也认得「晨读二十分钟」）
    static func coreKey(_ title: String) -> String? {
        let whole = key(title)
        var t = whole
        // 括号里的补充说明
        for (open, close) in [("（", "）"), ("(", ")"), ("【", "】"), ("[", "]")] {
            while let a = t.range(of: open), let b = t.range(of: close, range: a.upperBound..<t.endIndex) {
                t.removeSubrange(a.lowerBound..<b.upperBound)
            }
        }
        t = t.trimmingCharacters(in: .whitespaces)
        for head in ["每天", "每日", "天天"] where t.hasPrefix(head) {
            t = String(t.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if t.hasSuffix("打卡"), t.count > 2 { t = String(t.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        // 末尾的“二十分钟”“8 杯”“30min”：先去单位，再去前面的数
        let chars = Array(t)
        var end = chars.count
        for (spelling, _) in QuickParse.unitSpellings {
            let w = Array(spelling.lowercased())
            if w.count < end, Array(chars[(end - w.count)..<end]) == w { end -= w.count; break }
        }
        if end < chars.count {
            var k = end
            while k > 0, chars[k - 1] == " " { k -= 1 }
            let numeral: (Character) -> Bool = { c in
                (c.isASCII && (c.isNumber || c == ".")) || QuickParse.chineseDigits[c] != nil || QuickParse.chineseUnits[c] != nil || c == "半"
            }
            var start = k
            while start > 0, numeral(chars[start - 1]) { start -= 1 }
            // 单位前面要真有个数（“喝水杯”不去）
            end = start < k ? start : chars.count
        }
        t = String(chars[0..<end]).trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t != whole else { return nil }
        return t
    }

    /// 同一组的说法对上了几项功课（owners 是这几项在 titles 里的下标）时，按这个说法挑一项：
    /// 先找名字里含有这个说法（或组里同一撮的说法）的那项——“撸铁”→「力量训练」；
    /// 再退一步挑名字就是组名的那项——“跑步”在「运动」「力量训练」之间记「运动」。还挑不出时 nil（不猜）
    static func preferred(word: String, group g: Int, owners: [Int], titles: [String]) -> Int? {
        guard groups.indices.contains(g) else { return nil }
        if owners.count == 1 { return owners[0] }
        let w = key(word)
        let near = Set([w] + groups[g].close.filter { $0.contains(w) }.flatMap { $0 })
        let named = owners.filter { i in titles.indices.contains(i) && near.contains { key(titles[i]).contains($0) } }
        if named.count == 1 { return named[0] }
        let pool = named.isEmpty ? owners : named
        let plain = pool.filter { titles.indices.contains($0) && key(titles[$0]) == groups[g].words[0] }
        return plain.count == 1 ? plain[0] : nil
    }

    /// 功课名属于哪几组（功课名里含有这组的某个说法；“早睡早起”同时属于两组）
    static func groups(ofTitle title: String) -> [Int] {
        let k = key(title)
        guard !k.isEmpty else { return [] }
        return groups.indices.filter { g in groups[g].words.contains { k.contains($0) } }
    }

    /// 一段话里认出的同类词：每组取这段话里最长的那个说法；弱说法只在 units 里有它要的单位时才算
    static func words(in text: String, units: Set<String> = []) -> [(group: Int, word: String)] {
        let k = key(text)
        guard !k.isEmpty else { return [] }
        var found: [(group: Int, word: String)] = []
        for (g, group) in groups.enumerated() {
            var candidates = group.words.filter { k.contains($0) }
            if !group.weakUnits.isDisjoint(with: units), group.weakNeeds.isEmpty || group.weakNeeds.contains(where: { k.contains($0) }) {
                candidates += group.weak.filter { k.contains($0) }
            }
            if let best = candidates.max(by: { $0.count < $1.count }) { found.append((g, best)) }
        }
        return found
    }

    /// 名字对不上任何功课时再查同类（先用 NameMatch.index 找同名的，对不上再调这里）：
    /// name 里认出的同类词所在的组，与功课名所在的组相同、且合起来只对上一项功课 → 对上；对上多项或一项都没有 → nil。
    /// 只看正式说法，不看弱说法（传书写的是习惯名，不是一句话）
    static func match(_ name: String, titles: [String]) -> Match? {
        let found = words(in: name)
        guard !found.isEmpty else { return nil }
        let titleGroups = titles.map(groups(ofTitle:))
        var hits: [Int: String] = [:]
        for (group, word) in found {
            for (index, owned) in titleGroups.enumerated() where owned.contains(group) {
                // 同一项功课被两组同时对上时，记较长的那个说法
                if let old = hits[index], old.count >= word.count { continue }
                hits[index] = word
            }
        }
        guard hits.count == 1, let only = hits.first else { return nil }
        return Match(index: only.key, via: only.value)
    }

    /// 同类说法 word（match 的 via）记到功课 title 上、又没写数量时，能不能替他记满目标值：
    /// 同一回事的组（打坐之于冥想）能；只是相关的组（fillsTarget 为假：散步之于「步数」、英语之于「背单词」、写论文之于「写作」）、
    /// 而功课名里又没有这个说法时不能——与随手记“说到「步数」但没写数量，先记成日记”同一规矩
    static func fillsTarget(via word: String, title: String) -> Bool {
        let w = key(word)
        guard !w.isEmpty, !key(title).contains(w) else { return true }
        return groups.allSatisfy { $0.fillsTarget || !($0.words.contains(w) || $0.weak.contains(w)) }
    }

    /// match 对不上时的候选：name 里认出的同类词所在的组，对上的那几项功课（升序下标）。
    /// 传书打卡“跑步”而库里有「运动」「力量训练」两项时，退回那一条并列出这两项
    static func candidates(_ name: String, titles: [String]) -> [Int] {
        let found = Set(words(in: name).map(\.group))
        guard !found.isEmpty else { return [] }
        return titles.indices.filter { !Set(groups(ofTitle: titles[$0])).isDisjoint(with: found) }
    }

    /// 给 AI 的投递说明里“也能对上的说法”一列：每项功课按同类说法还能对上的词（名字里已有的不列）。
    /// 一组同时对上几项功课时，那组的词对哪一项都不算（传书时不猜），不列；每项最多 limit 个
    static func readmeWords(titles: [String], limit: Int = 8) -> [[String]] {
        let owned = titles.map(groups(ofTitle:))
        return titles.indices.map { i in
            let k = key(titles[i])
            var list: [String] = []
            for g in owned[i] where owned.indices.filter({ owned[$0].contains(g) }).count == 1 {
                list += groups[g].words.filter { !k.contains($0) && !list.contains($0) }
            }
            return Array(list.prefix(limit))
        }
    }

    /// README“也能对上的说法”那一格：hasTarget（功课有数量目标）时，只是相关的说法（散步之于「步数」）另起一段、注明“需写数量”——
    /// 不写 quantity 时传书不替他记满，那一条会被退回。没有说法时“—”
    static func readmeCell(_ words: [String], title: String, hasTarget: Bool) -> String {
        guard !words.isEmpty else { return "—" }
        let loose = hasTarget ? words.filter { !fillsTarget(via: $0, title: title) } : []
        let plain = words.filter { !loose.contains($0) }
        var parts: [String] = []
        if !plain.isEmpty { parts.append(plain.joined(separator: "、")) }
        if !loose.isEmpty { parts.append(loose.joined(separator: "、") + "（需写数量）") }
        return parts.joined(separator: "；")
    }
}
