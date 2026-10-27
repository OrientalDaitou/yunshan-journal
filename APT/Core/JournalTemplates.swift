import Foundation

// 落笔模板：修行录落笔框“套用模板 ▾”里的几套（内置 4 套 + 自己存的，最多 20 套）。
// 纯数据与纯函数，不依赖 SwiftData，CoreCheck 可测。自存的模板放在偏好设置 `templates.custom`（JSON 数组），不动数据模型；
// 界面在 Views/JournalComposer（菜单与套用）、Views/JournalTemplateSheet（存为模板、管理模板）。首页的小落笔框不用这里。

/// 一套落笔模板：名称 + 正文骨架（一般是几段【段名】，每段下空一行）。
struct JournalTemplate: Codable, Equatable, Identifiable {
    var name: String
    var body: String

    var id: String { name }

    /// 内置的不能改名、删除
    var isBuiltin: Bool { JournalTemplates.builtins.contains { $0.name == name } }

    /// 菜单里名称后面的一句说明：有【段名】的列段名（“所得 · 所失 · 所悟 · 下一步”），没有的取第一行（最多 14 字）
    var summary: String {
        let heads = JournalTemplates.headings(in: body)
        if !heads.isEmpty { return heads.joined(separator: " · ") }
        let first = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return first.count > 14 ? String(first.prefix(14)) + "…" : first
    }

    /// 菜单里的一项：“晚课三省（今日所成 · 卡在何处 · 明日第一件事）”
    var menuTitle: String { summary.isEmpty ? name : "\(name)（\(summary)）" }
}

/// 套用之后正文怎么变：直接放入（原来是空的，或只有没动过的模板骨架）还是接在末尾
struct JournalTemplateApplication: Equatable {
    var text: String
    /// true：原来写了字，模板接在末尾（界面上提示一句）
    var appended: Bool
}

enum JournalTemplates {
    /// 偏好设置里存自存模板的键（JSON 数组：[{"name": …, "body": …}]）
    static let customKey = "templates.custom"
    /// 自存的最多几套
    static let limit = 20
    /// 名称最长几个字（菜单里一眼看完）
    static let nameLimit = 12

    /// 内置四套：复盘四段（原来的复盘模板）、晚课三省、读书札记、一事一记
    static let builtins: [JournalTemplate] = [
        JournalTemplate(name: "复盘四段", body: ReviewPeriod.template),
        JournalTemplate(name: "晚课三省", body: "【今日所成】\n\n【卡在何处】\n\n【明日第一件事】\n"),
        JournalTemplate(name: "读书札记", body: "【书名】\n\n【摘句】\n\n【所思】\n"),
        JournalTemplate(name: "一事一记", body: "【事】\n\n【感】\n\n【下一步】\n"),
    ]

    /// 菜单里的全部：内置在前，自存的照存的先后（新存的在最后）
    static func all(custom: [JournalTemplate]) -> [JournalTemplate] { builtins + custom }

    // MARK: 存取

    /// 读偏好里的 JSON：读坏了当没有；名称为空、正文为空、与内置或前面同名的丢掉，最多取 20 套
    static func decode(_ raw: String) -> [JournalTemplate] {
        guard let data = raw.data(using: .utf8), !raw.isEmpty,
              let list = try? JSONDecoder().decode([JournalTemplate].self, from: data) else { return [] }
        var seen = Set(builtins.map(\.name))
        var result: [JournalTemplate] = []
        for item in list {
            let name = cleanName(item.name)
            guard !name.isEmpty, !isBlankText(item.body), seen.insert(name).inserted else { continue }
            result.append(JournalTemplate(name: name, body: item.body))
            if result.count == limit { break }
        }
        return result
    }

    static func encode(_ list: [JournalTemplate]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(list) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 名称：去掉首尾空白，换行换成空格，最多 12 字
    static func cleanName(_ name: String) -> String {
        let flat = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(nameLimit))
    }

