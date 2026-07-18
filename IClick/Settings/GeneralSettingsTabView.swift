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
    @AppStorage(Key.showInDock) private var showInDock = false

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

            // Launch & Appearance
            Section {
                LaunchAtLogin.Toggle("登录时启动")
                Toggle("在菜单栏显示", isOn: $showMenuBarExtra)
                Toggle("在程序坞显示", isOn: $showInDock)
                    .onChange(of: showInDock) { _, newValue in
                        if newValue {
                            NSApp.setActivationPolicy(.regular)
                        } else {
                            NSApp.setActivationPolicy(.accessory)
                        }
                    }
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
}
