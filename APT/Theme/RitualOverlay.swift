import SwiftUI
import AppKit
import QuartzCore

// 关键时刻的仪式：落笔入卷（墨迹晕开、纸卷合拢、化作灵光飞入修行录）、功课圆满（四方灵光汇丹田、金符展开）、朱印。
// 全部用 Core Animation：触发时同步建层、按 RitualTimeline 取样生成关键帧，CATransaction.flush() 提交到渲染进程，
// 之后主线程再忙（入卷后 @Query 重取、修为重算）也照样流畅。离屏定格用同一套时间函数直接把图层摆到某一刻（pose）。
// 图层铺满窗口，hitTest 永远返回 nil，不接收点击、不成为第一响应者、对读屏隐藏；动效关闭时不播（见 EffectsCenter）。

// MARK: - 锚点

/// 仪式落在哪里：挂在界面元素上登记位置（窗口坐标），与 .sealAnchor() 同一种做法
enum RitualAnchor: Hashable {
    /// 落笔框（纸笺铺在这里）
    case composer
    /// 侧栏“修行录”那一行（小卷飞到它的小物上）
    case chronicleNav
    /// 侧栏境界徽记（“丹田”，灵光汇聚处）
    case dantian
}

private struct RitualAnchorModifier: ViewModifier {
    var anchor: RitualAnchor
    @Environment(EffectsCenter.self) private var effects: EffectsCenter?
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
                effects?.registerRitualAnchor(anchor, id: id, rect: rect)
            }
            .onDisappear { effects?.unregisterRitualAnchor(anchor, id: id) }
    }
}

extension View {
    /// 登记仪式锚点；nil 时什么都不做（方便写 section == .chronicle ? .chronicleNav : nil）
    @ViewBuilder
    func ritualAnchor(_ anchor: RitualAnchor?) -> some View {
        if let anchor {
            modifier(RitualAnchorModifier(anchor: anchor))
        } else {
            self
        }
    }
}

// MARK: - 播放器

@MainActor
protocol RitualPlayer: AnyObject {
    func play(_ ritual: EffectsCenter.Ritual)
    func playSeal(_ seal: EffectsCenter.Seal)
    /// 渡劫开始时：正在放的仪式 0.12 秒内淡掉
    func cancelAll()
}

/// 挂在 RootView 的叠加层里（飘字之上、SwiftUI 朱印之下）：铺满窗口、不接收点击、对读屏隐藏；离屏截图时什么都不放。
/// 用 GeometryReader 取自身在窗口里的原点交给宿主视图：锚点、点击位置都先减去它再摆图层（与 SealStampOverlay.center 同一做法）
struct RitualOverlay: View {
    @Environment(EffectsCenter.self) private var effects

    var body: some View {
        if !RenderMode.offscreen {
            GeometryReader { geo in
                RitualLayerView(effects: effects, origin: geo.frame(in: .global).origin)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct RitualLayerView: NSViewRepresentable {
    var effects: EffectsCenter
    var origin: CGPoint

    func makeNSView(context: Context) -> RitualHostView {
        let view = RitualHostView(frame: .zero)
        view.effects = effects
        view.origin = origin
        effects.ritualPlayer = view
        return view
    }

    func updateNSView(_ view: RitualHostView, context: Context) {
        view.origin = origin
        if view.effects !== effects {
            view.effects = effects
            effects.ritualPlayer = view
        }
    }

    static func dismantleNSView(_ view: RitualHostView, coordinator: ()) {
        if let effects = view.effects, effects.ritualPlayer === view { effects.ritualPlayer = nil }
        view.cancelAll()
    }
}

/// 仪式图层的宿主：hitTest 永远返回 nil；makeNSView 时登记为 effects.ritualPlayer，dismantle 时注销
final class RitualHostView: NSView, RitualPlayer {
    weak var effects: EffectsCenter?
    /// 叠加层在窗口里的原点（窗口坐标）
    var origin: CGPoint = .zero
    private let stage = RitualStage()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 纸笺上的字被墨洇开：CATextLayer 的高斯模糊要 Core Image 滤镜
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = false
        layer?.addSublayer(stage.root)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func isAccessibilityElement() -> Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.root.frame = bounds
        CATransaction.commit()
    }

    private func prepare() {
        if stage.root.frame != bounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stage.root.frame = bounds
            CATransaction.commit()
        }
        stage.dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        stage.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        stage.origin = origin
        stage.size = bounds.size
    }

    func play(_ ritual: EffectsCenter.Ritual) {
        prepare()
        stage.play(ritual)
    }

    func playSeal(_ seal: EffectsCenter.Seal) {
        prepare()
        stage.playSeal(seal)
    }

    func cancelAll() { stage.cancelAll() }

    /// 离屏定格：不加动画，直接把各层摆成 t 时刻的样子（与 play 用同一套时间函数）
    func pose(_ ritual: EffectsCenter.Ritual, at t: Double) {
        prepare()
        stage.pose(ritual, at: t)
    }

    /// 离屏定格朱印
    func poseSeal(_ seal: EffectsCenter.Seal, at t: Double) {
        prepare()
        stage.poseSeal(seal, at: t)
    }

    /// 落笔框位置变了（入卷后清空变矮、滚动）：衬纸跟着换成新的框
    func anchorMoved(_ anchor: RitualAnchor, rect: CGRect) {
        guard anchor == .composer else { return }
        stage.composerMoved(to: CGRect(origin: CGPoint(x: rect.minX - origin.x, y: rect.minY - origin.y), size: rect.size))
    }
}

// MARK: - 时间轨

/// 一条“随时间变化的图层属性”：播放时按它取样生成关键帧，定格时直接取某一刻的值
private struct RitualTrack {
    let layer: CALayer
    let keyPath: String
    /// 关键帧覆盖 [0, length] 秒，之后停在 length 时刻的值
    let length: Double
    /// 只在实际播放时用：离屏定格的 render(in:) 不画滤镜
    var liveOnly = false
    /// 关键帧每秒取几个点：默认 90（仪式跟着屏幕刷新，60–120 帧）；数量多的灵光取 50，位置用平滑曲线连起来
    var rate: Double = 90
    /// 同一条轨迹只晚一点的副本（灵光的彗尾）：同一个 shareKey 只取样一次，之后各份只把开始时刻推后 lag 秒
    var shareKey: String? = nil
    var lag: Double = 0
    let value: (Double) -> Any

    /// 设成共用：value 必须等于“领头那份晚 lag 秒”
    func shared(_ key: String, lag: Double) -> RitualTrack {
        var copy = self
        copy.shareKey = key
        copy.lag = lag
        return copy
    }

    static func number(_ layer: CALayer, _ keyPath: String, _ length: Double, liveOnly: Bool = false, rate: Double = 90,
                       _ f: @escaping (Double) -> Double) -> RitualTrack {
        RitualTrack(layer: layer, keyPath: keyPath, length: length, liveOnly: liveOnly, rate: rate) { NSNumber(value: f($0)) }
    }

    static func position(_ layer: CALayer, _ length: Double, rate: Double = 90, _ f: @escaping (Double) -> CGPoint) -> RitualTrack {
        RitualTrack(layer: layer, keyPath: "position", length: length, rate: rate) { NSValue(point: f($0)) }
    }

    /// cache：共用轨迹的关键帧（同一场里只取样一次）；now：这一场的开始时刻（共用的副本按它推后 lag）
    func animate(cache: inout [String: CAKeyframeAnimation], now: CFTimeInterval) {
        let animation: CAKeyframeAnimation
        if let key = shareKey, let hit = cache[key] {
            animation = hit
        } else {
            let samples = max(2, Int((length * rate).rounded(.up)) + 1)
            let times = RitualTimeline.keyTimes(samples: samples)
            animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = times.map { value($0 * length + lag) }
            animation.keyTimes = times.map { NSNumber(value: $0) }
            animation.duration = length
            animation.calculationMode = rate < 90 && keyPath == "position" ? .cubic : .linear
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            if let key = shareKey { cache[key] = animation }
        }
        if shareKey != nil {
            // 开始前停在第一帧（还没出发、透明）；add 时会复制一份，改开始时刻不影响别的副本
            animation.beginTime = now + lag
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: keyPath)
        set(value(length + lag))
    }

    func pose(at t: Double) {
        guard !liveOnly else { return }
        set(value(min(t, length)))
    }

    /// 写模型值。缩放、旋转直接写 transform（每个图层只有其中一种，见各处的分层），其余走 KVC
    private func set(_ value: Any) {
        switch keyPath {
        case "transform.scale":
            let s = CGFloat((value as? NSNumber)?.doubleValue ?? 1)
            layer.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
        case "transform.rotation.z":
            layer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat((value as? NSNumber)?.doubleValue ?? 0)))
        default:
            layer.setValue(value, forKeyPath: keyPath)
        }
    }
}

