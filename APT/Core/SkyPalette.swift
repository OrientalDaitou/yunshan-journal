import Foundation

// 天色调色表：四时 × 浅 / 深各一套，按 SkyMix 的权重混合。全是数字（sRGB 0…1），
// 到了 Theme 层（SkyLayers.swift）再变成 Color / CGColor。昼这一档全是零：白天与原来逐像素一样。

/// 一个 sRGB 颜色（不预乘，a 是不透明度）
struct SkyRGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double

    static let clear = SkyRGBA(r: 0, g: 0, b: 0, a: 0)
    static let white = SkyRGBA(r: 1, g: 1, b: 1, a: 1)

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(hex: UInt32, a: Double) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255, a: a)
    }

    /// 预乘空间插值：结果的 a 线性变化，rgb 按各自的 a 加权；与全透明混合时 rgb 不变、只有 a 变小
    /// （直接插 rgb 的话，“无”是黑色，过渡途中罩色和远山都会被往黑里拽）
    func mixed(with other: SkyRGBA, _ t: Double) -> SkyRGBA {
        Self.blend([(self, 1 - t), (other, t)])
    }

    /// 多个颜色按权重在预乘空间混合（权重和应为 1）。全都透明时 rgb 取按权重的平均，a 为 0
    static func blend(_ items: [(color: SkyRGBA, weight: Double)]) -> SkyRGBA {
        let a = items.reduce(0) { $0 + $1.weight * $1.color.a }
        guard a > 1e-12 else {
            let total = max(1e-12, items.reduce(0) { $0 + $1.weight })
            return SkyRGBA(r: items.reduce(0) { $0 + $1.weight * $1.color.r } / total,
                           g: items.reduce(0) { $0 + $1.weight * $1.color.g } / total,
                           b: items.reduce(0) { $0 + $1.weight * $1.color.b } / total, a: 0)
        }
        func channel(_ key: KeyPath<SkyRGBA, Double>) -> Double {
            items.reduce(0) { $0 + $1.weight * $1.color.a * $1.color[keyPath: key] } / a
        }
        return SkyRGBA(r: channel(\.r), g: channel(\.g), b: channel(\.b), a: a)
    }

    /// 同色、换一个不透明度
    func with(a: Double) -> SkyRGBA { SkyRGBA(r: r, g: g, b: b, a: a) }

    /// 把 self 叠在 base 上（source-over，base 不透明）之后的颜色
    func over(_ base: SkyRGBA) -> SkyRGBA {
        SkyRGBA(r: r * a + base.r * (1 - a), g: g * a + base.g * (1 - a), b: b * a + base.b * (1 - a), a: 1)
    }

    /// rgb 往 tint 的 rgb 靠，比例取 tint.a；自身的 a 不变（远山墨色、日晕换色用）
    func tinted(toward tint: SkyRGBA) -> SkyRGBA {
        let t = min(1, max(0, tint.a))
        return SkyRGBA(r: r + (tint.r - r) * t, g: g + (tint.g - g) * t, b: b + (tint.b - b) * t, a: a)
    }
}

