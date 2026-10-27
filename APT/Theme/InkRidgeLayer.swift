import SwiftUI
import AppKit

// 三重水墨远山的 Core Animation 版：各自缓缓漂移，越近动得越多，有纵深感。
// 山脊路径与 SwiftUI 版（Spirit.swift 的 InkMountains，离屏截图仍用它）是同一个 RidgeShape，
// 时刻为 0 时三重山的位置与原来的静态画面完全相同。

/// 远山（InkMountains 在界面里用它）。ink 是已经按天色混好的墨色（a 不用，各重山的透明度另算）
struct InkRidgeView: NSViewRepresentable {
    var ink: SkyRGBA
    var dark: Bool
    var animated: Bool

    func makeNSView(context: Context) -> InkRidgeHostView { InkRidgeHostView() }
    func updateNSView(_ view: InkRidgeHostView, context: Context) {
        view.configure(ink: ink, dark: dark, animated: animated)
    }
}

final class InkRidgeHostView: NSView {
    /// 由远到近三重：种子、山脚线、起伏（与原来的三重山相同）、透明度、漂移振幅（pt）、周期（秒）
    static let ridges: [(seed: Int, baseline: CGFloat, amplitude: CGFloat, alpha: Double, drift: CGFloat, period: Double)] = [
        (7, 0.42, 0.32, 0.05, 14, 180),
        (20, 0.6, 0.3, 0.075, 22, 140),
        (33, 0.8, 0.26, 0.11, 32, 100),
    ]
    /// 山所在的高度（底部 360）
    static let height: CGFloat = 360

    private let stack = CALayer()
    /// 原来每重山各自从上到下渐隐（alpha → ×0.25 → 0），三重都在同一个 360 高的框里，
    /// 所以改成整组共用一个竖向渐变遮罩；三重山都很淡（≤ 0.13），先叠后遮与各自渐变只差千分之几
    private let fade = CAGradientLayer()
    private let shapes = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    private var lastWidth: CGFloat = 0
    private var dark: Bool?
    private var ink: SkyRGBA?
    /// 漂移动画的起点（本层时间）：暂停 / 继续、窗口尺寸变化都接着原来的相位，不跳回起点
    private var driftStart: CFTimeInterval?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fade.colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.25), CGColor(gray: 1, alpha: 0)]
        fade.locations = [0, 0.5, 1]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        stack.mask = fade
        for shape in shapes {
            shape.fillColor = nil
            stack.addSublayer(shape)
        }
        layer?.addSublayer(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let w = bounds.width
        guard w > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stack.frame = bounds
        fade.frame = stack.bounds
        // 路径只在宽度变化时重建（每重约 300 个点，很便宜）
        let rebuild = w != lastWidth
        lastWidth = w
        for (index, (shape, spec)) in zip(shapes, Self.ridges).enumerated() {
            let rect = CGRect(x: 0, y: 0, width: w * 1.2, height: Self.height)
            if rebuild {
                shape.path = RidgeShape(seed: spec.seed, baseline: spec.baseline, amplitude: spec.amplitude).path(in: rect).cgPath
            }
            // 与原来一样：1.2 倍宽、居中，再各自错开 (layer − 1) × 30
            shape.frame = CGRect(x: -w * 0.1 + CGFloat(index - 1) * 30, y: bounds.height - Self.height,
                                 width: rect.width, height: rect.height)
        }
        CATransaction.commit()
        attachDrift()
    }

    func configure(ink: SkyRGBA, dark: Bool, animated: Bool) {
        let flipped = self.dark != dark
        if flipped || self.ink != ink {
            self.dark = dark
            self.ink = ink
            CATransaction.begin()
            // 换色走 2.5 秒（在渲染进程里做）；第一次、切换深浅色、关掉动效时直接换
            if flipped || !animated {
                CATransaction.setDisableActions(true)
            } else {
                CATransaction.setAnimationDuration(2.5)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            }
            for (shape, spec) in zip(shapes, Self.ridges) {
                shape.fillColor = ink.with(a: spec.alpha * (dark ? 1.2 : 1)).cgColor
            }
            CATransaction.commit()
        }
        // 暂停 / 继续时保持当前画面，不跳回起点
        layer?.setPaused(!animated)
    }

    /// 每重山往返漂移（叠加在原位上的正弦偏移，与尺寸无关，挂一次就够）
    private func attachDrift() {
        guard let host = layer else { return }
        let start = driftStart ?? host.convertTime(CACurrentMediaTime(), from: nil)
        driftStart = start
        for (shape, spec) in zip(shapes, Self.ridges) where shape.animation(forKey: "drift") == nil {
            shape.add(SkyLayout.drift(amplitude: spec.drift, period: spec.period, from: start, maxFrames: 20), forKey: "drift")
        }
    }
}