// MARK: - 舞台

/// 仪式的图层树：宿主视图与离屏定格共用。三层容器定上下顺序：
/// 下层（衬纸 < 纸笺 < 卷轴 < 墨晕 < 墨星、印泥晕） < 朱印 < 上层（尾迹 / 小卷 < 涟漪；圆满整场）
@MainActor
final class RitualStage {
    let root = CALayer()
    private let lower = CALayer()
    private let sealHost = CALayer()
    private let upper = CALayer()
    var dark = false
    var contentsScale: CGFloat = 2
    /// 叠加层在窗口里的原点：锚点先减去它
    var origin = CGPoint.zero
    var size = CGSize.zero

    private enum Kind { case inscription, consummation, seal }

    private final class Show {
        let id = UUID()
        let kind: Kind
        var groups: [CALayer] = []
        var tracks: [RitualTrack] = []
        let length: Double
        /// 衬纸：跟着落笔框的实际位置走（清空后变矮，露出下面的心境、按钮）
        var backing: CALayer?
        var started = CACurrentMediaTime()

        init(kind: Kind, length: Double) {
            self.kind = kind
            self.length = length
        }
    }

    private var shows: [Show] = []

    init() {
        for container in [lower, sealHost, upper] {
            container.anchorPoint = .zero
            container.bounds = .zero
            container.position = .zero
            root.addSublayer(container)
        }
        root.masksToBounds = false
    }

    // MARK: 播放与定格

    func play(_ ritual: EffectsCenter.Ritual) {
        guard size.width > 0, size.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let show = build(ritual)
        replace(show)
        animate(show)
        CATransaction.commit()
        CATransaction.flush()
        scheduleRemoval(show)
    }

    func playSeal(_ seal: EffectsCenter.Seal) {
        guard size.width > 0, size.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let show = buildSeal(seal)
        replace(show)
        animate(show)
        CATransaction.commit()
        CATransaction.flush()
        scheduleRemoval(show)
    }

    func pose(_ ritual: EffectsCenter.Ritual, at t: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let show = build(ritual)
        clear(show.kind)
        shows.append(show)
        for track in show.tracks { track.pose(at: t) }
        CATransaction.commit()
    }

    func poseSeal(_ seal: EffectsCenter.Seal, at t: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let show = buildSeal(seal)
        clear(.seal)
        shows.append(show)
        for track in show.tracks { track.pose(at: t) }
        CATransaction.commit()
    }

    private func animate(_ show: Show) {
        var cache: [String: CAKeyframeAnimation] = [:]
        let now = root.convertTime(CACurrentMediaTime(), from: nil)
        for track in show.tracks { track.animate(cache: &cache, now: now) }
    }

    /// 渡劫开始：正在放的全部淡掉
    func cancelAll() {
        let current = shows
        shows.removeAll()
        CATransaction.begin()
        fade(current)
        CATransaction.commit()
    }

    /// 落笔框变了：衬纸换成新的框（仪式还在放时）
    func composerMoved(to rect: CGRect) {
        guard rect.width > 20, rect.height > 20,
              let show = shows.last(where: { $0.kind == .inscription && $0.backing != nil }),
              CACurrentMediaTime() - show.started < show.length, let backing = show.backing else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backing.frame = rect
        CATransaction.commit()
    }

    /// 同类的上一场先 0.12 秒淡掉，再放新的
    private func replace(_ show: Show) {
        let old = shows.filter { $0.kind == show.kind }
        shows.removeAll { $0.kind == show.kind }
        fade(old)
        show.started = CACurrentMediaTime()
        shows.append(show)
    }

    private func clear(_ kind: Kind) {
        for show in shows where show.kind == kind { show.groups.forEach { $0.removeFromSuperlayer() } }
        shows.removeAll { $0.kind == kind }
    }

