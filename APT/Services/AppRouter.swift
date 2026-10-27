import AppKit
import Observation
import UserNotifications

/// 跨页面跳转的请求：全局搜索、提醒通知点开后，带着要定位的内容切到目标页。
@Observable
final class AppRouter {
    /// 切到哪一页（RootView 监听后执行；主窗口还没出现时，窗口出现后在 bootstrap 里补上）
    var page: AppSection?
    /// 修行录：预填搜索词 / 直接切到某种落笔
    var chronicleSearch: String?
    var chronicleCompose: JournalKind?
    /// 灵石账簿：切到交易明细并预填搜索
    var financeSearch: String?
    /// 时辰卷：跳到包含这一天的那一周
    var scheduleDay: LocalDay?
    /// 打开七日小卷（WeeklyScrollSheet）：谁在当前页谁打开，打开即清零（修行录接收；要从别处打开就先把 page 切到修行录）
    var weeklyScroll = false
    /// 指定由哪一页打开七日小卷（nil = 谁在当前页谁开）。点开周复盘提醒会同时切页，指定修行录，
    /// 免得首页在切走前的一瞬先接走、随即被换下去，小卷跟着消失
    var weeklyScrollTarget: AppSection?
    /// 打开主窗口（RootView 出现时用 openWindow 填上）：主窗口关着时点通知，用它把窗口重新打开
    @ObservationIgnored var openMainWindow: (@MainActor () -> Void)?

    static let shared = AppRouter()

    /// 把主窗口带到前面：最小化了就还原，关掉了就重新打开。
    @MainActor
    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let windows = NSApp.windows.filter { !($0 is NSPanel) && $0.frame.width > 800 }
        if let window = windows.first(where: { $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else if let window = windows.first(where: { $0.isMiniaturized }) {
            window.deminiaturize(nil)
        } else {
            shared.openMainWindow?()
        }
    }
}

/// 周复盘提醒：每周一条系统通知（默认周日 21:00，洞府设置里可改星期与时刻），点开直接进入修行录的复盘落笔。
/// 也是全应用唯一的通知代理：落笔时辰、功课时辰（标识 apt.write. / apt.habits. 开头）交给 DailyReminder.handle。
@MainActor
final class ReviewReminder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReviewReminder()
    nonisolated static let identifier = "apt.weekly-review"
    nonisolated static let enabledKey = "reminder.weeklyReview"
    /// 星期：1 = 周日 … 7 = 周六；时刻：当天第几分钟（AppPreferences.defaults，设置页的 @AppStorage 读写同一份）
    nonisolated static let weekdayKey = "reminder.weeklyReview.weekday"
    nonisolated static let minuteKey = "reminder.weeklyReview.minute"

    static var weekday: Int {
        ReminderPlan.clampWeekday((AppPreferences.defaults.object(forKey: weekdayKey) as? Int) ?? ReminderPlan.defaultWeeklyWeekday)
    }
    static var minute: Int {
        ReminderPlan.clampMinute((AppPreferences.defaults.object(forKey: minuteKey) as? Int) ?? ReminderPlan.defaultWeeklyMinute)
    }

    /// 由 AppHost 在应用启动时（启动完成之前）调用一次
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// 打开或关闭提醒；打开时先请求通知权限，返回是否成功。星期与时刻按设置里记下的（改了星期 / 时刻再调一次即可）。
    func setEnabled(_ on: Bool) async -> Bool {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        guard on else { return true }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = "该写周复盘了"
        content.body = "这一周所得、所失、所悟，落笔成卷。"
        content.sound = .default
        let when = ReminderPlan.weeklyComponents(weekday: Self.weekday, minute: Self.minute)
        let request = UNNotificationRequest(identifier: Self.identifier, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: true))
        do { try await center.add(request) } catch { return false }
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        // 落笔时辰、功课时辰：按标识前缀交给 DailyReminder
        if DailyReminder.handles(identifier) {
            await DailyReminder.handle(response)
            return
        }
        guard identifier == Self.identifier else { return }
        await MainActor.run {
            AppRouter.shared.chronicleCompose = .review
            AppRouter.shared.page = .chronicle
            // 主窗口关着（应用只在菜单栏）时，把它重新打开，否则点了通知没有任何反应
            AppRouter.showMainWindow()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
