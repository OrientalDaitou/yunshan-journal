import SwiftUI

// 灵气与氛围特效：粒子灵气、流云、远山、卡片灵纹、标题掠光、切页时新页面由虚化实。
// 落印、飞剑传书、渡劫这几样仪式特效在 Overlays.swift；天色随时辰（星、霞云、晨雾）在 SkyLayers.swift。
// 所有动画都受 `spiritMotion` 控制：设置里关闭动效或系统“减少动态效果”时全部静止。

private struct SpiritMotionKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var spiritMotion: Bool {
        get { self[SpiritMotionKey.self] }
        set { self[SpiritMotionKey.self] = newValue }
    }
}

/// 稳定的伪随机数（0..<1），保证每颗灵气粒子轨迹固定、跨帧连续。
@inline(__always)
func spiritNoise(_ index: Int, _ salt: Int) -> Double {
    var x = UInt64(truncatingIfNeeded: index &* 0x9E3779B1 ^ salt &* 0x85EBCA77) &+ 0x632BE59BD9B4E019
    x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
    x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
    x ^= x >> 31
    return Double(x % 1_000_000) / 1_000_000
}

/// 灵气光点的三种颜色（sRGB）：深色是月下的金、玉、青，浅色是宣纸上的赭金、松绿、暖金。
/// 粒子层（NSColor）与渡劫的灵气四溅（SwiftUI Color）都从这一份取，调色只改这里。
enum SpiritPalette {
    private static func rgb(dark: Bool) -> [(r: Double, g: Double, b: Double)] {
        dark
            ? [(0.93, 0.82, 0.56), (0.66, 0.90, 0.78), (0.72, 0.84, 0.98)]
            : [(0.72, 0.55, 0.27), (0.29, 0.55, 0.43), (0.85, 0.66, 0.36)]
    }

    static func motes(dark: Bool) -> [Color] {
        rgb(dark: dark).map { Color(red: $0.r, green: $0.g, blue: $0.b) }
    }

    static func moteColors(dark: Bool) -> [NSColor] {
        rgb(dark: dark).map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
    }
}

/// 流云的雾色与朝阳 / 月华的光晕色（sRGB 分量）：截图用的静态雾（SwiftUI）与动态流云（Core Animation）共用这一份，
/// 调色时两边一起变，截图与实际不会对不上。
struct MistPalette {
    typealias RGBA = (r: Double, g: Double, b: Double, a: Double)
    /// 雾：浅色是宣纸上的白雾，深色是月下极淡的薄云
    var mist: RGBA
    /// 日晕 / 月华
    var glow: RGBA
    /// 第三团玉色薄雾（只有动态流云用）
    var jade: RGBA

    init(dark: Bool) {
        mist = dark ? (0.85, 0.85, 0.85, 0.05) : (1, 1, 1, 0.55)
        glow = dark ? (0.82, 0.71, 0.51, 0.10) : (1, 0.86, 0.6, 0.22)
        jade = dark ? (0.64, 0.77, 0.68, 0.06) : (0.26, 0.46, 0.38, 0.07)
    }

    static func color(_ c: RGBA) -> Color { Color(red: c.r, green: c.g, blue: c.b, opacity: c.a) }
    static func nsColor(_ c: RGBA) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }

    /// 颜色往 tint 靠（比例取 tint.a），透明度不变：天色入夜时把暖色日晕转成月白（SkyLook.sunTint）
    static func tinted(_ c: RGBA, toward tint: SkyRGBA) -> RGBA {
        let t = SkyRGBA(r: c.r, g: c.g, b: c.b, a: c.a).tinted(toward: tint)
        return (t.r, t.g, t.b, t.a)
    }
}

extension CALayer {
    /// 暂停 / 继续这一层（连同子层）的动画时间轴：暂停时停在当前画面，继续时从停下的地方接着走，不跳回起点
    func setPaused(_ paused: Bool) {
        let target: Float = paused ? 0 : 1
        guard speed != target else { return }
        if paused {
            let now = convertTime(CACurrentMediaTime(), from: nil)
            speed = 0
            timeOffset = now
        } else {
            let pausedAt = timeOffset
            speed = 1
            timeOffset = 0
            beginTime = 0
            beginTime = convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        }
    }
}

/// 运行方式。
enum RenderMode {
    /// 离屏截图（--render-pages）：跳过系统粒子 / 渐变层（renderInContext 软件渲染它们极慢），画作同步烘好，不装事件监听
    static let offscreen = CommandLine.arguments.contains("--render-pages")
}

