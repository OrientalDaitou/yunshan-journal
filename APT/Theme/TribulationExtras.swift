import SwiftUI

// 渡劫升境的打磨（在原有的黑幕、天雷三落、金光通天、光环、灵气四溅、境界名由虚化实之上再加，时间轴不改）：
// 劫云压顶、雷从云里劈出、云底被雷照亮、雷落之处的冲击光与火花、光柱里灵气上涌、八卦符环、功成后金雨徐落。
// 全是静态函数，用 GraphicsContext 画；TribulationScene 只加几行调用。不新增任何全屏闪光，光敏安全不变。

enum TribulationExtras {
    /// 劫云的颜色：云心近黑的紫灰，云边略亮
    private static let cloudCore = Color(red: 0.10, green: 0.09, blue: 0.14)
    private static let cloudEdge = Color(red: 0.38, green: 0.36, blue: 0.50)
    private static let cloudMid = Color(red: 0.2, green: 0.18, blue: 0.27)
    private static let gold = Color(red: 1, green: 0.84, blue: 0.5)

    /// 第 i 团劫云：中心（相对坐标，压到顶部 0–18% 高的位置）与大小（相对窗口宽）
    private static func cloud(_ i: Int) -> (x: Double, y: Double, width: Double) {
        let x = (Double(i) + 0.5) / 7 + (spiritNoise(i, 120) - 0.5) * 0.06
        let y = 0.03 + 0.11 * spiritNoise(i, 121)
        let width = 0.26 + 0.1 * spiritNoise(i, 122)
        return (x, y, width)
    }

    /// 劫云这一刻的中心：0–0.35 秒从窗口上沿外压下来；1.05 秒金光一起，向两侧推开（± 0.3w）并在 1.8 秒前淡尽
    private static func cloudCenter(_ i: Int, size: CGSize, e: Double) -> CGPoint {
        let c = cloud(i)
        let fall = 1 - pow(1 - min(1, max(0, e / 0.35)), 3)
        let push = smooth((e - 1.05) / 0.75)
        let side: Double = c.x < 0.5 ? -1 : 1
        let restY = c.y * size.height
        let y = -size.height * 0.2 + (restY + size.height * 0.2) * fall
        let x = c.x * size.width + side * 0.3 * size.width * push * (0.6 + 0.8 * abs(c.x - 0.5))
        return CGPoint(x: x, y: y)
    }

    private static func smooth(_ x: Double) -> Double {
        let u = min(1, max(0, x))
        return u * u * (3 - 2 * u)
    }

