//
//  UpdaterView.swift
//  IClick
//
//  Created by 李旭 on 2025/9/21.
//

#if !APP_STORE

import SwiftUI

struct UpdateView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var updateManager: UpdateManager

    private var appIcon: Image {
        Image(nsImage: NSApplication.shared.applicationIconImage)
    }

    var body: some View {
        VStack(spacing: 0) {
            if updateManager.isChecking {
                checkingView
            } else if updateManager.isDownloading {
                downloadingView
            } else if let release = updateManager.availableUpdate {
                updateAvailableView(release)
            } else if let error = updateManager.updateError {
                errorView(error)
            } else {
                noUpdateView
            }
        }
        .frame(width: 360)
    }

    // MARK: - 顶部图标区域（共享）

    @ViewBuilder
    private func headerSection(title: String, subtitle: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 14) {
            appIcon
                .resizable()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: - 正在检查

    private var checkingView: some View {
        VStack(spacing: 0) {
            Text("软件更新")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)

            Divider()

            HStack(alignment: .top, spacing: 14) {
                appIcon
                    .resizable()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    Text("正在检查更新...")
                        .font(.headline)
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button {
                    updateManager.dismissUpdateSheet()
                } label: {
                    Text("取消")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
        }
    }

    // MARK: - 正在下载

    private var downloadingView: some View {
        VStack(spacing: 0) {
            headerSection(
                title: "正在下载更新…",
                subtitle: "\(Int(updateManager.downloadProgress * 100))%"
            )

            ProgressView(value: updateManager.downloadProgress)
                .progressViewStyle(.linear)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            Divider()

            HStack {
                Spacer()
                Button("取消") {
                    updateManager.dismissUpdateSheet()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding(12)
        }
    }

    // MARK: - 有可用更新

    private func updateAvailableView(_ release: GitHubRelease) -> some View {
        VStack(spacing: 0) {
            headerSection(
                title: "发现新版本",
                subtitle: "版本 \(release.version)"
            )

            ScrollView {
                Text(release.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            HStack(spacing: 12) {
                Button("稍后") {
                    updateManager.dismissUpdateSheet()
                }
                .keyboardShortcut(.cancelAction)

                Button("忽略此版本") {
                    updateManager.ignoreCurrentUpdate()
                    updateManager.dismissUpdateSheet()
                }

                Spacer()

                Button("下载并安装") {
                    Task {
                        await updateManager.downloadAndInstallUpdate()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
            }
            .padding(16)
        }
    }

    // MARK: - 已是最新

    private var noUpdateView: some View {
        VStack(spacing: 0) {
            headerSection(
                title: "您使用的就是最新版！",
                subtitle: "IClick \(Constants.appVersion) 是当前的最新版本。"
            )

            Divider()

            HStack {
                Spacer()
                Button("好") {
                    updateManager.dismissUpdateSheet()
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    // MARK: - 检查失败

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 0) {
            headerSection(
                title: "检查更新失败",
                subtitle: error
            )

            Divider()

            HStack {
                Spacer()
                Button("好") {
                    updateManager.dismissUpdateSheet()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }
}

#endif
