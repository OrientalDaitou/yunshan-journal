import Foundation

// 天色随时辰：本机时刻 → 晨 / 昼 / 暮 / 夜 四时权重，以及首页问候、十二时辰。
// 纯函数，只依赖 Foundation（CoreCheck 单独编译这个文件夹）。调色表在 SkyPalette.swift。

/// 四时天色
enum SkyPhase: String, CaseIterable {
    case dawn, day, dusk, night
}

/// 四时权重：四项和为 1，同一时刻最多两项不为 0（过渡时一升一降）
struct SkyMix: Equatable {
    var dawn = 0.0, day = 1.0, dusk = 0.0, night = 0.0

    /// 正午：只有“昼”，等于不加任何天色
    static let noon = SkyMix()

    /// 只有一种天色
    init(pure phase: SkyPhase) {
        self.init(dawn: 0, day: 0, dusk: 0, night: 0)
        self[phase] = 1
    }

    init(dawn: Double = 0, day: Double = 1, dusk: Double = 0, night: Double = 0) {
        self.dawn = dawn
        self.day = day
        self.dusk = dusk
        self.night = night
    }

    subscript(_ phase: SkyPhase) -> Double {
        get {
            switch phase {
            case .dawn: dawn
            case .day: day
            case .dusk: dusk
            case .night: night
            }
        }
        set {
            switch phase {
            case .dawn: dawn = newValue
            case .day: day = newValue
            case .dusk: dusk = newValue
            case .night: night = newValue
            }
        }
    }

    /// 四项里变化最大的那一项的变化量：SkyTimeline 用它判断“一小步直接换 / 一大步渐变过去”
    func maxDelta(to other: SkyMix) -> Double {
        SkyPhase.allCases.map { abs(self[$0] - other[$0]) }.max() ?? 0
    }
}

enum SkyClock {
    /// 关键时刻（当天第几分钟 → 这一刻是纯粹的哪种天色）。相邻两个关键点之间按 smoothstep 过渡，
    /// 最后一个关键点接回第一个（跨午夜）
    static let keyframes: [(minute: Int, phase: SkyPhase)] = [
        (270, .night),   // 04:30
        (330, .dawn),    // 05:30
        (420, .dawn),    // 07:00
        (510, .day),     // 08:30
        (990, .day),     // 16:30
        (1050, .dusk),   // 17:30
        (1125, .dusk),   // 18:45
        (1185, .night),  // 19:45
    ]

    /// minute 可以带小数，超出 [0, 1440) 时按天取模
    static func mix(minute: Double) -> SkyMix {
        guard minute.isFinite else { return .noon }
        var m = minute.truncatingRemainder(dividingBy: 1440)
        if m < 0 { m += 1440 }
        let count = keyframes.count
        for index in 0..<count {
            let from = keyframes[index], to = keyframes[(index + 1) % count]
            // 这一段的长度与已走过的分钟数（跨午夜的那段按 +1440 算）
            var span = Double(to.minute - from.minute)
            if span <= 0 { span += 1440 }
            var elapsed = m - Double(from.minute)
            if elapsed < 0 { elapsed += 1440 }
            guard elapsed < span else { continue }
            if from.phase == to.phase { return SkyMix(pure: from.phase) }
            let t = smoothstep(elapsed / span)
            var result = SkyMix(dawn: 0, day: 0, dusk: 0, night: 0)
            result[from.phase] = 1 - t
            result[to.phase] = t
            return result
        }
        return .noon
    }

    /// 墙钟时刻（含秒的小数分钟）。用 .autoupdatingCurrent：改了系统时区马上就生效
    static func minute(of date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let seconds = Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1_000_000_000
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) + seconds / 60
    }

    static func mix(at date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> SkyMix {
        mix(minute: minute(of: date, timeZone: timeZone))
    }

    /// 首页问候：分界与原来相同（<6 夜深了，<12 早安，<18 午安，其余 晚上好）
    static func greeting(minute: Int) -> String {
        let hour = wrapped(minute) / 60
        return hour < 6 ? "夜深了" : hour < 12 ? "早安" : hour < 18 ? "午安" : "晚上好"
    }

    /// 时辰：子时 23:00–00:59，丑时 01:00–02:59 … 亥时 21:00–22:59
    static func shichen(minute: Int) -> String {
        let names = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]
        return names[((wrapped(minute) + 60) / 120) % 12] + "时"
    }

    /// 横幅眉题整句：“晚上好，青岚 · 10月20日 周二 · 酉时”（日期用页面传进来的 today，与页面其余部分一致）
    static func greetingLine(name: String, today: LocalDay, minute: Int) -> String {
        "\(greeting(minute: minute))，\(name) · \(today.label(relativeTo: today)) \(today.weekdayName) · \(shichen(minute: minute))"
    }

    static func smoothstep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// 分钟数取模到 0…1439
    private static func wrapped(_ minute: Int) -> Int { ((minute % 1440) + 1440) % 1440 }
}
