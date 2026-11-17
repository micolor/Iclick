//
//  AboutSettingsTabView.swift
//  IClick
//
//  Created by 李旭 on 2024/4/4.
//

import AppKit
import FinderSync
import SwiftUI

struct AboutSettingsTabView: View {
    @EnvironmentObject var updateManager: UpdateManager

    var body: some View {
        VStack(spacing: 0) {
            // Header: Icon + Name + Version
            VStack(spacing: 10) {
                Image("Logo")
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                VStack(spacing: 4) {
                    Text("IClick")
                        .font(.title)
                        .fontWeight(.semibold)

                    Text("版本 \(Constants.appVersion) (\(getBuildVersion()))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            Divider()

            // Description
            VStack(spacing: 16) {
                Text("Finder 右键菜单扩展，支持自定义应用打开文件夹，并提供常用操作。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

            }
            .padding(.vertical, 20)

            Divider()

            // Check for Updates
            Button {
                Task {
                    // 用户手动点「检查更新」时忽略「忽略此版本」列表：
                    // 否则点过一次忽略之后，手动检查也永远看不到那个版本，
                    // 界面上还会错误地显示「您使用的就是最新版」。
                    await updateManager.checkForUpdates(force: true)
                }
            } label: {
                Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    func getBuildVersion() -> String {
        if let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            return buildVersion
        }
        return "Unknown"
    }
}

#Preview {
    AboutSettingsTabView()
}
