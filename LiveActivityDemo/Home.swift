//
//  Home.swift
//  LiveActivityDemo
//
//  Created by ak on 2022/11/15.
//

/*
 【SwiftUI 页面骨架】
 - `struct Home: View`：声明这是一屏界面；必须实现 `body`。
 - `@State`：视图自带的可变状态；改了会自动刷新界面（与 UIKit 手动 reload 不同）。
 - `ScrollView` / `VStack`：纵向可滚容器里叠一组竖排子视图。
 - `Button`：点击触发闭包；内部若调用 `async` API，习惯包一层 `Task { await ... }`。
 */

import SwiftUI

struct Home: View {
    /// 与 Extension 里 attributes 同源的一份拷贝，用来驱动上方“预览卡片”。
    @State private var attrs = LiveActivityUtils.sampleAttributes()
    /// 与 Extension 里 ContentState 同源的一份拷贝；按钮会改它再 push 给系统。
    @State private var state = LiveActivityUtils.sampleInitialState()
    /// SwiftUI 不会感知缓存目录里新出现的图片文件，预下载完成后用这个 token 触发一次重建。
    @State private var badgeReloadToken = UUID()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("实时活动预览（锁屏样式近似）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                // 下方这一块只是 App 内预览，真正的锁屏 UI 由 Extension 渲染；
                // 但共用同一套 `MatchScoreboardContent`，样式可保持一致。
                MatchScoreboardContent(
                    appName: attrs.appName,
                    matchStageTitle: attrs.matchStageTitle,
                    homeTeamName: attrs.homeTeamName,
                    awayTeamName: attrs.awayTeamName,
                    homeScore: state.homeScore,
                    awayScore: state.awayScore,
                    minuteText: state.minuteText,
                    aggregateLine: state.aggregateLine,
                    compact: false,
                    homeTeamLogoURL: attrs.homeTeamLogoURL,
                    awayTeamLogoURL: attrs.awayTeamLogoURL
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
                .background(Color.black.opacity(0.92))
                // `clipShape`：按圆角矩形裁剪子视图，常用于卡片圆角。
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                // 队徽下载完后用 token 触发一次 SwiftUI 重建，让 UIImage(contentsOfFile:) 拿到新文件。
                .id(badgeReloadToken)

                VStack(alignment: .leading, spacing: 12) {
                    Button("开启实时活动") {
                        Task {
                            await LiveActivityUtils.request(attributes: attrs, state: state)
                        }
                    }

                    Button("模拟进球（客队 +1，含提醒）") {
                        state.awayScore += 1
                        state.minuteText = "\(minuteValue(from: state.minuteText) + 1)′"
                        LiveActivityUtils.update(state: state, alert: true)
                    }

                    Button("刷新比分（静默更新）") {
                        state.minuteText = "\(minuteValue(from: state.minuteText) + 5)′"
                        LiveActivityUtils.update(state: state, alert: false)
                    }

                    Button("结束实时活动", role: .destructive) {
                        Task { await LiveActivityUtils.end() }
                    }
                }
                .buttonStyle(.borderedProminent)
                // `frame(maxWidth: .infinity, alignment:)`：让整列在横向上尽量占满，文字仍左对齐。
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        // 进入页面就触发一次预下载；下载完更新 token，预览卡片重建并显示队徽。
        .task {
            await TeamBadgeCache.prefetch([attrs.homeTeamLogoURL, attrs.awayTeamLogoURL])
            badgeReloadToken = UUID()
        }
    }

    /// 从 "75′" / "75'" 解析分钟数，解析失败则返回 75。
    private func minuteValue(from text: String) -> Int {
        let digits = text.prefix { $0.isNumber }
        return Int(digits) ?? 75
    }
}

struct Home_Previews: PreviewProvider {
    static var previews: some View {
        Home()
    }
}