    private func fade(_ old: [Show]) {
        for show in old {
            for group in show.groups {
                let from = group.presentation()?.opacity ?? group.opacity
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = from
                fade.toValue = 0
                fade.duration = 0.12
                group.add(fade, forKey: "cancel")
                group.opacity = 0
            }
        }
        guard !old.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            for show in old { show.groups.forEach { $0.removeFromSuperlayer() } }
        }
    }

    private func scheduleRemoval(_ show: Show) {
        DispatchQueue.main.asyncAfter(deadline: .now() + show.length + 0.15) { [weak self] in
            guard let self, self.shows.contains(where: { $0 === show }) else { return }
            show.groups.forEach { $0.removeFromSuperlayer() }
            self.shows.removeAll { $0 === show }
        }
    }

    private func build(_ ritual: EffectsCenter.Ritual) -> Show {
        switch ritual {
        case .inscription(let inscription): buildInscription(inscription)
        case .consummation(let consummation): buildConsummation(consummation)
        }
    }

    // MARK: 小工具

    private func localRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - origin.x, y: rect.minY - origin.y, width: rect.width, height: rect.height)
    }

    private func localPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - origin.x, y: point.y - origin.y) }

    private func group(in container: CALayer, _ show: Show) -> CALayer {
        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.bounds = .zero
        layer.position = .zero
        container.addSublayer(layer)
        show.groups.append(layer)
        return layer
    }

    /// 柔光点（颜色烘在图里）
    private func sprite(_ rgb: RitualRGB, side: CGFloat, at point: CGPoint = .zero, core: Bool = false) -> CALayer {
        let layer = CALayer()
        layer.contents = core ? RitualArt.core(rgb) : RitualArt.glow(rgb)
        layer.contentsGravity = .resize
        layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        layer.position = point
        return layer
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// 朱印中心：正盖在刚点的按钮上，印的下沿略低于按钮、往上探进正文框的右下角，并留在窗口里（与 SealStampOverlay 相同）
    static func sealCenter(sealSize: CGSize, anchor: CGRect?, in size: CGSize) -> CGPoint {
        guard let anchor, size.width > 0, size.height > 0 else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let x = anchor.midX
        let y = anchor.maxY + 6 - sealSize.height / 2
        let marginX = sealSize.width / 2 + 16, marginY = sealSize.height / 2 + 16
        return CGPoint(x: min(max(x, marginX), size.width - marginX), y: min(max(y, marginY), size.height - marginY))
    }

    /// 侧栏“修行录”小物的圆心：锚点登记的是整行（左内边距 10 + 小物半宽 21；紧凑排布 10 + 18），去掉行下 3pt（紧凑 2pt）的间距再取竖直居中
    static func ornamentCenter(of row: CGRect) -> CGPoint {
        let compact = row.height < 48
        return CGPoint(x: row.minX + (compact ? 28 : 31), y: row.minY + (row.height - (compact ? 2 : 3)) / 2)
    }

    /// 沿二次贝塞尔的折线（64 段）与各点的弧长占比：尾迹的 strokeEnd 按弧长走，与小卷的位置对得上
    private struct ArcPath {
        let points: [CGPoint]
        let fractions: [Double]
        let path: CGPath

        init(from: CGPoint, to: CGPoint, swirl: Double, segments: Int = 64) {
            var pts: [CGPoint] = []
            for j in 0...segments {
                let p = RitualTimeline.curve(from: (Double(from.x), Double(from.y)), to: (Double(to.x), Double(to.y)),
                                             swirl: swirl, s: Double(j) / Double(segments))
                pts.append(CGPoint(x: p.x, y: p.y))
            }
            var lengths: [Double] = [0]
            for j in 1..<pts.count { lengths.append(lengths[j - 1] + Double(hypot(pts[j].x - pts[j - 1].x, pts[j].y - pts[j - 1].y))) }
            let total = max(1e-6, lengths.last ?? 1)
            points = pts
            fractions = lengths.map { $0 / total }
            let path = CGMutablePath()
            path.addLines(between: pts)
            self.path = path
        }

        /// 参数 s 处的点
        func point(_ s: Double) -> CGPoint {
            let x = min(1, max(0, s)) * Double(points.count - 1)
            let i = min(points.count - 2, Int(x)), f = CGFloat(x - Double(i))
            return CGPoint(x: points[i].x + (points[i + 1].x - points[i].x) * f, y: points[i].y + (points[i + 1].y - points[i].y) * f)
        }

        /// 参数 s 处走过的弧长占比
        func fraction(_ s: Double) -> Double {
            let x = min(1, max(0, s)) * Double(points.count - 1)
            let i = min(points.count - 2, Int(x)), f = x - Double(i)
            return fractions[i] + (fractions[i + 1] - fractions[i]) * f
        }
    }

    // MARK: 朱印

    private func buildSeal(_ seal: EffectsCenter.Seal) -> Show {
        let length = RitualTimeline.sealLength
        let show = Show(kind: .seal, length: length)
        let host = group(in: sealHost, show)
        let sealSize = SealLayerFactory.size(for: seal.text)
        let center = Self.sealCenter(sealSize: sealSize, anchor: seal.anchor.map(localRect), in: size)
        let P = RitualTimeline.seal(at:)

        // 涟漪只留一圈（不随印身旋转）
        let ripple = CALayer()
        ripple.bounds = CGRect(x: 0, y: 0, width: sealSize.height, height: sealSize.height)
        ripple.cornerRadius = sealSize.height / 2
        ripple.borderWidth = 1.5
        ripple.borderColor = RitualPalette.cinnabar(0.45)
        ripple.position = center
        host.addSublayer(ripple)
        show.tracks.append(.number(ripple, "transform.scale", length) { 0.7 + 0.9 * P($0).ripple })
        show.tracks.append(.number(ripple, "opacity", length) { 0.7 * P($0).rippleAlpha })

        // 2.2 倍、−16° 弹簧落到 1 倍、−6°（旋转、缩放分两层，互不干扰）
        let rotor = CALayer()
        rotor.bounds = .zero
        rotor.position = center
        let scaler = CALayer()
        scaler.bounds = .zero
        scaler.position = .zero
        let body = SealLayerFactory.make(text: seal.text, scale: 1, contentsScale: contentsScale)
        body.position = .zero
        scaler.addSublayer(body)
        rotor.addSublayer(scaler)
        host.addSublayer(rotor)
        show.tracks.append(.number(rotor, "transform.rotation.z", length) { (-16 + 10 * P($0).landing) * .pi / 180 })
        show.tracks.append(.number(scaler, "transform.scale", length) { 2.2 - 1.2 * P($0).landing })
        show.tracks.append(.number(body, "opacity", length) { P($0).alpha })
        show.tracks.append(.number(body, "shadowOpacity", length) { 0.45 * P($0).shadow })
        show.tracks.append(.number(body, "shadowRadius", length) { 12 * min(1, max(0, P($0).landing)) })
        return show
    }

    // MARK: 落笔入卷

    private func buildInscription(_ inscription: EffectsCenter.Inscription) -> Show {
        let L = RitualTimeline.inscriptionLength
        let P = RitualTimeline.inscription(at:)
        let progress = RitualTimeline.progress
        let show = Show(kind: .inscription, length: L)
        let below = group(in: lower, show)
        let above = group(in: upper, show)
        let sealCenter = Self.sealCenter(sealSize: SealLayerFactory.size(for: "入卷"), anchor: inscription.seal.map(localRect), in: size)
        let ink = RitualPalette.ink(dark)
        let accent = RitualPalette.kind(inscription.kind, dark: dark)

        /// 三团墨晕：从印下往左上漫开，320 ms 最浓，800 ms 淡尽（后两团依次晚 50 ms）
        func blooms(in parent: CALayer, seal s: CGPoint, height: CGFloat) {
            for k in 0..<3 {
                let h = height * [1, 0.76, 0.56][k]
                let w = h * 1.8
                let blob = CALayer()
                blob.contents = RitualArt.blot(ink.rgb, variant: k)
                blob.contentsGravity = .resize
                blob.bounds = CGRect(x: 0, y: 0, width: w, height: h)
                parent.addSublayer(blob)
                let start = CGPoint(x: s.x - 6, y: s.y - 10)
                let end = CGPoint(x: s.x - w * [0.32, 0.62, 0.12][k], y: s.y - h * [0.22, 0.08, 0.36][k])
                let lag = 0.05 * Double(k), strength = [1.0, 0.85, 0.7][k]
                show.tracks.append(.position(blob, L) { t in
                    let g = CGFloat(P(t - lag).bloomScale)
                    return CGPoint(x: start.x + (end.x - start.x) * g, y: start.y + (end.y - start.y) * g)
                })
                show.tracks.append(.number(blob, "transform.scale", L) { Self.lerp(0.15, 1, P($0 - lag).bloomScale) })
                show.tracks.append(.number(blob, "opacity", L) { ink.alpha * strength * P($0 - lag).bloomAlpha })
            }
        }

        let slip = inscription.slip.map(localRect).flatMap { $0.width > 40 && $0.height > 24 ? $0 : nil }
        if let slip {
            let w = slip.width, h = slip.height
            // 衬纸：与落笔框底同色（卡片色上叠纸色 0.6），留到 1350 ms：主线程还没刷新时，纸笺卷走后露出的也是一张白纸
            let backing = CALayer()
            backing.frame = slip
            backing.backgroundColor = RitualPalette.backing(dark)
            backing.cornerRadius = Radius.control
            backing.borderWidth = 1
            backing.borderColor = RitualPalette.line(dark)
            below.addSublayer(backing)
            show.backing = backing
            show.tracks.append(.number(backing, "opacity", L) { P($0).backingAlpha })

            // 纸笺：卡片纸色、本类颜色的细边、刚写的正文；自右向左卷起（左缘不动，右边一截截卷进卷轴）
            let clip = CALayer()
            clip.anchorPoint = CGPoint(x: 0, y: 0.5)
            clip.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            clip.position = CGPoint(x: slip.minX, y: slip.midY)
            clip.masksToBounds = true
            clip.cornerRadius = Radius.control
            below.addSublayer(clip)
            let paper = CALayer()
            paper.frame = CGRect(x: 0, y: 0, width: w, height: h)
            paper.backgroundColor = RitualPalette.card(dark)
            paper.cornerRadius = Radius.control
            paper.borderWidth = 1
            paper.borderColor = accent.cg(0.75)
            clip.addSublayer(paper)
            let text = CATextLayer()
            text.frame = CGRect(x: 15, y: 10, width: max(10, w - 30), height: max(10, h - 20))
            text.string = RitualPalette.slipText(inscription.preview, dark: dark)
            text.isWrapped = true
            text.truncationMode = .end
            text.contentsScale = contentsScale
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(0, forKey: kCIInputRadiusKey)
                blur.setValue("blur", forKey: "name")
                text.filters = [blur]
            }
            clip.addSublayer(text)
            show.tracks.append(.number(text, "opacity", L) { 1 - 0.2 * P($0).slipBlur })
            show.tracks.append(.number(text, "filters.blur.inputRadius", L, liveOnly: true) { 1.2 * P($0).slipBlur })
            // 墨晕在纸上：随纸一起被卷走
            blooms(in: clip, seal: CGPoint(x: sealCenter.x - slip.minX, y: sealCenter.y - slip.minY), height: min(hypot(w, h) * 0.6, 2.4 * h + 80))
            // 卷起处一道弧形暗影（纸在这里弯进卷轴）
            let curl = CAGradientLayer()
            curl.anchorPoint = CGPoint(x: 1, y: 0.5)
            curl.bounds = CGRect(x: 0, y: 0, width: 22, height: h)
            curl.startPoint = CGPoint(x: 0, y: 0.5)
            curl.endPoint = CGPoint(x: 1, y: 0.5)
            curl.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: dark ? 0.55 : 0.2)]
            clip.addSublayer(curl)
            show.tracks.append(.number(clip, "bounds.size.width", L) { Double(w) * (1 - P($0).roll) })
            show.tracks.append(.number(clip, "opacity", L) { P($0).slipAlpha })
            show.tracks.append(.position(curl, L) { CGPoint(x: w * CGFloat(1 - P($0).roll), y: h / 2) })
            show.tracks.append(.number(curl, "opacity", L) { P($0).rodAlpha })

            // 卷轴：在纸笺右缘现出，跟着卷起处左移，卷进的纸越多越粗（12 → 18pt）
            let rod = RollerLayer(height: h + 10, dark: dark)
            below.addSublayer(rod.root)
            show.tracks.append(.position(rod.root, L) { CGPoint(x: slip.minX + w * CGFloat(1 - P($0).roll), y: slip.midY) })
            show.tracks.append(.number(rod.root, "opacity", L) { P($0).rodAlpha * (1 - progress($0, 0.895, 0.905)) })
            show.tracks += rod.widthTracks(L) { 12 + 6 * P($0).rodWidth }
            // 卷起时，卷轴边上飘起点点灵光（本类颜色掺金），往上飘散
            let sparkTone = accent.mixed(with: .gold, 0.5)
            for k in 0..<8 {
                let born = 0.42 + 0.055 * Double(k)
                let x0 = slip.minX + w * CGFloat(1 - P(born).roll)
                let y0 = slip.minY - 5 + (h + 10) * CGFloat(0.1 + 0.8 * RitualTimeline.noise(k, 91))
                let rise = CGFloat(16 + 22 * RitualTimeline.noise(k, 92)), drift = CGFloat((RitualTimeline.noise(k, 93) - 0.5) * 14)
                let mote = sprite(sparkTone, side: CGFloat(9 + 6 * RitualTimeline.noise(k, 94)), at: CGPoint(x: x0, y: y0), core: true)
                below.addSublayer(mote)
                show.tracks.append(.position(mote, L) { t in
                    let f = progress(t, born, born + 0.4)
                    return CGPoint(x: x0 + drift * CGFloat(f), y: y0 - rise * CGFloat(RitualTimeline.easeOutCubic(f)))
                })
                show.tracks.append(.number(mote, "opacity", L) { t in
                    progress(t, born, born + 0.05) * (1 - RitualTimeline.smoothstep(progress(t, born + 0.12, born + 0.4)))
                })
            }
        } else {
            // 没有落笔框（问道页存档）：只有朱印、印泥晕和墨晕
            blooms(in: below, seal: sealCenter, height: 230)
        }

        // 印泥晕：印下泛起一圈朱砂淡晕（0.3 → 0.9 倍）
        let halo = CALayer()
        halo.contents = RitualArt.blot(RitualRGB(r: 0.70, g: 0.20, b: 0.16), variant: 3)
        halo.contentsGravity = .resize
        let haloSide = SealLayerFactory.size(for: "入卷").height * 2.2
        halo.bounds = CGRect(x: 0, y: 0, width: haloSide, height: haloSide)
        halo.position = sealCenter
        below.addSublayer(halo)
        show.tracks.append(.number(halo, "transform.scale", L) { Self.lerp(0.3, 0.9, P($0).haloScale) })
        show.tracks.append(.number(halo, "opacity", L) { 0.28 * P($0).haloAlpha })

        // 墨星：5 点细小墨星从印下向左上溅出 30–60pt 后淡去
        for k in 0..<5 {
            let angle = [196.0, 212, 228, 243, 257][k] * .pi / 180
            let distance = 30 + 30 * RitualTimeline.noise(k, 61)
            let side = CGFloat(3 + 3 * RitualTimeline.noise(k, 62))
            let drop = CALayer()
            drop.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            drop.cornerRadius = side / 2
            drop.backgroundColor = ink.rgb.cg(dark ? 0.75 : 0.7)
            let start = CGPoint(x: sealCenter.x - 8, y: sealCenter.y - 14)
            drop.position = start
            below.addSublayer(drop)
            show.tracks.append(.position(drop, L) { t in
                let d = CGFloat(distance * P(t).splatter)
                return CGPoint(x: start.x + CGFloat(cos(angle)) * d, y: start.y + CGFloat(sin(angle)) * d)
            })
            show.tracks.append(.number(drop, "opacity", L) { P($0).splatterAlpha })
            show.tracks.append(.number(drop, "transform.scale", L) { 1 - 0.45 * P($0).splatter })
        }

        // 卷成的小卷：缩小、转成横卷，沿往上拱的弧线化作一道灵光飞向“修行录”，拖着本类颜色的尾迹
        guard let slip else { return show }
        let from = CGPoint(x: slip.minX, y: slip.midY)
        let scroll = CALayer()
        scroll.bounds = .zero
        scroll.position = from
        let turn = CALayer()
        turn.bounds = .zero
        let shrink = CALayer()
        shrink.bounds = .zero
        let glow = sprite(accent.mixed(with: RitualRGB.gold, 0.35), side: 60)
        let core = sprite(RitualRGB(r: 1, g: 0.97, b: 0.88), side: 20, core: true)
        let body = RollerLayer(height: slip.height + 10, dark: dark)
        body.setWidth(18)
        let tie = CALayer()
        tie.bounds = CGRect(x: 0, y: 0, width: 22, height: 5)
        tie.backgroundColor = accent.cg(0.95)
        tie.cornerRadius = 1.5
        shrink.addSublayer(body.root)
        shrink.addSublayer(tie)
        turn.addSublayer(glow)
        turn.addSublayer(shrink)
        turn.addSublayer(core)
        scroll.addSublayer(turn)

        if let targetRow = inscription.target.map(localRect) {
            let to = Self.ornamentCenter(of: targetRow)
            let arc = ArcPath(from: from, to: to, swirl: to.x <= from.x ? 0.55 : -0.55)
            let endScale = min(0.3, 30 / (slip.height + 10))
            // 尾迹：同一条路径，前端跟着小卷，末端晚 150 ms 跟上；外面一层宽而淡的光，里面一线亮色
            for (width, alpha) in [(CGFloat(10), 0.22), (CGFloat(3), 0.95)] {
                let trail = CAShapeLayer()
                trail.path = arc.path
                trail.fillColor = nil
                trail.strokeColor = accent.mixed(with: .white, dark ? 0.25 : 0).cg(alpha)
                trail.lineWidth = width
                trail.lineCap = .round
                trail.lineJoin = .round
                if width < 5 {
                    trail.shadowColor = RitualRGB.gold.cg(1)
                    trail.shadowOpacity = 0.9
                    trail.shadowRadius = 6
                    trail.shadowOffset = .zero
                }
                above.addSublayer(trail)
                show.tracks.append(.number(trail, "strokeEnd", L) { arc.fraction(P($0).flight) })
                show.tracks.append(.number(trail, "strokeStart", L) { arc.fraction(P($0).trail) })
                show.tracks.append(.number(trail, "opacity", L) { P($0).trailAlpha })
            }
            above.addSublayer(scroll)
            show.tracks.append(.position(scroll, L) { arc.point(P($0).flight) })
            show.tracks.append(.number(scroll, "opacity", L) { $0 >= 0.9 ? P($0).rodAlpha : 0 })
            show.tracks.append(.number(turn, "transform.rotation.z", L) { -.pi / 2 * RitualTimeline.smoothstep(P($0).flight / 0.5) })
            show.tracks.append(.number(shrink, "transform.scale", L) { Self.lerp(1, Double(endScale), P($0).flightScale) })
            show.tracks.append(.number(glow, "opacity", L) { 0.9 * P($0).flightAlpha })
            show.tracks.append(.number(core, "opacity", L) { P($0).flightAlpha })

            // 抵达：“修行录”小物处一闪灵光，泛起一圈金色涟漪（半径 22 → 42）
            let flash = sprite(RitualRGB.gold, side: 76, at: to)
            above.addSublayer(flash)
            show.tracks.append(.number(flash, "opacity", L) { 0.85 * P($0).arrivalGlow })
            show.tracks.append(.number(flash, "transform.scale", L) { 0.6 + 0.5 * P($0).arrivalGlow })
            let ring = CALayer()
            ring.bounds = CGRect(x: 0, y: 0, width: 84, height: 84)
            ring.cornerRadius = 42
            ring.borderColor = RitualRGB.gold.cg(1)
            ring.position = to
            above.addSublayer(ring)
            let ringScale: (Double) -> Double = { (22 + 20 * P($0).pulseRadius) / 42 }
            show.tracks.append(.number(ring, "transform.scale", L) { ringScale($0) })
            show.tracks.append(.number(ring, "borderWidth", L) { 2.6 * (1 - 0.5 * P($0).pulseRadius) / ringScale($0) })
            show.tracks.append(.number(ring, "opacity", L) { 0.8 * P($0).pulseAlpha })
        } else {
            // 没有“修行录”的位置：卷好的小卷在原地淡去
            above.addSublayer(scroll)
            glow.opacity = 0
            core.opacity = 0
            show.tracks.append(.number(scroll, "opacity", L) { $0 >= 0.9 ? P($0).strandedAlpha : 0 })
        }
        return show
    }

    // MARK: 功课圆满

    private func buildConsummation(_ consummation: EffectsCenter.Consummation) -> Show {
        let L = RitualTimeline.consummationLength
        let P = RitualTimeline.consummation(at:)
        let show = Show(kind: .consummation, length: L)
        let layer = group(in: upper, show)
        let W = size.width, H = size.height
        let dantianRect = consummation.dantian.map(localRect)
        // 拿不到徽记位置时（理论上不会）：汇聚点改为正文区中上部
        let D = dantianRect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: 300 + (W - 300) / 2, y: H * 0.3)
        let bannerLeft = (dantianRect?.maxX ?? D.x - 116) + 10
        let tones = RitualPalette.motes(dark)

        // 四方灵光：每边 12 点，每点带 3 节渐小渐淡的彗尾（各晚 25 ms）
        let count = 48, moteLength = 0.75
        for i in 0..<count {
            let m = RitualTimeline.mote(i, of: count)
            let along = CGFloat(m.along), inset: CGFloat = 6
            let start: CGPoint = switch m.edge {
            case 0: CGPoint(x: along * W, y: inset)
            case 1: CGPoint(x: W - inset, y: along * H)
            case 2: CGPoint(x: along * W, y: H - inset)
            default: CGPoint(x: inset, y: along * H)
            }
            let arc = ArcPath(from: start, to: D, swirl: m.swirl, segments: 32)
            // 彗尾的每一节都是领头那颗晚 12 ms 的副本：关键帧只取样一次，各节只推后开始时刻；渐淡放在外面那层的不透明度上
            for k in 0..<6 {
                let lag = 0.012 * Double(k)
                let side = CGFloat(34 * m.size) * pow(0.86, CGFloat(k))
                let holder = CALayer()
                holder.anchorPoint = .zero
                holder.bounds = .zero
                holder.position = .zero
                holder.opacity = Float(1 - 0.15 * Double(k))
                let dot = sprite(tones[m.tone], side: side, at: start, core: k == 0)
                holder.addSublayer(dot)
                layer.addSublayer(holder)
                show.tracks.append(RitualTrack.position(dot, moteLength, rate: 50) {
                    arc.point(RitualTimeline.moteTravel(delay: m.delay, at: $0 - lag))
                }.shared("mote\(i).p", lag: lag))
                show.tracks.append(RitualTrack.number(dot, "opacity", moteLength, rate: 50) {
                    RitualTimeline.moteAlpha(delay: m.delay, at: $0 - lag) * RitualTimeline.moteEnvelope(at: $0 - lag)
                }.shared("mote\(i).o", lag: lag))
                show.tracks.append(RitualTrack.number(dot, "transform.scale", moteLength, rate: 50) {
                    let travel = RitualTimeline.moteTravel(delay: m.delay, at: $0 - lag)
                    return 1 - 0.6 * travel * travel
                }.shared("mote\(i).s", lag: lag))
            }
        }

        // 刚点的打卡圈升起一缕更亮的玉色灵线
        if let source = consummation.source.map(localPoint) {
            let arc = ArcPath(from: source, to: D, swirl: source.x >= D.x ? 0.45 : -0.45)
            let jade = RitualPalette.thread(dark)
            let thread = CAShapeLayer()
            thread.path = arc.path
            thread.fillColor = nil
            thread.strokeColor = jade.cg(0.95)
            thread.lineWidth = 2.5
            thread.lineCap = .round
            thread.shadowColor = jade.cg(1)
            thread.shadowOpacity = 0.9
            thread.shadowRadius = 6
            thread.shadowOffset = .zero
            layer.addSublayer(thread)
            show.tracks.append(.number(thread, "strokeEnd", L) { arc.fraction(P($0).thread) })
            show.tracks.append(.number(thread, "strokeStart", L) { arc.fraction(P($0).threadTail) })
            show.tracks.append(.number(thread, "opacity", L) { P($0).threadAlpha })
            let head = sprite(jade, side: 28, at: source, core: true)
            layer.addSublayer(head)
            show.tracks.append(.position(head, L) { arc.point(P($0).thread) })
            show.tracks.append(.number(head, "opacity", L) { P($0).threadAlpha })
        }

        // 灵光汇入时，丹田先慢慢聚起一团光，接着“一亮”
        let gathering = sprite(RitualRGB.gold, side: 120, at: D)
        layer.addSublayer(gathering)
        show.tracks.append(.number(gathering, "opacity", L) { t in
            0.75 * RitualTimeline.smoothstep(RitualTimeline.progress(P(t).gather, 0.35, 1)) * (1 - RitualTimeline.progress(t, 0.62, 0.78))
        })
        show.tracks.append(.number(gathering, "transform.scale", L) { 0.45 + 0.55 * P($0).gather })

        // 丹田一亮：一团金光、一圈金环（半径 36 → 96，线宽 2.5 → 0.5）、八道短芒转过 20° 后淡去
        let flare = sprite(RitualRGB.gold, side: 150, at: D)
        let flareCore = sprite(RitualRGB(r: 1, g: 0.95, b: 0.8), side: 58, at: D, core: true)
        layer.addSublayer(flare)
        layer.addSublayer(flareCore)
        show.tracks.append(.number(flare, "transform.scale", L) { 0.55 + 0.75 * P($0).flare })
        show.tracks.append(.number(flare, "opacity", L) { 0.9 * P($0).flareAlpha })
        show.tracks.append(.number(flareCore, "opacity", L) { 0.95 * P($0).flareAlpha })
        let ring = CALayer()
        ring.bounds = CGRect(x: 0, y: 0, width: 192, height: 192)
        ring.cornerRadius = 96
        ring.borderColor = RitualRGB.gold.cg(1)
        ring.position = D
        layer.addSublayer(ring)
        let ringScale: (Double) -> Double = { (36 + 60 * P($0).ringRadius) / 96 }
        show.tracks.append(.number(ring, "transform.scale", L) { ringScale($0) })
        show.tracks.append(.number(ring, "borderWidth", L) { (2.5 - 2 * P($0).ringRadius) / ringScale($0) })
        show.tracks.append(.number(ring, "opacity", L) { P($0).ringAlpha })
        let rays = CALayer()
        rays.bounds = .zero
        rays.position = D
        for j in 0..<8 {
            let theta = Double(j) * .pi / 4 + .pi / 8
            let ray = CAGradientLayer()
            ray.bounds = CGRect(x: 0, y: 0, width: 2.5, height: 30)
            ray.colors = [RitualRGB.gold.cg(0), RitualRGB.gold.cg(0.95), RitualRGB.gold.cg(0)]
            ray.locations = [0, 0.45, 1]
            ray.position = CGPoint(x: cos(theta) * 58, y: sin(theta) * 58)
            ray.setAffineTransform(CGAffineTransform(rotationAngle: theta + .pi / 2))
            rays.addSublayer(ray)
        }
        layer.addSublayer(rays)
        show.tracks.append(.number(rays, "transform.rotation.z", L) { P($0).rays * .pi / 9 })
        show.tracks.append(.number(rays, "opacity", L) { P($0).raysAlpha })

        // 金符：从徽记右侧向右展开一道 232 × 52 的横幅符箓，左轴先现、右轴随展开右移，字依次显出，白光扫过，再上浮淡去
        let bannerWidth: CGFloat = 232, bannerHeight: CGFloat = 52
        let banner = CALayer()
        banner.bounds = .zero
        banner.position = CGPoint(x: bannerLeft, y: D.y)
        layer.addSublayer(banner)
        show.tracks.append(.position(banner, L) { CGPoint(x: bannerLeft, y: D.y - 8 * CGFloat(P($0).bannerRise)) })
        show.tracks.append(.number(banner, "opacity", L) { P($0).bannerAlpha })
        let halo = sprite(RitualRGB.gold, side: 1, at: CGPoint(x: bannerWidth / 2, y: 0))
        halo.bounds = CGRect(x: 0, y: 0, width: bannerWidth + 110, height: bannerHeight + 70)
        banner.addSublayer(halo)
        let haloStrength = dark ? 0.55 : 0.4
        show.tracks.append(.number(halo, "opacity", L) { haloStrength * P($0).unroll })
        let clip = CALayer()
        clip.anchorPoint = CGPoint(x: 0, y: 0.5)
        clip.bounds = CGRect(x: 0, y: 0, width: bannerWidth, height: bannerHeight)
        clip.position = .zero
        clip.masksToBounds = true
        clip.cornerRadius = 3
        banner.addSublayer(clip)
        show.tracks.append(.number(clip, "bounds.size.width", L) { Double(bannerWidth) * P($0).unroll })
        let paper = CAGradientLayer()
        paper.frame = CGRect(x: 0, y: 0, width: bannerWidth, height: bannerHeight)
        paper.colors = RitualPalette.bannerPaper(dark)
        paper.startPoint = CGPoint(x: 0.5, y: 0)
        paper.endPoint = CGPoint(x: 0.5, y: 1)
        clip.addSublayer(paper)
        // 金纸上缘一层淡淡的光泽
        let sheen = CAGradientLayer()
        sheen.frame = paper.frame
        sheen.colors = [CGColor(gray: 1, alpha: dark ? 0.12 : 0.35), CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0)]
        sheen.locations = [0, 0.45, 1]
        clip.addSublayer(sheen)
        let ink = RitualPalette.bannerInk(dark)
        for (inset, width, alpha) in [(CGFloat(3), CGFloat(1.2), 0.7), (CGFloat(7), CGFloat(0.8), 0.4)] {
            let frame = CALayer()
            frame.frame = CGRect(x: 0, y: 0, width: bannerWidth, height: bannerHeight).insetBy(dx: inset, dy: inset)
            frame.borderWidth = width
            frame.borderColor = ink.cg(alpha)
            frame.cornerRadius = 2
            clip.addSublayer(frame)
        }
        // 内框四角各一点朱砂菱花
        for corner in [CGPoint(x: 7, y: 7), CGPoint(x: bannerWidth - 7, y: 7), CGPoint(x: 7, y: bannerHeight - 7),
                       CGPoint(x: bannerWidth - 7, y: bannerHeight - 7)] {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
            dot.backgroundColor = ink.cg(0.6)
            dot.position = corner
            dot.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 4))
            clip.addSublayer(dot)
        }
        let font = RitualPalette.songti(24, bold: true)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        for (i, ch) in ["功", "课", "圆", "满"].enumerated() {
            let glyph = CATextLayer()
            glyph.string = RitualPalette.glyph(ch, font: font, color: ink.cg(1))
            glyph.alignmentMode = .center
            glyph.contentsScale = contentsScale
            glyph.bounds = CGRect(x: 0, y: 0, width: 32, height: lineHeight)
            glyph.position = CGPoint(x: bannerWidth / 2 + (CGFloat(i) - 1.5) * 44, y: bannerHeight / 2 + 1)
            // 朱砂字透一点金光（深色下更明显）
            glyph.shadowColor = RitualRGB.gold.cg(1)
            glyph.shadowOpacity = dark ? 0.6 : 0.3
            glyph.shadowRadius = 4
            glyph.shadowOffset = .zero
            clip.addSublayer(glyph)
            let from = 0.2 * Double(i)
            show.tracks.append(.number(glyph, "opacity", L) { RitualTimeline.smoothstep(RitualTimeline.progress(P($0).textReveal, from, from + 0.35)) })
            show.tracks.append(.number(glyph, "transform.scale", L) {
                1.18 - 0.18 * RitualTimeline.easeOutCubic(RitualTimeline.progress(P($0).textReveal, from, from + 0.35))
            })
        }
        let glint = CAGradientLayer()
        glint.bounds = CGRect(x: 0, y: 0, width: 44, height: 110)
        glint.startPoint = CGPoint(x: 0, y: 0.5)
        glint.endPoint = CGPoint(x: 1, y: 0.5)
        glint.colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: dark ? 0.45 : 0.7), CGColor(gray: 1, alpha: 0)]
        glint.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 9))
        glint.position = CGPoint(x: -40, y: bannerHeight / 2)
        clip.addSublayer(glint)
        show.tracks.append(.position(glint, L) { CGPoint(x: -40 + (bannerWidth + 80) * CGFloat(P($0).glint), y: bannerHeight / 2) })
        show.tracks.append(.number(glint, "opacity", L) { P($0).glintAlpha })
        // 两根轴：左轴先现，右轴随展开右移
        let leftAxis = RollerLayer(height: bannerHeight + 10, dark: dark)
        leftAxis.setWidth(7)
        leftAxis.root.position = .zero
        banner.addSublayer(leftAxis.root)
        let rightAxis = RollerLayer(height: bannerHeight + 10, dark: dark)
        rightAxis.setWidth(7)
        banner.addSublayer(rightAxis.root)
        show.tracks.append(.position(rightAxis.root, L) { CGPoint(x: bannerWidth * CGFloat(P($0).unroll), y: 0) })

        // 金屑：符箓上缘散出 10 点，往上飘
        for k in 0..<10 {
            let x0 = bannerLeft + 18 + CGFloat(k) * 21.8
            let rise = CGFloat(14 + 22 * RitualTimeline.noise(k, 71))
            let drift = CGFloat((RitualTimeline.noise(k, 72) - 0.5) * 14)
            let spark = sprite(RitualRGB.gold, side: CGFloat(8 + 5 * RitualTimeline.noise(k, 73)), core: true)
            layer.addSublayer(spark)
            show.tracks.append(.position(spark, L) { t in
                let p = P(t)
                let s = CGFloat(p.sparks)
                return CGPoint(x: x0 + drift * s, y: D.y - bannerHeight / 2 - 8 * CGFloat(p.bannerRise) - rise * s)
            })
            show.tracks.append(.number(spark, "opacity", L) { P($0).sparkAlpha })
        }
        return show
    }
}

