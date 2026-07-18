//
//  AppsSettingsTabView.swift
//  IClick
//
//  Created by 李旭 on 2024/11/18.
//

import AppKit
import SwiftUI

struct AppsSettingsTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var editingItem: OpenWithApp? = nil
    @State private var draggedItem: OpenWithApp? = nil
    @State private var dropTargetId: String? = nil

    let messager = Messager.shared

    var body: some View {
        Form {
            Section {
                if appState.apps.isEmpty {
                    HStack {
                        Image(systemName: "app.badge")
                            .foregroundStyle(.purple)
                        Text("未添加应用")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(appState.apps) { item in
                        appRow(item: item)
                            .onDrag {
                                draggedItem = item
                                return NSItemProvider(object: item.id as NSString)
                            }
                            .onDrop(of: [.text], delegate: AppDropDelegate(
                                item: item,
                                appState: appState,
                                draggedItem: $draggedItem,
                                dropTargetId: $dropTargetId
                            ))
                    }
                    .onDelete { indexSet in
                        appState.deleteApp(index: indexSet.first ?? 0)
                        messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: []))
                    }
                }
            } header: {
                HStack {
                    Text("常用 App")
                    Spacer()
                    Button {
                        let panel = NSOpenPanel()
                        panel.title = "选择应用"
                        panel.allowedContentTypes = [.application]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url {
                            appState.addApp(item: OpenWithApp(appURL: url))
                            messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: []))
                        }
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    Button {
                        appState.apps.removeAll()
                        appState.sync()
                        messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: []))
                    } label: {
                        Label("重置", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingItem) { item in
            AppEditSheet(item: item) { result in
                switch result {
                case .save(let name, let arguments, let environment, let icon):
                    appState.updateApp(
                        id: item.id,
                        itemName: name,
                        arguments: arguments,
                        environment: environment
                    )
                    if let idx = appState.apps.firstIndex(where: { $0.id == item.id }) {
                        appState.apps[idx].icon = icon
                    }
                    messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: []))
                case .cancel:
                    break
                }
                editingItem = nil
            }
        }
    }

    // MARK: - 列表行

    @ViewBuilder
    private func appRow(item: OpenWithApp) -> some View {
        let isDropTarget = dropTargetId == item.id

        HStack(spacing: 12) {
            if let icon = item.icon, !icon.isEmpty {
                if icon.contains("/") {
                    CustomIconView(path: icon, size: 18)
                } else {
                    Image(systemName: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                }
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            }

            Text(item.name)

            Spacer()

            // 位置标签：点击切换主菜单/子菜单
            Button {
                if let idx = appState.apps.firstIndex(where: { $0.id == item.id }) {
                    appState.apps[idx].showInMainMenu.toggle()
                    appState.sync()
                    messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: []))
                }
            } label: {
                Text(item.showInMainMenu ? "主菜单" : "子菜单")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(item.showInMainMenu ? Color.blue.opacity(0.15) : Color.purple.opacity(0.15))
                    )
                    .foregroundStyle(item.showInMainMenu ? .blue : .purple)
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { item.enabled },
                set: { newVal in
                    if let idx = appState.apps.firstIndex(where: { $0.id == item.id }) {
                        appState.apps[idx].enabled = newVal
                        appState.sync()
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(item.enabled ? "已启用" : "已禁用")
            .onTapGesture { }
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.15), value: dropTargetId)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            editingItem = item
        }
        .contextMenu {
            Button {
                editingItem = item
            } label: {
                Label("编辑", systemImage: "pencil")
            }

            Divider()

            Button {
                if let idx = appState.apps.firstIndex(where: { $0.id == item.id }), idx > 0 {
                    appState.apps.move(fromOffsets: IndexSet(integer: idx), toOffset: idx - 1)
                    appState.sync()
                    messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: []))
                }
            } label: {
                Label("上移", systemImage: "arrow.up")
            }
            .disabled(appState.apps.first?.id == item.id)

            Button {
                if let idx = appState.apps.firstIndex(where: { $0.id == item.id }), idx < appState.apps.count - 1 {
                    appState.apps.move(fromOffsets: IndexSet(integer: idx), toOffset: idx + 2)
                    appState.sync()
                    messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: []))
                }
            } label: {
                Label("下移", systemImage: "arrow.down")
            }
            .disabled(appState.apps.last?.id == item.id)

            Divider()

            Button(role: .destructive) {
                if let idx = appState.apps.firstIndex(where: { $0.id == item.id }) {
                    appState.deleteApp(index: idx)
                    messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: []))
                }
            } label: {
                Label("移除", systemImage: "trash")
            }
        }
    }
}

// MARK: - 拖拽排序 Delegate

struct AppDropDelegate: DropDelegate {
    let item: OpenWithApp
    let appState: AppState
    @Binding var draggedItem: OpenWithApp?
    @Binding var dropTargetId: String?

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        dropTargetId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedItem,
              draggedItem.id != item.id,
              let sourceIndex = appState.apps.firstIndex(where: { $0.id == draggedItem.id }),
              let destIndex = appState.apps.firstIndex(where: { $0.id == item.id })
        else { return }

        dropTargetId = item.id

        withAnimation(.easeInOut(duration: 0.2)) {
            appState.apps.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destIndex > sourceIndex ? destIndex + 1 : destIndex)
            appState.sync()
        }
    }

    func dropExited(info: DropInfo) {
        dropTargetId = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - 编辑 Sheet

enum AppEditResult {
    case save(name: String, arguments: [String], environment: [String: String], icon: String?)
    case cancel
}

struct AppEditSheet: View {
    let item: OpenWithApp
    let onResult: (AppEditResult) -> Void

    @State private var appName: String = ""
    @State private var appURL: URL?
    @State private var appIcon: String = ""
    @State private var showIconPicker = false

    var body: some View {
        VStack(spacing: 0) {
            Text("编辑应用")
                .font(.headline)
                .padding()

            Divider()

            VStack(spacing: 0) {
                // 显示名称
                HStack(spacing: 6) {
                    Text("显示名称:")
                        .frame(width: 75, alignment: .trailing)
                    TextField("", text: $appName)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider().padding(.horizontal)

                // 显示图标
                HStack(spacing: 6) {
                    Text("显示图标:")
                        .frame(width: 75, alignment: .trailing)

                    Button {
                        showIconPicker = true
                    } label: {
                        HStack(spacing: 8) {
                            if !appIcon.isEmpty && appIcon != item.icon {
                                if appIcon.contains("/") {
                                    CustomIconView(path: appIcon, size: 24)
                                } else {
                                    Image(systemName: appIcon)
                                        .font(.system(size: 24))
                                        .frame(width: 24, height: 24)
                                }
                            } else if let url = appURL {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 24, height: 24)
                            }
                            Text("点击可修改")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        appIcon = ""
                        appURL = item.url
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        let panel = NSOpenPanel()
                        panel.title = "选择应用"
                        panel.allowedContentTypes = [.application]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url {
                            appURL = url
                            appIcon = ""
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            Divider()

            HStack {
                Spacer()

                Button("取消") {
                    onResult(.cancel)
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    onResult(.save(name: appName, arguments: [], environment: [:], icon: appIcon.isEmpty ? nil : appIcon))
                }
                .buttonStyle(.borderedProminent)
                .disabled(appName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420, height: 200)
        .sheet(isPresented: $showIconPicker) {
            IconPickerSheet(
                selectedIcon: $appIcon,
                onDismiss: { showIconPicker = false }
            )
        }
        .onAppear {
            appURL = item.url
            appName = item.itemName
            appIcon = item.icon ?? ""
        }
    }
}
