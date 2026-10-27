import Foundation

/// 个人档案字段目录。key 与旧版 `profile` 记录字段完全一致，保证导入不丢字段。
struct ProfileField: Identifiable, Hashable {
    let key: String
    let label: String
    let placeholder: String
    let multiline: Bool
    var id: String { key }
}

struct ProfileSection: Identifiable {
    let title: String
    let subtitle: String
    let fields: [ProfileField]
    var id: String { title }
}

enum ProfileCatalog {
    private static func f(_ key: String, _ label: String, _ placeholder: String = "", multiline: Bool = false) -> ProfileField {
        ProfileField(key: key, label: label, placeholder: placeholder, multiline: multiline)
    }

    static let sections: [ProfileSection] = [
        ProfileSection(title: "基本信息", subtitle: "名号与出身", fields: [
            f("nickname", "昵称", "例如：青岚"),
            f("name", "姓名"),
            f("preferred_name", "希望被称呼为"),
            f("city", "所在城市", "例如：悉尼"),
            f("timezone", "时区", "例如：Australia/Sydney"),
            f("identity", "身份", "例如：大学生 / 研究生 / 在职"),
            f("school", "学校 / 单位"),
            f("major", "专业 / 方向"),
            f("work_status", "当前阶段", "例如：Final Year"),
        ]),
        ProfileSection(title: "当前状态", subtitle: "此刻的修行处境", fields: [
            f("main_tasks", "主要任务", "这段时间最主要在做什么", multiline: true),
            f("important_project", "重要项目", multiline: true),
            f("current_stage", "当前处境", multiline: true),
            f("concerns", "担心的事", multiline: true),
            f("stress_sources", "压力来源", multiline: true),
            f("improvements", "想改进的地方", multiline: true),
        ]),
        ProfileSection(title: "目标", subtitle: "道心所向", fields: [
            f("academic_goals", "学业目标", multiline: true),
            f("career_goals", "职业目标", multiline: true),
            f("financial_goals", "财务目标", multiline: true),
            f("learning_goals", "学习目标", multiline: true),
            f("growth_goals", "个人成长目标", multiline: true),
            f("life_goals", "生活目标", multiline: true),
        ]),
        ProfileSection(title: "偏好", subtitle: "修行习性", fields: [
            f("preferred_work_time", "偏好的工作时间", "例如：上午 9–12 点效率最高"),
            f("study_preference", "学习偏好", multiline: true),
            f("work_style", "工作风格", multiline: true),
            f("software", "常用软件 / 工具", multiline: true),
            f("working_methods", "工作方法", "例如：番茄钟、GTD", multiline: true),
            f("rest_preferences", "休息方式", multiline: true),
        ]),
    ]

    static let allFields: [ProfileField] = sections.flatMap(\.fields)
    static let knownKeys: Set<String> = Set(allFields.map(\.key))

    /// 已填写字段占比（0…1）。
    static func completeness(_ values: [String: String]) -> Double {
        let filled = allFields.filter { !(values[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        return Double(filled) / Double(allFields.count)
    }
}