/// 卷轴：金褐色圆柱渐变 + 两端深一档的小圆帽（纸卷合拢的卷轴、飞行的小卷、符箓两轴共用）
@MainActor
private final class RollerLayer {
    let root = CALayer()
    private let body = CAGradientLayer()
    private let caps = [CALayer(), CALayer()]
    private let height: CGFloat

    init(height: CGFloat, dark: Bool) {
        self.height = height
        root.bounds = .zero
        body.colors = RitualPalette.rod(dark)
        body.locations = [0, 0.45, 1]
        body.startPoint = CGPoint(x: 0, y: 0.5)
        body.endPoint = CGPoint(x: 1, y: 0.5)
        body.cornerRadius = 2
        body.position = .zero
        root.addSublayer(body)
        for (index, cap) in caps.enumerated() {
            cap.backgroundColor = RitualPalette.rodCap(dark)
            cap.cornerRadius = 2.5
            cap.position = CGPoint(x: 0, y: (index == 0 ? -1 : 1) * height / 2)
            root.addSublayer(cap)
        }
        setWidth(12)
    }

    func setWidth(_ width: CGFloat) {
        body.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        for cap in caps { cap.bounds = CGRect(x: 0, y: 0, width: width + 5, height: 6) }
    }

    /// 粗细随时间变（纸卷合拢时卷进的纸越多越粗）
    fileprivate func widthTracks(_ length: Double, _ width: @escaping (Double) -> Double) -> [RitualTrack] {
        [.number(body, "bounds.size.width", length) { width($0) }]
            + caps.map { cap in .number(cap, "bounds.size.width", length) { width($0) + 5 } }
    }
}