/// 某一时刻的天色：页面底各层的颜色与系数、横幅画作的调色
struct SkyLook: Equatable {
    // —— 页面底（PaperBackground）——
    /// 整页罩一层色
    var veil: SkyRGBA
    /// 顶部天光带：顶端颜色
    var horizonTop: SkyRGBA
    /// 天光带中段（约 35% 高处），到 70% 高处归零
    var horizonMid: SkyRGBA
    /// 霞光带：贴远山山脊那一段
    var xiaLow: SkyRGBA
    /// 霞光带：往上那一段
    var xiaHigh: SkyRGBA
    /// 天光：朝阳 / 夕照 / 月华
    var glow: SkyRGBA
    /// 天光位置（相对坐标）与直径（pt）
    var glowX: Double, glowY: Double, glowSize: Double
    /// 霞云不透明度系数
    var xiaClouds: Double
    /// 霞云左右两端的颜色（横向渐变，近日的一侧更暖；只取 rgb，透明度由 xiaClouds 定）：
    /// 晨是杏色（朝阳在左），暮是绯红到金橙（夕照在右）
    var xiaCloudLeft: SkyRGBA
    var xiaCloudRight: SkyRGBA
    /// 星点
    var stars: Double
    /// 星河
    var galaxy: Double
    /// 山脚晨雾
    var fog: Double
    /// 远山墨色往这个颜色靠，a = 混入比例（0 = 原色）
    var ridgeInk: SkyRGBA
    /// 现有流云日晕的颜色往这个颜色靠，a = 混入比例（0 = 原色）；只改色相，透明度不变
    var sunTint: SkyRGBA
    /// 暗角颜色（昼 = 原来的值）
    var vignette: SkyRGBA
    /// 浅色也放流星（夜的权重 ≥ 0.5）
    var meteors: Bool
    // —— 横幅画作 ——
    /// 乘色（a 恒为 1：colorMultiply 连透明度一起乘，a < 1 会把画作晕边变淡；昼 = 纯白，等于不变）
    var heroMultiply: SkyRGBA
    /// 画面右上角往左下渐隐的一层光，按画作自身的透明度遮罩
    var heroGlow: SkyRGBA
    /// 画面下部再加的薄雾
    var heroFog: Double

    /// 四时预设（数值见设计稿 P3 §2.3；渲染比对后微调过的地方在旁边注明）
    static func preset(_ phase: SkyPhase, dark: Bool) -> SkyLook {
        dark ? darkPreset(phase) : lightPreset(phase)
    }

    /// 四套按权重混合（颜色在预乘空间）；meteors = night ≥ 0.5。纯时刻直接返回预设
    static func look(_ mix: SkyMix, dark: Bool) -> SkyLook {
        let parts = SkyPhase.allCases.compactMap { phase -> (look: SkyLook, weight: Double)? in
            let w = min(1, max(0, mix[phase]))
            return w > 0 ? (preset(phase, dark: dark), w) : nil
        }
        guard let first = parts.first else { return preset(.day, dark: dark) }
        if parts.count == 1 { return first.look }
        let total = parts.reduce(0) { $0 + $1.weight }
        let weighted = parts.map { ($0.look, $0.weight / total) }
        func color(_ key: KeyPath<SkyLook, SkyRGBA>) -> SkyRGBA {
            SkyRGBA.blend(weighted.map { ($0.0[keyPath: key], $0.1) })
        }
        func scalar(_ key: KeyPath<SkyLook, Double>) -> Double {
            weighted.reduce(0) { $0 + $1.1 * $1.0[keyPath: key] }
        }
        // 天光的位置与大小按“看得见的程度”（权重 × 透明度）加权：昼→暮时夕照就在原地淡入，不会从别处滑过来
        let glowWeights = weighted.map { $0.1 * $0.0.glow.a }
        let glowTotal = glowWeights.reduce(0, +)
        func glowScalar(_ key: KeyPath<SkyLook, Double>) -> Double {
            guard glowTotal > 1e-12 else { return scalar(key) }
            return zip(weighted, glowWeights).reduce(0) { $0 + $1.1 * $1.0.0[keyPath: key] } / glowTotal
        }
        var heroMultiply = color(\.heroMultiply)
        heroMultiply.a = 1
        return SkyLook(veil: color(\.veil), horizonTop: color(\.horizonTop), horizonMid: color(\.horizonMid),
                       xiaLow: color(\.xiaLow), xiaHigh: color(\.xiaHigh), glow: color(\.glow),
                       glowX: glowScalar(\.glowX), glowY: glowScalar(\.glowY), glowSize: glowScalar(\.glowSize),
                       xiaClouds: scalar(\.xiaClouds), xiaCloudLeft: color(\.xiaCloudLeft), xiaCloudRight: color(\.xiaCloudRight),
                       stars: scalar(\.stars), galaxy: scalar(\.galaxy), fog: scalar(\.fog),
                       ridgeInk: color(\.ridgeInk), sunTint: color(\.sunTint), vignette: color(\.vignette),
                       meteors: mix.night >= 0.5,
                       heroMultiply: heroMultiply, heroGlow: color(\.heroGlow), heroFog: scalar(\.heroFog))
    }