// MARK: - 动效节奏

/// 动效分四档，全应用共用同一套曲线。调用处仍要遵守动效开关：`withAnimation(motion ? Motion.quick : nil)`。
enum Motion {
    /// 按压、勾选（0.15 秒）
    static let quick = Animation.easeOut(duration: 0.15)
    /// 悬停浮起、展开收起、提示出现（弹簧 0.32 / 0.85）
    static let standard = Animation.spring(response: 0.32, dampingFraction: 0.85)
    /// 可点块的悬停底色与描边（0.18 秒缓出）
    static let hover = Animation.easeOut(duration: 0.18)
    /// 进度条、数值变化（0.5 秒）
    static let gentle = Animation.easeInOut(duration: 0.5)
    /// 仪式（落印、飞剑、渡劫）的落定：可以长、可以大
    static let ceremony = Animation.spring(response: 0.32, dampingFraction: 0.62)

    /// 进页：背景柔光与横幅画作一起淡入
    static let reveal = Animation.easeOut(duration: 0.4)
    /// 进页：标题与卡片上浮显现
    static let entrance = Animation.easeOut(duration: 0.26)
    /// 进页错峰：标题（order < 0）0.06 秒；卡片从 0.12 秒起每张错开 50 毫秒，前 6 张之后一起出现。全程约 0.6 秒内走完
    static func entranceDelay(_ order: Int) -> Double {
        order < 0 ? 0.06 : 0.12 + Double(min(order, 5)) * 0.05
    }
}

/// 进页时上浮显现（见 `View.ysEntrance(order:)`）。
private struct EntranceModifier: ViewModifier {
    var order: Int
    @Environment(\.spiritMotion) private var motion
    /// 是否已经显现过：出现之后动效开关再变也不会把它重新藏起来
    @State private var shown = false

    func body(content: Content) -> some View {
        let hidden = !shown && motion && !RenderMode.offscreen
        content
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden ? 10 : 0)
            .onAppear {
                guard !shown else { return }
                guard motion, !RenderMode.offscreen else { shown = true; return }
                withAnimation(Motion.entrance.delay(Motion.entranceDelay(order))) { shown = true }
            }
    }
}

extension View {
    /// 进页时按顺序上浮显现：横幅标题传 -1，正文卡片从 0 起依次标号（前 6 张错峰，其余一起出现）。
    /// 关闭动效、系统“减少动态效果”或离屏截图时直接显示。
    func ysEntrance(order: Int) -> some View { modifier(EntranceModifier(order: order)) }
}

// MARK: - 柔光

/// 一团边缘完全化开的柔光 / 雾气（椭圆渐变，不依赖模糊滤镜）。
struct SoftGlow: View {
    var color: Color
    var body: some View {
        Rectangle()
            .fill(EllipticalGradient(stops: [.init(color: color, location: 0), .init(color: color.opacity(0.55), location: 0.35),
                                             .init(color: color.opacity(0), location: 1)], center: .center))
            .allowsHitTesting(false)
    }
}

// MARK: - 灵气粒子

