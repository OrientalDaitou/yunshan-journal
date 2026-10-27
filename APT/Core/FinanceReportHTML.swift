import Foundation

/// 月报导出为独立 HTML（可打印），版式沿用旧版“月度修习录”。
enum FinanceReportHTML {
    static func render(_ report: MonthlyReport, timeZone: TimeZone = .current) -> String {
        func esc(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func money(_ cents: Int) -> String { (cents < 0 ? "-" : "") + "A" + FinanceEngine.money(abs(cents)) }
        func table(_ headers: [String], _ rows: [[String]]) -> String {
            let head: String = headers.map { (h: String) -> String in "<th>" + esc(h) + "</th>" }.joined()
            let body: String = rows.map { (row: [String]) -> String in
                let cells: String = row.map { (c: String) -> String in "<td>" + esc(c) + "</td>" }.joined()
                return "<tr>" + cells + "</tr>"
            }.joined()
            return "<table><thead><tr>" + head + "</tr></thead><tbody>" + body + "</tbody></table>"
        }
        let f = report.summary
        let coverage = f.coverageConfirmed ? "已确认银行导出范围覆盖整月" : f.fullMonth ? "已有导入范围覆盖整月" : "部分月份，暂不与整月比较"
        var generated = report.generatedAt
        if let date = LegacyMapper.timestamp(report.generatedAt) { generated = DateText.stamp(date, timeZone: timeZone) }
        var s: [String] = []
        s.append("<h1>\(esc(report.month)) · 月度修习录</h1><p>\(esc(coverage)) · \(f.rowCount) 笔 · \(f.accountCount) 个已导入账户</p>")
        s.append(table(["消费扣款", "本月退款", "净消费", "其他扣款"], [[money(f.spendCents), money(f.refundCents), money(f.netSpendCents), money(f.excludedCents)]]))
        s.append("<h2>消费类别</h2>")
        s.append(table(["类别", "扣款", "占比"], f.categories.sorted { $0.value > $1.value }.map { key, amount in
            [key, money(amount), f.spendCents > 0 ? String(format: "%.1f%%", Double(amount) / Double(f.spendCents) * 100) : "0%"]
        }))
        if let c = report.comparison {
            s.append("<h2>与 \(esc(c.previousMonth)) 比较</h2>")
            s.append("<p>消费变化 \(money(c.spendChangeCents))；扣除教育支出后的变化 \(money(c.nonEducationChangeCents))。</p>")
            s.append(table(["类别", "本月", "上月", "差额"], c.categories.map { [$0.category, money($0.currentCents), money($0.previousCents), money($0.changeCents)] }))
        } else {
            s.append("<p>本月或上月未覆盖整月，暂不计算环比。</p>")
        }
        s.append("<h2>大额单笔支出</h2>")
        s.append(table(["日期", "商户", "类别", "扣款"], report.largePurchases.map { [$0.date, $0.merchant, $0.category, money($0.cents)] }))
        s.append("<h2>消费之外</h2>")
        s.append(table(["类别", "其他扣款"], f.excludedCategories.sorted { $0.value > $1.value }.map { [$0.key, money($0.value)] }))
        s.append("<h2>可选消费预算</h2>")
        s.append(table(["项目", "消费扣款", "预算", "余额"], report.budgets.map {
            [$0.label, money($0.spentCents), $0.limitCents.map(money) ?? "未设置", $0.remainingCents.map(money) ?? "—"]
        }))
        s.append("<h2>固定账单检查</h2>")
        s.append(table(["服务", "本月扣款", "笔数", "保留选择", "核对提示"], report.services.map {
            [$0.label, money($0.debitCents), String($0.count), $0.status == "keep" ? "保留" : "待核对",
             $0.signals.isEmpty ? "未发现上述提示" : $0.signals.map(\.text).joined(separator: "；")]
        }))
        s.append("<h2>下月三件事</h2><ol>" + report.suggestions.map { "<li>\(esc($0))</li>" }.joined() + "</ol>")
        s.append("<h2>我的月末备注</h2><p class=\"reflection\">\(esc(report.reflection.isEmpty ? "未填写" : report.reflection))</p>")
        s.append("<p class=\"footnote\">版本 \(report.version) · 保存于 \(esc(generated))（\(esc(timeZone.identifier))）。此为保存时的本地账本快照；待分类记录会影响结论，退款原消费可能在其他月份。差额和节省建议不代表已实现的节省。</p>")
        let style = "body{max-width:1000px;margin:40px auto;padding:0 24px;color:#254738;background:#fbfbf5;font:15px/1.8 -apple-system,'PingFang SC',sans-serif}h1,h2{font-family:'Songti SC',serif}h2{margin-top:32px}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:10px;border-bottom:1px solid #d8dfd0}th{background:#edf1e3}li{margin:10px 0}.reflection{white-space:pre-wrap}.footnote{font-size:12px;color:#63765d;margin-top:35px}@media print{body{margin:0;padding:0;background:white}tr{break-inside:avoid}h2{break-after:avoid}}"
        return "<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>\(esc(report.month)) 灵石账簿</title><style>\(style)</style><body>" + s.joined() + "</body></html>"
    }
}