    // MARK: 预设

    private static func hex(_ value: UInt32, _ a: Double) -> SkyRGBA { SkyRGBA(hex: value, a: a) }

    /// 昼：什么都不加（暗角是原来的值）
    private static func noon(vignette: SkyRGBA) -> SkyLook {
        SkyLook(veil: .clear, horizonTop: .clear, horizonMid: .clear, xiaLow: .clear, xiaHigh: .clear,
                glow: .clear, glowX: 0.5, glowY: 0.1, glowSize: 700,
                xiaClouds: 0, xiaCloudLeft: .clear, xiaCloudRight: .clear, stars: 0, galaxy: 0, fog: 0,
                ridgeInk: .clear, sunTint: .clear, vignette: vignette, meteors: false,
                heroMultiply: .white, heroGlow: .clear, heroFog: 0)
    }

    /// 浅色（晨光）
    private static func lightPreset(_ phase: SkyPhase) -> SkyLook {
        switch phase {
        case .dawn:
            SkyLook(veil: hex(0xFAE6CC, 0.10), horizonTop: hex(0xF7CCA8, 0.28), horizonMid: hex(0xFCEBD1, 0.12),
                    xiaLow: hex(0xFAC79E, 0.18), xiaHigh: hex(0xFCE3C2, 0.10),
                    glow: hex(0xFFD19E, 0.30), glowX: 0.28, glowY: 0.08, glowSize: 720,
                    xiaClouds: 0.45, xiaCloudLeft: hex(0xFAD9B8, 1), xiaCloudRight: hex(0xFCEBD6, 1),
                    stars: 0, galaxy: 0, fog: 0.85,
                    ridgeInk: hex(0x73858F, 0.35), sunTint: .clear, vignette: hex(0xE0D6C7, 0.30), meteors: false,
                    heroMultiply: hex(0xFFF5E6, 1), heroGlow: hex(0xFFD9A6, 0.16), heroFog: 0.6)
        case .day:
            noon(vignette: SkyRGBA(r: 0.84, g: 0.86, b: 0.79, a: 0.35))
        case .dusk:
            // 霞光带比设计稿的 .30 / .20 收了一些：修行录时间线的日期行常落在这一带，
            // 最浓处的纸面也要守住亮度 0.78（inkSoft 小字约 4:1）
            SkyLook(veil: hex(0xF7D6B8, 0.14), horizonTop: hex(0xCC8C9E, 0.22), horizonMid: hex(0xF5B373, 0.20),
                    xiaLow: hex(0xF7A85E, 0.18), xiaHigh: hex(0xE07A6A, 0.10),
                    glow: hex(0xFA9E5C, 0.34), glowX: 0.80, glowY: 0.16, glowSize: 820,
                    xiaClouds: 0.85, xiaCloudLeft: hex(0xE07A6A, 1), xiaCloudRight: hex(0xF7A85E, 1),
                    stars: 0.08, galaxy: 0, fog: 0.15,
                    ridgeInk: hex(0x5C424D, 0.45), sunTint: .clear, vignette: hex(0xCCB3A8, 0.35), meteors: false,
                    heroMultiply: hex(0xFFE0C7, 1), heroGlow: hex(0xFF9E61, 0.22), heroFog: 0.1)
        case .night:
            // 纸面约 #E1E6E8（亮度 0.785）：inkSoft 小字约 4:1，veil 与暗角都不能再加深
            SkyLook(veil: hex(0x809ED1, 0.15), horizonTop: hex(0x4D669E, 0.16), horizonMid: hex(0x8CA6D1, 0.06),
                    xiaLow: .clear, xiaHigh: .clear,
                    glow: hex(0xDBE6FF, 0.30), glowX: 0.86, glowY: 0.05, glowSize: 600,
                    xiaClouds: 0, xiaCloudLeft: .clear, xiaCloudRight: .clear,
                    stars: 1, galaxy: 0.8, fog: 0.25,
                    ridgeInk: hex(0x384D75, 0.50), sunTint: hex(0xDBE6FF, 1), vignette: hex(0x9EADCC, 0.28), meteors: true,
                    heroMultiply: hex(0xD6E3FF, 1), heroGlow: hex(0xCCDBFF, 0.10), heroFog: 0.2)
        }
    }

