//
//  LiveActivityDemoApp.swift
//  LiveActivityDemo
//
//  Created by ak on 2022/11/15.
//

import SwiftUI
import ActivityKit

@main
struct LiveActivityDemoApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    
    var body: some Scene {
        WindowGroup {
            Home()
        }
    }
}

class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var backgroundTask: UIBackgroundTaskIdentifier?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        AppLog.app.notice("didFinishLaunching")
        let osVer = UIDevice.current.systemVersion
        AppLog.app.notice("[LA] iOS=\(osVer, privacy: .public) bundleId=\(Bundle.main.bundleIdentifier ?? "?", privacy: .public)")
        print("didFinishLaunching--xxxx")
        UNUserNotificationCenter.current().requestAuthorization { _, _ in
            
        }
        application.registerForRemoteNotifications()
        UNUserNotificationCenter.current().delegate = self
        LiveActivityUtils.observePushToStartTokens()
        LiveActivityUtils.observeNewActivities()
        Task { await LiveActivityUtils.reconcile() }
        return true
    }

    /// 方案 B 唤起入口：server 用 silent push 携带 `la_create` payload，
    /// 这里在后台读 payload → 本地 `Activity.request(pushType: .token)` 创建 →
    /// `observe()` 自动通过 `pushTokenUpdates` 拿到 activity push token 并上报。
    /// 需要：Background Modes → Remote notifications；apns-push-type: background；
    ///       apns-priority: 5；content-available: 1。
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        AppLog.push.notice("[LA] didReceiveRemoteNotification userInfo: \(userInfo, privacy: .public)")
        let bgTask = application.beginBackgroundTask(withName: "LA.silentPush") {
            completionHandler(.failed)
        }
        guard let payload = userInfo["la_create"] as? [String: Any] else {
            AppLog.push.notice("[LA] silent push without la_create, ignore")
            completionHandler(.noData)
            application.endBackgroundTask(bgTask)
            return
        }
        Task {
            await LiveActivityUtils.createFromSilentPush(payload)
            completionHandler(.newData)
            application.endBackgroundTask(bgTask)
        }
    }
    
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        AppLog.app.info("open url: \(url.absoluteString, privacy: .public)")
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        AppLog.push.notice("[LA] device token: \(token, privacy: .public)")
        Task { await ServerSync.uploadDeviceToken(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppLog.push.error("APNs register failed: \(error.localizedDescription, privacy: .public)")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        AppLog.push.notice("willPresent userInfo: \(notification.request.content.userInfo, privacy: .public)")
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        AppLog.push.notice("didReceive userInfo: \(response.notification.request.content.userInfo, privacy: .public)")
    }
}


