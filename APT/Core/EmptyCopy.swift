import Foundation

/// 空状态的文案与小物：全应用一处写定，界面（Shared.swift 的 `OrnamentEmpty` / `EmptyHint`）与自检共用。
///
/// 一套写法：
/// - **大号留白**（`OrnamentEmpty`）：整页、或首页一整张卡一条都没有时用。小物 84pt（就是侧栏里这一页的那枚）+ 宋体对句标题
///   （“四字，静待两字”）+ 一句说明（说清下一步做什么）+ 直达下一步的按钮（主按钮在前，带图标）。
///   这时横幅、工具条里不再放同一个按钮（一屏只放一处）；下一步就在眼前时（如正上方的落笔框）不另放按钮，说明里指过去。
/// - **一行小字**（`EmptyHint`）：有数据的页里某张卡、某一块空着，或筛选后没有结果。图标 + 一句话；
///   能就地做下一步时行尾带一个小操作（打开新建弹窗用 `.inlineAction`，去别的页用 `.cardLink`）。
/// - 卡内小节（心境曲线、之后三天）空着：更轻的 `Hint` 一句，写在各自的视图里。
///
/// 说明与小字都只写一句、句号结尾、不超过 `maxLength` 字；同一屏不重复说同一件事（例如今日行程里“今天”和“之后三天”都空时只说一次）。
struct EmptyCopy: Equatable, Sendable {
    /// 小物插画（Scenery 里的文件名，不带扩展名）
    var ornament: String
    /// 宋体对句：“四字，静待两字”
    var title: String
    /// 一句说明：下一步做什么
    var text: String

    /// 说明、小字的字数上限（按字符计，标点也算）
    static let maxLength = 32

    /// 一行小字：图标（SF Symbols）+ 一句话
    struct Line: Equatable, Sendable {
        var symbol: String
        var text: String
    }
}

// MARK: - 大号留白（按页）

extension EmptyCopy {
    /// 修行录：一篇都没有。落笔框就在正上方，不另放按钮
    static let chronicle = EmptyCopy(ornament: "yunshan-ornament-journal-v1", title: "一卷留白，静待落笔",
                                     text: "在上方写下今天的第一笔，修行录便从这里展开。")
    /// 每日功课（也用在今日洞府的“今日功课”卡）：一项功课都没有
    static let habits = EmptyCopy(ornament: "yunshan-ornament-lotus-v1", title: "一池清莲，静待初课",
                                  text: "先立一件小事，比如“晨读 20 分钟”。")
    /// 起居有常：一条作息都没有
    static let routine = EmptyCopy(ornament: "yunshan-ornament-hourglass-v1", title: "起居未定，静待布阵",
                                   text: "定下睡眠、三餐与学习的时段，时辰卷里会衬上浅色底纹。")
    /// 时辰卷（近期列表、全部日程）：一个日程都没有
    static let schedule = EmptyCopy(ornament: "yunshan-ornament-waterclock-v1", title: "时辰未排，静待一程",
                                    text: "排下第一程；每周重复的课只需录一次。")
    /// 灵石账簿：一笔交易都没有（三个标签同一张）
    static let finance = EmptyCopy(ornament: "yunshan-ornament-abacus-v1", title: "账房清静，静待入账",
                                   text: "导入网银导出的 CSV 自动分类；现金消费可手记一笔。")
    /// 岁月长卷：全应用一条记录都没有
    static let annals = EmptyCopy(ornament: "yunshan-ornament-scroll-v1", title: "长卷未展，静待岁月",
                                  text: "落笔、打卡或记账之后，这一年会在这里汇成一卷。")

    /// 全部大号留白（自检逐条核对写法用）
    static let all: [(name: String, copy: EmptyCopy)] = [
        ("chronicle", chronicle), ("habits", habits), ("routine", routine),
        ("schedule", schedule), ("finance", finance), ("annals", annals),
    ]
}

// MARK: - 一行小字

extension EmptyCopy.Line {
    // 今日洞府
    /// 有功课，但今天没有要打卡的
    static let restDay = Self(symbol: "leaf", text: "今天没有该打卡的功课，且歇一歇。")
    /// 今天与之后三天都没有日程、也没有作息：只说这一次（行尾“新增日程”）
    static let nothingAhead = Self(symbol: "cloud", text: "今日与之后三天都还没有安排。")
    /// 今天没有，之后三天有
    static let todayFree = Self(symbol: "cloud", text: "今天没有日程，也没有作息。")
    /// 近 14 日修为全是 0（衬在空图表正中）
    static let noCultivation = Self(symbol: "sparkles", text: "打卡、落笔都会积攒修为，这里会长出第一根柱。")

