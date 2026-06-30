//
//  MyWidgetBundle.swift
//  MyWidget
//
//  Created by ak on 2022/11/15.
//

/*
 【扩展入口】
 `@main`：Widget Extension 进程的入口（类似 App 的 main）。
 `WidgetBundle`：把一个扩展里的多个 Widget / Live Activity 注册项打包；
 这里包含普通桌面小组件 `MyWidget()` 与实时活动 `MyWidgetLiveActivity()`。
 */

import SwiftUI
import WidgetKit

@main
struct MyWidgetBundle: WidgetBundle {
    var body: some Widget {
        MyWidget()
        MyWidgetLiveActivity()
    }
}