/// 缓缓上浮、明灭的灵气光点；meteors 时偶有流星划过（深色一直有，浅色只在天色入夜时有）。
/// 由 Core Animation 粒子发射器在渲染进程里绘制，应用本身几乎不占 CPU。
struct SpiritField: View {
    var count: Int = 44
    var animated: Bool
    var meteors: Bool = false
    var intensity: Double = 1
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if RenderMode.offscreen { Color.clear } else { emitter }
    }

    private var emitter: some View {
        SpiritEmitterView(density: Double(count), animated: animated, meteors: meteors,
                          intensity: intensity, dark: scheme == .dark)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct SpiritEmitterView: NSViewRepresentable {
    var density: Double
    var animated: Bool
    var meteors: Bool
    var intensity: Double
    var dark: Bool

    func makeNSView(context: Context) -> EmitterHostView { EmitterHostView() }

    func updateNSView(_ view: EmitterHostView, context: Context) {
        view.configure(density: density, animated: animated, meteors: meteors, intensity: intensity, dark: dark)
    }
}

final class EmitterHostView: NSView {
    private let motes = CAEmitterLayer()
    private let shooting = CAEmitterLayer()
    private var signature = ""
    /// 流星另记：浅色入夜时才开、天亮时关，只换流星，不重建光点（否则光点会整片重新预热、闪一下）
    private var meteorSignature = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(motes)
        layer?.addSublayer(shooting)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        motes.frame = b
        motes.emitterShape = .line
        motes.emitterPosition = CGPoint(x: b.midX, y: b.maxY + 20)
        motes.emitterSize = CGSize(width: b.width * 1.1, height: 1)
        shooting.frame = b
        shooting.emitterShape = .line
        shooting.emitterPosition = CGPoint(x: b.width * 0.72, y: -10)
        shooting.emitterSize = CGSize(width: b.width * 0.5, height: 1)
        CATransaction.commit()
    }

    func configure(density: Double, animated: Bool, meteors: Bool, intensity: Double, dark: Bool) {
        let key = "\(density)|\(intensity)|\(dark)"
        if key != signature {
            signature = key
            motes.emitterCells = Self.moteCells(density: density, intensity: intensity, dark: dark)
            // 预热：一打开就布满光点（用本层时间轴，暂停 / 继续过之后也正确）
            motes.beginTime = (layer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()) - 30
        }
        let meteorKey = "\(meteors)|\(dark)"
        if meteorKey != meteorSignature {
            meteorSignature = meteorKey
            shooting.emitterCells = meteors ? [Self.meteorCell(dark: dark)] : []
        }
        // 暂停 / 继续时保持当前画面
        layer?.setPaused(!animated)
    }

    private static let glow: CGImage? = {
        let size = 48
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.5), CGColor(gray: 1, alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.18, 1]) else { return nil }
        let c = CGPoint(x: size / 2, y: size / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size / 2), options: [])
        return ctx.makeImage()
    }()

    /// 斜向的流星（头在左下、尾在右上，与发射方向一致，不需要旋转粒子）
    private static let streak: CGImage? = {
        let w = 130, h = 95
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CGContext 原点在左下：头 (4,4)，尾 (w-4, h-4)
        let steps = 40
        for i in 0..<steps {
            let f = CGFloat(i) / CGFloat(steps)
            let x = 4 + (CGFloat(w) - 8) * f, y = 4 + (CGFloat(h) - 8) * f
            ctx.setFillColor(CGColor(gray: 1, alpha: (1 - f) * 0.9))
            let r = 1.6 * (1 - f) + 0.4
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        return ctx.makeImage()
    }()

    private static func moteCells(density: Double, intensity: Double, dark: Bool) -> [CAEmitterCell] {
        let palette = SpiritPalette.moteColors(dark: dark)
        let peak = Float(min(1, (dark ? 0.85 : 0.6) * intensity))
        return palette.map { color in
            let cell = CAEmitterCell()
            cell.contents = glow
            cell.birthRate = Float(density / 3 / 40)
            cell.lifetime = 40
            cell.lifetimeRange = 10
            cell.velocity = 22
            cell.velocityRange = 12
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi / 10
            cell.xAcceleration = 0
            cell.scale = 0.26
            cell.scaleRange = 0.14
            cell.color = color.withAlphaComponent(CGFloat(peak)).cgColor
            cell.alphaRange = 0.35
            cell.alphaSpeed = -peak / 40
            return cell
        }
    }

    /// 流星：深色是白色，浅色（天色入夜时才有）是淡金，在幽蓝的纸面上看得见又不刺眼
    private static func meteorCell(dark: Bool) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = streak
        // 约 11 秒一颗（“偶有流星”）
        cell.birthRate = 1.0 / 11
        cell.lifetime = 1.3
        cell.velocity = 520
        cell.velocityRange = 120
        cell.emissionLongitude = .pi * 0.8
        cell.emissionRange = .pi / 24
        cell.alphaSpeed = -0.75
        cell.scale = 0.9
        cell.color = dark ? NSColor(white: 1, alpha: 0.85).cgColor : NSColor(srgbRed: 0.80, green: 0.68, blue: 0.42, alpha: 0.9).cgColor
        // 流星沿运动方向拉长
        cell.spin = 0
        return cell
    }
}

// MARK: - 流云与天光

