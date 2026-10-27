import SwiftUI
import AppKit

// EffectsCenter 里与“关键时刻的仪式”有关的类型与小工具（属性、stamp、perfectDayChanged 在 Effects.swift 里）。

extension EffectsCenter {
    /// 交给仪式图层播放的一场仪式
    enum Ritual: Equatable {
        case inscription(Inscription)
        case consummation(Consummation)
    }

    /// 落笔入卷：刚写的那页纸卷成小卷，化作灵光飞进侧栏“修行录”
    struct Inscription: Equatable {
        let id = UUID()
        /// 纸笺上显示的正文（RitualRules.inscriptionPreview）
        var preview: String
        /// 纸笺细边和尾迹的颜色：日记玉、灵感金、复盘青
        var kind: JournalKind?
        /// 落笔框（.composer，窗口坐标）；nil 时（问道页存档）只有朱印与墨晕
        var slip: CGRect?
        /// 落印处（按钮）
        var seal: CGRect?
        /// 侧栏“修行录”那一行（.chronicleNav）；nil 时纸卷在原地淡去
        var target: CGRect?
    }

    /// 功课圆满：四方灵光汇入境界徽记（丹田），徽记旁展开金色符箓
    struct Consummation: Equatable {
        let id = UUID()
        /// 侧栏境界徽记（.dantian，窗口坐标）
        var dantian: CGRect?
        /// 刚点的打卡圈（鼠标点击处，窗口坐标）；键盘触发、弹窗里点“确定”时为 nil
        var source: CGPoint?
    }

    /// 登记 / 更新一个仪式锚点。落笔框变了（入卷后清空、变矮）时顺带告诉图层，衬纸跟着换成新的框
    @MainActor
    func registerRitualAnchor(_ anchor: RitualAnchor, id: UUID, rect: CGRect) {
        ritualAnchors[anchor] = (id, rect)
        (ritualPlayer as? RitualHostView)?.anchorMoved(anchor, rect: rect)
    }

    @MainActor
    func unregisterRitualAnchor(_ anchor: RitualAnchor, id: UUID) {
        if ritualAnchors[anchor]?.id == id { ritualAnchors[anchor] = nil }
    }

    /// 当前这次打卡的鼠标位置（窗口坐标，左上角起算）：只认点在仪式图层所在窗口里的鼠标事件；
    /// 键盘打卡、弹窗里点“确定”都是 nil。NSApp 必须可选链：自检在 APTApp.init 里跑，那时可能还没有
    @MainActor
    func ritualClickPoint() -> CGPoint? {
        guard let event = NSApp?.currentEvent,
              [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(event.type),
              let window = event.window, let view = ritualPlayer as? NSView, view.window === window,
              let content = window.contentView else { return nil }
        let p = content.convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: content.isFlipped ? p.y : content.bounds.height - p.y)
    }

    /// 播“功课圆满”：境界徽记的位置等弹窗关了再取（侧栏在矮窗口会改紧凑排布）
    @MainActor
    func playConsummation(source: CGPoint?) {
        guard let player = ritualPlayer else { return }
        AccessibilityNotification.Announcement("功课圆满").post()
        let ritual = Ritual.consummation(Consummation(dantian: ritualAnchors[.dantian]?.rect, source: source))
        lastRitual = ritual
        player.play(ritual)
    }
}