    /// 劫云压顶：7 团乌云、每团 5 个椭圆径向渐变（共 35 次填充），慢慢打旋（±4°）。画在黑幕之上、天雷之下。
    /// 第 2、3 道雷时，雷出处的云底被局部照亮（径向光 α ≤ 0.12、半径 160、0.18 秒）
    static func drawClouds(_ gc: inout GraphicsContext, size: CGSize, e: Double, strikes: [Double]) {
        let fade = 1 - smooth((e - 1.05) / 0.75)
        guard fade > 0 else { return }
        for i in 0..<7 {
            let c = cloud(i)
            let center = cloudCenter(i, size: size, e: e)
            let width = c.width * size.width, height = width * 0.42
            let swirl = 4 * Double.pi / 180 * sin(e * 0.9 + Double(i) * 1.7)
            var cloudContext = gc
            cloudContext.translateBy(x: center.x, y: center.y)
            cloudContext.rotate(by: .radians(swirl))
            cloudContext.opacity = fade
            for k in 0..<5 {
                let dx = (Double(k) - 2) * 0.2 * width + (spiritNoise(i * 5 + k, 123) - 0.5) * 0.12 * width
                let dy = (spiritNoise(i * 5 + k, 124) - 0.5) * 0.35 * height - (k == 2 ? height * 0.12 : 0)
                let r = (0.32 + 0.16 * spiritNoise(i * 5 + k, 125)) * width
                var lump = cloudContext
                lump.translateBy(x: dx, y: dy)
                lump.scaleBy(x: 1, y: 0.55)
                // 云心浓、往外渐淡，边上透一点亮紫（不画成一圈亮边：几团叠在一起会像一道道水纹）
                lump.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)),
                          with: .radialGradient(Gradient(stops: [.init(color: cloudCore.opacity(0.8), location: 0),
                                                                 .init(color: cloudCore.opacity(0.66), location: 0.38),
                                                                 .init(color: cloudMid.opacity(0.38), location: 0.66),
                                                                 .init(color: cloudEdge.opacity(0.1), location: 0.86),
                                                                 .init(color: cloudEdge.opacity(0), location: 1)]),
                                                center: .zero, startRadius: 0, endRadius: r))
            }
        }
        // 第 2、3 道雷：雷出处的云底局部亮起
        for (index, strike) in strikes.enumerated() where index > 0 {
            let d = e - strike
            guard d >= 0, d < 0.18 else { continue }
            let a = 0.12 * (1 - d / 0.18) * fade
            let anchor = cloudAnchor(index: index, size: size)
            gc.fill(Path(ellipseIn: CGRect(x: anchor.x - 160, y: anchor.y - 160, width: 320, height: 320)),
                    with: .radialGradient(Gradient(colors: [Color(red: 0.78, green: 0.86, blue: 1).opacity(a), .clear]),
                                          center: anchor, startRadius: 0, endRadius: 160))
        }
    }

    /// 第 index 道天雷的起点：离它原本落点最近的那团劫云的云底（压到位后的位置）
    static func cloudAnchor(index: Int, size: CGSize) -> CGPoint {
        let x = size.width * (0.25 + spiritNoise(index, 50) * 0.5)
        let nearest = (0..<7).min { abs(cloud($0).x * size.width - x) < abs(cloud($1).x * size.width - x) } ?? 3
        let c = cloud(nearest)
        let width = c.width * size.width
        return CGPoint(x: c.x * size.width + (x - c.x * size.width) * 0.3, y: c.y * size.height + width * 0.42 * 0.3)
    }

    /// 雷落之处（每道雷 +0.05 秒）：一圈青白冲击光（半径 30 → 120，α 0.5 → 0，0.3 秒）+ 6 点火花外溅
    static func drawImpacts(_ gc: inout GraphicsContext, e: Double, strikes: [Double], target: CGPoint) {
        for (index, strike) in strikes.enumerated() {
            let d = e - strike - 0.05
            guard d >= 0, d < 0.3 else { continue }
            let f = d / 0.3
            let eased = 1 - pow(1 - f, 3)
            let r = 30 + 90 * eased
            let a = 0.5 * (1 - f)
            gc.fill(Path(ellipseIn: CGRect(x: target.x - r, y: target.y - r * 0.6, width: r * 2, height: r * 1.2)),
                    with: .radialGradient(Gradient(colors: [Color(red: 0.8, green: 0.92, blue: 1).opacity(a * 0.5), .clear]),
                                          center: target, startRadius: 0, endRadius: r))
            gc.stroke(Path(ellipseIn: CGRect(x: target.x - r, y: target.y - r * 0.6, width: r * 2, height: r * 1.2)),
                      with: .color(Color(red: 0.85, green: 0.95, blue: 1).opacity(a)), lineWidth: 2.2 * (1 - f) + 0.6)
            for k in 0..<6 {
                let angle = spiritNoise(index * 6 + k, 130) * 2 * .pi
                let travel = (40 + 70 * spiritNoise(index * 6 + k, 131)) * eased
                let p = CGPoint(x: target.x + cos(angle) * travel, y: target.y + sin(angle) * travel * 0.7 + 40 * f * f)
                let s = 2.2 * (1 - f) + 0.6
                gc.fill(Path(ellipseIn: CGRect(x: p.x - s * 3, y: p.y - s * 3, width: s * 6, height: s * 6)),
                        with: .radialGradient(Gradient(colors: [Color(red: 0.85, green: 0.95, blue: 1).opacity(0.55 * (1 - f)), .clear]),
                                              center: p, startRadius: 0, endRadius: s * 3))
                gc.fill(Path(ellipseIn: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)), with: .color(.white.opacity(1 - f)))
            }
        }
    }

    /// 光柱内灵气上涌（1.05 秒起）：36 点金色灵气在光柱宽度内由下往上快速升起（每秒 300–600pt，循环），亮度跟着光柱走
    static func drawPillarMotes(_ gc: inout GraphicsContext, size: CGSize, e: Double, center: CGPoint, width: Double, strength: Double) {
        guard e > 1.05, width > 4, strength > 0 else { return }
        let span = size.height + 60
        for i in 0..<36 {
            let speed = 300 + 300 * spiritNoise(i, 140)
            let offset = spiritNoise(i, 141) * span
            let y = size.height + 30 - ((e - 1.05) * speed + offset).truncatingRemainder(dividingBy: span)
            let x = center.x + (spiritNoise(i, 142) - 0.5) * width * 0.8 + sin(e * 3 + Double(i)) * 3
            let r = 1.4 + 2 * spiritNoise(i, 143)
            let a = strength * (0.55 + 0.45 * spiritNoise(i, 144))
            gc.fill(Path(ellipseIn: CGRect(x: x - r * 4, y: y - r * 4, width: r * 8, height: r * 8)),
                    with: .radialGradient(Gradient(colors: [gold.opacity(a * 0.45), .clear]), center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r * 4))
            // 上升带出的短尾
            var trail = Path()
            trail.move(to: CGPoint(x: x, y: y))
            trail.addLine(to: CGPoint(x: x, y: y + r * 7))
            gc.stroke(trail, with: .linearGradient(Gradient(colors: [Color.white.opacity(a * 0.8), .clear]),
                                                   startPoint: CGPoint(x: x, y: y), endPoint: CGPoint(x: x, y: y + r * 7)),
                      style: StrokeStyle(lineWidth: r * 0.9, lineCap: .round))
            gc.fill(Path(ellipseIn: CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r)), with: .color(Color.white.opacity(a)))
        }
    }

    /// 金雨徐落（2.4 秒起，祥瑞余韵）：28 片小金屑从顶上缓缓飘落（每秒 40–90pt，左右正弦轻摆），α 0.5，0.6 秒淡入
    static func drawBlessingRain(_ gc: inout GraphicsContext, size: CGSize, e: Double) {
        let d = e - 2.4
        guard d > 0 else { return }
        let fadeIn = min(1, d / 0.6)
        for i in 0..<28 {
            let speed = 40 + 50 * spiritNoise(i, 150)
            // 起点散在上半屏（随淡入现出），再缓缓往下飘
            let y = -20 + spiritNoise(i, 151) * size.height * 0.5 + d * speed
            guard y > -20, y < size.height + 20 else { continue }
            let x = spiritNoise(i, 152) * size.width + sin(d * (0.9 + spiritNoise(i, 153)) + Double(i)) * 14
            let r = 2 + 2 * spiritNoise(i, 154)
            let a = 0.5 * fadeIn
            var flake = gc
            flake.translateBy(x: x, y: y)
            flake.rotate(by: .radians(d * (1 + spiritNoise(i, 155)) + Double(i)))
            flake.fill(Path(ellipseIn: CGRect(x: -r * 4, y: -r * 4, width: r * 8, height: r * 8)),
                       with: .radialGradient(Gradient(colors: [gold.opacity(a * 0.5), .clear]), center: .zero, startRadius: 0, endRadius: r * 4))
            // 金屑：一片细长的菱形，转着落
            var shard = Path()
            shard.move(to: CGPoint(x: 0, y: -r * 1.6))
            shard.addLine(to: CGPoint(x: r * 0.6, y: 0))
            shard.addLine(to: CGPoint(x: 0, y: r * 1.6))
            shard.addLine(to: CGPoint(x: -r * 0.6, y: 0))
            shard.closeSubpath()
            flake.fill(shard, with: .color(Color(red: 1, green: 0.9, blue: 0.62).opacity(min(1, a * 1.8))))
        }
    }
}

