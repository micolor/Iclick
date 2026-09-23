//
//  SettingsWindow.swift
//  IClick
//
//  Created by 李旭 on 2024/9/25.
//

import SwiftUI

struct SettingsWindow: Scene {
    @ObservedObject var appState: AppState

    @EnvironmentObject var updateManager: UpdateManager

    let onAppear: () -> Void

    var body: some Scene {
        Window("Settings", id: Constants.settingsWindowID) {
            SettingsView()
                .environmentObject(appState)
                .onAppear {
                    onAppear()
                }
                .frame(minWidth: 800, minHeight: 500)
                .sheet(isPresented: $updateManager.showUpdateSheet) {
                    UpdateView(updateManager: updateManager)
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 800, height: 500)
        // 启动时不要把这个窗口开出来。
        // 手记：SwiftUI 的 Window 场景默认在每次进程启动时present一次，所以扩展
        // 一旦把主应用冷启动起来（launchHostApp），用户的屏幕上就会冒出设置窗口 ——
        // 这正是「右键点一下菜单项，管理界面就弹出来」的原因（2026-09-23 实测：
        // 冷启动后 1~12 秒窗口数稳定为 1，加 -ApplePersistenceIgnoreState YES 仍是 1，
        // 排除窗口状态恢复）。suppressed 只影响「启动时自动呈现」，
        // 菜单栏里的 openWindow(id:) 照常能打开。
        .defaultLaunchBehavior(.suppressed)
    }

}