    /// 存成模板的正文：去掉首尾空行，末尾留一个换行（套用后光标落在新的一行，和内置的一样）
    static func cleanBody(_ body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: 存为模板 / 改名 / 删除

    /// 起名存模板时名称有什么问题（nil 表示可以存）。replacing：正在改名的那一套原来的名字（和自己同名不算重名）
    static func nameProblem(_ name: String, custom: [JournalTemplate], replacing: String? = nil) -> String? {
        let name = cleanName(name)
        if name.isEmpty { return "起个名字" }
        if builtins.contains(where: { $0.name == name }) { return "与内置模板同名，换一个" }
        if name != replacing, custom.contains(where: { $0.name == name }) { return "已有同名的模板，换一个" }
        return nil
    }

    /// 存为模板：名称、正文都整理过；名称有问题、正文空、已满 20 套时返回 nil（界面先用 nameProblem / isFull 说明）
    static func adding(name: String, body: String, to custom: [JournalTemplate]) -> [JournalTemplate]? {
        guard nameProblem(name, custom: custom) == nil, !isBlankText(body), !isFull(custom) else { return nil }
        return custom + [JournalTemplate(name: cleanName(name), body: cleanBody(body))]
    }

    static func isFull(_ custom: [JournalTemplate]) -> Bool { custom.count >= limit }

    /// 改名：内置的、不存在的、新名字有问题时返回 nil；名字没变时原样返回
    static func renaming(_ old: String, to new: String, in custom: [JournalTemplate]) -> [JournalTemplate]? {
        guard let index = custom.firstIndex(where: { $0.name == old }),
              nameProblem(new, custom: custom, replacing: old) == nil else { return nil }
        var list = custom
        list[index].name = cleanName(new)
        return list
    }

    /// 删除一套自存的（内置的不在这张表里，删不到）
    static func removing(_ name: String, from custom: [JournalTemplate]) -> [JournalTemplate] {
        custom.filter { $0.name != name }
    }

    // MARK: 套用

    /// 套用一套模板：正文空（或只有没动过的模板骨架）→ 直接换成模板；写了字 → 接在末尾、空一行。
    /// 正文正好就是这一套（带实际内容的自存模板连点两下）时也是直接换，不叠两份
    static func applying(_ template: JournalTemplate, to text: String, custom: [JournalTemplate]) -> JournalTemplateApplication {
        if isSkeleton(text, custom: custom) || nonEmptyLines(text) == nonEmptyLines(template.body) {
            return JournalTemplateApplication(text: template.body, appended: false)
        }
        let kept = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return JournalTemplateApplication(text: kept + "\n\n" + template.body, appended: true)
    }

    // MARK: 骨架判定

    /// 正文是不是“还没写东西”：空白，或只由一套或几套模板的段名原样拼成（套了模板还没动笔）。
    /// 落笔入卷按这个判断能不能入卷（以前只认复盘四段），套用模板时按这个判断是直接换还是接在后面；
    /// 修行录草稿“是不是空的”（Views/ChronicleSupport 的 JournalDraft.isBlankBody：首页草稿挪不挪过去、
    /// 进页复位补记日期与类型、周复盘提醒换不换类型、七日小卷存草稿问不问）也是这一个判定。
    /// 只认整套的骨架：少了一段、多写了一个字都算写过（例如单写一行“【书名】三体”）。
    /// 自存的模板只有每行都“像段名或引子”（见 isSkeletonTemplate）才当骨架：存的是一句常记的话或一份打卡文字时，
    /// 原样套用（或正好写出同样一句）就是写了东西，能入卷
    static func isSkeleton(_ text: String, custom: [JournalTemplate]) -> Bool {
        let lines = nonEmptyLines(text)
        if lines.isEmpty { return true }
        let patterns = (builtins + custom.filter(isSkeletonTemplate)).map { nonEmptyLines($0.body) }.filter { !$0.isEmpty }
        // 从头往后拼：reachable[i] 表示前 i 行正好是几套骨架首尾相接
        var reachable = [Bool](repeating: false, count: lines.count + 1)
        reachable[0] = true
        for start in 0..<lines.count where reachable[start] {
            for pattern in patterns where start + pattern.count <= lines.count {
                if Array(lines[start..<start + pattern.count]) == pattern { reachable[start + pattern.count] = true }
            }
        }
        return reachable[lines.count]
    }

    /// 这套模板是不是“只有骨架”：每个非空行都像段名（整行就是一个【…】，后面没有字）或引子（以“：”“:”结尾）。
    /// 内置四套都是；自存的含有别的内容行（“今天跑了 5 公里”“早安”）就不是，不参与骨架判定
    static func isSkeletonTemplate(_ template: JournalTemplate) -> Bool {
        let lines = nonEmptyLines(template.body)
        return !lines.isEmpty && lines.allSatisfy(isSkeletonLine)
    }

    /// 一行像段名或引子：“【书名】”（】之后没有字）、“这周最开心的事：”“下周:”
    private static func isSkeletonLine(_ line: String) -> Bool {
        if line.hasSuffix("：") || line.hasSuffix(":") { return true }
        guard line.hasPrefix("【"), let close = line.firstIndex(of: "】") else { return false }
        return line.index(after: close) == line.endIndex
    }

    /// 模板正文里的段名：行首的【…】（“【书名】” → “书名”），按出现的次序
    static func headings(in body: String) -> [String] {
        nonEmptyLines(body).compactMap { line in
            guard line.hasPrefix("【"), let close = line.firstIndex(of: "】") else { return nil }
            let name = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
    }

    private static func nonEmptyLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func isBlankText(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
