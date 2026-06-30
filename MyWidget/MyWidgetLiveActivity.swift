//
//  MyWidgetLiveActivity.swift
//  MyWidget
//
//  Created by ak on 2022/11/11.
//

/*
 【实时活动在哪个 Target】
 本文件属于 Widget Extension（MyWidgetExtension）。系统渲染锁屏卡片、灵动岛时，
 只会加载扩展里的 SwiftUI，因此 ActivityConfiguration 必须写在这里（或与扩展同模块）。

 【SwiftUI 速览】
 - `View`：界面都由遵循 `View` 的结构体描述；核心是 `var body: some View { ... }`。
 - `some View`：“某种具体视图类型”，编译器帮你推断，无需手写很长泛型。
 - 修饰符链：`视图.padding().background()` 从上到下依次包裹，顺序会影响绘制结果。
 - `@ViewBuilder`：让函数可以写多个子视图/if 分支，编译器把它们合成一个视图。

 【ActivityKit 速览】
 - `ActivityAttributes`：一次实时活动的“模板 + 可变状态类型定义”。
 - `attributes`（`MyWidgetAttributes`）：创建活动后通常不变，如队名、赛事标题。
 - `ContentState`：会反复更新，如比分、进行时间；推送/本地 update 都是在更新它。
 */

import ActivityKit
import SwiftUI
import WidgetKit

/// 实时活动的数据模型：`Activity<MyWidgetAttributes>` 的泛型参数必须是这个类型。
public struct MyWidgetAttributes: ActivityAttributes {

    /// 可变状态：每次 `Activity.update(using:)` 或 APNs 下发，都是换一版 ContentState。
    /// 必须 `Codable` + `Hashable`，以便序列化与 diff。
    public struct ContentState: Codable, Hashable {
        public var homeScore: Int
        public var awayScore: Int
        /// 当前比赛时钟文案，例如 "75'"
        public var minuteText: String
        /// 首回合比分等辅助文案，不需要可传空字符串
        public var aggregateLine: String

        public init(
            homeScore: Int,
            awayScore: Int,
            minuteText: String,
            aggregateLine: String
        ) {
            self.homeScore = homeScore
            self.awayScore = awayScore
            self.minuteText = minuteText
            self.aggregateLine = aggregateLine
        }
    }

    /// 创建活动时写入，之后一般不再改（若改需走 API 语义，多数业务只更新 ContentState）。
    public var appName: String
    public var matchStageTitle: String
    public var homeTeamName: String
    public var awayTeamName: String
    /// 队徽 URL（网络地址）。Widget 不会直接拉，主 App 通过 `TeamBadgeCache.prefetch`
    /// 先把图片下到 App Group 共享目录，扩展端用 `UIImage(contentsOfFile:)` 读取。
    public var homeTeamLogoURL: String
    public var awayTeamLogoURL: String

    public init(
        appName: String,
        matchStageTitle: String,
        homeTeamName: String,
        awayTeamName: String,
        homeTeamLogoURL: String,
        awayTeamLogoURL: String
    ) {
        self.appName = appName
        self.matchStageTitle = matchStageTitle
        self.homeTeamName = homeTeamName
        self.awayTeamName = awayTeamName
        self.homeTeamLogoURL = homeTeamLogoURL
        self.awayTeamLogoURL = awayTeamLogoURL
    }
}

/// Widget 扩展的入口之一：在 MyWidgetBundle 里注册。
struct MyWidgetLiveActivity: Widget {

    /// 锁屏 / 通知中心的 tint 背景：固定深色，不跟随系统浅色模式。
    private static let activityTint = Color.black.opacity(0.92)

