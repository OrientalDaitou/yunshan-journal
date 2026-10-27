import Foundation

/// 常驻动效（流云、灵气光点、远山、星点、晨雾、长卷金光呼吸）此刻开不开（#20 能耗）。
/// 没人看的时候整组停下、一动就接着飘：各层都用 setPaused 原地停、原地续，画面不跳，人在用的时候一切照旧。
/// 这里只做判断（纯函数，CoreCheck 测）；收事件、看主窗口遮挡在 Views/ActivityWatch.swift。
enum MotionGate {
    /// 前台放着多久不碰算“走开了”（秒）：3 分钟
    static let idleAfter: TimeInterval = 180
    /// 低频检查最长隔多久（秒）。离 3 分钟不到 30 秒时改为正好在 3 分钟那一刻再看一次，所以停得准；恢复不靠它，碰一下立刻恢复
    static let checkEvery: TimeInterval = 30

    /// 距最后一次操作已满 3 分钟（时间用同一个钟：开机以来的秒数）
    static func isIdle(now: TimeInterval, lastActivity: TimeInterval, after threshold: TimeInterval = idleAfter) -> Bool {
        now - lastActivity >= threshold
    }

    /// 下一次检查在多少秒后；已经闲着时为 nil（不用再定时，等下一次操作）。
    /// 最长 30 秒、最短 1 秒：时钟被拨回（lastActivity 比 now 还晚）时也按 30 秒算，不会忙等
    static func nextCheck(now: TimeInterval, lastActivity: TimeInterval, after threshold: TimeInterval = idleAfter) -> TimeInterval? {
        guard !isIdle(now: now, lastActivity: lastActivity, after: threshold) else { return nil }
        let remaining = lastActivity + threshold - now
        return min(checkEvery, max(1, remaining))
    }

    /// 主窗口算不算被挡住：只在窗口已经摆上屏、且系统说它一点都看不见时才算
    /// （被别的应用窗口完全盖住、最小化、在别的桌面、屏幕锁定或熄灭）。窗口还没上屏时按“看得见”算，等系统通知再改
    static func isOccluded(onScreen: Bool, visibleFlag: Bool) -> Bool {
        onScreen && !visibleFlag
    }

    /// 常驻动效开不开：动效开关开、系统没开“减少动态效果”、窗口在前台、近 3 分钟有人动过、主窗口没被完全挡住。
    /// 前三项就是原来的定义（动效开关的含义不变）；后两项只在“没人看”时让它暂时视为关
    static func allows(enabled: Bool, reduceMotion: Bool, inactive: Bool, idle: Bool, occluded: Bool) -> Bool {
        enabled && !reduceMotion && !inactive && !idle && !occluded
    }

    /// 金光呼吸（岁月长卷期末徽记背后）的节律：0.9 ↔ 1.15 倍，2.4 秒一个来回，按余弦缓入缓出
    enum Breath {
        static let low: Double = 0.9
        static let high: Double = 1.15
        static let period: Double = 2.4

        /// t 秒时的倍数（原来 SwiftUI 逐帧算的公式；Core Animation 版用同样的曲线，样子不变）
        static func scale(at t: Double) -> Double {
            let phase = (1 - cos(t * 2 * .pi / period)) / 2
            return low + (high - low) * phase
        }

        /// 从静止的 1 倍开始呼吸时，动画要先走多少秒，才正好落在 1 倍那一点（往上走的半程里）：
        /// 关着动效时金光停在 1 倍，打开时从 1 倍接着长，不先跳回 0.9
        static var restOffset: Double {
            let phase = (1 - low) / (high - low)
            return acos(1 - 2 * phase) * period / (2 * .pi)
        }
    }
}