/// 八卦符环：托在新境界徽记背后的两圈金线圆（半径 150 α 0.55、122 α 0.35），中间 24 道刻度，
/// 先天八卦（乾兑离震巽坎艮坤）均布在半径 136 上。外圈（连八卦）顺时针每秒 10°，内圈（连刻度）逆时针每秒 6°；
/// 下缘渐隐：徽记下面紧挨着“渡劫功成”和境界名，整圈画全会从字上穿过，现在只像一道托在徽记上方的光环。320 × 320
struct RuneRing: View {
    /// 0…1：随标题一起由虚化实（整体 α = 0.7 × progress）
    var progress: Double
    /// 秒：转动用；静态卡传 0
    var elapsed: Double

    /// 先天八卦，三爻自下而上（1 阳 0 阴）
    static let trigrams: [[Int]] = [[1, 1, 1], [1, 1, 0], [1, 0, 1], [1, 0, 0], [0, 1, 1], [0, 1, 0], [0, 0, 1], [0, 0, 0]]

    var body: some View {
        Canvas { gc, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let gold = Color(red: 1, green: 0.84, blue: 0.5)
            var outer = gc
            outer.translateBy(x: c.x, y: c.y)
            outer.rotate(by: .degrees(elapsed * 10))
            outer.stroke(Path(ellipseIn: CGRect(x: -150, y: -150, width: 300, height: 300)), with: .color(gold.opacity(0.55)), lineWidth: 1.2)
            for (k, lines) in Self.trigrams.enumerated() {
                var mark = outer
                mark.rotate(by: .degrees(Double(k) * 45))
                // 朝外的一卦：爻与半径垂直，最下一爻离中心最近
                for (j, yang) in lines.enumerated() {
                    let r = 131 + CGFloat(j) * 5
                    if yang == 1 {
                        mark.fill(Path(CGRect(x: -7, y: -r - 1, width: 14, height: 2)), with: .color(gold.opacity(0.9)))
                    } else {
                        mark.fill(Path(CGRect(x: -7, y: -r - 1, width: 5.5, height: 2)), with: .color(gold.opacity(0.9)))
                        mark.fill(Path(CGRect(x: 1.5, y: -r - 1, width: 5.5, height: 2)), with: .color(gold.opacity(0.9)))
                    }
                }
            }
            var inner = gc
            inner.translateBy(x: c.x, y: c.y)
            inner.rotate(by: .degrees(-elapsed * 6))
            inner.stroke(Path(ellipseIn: CGRect(x: -122, y: -122, width: 244, height: 244)), with: .color(gold.opacity(0.35)), lineWidth: 1)
            for k in 0..<24 {
                var tick = inner
                tick.rotate(by: .degrees(Double(k) * 15 + 7.5))
                let long = k % 3 == 1
                tick.fill(Path(CGRect(x: -0.6, y: -128 - (long ? 3 : 0), width: 1.2, height: long ? 8 : 5)), with: .color(gold.opacity(0.6)))
            }
        }
        .frame(width: 320, height: 320)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55), .init(color: .clear, location: 0.75)],
                             startPoint: .top, endPoint: .bottom))
        .opacity(0.7 * min(1, max(0, progress)))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