/// 页面底层：几团极淡的流云缓慢飘移，加一轮朝阳 / 月华的光晕。
/// sunTint：天色给的日晕换色（入夜转成月白，免得幽蓝纸面上挂一团暖黄）；只改颜色，透明度、位置、大小不变
struct MistDrift: View {
    var animated: Bool
    var sunTint: SkyRGBA = .clear
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if RenderMode.offscreen {
            staticMist
        } else {
            MistLayerView(animated: animated, dark: scheme == .dark, sunTint: sunTint)
                .allowsHitTesting(false)
        }
    }

    /// 截图用的静态版（与动画起点一致）
    private var staticMist: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let palette = MistPalette(dark: scheme == .dark)
            let mist = MistPalette.color(palette.mist)
            ZStack {
                SoftGlow(color: MistPalette.color(MistPalette.tinted(palette.glow, toward: sunTint)))
                    .frame(width: 640, height: 640).position(x: w * 0.86, y: h * 0.04)
                SoftGlow(color: mist).frame(width: w * 0.9, height: h * 0.3).position(x: w * 0.62, y: h * 0.36)
                SoftGlow(color: mist).frame(width: w * 0.75, height: h * 0.26).position(x: w * 0.4, y: h * 0.72)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 流云与天光：Core Animation 渐变层 + 系统层动画，在渲染进程里运行，不占应用 CPU。
private struct MistLayerView: NSViewRepresentable {
    var animated: Bool
    var dark: Bool
    var sunTint: SkyRGBA

    func makeNSView(context: Context) -> MistHostView { MistHostView() }
    func updateNSView(_ view: MistHostView, context: Context) { view.configure(animated: animated, dark: dark, sunTint: sunTint) }
}

final class MistHostView: NSView {
    private let sun = CAGradientLayer()
    private let clouds = [CAGradientLayer(), CAGradientLayer(), CAGradientLayer()]
    /// 工笔流云图层（有素材时取代前两团渐变雾）
    private let bands = [CALayer(), CALayer()]
    private static let cloudImage: CGImage? = Scenery.image("yunshan-cloud-band-v1")?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    private var dark: Bool?
    /// 日晕当前的换色（天色）
    private var sunTint: SkyRGBA?
    private var lastSize = CGSize.zero
    /// 流云动画的起点（本层时间）：窗口尺寸变化时重建动画也从这里算相位，流云不会跳回起点
    private var driftStart: CFTimeInterval?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for layer in [sun] + clouds {
            layer.type = .radial
            layer.startPoint = CGPoint(x: 0.5, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 1)
            self.layer?.addSublayer(layer)
        }
        for band in bands {
            band.contents = Self.cloudImage
            band.contentsGravity = .resize
            self.layer?.addSublayer(band)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 每团云：尺寸（相对宽高）、起点与终点（相对坐标）、周期
    private let specs: [(w: CGFloat, h: CGFloat, from: CGPoint, to: CGPoint, period: Double)] = [
        (0.9, 0.3, CGPoint(x: 0.62, y: 0.36), CGPoint(x: 0.30, y: 0.36), 52),
        (0.75, 0.26, CGPoint(x: 0.40, y: 0.72), CGPoint(x: 0.78, y: 0.72), 64),
        (0.6, 0.4, CGPoint(x: 0.28, y: 0.85), CGPoint(x: 0.15, y: 0.95), 46),
    ]

    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        let w = bounds.width, h = bounds.height
        let start = driftStart ?? (self.layer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime())
        driftStart = start
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sun.bounds = CGRect(x: 0, y: 0, width: 640, height: 640)
        sun.position = CGPoint(x: w * 0.86, y: h * 0.04)
        let hasBands = Self.cloudImage != nil
        for (index, (gradient, spec)) in zip(clouds, specs).enumerated() {
            // 前两团用流云图（宽高比 3:1），第三团保留玉色渐变
            let layer: CALayer = (hasBands && index < bands.count) ? bands[index] : gradient
            if hasBands && index < bands.count { gradient.isHidden = true }
            layer.bounds = hasBands && index < bands.count
                ? CGRect(x: 0, y: 0, width: w * spec.w, height: w * spec.w / 3)
                : CGRect(x: 0, y: 0, width: w * spec.w, height: h * spec.h)
            layer.position = CGPoint(x: w * spec.from.x, y: h * spec.from.y)
            layer.removeAnimation(forKey: "drift")
            let drift = CABasicAnimation(keyPath: "position")
            drift.fromValue = NSValue(point: CGPoint(x: w * spec.from.x, y: h * spec.from.y))
            drift.toValue = NSValue(point: CGPoint(x: w * spec.to.x, y: h * spec.to.y))
            drift.duration = spec.period / 2
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // 续接原来的相位（子层与本层时间轴一致）
            drift.beginTime = start
            // 流云每秒只移动十来个点，30 帧足够顺滑，不必按屏幕最高刷新率合成
            drift.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
            layer.add(drift, forKey: "drift")
        }
        CATransaction.commit()
    }

    func configure(animated: Bool, dark: Bool, sunTint: SkyRGBA = .clear) {
        let flipped = self.dark != dark
        if flipped {
            self.dark = dark
            let palette = MistPalette(dark: dark)
            let mist = MistPalette.nsColor(palette.mist), jade = MistPalette.nsColor(palette.jade)
            clouds[0].colors = [mist.cgColor, mist.withAlphaComponent(mist.alphaComponent * 0.55).cgColor, mist.withAlphaComponent(0).cgColor]
            clouds[1].colors = clouds[0].colors
            clouds[2].colors = [jade.cgColor, jade.withAlphaComponent(0.035).cgColor, jade.withAlphaComponent(0).cgColor]
            for layer in clouds { layer.locations = [0, 0.35, 1] }
            // 流云：浅色时是宣纸上的白雾，深色时是月下极淡的薄云
            bands[0].opacity = dark ? 0.10 : 0.55
            bands[1].opacity = dark ? 0.07 : 0.4
        }
        if flipped || self.sunTint != sunTint {
            self.sunTint = sunTint
            // 日晕：天色换色走 2.5 秒（在渲染进程里做）；切换深浅色、关掉动效时直接换
            CATransaction.begin()
            if flipped || !animated {
                CATransaction.setDisableActions(true)
            } else {
                CATransaction.setAnimationDuration(2.5)
            }
            let glow = MistPalette.nsColor(MistPalette.tinted(MistPalette(dark: dark).glow, toward: sunTint))
            sun.colors = [glow.cgColor, glow.withAlphaComponent(0).cgColor]
            CATransaction.commit()
        }
        // 暂停 / 继续时保持当前画面，不跳回起点
        layer?.setPaused(!animated)
    }
}

// MARK: - 水墨远山

/// 一道起伏的山脊（几组正弦叠加，峰顶略尖），填充到底部。
struct RidgeShape: Shape {
    var seed: Int
    /// 山脚线（相对高度，0 顶 1 底）
    var baseline: CGFloat
    /// 起伏幅度（相对高度）
    var amplitude: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let f1 = 1.4 + spiritNoise(seed, 60) * 1.2, f2 = 3.1 + spiritNoise(seed, 61) * 2.4, f3 = 7 + spiritNoise(seed, 62) * 5
        let p1 = spiritNoise(seed, 63) * 6.28, p2 = spiritNoise(seed, 64) * 6.28, p3 = spiritNoise(seed, 65) * 6.28
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for x in stride(from: 0, through: w, by: 4) {
            let u = Double(x / w) * 2 * .pi
            let ridge = 0.55 * (1 - abs(sin(u * f1 / 2 + p1))) + 0.3 * (1 - abs(sin(u * f2 / 2 + p2))) + 0.15 * sin(u * f3 + p3)
            p.addLine(to: CGPoint(x: rect.minX + x, y: rect.minY + h * baseline - h * amplitude * CGFloat(ridge)))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// 页面底部三重远山：越远越淡，山脚隐入云雾；三重远山各自缓缓漂移（Core Animation，越近动得越多）。
/// ink：天色给的墨色偏移（rgb 往它靠，比例取它的 a；.clear = 原色），入夜偏靛青、黄昏成紫褐剪影。
/// 离屏截图用下面的 SwiftUI 静态画法（与动画起点一致）
struct InkMountains: View {
    var animated: Bool
    var ink: SkyRGBA = .clear
    @Environment(\.colorScheme) private var scheme

    /// 原来的墨色：深色月下淡青，浅色松烟墨绿
    static func baseInk(dark: Bool) -> SkyRGBA {
        dark ? SkyRGBA(r: 0.55, g: 0.72, b: 0.66, a: 1) : SkyRGBA(r: 0.28, g: 0.42, b: 0.36, a: 1)
    }

    var body: some View {
        let dark = scheme == .dark
        let tone = Self.baseInk(dark: dark).tinted(toward: ink)
        if RenderMode.offscreen {
            still(ink: tone.color, dark: dark)
        } else {
            InkRidgeView(ink: tone, dark: dark, animated: animated)
                .frame(height: InkRidgeHostView.height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func still(ink: Color, dark: Bool) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .bottom) {
                ForEach(0..<3) { layer in
                    let alpha: Double = [0.05, 0.075, 0.11][layer] * (dark ? 1.2 : 1)
                    RidgeShape(seed: 7 + layer * 13, baseline: [0.42, 0.6, 0.8][layer], amplitude: [0.32, 0.3, 0.26][layer])
                        .fill(LinearGradient(colors: [ink.opacity(alpha), ink.opacity(alpha * 0.25), .clear], startPoint: .top, endPoint: .bottom))
                        .frame(width: w * 1.2)
                        .offset(x: CGFloat(layer - 1) * 30)
                }
            }
            .frame(width: w, height: geo.size.height, alignment: .bottom)
        }
        .frame(height: 360)
        .allowsHitTesting(false)
        .drawingGroup()
    }
}

// MARK: - 卡片灵纹

/// 四角的回纹描边，给卡片一点“法器”的边框感。
struct CornerFlourish: Shape {
    var inset: CGFloat = 7
    var length: CGFloat = 15

    /// 悬停时回纹是“伸长”出去的，而不是一下跳到新长度
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(inset, length) }
        set { inset = newValue.first; length = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = rect.insetBy(dx: inset, dy: inset)
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: r.minX, y: r.minY), 1, 1), (CGPoint(x: r.maxX, y: r.minY), -1, 1),
            (CGPoint(x: r.minX, y: r.maxY), 1, -1), (CGPoint(x: r.maxX, y: r.maxY), -1, -1),
        ]
        for (c, sx, sy) in corners {
            p.move(to: CGPoint(x: c.x, y: c.y + sy * length))
            p.addLine(to: CGPoint(x: c.x, y: c.y + sy * 4))
            p.addQuadCurve(to: CGPoint(x: c.x + sx * 4, y: c.y), control: c)
            p.addLine(to: CGPoint(x: c.x + sx * length, y: c.y))
            // 内侧小回勾
            p.move(to: CGPoint(x: c.x + sx * 4, y: c.y + sy * 8))
            p.addLine(to: CGPoint(x: c.x + sx * 4, y: c.y + sy * 4))
            p.addLine(to: CGPoint(x: c.x + sx * 8, y: c.y + sy * 4))
        }
        return p
    }
}

