import Foundation

/// 与时区无关的“本地日期”。内部使用儒略日数（JDN），日期加减不受夏令时影响。
/// 存储格式与旧版一致：`YYYY-MM-DD`。
struct LocalDay: Hashable, Comparable, Codable, CustomStringConvertible {
    let jdn: Int

    init(jdn: Int) { self.jdn = jdn }

    init(year: Int, month: Int, day: Int) {
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        jdn = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
    }

    /// 解析 `YYYY-MM-DD`；格式或日期无效时返回 nil。
    init?(key: String) {
        guard let parts = LocalDay.canonicalParts(key) ?? LocalDay.splitParts(key),
              (1...12).contains(parts.month), (1...31).contains(parts.day) else { return nil }
        self.init(year: parts.year, month: parts.month, day: parts.day)
        let c = civil
        guard c.month == parts.month, c.day == parts.day else { return nil }
    }

    /// 标准写法（正好 10 个字节：4 位数字-2 位数字-2 位数字）直接按字节读，不建数组；不是这个样子的返回 nil，交给 splitParts。
    /// 标准写法下两条路读出的年月日相同，所以解析结果与原来逐字一致。
    private static func canonicalParts(_ key: String) -> (year: Int, month: Int, day: Int)? {
        let bytes = key.utf8
        guard bytes.count == 10 else { return nil }
        var y = 0, m = 0, d = 0
        for (index, byte) in bytes.enumerated() {
            if index == 4 || index == 7 {
                guard byte == UInt8(ascii: "-") else { return nil }
                continue
            }
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            let digit = Int(byte - UInt8(ascii: "0"))
            if index < 4 { y = y * 10 + digit } else if index < 7 { m = m * 10 + digit } else { d = d * 10 + digit }
        }
        return (y, m, d)
    }

    /// 原来的解析：按“-”切开（空段忽略）、各段字数固定、Int 能读。多余的“-”、“+”号这类少见写法也照旧处理。
    private static func splitParts(_ key: String) -> (year: Int, month: Int, day: Int)? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return (y, m, d)
    }

    /// 每次新建 Calendar 只占约 0.09 µs，today() 的 0.5 µs 几乎全花在 dateComponents 上，复用 Calendar 实测没有收益，所以照旧
    init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    static func today(in timeZone: TimeZone = .current) -> LocalDay { LocalDay(date: Date(), timeZone: timeZone) }

    private var civil: (year: Int, month: Int, day: Int) {
        let a = jdn + 32044
        let b = (4 * a + 3) / 146097
        let c = a - 146097 * b / 4
        let d = (4 * c + 3) / 1461
        let e = c - 1461 * d / 4
        let m = (5 * e + 2) / 153
        return (100 * b + d - 4800 + m / 10, m + 3 - 12 * (m / 10), e - (153 * m + 2) / 5 + 1)
    }

    var year: Int { civil.year }
    var month: Int { civil.month }
    var day: Int { civil.day }

    /// 0 = 周一 … 6 = 周日（与旧版 Python `weekday()` 相同）。
    var weekdayIndex: Int { ((jdn % 7) + 7) % 7 }
    var mondayOfWeek: LocalDay { adding(days: -weekdayIndex) }
    var firstOfMonth: LocalDay { LocalDay(year: year, month: month, day: 1) }

    /// `YYYY-MM-DD`。0–9999 年（月、日不超过两位）直接拼 10 个字节，与 String(format: "%04d-%02d-%02d") 逐字相同但快得多；
    /// 超出这个范围的少见日期仍走 String(format:)。
    var key: String {
        let c = civil
        guard (0...9999).contains(c.year), (0...99).contains(c.month), (0...99).contains(c.day) else {
            return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
        }
        return String(unsafeUninitializedCapacity: 10) { buffer in
            func put(_ value: Int, digits: Int, at start: Int) {
                var rest = value
                for offset in stride(from: digits - 1, through: 0, by: -1) {
                    buffer[start + offset] = UInt8(ascii: "0") + UInt8(rest % 10)
                    rest /= 10
                }
            }
            put(c.year, digits: 4, at: 0)
            buffer[4] = UInt8(ascii: "-")
            put(c.month, digits: 2, at: 5)
            buffer[7] = UInt8(ascii: "-")
            put(c.day, digits: 2, at: 8)
            return 10
        }
    }
    var description: String { key }

    func adding(days: Int) -> LocalDay { LocalDay(jdn: jdn + days) }
    func days(to other: LocalDay) -> Int { other.jdn - jdn }

    /// 当天零点（指定时区）对应的 Date；minutes 为当天的墙钟时刻（第几分钟，可超出 0…1439，按天进位）。
    /// 按“年月日 + 时分”组装，而不是零点加绝对分钟数，所以夏令时切换日的 09:00 仍是当地 09:00；
    /// 落在被跳过的那一小时里的时刻由 Foundation 顺延。
    func date(minutes: Int = 0, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dayOffset = minutes >= 0 ? minutes / 1440 : -((-minutes + 1439) / 1440)
        let minuteOfDay = minutes - dayOffset * 1440
        let target = adding(days: dayOffset)
        let components = DateComponents(year: target.year, month: target.month, day: target.day,
                                        hour: minuteOfDay / 60, minute: minuteOfDay % 60)
        return calendar.date(from: components) ?? Date()
    }

    static func < (lhs: LocalDay, rhs: LocalDay) -> Bool { lhs.jdn < rhs.jdn }

    static func range(_ first: LocalDay, _ last: LocalDay) -> [LocalDay] {
        guard first <= last else { return [] }
        return (first.jdn...last.jdn).map(LocalDay.init(jdn:))
    }

    // MARK: 中文显示

    static let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    static let weekdayShortNames = ["一", "二", "三", "四", "五", "六", "日"]

    var weekdayName: String { LocalDay.weekdayNames[weekdayIndex] }
    var shortLabel: String { "\(month)月\(day)日" }
    var longLabel: String { "\(year)年\(month)月\(day)日 \(weekdayName)" }
    /// “10月14日”；不是 today 那一年时带上年份（“2025年10月14日”）
    func label(relativeTo today: LocalDay) -> String { year == today.year ? shortLabel : "\(year)年\(shortLabel)" }
    /// 图表横轴的短写法：“10/1”（月在前，不跟系统地区格式走，免得“1/10”被看成 1 月 10 日）
    var axisLabel: String { "\(month)/\(day)" }
    /// 所在月份的键 `YYYY-MM`
    var monthKey: String { String(key.prefix(7)) }
}

