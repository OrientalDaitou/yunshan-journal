import Foundation
import AppKit

// r7-keys 的运行时自检：渡劫画面盖着主窗口时，页面按键（方向键、空格、回车）一律不接。
// 画面开着时按空格想“继续”，不能把底下刚打的卡取消掉；画面散去后页面按键照常。

extension SelfTest {
    @MainActor
    static func r7KeysChecks(_ check: (Bool, String) -> Void) {
        let effects = EffectsCenter()
        check(!PageKeys.covered(by: nil) && !PageKeys.covered(by: effects), "页面按键：没有渡劫画面时照常接")
        effects.breakthrough = "筑基"
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)
        check(PageKeys.covered(by: effects) && space.map { !PageKeys.accepts($0, in: window, effects: effects) } ?? false,
              "页面按键：渡劫画面盖着主窗口时空格、方向键、回车都不接")
        effects.breakthrough = nil
        check(!PageKeys.covered(by: effects), "页面按键：渡劫画面散去后照常接")
        window.close()
    }
}
