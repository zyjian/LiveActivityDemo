//
//  LiveActivityUtils.swift
//  LiveActivityDemo
//
//  Created by ak on 2022/11/15.
//

/*
 【本文件角色】
 ActivityKit 调用收敛点：`request` 创建、`update` 更新、`end` 结束，以及
 push-to-start / activity push token 的统一上报。

 【单活动不变量（业务约束：一个用户同时只看一场比赛）】
 - 端上**至多一个** active Activity；reconcile() 会把多余的直接 end。
 - 监听器对同一 activity.id 幂等：不会重复挂 Task。
 - 任何让 Activity 离开 .active 的事件（dismissed / ended / stale）都会通知服务器
   清理对应 activityToken；由 stopObserving 返回值保证只清理一次。

 【调用时机】
 - App 启动：observePushToStartTokens() + observeNewActivities() + reconcile()
 - silent push 唤起：reconcile()
 - 本地 request() 创建完：内部会自动 observe
 */

import ActivityKit
import Foundation
import MyWidgetExtension
import UIKit

enum LiveActivityUtils {

    // MARK: - Public API

    /// push-to-start token（iOS 17.2+）。App 启动调用一次即可，循环常驻、自动处理轮换。
    static func observePushToStartTokens() {
        guard #available(iOS 17.2, *) else {
            AppLog.liveActivity.notice("[LA] push-to-start requires iOS 17.2+")
            return
        }
        Task {
            for await tokenData in Activity<MyWidgetAttributes>.pushToStartTokenUpdates {
                let token = tokenData.hexString
                AppLog.liveActivity.notice("[LA] push-to-start token: \(token, privacy: .public)")
                await ServerSync.uploadPushToStartToken(token)
            }
        }
    }

    /// 监听由系统（push-to-start）或本地新创建的 Activity。App 前台时 push-to-start 命中
    /// 既不会走 launch 也不会走 silent push，必须靠这条流挂上 token 观察者。
    /// 启动调用一次，循环常驻。
    /// 已在 registry 中的活动（启动时系统立即吐出的存量）会被跳过，避免与启动时的
    /// reconcile() 产生重复调用。
    /// - 注意：直接用 activityUpdates 吐出的 live 实例调用 observe()，避免用
    ///   Activity.activities 快照实例订阅 pushTokenUpdates 时错过首次 emit。
    static func observeNewActivities() {
        Task {
            for await activity in Activity<MyWidgetAttributes>.activityUpdates {
                AppLog.liveActivity.notice("[LA] activityUpdates: id=\(activity.id, privacy: .public)")
                guard await !registry.isObserving(activity.id) else { continue }
                AppLog.liveActivity.notice("[LA] activityUpdates: new activity, observing live instance")
                // 终止多余的 active（单活动不变量），但用 live activity 实例直接 observe
                await endStaleActivities(except: activity.id)
                await observe(activity)
            }
        }
    }

    /// 结束除 keepId 之外的所有 active Activity，并通知服务器清理 token。
    private static func endStaleActivities(except keepId: String) async {
        let stales = Activity<MyWidgetAttributes>.activities.filter {
            $0.id != keepId && $0.activityState == .active
        }
        await withTaskGroup(of: Void.self) { group in
            for act in stales {
                group.addTask {
                    AppLog.liveActivity.notice("[LA] ending stale id=\(act.id, privacy: .public)")
                    await act.end(dismissalPolicy: .immediate)
                    if await registry.stopObserving(act.id) {
                        await ServerSync.clearActivityToken(activityId: act.id)
                    }
                }
            }
        }
    }

    /// 统一收敛入口：保证单活动不变量，并对保留的 Activity 挂载监听（幂等）。
    /// 调用点：App 启动、silent push 唤起、本地 request 之后。
    /// - Returns: 当前在监听的 active 数量（0 或 1），可用于 silent push 的 fetchResult。
    @discardableResult
    static func reconcile() async -> Int {
        let all = Activity<MyWidgetAttributes>.activities
        AppLog.liveActivity.notice("[LA] reconcile: \(all.count, privacy: .public) activities found")

        // 非 active 的全部告知服务器清理（dismissed / ended / stale）
        for act in all where act.activityState != .active {
            if await registry.stopObserving(act.id) {
                await ServerSync.clearActivityToken(activityId: act.id)
            }
        }

        // active 中保留最后一个（系统按创建顺序返回），其余 end
        let actives = all.filter { $0.activityState == .active }
        guard let kept = actives.last else { return 0 }
        for stale in actives.dropLast() {
            AppLog.liveActivity.notice("[LA] reconcile: ending stale active id=\(stale.id, privacy: .public)")
            await stale.end(dismissalPolicy: .immediate)
            if await registry.stopObserving(stale.id) {
                await ServerSync.clearActivityToken(activityId: stale.id)
            }
        }

        await observe(kept)
        return 1
    }

    /// 申请新 Activity；先 await end() 确保旧活动完全结束后再创建，避免竞态。
    static func request(attributes: MyWidgetAttributes? = nil,
                        state: MyWidgetAttributes.ContentState? = nil) async {
        let appState = await MainActor.run { UIApplication.shared.applicationState }
        AppLog.liveActivity.notice("[LA] request: appState=\(appState.rawValue, privacy: .public) (0=active,1=inactive,2=background)")
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            AppLog.liveActivity.error("[LA] Live Activities not enabled")
            return
        }
        AppLog.liveActivity.notice("[LA] request: step 1 end() begin")
        await end()
        AppLog.liveActivity.notice("[LA] request: step 2 end() done")

        let attrs = attributes ?? sampleAttributes()
        let initial = state ?? sampleInitialState()
        await TeamBadgeCache.prefetch([attrs.homeTeamLogoURL, attrs.awayTeamLogoURL])
        AppLog.liveActivity.notice("[LA] request: step 3 prefetch done, calling Activity.request")

        do {
            let current = try Activity.request(attributes: attrs,
                                               contentState: initial,
                                               pushType: .token)
            AppLog.liveActivity.notice("[LA] request success id=\(current.id, privacy: .public)")
            await observe(current)
        } catch {
            AppLog.liveActivity.error("[LA] request error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 方案 B 入口：silent push 唤醒 app 后，从 payload 里读取 attributes / content_state，
    /// 本地走 `Activity.request(pushType: .token)` 创建。绕开 iOS 18 push-to-start
    /// 不分配 activity push token 的 bug。
    /// payload 结构（在 userInfo 顶层的 "la_create" 键下）：
    ///   {
    ///     "attributes": { appName, matchStageTitle, homeTeamName, awayTeamName,
    ///                     homeTeamLogoURL, awayTeamLogoURL },
    ///     "content_state": { homeScore, awayScore, minuteText, aggregateLine }
    ///   }
    static func createFromSilentPush(_ payload: [String: Any]) async {
        guard let attrs = parseAttributes(payload["attributes"] as? [String: Any]),
              let state = parseContentState(payload["content_state"] as? [String: Any]) else {
            AppLog.liveActivity.error("[LA] silent-push create: invalid la_create payload")
            return
        }
        AppLog.liveActivity.notice("[LA] silent-push create: home=\(state.homeScore, privacy: .public) away=\(state.awayScore, privacy: .public) minute=\(state.minuteText, privacy: .public)")
        await request(attributes: attrs, state: state)
    }

    private static func parseAttributes(_ dict: [String: Any]?) -> MyWidgetAttributes? {
        guard let dict,
              let appName = dict["appName"] as? String,
              let matchStageTitle = dict["matchStageTitle"] as? String,
              let homeTeamName = dict["homeTeamName"] as? String,
              let awayTeamName = dict["awayTeamName"] as? String,
              let homeTeamLogoURL = dict["homeTeamLogoURL"] as? String,
              let awayTeamLogoURL = dict["awayTeamLogoURL"] as? String else {
            return nil
        }
        return MyWidgetAttributes(
            appName: appName,
            matchStageTitle: matchStageTitle,
            homeTeamName: homeTeamName,
            awayTeamName: awayTeamName,
            homeTeamLogoURL: homeTeamLogoURL,
            awayTeamLogoURL: awayTeamLogoURL
        )
    }

    private static func parseContentState(_ dict: [String: Any]?) -> MyWidgetAttributes.ContentState? {
        guard let dict,
              let homeScore = dict["homeScore"] as? Int,
              let awayScore = dict["awayScore"] as? Int,
              let minuteText = dict["minuteText"] as? String,
              let aggregateLine = dict["aggregateLine"] as? String else {
            return nil
        }
        return MyWidgetAttributes.ContentState(
            homeScore: homeScore,
            awayScore: awayScore,
            minuteText: minuteText,
            aggregateLine: aggregateLine
        )
    }

    /// 本地更新 ContentState；`alert == true` 时附带横幅/提示音。
    static func update(state: MyWidgetAttributes.ContentState, alert: Bool = false) {
        Task {
            guard let current = Activity<MyWidgetAttributes>.activities
                .first(where: { $0.activityState == .active }) else {
                AppLog.liveActivity.notice("[LA] update skipped: no active activity")
                return
            }
            let cfg: AlertConfiguration? = alert
                ? AlertConfiguration(title: "比分更新",
                                     body: "\(state.homeScore) - \(state.awayScore) · \(state.minuteText)",
                                     sound: .default)
                : nil
            await current.update(using: state, alertConfiguration: cfg)
        }
    }

    /// 结束所有 active 并等待完成；通过 stopObserving 返回值保证服务器清理只触发一次。
    static func end() async {
        let actives = Activity<MyWidgetAttributes>.activities.filter { $0.activityState == .active }
        guard !actives.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for item in actives {
                group.addTask {
                    AppLog.liveActivity.notice("[LA] end activity \(item.id, privacy: .public)")
                    await item.end(dismissalPolicy: .immediate)
                    if await registry.stopObserving(item.id) {
                        await ServerSync.clearActivityToken(activityId: item.id)
                    }
                }
            }
        }
    }

    // MARK: - Samples

    static func sampleAttributes() -> MyWidgetAttributes {
        MyWidgetAttributes(
            appName: "Demo",
            matchStageTitle: "欧冠 半决赛 次回合",
            homeTeamName: "拜仁慕尼黑",
            awayTeamName: "巴黎圣日耳曼",
            homeTeamLogoURL: "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1b/FC_Bayern_M%C3%BCnchen_logo_%282017%29.svg/120px-FC_Bayern_M%C3%BCnchen_logo_%282017%29.svg.png",
            awayTeamLogoURL: "https://upload.wikimedia.org/wikipedia/en/thumb/a/a7/Paris_Saint-Germain_F.C..svg/120px-Paris_Saint-Germain_F.C..svg.png"
        )
    }

    static func sampleInitialState() -> MyWidgetAttributes.ContentState {
        MyWidgetAttributes.ContentState(
            homeScore: 0,
            awayScore: 1,
            minuteText: "75′",
            aggregateLine: "首回合 4-5"
        )
    }

    // MARK: - Internals

    /// 对 Activity 挂监听，按 activity.id 幂等去重，避免 reconcile 反复调用时泄漏 Task。
    private static func observe(_ activity: Activity<MyWidgetAttributes>) async {
        let firstTime = await registry.startObserving(activity.id)
        guard firstTime else { return }
        AppLog.liveActivity.notice("[LA] observe id=\(activity.id, privacy: .public)")

        // push-to-start 创建的 activity，token 可能在首次订阅 stream 前已就绪，
        // 先同步读取一次作为保底，避免 stream 因为 token 已 emit 而错过首值。
        if let tokenData = activity.pushToken {
            let token = tokenData.hexString
            AppLog.liveActivity.notice("[LA] activity push token (sync)\n  id=\(activity.id, privacy: .public)\n  token=\(token, privacy: .public)")
            await ServerSync.uploadActivityToken(activityId: activity.id, token: token)
        } else {
            AppLog.liveActivity.notice("[LA] pushToken nil at observe time, waiting stream id=\(activity.id, privacy: .public)")
        }

        // pushToken stream：之后每次 rotation 触发（push-to-start 首次可能延迟 emit）
        Task {
            AppLog.liveActivity.notice("[LA] pushTokenUpdates subscribed id=\(activity.id, privacy: .public)")
            for await data in activity.pushTokenUpdates {
                let token = data.hexString
                AppLog.liveActivity.notice("[LA] activity push token (stream)\n  id=\(activity.id, privacy: .public)\n  token=\(token, privacy: .public)")
                await ServerSync.uploadActivityToken(activityId: activity.id, token: token)
            }
        }

        // activityState：离开 .active 即清理；stopObserving 返回 true 才上报，
        // 确保本地 end() 和此处不会各自触发一次 clearActivityToken。
        Task {
            for await state in activity.activityStateUpdates {
                AppLog.liveActivity.notice("[LA] state id=\(activity.id, privacy: .public) → \(String(describing: state), privacy: .public)")
                if state != .active {
                    if await registry.stopObserving(activity.id) {
                        await ServerSync.clearActivityToken(activityId: activity.id)
                    }
                    break
                }
            }
        }

        // contentState：调试用，可按需移除。
        Task {
            for await cs in activity.contentStateUpdates {
                AppLog.liveActivity.info("[LA] content \(cs.homeScore, privacy: .public)-\(cs.awayScore, privacy: .public) \(cs.minuteText, privacy: .public)")
            }
        }
    }

    private static let registry = ObservationRegistry()

    /// actor 串行化 observed set 的读写，避免多个 Task 并发触发重复订阅或重复清理。
    private actor ObservationRegistry {
        private var observed: Set<String> = []
        func startObserving(_ id: String) -> Bool { observed.insert(id).inserted }
        /// 返回 true 表示该 id 确实在 set 中并被移除（首次停止），false 表示已被移除过。
        @discardableResult
        func stopObserving(_ id: String) -> Bool { observed.remove(id) != nil }
        func isObserving(_ id: String) -> Bool { observed.contains(id) }
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// 端上 → 后端的 token 同步。base URL 从 Info.plist `LADemoServerBaseURL` 读取
/// （默认 `http://127.0.0.1:8000`）。真机调试改成局域网 IP，例如 `http://192.168.x.x:8000`。
///
/// 失败仅记日志、不重试：MVP 行为。生产应加本地落库 + 启动/前台补传。
enum ServerSync {
    static func uploadDeviceToken(_ token: String) async {
        await post("/api/tokens/device", body: ["token": token], kind: "device")
    }
    static func uploadPushToStartToken(_ token: String) async {
        await post("/api/tokens/push-to-start", body: ["token": token], kind: "push-to-start")
    }
    static func uploadActivityToken(activityId: String, token: String, matchId: String? = nil) async {
        var body: [String: Any] = ["activity_id": activityId, "token": token]
        if let matchId { body["match_id"] = matchId }
        await post("/api/tokens/activity", body: body, kind: "activity")
    }
    static func clearActivityToken(activityId: String) async {
        await post("/api/tokens/activity/clear", body: ["activity_id": activityId], kind: "activity.clear")
    }

    // MARK: - Internals

    private static let baseURL: URL = {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "LADemoServerBaseURL") as? String) ?? "http://127.0.0.1:8000"
        return URL(string: raw) ?? URL(string: "http://127.0.0.1:8000")!
    }()

    private static func post(_ path: String, body: [String: Any], kind: String) async {
        guard let url = URL(string: path, relativeTo: baseURL) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            AppLog.liveActivity.notice("[LA] sync \(kind, privacy: .public) → \(code, privacy: .public)")
        } catch {
            AppLog.liveActivity.error("[LA] sync \(kind, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
