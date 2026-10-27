import Foundation

// 关键时刻的仪式（落笔入卷、功课圆满、朱印）的时间轴：纯函数，给出每个时刻各部分的状态（pose）。
// Core Animation 播放时按它取样生成关键帧，离屏定格时直接按它摆图层，CoreCheck 也拿它验“1.5 秒后全部透明”，
// 三处用的是同一份时间函数，画面对得上。pose 里只存 0…1 的进度量，pt、半径、角度由 RitualHostView 换算。

enum RitualTimeline {
    /// 落笔入卷（墨迹晕开 + 纸卷合拢 + 飞入修行录）的总长
    static let inscriptionLength = 1.5
    /// 功课圆满（四方灵光汇丹田 + 金符展开）的总长
    static let consummationLength = 1.5
    /// 朱印：落下、涟漪、淡成印痕，2.2 秒起 0.4 秒淡出（与 SwiftUI 版 SealStamp 同一时间轴）
    static let sealLength = 2.6

    // MARK: 落笔入卷

    struct InscriptionPose: Equatable {
        /// 衬纸：与落笔框底同色的纸面，一直留到 1350 ms 再淡出
        var backingAlpha: Double
        /// 纸笺（刚写的那页）：不透明度、文字洇开的程度（0…1 → 模糊 0…1.2pt）、卷起的比例（0 = 平铺，1 = 卷完）
        var slipAlpha, slipBlur, roll: Double
        /// 卷轴：不透明度（含抵达时淡去）、粗细（0…1 → 12…18pt）
        var rodAlpha, rodWidth: Double
        /// 墨晕（三团从印下往左上漫开）、印泥晕（印下一圈朱砂淡晕）
        var bloomScale, bloomAlpha, haloScale, haloAlpha: Double
        /// 墨星外溅：飞出的进度与不透明度
        var splatter, splatterAlpha: Double
        /// 小卷飞行：沿弧线的进度、缩小的进度（0…1 → 1…0.3 倍）、裹着小卷的那团灵光
        var flight, flightScale, flightAlpha: Double
        /// 尾迹：末端跟到哪里（strokeStart，比小卷晚 150 ms）与不透明度；前端就是 flight
        var trail, trailAlpha: Double
        /// 抵达“修行录”：金色涟漪的半径进度（0…1 → 22…42pt）与不透明度、小物处一闪的灵光
        var pulseRadius, pulseAlpha, arrivalGlow: Double
        /// 没有“修行录”的位置时：卷好的小卷在原地淡去（900–1100 ms）
        var strandedAlpha: Double

        /// 所有不透明度（CoreCheck：1.5 秒后全为 0）
        var alphas: [Double] {
            [backingAlpha, slipAlpha, rodAlpha, bloomAlpha, haloAlpha, splatterAlpha, flightAlpha, trailAlpha, pulseAlpha, arrivalGlow, strandedAlpha]
        }
        /// 全部量（CoreCheck：都在 [0,1]）
        var values: [Double] {
            alphas + [slipBlur, roll, rodWidth, bloomScale, haloScale, splatter, flight, flightScale, trail, pulseRadius]
        }
    }

