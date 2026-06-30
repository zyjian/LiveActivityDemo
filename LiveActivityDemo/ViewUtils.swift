//
//  ViewUtils.swift
//  LiveActivityDemo
//
//  Created by ak on 2022/11/15.
//

/*
 【SwiftUI 常用容器（比分板主要靠它们排版）】
 - `VStack`：Vertical Stack，子视图**竖直**排列；`spacing` 控制相邻间距。
 - `HStack`：Horizontal Stack，子视图**水平**排列。
 - `ZStack`：Depth Stack，子视图**叠在一起**（类似 PSD 图层）；常用于徽章底图+图标。
 - `Spacer()`：在 Stack 里占位“吃掉剩余空间”，把两侧内容顶到两头。
 - `some View`：函数的返回值类型占位，表示“某一种 View”，具体类型由编译器推断。

 【修饰符（modifier）】
 写在视图后面的 `.font(...) .foregroundStyle(...)` 等都是修饰符；
 顺序很重要：例如先 `padding` 再 `background`，背景会包住带内边距后的尺寸。

 【本文件被两处编译】
 LiveActivityDemo 主 Target 与 MyWidgetExtension 都加入了此文件，
 因此这里的视图可同时用于：App 内预览 + 真正的 Live Activity UI。
 */

import CryptoKit
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/*
 【网络队徽缓存（参考 GTBizWidget 的做法）】
 Widget Extension 沙盒里不能稳定跑 URLSession/AsyncImage：
 - 系统会很快冻结扩展进程，下载常常拿不到结果；
 - 即使拿到，Live Activity 也不允许把 UIImage/Data 塞进 ContentState（4KB 上限）。

 所以策略是：
 1) **主 App** 在 `Activity.request` / `update` 前用 URLSession 把队徽下载到 **App Group 共享目录**；
 2) Attributes/ContentState 里**只传 URL 字符串**（路径用 URL 经 SHA256 推导，跨进程稳定）；
 3) Widget 端用 `UIImage(contentsOfFile:)` 读本地文件，读不到时回退到首字占位。

 ⚠️ 必须先做：
 - 在 Apple Developer 后台注册一个 App Group，例如 `group.com.gate.liveactivitydemo`；
 - 在 Xcode → LiveActivityDemo / MyWidgetExtension 两个 target 的 Signing & Capabilities 里都勾上同一个 App Group；
 - 同步修改下方 `TeamBadgeCache.appGroupID`。
 没配 App Group 时会回退到各自 Target 的 caches 目录——主 App 写的文件 Widget 看不到，Widget 端只能显示兜底首字。
 */
enum TeamBadgeCache {
    /// 在两个 Target 的 .entitlements 与 Developer 后台保持一致。
    static let appGroupID = "group.com.gate.liveactivitydemo"

    /// 共享缓存子目录：`<AppGroupContainer>/team_badges/`。
    private static var directory: URL? {
        let fm = FileManager.default
        if let base = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return base.appendingPathComponent("team_badges", isDirectory: true)
        }
        // 兜底：仅当前进程可见，主 App / Widget 互相读不到。生产前请务必配置 App Group。
        return fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("team_badges", isDirectory: true)
    }

    /// URL → 稳定文件名。Swift 的 `Hasher` 带每进程随机 seed，跨进程不一致，必须用 SHA256。
    private static func filename(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).img"
    }

    /// Widget 渲染时调用：拿到则返回绝对路径，没拿到（未下载/下载失败）返回 nil → 用占位。
    static func localPath(for url: String?) -> String? {
        guard let url, !url.isEmpty, let dir = directory else { return nil }
        let file = dir.appendingPathComponent(filename(for: url))
        return FileManager.default.fileExists(atPath: file.path) ? file.path : nil
    }

    /// 主 App 在 `Activity.request` / `update` 之前调用，把网络图固化到共享目录。
    /// 已存在则跳过，避免每次开活动都重下。
    @discardableResult
    static func prefetch(_ urlString: String) async -> String? {
        guard let dir = directory,
              let remote = URL(string: urlString) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(filename(for: urlString))
        if FileManager.default.fileExists(atPath: dest.path) {
            return dest.path
        }
        do {
            let (tmpURL, response) = try await URLSession.shared.download(from: remote)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                AppLog.badgeCache.error("HTTP \(http.statusCode, privacy: .public) for \(urlString, privacy: .public)")
                return nil
            }
            // `download` 给的临时文件函数返回后会被系统清理，必须立刻 move。
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmpURL, to: dest)
            return dest.path
        } catch {
            AppLog.badgeCache.error("prefetch failed for \(urlString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 并行预下载多张图。返回时所有任务都已结束（成功或失败）。
    static func prefetch(_ urls: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for u in urls {
                group.addTask { _ = await prefetch(u) }
            }
        }
    }
}

