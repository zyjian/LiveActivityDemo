//
//  AppLog.swift
//  LiveActivityDemo
//
//  统一日志入口：用 os.Logger 写入 unified logging system，
//  这样在 macOS 控制台里按 subsystem `com.zhu.LiveActivityDemo` 过滤就能看到，
//  包括 App 未启动时由系统侧（push-to-start / silent push 唤起）产生的日志。
//
//  在控制台菜单「操作」里勾选「包括信息消息 / 包括调试消息」才能看到 .info / .debug 级别。
//

import Foundation
import os

enum AppLog {
    static let subsystem = "com.zhu.LiveActivityDemo"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let push = Logger(subsystem: subsystem, category: "Push")
    static let liveActivity = Logger(subsystem: subsystem, category: "LiveActivity")
    static let badgeCache = Logger(subsystem: subsystem, category: "BadgeCache")
}