    /// `WidgetConfiguration` 告诉系统：这类 Live Activity 用哪套 Attributes、界面怎么画。
    var body: some WidgetConfiguration {
        // 第一个闭包：锁屏 / 通知中心里的大卡片 UI（与灵动岛无关）。
        ActivityConfiguration(for: MyWidgetAttributes.self) { context in
            lockScreenView(context)
                // 卡片背后系统叠的 tint：固定深底。
                .activityBackgroundTint(Self.activityTint)
                // 系统按钮（若存在）前景色。锁屏始终深底，可保持高亮白。
                .activitySystemActionForegroundColor(Color.white.opacity(0.9))

        } dynamicIsland: { context in
            /*
             【灵动岛三段 UI 是分开定制的】
             1) `DynamicIsland { ... }` 内：长按展开后，分 leading / trailing / bottom 等区域排版。
             2) `compactLeading` / `compactTrailing`：药丸左右两小块（仅一个活动时常见）。
             3) `minimal`：多个活动挤在一起时，岛上只显示最小的一点点。

             `context.attributes`：固定信息；`context.state`：当前 ContentState。
             */
            DynamicIsland {
                // 展开区 · leading：占住 TrueDepth 摄像头**左**侧那一带，放角标 + App 名。
                // 灵动岛恒为黑色药丸：强制子树走 .dark + 深色调色板，避免系统浅色时变白底白字。
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        MatchBrandMarkView()
                        Text(context.attributes.appName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.leading, 4)
                    .environment(\.colorScheme, .dark)
                    .environment(\.liveActivityPalette, LiveActivityPalette(scheme: .dark))
                }

                // 展开区 · trailing：摄像头**右**侧，放赛程标题。
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.matchStageTitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.82))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .padding(.trailing, 4)
                        .environment(\.colorScheme, .dark)
                        .environment(\.liveActivityPalette, LiveActivityPalette(scheme: .dark))
                }

                // 展开区 · 底部：只放三列比分体，header 已经拆到上面 leading/trailing 了。
                DynamicIslandExpandedRegion(.bottom) {
                    MatchScoreRow(
                        homeTeamName: context.attributes.homeTeamName,
                        awayTeamName: context.attributes.awayTeamName,
                        homeScore: context.state.homeScore,
                        awayScore: context.state.awayScore,
                        minuteText: context.state.minuteText,
                        aggregateLine: context.state.aggregateLine,
                        compact: false,
                        homeTeamLogoURL: context.attributes.homeTeamLogoURL,
                        awayTeamLogoURL: context.attributes.awayTeamLogoURL
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .environment(\.colorScheme, .dark)
                    .environment(\.liveActivityPalette, LiveActivityPalette(scheme: .dark))
                }

            } compactLeading: {
                // 紧凑态 · 左：主队队徽 + 主队得分（药丸常驻黑底，强制深色调色板）
                HStack(spacing: 3) {
                    MatchTeamBadgeView(
                        teamName: context.attributes.homeTeamName,
                        logoURL: context.attributes.homeTeamLogoURL,
                        size: 20
                    )
                    Text("\(context.state.homeScore)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                .environment(\.colorScheme, .dark)
                .environment(\.liveActivityPalette, LiveActivityPalette(scheme: .dark))
            } compactTrailing: {
                HStack(spacing: 3) {
                    Text("\(context.state.awayScore)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                    MatchTeamBadgeView(
                        teamName: context.attributes.awayTeamName,
                        logoURL: context.attributes.awayTeamLogoURL,
                        size: 20
                    )
                }
                .environment(\.colorScheme, .dark)
                .environment(\.liveActivityPalette, LiveActivityPalette(scheme: .dark))
            } minimal: {
                // 最小态：空间极小，一般只保留最关键数字
                Text("\(context.state.homeScore)-\(context.state.awayScore)")
                    .font(.caption2.weight(.heavy))
                    .monospacedDigit()
            }
            // 用户点整颗岛时系统会尝试打开这个 URL（需在主 App 配置 URL Scheme）。
            .widgetURL(URL(string: "liveactivitydemo://match"))
            // 岛外轮廓高亮色
            .keylineTint(Color(red: 0.93, green: 0.16, blue: 0.14))
        }
    }

    /// 锁屏卡片主体：固定深色（与灵动岛一致）。
    /// iOS 17+ 要求 Live Activity 锁屏内容必须显式声明 `.containerBackground(for: .widget)`，
    /// 否则一直打印 "widget background view is missing" 警告。`activityBackgroundTint` 不替代它。
    @ViewBuilder
    private func lockScreenView(_ context: ActivityViewContext<MyWidgetAttributes>) -> some View {
        LockScreenContainer(context: context)
    }

    private struct LockScreenContainer: View {
        let context: ActivityViewContext<MyWidgetAttributes>

        var body: some View {
            let palette = LiveActivityPalette(scheme: .dark)
            let content = MatchScoreboardContent(
                appName: context.attributes.appName,
                matchStageTitle: context.attributes.matchStageTitle,
                homeTeamName: context.attributes.homeTeamName,
                awayTeamName: context.attributes.awayTeamName,
                homeScore: context.state.homeScore,
                awayScore: context.state.awayScore,
                minuteText: context.state.minuteText,
                aggregateLine: context.state.aggregateLine,
                compact: false,
                homeTeamLogoURL: context.attributes.homeTeamLogoURL,
                awayTeamLogoURL: context.attributes.awayTeamLogoURL
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .environment(\.colorScheme, .dark)
            .environment(\.liveActivityPalette, palette)

            if #available(iOS 17.0, *) {
                content.containerBackground(for: .widget) {
                    palette.cardBackground
                }
            } else {
                content
            }
        }
    }
}