    static func inscription(at time: Double) -> InscriptionPose {
        let t = max(0, time)
        let roll = easeInQuad(progress(t, 0.35, 0.9))
        let flight = smoothstep(progress(t, 0.9, 1.35))
        let arrived = t >= 1.35
        return InscriptionPose(
            backingAlpha: 1 - progress(t, 1.35, 1.5),
            slipAlpha: 1 - smoothstep(progress(t, 0.84, 0.9)),
            slipBlur: easeOutCubic(progress(t, 0.15, 0.5)),
            roll: roll,
            rodAlpha: progress(t, 0.35, 0.41) * (1 - smoothstep(progress(t, 1.3, 1.38))),
            rodWidth: roll,
            bloomScale: easeOutCubic(progress(t, 0.15, 0.8)),
            bloomAlpha: smoothstep(progress(t, 0.15, 0.32)) * (1 - smoothstep(progress(t, 0.32, 0.8))),
            haloScale: easeOutCubic(progress(t, 0.15, 0.55)),
            haloAlpha: smoothstep(progress(t, 0.15, 0.2)) * (1 - smoothstep(progress(t, 0.35, 0.75))),
            splatter: easeOutCubic(progress(t, 0.15, 0.38)),
            splatterAlpha: progress(t, 0.15, 0.17) * (1 - smoothstep(progress(t, 0.24, 0.38))),
            flight: flight,
            flightScale: easeOutCubic(progress(t, 0.9, 1.35)),
            flightAlpha: smoothstep(progress(t, 0.9, 1.05)) * (1 - smoothstep(progress(t, 1.33, 1.45))),
            trail: smoothstep(progress(t - 0.15, 0.9, 1.35)),
            trailAlpha: (t >= 0.9 ? 1 : 0) * (1 - progress(t, 1.38, 1.5)),
            pulseRadius: easeOutCubic(progress(t, 1.35, 1.5)),
            pulseAlpha: arrived ? 1 - progress(t, 1.35, 1.5) : 0,
            arrivalGlow: smoothstep(progress(t, 1.28, 1.36)) * (1 - smoothstep(progress(t, 1.36, 1.5))),
            strandedAlpha: 1 - smoothstep(progress(t, 0.9, 1.1)))
    }

    // MARK: 功课圆满

    struct ConsummationPose: Equatable {
        /// 四方灵光汇聚：总进度、整体不透明度、缩小的进度（0…1 → 1…0.4 倍）
        var gather, moteAlpha, moteScale: Double
        /// 刚点的打卡圈升起的一缕玉色灵线：前端、末端、不透明度
        var thread, threadTail, threadAlpha: Double
        /// 丹田一亮：金光（大小进度、不透明度）、金环（半径进度 0…1 → 36…96pt、不透明度）、八道短芒（转过的进度、不透明度）
        var flare, flareAlpha, ringRadius, ringAlpha, rays, raysAlpha: Double
        /// 符箓：展开的比例、字依次显出的进度、白光扫过的进度与不透明度、整体不透明度、上浮的进度（0…1 → 8pt）
        var unroll, textReveal, glint, glintAlpha, bannerAlpha, bannerRise: Double
        /// 金屑：飘起的进度与不透明度
        var sparks, sparkAlpha: Double

        var alphas: [Double] { [moteAlpha, threadAlpha, flareAlpha, ringAlpha, raysAlpha, glintAlpha, bannerAlpha, sparkAlpha] }
        var values: [Double] {
            alphas + [gather, moteScale, thread, threadTail, flare, ringRadius, rays, unroll, textReveal, glint, bannerRise, sparks]
        }
    }

    static func consummation(at time: Double) -> ConsummationPose {
        let t = max(0, time)
        let gather = progress(t, 0, 0.65)
        return ConsummationPose(
            gather: gather,
            moteAlpha: moteEnvelope(at: t),
            moteScale: gather * gather,
            thread: easeInOutSine(progress(t, 0.02, 0.6)),
            threadTail: easeInOutSine(progress(t, 0.17, 0.66)),
            threadAlpha: progress(t, 0.02, 0.08) * (1 - progress(t, 0.56, 0.66)),
            flare: easeOutCubic(progress(t, 0.6, 1.0)),
            flareAlpha: smoothstep(progress(t, 0.6, 0.7)) * (1 - smoothstep(progress(t, 0.7, 1.0))),
            ringRadius: easeOutCubic(progress(t, 0.62, 1.0)),
            ringAlpha: progress(t, 0.62, 0.66) * (1 - progress(t, 0.66, 1.0)),
            rays: easeOutCubic(progress(t, 0.62, 1.0)),
            raysAlpha: smoothstep(progress(t, 0.62, 0.68)) * (1 - smoothstep(progress(t, 0.75, 1.0))),
            unroll: easeOutCubic(progress(t, 0.65, 1.0)),
            textReveal: progress(t, 0.72, 1.05),
            glint: smoothstep(progress(t, 1.0, 1.15)),
            glintAlpha: progress(t, 0.99, 1.02) * (1 - progress(t, 1.13, 1.16)),
            bannerAlpha: progress(t, 0.65, 0.68) * (1 - smoothstep(progress(t, 1.3, 1.5))),
            bannerRise: smoothstep(progress(t, 1.3, 1.5)),
            sparks: easeOutCubic(progress(t, 1.3, 1.5)),
            sparkAlpha: progress(t, 1.3, 1.34) * (1 - progress(t, 1.38, 1.5)))
    }