// MARK: - 朱印图层

/// 朱印的 Core Animation 版（主窗口落印与随手记小印共用）。外观照 SealStamp：朱砂 (0.70,0.20,0.16) 深浅同色、
/// 尺寸算法相同、字用与 Theme.songti(28, .bold) 同一个字体（没有宋体时同样回退衬线体）
enum SealLayerFactory {
    static func size(for text: String) -> CGSize {
        let count = max(1, min(4, text.count))
        return CGSize(width: 64, height: 24 + CGFloat(count) * 36)
    }

    static func make(text: String, scale: CGFloat, contentsScale: CGFloat = 2) -> CALayer {
        let base = size(for: text)
        let w = base.width * scale, h = base.height * scale
        let body = CALayer()
        body.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        body.cornerRadius = 7 * scale
        body.backgroundColor = RitualPalette.cinnabar(0.92)
        body.shadowColor = RitualPalette.cinnabar(1)
        body.shadowOpacity = 0
        body.shadowRadius = 12 * scale
        body.shadowOffset = .zero
        body.shadowPath = CGPath(roundedRect: body.bounds, cornerWidth: 7 * scale, cornerHeight: 7 * scale, transform: nil)
        let frame = CALayer()
        frame.frame = body.bounds.insetBy(dx: 5 * scale, dy: 5 * scale)
        frame.cornerRadius = 4 * scale
        frame.borderWidth = 1.5 * scale
        frame.borderColor = CGColor(gray: 1, alpha: 0.75)
        body.addSublayer(frame)
        let font = RitualPalette.songti(28 * scale, bold: true)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let chars = Array(text.prefix(4))
        let top = (h - CGFloat(chars.count) * 36 * scale) / 2
        for (i, ch) in chars.enumerated() {
            let glyph = CATextLayer()
            glyph.string = RitualPalette.glyph(String(ch), font: font, color: CGColor(gray: 1, alpha: 0.95))
            glyph.alignmentMode = .center
            glyph.contentsScale = contentsScale
            let rowCenter = top + (CGFloat(i) + 0.5) * 36 * scale
            glyph.frame = CGRect(x: 0, y: rowCenter - lineHeight / 2, width: w, height: lineHeight)
            body.addSublayer(glyph)
        }
        return body
    }
}

