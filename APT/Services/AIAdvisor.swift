import Foundation

/// AI 建议接口。第一版只实现“导出”，API 接入时新增一个遵循此协议的类型并注册即可。
///
/// 接入约定：
/// - 输入只有结构化摘要（PlannerSummary 与其 Markdown），AI 永远不直接读写数据库；
/// - 返回纯文本建议，由用户在“参悟”页面查看、记录是否采纳；
/// - API Key 应保存在钥匙串（Keychain），不要存进 SwiftData 或导出文件。
protocol AIAdvisor {
    var id: String { get }
    var displayName: String { get }
    /// 是否已经可以直接发送（例如已配置 API Key）。
    var isConfigured: Bool { get }
    func requestAdvice(prompt: String, summary: PlannerSummary) async throws -> String
}

enum AIAdvisorError: LocalizedError {
    case notConfigured
    var errorDescription: String? {
        switch self {
        case .notConfigured: "尚未接入 AI 服务。请先复制或导出摘要，粘贴到你常用的 AI 对话中。"
        }
    }
}

/// 默认：不联网，只负责导出。
struct ExportOnlyAdvisor: AIAdvisor {
    let id = "export"
    let displayName = "仅导出（不联网）"
    let isConfigured = false
    func requestAdvice(prompt: String, summary: PlannerSummary) async throws -> String { throw AIAdvisorError.notConfigured }
}

enum AIAdvisorRegistry {
    /// 以后在这里追加新的服务，例如 `ClaudeAdvisor()`。
    static let all: [any AIAdvisor] = [ExportOnlyAdvisor()]

    static func advisor(id: String) -> any AIAdvisor {
        all.first { $0.id == id } ?? ExportOnlyAdvisor()
    }
}