/// 月份键 `YYYY-MM` 的中文写法，全应用统一为“2026年10月”（与 longLabel 的“2026年10月14日”一致）。
enum MonthKey {
    /// 给了 today 且同一年时省略年份（“10月”）；认不出的键原样返回
    static func label(_ key: String, relativeTo today: LocalDay? = nil) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return key }
        return label(year: year, month: month, relativeTo: today)
    }

    static func label(year: Int, month: Int, relativeTo today: LocalDay? = nil) -> String {
        today?.year == year ? "\(month)月" : "\(year)年\(month)月"
    }
}

/// 时间的几种固定写法。格式化器按（格式、时区）缓存复用；一律 en_US_POSIX，不随系统地区设置变。
enum DateText {
    /// “2026-10-14 21:30”：快照、摘要、报告、回执里的时间
    static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String { string(date, format: "yyyy-MM-dd HH:mm", timeZone: timeZone) }

    /// “20261014-213000”：传书归档文件名开头的收录时间（清理归档时按它解析，格式不能改）
    static func fileStamp(_ date: Date) -> String { string(date, format: fileStampFormat) }
    static func date(fileStamp text: String) -> Date? { formatter(fileStampFormat, .current).date(from: text) }

    /// “10月14日 21:30”：界面上的时刻
    static func display(_ date: Date) -> String { string(date, format: "M月d日 HH:mm") }

    static func string(_ date: Date, format: String, timeZone: TimeZone = .current) -> String {
        formatter(format, timeZone).string(from: date)
    }

    private static let fileStampFormat = "yyyyMMdd-HHmmss"
    private static let lock = NSLock()
    private static var cache: [String: DateFormatter] = [:]

    /// 建好后只读不改（DateFormatter 只读时可以跨线程用）；缓存本身加锁
    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let key = format + "|" + timeZone.identifier
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        cache[key] = f
        return f
    }
}

/// `HH:MM` 与“当天第几分钟”之间的转换。
enum ClockTime {
    /// allowEndOfDay：只有结束时间才接受 “24:00”（当天结束），开始时间一律拒绝。
    static func minutes(from text: String?, allowEndOfDay: Bool = false) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        if h == 24 && m == 0 { return allowEndOfDay ? 24 * 60 : nil }
        guard (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    static func text(_ minutes: Int?) -> String {
        guard let minutes else { return "" }
        let clamped = max(0, min(minutes, 24 * 60))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    static func range(_ start: Int?, _ end: Int?) -> String {
        guard let start else { return "全天" }
        guard let end else { return text(start) }
        return "\(text(start))–\(text(end))"
    }

    static func minutes(of date: Date, timeZone: TimeZone = .current) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