// MARK: - 随手记小印

/// 随手记浮窗里就地盖的小印（朱印缩到 0.45 倍）：落定时一圈小涟漪，印下一小团墨晕
@MainActor
final class MiniSealController {
    fileprivate weak var view: MiniSealHostView?

    /// animated 为假（关动效）时什么都不画
    func stamp(_ text: String, animated: Bool) {
        guard animated else { return }
        view?.stamp(text)
    }
}

struct MiniSealView: NSViewRepresentable {
    var controller: MiniSealController

    func makeNSView(context: Context) -> MiniSealHostView {
        let view = MiniSealHostView(frame: .zero)
        controller.view = view
        return view
    }

    func updateNSView(_ view: MiniSealHostView, context: Context) {
        controller.view = view
    }
}

final class MiniSealHostView: NSView {
    private var current: CALayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// 从 2 倍、−14° 弹簧落到 1 倍、−6°（同一套弹簧），0.5 秒一圈小涟漪，0.4 秒一小团墨晕；之后照主窗口的节奏淡成印痕再散去
    func stamp(_ text: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let built = build(text)
        var cache: [String: CAKeyframeAnimation] = [:]
        let now = layer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()
        for track in built?.tracks ?? [] { track.animate(cache: &cache, now: now) }
        CATransaction.commit()
        CATransaction.flush()
        guard let group = built?.group else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + RitualTimeline.sealLength + 0.1) { [weak self, weak group] in
            guard let group, self?.current === group else { return }
            group.removeFromSuperlayer()
            self?.current = nil
        }
    }

    /// 离屏定格：把小印摆到 t 时刻
    func pose(_ text: String, at t: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for track in build(text)?.tracks ?? [] { track.pose(at: t) }
        CATransaction.commit()
    }

    private func build(_ text: String) -> (group: CALayer, tracks: [RitualTrack])? {
        guard let host = layer else { return nil }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scale: CGFloat = 0.45
        let sealSize = SealLayerFactory.size(for: text)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let length = RitualTimeline.sealLength
        let P = RitualTimeline.seal(at:)
        current?.removeFromSuperlayer()
        let group = CALayer()
        group.bounds = .zero
        group.position = .zero
        group.anchorPoint = .zero
        host.addSublayer(group)
        current = group
        var tracks: [RitualTrack] = []
        let ink = RitualPalette.ink(dark)
        let blot = CALayer()
        blot.contents = RitualArt.blot(ink.rgb, variant: 1)
        blot.contentsGravity = .resize
        blot.bounds = CGRect(x: 0, y: 0, width: 62, height: 46)
        blot.position = CGPoint(x: center.x - 4, y: center.y + 4)
        group.addSublayer(blot)
        tracks.append(.number(blot, "transform.scale", length) { 0.4 + 0.7 * RitualTimeline.easeOutCubic(RitualTimeline.progress($0, 0.15, 0.55)) })
        tracks.append(.number(blot, "opacity", length) {
            ink.alpha * 1.6 * RitualTimeline.progress($0, 0.15, 0.2) * (1 - RitualTimeline.smoothstep(RitualTimeline.progress($0, 0.25, 0.55)))
        })
        let ripple = CALayer()
        let side = sealSize.height * scale
        ripple.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        ripple.cornerRadius = side / 2
        ripple.borderWidth = 1.2
        ripple.borderColor = RitualPalette.cinnabar(0.5)
        ripple.position = center
        group.addSublayer(ripple)
        tracks.append(.number(ripple, "transform.scale", length) { 0.7 + 0.9 * RitualTimeline.easeOutCubic(RitualTimeline.progress($0, 0.16, 0.66)) })
        tracks.append(.number(ripple, "opacity", length) {
            $0 < 0.16 ? 0 : 0.7 * (1 - RitualTimeline.easeOutCubic(RitualTimeline.progress($0, 0.16, 0.66)))
        })
        let rotor = CALayer()
        rotor.bounds = .zero
        rotor.position = center
        let scaler = CALayer()
        scaler.bounds = .zero
        let body = SealLayerFactory.make(text: text, scale: scale, contentsScale: window?.backingScaleFactor ?? 2)
        scaler.addSublayer(body)
        rotor.addSublayer(scaler)
        group.addSublayer(rotor)
        tracks.append(.number(rotor, "transform.rotation.z", length) { (-14 + 8 * P($0).landing) * .pi / 180 })
        tracks.append(.number(scaler, "transform.scale", length) { 2 - P($0).landing })
        tracks.append(.number(body, "opacity", length) { P($0).alpha })
        tracks.append(.number(body, "shadowOpacity", length) { 0.45 * P($0).shadow })
        return (group, tracks)
    }
}

