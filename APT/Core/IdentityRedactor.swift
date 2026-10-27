import Foundation

// 问道灵枢“隐去姓名”：开着时，把档案里写下的称呼（姓名、昵称、希望的称呼）在整份摘要里换成“〔姓名〕”——
// 日记正文、目标 / 日程标题、手记备注里写到的也换（纯逻辑）。只作用于复制 / 导出 / 发给外部 AI 的那份，应用里的记录不变；
// 快照、岁月长卷导出不经过这里。
// 已知局限：只认档案里写下的称呼本身，日记里用的别称认不出；两个字的称呼若恰是常用词，正文里的这个词也会被换掉。

enum IdentityRedactor {
    static let placeholder = "〔姓名〕"

    /// 档案称呼 → 要替换的名字（按长度降序：“青岚子”先于“青岚”，“张伟（Alex）”先于“张伟”）。分两层拆：
    /// 1. 按“；、,，/”与换行拆成一个个称呼；
    /// 2. 每个称呼再按空白、括号（（）()[]【】「」等）、间隔号（·•・）拆成几段，每段去掉首尾标点——
    ///    “张伟（Alex）”“张伟 (Alex)”拆出“张伟”“Alex”，“亚历克斯·张”拆出“亚历克斯”（“张”太短，不单独换），
    ///    拆得开的称呼整段原文也留着（正文里照原样写的，整段换成一个〔姓名〕）。
    /// 汉字 ≥ 2 个、或拉丁字母 ≥ 3 个才算（太短容易误伤普通词：单个“张”、一个字母都不换）；不分大小写去重
    static func names(from values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ name: String) {
            let han = name.unicodeScalars.filter(isHan).count
            let latin = name.unicodeScalars.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count
            guard han >= 2 || latin >= 3, seen.insert(name.lowercased()).inserted else { return }
            result.append(name)
        }
        for value in values {
            for piece in value.split(whereSeparator: { listSeparators.contains($0) || $0.isNewline }) {
                let whole = piece.trimmingCharacters(in: .whitespaces)
                let parts = whole.split(whereSeparator: { nameSeparators.contains($0) || $0.isWhitespace })
                    .map { $0.trimmingCharacters(in: edgeMarks) }
                    .filter { !$0.isEmpty }
                if parts.count > 1 { add(whole) }
                parts.forEach(add)
            }
        }
        return result.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    /// 汉字名直接替换；含拉丁字母的名字按单词边界、不分大小写替换（"Alex" 换，"Alexson" 不换）。
    /// 所有名字合成一个正则一遍替换完：换进去的“〔姓名〕”不会再被别的名字匹配
    static func redact(_ text: String, names: [String]) -> String {
        guard let matcher = matcher(names) else { return text }
        return redact(text, matcher: matcher)
    }

    /// 整份摘要：编码成 JSON → 读成字典 → 只替换字符串值、不碰键名（递归）→ 写回 → 解码。
    /// 非有限数（心境平均、每周时长等 Double 偶尔是 NaN / 无穷大）先写成占位字符串再原样读回。
    /// 往返失败（理论上不会：键没动、值只换文字）时不返回原样，而是清空了档案、目标、修行录、日程、本月手记的副本（宁缺不漏）。
    static func redact(_ summary: PlannerSummary, names: [String]) -> PlannerSummary {
        guard let matcher = matcher(names) else { return summary }
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: Marker.positive, negativeInfinity: Marker.negative, nan: Marker.nan)
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: Marker.positive, negativeInfinity: Marker.negative, nan: Marker.nan)
        func replaced(_ value: Any) -> Any {
            switch value {
            case let text as String: return Marker.all.contains(text) ? text : redact(text, matcher: matcher)
            case let array as [Any]: return array.map(replaced)
            case let object as [String: Any]: return object.mapValues(replaced)
            default: return value
            }
        }
        if let data = try? encoder.encode(summary),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let back = try? JSONSerialization.data(withJSONObject: replaced(object), options: [.fragmentsAllowed]),
           let result = try? decoder.decode(PlannerSummary.self, from: back) {
            return result
        }
        var stripped = summary
        stripped.profile = [:]
        stripped.goals = []
        stripped.journal = []
        stripped.past = []
        stripped.upcoming = []
        stripped.recurringEvents = []
        stripped.financeToDate = nil
        stripped.focusQuestion = redact(summary.focusQuestion, matcher: matcher)
        return stripped
    }

    // MARK: 内部

    /// 非有限数的占位：与 SummaryRenderer.json 同一前缀，三种各一个，NaN 读回来仍是 NaN
    private enum Marker {
        static let positive = "APT-NONFINITE-NUMBER+inf"
        static let negative = "APT-NONFINITE-NUMBER-inf"
        static let nan = "APT-NONFINITE-NUMBER-nan"
        static let all: Set<String> = [positive, negative, nan]
    }

    /// 几个称呼之间的分隔（第一层）
    private static let listSeparators: Set<Character> = ["；", ";", "、", ",", "，", "/", "／"]
    /// 一个称呼里几段之间的分隔（第二层，另加空白）：括号、间隔号
    private static let nameSeparators: Set<Character> = ["（", "）", "(", ")", "[", "]", "【", "】", "「", "」", "『", "』",
                                                         "《", "》", "〈", "〉", "·", "•", "・", "‧"]
    /// 每段首尾去掉的：标点、符号、空白（“Alex.”“-青岚-”只留名字本身）
    private static let edgeMarks = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }

    private static func matcher(_ names: [String]) -> NSRegularExpression? {
        let usable = names.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        guard !usable.isEmpty else { return nil }
        let alternatives = usable.map { name -> String in
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let latin = name.unicodeScalars.contains { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
            // 拉丁名按单词边界：前后不能紧挨字母或数字（不用 \b：ICU 把汉字也当单词字符，“Alex今天”里的 Alex 会认不出）
            return latin ? "(?<![A-Za-z0-9_])" + escaped + "(?![A-Za-z0-9_])" : escaped
        }
        return try? NSRegularExpression(pattern: alternatives.joined(separator: "|"), options: [.caseInsensitive])
    }

    private static func redact(_ text: String, matcher: NSRegularExpression) -> String {
        guard !text.isEmpty else { return text }
        return matcher.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                withTemplate: NSRegularExpression.escapedTemplate(for: placeholder))
    }
}
