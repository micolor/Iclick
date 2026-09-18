//
//  GeneralSettingsTabView.swift
//  IClick
//
//  Created by 李旭 on 2024/4/10.
//

import AppKit
import FinderSync
import SwiftUI

struct GeneralSettingsTabView: View {
    @AppStorage("extensionEnabled") private var extensionEnabled = false
    @AppStorage(Key.showMenuBarExtra) private var showMenuBarExtra = true
    /// 与 IClickApp 启动时读取的是同一份存储（SharedSettings plist）。
    /// 之前这里用 @AppStorage 写 UserDefaults.standard，而 AppDelegate 读的是 plist，
    /// 两者不通 → 开关状态在下次启动时丢失。
    @State private var showInDock = SharedSettings.bool(forKey: Key.showInDock)

    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            // Extension
            Section {
                HStack {
                    Text("启用扩展")
                    Spacer()
                    Button("打开系统设置") {
                        FinderSync.FIFinderSyncController.showExtensionManagementInterface()
                    }
                }
                HStack {
                    Image(systemName: extensionEnabled ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(extensionEnabled ? .green : .secondary)
                    Text(extensionEnabled ? "扩展已启用" : "扩展未启用")
                        .foregroundStyle(.secondary)
                }
            }

            // Full Disk Access：右键菜单要在所有目录生效，必须授权
            Section {
                HStack {
                    Text("右键菜单在所有目录生效")
                    Spacer()
                    Button("授权完全磁盘访问") {
                        openFullDiskAccessSettings()
                    }
                }
                Text("FinderSync 扩展受沙盒限制，未授权前只能在已授权目录显示菜单。授权后可在任意目录使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Launch & Appearance
            Section {
                LaunchAtLogin.Toggle("登录时启动")
                Toggle("在菜单栏显示", isOn: $showMenuBarExtra)
                Toggle("在程序坞显示", isOn: Binding(
                    get: { showInDock },
                    set: { newValue in
                        showInDock = newValue
                        SharedSettings.set(newValue, forKey: Key.showInDock)
                        SharedSettings.synchronize()
                        NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                    }
                ))
            }

            // Authorized Folders List — 已隐藏，授权由右键菜单自动引导
        }
        .formStyle(.grouped)
        .onAppear {
            extensionEnabled = FIFinderSyncController.isExtensionEnabled
        }
        .onForeground {
            updateEnableState()
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            let newState = FIFinderSyncController.isExtensionEnabled
            if extensionEnabled != newState {
                extensionEnabled = newState
            }
        }
    }

    func updateEnableState() {
        extensionEnabled = FIFinderSyncController.isExtensionEnabled
    }

    /// 打开系统设置的「完全磁盘访问」面板
    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