// MARK: - 颜色与小图

/// sRGB 颜色（仪式里的颜色都写成明确的浅 / 深两套，不靠动态 NSColor 在 CALayer 里自动换色）
struct RitualRGB: Equatable {
    var r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    func cg(_ alpha: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    func mixed(with other: RitualRGB, _ t: Double) -> RitualRGB {
        RitualRGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    /// 灵光金：深浅同色的亮金（发光处）
    static let gold = RitualRGB(r: 1, g: 0.84, b: 0.5)
    static let white = RitualRGB(r: 1, g: 1, b: 1)
}

/// 纸、墨、朱砂、金、玉、青的浅深两套 sRGB
enum RitualPalette {
    static func cinnabar(_ alpha: Double) -> CGColor { CGColor(srgbRed: 0.70, green: 0.20, blue: 0.16, alpha: alpha) }
    /// 卡片纸色（纸笺）
    static func card(_ dark: Bool) -> CGColor { RitualRGB(hex: dark ? 0x172A2C : 0xFFFDF8).cg(1) }
    /// 落笔框底（卡片色上叠纸色 0.6）：衬纸
    static func backing(_ dark: Bool) -> CGColor { RitualRGB(hex: dark ? 0x122022 : 0xF7F7F1).cg(1) }
    static func line(_ dark: Bool) -> CGColor { RitualRGB(hex: dark ? 0x2D4141 : 0xDCE1D4).cg(1) }
    /// 墨晕：浅色是墨绿 #24493D、深色是月下灵墨（淡玉 #A3C5AE）。设计稿是 α 0.20 / 0.14，渲染出来深色几乎看不见、
    /// 浅色只是一层灰，各提到 0.26 / 0.24（墨团图边缘本来就是渐淡的，最浓处只在中心一小块）
    static func ink(_ dark: Bool) -> (rgb: RitualRGB, alpha: Double) {
        dark ? (RitualRGB(hex: 0xA3C5AE), 0.24) : (RitualRGB(hex: 0x24493D), 0.26)
    }
    /// 本类颜色：日记玉、灵感金、复盘青（与 Theme.color(for: JournalKind) 相同）
    static func kind(_ kind: JournalKind?, dark: Bool) -> RitualRGB {
        switch kind ?? .diary {
        case .diary: RitualRGB(hex: dark ? 0xA3C5AE : 0x427560)
        case .note: RitualRGB(hex: dark ? 0xD2B682 : 0x9B7951)
        case .review: RitualRGB(hex: dark ? 0x93B3CF : 0x4C6E8E)
        }
    }
    /// 卷轴：金褐色圆柱
    static func rod(_ dark: Bool) -> [CGColor] {
        (dark ? [0x5A4526, 0xC9AE78, 0x4A381E] : [0x8A6A3E, 0xE3C98F, 0x7A5A30]).map { RitualRGB(hex: UInt32($0)).cg(1) }
    }
    static func rodCap(_ dark: Bool) -> CGColor { RitualRGB(hex: dark ? 0x3A2C17 : 0x6A4E2A).cg(1) }
    /// 符箓金纸（上 → 下）
    static func bannerPaper(_ dark: Bool) -> [CGColor] {
        (dark ? [0x4B3E22, 0x34291A] : [0xF7E9C4, 0xEBCF8E]).map { RitualRGB(hex: UInt32($0)).cg(1) }
    }
    /// 符箓上的朱砂（边框与字）
    static func bannerInk(_ dark: Bool) -> RitualRGB { RitualRGB(hex: dark ? 0xE39A8E : 0xA9483C) }
    /// 灵光的金、玉、青（与 SpiritPalette.motes 相同）
    static func motes(_ dark: Bool) -> [RitualRGB] {
        dark ? [RitualRGB(r: 0.93, g: 0.82, b: 0.56), RitualRGB(r: 0.66, g: 0.90, b: 0.78), RitualRGB(r: 0.72, g: 0.84, b: 0.98)]
             : [RitualRGB(r: 0.72, g: 0.55, b: 0.27), RitualRGB(r: 0.29, g: 0.55, b: 0.43), RitualRGB(r: 0.85, g: 0.66, b: 0.36)]
    }
    /// 打卡圈升起的玉色灵线（比灵光更亮一档）
    static func thread(_ dark: Bool) -> RitualRGB { dark ? RitualRGB(r: 0.72, g: 0.96, b: 0.84) : RitualRGB(r: 0.26, g: 0.6, b: 0.46) }

    /// 宋体（与 Theme.songti 同一个字体族；没有宋体时回退衬线体）
    static func songti(_ size: CGFloat, bold: Bool) -> NSFont {
        if let font = NSFontManager.shared.font(withFamily: "Songti SC", traits: bold ? .boldFontMask : [], weight: bold ? 9 : 5, size: size) {
            return font
        }
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    /// 纸笺上的正文：14pt 系统字体、行距 3（与 PaperEditor 相同），正文色 Theme.text
    static func slipText(_ text: String, dark: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.lineBreakMode = .byWordWrapping
        let color = RitualRGB(hex: dark ? 0xCCDCD3 : 0x35463E).cg(1)
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor(cgColor: color) ?? .textColor,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            .paragraphStyle: style,
        ])
    }

    /// 单个字（朱印、符箓）：CATextLayer 用 CoreText 画，前景色两种键都给
    static func glyph(_ text: String, font: NSFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .white,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
    }
}

/// 仪式用的小图：第一次用到时用 CoreGraphics 烘好（颜色烘在图里），之后常驻
@MainActor
enum RitualArt {
    private static var cache: [String: CGImage] = [:]
    private static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func key(_ rgb: RitualRGB) -> String { "\(Int(rgb.r * 255)),\(Int(rgb.g * 255)),\(Int(rgb.b * 255))" }

