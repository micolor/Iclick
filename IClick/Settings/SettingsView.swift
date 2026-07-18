//
//  SettingsView.swift
//  IClick
//
//  Created by 李旭 on 2024/4/4.
//

import SwiftUI

enum Tabs: String, CaseIterable, Identifiable {
    case general = "General"
    case apps = "Apps"
    case actions = "Actions"
    case newFile = "New File"
    case cdirs = "Common Dir"
    case about = "About"

    var id: String { self.rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .apps: "app.badge"
        case .actions: "bolt"
        case .newFile: "doc.badge.plus"
        case .cdirs: "folder"
        case .about: "info.circle"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: .secondary
        case .apps: .purple
        case .actions: .orange
        case .newFile: .blue
        case .cdirs: .green
        case .about: .secondary
        }
    }
}

struct SettingsView: View {
    @State private var selectedTab: Tabs = .general
    @EnvironmentObject var appState: AppState
    @State var showSelectApp = false

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            // 应用图标
            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.top, 20)
                .padding(.bottom, 8)

            // 应用名称 + 版本号
            Text("IClick v\(Constants.appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)

            // 菜单列表
            List(selection: self.$selectedTab) {
                sidebarRow(tab: .general)
                sidebarRow(tab: .actions)
                sidebarRow(tab: .apps)
                sidebarRow(tab: .newFile)
                sidebarRow(tab: .cdirs)
                sidebarRow(tab: .about)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .navigationSplitViewColumnWidth(200)
    }

    @ViewBuilder
    private func sidebarRow(tab: Tabs) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tab.icon)
                .foregroundStyle(tab.iconColor)
                .frame(width: 20)
            Text(LocalizedStringKey(tab.rawValue))
        }
        .tag(tab)
    }

    @ViewBuilder var detailView: some View {
        Group {
            switch self.selectedTab {
            case .general:
                GeneralSettingsTabView()
            case .apps:
                AppsSettingsTabView()
            case .actions:
                ActionSettingsTabView()
            case .newFile:
                NewFileSettingsTabView()
            case .cdirs:
                CommonDirsSettingTabView()
            case .about:
                AboutSettingsTabView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 450, idealWidth: 600, maxWidth: 800)
    }

    var body: some View {
        NavigationSplitView {
            self.sidebar
        } detail: {
            self.detailView
        }
        .tint(.accentColor)
        .toolbar(removing: .sidebarToggle)
    }
}

#Preview {
    SettingsView()
}
