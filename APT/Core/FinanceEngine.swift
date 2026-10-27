import Foundation
import CryptoKit

/// 灵石账簿的计算逻辑，逐条对应旧版（Python 版）的 `finance.py` 与 `finance_monthly.py`。
/// 只陈述账面事实：不推断购买内容，也不把“支出下降”当成已经省下的钱。
enum FinanceEngine {
    // MARK: 目录

    static let categories = ["餐饮与外卖", "超市与食品", "交通出行", "通讯与网络", "软件与会员", "教育与学费",
                             "购物", "健康与健身", "娱乐", "彩票", "银行手续费", "待分类消费",
                             "投资转账", "借出款", "转账待确认", "现金取款", "转入款待确认", "利息收入"]
    /// 不计入“消费”的扣款或入账
    static let nonSpend: Set<String> = ["投资转账", "借出款", "转账待确认", "现金取款", "转入款待确认", "利息收入"]
    static let reviewCategories: Set<String> = ["转账待确认", "转入款待确认", "待分类消费"]
    static var spendCategories: [String] { categories.filter { !nonSpend.contains($0) } }

    static let rules: [(category: String, pattern: String)] = [
        ("软件与会员", #"OPENAI|CHATGPT|GOOGLE.*ONE|AMZNPRIME|UBER.*ONE MEMBERSHIP|APPLE.COM/BILL|X CORP.*PAID|NETFLIX|DISNEY PLUS"#),
        ("交通出行", #"DIDIMOBILITY|UBER.*TRIP|TRANSPORTFORNSW|TRANSPORT FOR NSW|TFNSW OPAL|13CABS|AMPOL|CALTEX"#),
        ("通讯与网络", #"TELSTRA|OPTUS|VODAFONE|AUSSIE BROADBAND"#),
        ("教育与学费", #"STUDENT FEES|UNIVERSITY"#),
        ("健康与健身", #"ANYTIME FITNESS|CHEMIST WAREHOUSE|PRICELINE PHARMACY|SPECSAVERS"#),
        ("银行手续费", #"INTERNATIONAL TRANSACTION FEE|ACCOUNT.*FEE"#),
        ("超市与食品", #"COLES|WW METRO|WOOLWORTHS|ALDI STORES|IGA |HARRIS FARM|HMART"#),
        ("餐饮与外卖", #"UBER.*EATS|HUNGRYPANDA|MENULOG|DOORDASH|MCDONALDS|KFC |HUNGRY JACK|DOMINOS|SUBWAY|GUZMAN Y GOMEZ|NANDOS|STARBUCKS|SUSHI HUB"#),
        ("购物", #"AMAZON AU|TAOBAO"#),
        ("娱乐", #"HOYTS|TICKETEK|TICKETMASTER"#),
        ("彩票", #"TATTS ONLINE|THE LOTT|LOTTERYWEST"#),
    ]

    static let merchantGroups: [(key: String, label: String, pattern: String)] = [
        ("chatgpt", "ChatGPT", #"OPENAI.*CHATGPT"#),
        ("telstra", "Telstra", #"TELSTRA"#),
        ("optus", "Optus", #"OPTUS"#),
        ("ride_hail", "DiDi / Uber 打车", #"DIDIMOBILITY|UBER.*TRIP"#),
        ("delivery", "外卖平台", #"UBER.*EATS|HUNGRYPANDA|MENULOG|DOORDASH"#),
        ("lottery", "彩票", #"TATTS ONLINE|THE LOTT|LOTTERYWEST"#),
        ("gym", "Anytime Fitness", #"ANYTIME FITNESS"#),
        ("prime", "Amazon Prime", #"AMZNPRIME"#),
        ("uber_one", "Uber One", #"UBER.*ONE MEMBERSHIP"#),
        ("x", "X 付费功能", #"X CORP.*PAID"#),
        ("google_one", "Google One", #"GOOGLE.*ONE"#),
        ("apple", "Apple 账单", #"APPLE.COM/BILL"#),
    ]

    static let budgetLabels: [(key: String, label: String)] = [("dining", "餐饮与外卖"), ("ride_hail", "打车"), ("entertainment", "娱乐与彩票")]
    static let serviceKeys: Set<String> = ["chatgpt", "telstra", "optus", "gym", "prime", "uber_one", "x", "google_one", "apple"]

    // MARK: 工具

    /// 编译好的正则，连同它必须出现的字面片段（见 requiredLiterals；空数组 = 这条不预筛）
    private static var regexCache: [String: (regex: NSRegularExpression, literals: [[[UInt8]]])] = [:]
    static func matches(_ pattern: String, _ text: String) -> Bool {
        let entry: (regex: NSRegularExpression, literals: [[[UInt8]]])
        if let cached = regexCache[pattern] {
            entry = cached
        } else {
            guard let made = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
            entry = (made, requiredLiterals(pattern) ?? [])
            regexCache[pattern] = entry
        }
        // 纯 ASCII 的文字里，每一支都缺至少一段必需的字面片段时，正则不可能命中：直接返回 false，结果相同，只是不必跑正则
        // （账单分组、商户名每笔要对十几条正则，绝大多数是这样筛掉的）
        if !entry.literals.isEmpty, lacksLiterals(text, entry.literals) { return false }
        return entry.regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 正则每一支（按 | 分）里必须原样出现的字面片段，大写。只认最简单的写法：普通字符、`.`、`.*`、可有可无的 `?`、
    /// `\s` `\b` 这类、转义的标点；碰到括号、方括号、`+`、`{}`、`^` `$`、别的转义或非 ASCII 字符就返回 nil（这条不预筛）。
    /// 某一支一段都取不出来（例如 `.*`）也返回 nil。
    static func requiredLiterals(_ pattern: String) -> [[[UInt8]]]? {
        let plain = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 /:-_,&'#@!%=<>~\";".utf8)
        let quotable = Set(".*?+|()[]{}^$\\/-:&#".utf8)
        let classes = Set("sSdDwWbB".utf8)
        var branches: [[[UInt8]]] = []
        var branch: [[UInt8]] = []
        var run: [UInt8] = []
        var lastWasLiteral = false
        func endRun() {
            if !run.isEmpty { branch.append(run.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 32 : $0 }) }
            run = []
            lastWasLiteral = false
        }
        func endBranch() -> Bool {
            endRun()
            guard !branch.isEmpty else { return false }
            branches.append(branch)
            branch = []
            return true
        }
        var bytes = Array(pattern.utf8)[...]
        while let byte = bytes.popFirst() {
            switch byte {
            case UInt8(ascii: "|"):
                guard endBranch() else { return nil }
            case UInt8(ascii: "\\"):
                guard let next = bytes.popFirst() else { return nil }
                if quotable.contains(next) {
                    run.append(next)
                    lastWasLiteral = true
                } else if classes.contains(next) {
                    endRun()
                } else {
                    return nil
                }
            case UInt8(ascii: "."):
                endRun()
            case UInt8(ascii: "?"), UInt8(ascii: "*"):
                // 前一个字可有可无：从这一段里拿掉
                if lastWasLiteral { run.removeLast() }
                endRun()
            default:
                guard plain.contains(byte) else { return nil }
                run.append(byte)
                lastWasLiteral = true
            }
        }
        guard endBranch() else { return nil }
        return branches
    }

    /// 文字是纯 ASCII，且每一支都至少缺一段必需的字面片段（不分大小写）时为 true。文字含非 ASCII 字符、
    /// 或取不到连续的字节时为 false：照常交给正则（大小写折叠、组合字符等交给正则自己判断）。
    private static func lacksLiterals(_ text: String, _ branches: [[[UInt8]]]) -> Bool {
        text.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            guard bytes.allSatisfy({ $0 < 0x80 }) else { return false }
            return !branches.contains { branch in branch.allSatisfy { contains(bytes, $0) } }
        } ?? false
    }

    /// ASCII 字节里是否有 needle（needle 已是大写，haystack 的小写字母按大写比）
    private static func contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            var offset = 0
            while offset < needle.count {
                let byte = haystack[start + offset]
                guard (byte >= 0x61 && byte <= 0x7A ? byte - 32 : byte) == needle[offset] else { break }
                offset += 1
            }
            if offset == needle.count { return true }
        }
        return false
    }

    /// 与 Python `json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))` 相同的输出（仅支持字符串与整数数组），
    /// 用于计算与旧版一致的交易 ID，保证同一份 CSV 重复导入时能识别为重复。
    static func pythonJSON(_ values: [Any]) -> String {
        func string(_ s: String) -> String {
            var out = "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case "\u{08}": out += "\\b"
                case "\u{0C}": out += "\\f"
                default:
                    if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
                }
            }
            return out + "\""
        }
        return "[" + values.map { value -> String in
            switch value {
            case let s as String: return string(s)
            case let n as Int: return String(n)
            default: return "null"
            }
        }.joined(separator: ",") + "]"
    }

    static func sha256(_ text: String) -> String { hex(SHA256.hash(data: Data(text.utf8))) }

    private static let hexDigits = Array("0123456789abcdef".utf8)
    /// 字节转小写十六进制：结果与逐字节 String(format: "%02x") 拼接完全相同（交易 ID 不变），但快得多（导入时每行要算两次哈希）。
    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func digest(_ values: [Any]) -> String { sha256(pythonJSON(values)) }

    static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// 存储里的 UTC 时间戳（新版 "…Z"、旧版 "…+00:00"）按本地时区显示；存储格式不变。解析失败时原样返回。
    static func localStamp(_ iso: String, format: String = "yyyy-MM-dd HH:mm", timeZone: TimeZone = .current) -> String {
        guard let date = LegacyMapper.timestamp(iso) else { return iso }
        return DateText.string(date, format: format, timeZone: timeZone)
    }

    /// "+1,234.50" / "-21.80" / "$5" → 分；超过两位小数或不是数字时报错。
    static func cents(_ text: String) throws -> Int {
        var s = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
        var sign = 1
        if s.hasPrefix("-") { sign = -1; s.removeFirst() } else if s.hasPrefix("+") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !s.isEmpty, parts.count <= 2, let whole = Int(parts[0].isEmpty ? "0" : String(parts[0])), whole >= 0,
              parts[0].allSatisfy(\.isNumber) else { throw FinanceError.invalid("金额必须是有效的两位小数澳元数值") }
        var fraction = 0
        if parts.count == 2 {
            let f = String(parts[1])
            guard f.count <= 2, f.allSatisfy(\.isNumber) else { throw FinanceError.invalid("金额必须是有效的两位小数澳元数值") }
            fraction = Int(f.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        }
        guard whole <= 100_000_000 else { throw FinanceError.invalid("金额超出范围") }
        return sign * (whole * 100 + fraction)
    }

    /// 手记金额（正数，单位分）：随手记、手记一笔、交易编辑、飞剑传书共用这一套规则。
    /// 接受 "18.5"、"$18.50"、"A$18"、"1,234.50"、"18,5"、"18，5"、"１８．５"：全角逗号 / 句号当小数点，全角数字与符号转成半角，空格忽略。
    /// 半角逗号只在两种写法下接受：标准千分位（1,234 / 12,345.60），或唯一一个逗号后跟 1–2 位数字且没有小数点（当小数点）；
    /// 其余一律报错——不能像 cents() 那样把逗号全删掉，否则 "18,5" 会变成 $185。
    /// 出错时说明原因：看不懂、超过两位小数、不大于 0、太大。
    static func manualCents(_ text: String) throws -> Int {
        let unreadable = FinanceError.invalid("看不懂这个金额，请写成 18.50 这样")
        let tooLarge = FinanceError.invalid("金额太大了，单笔上限 100 万")
        // 全角逗号、句号都当小数点（输入法里常打出来），再把全角数字和符号转成半角
        var s = text.replacingOccurrences(of: "，", with: ".").replacingOccurrences(of: "。", with: ".")
        s = (s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s).filter { !$0.isWhitespace }
        if s.hasPrefix("+") { s.removeFirst() }
        if s.hasPrefix("A$") { s.removeFirst(2) } else if s.hasPrefix("$") { s.removeFirst() }
        if s.contains(",") {
            if matches(#"^[0-9]{1,3}(,[0-9]{3})+(\.[0-9]{0,2})?$"#, s) {
                s = s.replacingOccurrences(of: ",", with: "")
            } else if matches(#"^[0-9]+,[0-9]{1,2}$"#, s) {
                s = s.replacingOccurrences(of: ",", with: ".")
            } else {
                throw unreadable
            }
        }
        if matches(#"^[0-9]*\.[0-9]{3,}$"#, s) { throw FinanceError.invalid("金额最多两位小数，例如 18.50") }
        guard matches(#"^[0-9]*(\.[0-9]{0,2})?$"#, s), s.contains(where: \.isNumber) else { throw unreadable }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let whole = parts[0].isEmpty ? "0" : String(parts[0])
        let fraction = parts.count > 1 ? String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0) : "00"
        // 整数部分超过 7 位（不算开头的 0）必然超出上限；先拦下，免得乘 100 时溢出
        guard whole.drop(while: { $0 == "0" }).count <= 7, let w = Int(whole), let f = Int(fraction) else { throw tooLarge }
        let value = w * 100 + f
        guard value > 0 else { throw FinanceError.invalid("金额要大于 0") }
        guard value < 100_000_000 else { throw tooLarge }
        return value
    }

    private static let moneyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    static func money(_ cents: Int, sign: Bool = false) -> String {
        let text = moneyFormatter.string(from: NSNumber(value: Double(abs(cents)) / 100)) ?? "0.00"
        if cents < 0 { return "-$" + text }
        return (sign && cents > 0 ? "+$" : "$") + text
    }

    // MARK: 分类

    static func classify(_ description: String, amount: Int) -> (category: String, kind: String, review: Bool, reason: String) {
        let text = description.uppercased()
        if text.contains("INTEREST") && amount > 0 { return ("利息收入", "利息", false, "银行描述包含利息") }
        if amount < 0 && matches(#"TRANSFER TO.*(COMMSEC|SELFWEALTH|STAKE|MOOMOO|SHARESIES|RAIZ|SPACESHIP)"#, text) {
            return ("投资转账", "投资转账", false, "描述中的收款方为券商或投资账户")
        }
        if matches(#"TRANSFER (TO|FROM)|CREDIT TO ACCOUNT"#, text) {
            return amount < 0 ? ("转账待确认", "转出", true, "个人转账的用途需要确认") : ("转入款待确认", "转入", true, "转入款不自动视为工资或收入")
        }
        if amount < 0 && matches(#"WITHDRAWAL|CASH WITHDRAW|ATM "#, text) { return ("现金取款", "现金取款", true, "现金的实际用途尚未记录") }
        for rule in rules where matches(rule.pattern, text) {
            if amount > 0 {
                if matches(#"RETURN|REFUND|REVERSAL"#, text) { return (rule.category, "退款", false, "退款描述与商户类别匹配；未假定原消费在本期") }
                return ("转入款待确认", "转入", true, "正数入账未明确标为退款")
            }
            return (rule.category, "消费", false, "按商户描述分类；银行未提供购买明细")
        }
        if amount > 0 && matches(#"RETURN|REFUND|REVERSAL"#, text) { return ("待分类消费", "退款", true, "退款商户类别需要确认") }
        return amount < 0 ? ("待分类消费", "消费", true, "商户名称不足以确定用途") : ("转入款待确认", "转入", true, "入账用途需要确认")
    }

    // 商户名用到的正则只编译一次（交易明细、批量归类、固定账单检查都会对每笔调用 merchantKey）
    private static let merchantTail = try! NSRegularExpression(pattern: #"\s+(?:CARD\s+XX\d+|VALUE DATE\s*:)"#)
    private static let merchantRefundPrefix = try! NSRegularExpression(pattern: #"^(?:RETURN|REFUND|REVERSAL)\s+"#)
    private static let whitespaceRun = try! NSRegularExpression(pattern: #"\s+"#)

    /// 商户名：去掉卡号、Value Date 等尾巴和开头的 RETURN / REFUND。
    static func merchantKey(_ row: FinanceTransaction) -> String {
        var text = row.description.uppercased()
        if let match = merchantTail.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            text = String(text[..<range.lowerBound])
        }
        text = merchantRefundPrefix.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        text = whitespaceRun.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: 商户名的好读写法（只用于界面显示：分类、分类记忆、批量归类、月报仍用 merchantKey）

    /// 常见商户的固定写法，先于 merchantGroups 的标签（那几个标签是预算 / 账单分组用的，如“DiDi / Uber 打车”）
    static let displayNames: [(pattern: String, label: String)] = [
        (#"OPENAI.*CHATGPT"#, "ChatGPT"),
        (#"DIDIMOBILITY"#, "DiDi 打车"),
        (#"UBER\s?\*\s?TRIP"#, "Uber 打车"),
        (#"UBER\s?\*\s?EATS"#, "Uber Eats"),
        (#"HUNGRYPANDA"#, "HungryPanda"),
        (#"TRANSPORTFORNSW|TRANSPORT FOR NSW|TFNSW"#, "Opal 公交"),
        (#"TATTS ONLINE"#, "Tatts 彩票"),
        (#"INTERNATIONAL TRANSACTION FEE"#, "境外交易手续费"),
    ]
    /// 卡消费描述末尾的州 / 国家代码
    private static let regionTokens: Set<String> = ["AU", "AUS", "NS", "NSW", "NSWAU", "VIC", "QLD", "ACT", "WA", "SA", "TAS", "NT",
                                                    "USA", "US", "CA", "TX", "HK", "HKG", "NZ", "NZL", "GB", "GBR", "SG", "SGP", "CN", "CHN"]
    /// 公司后缀等噪音（门店编号另按“含数字”去掉）
    private static let noiseTokens: Set<String> = ["PTY", "LTD", "LT", "PT", "P/L", "LIMITED", "INC", "AUSTRALIA", "AUST", "INT"]
    /// 保持大写的缩写
    private static let acronyms: Set<String> = ["WW", "KFC", "AU", "CBD", "CT", "AO", "IGA", "BP", "NSW", "USA", "UK", "ATM", "JB", "HK"]
    private static let wordFixes: [String: String] = ["MCDONALDS": "McDonald's"]
    /// 方位词：“HAWTHORN EAST”这类两个词的地名
    private static let compassTokens: Set<String> = ["EAST", "WEST", "NORTH", "SOUTH"]

    /// 交易明细、编辑弹窗里显示的商户名：手记直接用你写的说明；银行流水先认常见商户（ChatGPT、Uber Eats……），
    /// 再认转账（“转给 X”“来自 X”），其余把全大写的银行原文写成“Tong Lin Li · Chatswood”（去掉州 / 国家代码、门店编号、PTY LTD）。
    /// 银行原文仍保存在交易里，编辑弹窗照原样显示。
    static func merchantDisplay(_ row: FinanceTransaction) -> String {
        if row.isManual {
            let text = row.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "（未写说明）" : text
        }
        return merchantDisplay(key: merchantKey(row))
    }

    /// 同上，输入是 merchantKey 的结果（例如月报里存的大额支出商户）
    static func merchantDisplay(key: String) -> String {
        let text = key.uppercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return key }
        for item in displayNames where matches(item.pattern, text) { return item.label }
        for group in merchantGroups where matches(group.pattern, text) { return group.label }
        if let transfer = transferDisplay(text) { return transfer }
        // 网银附加的“COMMBANK APP BPAY 252957 …”之后都是编号
        let core = text.range(of: " COMMBANK APP").map { String(text[..<$0.lowerBound]) } ?? text
        var tokens = core.split(separator: " ").map(String.init)
        // 收单机构前缀：“SQ *YUNNN” → “YUNNN”
        if let first = tokens.first, ["SQ", "SP", "SMP", "LS", "ZLR"].contains(first), tokens.count > 1, tokens[1].hasPrefix("*") {
            tokens.removeFirst()
        }
        tokens = tokens.map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }.filter { !$0.isEmpty }
        var hadRegion = false
        while let last = tokens.last, regionTokens.contains(last), tokens.count > 1 {
            tokens.removeLast()
            hadRegion = true
        }
        var kept = tokens.filter { token in !noiseTokens.contains(token) && !token.contains(where: \.isNumber) }
        while let last = kept.last, kept.count > 1, ["OF", "THE", "AND", "&"].contains(last) { kept.removeLast() }
        guard !kept.isEmpty else { return titled(tokens.isEmpty ? [text] : tokens) }
        // 有州 / 国家代码时，最后一个词多半是地名（“HAWTHORN EAST”取两个词）
        if hadRegion, kept.count >= 2, let last = kept.last {
            let suburbCount = compassTokens.contains(last) && kept.count >= 3 ? 2 : 1
            let suburb = Array(kept.suffix(suburbCount))
            let name = Array(kept.dropLast(suburbCount))
            let suburbText = suburb.joined(separator: " ")
            if suburbText.count >= 4, !["OF", "THE", "AND"].contains(suburb[0]) {
                // 店名里已经带着地名（“AMPOL CHATSWOOD”）就不再重复
                if name.joined(separator: " ").contains(suburbText) { return titled(name) }
                return titled(name) + " · " + titled(suburb)
            }
        }
        return titled(kept)
    }

    /// 转账：“TRANSFER TO X COMMBANK APP …” → “转给 X”；“FAST TRANSFER FROM X …” → “来自 X”；
    /// “DIRECT CREDIT 000415 X” → “X”。认不出时为 nil。
    private static func transferDisplay(_ text: String) -> String? {
        func payee(_ rest: Substring) -> String {
            var s = String(rest)
            // 银行附加的固定字样之后是备注，只留对方名字
            for marker in [" COMMBANK", " PAYID", " CREDIT TO ACCOUNT"] {
                if let range = s.range(of: marker) { s = String(s[..<range.lowerBound]) }
            }
            s = s.replacingOccurrences(of: "_", with: " ")
            let words = s.split(separator: " ").map(String.init)
            return words.isEmpty ? "" : titled(words)
        }
        for (prefix, verb) in [("FAST TRANSFER TO ", "转给"), ("TRANSFER TO ", "转给"), ("FAST TRANSFER FROM ", "来自"), ("TRANSFER FROM ", "来自")]
            where text.hasPrefix(prefix) {
            let name = payee(text.dropFirst(prefix.count))
            return name.isEmpty ? nil : "\(verb) \(name)"
        }
        for prefix in ["DIRECT CREDIT ", "DIRECT DEBIT "] where text.hasPrefix(prefix) {
            let words = text.dropFirst(prefix.count).split(separator: " ").map(String.init).filter { !$0.contains(where: \.isNumber) }
            return words.isEmpty ? nil : titled(words)
        }
        return nil
    }

    /// 全大写的词写成首字母大写（缩写、带数字的编号保持原样）
    private static func titled(_ words: [String]) -> String {
        words.enumerated().map { index, word in
            if let fixed = wordFixes[word] { return fixed }
            if acronyms.contains(word) || word.contains(where: \.isNumber) || !word.contains(where: \.isLetter) { return word }
            if index > 0, ["OF", "AND"].contains(word) { return word.lowercased() }
            return word.capitalized
        }.joined(separator: " ")
    }

    static func ruleEligible(_ row: FinanceTransaction) -> Bool {
        (row.kind == "消费" || row.kind == "退款") && !nonSpend.contains(row.category) && row.amountCents != 0
            && !matches(#"TRANSFER|CREDIT TO ACCOUNT|WITHDRAW|\bATM\b"#, row.description)
    }

    // MARK: CSV 导入

    /// 解析 CommBank CSV：日期 DD/MM/YYYY、金额、描述、余额四列。交易 ID 与旧版算法一致。
    static func parseCSV(_ raw: String, account rawAccount: String) throws -> [FinanceTransaction] {
        guard raw.utf8.count <= 750 * 1024 else { throw FinanceError.invalid("请选择不超过 750 KiB 的 CommBank CSV 文件") }
        let account = rawAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(account.count) else { throw FinanceError.invalid("请填写不超过 80 字的账户名称，可只保留末四位") }
        // “手记”账户的交易可单删、可改金额；银行流水记在这个名下会被当成手记（正数退款改一次就变成扣款）
        guard account != ManualExpense.account else {
            throw FinanceError.invalid("「\(ManualExpense.account)」是手动记账专用的账户名，请换一个名称（例如 CommBank 0123）")
        }
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var rows: [FinanceTransaction] = []
        var occurrences: [String: Int] = [:]
        for (index, values) in try csvRecords(text).enumerated() {
            let line = index + 1
            if values.isEmpty || values.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            if line == 1 && values[0].lowercased().trimmingCharacters(in: .whitespaces) == "date" { continue }
            guard values.count == 4 else { throw FinanceError.invalid("第 \(line) 行应包含日期、金额、描述、余额四列") }
            // 与旧版 strptime('%d/%m/%Y') 一致：年份必须是 4 位（另存后变成 1/10/26 的不能当成公元 26 年）
            let dateParts = values[0].trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
            func number(_ part: Substring, digits: ClosedRange<Int>) -> Int? {
                digits.contains(part.count) && part.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(part) : nil
            }
            guard dateParts.count == 3, let d = number(dateParts[0], digits: 1...2), let m = number(dateParts[1], digits: 1...2),
                  let y = number(dateParts[2], digits: 4...4), (2000...2100).contains(y),
                  let day = LocalDay(key: String(format: "%04d-%02d-%02d", y, m, d)) else {
                throw FinanceError.invalid("第 \(line) 行日期应为 DD/MM/YYYY（例如 01/10/2026），实际为「\(values[0].prefix(30))」")
            }
            let description = values[2]
            guard !description.trimmingCharacters(in: .whitespaces).isEmpty, description.count <= 2000 else {
                throw FinanceError.invalid("第 \(line) 行交易描述无效")
            }
            let amount: Int, balance: Int
            do { amount = try cents(values[1]) } catch {
                throw FinanceError.invalid("第 \(line) 行金额列「\(values[1].prefix(30))」无效：\(error.localizedDescription)")
            }
            do { balance = try cents(values[3]) } catch {
                throw FinanceError.invalid("第 \(line) 行余额列「\(values[3].prefix(30))」无效：\(error.localizedDescription)")
            }
            let c = classify(description, amount: amount)
            let identity = digest([account, day.key, amount, description, balance])
            occurrences[identity, default: 0] += 1
            rows.append(FinanceTransaction(
                id: digest([identity, occurrences[identity]!]), date: day.key, amountCents: amount, balanceCents: balance,
                description: description, account: account, category: c.category, kind: c.kind, needsReview: c.review,
                reason: c.reason, sourceLine: line))
            if rows.count > 5000 { throw FinanceError.invalid("一次最多导入 5,000 笔，请按日期分批导出") }
        }
        return rows
    }

    private enum CSVState { case fieldStart, unquoted, quoted, quoteInQuoted }

    /// 最小 CSV 解析，行为与 Python csv.reader（默认 excel 方言）一致：只有字段开头的引号才开启引号模式，
    /// 字段中间的引号按普通字符保留；支持引号内逗号与换行、"" 转义。文件结束时引号仍未闭合则报错（不再静默吞掉后面所有行）。
    static func csvRecords(_ text: String) throws -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var state = CSVState.fieldStart
        func endField() {
            record.append(field)
            field = ""
            state = .fieldStart
        }
        func endRecord() {
            endField()
            records.append(record)
            record = []
        }
        for ch in text {
            let newline = ch == "\n" || ch == "\r\n" || ch == "\r"
            switch state {
            case .quoted:
                if ch == "\"" { state = .quoteInQuoted } else { field.append(ch) }
            case .quoteInQuoted:
                if ch == "\"" { field.append("\""); state = .quoted }
                else if ch == "," { endField() }
                else if newline { endRecord() }
                else { field.append(ch); state = .unquoted }
            case .fieldStart, .unquoted:
                if ch == "\"" && state == .fieldStart { state = .quoted }
                else if ch == "," { endField() }
                else if newline { endRecord() }
                else { field.append(ch); state = .unquoted }
            }
        }
        if state == .quoted {
            throw FinanceError.invalid("第 \(records.count + 1) 条记录的引号没有闭合，请检查文件")
        }
        // 文件末尾没有换行时，补上最后一条记录
        if state != .fieldStart || !field.isEmpty || !record.isEmpty { endRecord() }
        return records
    }

    /// CSV 新交易与已有“手记”交易可能是同一笔：金额相同（同为扣款）、日期相差不超过 3 天。只做提示，由用户决定删不删手记那笔。
    struct ManualMatch: Identifiable, Hashable {
        var bank: FinanceTransaction
        var manual: FinanceTransaction
        var id: String { bank.id + "|" + manual.id }
    }

    struct ImportPreview {
        var rows: [FinanceTransaction]
        var newCount: Int
        var duplicateCount: Int
        var start: String?
        var end: String?
        var sha256: String
        var account: String
        /// 新交易里疑似与手记重复的（每笔手记最多配一笔）
        var manualMatches: [ManualMatch] = []
        /// 新交易里与“别的账户名”下已有交易完全相同（日期、金额、描述、余额都一致）的笔数：多半是同一份文件填了不同的账户名
        var crossAccountCount = 0
        var crossAccounts: [String] = []
    }

    /// 与账户名无关的交易指纹（不进交易 ID，只用于识别“同一份文件换了账户名再导入”）
    static func contentFingerprint(_ row: FinanceTransaction) -> String {
        pythonJSON([row.date, row.amountCents, row.description, row.balanceCents])
    }

    /// 校验用户确认的银行导出范围（对应旧版 confirmed_period）：结束日期不能晚于今天，否则当月会被误标成“已确认覆盖整月”。
    static func validatePeriod(_ period: StatementPeriod, today: LocalDay = .today()) throws {
        guard let start = LocalDay(key: period.start), let end = LocalDay(key: period.end) else {
            throw FinanceError.invalid("银行导出的起止日期无效")
        }
        guard start <= end else { throw FinanceError.invalid("开始日期不能晚于结束日期") }
        guard end <= today else { throw FinanceError.invalid("银行导出结束日期不能晚于今天；当前月份请只确认已到来的日期") }
        guard start.days(to: end) <= 3660 else { throw FinanceError.invalid("一次确认的导出范围不能超过 3,660 天，请分批导出") }
    }

    /// 全局按日期差配对：先列出所有“金额相同、相差不超过 maxDays 天”的（银行行, 手记）组合，按天数差从小到大取两边都还没用过的。
    /// 不能按银行行日期顺序贪心——较早的另一笔同价消费会先把手记抢走，真正同日的那笔反而漏标。
    static func manualMatches(for rows: [FinanceTransaction], in ledger: FinanceLedger, maxDays: Int = 3) -> [ManualMatch] {
        var pool: [Int: [(row: FinanceTransaction, day: LocalDay)]] = [:]   // 金额 → 手记
        for row in ledger.transactions where row.isManual && !row.isIgnored && row.amountCents != 0 {
            guard let day = LocalDay(key: row.date) else { continue }
            pool[row.amountCents, default: []].append((row, day))
        }
        guard !pool.isEmpty else { return [] }
        var candidates: [(bank: FinanceTransaction, manual: FinanceTransaction, distance: Int)] = []
        for bank in rows where !bank.isManual && bank.amountCents != 0 {
            guard let bankDay = LocalDay(key: bank.date), let manuals = pool[bank.amountCents] else { continue }
            for manual in manuals {
                let distance = abs(bankDay.days(to: manual.day))
                if distance <= maxDays { candidates.append((bank, manual.row, distance)) }
            }
        }
        candidates.sort {
            ($0.distance, $0.bank.date, $0.bank.sourceLine, $0.manual.date, $0.manual.id)
                < ($1.distance, $1.bank.date, $1.bank.sourceLine, $1.manual.date, $1.manual.id)
        }
        var usedBanks = Set<String>(), usedManuals = Set<String>()
        var result: [ManualMatch] = []
        for c in candidates where !usedBanks.contains(c.bank.id) && !usedManuals.contains(c.manual.id) {
            usedBanks.insert(c.bank.id)
            usedManuals.insert(c.manual.id)
            result.append(ManualMatch(bank: c.bank, manual: c.manual))
        }
        // 列表按银行流水的日期排，方便逐对核对
        return result.sorted { ($0.bank.date, $0.bank.sourceLine) < ($1.bank.date, $1.bank.sourceLine) }
    }

    /// 反向检查：一笔手记（还没入账或刚改过）在账上已有的银行扣款里，可能是同一笔的那些——金额相同、相差不超过 maxDays 天、
    /// 没设为不计入。按日期差从近到远排。用于“先导入了银行流水、后补记手记”的情况（之后的导入不会再拿旧流水来配对）。
    static func existingBankMatches(for manual: FinanceTransaction, in ledger: FinanceLedger, maxDays: Int = 3) -> [FinanceTransaction] {
        guard manual.amountCents != 0, let day = LocalDay(key: manual.date) else { return [] }
        let found: [(row: FinanceTransaction, distance: Int)] = ledger.transactions.compactMap { row in
            guard !row.isManual, !row.isIgnored, row.id != manual.id, row.amountCents == manual.amountCents,
                  let other = LocalDay(key: row.date) else { return nil }
            let distance = abs(day.days(to: other))
            return distance <= maxDays ? (row, distance) : nil
        }
        return found.sorted { ($0.distance, $0.row.date, $0.row.sourceLine) < ($1.distance, $1.row.date, $1.row.sourceLine) }.map(\.row)
    }

    static func previewImport(raw: String, account: String, ledger: FinanceLedger, period: StatementPeriod?,
                              today: LocalDay = .today()) throws -> ImportPreview {
        if let period { try validatePeriod(period, today: today) }
        let rows = try parseCSV(raw, account: account)
        if rows.isEmpty && period == nil { throw FinanceError.invalid("CSV 中没有交易记录") }
        if let period, rows.contains(where: { $0.date < period.start || $0.date > period.end }) {
            throw FinanceError.invalid("CSV 的交易日期超出你确认的银行导出范围，请核对文件或日期")
        }
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = Set(ledger.transactions.map(\.id))
        let fresh = rows.filter { !ids.contains($0.id) }
        // 同一笔银行流水出现在别的账户名下：按指纹逐笔配对计数
        var others: [String: [String]] = [:]
        for row in ledger.transactions where !row.isManual && row.account != trimmed {
            others[contentFingerprint(row), default: []].append(row.account)
        }
        var crossCount = 0
        var crossAccounts = Set<String>()
        if !others.isEmpty {
            for row in fresh {
                let key = contentFingerprint(row)
                guard let other = others[key]?.popLast() else { continue }
                crossCount += 1
                crossAccounts.insert(other)
            }
        }
        return ImportPreview(rows: rows, newCount: fresh.count, duplicateCount: rows.count - fresh.count,
                             start: rows.map(\.date).min(), end: rows.map(\.date).max(), sha256: sha256(raw),
                             account: trimmed, manualMatches: manualMatches(for: fresh, in: ledger),
                             crossAccountCount: crossCount, crossAccounts: crossAccounts.sorted())
    }

    @discardableResult
    static func applyImport(raw: String, preview: ImportPreview, period: StatementPeriod?, to ledger: inout FinanceLedger) -> Int {
        let ids = Set(ledger.transactions.map(\.id))
        let added = preview.rows.filter { !ids.contains($0.id) }
        let stamp = now()
        // 与旧版一致：同一文件 + 同一账户才视为同一来源；空文件（只用来确认范围）只有在确认范围也相同时才合并，
        // 否则另起一条，免得 10 月的确认把 9 月的确认覆盖掉
        if let index = ledger.sources.firstIndex(where: { $0.sha256 == preview.sha256 && $0.account == preview.account
                                                          && (!preview.rows.isEmpty || $0.statementPeriod == period) }) {
            if let period { ledger.sources[index].statementPeriod = period }
        } else {
            ledger.sources.append(FinanceSource(sha256: preview.sha256, account: preview.account, rawCsv: raw, importedAt: stamp,
                                                rows: preview.rows.count, start: preview.start ?? period?.start,
                                                end: preview.end ?? period?.end, pendingIncluded: false, statementPeriod: period))
        }
        for var row in added {
            row.importedAt = stamp
            row.sourceSha256 = preview.sha256
            applyRule(ledger, to: &row)
            ledger.transactions.append(row)
        }
        return added.count
    }

    // MARK: 修改分类与分类记忆

    static func applyRule(_ ledger: FinanceLedger, to row: inout FinanceTransaction) {
        guard ruleEligible(row) else { return }
        let key = merchantKey(row)
        if let rule = ledger.merchantRules.first(where: { $0.enabled && $0.account == row.account && $0.merchant == key }) {
            row.category = rule.category
            row.classification = "rule"
            row.needsReview = false
            row.reason = "按你保存的同账户商户分类记忆归类"
        }
    }

    static func canRemember(_ row: FinanceTransaction, category: String) -> Bool {
        ruleEligible(row) && !nonSpend.contains(category) && category != "待分类消费"
    }

    static func rememberRule(in ledger: inout FinanceLedger, row: FinanceTransaction, category: String) throws {
        guard canRemember(row, category: category) else {
            throw FinanceError.invalid("仅可记住已确认的商户消费类别；个人转账请逐笔确认")
        }
        let key = merchantKey(row)
        let identity = digest([row.account, key])
        if let index = ledger.merchantRules.firstIndex(where: { $0.id == identity }) {
            ledger.merchantRules[index].category = category
            ledger.merchantRules[index].enabled = true
            ledger.merchantRules[index].revision += 1
        } else {
            ledger.merchantRules.append(MerchantRule(id: identity, account: row.account, merchant: key, category: category,
                                                     enabled: true, revision: 0, createdAt: now()))
        }
    }

    /// 逐笔确认类别与备注（对应旧版 FinanceService.update）。
    static func updateTransaction(in ledger: inout FinanceLedger, id: String, category: String, note: String, remember: Bool) throws {
        guard categories.contains(category) else { throw FinanceError.invalid("请选择有效类别") }
        guard note.count <= 2000 else { throw FinanceError.invalid("备注最多 2,000 字") }
        guard let index = ledger.transactions.firstIndex(where: { $0.id == id }) else { throw FinanceError.invalid("交易不存在") }
        if remember { try rememberRule(in: &ledger, row: ledger.transactions[index], category: category) }
        var row = ledger.transactions[index]
        row.category = category
        row.note = note
        row.classification = "user"
        row.revision += 1
        row.needsReview = reviewCategories.contains(category)
        // 手记的 reason 记着来源（手动记账 / 随手记 / 飞剑传书 · 谁），保留下来
        if !row.isManual { row.reason = "用户确认的分类" }
        if row.amountCents < 0 {
            row.kind = ["投资转账", "借出款", "现金取款"].contains(category) ? category : category == "转账待确认" ? "转出" : "消费"
        } else if row.amountCents > 0 {
            // 正数入账：确认成消费类别即为退款（抵扣净消费）；改回不计入消费的类别则不再算退款
            row.kind = category == "利息收入" ? "利息" : nonSpend.contains(category) ? "转入" : "退款"
        }
        ledger.transactions[index] = row
    }

    // MARK: 手记的修改与删除、不计入统计

    /// 删除一笔手记（手动记账、随手记、飞剑传书）。银行导入的交易与网银流水一一对应，不提供单删：
    /// 重复导入时会按 ID 自动回来；重复或无关的流水请设为“不计入统计”，整份导错请撤销最近一次导入。
    static func deleteTransaction(in ledger: inout FinanceLedger, id: String) throws {
        guard let index = ledger.transactions.firstIndex(where: { $0.id == id }) else { throw FinanceError.invalid("这笔交易已不存在") }
        guard ledger.transactions[index].isManual else {
            throw FinanceError.invalid("银行导入的交易不能单独删除；可设为“不计入统计”，整份导错可撤销最近一次导入")
        }
        ledger.transactions.remove(at: index)
    }

    /// 修改手记的日期、金额（正数，存为扣款）与说明。银行导入的交易不能改，免得与网银对不上。
    static func editManual(in ledger: inout FinanceLedger, id: String, date: String, cents: Int, description: String) throws {
        guard let index = ledger.transactions.firstIndex(where: { $0.id == id }) else { throw FinanceError.invalid("这笔交易已不存在") }
        guard ledger.transactions[index].isManual else { throw FinanceError.invalid("银行导入的交易不能修改金额、日期与说明") }
        // 手记一定是扣款；正数（退款、入账）多半是误记在“手记”名下的银行流水，按扣款改写会把退款变成消费
        guard ledger.transactions[index].amountCents < 0 else {
            throw FinanceError.invalid("这笔是入账或退款，不是手记的扣款，不能在这里修改金额、日期与说明")
        }
        guard let day = LocalDay(key: date) else { throw FinanceError.invalid("日期无效") }
        guard cents > 0, cents < 100_000_000 else { throw FinanceError.invalid("金额需大于 0 且小于 $1,000,000") }
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2000 else { throw FinanceError.invalid("说明不能为空，最多 2,000 字") }
        var row = ledger.transactions[index]
        let amount = -abs(cents)
        guard row.date != day.key || row.amountCents != amount || row.description != text else { return }
        row.date = day.key
        row.amountCents = amount
        row.description = text
        row.revision += 1
        ledger.transactions[index] = row
    }

    /// 设为“不计入统计”或改回：交易本身保留，只是不再算进消费、退款、预算、固定账单与月报。
    static func setIgnored(in ledger: inout FinanceLedger, id: String, ignored: Bool) throws {
        guard let index = ledger.transactions.firstIndex(where: { $0.id == id }) else { throw FinanceError.invalid("这笔交易已不存在") }
        guard ledger.transactions[index].isIgnored != ignored else { return }
        ledger.transactions[index].ignored = ignored ? true : nil
        ledger.transactions[index].revision += 1
    }

    // MARK: 撤销导入

    /// 最近一次银行导入（按导入时间）在 sources 里的位置。只允许撤销这一次：更早的导入若与之后的文件重叠，
    /// 后来文件里重叠的交易被当作“已存在”跳过、仍记在更早那次名下，撤销更早的会把它们一起删掉。
    static func latestImportIndex(_ ledger: FinanceLedger) -> Int? {
        let times = ledger.sources.map { LegacyMapper.timestamp($0.importedAt) ?? .distantPast }
        return ledger.sources.indices.max { (times[$0], $0) < (times[$1], $1) }
    }

    /// 某次导入新增的交易（同账户、同文件指纹）。若另有导入记录共用同一文件与账户，这些交易不归它独有，返回空。
    static func rowsAdded(bySource index: Int, in ledger: FinanceLedger) -> [FinanceTransaction] {
        guard ledger.sources.indices.contains(index) else { return [] }
        let source = ledger.sources[index]
        let shared = ledger.sources.indices.contains {
            $0 != index && ledger.sources[$0].sha256 == source.sha256 && ledger.sources[$0].account == source.account
        }
        if shared { return [] }
        return ledger.transactions.filter { $0.sourceSha256 == source.sha256 && $0.account == source.account }
    }

    /// 撤销最近一次导入：删掉这条导入记录与它新增的交易。`expected` 是用户确认时看到的那条记录；账本已变化就拒绝，什么都不动。
    /// 返回删掉的交易笔数；导入后按疑似重复删掉的手记会一并放回（笔数见 undoLatestImportDetailed）。
    @discardableResult
    static func undoLatestImport(in ledger: inout FinanceLedger, expected: FinanceSource) throws -> Int {
        try undoLatestImportDetailed(in: &ledger, expected: expected).removed
    }

    struct UndoImportResult { var removed: Int; var restoredManual: Int }

    @discardableResult
    static func undoLatestImportDetailed(in ledger: inout FinanceLedger, expected: FinanceSource) throws -> UndoImportResult {
        guard let index = latestImportIndex(ledger), ledger.sources[index] == expected else {
            throw FinanceError.invalid("只能撤销最近一次导入；账本刚有变化，请重新查看后再试")
        }
        let ids = Set(rowsAdded(bySource: index, in: ledger).map(\.id))
        let restore = ledger.sources[index].removedManual ?? []
        ledger.sources.remove(at: index)
        ledger.transactions.removeAll { ids.contains($0.id) }
        // 放回这次导入后按疑似重复删掉的手记（同 ID 已在账上的跳过，不重复添加）
        var existing = Set(ledger.transactions.map(\.id))
        var restored = 0
        for row in restore {
            guard existing.insert(row.id).inserted else { continue }
            ledger.transactions.append(row)
            restored += 1
        }
        return UndoImportResult(removed: ids.count, restoredManual: restored)
    }

    /// 导入后确认“银行流水与手记是同一笔”时删掉手记那笔，并把它原样记在这次导入记录下（撤销这次导入时放回）。
    /// `source` 是这次导入新建的导入记录；找不到它（或为 nil）时照样删除，只是不记。
    /// 返回删掉的那笔（原样）与更新后的导入记录；调用方要用新的导入记录替换手上的旧值，否则之后撤销导入会因“账本已变化”被拒。
    @discardableResult
    static func deleteDuplicateManual(in ledger: inout FinanceLedger, id: String,
                                      source: FinanceSource?) throws -> (row: FinanceTransaction, source: FinanceSource?) {
        guard let row = ledger.transactions.first(where: { $0.id == id }) else { throw FinanceError.invalid("这笔手记已不存在") }
        try deleteTransaction(in: &ledger, id: id)
        guard let source, let index = ledger.sources.firstIndex(of: source) else { return (row, nil) }
        ledger.sources[index].removedManual = (ledger.sources[index].removedManual ?? []) + [row]
        return (row, ledger.sources[index])
    }

    /// 撤回上面的删除：手记放回账本（同 ID 已在账上则不重复添加），并从导入记录的待恢复清单里去掉。返回更新后的导入记录。
    @discardableResult
    static func restoreDuplicateManual(in ledger: inout FinanceLedger, row: FinanceTransaction, source: FinanceSource?) -> FinanceSource? {
        if !ledger.transactions.contains(where: { $0.id == row.id }) { ledger.transactions.append(row) }
        guard let source, let index = ledger.sources.firstIndex(of: source) else { return nil }
        let left = (ledger.sources[index].removedManual ?? []).filter { $0.id != row.id }
        ledger.sources[index].removedManual = left.isEmpty ? nil : left
        return ledger.sources[index]
    }

    /// 同账户同商户的其他记录（批量归类候选；默认不改动你已逐笔确认过的记录）。
    static func sameMerchant(in ledger: FinanceLedger, as row: FinanceTransaction, category: String, includeConfirmed: Bool = false) -> [FinanceTransaction] {
        guard canRemember(row, category: category) else { return [] }
        let key = merchantKey(row)
        return ledger.transactions.filter {
            $0.id != row.id && ruleEligible($0) && $0.account == row.account && merchantKey($0) == key
                && (includeConfirmed || $0.classification != "user")
                && ($0.category != category || $0.classification != "user" || $0.needsReview)
        }
    }

    static func batchClassify(in ledger: inout FinanceLedger, ids: Set<String>, category: String) {
        for index in ledger.transactions.indices where ids.contains(ledger.transactions[index].id) {
            ledger.transactions[index].category = category
            ledger.transactions[index].classification = "user"
            ledger.transactions[index].needsReview = false
            ledger.transactions[index].revision += 1
            // 与 updateTransaction 一致：手记的 reason 记着来源（手动记账 / 随手记 / 飞剑传书 · 谁），不覆盖
            if !ledger.transactions[index].isManual { ledger.transactions[index].reason = "用户批量确认的商户分类" }
        }
    }

    // MARK: 月份与覆盖范围

    static func monthRange(_ month: String) -> (String, String)? {
        guard let first = LocalDay(key: month + "-01") else { return nil }
        let nextMonth = first.adding(days: 32).firstOfMonth
        return (first.key, nextMonth.adding(days: -1).key)
    }

    static func previousMonth(_ month: String) -> String? {
        guard let first = LocalDay(key: month + "-01") else { return nil }
        let prev = first.adding(days: -1)
        return String(format: "%04d-%02d", prev.year, prev.month)
    }

    static func ledgerMonths(_ ledger: FinanceLedger) -> [String] {
        ledgerMonths(Set(ledger.transactions.map(\.month)), sources: ledger.sources)
    }

    /// 同上，交易所在的月份已经取好（FinanceLedgerIndex 分组时顺便取得）
    static func ledgerMonths(_ transactionMonths: Set<String>, sources: [FinanceSource]) -> [String] {
        var months = transactionMonths
        for source in sources {
            guard source.statementPeriod != nil, let (first, last) = source.range, var day = LocalDay(key: String(first.prefix(7)) + "-01") else { continue }
            while day.key.prefix(7) <= last.prefix(7) {
                months.insert(String(day.key.prefix(7)))
                day = day.adding(days: 32).firstOfMonth
            }
        }
        return months.sorted(by: >)
    }

    static func covers(_ intervals: [(String, String)], _ first: String, _ last: String) -> Bool {
        covers(parsed: coverageIntervals(intervals), first, last)
    }

    /// 覆盖范围按开始日期（字符串）排好、解析成日期；解析不了的那段跳过（与原来在循环里跳过相同）。
    /// FinanceLedgerIndex 每个账户只排一次、解析一次，不必每个月都重来。
    static func coverageIntervals(_ intervals: [(String, String)]) -> [(LocalDay, LocalDay)] {
        intervals.sorted(by: { $0.0 < $1.0 }).compactMap { left, right in
            guard let a = LocalDay(key: left), let b = LocalDay(key: right) else { return nil }
            return (a, b)
        }
    }

    static func covers(parsed intervals: [(LocalDay, LocalDay)], _ first: String, _ last: String) -> Bool {
        guard var cursor = LocalDay(key: first), let target = LocalDay(key: last) else { return false }
        for (a, b) in intervals {
            if b < cursor { continue }
            if a > cursor { return false }
            cursor = max(cursor, b.adding(days: 1))
            if cursor > target { return true }
        }
        return false
    }

    /// 月份的首末日期键；认不出的月份键按“-01 到 -28”
    static func monthBounds(_ month: String) -> (String, String) { monthRange(month) ?? (month + "-01", month + "-28") }

    /// 到 last 为止已有导入记录的账户（判断整月是否导全时，这些账户都要覆盖到）
    static func coveredAccounts(_ sources: [FinanceSource], through last: String) -> Set<String> {
        Set(sources.filter { ($0.range?.0 ?? "9999") <= last }.map(\.account))
    }

    static func monthFacts(_ ledger: FinanceLedger, month: String) -> MonthFacts {
        let (first, last) = monthBounds(month)
        let rows = ledger.transactions.filter { $0.date >= first && $0.date <= last }
        let accounts = coveredAccounts(ledger.sources, through: last)
        let complete = !accounts.isEmpty && accounts.allSatisfy { account in
            covers(ledger.sources.filter { $0.account == account }.compactMap(\.range), first, last)
        }
        let confirmed = !accounts.isEmpty && accounts.allSatisfy { account in
            covers(ledger.sources.filter { $0.account == account && $0.statementPeriod != nil }.compactMap(\.range), first, last)
        }
        return monthFacts(month: month, first: first, last: last, rows: rows, accountCount: accounts.count,
                          fullMonth: complete, coverageConfirmed: confirmed)
    }

    /// 由这个月日期范围内的交易与覆盖情况汇总（直接计算与 FinanceLedgerIndex 共用这一段）
    static func monthFacts(month: String, first: String, last: String, rows: [FinanceTransaction],
                           accountCount: Int, fullMonth complete: Bool, coverageConfirmed confirmed: Bool) -> MonthFacts {
        var categoriesTotal: [String: Int] = [:], excluded: [String: Int] = [:]
        var refunds = 0, debit = 0
        for row in rows where !row.isIgnored {
            if row.amountCents < 0 {
                debit -= row.amountCents
                if nonSpend.contains(row.category) { excluded[row.category, default: 0] -= row.amountCents }
                else { categoriesTotal[row.category, default: 0] -= row.amountCents }
            } else if row.kind == "退款" {
                refunds += row.amountCents
            }
        }
        let spend = categoriesTotal.values.reduce(0, +)
        let education = categoriesTotal["教育与学费"] ?? 0
        return MonthFacts(month: month, start: first, end: last, rowCount: rows.count, fullMonth: complete, coverageConfirmed: confirmed,
                          accountCount: accountCount, spendCents: spend, refundCents: refunds, netSpendCents: spend - refunds,
                          debitCents: debit, excludedCents: excluded.values.reduce(0, +), excludedCategories: excluded,
                          educationCents: education, nonEducationCents: spend - education, categories: categoriesTotal,
                          needsReviewCount: rows.filter(\.awaitingReview).count)
    }

    // MARK: 预算与固定账单

    /// 计入消费的扣款（不含设为不计入统计的、转账取现等消费之外的类别）：预算里的打车、固定账单都只看这些
    static func isSpending(_ row: FinanceTransaction) -> Bool {
        row.amountCents < 0 && !row.isIgnored && !nonSpend.contains(row.category)
    }

    static func budgetStatus(_ ledger: FinanceLedger, month: String) -> [BudgetStatus] {
        let ridePattern = merchantGroups.first { $0.key == "ride_hail" }!.pattern
        let ride = ledger.transactions.filter {
            $0.month == month && isSpending($0) && matches(ridePattern, $0.description)
        }.reduce(0) { $0 - $1.amountCents }
        return budgetStatus(facts: monthFacts(ledger, month: month), rideCents: ride, limits: ledger.budgets[month] ?? [:])
    }

    /// 由本月账目、打车扣款合计与预算额度组成三项预算（直接计算与 FinanceLedgerIndex 共用）
    static func budgetStatus(facts: MonthFacts, rideCents ride: Int, limits: [String: Int]) -> [BudgetStatus] {
        let actual = ["dining": facts.categories["餐饮与外卖"] ?? 0, "ride_hail": ride,
                      "entertainment": (facts.categories["娱乐"] ?? 0) + (facts.categories["彩票"] ?? 0)]
        return budgetLabels.map { item in
            let limit = limits[item.key]
            return BudgetStatus(key: item.key, label: item.label, spentCents: actual[item.key] ?? 0, limitCents: limit,
                                remainingCents: limit.map { $0 - (actual[item.key] ?? 0) })
        }
    }

    static func preferenceKey(_ key: String) -> String { key == "telstra" || key == "optus" ? "communications" : key }

    /// 一个账单分组在本月、上月的扣款（都按账本里的顺序），以及本月之前是否出现过
    struct ServiceRows {
        var current: [FinanceTransaction]
        var prior: [FinanceTransaction]
        var seenBefore: Bool
    }

    static func serviceChecks(_ ledger: FinanceLedger, month: String) -> [ServiceCheck] {
        let previous = previousMonth(month)
        let priorFull = previous.map { monthFacts(ledger, month: $0).fullMonth } ?? false
        let spending = ledger.transactions.filter(isSpending)
        return serviceChecks(month: month, previous: previous, priorFull: priorFull, preferences: ledger.reviewPreferences) { group in
            let matched = spending.filter { matches(group.pattern, $0.description) }
            return ServiceRows(current: matched.filter { $0.month == month }, prior: matched.filter { $0.month == previous },
                               seenBefore: matched.contains(where: { $0.month < month }))
        }
    }

    /// 逐个账单分组检查（直接计算与 FinanceLedgerIndex 共用）；rows 给出该分组本月、上月的扣款
    static func serviceChecks(month: String, previous: String?, priorFull: Bool, preferences: [String: String],
                              rows: (_ group: (key: String, label: String, pattern: String)) -> ServiceRows) -> [ServiceCheck] {
        var result: [ServiceCheck] = []
        for group in merchantGroups where serviceKeys.contains(group.key) {
            let found = rows(group)
            let current = found.current.sorted { ($0.date, $0.sourceLine) < ($1.date, $1.sourceLine) }
            let prior = found.prior.sorted { ($0.date, $0.sourceLine) < ($1.date, $1.sourceLine) }
            if current.isEmpty && prior.isEmpty { continue }
            var signals: [ServiceSignal] = []
            if let c = current.last, let p = prior.last, -c.amountCents > -p.amountCents {
                signals.append(ServiceSignal(kind: "increase", text: "末次单笔扣款上升，核对账单内容或汇率", changeCents: p.amountCents - c.amountCents))
            }
            if !current.isEmpty && !found.seenBefore {
                signals.append(ServiceSignal(kind: "first_seen", text: "在已导入记录中本月首次出现；不代表订阅刚开通"))
            }
            var groups: [String: Int] = [:]
            for r in current { groups["\(r.date)|\(r.amountCents)|\(merchantKey(r))|\(r.account)", default: 0] += 1 }
            if groups.values.contains(where: { $0 > 1 }) {
                signals.append(ServiceSignal(kind: "possible_duplicate", text: "同日同商户同金额多笔扣款，需核对是否重复或不同订单"))
            }
            let pref = preferenceKey(group.key)
            result.append(ServiceCheck(key: group.key, label: group.label, preferenceKey: pref,
                                       status: preferences[pref] ?? "review",
                                       debitCents: -current.reduce(0) { $0 + $1.amountCents }, count: current.count,
                                       previousCents: priorFull ? -prior.reduce(0) { $0 + $1.amountCents } : nil,
                                       previousMonth: previous, signals: signals))
        }
        return result
    }

    // MARK: 月度修习录

    static func reportBasis(_ ledger: FinanceLedger, month: String) -> String {
        let previous = previousMonth(month)
        let rows = ledger.transactions.filter { $0.month == month || $0.month == previous }
        return reportBasis(rows: rows, facts: monthFacts(ledger, month: month), prior: previous.map { monthFacts(ledger, month: $0) },
                           budgets: ledger.budgets[month] ?? [:], preferences: ledger.reviewPreferences)
    }

    /// 月卷依据的指纹：本月与上月的交易（账本里的顺序）、两个月的账目、本月预算、账单偏好（直接计算与 FinanceLedgerIndex 共用）
    static func reportBasis(rows: [FinanceTransaction], facts: MonthFacts, prior: MonthFacts?,
                            budgets: [String: Int], preferences: [String: String]) -> String {
        struct Basis: Encodable {
            var rows: [FinanceTransaction]; var facts: MonthFacts; var prior: MonthFacts?
            var budgets: [String: Int]; var preferences: [String: String]
        }
        let basis = Basis(rows: rows, facts: facts, prior: prior, budgets: budgets, preferences: preferences)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(basis)) ?? Data()
        return hex(SHA256.hash(data: data))
    }

    /// 月卷“大额支出”的候选：单笔 $300 以上、计入消费的扣款
    static func isLargePurchase(_ row: FinanceTransaction) -> Bool {
        row.amountCents <= -30000 && !row.isIgnored && !nonSpend.contains(row.category)
    }

    static func reportDraft(_ ledger: FinanceLedger, month: String) -> MonthlyReport {
        let previous = previousMonth(month)
        // 先筛出本月的大额支出再按金额排（原来把整本账排一遍才筛本月）；排序是稳定的，同额的先后与原来相同
        let large = ledger.transactions.filter { $0.month == month && isLargePurchase($0) }.sorted { $0.amountCents < $1.amountCents }
        return reportDraft(month: month, previous: previous, facts: monthFacts(ledger, month: month),
                           prior: previous.map { monthFacts(ledger, month: $0) },
                           budgets: budgetStatus(ledger, month: month), services: serviceChecks(ledger, month: month),
                           large: large, basisHash: reportBasis(ledger, month: month))
    }

    /// 由各项账目组成月卷草稿（直接计算与 FinanceLedgerIndex 共用）。large：本月大额支出，已按金额从大到小排好
    static func reportDraft(month: String, previous: String?, facts: MonthFacts, prior: MonthFacts?,
                            budgets: [BudgetStatus], services: [ServiceCheck],
                            large: [FinanceTransaction], basisHash: String) -> MonthlyReport {
        var comparison: MonthComparison?
        if facts.fullMonth, let prior, prior.fullMonth, let previous {
            let keys = Set(facts.categories.keys).union(prior.categories.keys)
            let changes = keys.map { key in
                CategoryChange(category: key, currentCents: facts.categories[key] ?? 0, previousCents: prior.categories[key] ?? 0,
                               changeCents: (facts.categories[key] ?? 0) - (prior.categories[key] ?? 0))
            }.sorted { abs($0.changeCents) != abs($1.changeCents) ? abs($0.changeCents) > abs($1.changeCents) : $0.category < $1.category }
            comparison = MonthComparison(previousMonth: previous, spendChangeCents: facts.spendCents - prior.spendCents,
                                         netChangeCents: facts.netSpendCents - prior.netSpendCents,
                                         nonEducationChangeCents: facts.nonEducationCents - prior.nonEducationCents, categories: changes)
        }
        let top = facts.categories.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var suggestions: [String] = []
        if !facts.fullMonth { suggestions.append("先确认银行导出日期是否覆盖整月，再判断与上月的变化。") }
        if facts.needsReviewCount > 0 {
            suggestions.append("先核对 \(facts.needsReviewCount) 笔待确认记录；商户消费可批量分类，个人转账逐笔确认。")
        }
        let overspent = budgets.filter { ($0.remainingCents ?? 0) < 0 }.map(\.label)
        if !overspent.isEmpty { suggestions.append("回看" + overspent.joined(separator: "、") + "超预算的原因，选择一项调整下月频率或额度。") }
        if (budgets.first { $0.key == "ride_hail" }?.spentCents ?? 0) > 0 {
            suggestions.append("回看打车记录，挑选一趟方便乘公共交通的行程作为下月调整目标。")
        }
        let optional = services.filter { $0.status != "keep" && $0.count > 0 }.map(\.label)
        if !optional.isEmpty { suggestions.append("核对" + optional.prefix(3).joined(separator: "、") + "的实际使用率；常用服务标记保留，闲置项目再考虑调整。") }
        if (facts.categories["彩票"] ?? 0) > 0 || (facts.categories["娱乐"] ?? 0) > 0 {
            suggestions.append("回看娱乐与彩票支出，确认用途并给下月设置一个你认可的额度。")
        }
        for fallback in ["给餐饮、打车或娱乐选择一个下月目标，额度由你决定。",
                         "把学费、年费等一次性开销写入月报备注，比较日常消费时单独查看。",
                         "下次导入后回看类别变化；支出下降不自动等同于某项措施已经省下的钱。"] where suggestions.count < 3 {
            suggestions.append(fallback)
        }
        let purchases = large.prefix(5).map { LargePurchase(date: $0.date, merchant: merchantKey($0), category: $0.category, cents: -$0.amountCents) }
        return MonthlyReport(month: month, basisHash: basisHash, summary: facts, comparison: comparison,
                             topCategories: top.prefix(3).map { CategoryAmount(category: $0.key, cents: $0.value) },
                             budgets: budgets, services: services, suggestions: Array(suggestions.prefix(3)),
                             largePurchases: purchases, engine: "swift-1")
    }

    /// 保存月报：同月版本号递增；与最新版本完全相同则不重复保存。
    static func saveReport(in ledger: inout FinanceLedger, month: String, reflection: String) -> (MonthlyReport, Bool) {
        var report = reportDraft(ledger, month: month)
        let sameMonth = ledger.monthlyReports.filter { $0.month == month }
        if let latest = sameMonth.last, latest.basisHash == report.basisHash, latest.reflection == reflection {
            return (latest, false)
        }
        report.version = (sameMonth.map(\.version).max() ?? 0) + 1
        report.reflection = reflection
        report.generatedAt = now()
        report.id = digest([report.month, report.version, report.generatedAt, report.basisHash])
        ledger.monthlyReports.append(report)
        return (report, true)
    }

    /// 默认显示：最近一个已结束且覆盖整月的月份，否则最近有记录的月份。
    static func defaultMonth(_ ledger: FinanceLedger, today: LocalDay = .today()) -> String {
        let months = ledgerMonths(ledger)
        let current = String(today.key.prefix(7))
        if let full = months.first(where: { $0 < current && monthFacts(ledger, month: $0).fullMonth }) { return full }
        return months.first ?? current
    }

    // MARK: 合并（旧版导入）

    struct MergeResult { var transactions = 0; var sources = 0; var reports = 0; var rules = 0 }

    /// 把另一份账本并入：按 ID 去重，已有记录（含你在新版里的修改）一律保留。
    @discardableResult
    static func merge(_ other: FinanceLedger, into ledger: inout FinanceLedger) -> MergeResult {
        var result = MergeResult()
        let ids = Set(ledger.transactions.map(\.id))
        for row in other.transactions where !ids.contains(row.id) { ledger.transactions.append(row); result.transactions += 1 }
        let sourceKeys = Set(ledger.sources.map { $0.sha256 + "|" + $0.account })
        for source in other.sources where !sourceKeys.contains(source.sha256 + "|" + source.account) {
            ledger.sources.append(source); result.sources += 1
        }
        let reportIDs = Set(ledger.monthlyReports.map(\.id))
        for report in other.monthlyReports where !reportIDs.contains(report.id) { ledger.monthlyReports.append(report); result.reports += 1 }
        let ruleIDs = Set(ledger.merchantRules.map(\.id))
        for rule in other.merchantRules where !ruleIDs.contains(rule.id) { ledger.merchantRules.append(rule); result.rules += 1 }
        for (key, value) in other.reviewPreferences where ledger.reviewPreferences[key] == nil { ledger.reviewPreferences[key] = value }
        for (month, limits) in other.budgets where ledger.budgets[month] == nil { ledger.budgets[month] = limits }
        return result
    }
}

// MARK: - 账本派生数据（同一版账本只算一次）

/// 一版账本的派生数据：交易按月分组、各月账目、预算、固定账单、月卷草稿、交易明细的排序与搜索文字。
/// 每一项都与 FinanceEngine 里直接计算的同名函数结果完全相同（CoreCheck 逐项对照），只是同一版账本里各算一次：
/// 切月份、开关弹窗、拖窗口改宽度时都只是查表。账本一变就换一个新的（FinanceService 按存储对象与更新时间判断）。
/// 按需计算、算过就记下，所以是引用类型；不加锁，只在主线程用。
final class FinanceLedgerIndex {
    let ledger: FinanceLedger
    /// 有记录的月份，新的在前（同 FinanceEngine.ledgerMonths）
    let months: [String]
    /// 仍计入统计的待确认笔数（全部月份）
    let awaitingReviewCount: Int

    /// 交易按 `month`（日期前 7 个字）分组：账本里的下标，组内保持账本里的顺序
    private let rowsByMonth: [String: [Int]]
    private let awaitingByMonth: [String: Int]
    /// 交易日期全是 ASCII（实际总是如此）时，按日期范围取一个月的交易可以只看这个月的分组
    private let asciiDates: Bool
    /// 每个账户已证实的覆盖范围（全部导入 / 只算确认过导出范围的），按开始日期排好、解析好
    private let coverage: [String: (all: [(LocalDay, LocalDay)], confirmed: [(LocalDay, LocalDay)])]

    private var factsCache: [String: MonthFacts] = [:]
    private var budgetCache: [String: [BudgetStatus]] = [:]
    private var serviceCache: [String: [ServiceCheck]] = [:]
    private var draftCache: [String: MonthlyReport] = [:]
    /// 交易明细的排序（nil 键 = 全部月份）
    private var sortedCache: [String?: [Int]] = [:]
    private var displays: [String?] = []
    private var searchTexts: [SearchText?] = []

    /// 只取决于银行描述的结果（账单 / 打车分组命中哪几组、商户名的好读写法），换新版账本时沿用：
    /// 多数修改只动类别、备注，描述不变，不必再对每笔跑一遍正则。只记 ASCII 描述（字符串相等即逐字节相同）。
    private var groupMemo: [String: UInt16]
    private var displayMemo: [String: String]

    /// 交易明细搜索用的大写文字（描述、备注、商户名）
    private struct SearchText {
        var description: String
        var note: String
        var display: String
    }

    init(_ ledger: FinanceLedger, reusing previous: FinanceLedgerIndex? = nil) {
        self.ledger = ledger
        var byMonth: [String: [Int]] = [:], awaiting: [String: Int] = [:]
        var awaitingTotal = 0
        var ascii = true
        for (index, row) in ledger.transactions.enumerated() {
            let month = row.month
            byMonth[month, default: []].append(index)
            if row.awaitingReview {
                awaiting[month, default: 0] += 1
                awaitingTotal += 1
            }
            if ascii && !row.date.utf8.allSatisfy({ $0 < 0x80 }) { ascii = false }
        }
        rowsByMonth = byMonth
        awaitingByMonth = awaiting
        awaitingReviewCount = awaitingTotal
        asciiDates = ascii
        months = FinanceEngine.ledgerMonths(Set(byMonth.keys), sources: ledger.sources)
        var coverage: [String: (all: [(LocalDay, LocalDay)], confirmed: [(LocalDay, LocalDay)])] = [:]
        for account in Set(ledger.sources.map(\.account)) {
            let mine = ledger.sources.filter { $0.account == account }
            coverage[account] = (FinanceEngine.coverageIntervals(mine.compactMap(\.range)),
                                 FinanceEngine.coverageIntervals(mine.filter { $0.statementPeriod != nil }.compactMap(\.range)))
        }
        self.coverage = coverage
        // 上一版攒下的描述结果：比这本账大出很多时（例如换了一本账）不沿用，免得越攒越多
        let limit = ledger.transactions.count * 2 + 1000
        groupMemo = previous.flatMap { $0.groupMemo.count <= limit ? $0.groupMemo : nil } ?? [:]
        displayMemo = previous.flatMap { $0.displayMemo.count <= limit ? $0.displayMemo : nil } ?? [:]
    }

    // MARK: 月份与账目

    /// 这个月有没有交易（同 `transactions.contains { $0.month == month }`）
    func hasTransactions(in month: String) -> Bool { rowsByMonth[month] != nil }

    /// 这个月（按 `month` 前 7 个字）仍计入统计的待确认笔数
    func awaitingReviewCount(in month: String) -> Int { awaitingByMonth[month] ?? 0 }

    /// 同 FinanceEngine.monthFacts
    func monthFacts(_ month: String) -> MonthFacts {
        if let hit = factsCache[month] { return hit }
        let (first, last) = FinanceEngine.monthBounds(month)
        let rows: [FinanceTransaction]
        // 月份键是 7 个数字或“-”、首末日期都以它开头时，日期落在范围内的交易一定在这个月的分组里（ASCII 逐字节比较）；
        // 其余少见情况照原样整本筛
        if asciiDates, month.utf8.count == 7, month.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }),
           first.utf8.starts(with: month.utf8), last.utf8.starts(with: month.utf8) {
            rows = (rowsByMonth[month] ?? []).map { ledger.transactions[$0] }.filter { $0.date >= first && $0.date <= last }
        } else {
            rows = ledger.transactions.filter { $0.date >= first && $0.date <= last }
        }
        let accounts = FinanceEngine.coveredAccounts(ledger.sources, through: last)
        let complete = !accounts.isEmpty && accounts.allSatisfy { FinanceEngine.covers(parsed: coverage[$0]?.all ?? [], first, last) }
        let confirmed = !accounts.isEmpty && accounts.allSatisfy { FinanceEngine.covers(parsed: coverage[$0]?.confirmed ?? [], first, last) }
        let facts = FinanceEngine.monthFacts(month: month, first: first, last: last, rows: rows, accountCount: accounts.count,
                                             fullMonth: complete, coverageConfirmed: confirmed)
        factsCache[month] = facts
        return facts
    }

    /// 同 FinanceEngine.defaultMonth
    func defaultMonth(today: LocalDay = .today()) -> String {
        let current = String(today.key.prefix(7))
        if let full = months.first(where: { $0 < current && monthFacts($0).fullMonth }) { return full }
        return months.first ?? current
    }

    // MARK: 预算、固定账单、月卷

    /// 同 FinanceEngine.budgetStatus
    func budgetStatus(_ month: String) -> [BudgetStatus] {
        if let hit = budgetCache[month] { return hit }
        let ride = (groupRows["ride_hail"]?.byMonth[month] ?? []).reduce(0) { $0 - ledger.transactions[$1].amountCents }
        let result = FinanceEngine.budgetStatus(facts: monthFacts(month), rideCents: ride, limits: ledger.budgets[month] ?? [:])
        budgetCache[month] = result
        return result
    }

    /// 同 FinanceEngine.serviceChecks
    func serviceChecks(_ month: String) -> [ServiceCheck] {
        if let hit = serviceCache[month] { return hit }
        let previous = FinanceEngine.previousMonth(month)
        let priorFull = previous.map { monthFacts($0).fullMonth } ?? false
        let result = FinanceEngine.serviceChecks(month: month, previous: previous, priorFull: priorFull,
                                                 preferences: ledger.reviewPreferences) { group in
            let found = groupRows[group.key]
            return FinanceEngine.ServiceRows(current: (found?.byMonth[month] ?? []).map { ledger.transactions[$0] },
                                             prior: (previous.flatMap { found?.byMonth[$0] } ?? []).map { ledger.transactions[$0] },
                                             seenBefore: found?.firstMonth.map { $0 < month } ?? false)
        }
        serviceCache[month] = result
        return result
    }

    /// 同 FinanceEngine.reportDraft
    func reportDraft(_ month: String) -> MonthlyReport {
        if let hit = draftCache[month] { return hit }
        let previous = FinanceEngine.previousMonth(month)
        let facts = monthFacts(month)
        let prior = previous.map { monthFacts($0) }
        let mine = rowsByMonth[month] ?? []
        let large = mine.map { ledger.transactions[$0] }.filter(FinanceEngine.isLargePurchase).sorted { $0.amountCents < $1.amountCents }
        // 本月与上月的交易按账本里的顺序合在一起（两组下标各自递增，归并即可）
        let basisRows = Self.merged(mine, previous.flatMap { rowsByMonth[$0] } ?? []).map { ledger.transactions[$0] }
        let basis = FinanceEngine.reportBasis(rows: basisRows, facts: facts, prior: prior,
                                              budgets: ledger.budgets[month] ?? [:], preferences: ledger.reviewPreferences)
        let draft = FinanceEngine.reportDraft(month: month, previous: previous, facts: facts, prior: prior,
                                              budgets: budgetStatus(month), services: serviceChecks(month), large: large, basisHash: basis)
        draftCache[month] = draft
        return draft
    }

    /// 两组递增的下标合成一组（去重、仍递增）
    private static func merged(_ a: [Int], _ b: [Int]) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if j == b.count || (i < a.count && a[i] < b[j]) {
                result.append(a[i]); i += 1
            } else if i == a.count || b[j] < a[i] {
                result.append(b[j]); j += 1
            } else {
                result.append(a[i]); i += 1; j += 1
            }
        }
        return result
    }

    /// 计入消费的扣款里，固定账单各组与打车组命中的交易：分组键 → 月份 → 账本下标（账本顺序），以及最早出现的月份。
    /// 第一次用到时对全部扣款跑一遍分组正则（描述相同的沿用上一版的结果）。
    private lazy var groupRows: [String: (byMonth: [String: [Int]], firstMonth: String?)] = {
        var result: [String: (byMonth: [String: [Int]], firstMonth: String?)] = [:]
        for (index, row) in ledger.transactions.enumerated() where FinanceEngine.isSpending(row) {
            let mask = groupMask(row.description)
            guard mask != 0 else { continue }
            let month = row.month
            for (bit, group) in Self.trackedGroups.enumerated() where mask & (1 << bit) != 0 {
                var entry = result[group.key] ?? ([:], nil)
                entry.byMonth[month, default: []].append(index)
                if entry.firstMonth.map({ month < $0 }) ?? true { entry.firstMonth = month }
                result[group.key] = entry
            }
        }
        return result
    }()

    /// 需要逐笔判断的商户分组：固定账单（serviceKeys）与预算里的打车
    private static let trackedGroups = FinanceEngine.merchantGroups.filter {
        FinanceEngine.serviceKeys.contains($0.key) || $0.key == "ride_hail"
    }

    /// 一个描述命中 trackedGroups 的哪几组（按位）
    private func groupMask(_ description: String) -> UInt16 {
        let ascii = description.utf8.allSatisfy { $0 < 0x80 }
        if ascii, let hit = groupMemo[description] { return hit }
        var mask: UInt16 = 0
        for (bit, group) in Self.trackedGroups.enumerated() where FinanceEngine.matches(group.pattern, description) {
            mask |= 1 << bit
        }
        if ascii { groupMemo[description] = mask }
        return mask
    }

    // MARK: 交易明细

    /// 第 index 笔交易在界面上显示的商户名（同 FinanceEngine.merchantDisplay）
    func merchantDisplay(at index: Int) -> String {
        if displays.isEmpty { displays = Array(repeating: nil, count: ledger.transactions.count) }
        if let hit = displays[index] { return hit }
        let row = ledger.transactions[index]
        let text: String
        // 银行流水的商户名只取决于描述；手记直接用说明，不必记
        if !row.isManual, row.description.utf8.allSatisfy({ $0 < 0x80 }) {
            if let memo = displayMemo[row.description] {
                text = memo
            } else {
                text = FinanceEngine.merchantDisplay(row)
                displayMemo[row.description] = text
            }
        } else {
            text = FinanceEngine.merchantDisplay(row)
        }
        displays[index] = text
        return text
    }

    /// 交易明细的行（账本里的下标）：某个月（nil 为全部月份）里 keep 为真、且描述 / 备注 / 商户名（不分大小写）或类别含搜索词的交易，
    /// 按日期从新到旧、同日按导入行号排。query 是去掉首尾空格的搜索词，空的不筛。
    /// 先排好再筛：排序是稳定的，与原来“先筛再排”的结果相同。
    func rows(month: String?, query raw: String, where keep: (FinanceTransaction) -> Bool) -> [Int] {
        let query = raw.uppercased()
        var result: [Int] = []
        for index in sortedRows(month) {
            let row = ledger.transactions[index]
            guard keep(row) else { continue }
            if !query.isEmpty {
                let text = searchText(index)
                guard text.description.contains(query) || text.note.contains(query) || row.category.contains(raw)
                        || text.display.contains(query) else { continue }
            }
            result.append(index)
        }
        return result
    }

    private func sortedRows(_ month: String?) -> [Int] {
        if let hit = sortedCache[month] { return hit }
        let scope = month.map { rowsByMonth[$0] ?? [] } ?? Array(ledger.transactions.indices)
        let sorted = scope.map { (date: ledger.transactions[$0].date, line: ledger.transactions[$0].sourceLine, index: $0) }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.line < $1.line }
            .map(\.index)
        sortedCache[month] = sorted
        return sorted
    }

    private func searchText(_ index: Int) -> SearchText {
        if searchTexts.isEmpty { searchTexts = Array(repeating: nil, count: ledger.transactions.count) }
        if let hit = searchTexts[index] { return hit }
        let row = ledger.transactions[index]
        let text = SearchText(description: row.description.uppercased(), note: row.note.uppercased(),
                              display: merchantDisplay(at: index).uppercased())
        searchTexts[index] = text
        return text
    }
}

enum FinanceError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}