    private static func cached(_ key: String, _ make: () -> CGImage?) -> CGImage? {
        if let hit = cache[key] { return hit }
        let image = make()
        if let image { cache[key] = image }
        return image
    }

    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// 柔光点（64×64）：亮心约占两成，向外淡尽
    static func glow(_ rgb: RitualRGB) -> CGImage? {
        cached("glow|" + key(rgb)) { radial(rgb, alphas: [1, 0.55, 0.18, 0], at: [0, 0.18, 0.45, 1]) }
    }

    /// 亮心更实的光点（灵光的头、金屑、丹田的光心）
    static func core(_ rgb: RitualRGB) -> CGImage? {
        cached("core|" + key(rgb)) { radial(rgb.mixed(with: .white, 0.35), alphas: [1, 0.9, 0.35, 0], at: [0, 0.16, 0.4, 1]) }
    }

    private static func radial(_ rgb: RitualRGB, alphas: [Double], at locations: [CGFloat]) -> CGImage? {
        let side = 64
        guard let ctx = context(side, side),
              let gradient = CGGradient(colorsSpace: space, colors: alphas.map { rgb.cg($0) } as CFArray, locations: locations) else { return nil }
        let c = CGPoint(x: 32, y: 32)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: 32, options: [])
        return ctx.makeImage()
    }

    /// 柔边墨团（256×256）：中心浓、边缘由一圈不规则的小墨团扰动，再加几十缕向外洇开的细纹（像墨落在宣纸上沿纤维渗开）
    static func blot(_ rgb: RitualRGB, variant: Int) -> CGImage? {
        let space = Self.space
        return cached("blot|\(variant)|" + key(rgb)) {
            let side = 256
            guard let ctx = context(side, side) else { return nil }
            let c = CGPoint(x: 128, y: 128)
            func soft(_ center: CGPoint, _ radius: CGFloat, _ alpha: Double) {
                guard let g = CGGradient(colorsSpace: space, colors: [rgb.cg(alpha), rgb.cg(alpha * 0.55), rgb.cg(0)] as CFArray,
                                         locations: [0, 0.5, 1]) else { return }
                ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
            }
            soft(c, 92, 0.95)
            for k in 0..<22 {
                let angle = Double(k) / 22 * 2 * .pi + RitualTimeline.noise(k + variant * 40, 81) * 0.4
                let distance = 52 + 34 * RitualTimeline.noise(k + variant * 40, 82)
                let radius = 18 + 26 * RitualTimeline.noise(k + variant * 40, 83)
                soft(CGPoint(x: c.x + CGFloat(cos(angle) * distance), y: c.y + CGFloat(sin(angle) * distance)), CGFloat(radius),
                     0.35 + 0.35 * RitualTimeline.noise(k + variant * 40, 84))
            }
            ctx.setLineCap(.round)
            for k in 0..<46 {
                let angle = RitualTimeline.noise(k + variant * 60, 85) * 2 * .pi
                let r0 = 60 + 30 * RitualTimeline.noise(k + variant * 60, 86)
                let r1 = r0 + 18 + 26 * RitualTimeline.noise(k + variant * 60, 87)
                ctx.setStrokeColor(rgb.cg(0.12 + 0.12 * RitualTimeline.noise(k + variant * 60, 88)))
                ctx.setLineWidth(CGFloat(0.8 + 1.4 * RitualTimeline.noise(k + variant * 60, 89)))
                ctx.move(to: CGPoint(x: c.x + CGFloat(cos(angle) * r0), y: c.y + CGFloat(sin(angle) * r0)))
                let bend = (RitualTimeline.noise(k + variant * 60, 90) - 0.5) * 0.3
                ctx.addLine(to: CGPoint(x: c.x + CGFloat(cos(angle + bend) * r1), y: c.y + CGFloat(sin(angle + bend) * r1)))
                ctx.strokePath()
            }
            // 边缘整体收成圆形淡出，图边不会露出硬边
            if let edge = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray,
                                     locations: [0, 0.78, 1]) {
                ctx.setBlendMode(.destinationIn)
                ctx.drawRadialGradient(edge, startCenter: c, startRadius: 0, endCenter: c, endRadius: 128, options: [])
            }
            return ctx.makeImage()
        }
    }
}
