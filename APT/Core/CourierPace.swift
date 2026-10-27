import Foundation

/// 飞剑传书巡查的节奏（#21 能耗）：这一轮看完，隔多久再看一眼收件箱与数据。
///
/// - 应用在前台：每 3 秒（容差 1 秒，让系统把几处定时器并成一次唤醒）。
/// - 不在前台：收件箱有人盯着（InboxWatcher 的文件系统监视开起来了）就只在有文件进出、数据库保存、回到前台时醒来，另 60 秒兜底；
///   监视没开起来（收件箱建不出来等）退回每 10 秒。
/// - 收件箱里有刚写入、还没满 1 秒的传书（巡查要等文件写稳才收），就等它满 1 秒再看：AI 投进来的仍约 1–3 秒收录。
/// - 数据刚变、还没停稳：3 秒后再看一眼确认，确认没再变才重建快照（与以前“停稳 3 秒”同一节奏）。
enum CourierPace {
    struct Wait: Equatable {
        var seconds: Double
        var tolerance: Double
    }

    static let foreground = Wait(seconds: 3, tolerance: 1)
    static let background = Wait(seconds: 10, tolerance: 2)
    static let watched = Wait(seconds: 60, tolerance: 5)
    /// 刚写入的文件要停稳这么久才收录（与 CourierService.pendingFiles 的“满 1 秒”一致）
    static let settle: Double = 1
    /// 被叫醒时离上一轮至少隔这么久：一连串保存、一次写好几个文件，只多看一次
    static let minimumGap: Double = 0.5
    /// 不带修改时间的改动（珍藏等）靠这里兜底重建快照；归档清理的间隔
    static let recheckEvery: Double = 10 * 60
    static let cleanEvery: Double = 6 * 3600

    /// 下一次醒来前睡多久。settlingAge：收件箱里还在等写稳（不满 settle 秒）的传书里，写得最早那封已过了多少秒（没有就是 nil）
    static func next(foreground front: Bool, watching: Bool, unsettled: Bool, settlingAge: Double? = nil) -> Wait {
        var wait = front ? foreground : (watching ? watched : background)
        // 数据还没停稳：不论前后台，3 秒后再确认一次（不然后台改了一笔要等 60 秒才进快照）
        if unsettled, wait.seconds > foreground.seconds { wait = foreground }
        // 刚写入的传书：等它满 settle 秒再看（多留 0.1 秒，免得差一点又要再等一轮）；钟面倒拨（写入时刻在未来）时按常规节奏
        if let age = settlingAge, age >= 0, age < settle {
            let rest = settle - age + 0.1
            if rest < wait.seconds { wait = Wait(seconds: rest, tolerance: 0.1) }
        }
        return wait
    }

    /// 定时兜底到点没有（钟面倒拨时也算到点，免得一直不做）
    static func due(since last: Date, now: Date, every: Double) -> Bool {
        let gone = now.timeIntervalSince(last)
        return gone >= every || gone < 0
    }

    /// 被叫醒后还要再等多久才开始这一轮：离上一轮不到 minimumGap 就补足
    static func gapLeft(since last: Date, now: Date) -> Double {
        let gone = now.timeIntervalSince(last)
        guard gone >= 0 else { return 0 }
        return max(0, minimumGap - gone)
    }
}
