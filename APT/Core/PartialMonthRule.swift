import Foundation

/// 银行账单没导全的月份标什么、什么时候标：灵石账簿月份旁的小标、岁月长卷卷首灵石格与逐月柱的刻度下标、
/// 长卷导出（Markdown / PDF）的逐月表，都用这一个说法、这一条判断。
/// 界面的 FinanceHeadlineRule.partialLabel 引用这里（Core 拿不到 Views 里的常量，反过来引用）。
enum PartialMonthRule {
    /// 小标的字（以前写“部分”，看不出是什么的部分）
    static let label = "未导全"

    /// 导出逐月表里金额后面的写法：“$1,234（未导全）”
    static var suffix: String { "（\(label)）" }

    /// 要不要标：这个月没导全，并且账簿导入过银行账单。
    /// 只记手记、从没导入过银行账单的账簿每个月都“没导全”，不标（不然每个月都挂一个，像在催人去导账单）；
    /// 与岁月长卷的 manualOnly（ledger.sources 为空）同一规则
    static func flags(full: Bool, manualOnly: Bool) -> Bool { !full && !manualOnly }
}
