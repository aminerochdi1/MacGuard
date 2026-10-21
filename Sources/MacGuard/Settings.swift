import Foundation
import UserNotifications
import ServiceManagement

final class Settings: ObservableObject {
    enum ThemeChoice: String, CaseIterable { case system = "System", light = "Light", dark = "Dark" }

    private static let d = UserDefaults.standard
    private static func flag(_ k: String, _ def: Bool) -> Bool { (d.object(forKey: k) as? Bool) ?? def }

    /// Called after any change (on the main thread) so the app can push the new config to the monitor.
    var onChange: (() -> Void)?

    @Published var theme: ThemeChoice { didSet { Self.d.set(theme.rawValue, forKey: "theme"); onChange?() } }
    @Published var tempSensors: Bool { didSet { Self.d.set(tempSensors, forKey: "tempSensors"); onChange?() } }
    @Published var alerts: Bool { didSet { Self.d.set(alerts, forKey: "alerts"); if alerts { Notifier.shared.requestAuthorization() }; onChange?() } }
    @Published var notifyHeat: Bool { didSet { Self.d.set(notifyHeat, forKey: "notifyHeat"); onChange?() } }
    @Published var notifySuspect: Bool { didSet { Self.d.set(notifySuspect, forKey: "notifySuspect"); onChange?() } }
    @Published var keepInBackground: Bool { didSet { Self.d.set(keepInBackground, forKey: "keepInBackground"); onChange?() } }
    @Published var minerAutoCheck: Bool { didSet { Self.d.set(minerAutoCheck, forKey: "minerAutoCheck"); onChange?() } }
    @Published var saveLogs: Bool { didSet { Self.d.set(saveLogs, forKey: "saveLogs"); onChange?() } }
    @Published var logPath: String { didSet { Self.d.set(logPath, forKey: "logPath"); onChange?() } }

    @Published var loginError: String?
    private var suppressLogin = false
    @Published var launchAtLogin: Bool {
        didSet {
            guard !suppressLogin else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginError = nil
            } catch {
                suppressLogin = true
                launchAtLogin = !launchAtLogin
                suppressLogin = false
                loginError = "Couldn’t change the login item: \(error.localizedDescription). It usually works once the app is in /Applications."
            }
        }
    }

    init() {
        let d = Settings.d
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .light   // Steep is a light theme
        tempSensors = Settings.flag("tempSensors", true)
        alerts = Settings.flag("alerts", true)
        notifyHeat = Settings.flag("notifyHeat", true)
        notifySuspect = Settings.flag("notifySuspect", true)
        keepInBackground = Settings.flag("keepInBackground", true)
        minerAutoCheck = Settings.flag("minerAutoCheck", true)
        saveLogs = Settings.flag("saveLogs", true)
        logPath = d.string(forKey: "logPath") ?? (NSHomeDirectory() + "/Library/Logs/MacGuard")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var config: Monitor.Config {
        Monitor.Config(tempSensors: tempSensors, alerts: alerts, notifyHeat: notifyHeat,
                       notifySuspect: notifySuspect, saveLogs: saveLogs, logPath: logPath,
                       minerAutoCheck: minerAutoCheck)
    }
}

// MARK: - Notifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// UserNotifications crashes outside a real .app bundle (e.g. `swift run`), so guard it.
    private var usable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func setup() {
        guard usable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        guard usable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(id: String, title: String, body: String) {
        guard usable else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let req = UNNotificationRequest(identifier: id + "-\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    // Show banners even while MacGuard is the frontmost app
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