/// 示例遗留组件（圆形 SF Symbol）；当前比分 Demo 主要用下面的 Match* 视图。
class MyViews {
    /// `@ViewBuilder`：允许在闭包里写多个视图/if，编译器合成一棵视图树。
    @ViewBuilder
    static func CirclrIcon(_ name: String, color: Color = .red) -> some View {
        Circle()
            .foregroundColor(color)
            .overlay {
                Image(systemName: name)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(.white)
                    .padding(5)
                    .bold()
            }
    }
}

// MARK: - 足球比分实时活动（锁屏预览 / Widget 共用）

/*
 【深色 / 浅色配色】
 - 锁屏 Live Activity 固定深色，不跟随系统浅色模式。
 - 灵动岛药丸恒为黑色：Widget 里用 `.environment(\.colorScheme, .dark)` 强制深色调色板。
 - 用统一的 `LiveActivityPalette` 集中色值，所有文字/分割线/背景从这里取。
 */
struct LiveActivityPalette {
    let scheme: ColorScheme

    var primaryText: Color { scheme == .dark ? .white : .black }
    var secondaryText: Color { primaryText.opacity(0.78) }
    var tertiaryText: Color { primaryText.opacity(0.62) }
    /// 队徽圆形底色：深色时给一点白雾，浅色时给一点黑雾，否则平铺一片看不清。
    var badgeFill: Color { scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.06) }
    var badgeStroke: Color { primaryText.opacity(0.12) }
    /// 卡片背景：锁屏 / 通知中心用，灵动岛背景由系统画黑色，不靠这层。
    var cardBackground: Color { scheme == .dark ? Color.black.opacity(0.92) : Color(white: 0.97) }
}

private struct LiveActivityPaletteKey: EnvironmentKey {
    static let defaultValue = LiveActivityPalette(scheme: .dark)
}

extension EnvironmentValues {
    var liveActivityPalette: LiveActivityPalette {
        get { self[LiveActivityPaletteKey.self] }
        set { self[LiveActivityPaletteKey.self] = newValue }
    }
}

/// 左上角品牌角标：`ZStack` 叠一层红底矩形 + 白色闪电 SF Symbol。
/// 上线可整体替换为 `Image("your_logo").resizable()` 等素材。
struct MatchBrandMarkView: View {
    var body: some View {
        // gate_logo_new 已同时拷贝到主 App 和 Widget Extension 的 Assets.xcassets，
        // 两个 Target 的 Bundle 都能解析到。
        Image("gate_logo_new")
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
            .accessibilityLabel(Text("App"))
    }
}

/// 队徽视图：优先用 `logoURL` 对应的本地缓存文件渲染；缓存未命中时退化为首字占位。
/// 注意：这里**不会**直接从网络拉取——下载由主 App 通过 `TeamBadgeCache.prefetch` 完成。
struct MatchTeamBadgeView: View {
    let teamName: String
    /// 网络队徽 URL（建议是 PNG/WebP，SVG 不能直接被 UIImage 解码）。
    var logoURL: String? = nil
    /// 圆形直径。锁屏/展开态默认 44；灵动岛 compact 药丸用 ~20。
    var size: CGFloat = 44

    private var monogram: String {
        guard let ch = teamName.first else { return "?" }
        return String(ch)
    }