    /// 深色（月色）
    private static func darkPreset(_ phase: SkyPhase) -> SkyLook {
        switch phase {
        case .dawn:
            SkyLook(veil: .clear, horizonTop: hex(0x384D52, 0.20), horizonMid: hex(0x73664D, 0.10),
                    xiaLow: hex(0x8C6B4D, 0.14), xiaHigh: hex(0x4D5C5C, 0.08),
                    glow: hex(0xCCA87A, 0.12), glowX: 0.28, glowY: 0.08, glowSize: 720,
                    xiaClouds: 0.2, xiaCloudLeft: hex(0xFAD9B8, 1), xiaCloudRight: hex(0xFCEBD6, 1),
                    stars: 0.25, galaxy: 0, fog: 0.30,
                    ridgeInk: hex(0x809EA8, 0.25), sunTint: .clear, vignette: hex(0x000000, 0.45), meteors: false,
                    heroMultiply: hex(0xFFF7ED, 1), heroGlow: hex(0xF2C78C, 0.10), heroFog: 0.3)
        case .day:
            noon(vignette: hex(0x000000, 0.50))
        case .dusk:
            SkyLook(veil: hex(0x331A1F, 0.10), horizonTop: hex(0x40294A, 0.18), horizonMid: hex(0x734233, 0.14),
                    xiaLow: hex(0xB3733D, 0.18), xiaHigh: hex(0x8C3D3D, 0.16),
                    glow: hex(0xD9804F, 0.14), glowX: 0.80, glowY: 0.16, glowSize: 820,
                    xiaClouds: 0.35, xiaCloudLeft: hex(0x8C3D3D, 1), xiaCloudRight: hex(0xB3733D, 1),
                    stars: 0.2, galaxy: 0, fog: 0.10,
                    ridgeInk: hex(0x8C7385, 0.35), sunTint: .clear, vignette: hex(0x0A050A, 0.55), meteors: false,
                    heroMultiply: hex(0xFFE6D6, 1), heroGlow: hex(0xF2945F, 0.14), heroFog: 0.1)
        case .night:
            SkyLook(veil: hex(0x0F1A3D, 0.35), horizonTop: hex(0x1A2452, 0.25), horizonMid: .clear,
                    xiaLow: .clear, xiaHigh: .clear,
                    glow: hex(0xBFD1F2, 0.10), glowX: 0.86, glowY: 0.05, glowSize: 600,
                    xiaClouds: 0, xiaCloudLeft: .clear, xiaCloudRight: .clear,
                    stars: 1, galaxy: 1, fog: 0.12,
                    ridgeInk: hex(0x7A94C7, 0.35), sunTint: hex(0xBFD1F2, 0.5), vignette: hex(0x000000, 0.55), meteors: true,
                    heroMultiply: hex(0xEBF2FF, 1), heroGlow: hex(0xB3CCFF, 0.06), heroFog: 0.15)
        }
    }
}