    /// 第 i 颗灵光：从哪条边（0 上 1 右 2 下 3 左）、在边上的位置（0…1）、旋向（±0.6 弧度，左右交替）、
    /// 出发延迟（0–0.15 秒）、大小（0.6…1，相对）、颜色序号（0/1/2 = 金、玉、青）。种子固定，每次都一样
    static func mote(_ i: Int, of count: Int) -> (edge: Int, along: Double, swirl: Double, delay: Double, size: Double, tone: Int) {
        let n = max(1, count)
        let edge = i % 4
        let slot = i / 4
        let perEdge = max(1, (n + 3 - edge) / 4)
        let along = min(1, max(0, (Double(slot) + 0.5 + (noise(i, 1) - 0.5) * 0.6) / Double(perEdge)))
        let sign: Double = (slot + edge) % 2 == 0 ? 1 : -1
        let swirl = sign * (0.3 + 0.3 * noise(i, 2))
        let delay = 0.15 * noise(i, 3)
        let size = 0.6 + 0.4 * noise(i, 4)
        return (edge, along, swirl, delay, size, i % 3)
    }

    /// 灵光整体的不透明度包络（ConsummationPose.moteAlpha）：开头 40 ms 亮起，600–660 ms 收尽
    static func moteEnvelope(at t: Double) -> Double {
        progress(t, 0, 0.04) * (1 - progress(t, 0.6, 0.66))
    }

    /// 第 i 颗灵光（出发延迟 delay）在 t 时刻走到全程的几成：先亮起，再沿弧线加速，650 ms 时一齐到达
    static func moteTravel(delay: Double, at t: Double) -> Double {
        let x = progress(t, delay, 0.65)
        return 0.25 * x + 0.75 * x * x * x
    }

    /// 第 i 颗灵光的不透明度：出发后 60 ms 亮起，最后一程（走过 88% 之后）淡去，到达即灭
    static func moteAlpha(delay: Double, at t: Double) -> Double {
        guard t >= delay else { return 0 }
        let travel = moteTravel(delay: delay, at: t)
        return progress(t, delay, delay + 0.06) * (1 - smoothstep(progress(travel, 0.88, 1)))
    }

    /// 二次贝塞尔：控制点 = 起点 + (终点 − 起点)/2 绕起点转 swirl（即弧线偏离直线 swirl 角）；swirl = 0 时是直线
    static func curve(from: (x: Double, y: Double), to: (x: Double, y: Double), swirl: Double, s: Double) -> (x: Double, y: Double) {
        let hx = (to.x - from.x) / 2, hy = (to.y - from.y) / 2
        let cx = from.x + hx * cos(swirl) - hy * sin(swirl)
        let cy = from.y + hx * sin(swirl) + hy * cos(swirl)
        let u = 1 - s
        return (u * u * from.x + 2 * u * s * cx + s * s * to.x, u * u * from.y + 2 * u * s * cy + s * s * to.y)
    }

    /// CA 关键帧的采样时刻（0…1，含两端，递增）
    static func keyTimes(samples: Int = 31) -> [Double] {
        let n = max(2, samples)
        return (0..<n).map { Double($0) / Double(n - 1) }
    }

    // MARK: 朱印（与 SwiftUI 版 SealStamp 同一套：Motion.ceremony 弹簧、0.16 秒起涟漪、0.85 秒起淡成印痕、2.2 秒起淡出）