    /// 在 body 里查询本地路径 + 解码 UIImage；命中时返回 nil 之外的 Image。
    private var cachedBadge: UIImage? {
        guard let path = TeamBadgeCache.localPath(for: logoURL) else { return nil }
        return UIImage(contentsOfFile: path)
    }

    @Environment(\.liveActivityPalette) private var palette

    var body: some View {
        ZStack {
            Circle().fill(palette.badgeFill)
            if let ui = cachedBadge {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Text(monogram)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
            }
            Circle().stroke(palette.badgeStroke, lineWidth: 1)
        }
        .frame(width: size, height: size)
    }
}

/// 深色比分板：`body` 里用 `VStack` 分两大行——上行标题栏、下行主客队+中间信息。
/// `compact == true` 时收紧字号与间距，给灵动岛展开区等窄宽度用。
struct MatchScoreboardContent: View {
    let appName: String
    let matchStageTitle: String
    let homeTeamName: String
    let awayTeamName: String
    let homeScore: Int
    let awayScore: Int
    /// 例如 "75'"
    let minuteText: String
    /// 例如 "首回合 4-5"，不需要可为空字符串
    let aggregateLine: String
    /// 灵动岛等窄布局时收紧排版
    var compact: Bool = false
    /// 主队队徽 URL（被 `TeamBadgeCache` 解析为本地文件）
    var homeTeamLogoURL: String? = nil
    /// 客队队徽 URL
    var awayTeamLogoURL: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            MatchHeaderRow(appName: appName, matchStageTitle: matchStageTitle, compact: compact)
            MatchScoreRow(
                homeTeamName: homeTeamName,
                awayTeamName: awayTeamName,
                homeScore: homeScore,
                awayScore: awayScore,
                minuteText: minuteText,
                aggregateLine: aggregateLine,
                compact: compact,
                homeTeamLogoURL: homeTeamLogoURL,
                awayTeamLogoURL: awayTeamLogoURL
            )
        }
    }

}

/// 顶栏：App 角标+App 名，右侧赛程标题。拆出来好让灵动岛 leading/trailing 单独复用。
struct MatchHeaderRow: View {
    let appName: String
    let matchStageTitle: String
    var compact: Bool = false

    @Environment(\.liveActivityPalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                MatchBrandMarkView()
                Text(appName)
                    .font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
            }
            Spacer(minLength: 8)
            Text(matchStageTitle)
                .font(.system(size: compact ? 10 : 11, weight: .regular))
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
    }
}

/// 三列比分体：主队 | 时钟 | 客队。拆出来好让灵动岛 bottom region 直接复用，省掉重复 header。
struct MatchScoreRow: View {
    let homeTeamName: String
    let awayTeamName: String
    let homeScore: Int
    let awayScore: Int
    let minuteText: String
    let aggregateLine: String
    var compact: Bool = false
    var homeTeamLogoURL: String? = nil
    var awayTeamLogoURL: String? = nil

    @Environment(\.liveActivityPalette) private var palette

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 8 : 12) {
            teamColumn(name: homeTeamName, score: homeScore, logoURL: homeTeamLogoURL)
            centerColumn
            teamColumn(name: awayTeamName, score: awayScore, logoURL: awayTeamLogoURL)
        }
    }

    private func teamColumn(name: String, score: Int, logoURL: String?) -> some View {
        VStack(spacing: compact ? 4 : 6) {
            MatchTeamBadgeView(teamName: name, logoURL: logoURL)
            Text(name)
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.center)
            Text("\(score)")
                .font(.system(size: compact ? 28 : 34, weight: .bold))
                .foregroundStyle(palette.primaryText)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private var centerColumn: some View {
        VStack(spacing: compact ? 2 : 4) {
            Text(minuteText)
                .font(.system(size: compact ? 17 : 20, weight: .semibold))
                .foregroundStyle(palette.primaryText)
                .monospacedDigit()
            if !aggregateLine.isEmpty {
                Text(aggregateLine)
                    .font(.system(size: compact ? 10 : 11, weight: .regular))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(minWidth: compact ? 56 : 72)
    }
}