/// 悬停时卡片边缘亮起的一道金玉灵光（静态：只在悬停开始时绘制一次，不做逐帧转动，避免持续占用 CPU）。
struct SpiritRim: View {
    var cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(colors: [Theme.gold.opacity(0.95), Theme.jade.opacity(0.55), Theme.gold.opacity(0.25), Theme.gold.opacity(0.8)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.5)
            .allowsHitTesting(false)
    }
}

/// 掠过文字的一道光（标题用）：每次进入页面扫一次，扫完撤掉，不常驻消耗。
struct ShimmerSweep: ViewModifier {
    var animated: Bool
    @State private var progress: CGFloat = -0.2
    @State private var sweeping = false

    func body(content: Content) -> some View {
        content.overlay {
            if sweeping {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, Color.white.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 70)
                        .rotationEffect(.degrees(16))
                        .offset(x: -90 + (geo.size.width + 180) * progress)
                        .opacity(progress > 0 && progress < 1 ? 1 : 0)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            // 离屏截图不扫（截到半道光就不能逐张对比了）
            guard animated, !RenderMode.offscreen else { return }
            sweeping = true
            progress = 0
            withAnimation(.easeInOut(duration: 1.6).delay(0.5)) { progress = 1 }
            // 扫完把这层撤掉，不常驻
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { sweeping = false }
        }
    }
}

extension View {
    /// 标题掠光：每次进入页面扫一次
    func shimmerSweep(_ animated: Bool) -> some View { modifier(ShimmerSweep(animated: animated)) }
}

// MARK: - 切页：新页面由虚化实

struct MistRevealModifier: ViewModifier {
    var progress: Double
    func body(content: Content) -> some View {
        // 只用透明度与位移（整页模糊转场代价太大，切页会顿）
        content
            .opacity(progress)
            .offset(y: (1 - progress) * 12)
    }
}

extension AnyTransition {
    static var mistReveal: AnyTransition {
        .asymmetric(insertion: .modifier(active: MistRevealModifier(progress: 0), identity: MistRevealModifier(progress: 1)),
                    removal: .opacity.animation(.easeOut(duration: 0.15)))
    }
}
