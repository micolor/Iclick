//
//  CommonDirsSettingTabView.swift
//  IClick
//
//  Created by 李旭 on 2024/4/10.
//

import AppKit
import SwiftUI

struct CommonDirsSettingTabView: View {
    @AppLog(category: "settings-common-dirs")
    private var logger

    @EnvironmentObject var appState: AppState

    @State private var editingItem: CommonDir? = nil
    @State private var draggedItem: CommonDir? = nil
    @State private var dropTargetId: String? = nil
    @State private var toastMessage: String? = nil
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section {
                if appState.cdirs.isEmpty {
                    HStack {
                        Image(systemName: "folder.badge.questionmark")
                            .foregroundStyle(.green)
                        Text("未添加常用路径")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(appState.cdirs) { item in
                        dirRow(item: item)
                            .onDrag {
                                draggedItem = item
                                return NSItemProvider(object: item.id as NSString)
                            }
                            .onDrop(of: [.text], delegate: CommonDirDropDelegate(
                                item: item,
                                appState: appState,
                                draggedItem: $draggedItem,
                                dropTargetId: $dropTargetId
                            ))
                    }
                    .onDelete { indexSet in
                        appState.cdirs.remove(atOffsets: indexSet)
                        try? appState.saveCommonDir()
                    }
                }
            } header: {
                HStack {
                    Text("常用路径")
                    Spacer()
                    Button {
                        addCommonDir()
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label("重置", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .confirmationDialog("确定要清除所有常用路径吗？", isPresented: $showResetConfirm, titleVisibility: .visible) {
                        Button("清除全部", role: .destructive) {
                            appState.cdirs.removeAll()
                            try? appState.saveCommonDir()
                        }
                        Button("取消", role: .cancel) {}
                    }
                }
            } footer: {
                Text("从右键菜单快速访问常用路径。")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingItem) { item in
            CommonDirEditSheet(item: item) { result in
                switch result {
                case .save(let name):
                    if let idx = appState.cdirs.firstIndex(where: { $0.id == item.id }) {
                        appState.cdirs[idx].name = name
                        try? appState.saveCommonDir()
                    }
                case .cancel:
                    break
                }
                editingItem = nil
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = toastMessage {
                Text(msg)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { toastMessage = nil }
                        }
                    }
            }
        }
    }

    // MARK: - 添加常用路径（使用 NSOpenPanel 替代 fileImporter）

    @MainActor
    private func addCommonDir() {
        // 临时切换到 regular 激活策略，确保 NSOpenPanel 能正常弹出
        let oldPolicy = NSApp.activationPolicy()
        if oldPolicy != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "选择常用路径"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"

        let response = panel.runModal()
        // 恢复原来的激活策略
        if oldPolicy != .regular {
            NSApp.setActivationPolicy(oldPolicy)
        }

        guard response == .OK, let url = panel.url else {
            logger.info("取消选择文件夹")
            return
        }

        // 路径去重：标准化比对（兼容末尾斜杠差异）
        let normalizedPath = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        guard !appState.cdirs.contains(where: { dir in
            let existingPath = dir.url.path.hasSuffix("/") ? String(dir.url.path.dropLast()) : dir.url.path
            return existingPath == normalizedPath
        }) else {
            logger.info("路径已存在，跳过: \(url.path)")
            withAnimation { toastMessage = "该路径已添加" }
            return
        }

        let commonDir = CommonDir(id: UUID().uuidString, name: url.lastPathComponent, url: url, icon: "folder")
        appState.cdirs.append(commonDir)
        logger.info("已将文件夹添加到列表: \(commonDir.name)")

        do {
            try appState.saveCommonDir()
            logger.info("保存成功: \(commonDir.name) - \(url.path)")
            withAnimation { toastMessage = "已添加「\(commonDir.name)」" }
        } catch {
            logger.error("保存失败: \(error.localizedDescription)")
            withAnimation { toastMessage = "保存失败: \(error.localizedDescription)" }
        }
    }

    // MARK: - 列表行

    @ViewBuilder
    private func dirRow(item: CommonDir) -> some View {
        let isDropTarget = dropTargetId == item.id

        HStack(spacing: 12) {
            // 文件夹图标
            Image(systemName: "folder.fill")
                .font(.system(size: 16))
                .foregroundStyle(.green)
                .frame(width: 18, height: 18)

            // 名称 + 路径（两行）
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.body)
                Text(verbatim: item.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // 启用开关
            Toggle("", isOn: Binding(
                get: { item.enabled },
                set: { newVal in
                    if let idx = appState.cdirs.firstIndex(where: { $0.id == item.id }) {
                        appState.cdirs[idx].enabled = newVal
                        try? appState.saveCommonDir()
                    }
                }
            ))
            .labelsHidden()
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
                openInFinder(item)
            } label: {
                Label("在 Finder 中打开", systemImage: "arrow.right.to.line.compact")
            }

            Button {
                editingItem = item
            } label: {
                Label("编辑名称", systemImage: "pencil")
            }

            Divider()

            Button {
                if let idx = appState.cdirs.firstIndex(where: { $0.id == item.id }), idx > 0 {
                    appState.cdirs.move(fromOffsets: IndexSet(integer: idx), toOffset: idx - 1)
                    try? appState.saveCommonDir()
                }
            } label: {
                Label("上移", systemImage: "arrow.up")
            }
            .disabled(appState.cdirs.first?.id == item.id)

            Button {
                if let idx = appState.cdirs.firstIndex(where: { $0.id == item.id }), idx < appState.cdirs.count - 1 {
                    appState.cdirs.move(fromOffsets: IndexSet(integer: idx), toOffset: idx + 2)
                    try? appState.saveCommonDir()
                }
            } label: {
                Label("下移", systemImage: "arrow.down")
            }
            .disabled(appState.cdirs.last?.id == item.id)

            Divider()

            Button(role: .destructive) {
                if let idx = appState.cdirs.firstIndex(where: { $0.id == item.id }) {
                    appState.cdirs.remove(at: idx)
                    try? appState.saveCommonDir()
                }
            } label: {
                Label("移除", systemImage: "trash")
            }
        }
    }
    // MARK: - 在 Finder 中打开

