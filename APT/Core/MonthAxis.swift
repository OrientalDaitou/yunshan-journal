import Foundation

/// 灵石账簿「各月消费」图的横轴标签：月份一多（5 年 60 个月），每月都标就挤成一团，所以按图的实际宽度抽稀。
/// - 只有今年的月份时写“3月”；跨年时每年 1 月写成“2025年”（年份就标在年初那根柱下），其余写“3月”，
///   最早一根柱不是 1 月时写全“2024年11月”（放得下才标），免得开头几个月看不出是哪一年；
/// - 间隔从每月、每 2 / 3 / 4 / 6 个月、每年、每 2 年……里取最密、又互不重叠的一档，都从 1 月数起，各年对齐；
/// - 选中的月份始终标出（写全年份，今年的只写“10月”），与它挤在一起的其他标签让开；
/// - 宽度按字估：汉字一个字号宽，数字约 0.62 个字号宽，相邻两个标签至少隔 8 点。
/// 纯函数，CoreCheck 核对。
enum MonthAxis {
    /// 相邻两个标签之间至少留的空（点）
    static let gap = 8.0

    /// 要标出的月份（键 "YYYY-MM"）与写什么。months 从早到晚；width 是绘图区宽度（点）；没在 months 里的 selected 不标
    static func labels(months: [String], selected: String, today: LocalDay, width: Double, fontSize: Double = 10.5) -> [String: String] {
        let parsed = months.map(parse)
        guard !months.isEmpty, width > 0 else { return [:] }
        let slot = width / Double(months.count)
        let multiYear = parsed.contains { $0.map { $0.year != today.year } ?? false }
        func text(_ i: Int) -> String {
            guard let ym = parsed[i] else { return months[i] }
            if !multiYear { return "\(ym.month)月" }
            if ym.month == 1 { return "\(ym.year)年" }
            return i == 0 ? "\(ym.year)年\(ym.month)月" : "\(ym.month)月"
        }
        func center(_ i: Int) -> Double { (Double(i) + 0.5) * slot }
        func fits(_ a: (center: Double, width: Double), _ b: (center: Double, width: Double)) -> Bool {
            abs(a.center - b.center) >= (a.width + b.width) / 2 + gap
        }
        // 间隔：取各标签互不重叠的最密一档（最早那根柱另算，见下）
        var regular: [Int] = []
        for step in [1, 2, 3, 4, 6, 12, 24, 36, 60, 120, 240, 600] {
            let picked = parsed.indices.filter { i in
                guard let ym = parsed[i] else { return false }
                return step <= 12 ? (ym.month - 1) % step == 0 : ym.month == 1 && ym.year % (step / 12) == 0
            }
            let boxes = picked.map { (center: center($0), width: textWidth(text($0), fontSize: fontSize)) }
            regular = picked
            if zip(boxes, boxes.dropFirst()).allSatisfy({ fits($0, $1) }) { break }
        }
        // 先放选中的，再放年初、最早一根柱，最后放其余各档：与已放下的重叠就不标
        var order: [Int] = []
        if let s = months.firstIndex(of: selected) { order.append(s) }
        order += regular.filter { parsed[$0]?.month == 1 }
        if multiYear, parsed[0]?.month != 1 { order.append(0) }
        order += regular.filter { parsed[$0]?.month != 1 }
        var placed: [(center: Double, width: Double)] = []
        var result: [String: String] = [:]
        for i in order where result[months[i]] == nil {
            let isSelected = months[i] == selected
            let label = isSelected ? MonthKey.label(months[i], relativeTo: today) : text(i)
            let box = (center: center(i), width: textWidth(label, fontSize: fontSize) * (isSelected ? 1.06 : 1))
            guard isSelected || placed.allSatisfy({ fits($0, box) }) else { continue }
            placed.append(box)
            result[months[i]] = label
        }
        return result
    }

    /// 估一个标签的宽度（点）：ASCII 字符约 0.62 个字号宽，其余（汉字）一个字号宽
    static func textWidth(_ text: String, fontSize: Double) -> Double {
        text.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? fontSize * 0.62 : fontSize) }
    }

    private static func parse(_ key: String) -> (year: Int, month: Int)? {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        return (year, month)
    }
}