/// 页面纸色与亮度：CoreCheck 用它验“浅色夜不黑、深色昼不亮”
enum SkyPaper {
    /// 与 Theme.paper 一致
    static let lightBase = SkyRGBA(hex: 0xF2F3EC, a: 1)
    static let darkBase = SkyRGBA(hex: 0x0E191B, a: 1)

    /// 纸色叠上 veil（atTop 时再叠天光带顶端）之后的实际颜色
    static func effectivePaper(_ look: SkyLook, dark: Bool, atTop: Bool) -> SkyRGBA {
        let paper = look.veil.over(dark ? darkBase : lightBase)
        return atTop ? look.horizonTop.over(paper) : paper
    }

    /// 页面下部霞光带上的纸色（纸 + 罩色，再叠霞光带的上段 / 贴山脊那段）：霞光不能把直接写在页面上的小字压暗
    static func xiaPapers(_ look: SkyLook, dark: Bool) -> [SkyRGBA] {
        let paper = effectivePaper(look, dark: dark, atTop: false)
        return [paper, look.xiaHigh.over(paper), look.xiaLow.over(paper)]
    }

    /// WCAG 相对亮度
    static func luminance(_ c: SkyRGBA) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// WCAG 对比度（两色的相对亮度，较亮者在分子）
    static func contrast(_ a: SkyRGBA, _ b: SkyRGBA) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

/// 星点位置：固定种子（splitmix64），每次启动、每次截图都一样
enum SkyStarField {
    struct Star: Equatable {
        /// x ∈ [0,1]；y ∈ [0,0.62]，越靠上越密（y = r^1.6 × 0.62）
        var x: Double, y: Double
        /// 1.2–3.2pt，约 3% 是 4–5pt 的亮星（带十字芒）
        var size: Double
        /// 0.4–1
        var brightness: Double
        /// 约 20% 会明灭
        var twinkles: Bool
        /// 明灭周期 2.6–6.4 秒
        var period: Double
        /// 起点相位 0–1
        var phase: Double
        /// 0/1/2，对应三种星色
        var tone: Int

        /// 4pt 以上的亮星带十字芒
        var isBright: Bool { size >= 4 }
    }

    static func stars(count: Int = 180, seed: UInt64 = 0x5EED_57A2) -> [Star] {
        var state = seed
        func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
        return (0..<max(0, count)).map { index in
            let x = next(), y = pow(next(), 1.6) * 0.62
            // 亮星按序号取（每 32 颗一颗，约 3%）：数量稳定，不随种子忽多忽少；位置仍是随机的
            let bright = index % 32 == 13
            let size = bright ? 4 + next() : 1.2 + next() * 2
            let brightness = bright ? 0.85 + next() * 0.15 : 0.4 + next() * 0.6
            let twinkles = next() < 0.22
            let period = 2.6 + next() * 3.8
            let phase = next()
            let tone = min(2, Int(next() * 3))
            return Star(x: x, y: y, size: size, brightness: brightness, twinkles: twinkles, period: period, phase: phase, tone: tone)
        }
    }

    /// 三种星色：深色是白 / 淡金 / 淡青；浅色是墨蓝 / 淡金 / 青灰
    static func tones(dark: Bool) -> [SkyRGBA] {
        dark ? [SkyRGBA.white, SkyRGBA(hex: 0xF2E2B8, a: 1), SkyRGBA(hex: 0xCFE6F2, a: 1)]
             : [SkyRGBA(hex: 0x3D5280, a: 1), SkyRGBA(hex: 0x9E8047, a: 1), SkyRGBA(hex: 0x5C7A8A, a: 1)]
    }

    /// 星河的颜色：深色青白，浅色墨蓝
    static func galaxyTone(dark: Bool) -> SkyRGBA {
        dark ? SkyRGBA(r: 0.80, g: 0.86, b: 1.0, a: 1) : SkyRGBA(r: 0.32, g: 0.42, b: 0.62, a: 1)
    }
}