    struct SealPose: Equatable {
        /// 弹簧落下的进度：0 = 2.2 倍、−16°，1 = 1 倍、−6°；会略过 1（约 145 ms 第一次落到 1 倍，再回弹一点）
        var landing: Double
        /// 印身不透明度（0…1，落定是 0.96，印痕是 0.32）
        var alpha: Double
        /// 朱砂阴影（0…1 → 不透明度 0.45、半径 12）
        var shadow: Double
        /// 涟漪：扩散进度（0…1 → 0.7…1.6 倍）与不透明度（0…1 → 0…0.7）
        var ripple, rippleAlpha: Double
    }

    static func seal(at time: Double) -> SealPose {
        let t = max(0, time)
        let landing = spring(t)
        let settle = smoothstep(progress(t, 0.85, 1.2))
        let fadeOut = easeOutCubic(progress(t, 2.2, 2.6))
        let landed = min(1, max(0, 0.96 * landing))
        let ripple = easeOutCubic(progress(t, 0.16, 0.96))
        return SealPose(landing: landing,
                        alpha: (landed + (0.32 - landed) * settle) * (1 - fadeOut),
                        shadow: min(1, max(0, landing)) * (1 - settle),
                        ripple: ripple,
                        rippleAlpha: (1 - ripple) * (1 - fadeOut))
    }

    /// 欠阻尼弹簧（与 SwiftUI 的 .spring(response: 0.32, dampingFraction: 0.62) 同一组参数：刚度约 385、阻尼约 24.3、质量 1），
    /// 从 0 出发、初速为 0，返回位移（会略过 1）
    static func spring(_ t: Double, response: Double = 0.32, dampingFraction: Double = 0.62) -> Double {
        guard t > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        let zeta = min(0.999, max(0.01, dampingFraction))
        let decay = zeta * omega
        let wd = omega * sqrt(1 - zeta * zeta)
        return 1 - exp(-decay * t) * (cos(wd * t) + decay / wd * sin(wd * t))
    }

    // MARK: 缓动

    static func clamp01(_ x: Double) -> Double { x.isNaN ? 0 : min(1, max(0, x)) }
    /// t 在 [start, end] 里走了几成（两端之外取 0 / 1）
    static func progress(_ t: Double, _ start: Double, _ end: Double) -> Double {
        end > start ? clamp01((t - start) / (end - start)) : (t >= end ? 1 : 0)
    }
    static func smoothstep(_ x: Double) -> Double { let u = clamp01(x); return u * u * (3 - 2 * u) }
    static func easeOutCubic(_ x: Double) -> Double { let u = clamp01(x); return 1 - pow(1 - u, 3) }
    static func easeInCubic(_ x: Double) -> Double { let u = clamp01(x); return u * u * u }
    static func easeInQuad(_ x: Double) -> Double { let u = clamp01(x); return u * u }
    static func easeInOutSine(_ x: Double) -> Double { let u = clamp01(x); return (1 - cos(u * .pi)) / 2 }

    /// 固定种子的 0…1 噪声（splitmix64）
    static func noise(_ i: Int, _ salt: Int) -> Double {
        var z = UInt64(bitPattern: Int64(i &* 7919 &+ salt &* 104_729)) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

enum RitualRules {
    /// 这次打卡该不该播“功课圆满”：只看今天；由未圆满变为圆满；今天还没播过
    static func shouldCelebratePerfectDay(day: LocalDay, today: LocalDay, wasPerfect: Bool, isPerfect: Bool,
                                          celebrated: LocalDay?) -> Bool {
        day == today && !wasPerfect && isPerfect && celebrated != day
    }

    /// 纸笺上显示的正文：去掉首尾空白；连续多个换行（含其间的空格、制表符）并成一个换行；
    /// 最多 limit 个字符（Character 计），超出截到 limit 再加“…”
    static func inscriptionPreview(_ body: String, limit: Int = 240) -> String {
        var text = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "\n(?:[ \\t]*\n)+", with: "\n", options: .regularExpression)
        guard limit >= 0, text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
