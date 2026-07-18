//
//  NewFileSettingsTabView.swift
//  IClick
//
//  Created by 李梦佳 on 2025/1/30.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct NewFileSettingsTabView: View {
    @EnvironmentObject var appState: AppState

    @State private var editingItem: NewFile? = nil
    @State private var isAdding = false
    @State private var draggedItem: NewFile? = nil
    @State private var dropTargetId: String? = nil

    var body: some View {
        Form {
            Section {
                if appState.newFiles.isEmpty {
                    HStack {
                        Image(systemName: "doc.badge.plus")
                            .foregroundStyle(.blue)
                        Text("未配置文件类型")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(appState.newFiles) { item in
                    fileRow(item: item)
                        .onDrag {
                            draggedItem = item
                            return NSItemProvider(object: item.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: NewFileDropDelegate(
                            item: item,
                            appState: appState,
                            draggedItem: $draggedItem,
                            dropTargetId: $dropTargetId
                        ))
                }
                .onDelete { indexSet in
                    appState.newFiles.remove(atOffsets: indexSet)
                    save()
                }
            } header: {
                HStack {
                    Text("文件类型")
                    Spacer()
                    Button {
                        isAdding = true
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    Button {
                        appState.newFiles = NewFile.all
                        appState.sync()
                    } label: {
                        Label("重置", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingItem) { item in
            NewFileEditSheet(item: item) { result in
                switch result {
                case .save(let name, let ext, let enabled, let defaultName, let openApp, let icon):
                    if let idx = appState.newFiles.firstIndex(where: { $0.id == item.id }) {
                        appState.newFiles[idx].name = name
                        appState.newFiles[idx].ext = ext
                        appState.newFiles[idx].enabled = enabled
                        appState.newFiles[idx].defaultName = defaultName
                        appState.newFiles[idx].openApp = openApp
                        // 根据文件扩展名匹配默认图标，如果没有自定义图标则使用系统图标
                        let defaultIcons: [String: String] = [
                            ".json": "curlybraces", ".txt": "doc.plaintext",
                            ".md": "doc.richtext", ".docx": "doc.fill",
                            ".pptx": "rectangle.grid.3x2", ".xlsx": "tablecells"
                        ]
                        if let icon = icon {
                            appState.newFiles[idx].icon = icon
                        } else if let matchedIcon = defaultIcons[ext] {
                            appState.newFiles[idx].icon = matchedIcon
                        } else {
                            appState.newFiles[idx].icon = "doc"
                        }
                    } else {
                        var newItem = NewFile(ext: ext, name: name, enabled: enabled, idx: appState.newFiles.count, icon: icon ?? "doc", defaultName: defaultName)
                        newItem.openApp = openApp
                        appState.newFiles.append(newItem)
                    }
                    save()
                case .cancel:
                    break
                }
                editingItem = nil
            }
        }
        .sheet(isPresented: $isAdding) {
            NewFileEditSheet(item: nil) { result in
                switch result {
                case .save(let name, let ext, let enabled, let defaultName, let openApp, let icon):
                    var newItem = NewFile(ext: ext, name: name, enabled: enabled, idx: appState.newFiles.count, icon: icon ?? "doc", defaultName: defaultName)
                    newItem.openApp = openApp
                    appState.newFiles.append(newItem)
                    save()
                case .cancel:
                    break
                }
                isAdding = false
            }
        }
    }

    // MARK: - 列表行

    @ViewBuilder
    private func fileRow(item: NewFile) -> some View {
        let isDropTarget = dropTargetId == item.id

        HStack(spacing: 12) {
            systemIcon(for: item)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Text(item.ext)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { item.enabled },
                set: { newVal in
                    if let idx = appState.newFiles.firstIndex(where: { $0.id == item.id }) {
                        appState.newFiles[idx].enabled = newVal
                        save()
                    }
                }
            ))
            .labelsHidden()
            .onTapGesture { }  // 阻止事件穿透到父级
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.15), value: dropTargetId)
        .contentShape(Rectangle())  // 整行可点击区域
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
                if let idx = appState.newFiles.firstIndex(where: { $0.id == item.id }), idx > 0 {
                    appState.newFiles.move(fromOffsets: IndexSet(integer: idx), toOffset: idx - 1)
                    save()
                }
            } label: {
                Label("上移", systemImage: "arrow.up")
            }
            .disabled(appState.newFiles.first?.id == item.id)

            Button {
                if let idx = appState.newFiles.firstIndex(where: { $0.id == item.id }), idx < appState.newFiles.count - 1 {
                    appState.newFiles.move(fromOffsets: IndexSet(integer: idx), toOffset: idx + 2)
                    save()
                }
            } label: {
                Label("下移", systemImage: "arrow.down")
            }
            .disabled(appState.newFiles.last?.id == item.id)

            Divider()

            Button(role: .destructive) {
                if let idx = appState.newFiles.firstIndex(where: { $0.id == item.id }) {
                    appState.newFiles.remove(at: idx)
                    save()
                }
            } label: {
                Label("移除", systemImage: "trash")
            }
        }
    }

    private func save() {
        appState.sync()
    }

    /// 获取文件类型的图标
    @ViewBuilder
    private func systemIcon(for item: NewFile) -> some View {
        let icon = item.icon
        if icon.contains("/") {
            // 自定义图片路径
            CustomIconView(path: icon, size: 18)
        } else if NSImage(named: icon) != nil {
            // Asset catalog 图片
            Image(icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
        } else {
            // SF Symbol
            let sfName = NewFile.sfSymbolName(for: item.ext)
            if let nsImage = tintedSymbol(named: sfName, color: NewFile.nsFileIconColor(for: item.ext), size: 16) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: sfName)
                    .font(.system(size: 16))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(NewFile.fileIconColor(for: item.ext))
            }
        }
    }

    /// 与 FinderSync 扩展保持一致的分层着色方法，复杂多层图标可回退到单色渲染
    private func tintedSymbol(named name: String, color: NSColor, size: CGFloat, hierarchical: Bool = true) -> NSImage? {
        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        var config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        if hierarchical {
            config = config.applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        } else {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        }
        let tinted = sym.withSymbolConfiguration(config)
        tinted?.isTemplate = false
        return tinted
    }
}

// MARK: - 拖拽排序 Delegate

struct NewFileDropDelegate: DropDelegate {
    let item: NewFile
    let appState: AppState
    @Binding var draggedItem: NewFile?
    @Binding var dropTargetId: String?

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        dropTargetId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedItem,
              draggedItem.id != item.id,
              let sourceIndex = appState.newFiles.firstIndex(where: { $0.id == draggedItem.id }),
              let destIndex = appState.newFiles.firstIndex(where: { $0.id == item.id })
        else { return }

        dropTargetId = item.id

        withAnimation(.easeInOut(duration: 0.2)) {
            appState.newFiles.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destIndex > sourceIndex ? destIndex + 1 : destIndex)
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

enum EditSheetResult {
    case save(name: String, ext: String, enabled: Bool, defaultName: String, openApp: URL?, icon: String?)
    case cancel
}

struct NewFileEditSheet: View {
    let item: NewFile?
    let onResult: (EditSheetResult) -> Void

    @State private var name: String = ""
    @State private var ext: String = ""
    @State private var defaultName: String = "未命名"
    @State private var openApp: URL?
    @State private var iconPath: String?
    @State private var showIconPicker = false

    private var isAdding: Bool { item == nil }

    var body: some View {
        VStack(spacing: 0) {
            Text(isAdding ? "新建文件类型" : "编辑文件类型")
                .font(.headline)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider()

            VStack(spacing: 0) {
                // 文件类型
                HStack {
                    Text("文件类型:")
                        .frame(width: 75, alignment: .trailing)
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider().padding(.horizontal)

                // 文件图标
                HStack(spacing: 6) {
                    Text("文件图标:")
                        .frame(width: 75, alignment: .trailing)

                    Button {
                        showIconPicker = true
                    } label: {
                        HStack(spacing: 8) {
                            if isAdding {
                                Image(systemName: "plus.circle")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            } else {
                                iconView
                            }
                            Text(isAdding ? "选择图标" : "点击可修改")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if !isAdding {
                        Button {
                            iconPath = nil
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless)

                        Button {
                            if let path = Utils.pickAndCopyIcon() {
                                iconPath = path
                            }
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider().padding(.horizontal)

                // 默认名称
                HStack {
                    Text("默认名称:")
                        .frame(width: 75, alignment: .trailing)
                    TextField("", text: $defaultName)
                        .textFieldStyle(.roundedBorder)
                    Text(".")
                        .foregroundStyle(.secondary)
                    TextField("docx", text: $ext)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider().padding(.horizontal)

                // 打开应用
                HStack {
                    Text("打开应用:")
                        .frame(width: 75, alignment: .trailing)
                    Button("选择") {
                        let panel = NSOpenPanel()
                        panel.title = "选择应用"
                        panel.allowedContentTypes = [.application]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url {
                            openApp = url
                        }
                    }
                    if let app = openApp {
                        Text(app.deletingPathExtension().lastPathComponent)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("默认应用")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
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
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    var trimmedExt = ext.trimmingCharacters(in: .whitespaces)
                    guard !trimmedName.isEmpty, !trimmedExt.isEmpty else { return }
                    if !trimmedExt.hasPrefix(".") {
                        trimmedExt = "." + trimmedExt
                    }
                    onResult(.save(
                        name: trimmedName,
                        ext: trimmedExt,
                        enabled: item?.enabled ?? true,
                        defaultName: defaultName.trimmingCharacters(in: .whitespaces).isEmpty ? "未命名" : defaultName,
                        openApp: openApp,
                        icon: iconPath
                    ))
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || ext.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(width: 450, height: 260)
        .onAppear {
            if let item = item {
                name = item.name
                ext = item.ext.replacingOccurrences(of: ".", with: "")
                defaultName = item.defaultName
                openApp = item.openApp
                if !item.icon.contains("icon-file-") && !item.icon.contains("document") {
                    iconPath = item.icon
                }
            }
        }
        .sheet(isPresented: $showIconPicker) {
            IconPickerSheet(
                selectedIcon: Binding(
                    get: { iconPath ?? "" },
                    set: { iconPath = $0.isEmpty ? nil : $0 }
                ),
                onDismiss: { showIconPicker = false }
            )
        }
    }

    @ViewBuilder
    private var iconView: some View {
        let ext = item?.ext ?? ""
        if let path = iconPath, path.contains("/") {
            // 用户自定义图片
            CustomIconView(path: path, size: 24)
        } else if let path = iconPath, !path.isEmpty, NSImage(named: path) != nil {
            // Asset catalog 图片
            Image(path)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
        } else if let path = iconPath, !path.isEmpty {
            // SF Symbol 图标
            if let nsImage = tintedSymbol(named: path, color: NewFile.nsFileIconColor(for: ext), size: 20) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: path)
                    .font(.system(size: 20))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(NewFile.fileIconColor(for: ext))
            }
        } else if let item = item {
            // 使用默认图标
            if NSImage(named: item.icon) != nil {
                Image(item.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else {
                let sfName = NewFile.sfSymbolName(for: item.ext)
                if let nsImage = tintedSymbol(named: sfName, color: NewFile.nsFileIconColor(for: item.ext), size: 20) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: sfName)
                        .font(.system(size: 20))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(NewFile.fileIconColor(for: item.ext))
                }
            }
        } else {
            Image(systemName: "doc")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }

    /// 与 FinderSync 扩展保持一致的分层着色方法，复杂多层图标可回退到单色渲染
    private func tintedSymbol(named name: String, color: NSColor, size: CGFloat, hierarchical: Bool = true) -> NSImage? {
        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        var config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        if hierarchical {
            config = config.applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        } else {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        }
        let tinted = sym.withSymbolConfiguration(config)
        tinted?.isTemplate = false
        return tinted
    }
}
