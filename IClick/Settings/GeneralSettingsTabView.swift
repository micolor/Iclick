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
    // 必须显式指定 store：`.defaultAppStorage(UserDefaults.group)` 只加在 Scene 上时，
    // 这里的 @AppStorage 仍会落到 UserDefaults.standard（实测 onAppear 写出的
    // extensionEnabled 进了 standard），而菜单栏图标的 MenuBarExtra 读的是 group。
    // 两边不是同一个 store → 设置里把「在菜单栏显示」打开也不生效。
    @AppStorage("extensionEnabled", store: UserDefaults.group) private var extensionEnabled = false
    @AppStorage(Key.showMenuBarExtra, store: UserDefaults.group) private var showMenuBarExtra = true
    /// 与 IClickApp 启动时读取的是同一份存储（SharedSettings plist）。
    /// 之前这里用 @AppStorage 写 UserDefaults.standard，而 AppDelegate 读的是 plist，
    /// 两者不通 → 开关状态在下次启动时丢失。
    @State private var showInDock = SharedSettings.bool(forKey: Key.showInDock)
    /// FDA 只在进入设置页 / 从系统设置切回来时探测，不在渲染期间反复读受保护文件。
    @State private var fullDiskAccessStatus: Constants.FullDiskAccessStatus = Constants.fullDiskAccessStatus

    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            // 两项都由 macOS 管理，但机制完全不同：
            // 扩展启用决定「有没有菜单」，FDA 只决定「受保护路径里的动作能不能成功」。
            // 用整行可点击 + 右端状态/箭头，避免每行再放一个蓝色按钮造成视觉噪声。
            Section {
                permissionRow(
                    icon: "puzzlepiece.extension",
                    title: "Finder 扩展",
                    requirement: "必需",
                    description: "启用后 Finder 右键菜单里才会出现 IClick",
                    statusText: extensionEnabled ? "已启用" : "未启用",
                    statusColor: extensionEnabled ? .green : .orange
                ) {
                    FinderSync.FIFinderSyncController.showExtensionManagementInterface()
                }

                permissionRow(
                    icon: "lock.shield",
                    title: "完全磁盘访问",
                    requirement: "可选",
                    description: "仅在资源库、其他用户目录、外接磁盘等受保护位置操作文件时需要；授权后请重启 IClick",
                    statusText: fullDiskAccessStatus.title,
                    statusColor: fullDiskAccessStatus.tint
                ) {
                    openFullDiskAccessSettings()
                }
            } header: {
                HStack {
                    Text("权限与状态")
                    Spacer()
                    Button {
                        refreshPermissionStatus()
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("重新检测 Finder 扩展与完全磁盘访问状态")
                }
            } footer: {
                Text("两项都由 macOS 管理，IClick 只能打开对应设置，无法代替你开启；从系统设置返回后会自动重新检测。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        // 扩展启用状态只在用户离开本 App 去系统设置里改，回来时必然触发
        // didBecomeActive —— onForeground 已经覆盖了。原来那个 5 秒常驻定时器
        // 只是重复同一件事，窗口开着时每分钟白醒 12 次，去掉。
        .onForeground {
            // 用户可能刚从扩展管理面板或完全磁盘访问面板切回来。
            // 注意：TCC 对进程有缓存，刚授权时这里可能仍是「未授权」，
            // 需要退出并重开 IClick 才作数 —— 文案里已说明。
            refreshPermissionStatus()
        }
    }

    /// 整行可点击的权限行：左端图标 + 标题/说明，右端状态点和进入系统设置的箭头。
    /// 状态点使用固定 6pt 圆点，和文字基线对齐；两行的状态文字右对齐，避免按钮宽度不同造成错位。
    private func permissionRow(
        icon: String,
        title: String,
        requirement: String,
        description: String,
        statusText: String,
        statusColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                        Text(requirement)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func updateEnableState() {
        extensionEnabled = FIFinderSyncController.isExtensionEnabled
    }

    func refreshPermissionStatus() {
        updateEnableState()
        fullDiskAccessStatus = Constants.fullDiskAccessStatus
    }

    /// 打开系统设置的「完全磁盘访问」面板
    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

private extension Constants.FullDiskAccessStatus {
    var title: String {
        switch self {
        case .granted: "已授权"
        case .denied: "未授权"
        case .unknown: "无法判断"
        }
    }

    var tint: Color {
        switch self {
        case .granted: .green
        // FDA 是可选项：未授权用中性的灰点，不用橙色告警，
        // 否则会和「扩展未启用」这种真正影响主功能的状态混在一起。
        case .denied: .secondary
        case .unknown: .secondary
        }
    }
}