    // 修行录
    /// 往日回看：一周、一月、一年前的今天都没写过（全新的卷里说短一句，不把三个时段都念一遍）
    static let lookback = Self(symbol: "hourglass", text: "往年今日写过的，会在这里重现。")
    /// 只筛“珍藏”且一篇都没有
    static let noPinned = Self(symbol: "bookmark", text: "还没有珍藏：在时间线条目的“…”菜单里点“珍藏”。")
    /// 筛选后没有结果
    static let noMatch = Self(symbol: "magnifyingglass", text: "没有符合筛选条件的记录。")

    // 修士名帖
    static let noGoals = Self(symbol: "flag", text: "还没有目标：把下面的方向拆成一两个可衡量的小目标。")
    static let noActiveGoals = Self(symbol: "flag", text: "没有进行中的目标：新立一个，或把旧目标改回进行中。")

    // 时辰卷
    /// 周视图：一个日程都没有（行尾“新增日程”）
    static let weekEmpty = Self(symbol: "calendar", text: "还没有日程：双击下面的空白时段，即可排上一程。")
    /// 近期列表：有日程，但未来 30 天没有
    static let agendaEmpty = Self(symbol: "calendar", text: "未来 30 天没有日程。")

    // 每日功课
    /// 功课详情：这项功课还没打过卡
    static let noLogs = Self(symbol: "tray", text: "还没有打卡记录。")

    // 灵石账簿
    static let noSpend = Self(symbol: "tray", text: "本月没有消费扣款。")
    static let reviewClear = Self(symbol: "checkmark.seal", text: "没有待确认的记录，账目已清。")
    static let noTransactions = Self(symbol: "magnifyingglass", text: "没有符合条件的交易。")
    static let noBills = Self(symbol: "checkmark.seal", text: "本月和上月都没有识别到固定账单。")

    // 问道灵枢
    /// 全应用一条记录都没有：摘要里几乎没有东西可读（行尾“去落笔”）
    static let nothingToAsk = Self(symbol: "tray", text: "卷中还没有记录，先落笔、打卡几天再来问道。")

    /// 全部一行小字（自检逐条核对写法用）
    static let all: [(name: String, line: EmptyCopy.Line)] = [
        ("restDay", restDay), ("nothingAhead", nothingAhead), ("todayFree", todayFree), ("noCultivation", noCultivation),
        ("lookback", lookback), ("noPinned", noPinned), ("noMatch", noMatch),
        ("noGoals", noGoals), ("noActiveGoals", noActiveGoals),
        ("weekEmpty", weekEmpty), ("agendaEmpty", agendaEmpty), ("noLogs", noLogs),
        ("noSpend", noSpend), ("reviewClear", reviewClear), ("noTransactions", noTransactions), ("noBills", noBills),
        ("nothingToAsk", nothingToAsk),
    ]
}

// MARK: - 写法核对

extension EmptyCopy {
    /// 标题是否合“四字，静待两字”
    static func isCoupletTitle(_ title: String) -> Bool {
        let chars = Array(title)
        guard chars.count == 9, chars[4] == "，", String(chars[5...6]) == "静待" else { return false }
        return chars.enumerated().allSatisfy { index, char in index == 4 || !char.isPunctuation }
    }

    /// 说明 / 小字是否合“一句话”：句号结尾、中间没有别的句号（分号、冒号可以有），不超过 maxLength 字，首尾没有空白
    static func isOneSentence(_ text: String) -> Bool {
        guard text.count <= maxLength, text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasSuffix("。") else { return false }
        let enders: Set<Character> = ["。", "！", "？", "!", "?"]
        return text.dropLast().allSatisfy { !enders.contains($0) }
    }

    /// 一份文案里不合写法的地方（空数组 = 都合）
    var problems: [String] {
        var out: [String] = []
        if !EmptyCopy.isCoupletTitle(title) { out.append("标题不是“四字，静待两字”：\(title)") }
        if !EmptyCopy.isOneSentence(text) { out.append("说明不是一句话（句号结尾、≤ \(EmptyCopy.maxLength) 字）：\(text)") }
        if !(ornament.hasPrefix("yunshan-ornament-") && ornament.hasSuffix("-v1")) { out.append("小物不是 yunshan-ornament-…-v1：\(ornament)") }
        return out
    }
}

extension EmptyCopy.Line {
    var problems: [String] {
        var out: [String] = []
        if !EmptyCopy.isOneSentence(text) { out.append("小字不是一句话（句号结尾、≤ \(EmptyCopy.maxLength) 字）：\(text)") }
        if symbol.isEmpty || symbol.contains(" ") { out.append("图标名不对：\(symbol)") }
        return out
    }
}