    private func openInFinder(_ item: CommonDir) {
        logger.info("在 Finder 中打开: \(item.url.path)")
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.url.path)
    }
}

// MARK: - 拖放排序

struct CommonDirDropDelegate: DropDelegate {
    let item: CommonDir
    let appState: AppState
    @Binding var draggedItem: CommonDir?
    @Binding var dropTargetId: String?

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        dropTargetId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedItem = draggedItem,
              draggedItem.id != item.id,
              let sourceIndex = appState.cdirs.firstIndex(where: { $0.id == draggedItem.id }),
              let destIndex = appState.cdirs.firstIndex(where: { $0.id == item.id })
        else { return }

        dropTargetId = item.id

        withAnimation(.easeInOut(duration: 0.2)) {
            appState.cdirs.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destIndex > sourceIndex ? destIndex + 1 : destIndex)
            try? appState.saveCommonDir()
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

enum CommonDirEditSheetResult {
    case save(name: String)
    case cancel
}

struct CommonDirEditSheet: View {
    let item: CommonDir?
    let onResult: (CommonDirEditSheetResult) -> Void

    @State private var name: String

    init(item: CommonDir?, onResult: @escaping (CommonDirEditSheetResult) -> Void) {
        self.item = item
        self.onResult = onResult
        _name = State(initialValue: item?.name ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("请输入显示名称")
                .font(.headline)
                .padding()

            Divider()

            TextField("工作文档", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, newVal in
                    if newVal.count > 15 {
                        name = String(newVal.prefix(15))
                    }
                }
                .padding()

            Divider()

            HStack {
                Spacer()

                Button("取消") {
                    onResult(.cancel)
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmedName.isEmpty else { return }
                    onResult(.save(name: trimmedName))
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420, height: 160)
    }
}
