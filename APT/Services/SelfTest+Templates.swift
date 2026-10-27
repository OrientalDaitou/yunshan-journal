import SwiftUI
import SwiftData

// MARK: - r3-templates：#18 落笔模板
// 套用、骨架判定、改名删除的规则在 Tools/CoreCheck 里逐条核对；这里测要用到偏好设置与界面的部分：
// 自存模板经偏好设置 `templates.custom` 存取（读坏了当没有）；“存为模板”“管理模板”两个小弹窗在 1180×780 的窗口里放得下
// （存满 20 套、正文很长时也一样）；落笔框带着自存模板时，首页小落笔框和修行录完整落笔框都排得出来。
// 偏好都写进一个用完即删的临时域，不碰调试实例自己的偏好。

extension SelfTest {
    static func templatesChecks(_ check: (Bool, String) -> Void) throws {
        let suiteName = "io.github.orientaldaitou.yunshan.selftest.templates.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check(false, "落笔模板：开不出临时偏好域")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 1. 存取：存进去读得回来；键就是落笔框 @AppStorage 读的那一个；偏好里写坏了当没有
        let mine = [JournalTemplate(name: "周末小结", body: "这周最开心的事：\n\n下周想试试：\n"),
                    JournalTemplate(name: "读书", body: "【书】\n\n【一句】\n")]
        JournalTemplateStore.save(mine, defaults)
        check(JournalTemplateStore.load(defaults) == mine && defaults.string(forKey: "templates.custom") == JournalTemplates.encode(mine),
              "落笔模板：自存的存进偏好 templates.custom，读得回来")
        defaults.set("[{\"name\": 3}]", forKey: JournalTemplates.customKey)
        check(JournalTemplateStore.load(defaults).isEmpty, "落笔模板：偏好里写坏了当没有自存的，菜单照常列内置四套")

        // 2. 两个小弹窗在 1180×780（去掉 28pt 标题栏）里放得下：存满 20 套、正文很长也一样
        let full = (1...JournalTemplates.limit).map { JournalTemplate(name: "第\($0)套模板名字很长", body: "【段一】\n\n【段二】第 \($0) 套\n") }
        JournalTemplateStore.save(full, defaults)
        let container = try DataStore.makeContainer(inMemory: true)
        let c = container.mainContext
        DataStore.settings(in: c)
        DataStore.profile(in: c)
        DataStore.save(c)
        func fitting(_ view: some View, width: CGFloat? = nil) -> CGSize {
            let root = view
                .frame(width: width)
                .environment(EffectsCenter())
                .environment(\.spiritMotion, false)
                .modelContainer(container)
                .defaultAppStorage(defaults)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: CGSize(width: width ?? 900, height: 900))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        let longBody = (1...40).map { "【第 \($0) 段】这一段写得很长很长，看弹窗会不会被撑高" }.joined(separator: "\n\n")
        let limit = CGSize(width: 1180, height: 780 - 28)
        let sheets: [(String, CGSize, CGSize)] = [
            ("存为模板", fitting(JournalTemplateSaveSheet(templateBody: longBody, onSaved: { _ in })), JournalTemplateSaveSheet.size),
            ("管理模板", fitting(JournalTemplateSheet()), JournalTemplateSheet.size),
        ]
        let oversized = sheets.filter { _, size, declared in
            size.width > limit.width || size.height > limit.height || size.height < 100
                || abs(size.width - declared.width) > 1 || abs(size.height - declared.height) > 1
        }.map { "\($0.0) \(Int($0.1.width))×\(Int($0.1.height))" }
        check(oversized.isEmpty, "落笔模板：“存为模板”“管理模板”两个弹窗就是定好的大小、在 1180×780 里放得下（存满 20 套、正文 40 段也一样）"
              + (oversized.isEmpty ? "" : "（不对：\(oversized)）"))

        // 3. 落笔框带着自存模板：修行录的完整落笔框（三类）与首页的小落笔框（复盘）都排得出来；窄到 420 也不撑宽
        let page = "selftest-templates"
        defaults.set(full[0].body, forKey: JournalDraft.key(page, "text"))
        var bad: [String] = []
        for kind in JournalKind.allCases {
            for (compact, width) in [(false, CGFloat(560)), (false, 420), (true, 560)] where !compact || kind == .review {
                let size = fitting(JournalComposer(kind: .constant(kind), compact: compact, draftPage: page), width: width)
                if size.height < 100 || size.width > width + 1 { bad.append("\(kind.label)\(compact ? "（首页）" : "") \(Int(width)) → \(Int(size.width))×\(Int(size.height))") }
            }
        }
        check(bad.isEmpty, "落笔模板：带着自存模板时，修行录落笔框（日记 / 灵感 / 复盘，560 与 420 宽）和首页小落笔框都排得出来、不撑宽"
              + (bad.isEmpty ? "" : "（不对：\(bad)）"))

        // 4. 只套了模板没写字的草稿与空草稿一样看待（与“落笔入卷”同一个判定）：读书札记、自存的段名模板骨架都算空；
        //    带内容的自存模板原样放着算写过
        let reading = JournalTemplates.builtins[2].body
        let run = JournalTemplate(name: "跑步", body: "今天跑了 5 公里，配速 6'30\"\n")
        JournalTemplateStore.save([JournalTemplate(name: "晨跑", body: "【距离】\n\n【配速】\n"), run], defaults)
        func setDraft(_ page: String, _ fields: [String: String]) {
            for field in ["kind", "title", "text", "mood", "tags", "day", "period"] { defaults.removeObject(forKey: JournalDraft.key(page, field)) }
            for (field, value) in fields { defaults.set(value, forKey: JournalDraft.key(page, field)) }
        }
        func draft(_ page: String, _ field: String) -> String? { defaults.string(forKey: JournalDraft.key(page, field)) }
        let blankPage = "selftest-templates-blank"
        let blanks = [reading, "\n" + JournalTemplates.builtins[1].body, "【距离】\n\n【配速】\n", ReviewPeriod.template + "\n" + reading].map { text in
            setDraft(blankPage, ["text": text])
            return JournalDraft.isBlank(page: blankPage, defaults: defaults)
        }
        setDraft(blankPage, ["text": run.body])
        let runWritten = !JournalDraft.isBlank(page: blankPage, defaults: defaults)
        setDraft(blankPage, ["text": reading, "title": "三体"])
        let titled = !JournalDraft.isBlank(page: blankPage, defaults: defaults)
        check(blanks.allSatisfy { $0 } && runWritten && titled,
              "落笔草稿：只套了读书札记、晚课三省、自存的段名模板、几套接在一起都算空草稿；带内容的自存模板、写了标题的算写过：\(blanks)")

        // 首页写了两句、点“翻开修行录”：修行录落笔框里只有读书札记骨架，首页的两句照样挪过去，首页复位
        let source = "selftest-templates-dashboard"
        let target = "selftest-templates-chronicle"
        setDraft(source, ["text": "首页写的两句", "kind": JournalKind.diary.rawValue, "mood": "4"])
        setDraft(target, ["text": reading, "kind": JournalKind.note.rawValue, "day": "2026-10-15"])
        JournalDraft.moveIfTargetBlank(from: source, to: target, defaults: defaults)
        check(draft(target, "text") == "首页写的两句" && draft(target, "kind") == JournalKind.diary.rawValue && draft(target, "mood") == "4"
              && draft(target, "day") == nil && draft(source, "text") == "" && draft(source, "kind") == nil,
              "落笔草稿：修行录里只有读书札记骨架时，首页写的两句挪得过去（类型、心境跟着走，旧补记日期清掉），首页复位")

        // 进修行录：只有读书札记骨架、停在复盘、补记日期是旧的 → 日期回到今天、类型回到日记；日记里的骨架只复位日期、骨架留着
        setDraft(target, ["text": reading, "kind": JournalKind.review.rawValue, "day": "2026-10-15"])
        JournalDraft.resetIfBlank(page: target, defaults: defaults)
        let reviewReset = draft(target, "day") == nil && draft(target, "kind") == JournalKind.diary.rawValue && draft(target, "text") == ""
        setDraft(target, ["text": reading, "kind": JournalKind.diary.rawValue, "day": "2026-10-15"])
        JournalDraft.resetIfBlank(page: target, defaults: defaults)
        let diaryReset = draft(target, "day") == nil && draft(target, "kind") == JournalKind.diary.rawValue && draft(target, "text") == reading
        setDraft(target, ["text": reading + "\n读了一章", "kind": JournalKind.review.rawValue, "day": "2026-10-15"])
        JournalDraft.resetIfBlank(page: target, defaults: defaults)
        let writtenKept = draft(target, "day") == "2026-10-15" && draft(target, "kind") == JournalKind.review.rawValue
        check(reviewReset && diaryReset && writtenKept,
              "落笔草稿：进页时只有读书札记骨架的草稿补记日期回到今天、停在复盘的回到日记；写了字的原样保留")

        // 七日小卷“存为周复盘草稿 · 接在后面”：落笔框里只有读书札记骨架时整篇换成周复盘，不叠两套段名
        let today = LocalDay.today()
        let week = WeeklyDigest.Week(monday: today.mondayOfWeek, today: today)
        setDraft(WeeklyDraft.page, ["text": reading, "kind": JournalKind.diary.rawValue])
        let askFirst = !JournalDraft.isBlank(page: WeeklyDraft.page, defaults: defaults)
        WeeklyDraft.write(week: week, quotes: [], context: c, mode: .append, defaults: defaults)
        let weekly = draft(WeeklyDraft.page, "text") ?? ""
        check(!askFirst && weekly.hasPrefix("【所得】") && !weekly.contains("【书名】") && weekly.components(separatedBy: "【所得】").count == 2
              && draft(WeeklyDraft.page, "kind") == JournalKind.review.rawValue,
              "七日小卷：落笔框里只有读书札记骨架时不问“替换 / 接在后面”，接在后面也不叠两套段名")
        for page in [blankPage, source, target, WeeklyDraft.page] { setDraft(page, [:]) }

        // 5. 修行录落笔框换类型：日记里从菜单套的复盘四段，换到灵感不清；进复盘时自动填的那份，离开复盘才清；空着进复盘照旧自动填
        final class KindBox { var kind = JournalKind.diary }
        let box = KindBox()
        let kindPage = "selftest-templates-kind"
        setDraft(kindPage, ["text": ReviewPeriod.template])
        func composer() -> AnyView {
            AnyView(JournalComposer(kind: Binding(get: { box.kind }, set: { box.kind = $0 }), draftPage: kindPage)
                .frame(width: 560)
                .environment(EffectsCenter())
                .environment(\.spiritMotion, false)
                .modelContainer(container)
                .defaultAppStorage(defaults))
        }
        let kindHost = NSHostingView(rootView: composer())
        kindHost.frame = CGRect(x: 0, y: 0, width: 560, height: 700)
        let kindWindow = NSWindow(contentRect: kindHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
        kindWindow.isReleasedWhenClosed = false
        kindWindow.contentView = kindHost
        func switchKind(_ next: JournalKind) -> String {
            box.kind = next
            kindHost.rootView = composer()
            kindHost.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            return draft(kindPage, "text") ?? ""
        }
        kindHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let kindTexts = [switchKind(.note), switchKind(.diary), switchKind(.review), switchKind(.note), switchKind(.review)]
        kindWindow.contentView = nil
        kindWindow.close()
        let template = ReviewPeriod.template
        check(kindTexts == [template, template, template, "", template],
              "落笔模板：日记、灵感里套的复盘四段换类型不清；离开复盘时才清掉进复盘时的那份，空着进复盘照旧填复盘四段"
              + (kindTexts == [template, template, template, "", template] ? "" : "（不对：\(kindTexts.map(\.count))）"))
        setDraft(kindPage, [:])
    }
}
