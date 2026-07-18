//
//  ActionSettingsView.swift
//  IClick
//
//  Created by 李旭 on 2024/4/9.
//

import AppKit
import SwiftUI

/// 右键菜单统一列表项
enum MenuItemWrapper: Identifiable {
    case app(OpenWithApp)
    case action(RCAction)
    case submenu(id: String, name: String, icon: String, iconColor: Color, enabled: Bool)

    var id: String {
        switch self {
        case .app(let app): "app_\(app.id)"
        case .action(let action): "action_\(action.id)"
        case .submenu(let id, _, _, _, _): "submenu_\(id)"
        }
    }

    /// 子菜单原始 ID（不含前缀）
    var submenuId: String? {
        if case .submenu(let id, _, _, _, _) = self { return id }
        return nil
    }

    var name: String {
        switch self {
        case .app(let app): app.name
        case .action(let action): action.name
        case .submenu(_, let name, _, _, _): name
        }
    }

    var isEnabled: Bool {
        switch self {
        case .app(let app): app.enabled
        case .action(let action): action.enabled
        case .submenu(_, _, _, _, let enabled): enabled
        }
    }
}

struct ActionSettingsTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var draggedMenuItem: MenuItemWrapper? = nil
    @State private var dropTargetId: String? = nil
    @State private var editingApp: OpenWithApp? = nil
    @State private var editingAction: RCAction? = nil
    @State private var editingSubmenu: SubmenuEditInfo? = nil
    @State private var showAddSheet = false

    let messager = Messager.shared

    /// 可恢复的操作项（预定义中不在列表中的）
    private var availableActions: [RCAction] {
        RCAction.all.filter { action in
            !appState.actions.contains(where: { $0.id == action.id })
        }
    }

    /// 是否有可添加的项
    private var hasAvailableItems: Bool {
        !availableActions.isEmpty
    }

    /// 新建文件是否有启用项
    private var hasEnabledNewFiles: Bool {
        appState.newFiles.contains { $0.enabled }
    }

    /// 常用APP是否有非主菜单项
    private var hasSubmenuApps: Bool {
        appState.apps.contains { $0.enabled && !$0.showInMainMenu }
    }

    /// 常用路径是否有启用项
    private var hasEnabledCommonDirs: Bool {
        appState.cdirs.contains { $0.enabled }
    }

    /// 默认子菜单图标
    static let defaultSubmenuIcons: [String: String] = [
        "newFiles": "doc.badge.plus",
        "submenuApps": "app.badge",
        "commonDirs": "folder",
    ]

    /// 读取子菜单自定义图标
    private func submenuIcon(for id: String) -> String {
        UserDefaults.group.string(forKey: "submenu_icon_\(id)") ?? Self.defaultSubmenuIcons[id] ?? "folder"
    }

    /// 保存子菜单自定义图标
    private func saveSubmenuIcon(_ icon: String, for id: String) {
        UserDefaults.group.set(icon, forKey: "submenu_icon_\(id)")
    }

    /// 根据子菜单 ID 构建 MenuItemWrapper
    private func buildSubmenuItem(id: String) -> MenuItemWrapper? {
        switch id {
        case "newFiles":
            guard hasEnabledNewFiles else { return nil }
            return .submenu(id: "newFiles", name: String(localized: "New File"), icon: submenuIcon(for: "newFiles"), iconColor: .blue, enabled: appState.showNewFiles)
        case "submenuApps":
            guard hasSubmenuApps else { return nil }
            return .submenu(id: "submenuApps", name: String(localized: "Favorite Apps"), icon: submenuIcon(for: "submenuApps"), iconColor: .purple, enabled: hasSubmenuApps)
        case "commonDirs":
            guard hasEnabledCommonDirs else { return nil }
            return .submenu(id: "commonDirs", name: String(localized: "Favorite Folders"), icon: submenuIcon(for: "commonDirs"), iconColor: .green, enabled: appState.showCommonDirs)
        default:
            return nil
        }
    }

    /// 构建统一的菜单项列表，按 submenuOrder 排序子菜单
    private var menuItems: [MenuItemWrapper] {
        var items: [MenuItemWrapper] = []

        // 主菜单 App
        for app in appState.apps where app.showInMainMenu {
            items.append(.app(app))
        }

        // 子菜单项（按 submenuOrder 排序）
        for id in appState.submenuOrder {
            if let item = buildSubmenuItem(id: id) {
                items.append(item)
            }
        }

        // 操作项
        for action in appState.actions {
            items.append(.action(action))
        }

        return items
    }

    var body: some View {
        Form {
            Section {
                let items = menuItems
                if items.isEmpty {
                    HStack {
                        Image(systemName: "bolt.slash")
                            .foregroundStyle(.orange)
                        Text("未配置菜单项")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(items) { item in
                        menuItemRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                handleDoubleClick(item: item)
                            }
                            .onDrag {
                                draggedMenuItem = item
                                return NSItemProvider(object: item.id as NSString)
                            }
                            .onDrop(of: [.text], delegate: MenuItemDropDelegate(
                                item: item,
                                appState: appState,
                                draggedMenuItem: $draggedMenuItem,
                                dropTargetId: $dropTargetId
                            ))
                    }
                }
            } header: {
                HStack {
                    Text("右键菜单")
                    Spacer()
                    if hasAvailableItems {
                        Button {
                            showAddSheet = true
                        } label: {
                            Label("添加", systemImage: "plus")
                        }
                    }
                    Button {
                        appState.resetMenuItems()
                    } label: {
                        Label("重置", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingApp) { app in
            AppEditSheet(item: app) { result in
                switch result {
                case .save(let name, let arguments, let environment, let icon):
                    appState.updateApp(
                        id: app.id,
                        itemName: name,
                        arguments: arguments,
                        environment: environment
                    )
                    if let idx = appState.apps.firstIndex(where: { $0.id == app.id }) {
                        appState.apps[idx].icon = icon
                    }
                    messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: []))
                case .cancel:
                    break
                }
                editingApp = nil
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddMenuItemSheet(
                availableActions: availableActions,
                onAdd: { action in
                    appState.actions.append(action)
                    appState.toggleActionItem()
                    messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: []))
                },
                onDismiss: { showAddSheet = false }
            )
        }
        .sheet(item: $editingAction) { action in
            ActionEditSheet(action: action) { name, icon, requireSelection in
                if let idx = appState.actions.firstIndex(where: { $0.id == action.id }) {
                    appState.actions[idx].name = name
                    appState.actions[idx].icon = icon
                    appState.actions[idx].requireSelection = requireSelection
                    appState.toggleActionItem()
                    messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: []))
                }
                editingAction = nil
            }
        }
        .sheet(item: $editingSubmenu) { submenu in
            SubmenuEditSheet(id: submenu.id, name: submenu.name, icon: submenuIcon(for: submenu.id)) { newName, newIcon in
                saveSubmenuIcon(newIcon, for: submenu.id)
                editingSubmenu = nil
            }
        }
    }

    // MARK: - 列表行

    @ViewBuilder
    private func menuItemRow(item: MenuItemWrapper) -> some View {
        let isDropTarget = dropTargetId == item.id

        HStack(spacing: 12) {
            switch item {
            case .app(let app):
                if let icon = app.icon, !icon.isEmpty {
                    if icon.contains("/") {
                        CustomIconView(path: icon, size: 18)
                    } else {
                        Image(systemName: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)
                    }
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                }
                Text(app.name)
            case .action(let action):
                actionIconView(icon: action.icon, size: 18)
                Text(LocalizedStringKey(action.name))
            case .submenu(_, let name, let icon, let iconColor, _):
                Image(systemName: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(iconColor)
                Text(name)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { item.isEnabled },
                set: { newVal in
                    switch item {
                    case .app(let app):
                        if let idx = appState.apps.firstIndex(where: { $0.id == app.id }) {
                            appState.apps[idx].enabled = newVal
                            appState.sync()
                        }
                    case .action(let action):
                        if let idx = appState.actions.firstIndex(where: { $0.id == action.id }) {
                            appState.actions[idx].enabled = newVal
                            appState.toggleActionItem()
                            messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: []))
                        }
                    case .submenu(let id, _, _, _, _):
                        switch id {
                        case "newFiles":
                            appState.showNewFiles = newVal
                        case "commonDirs":
                            appState.showCommonDirs = newVal
                        default:
                            break
                        }
                        messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: []))
                    }
                }
            ))
            .labelsHidden()
            .onTapGesture { }
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.15), value: dropTargetId)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                switch item {
                case .app(let app):
                    editingApp = app
                case .action(let action):
                    editingAction = action
                case .submenu(let id, let name, let icon, _, _):
                    editingSubmenu = SubmenuEditInfo(id: id, name: name, icon: icon)
                }
            } label: {
                Label("编辑", systemImage: "pencil")
            }

            Divider()

            Button {
                moveItem(item: item, direction: .up)
            } label: {
                Label("上移", systemImage: "arrow.up")
            }
            .disabled(!canMove(item: item, direction: .up))

            Button {
                moveItem(item: item, direction: .down)
            } label: {
                Label("下移", systemImage: "arrow.down")
            }
            .disabled(!canMove(item: item, direction: .down))

            Divider()

            // 子菜单是固定项，不能移除
            if case .submenu = item {} else {
                Button(role: .destructive) {
                    removeItem(item: item)
                } label: {
                    Label("移除", systemImage: "minus.circle")
                }
            }
        }
    }

    // MARK: - 移动操作

    private enum MoveDirection { case up, down }

    private func canMove(item: MenuItemWrapper, direction: MoveDirection) -> Bool {
        switch item {
        case .app(let app):
            guard let idx = appState.apps.firstIndex(where: { $0.id == app.id }) else { return false }
            return direction == .up ? idx > 0 : idx < appState.apps.count - 1
        case .action(let action):
            guard let idx = appState.actions.firstIndex(where: { $0.id == action.id }) else { return false }
            return direction == .up ? idx > 0 : idx < appState.actions.count - 1
        case .submenu(let id, _, _, _, _):
            guard let idx = appState.submenuOrder.firstIndex(of: id) else { return false }
            return direction == .up ? idx > 0 : idx < appState.submenuOrder.count - 1
        }
    }

    private func moveItem(item: MenuItemWrapper, direction: MoveDirection) {
        let offset = direction == .up ? -1 : 1
        switch item {
        case .app(let app):
            if let idx = appState.apps.firstIndex(where: { $0.id == app.id }) {
                let newIdx = idx + offset
                appState.apps.swapAt(idx, newIdx)
                appState.sync()
            }
        case .action(let action):
            if let idx = appState.actions.firstIndex(where: { $0.id == action.id }) {
                let newIdx = idx + offset
                appState.actions.swapAt(idx, newIdx)
                appState.toggleActionItem()
                messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: []))
            }
        case .submenu(let id, _, _, _, _):
            if let idx = appState.submenuOrder.firstIndex(of: id) {
                let newIdx = idx + offset
                appState.submenuOrder.swapAt(idx, newIdx)
            }
        }
    }

    // MARK: - 移除操作（从列表中移除，可重新添加）

    private func removeItem(item: MenuItemWrapper) {
        switch item {
        case .app(let app):
            // App 不删除，只是从主菜单移到常用APP子菜单
            if let idx = appState.apps.firstIndex(where: { $0.id == app.id }) {
                appState.apps[idx].showInMainMenu = false
                appState.sync()
            }
        case .action(let action):
            // 操作从列表中移除，可从预定义列表恢复
            if let idx = appState.actions.firstIndex(where: { $0.id == action.id }) {
                appState.actions.remove(at: idx)
                appState.toggleActionItem()
                messager.sendMessage(name: "running", data: MessagePayload(action: "running", target: []))
            }
        case .submenu:
            break
        }
    }

    private func handleDoubleClick(item: MenuItemWrapper) {
        switch item {
        case .app(let app):
            editingApp = app
        case .action(let action):
            editingAction = action
        case .submenu(let id, let name, let icon, _, _):
            editingSubmenu = SubmenuEditInfo(id: id, name: name, icon: icon)
        }
    }

    @ViewBuilder
    private func actionIconView(icon: String, size: CGFloat) -> some View {
        if RCAction.isCustomIcon(icon) {
            CustomIconView(path: icon, size: size)
        } else {
            // 使用 NSImage 渲染，与 FinderSync 扩展保持一致的分层着色
            let isEyeIcon = icon == "eye" || icon == "eye.fill" || icon == "eye.slash" || icon == "eye.slash.fill"
            if let nsImage = tintedSymbol(named: icon, color: RCAction.nsIconColor(for: icon), size: size, hierarchical: !isEyeIcon) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .foregroundStyle(RCAction.iconColor(for: icon))
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

struct MenuItemDropDelegate: DropDelegate {
    let item: MenuItemWrapper
    let appState: AppState
    @Binding var draggedMenuItem: MenuItemWrapper?
    @Binding var dropTargetId: String?

    func performDrop(info: DropInfo) -> Bool {
        draggedMenuItem = nil
        dropTargetId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedMenuItem,
              draggedMenuItem.id != item.id else { return }

        dropTargetId = item.id

        switch (draggedMenuItem, item) {
        // App ↔ App
        case (.app(let srcApp), .app(let dstApp)):
            if let srcIdx = appState.apps.firstIndex(where: { $0.id == srcApp.id }),
               let dstIdx = appState.apps.firstIndex(where: { $0.id == dstApp.id }) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.apps.move(fromOffsets: IndexSet(integer: srcIdx), toOffset: dstIdx > srcIdx ? dstIdx + 1 : dstIdx)
                    appState.sync()
                }
            }

        // Action ↔ Action
        case (.action(let srcAction), .action(let dstAction)):
            if let srcIdx = appState.actions.firstIndex(where: { $0.id == srcAction.id }),
               let dstIdx = appState.actions.firstIndex(where: { $0.id == dstAction.id }) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.actions.move(fromOffsets: IndexSet(integer: srcIdx), toOffset: dstIdx > srcIdx ? dstIdx + 1 : dstIdx)
                    appState.sync()
                }
            }

        // Submenu ↔ Submenu
        case (.submenu(let srcId, _, _, _, _), .submenu(let dstId, _, _, _, _)):
            if let srcIdx = appState.submenuOrder.firstIndex(of: srcId),
               let dstIdx = appState.submenuOrder.firstIndex(of: dstId) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.submenuOrder.move(fromOffsets: IndexSet(integer: srcIdx), toOffset: dstIdx > srcIdx ? dstIdx + 1 : dstIdx)
                }
            }

        default:
            break
        }
    }

    func dropExited(info: DropInfo) {
        dropTargetId = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - 添加菜单项 Sheet

struct AddMenuItemSheet: View {
    let availableActions: [RCAction]
    let onAdd: (RCAction) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("关闭")

                Spacer()

                Text("新增右键菜单")
                    .font(.headline)

                Spacer()

                Color.clear
                    .frame(width: 14, height: 14)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if availableActions.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 32))
                    Text("没有可恢复的操作")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(availableActions) { action in
                        AddMenuItemRow(
                            iconName: action.icon,
                            name: String(localized: String.LocalizationValue(action.name))
                        ) {
                            onAdd(action)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(width: 420, height: 340)
    }
}

// MARK: - 添加菜单项行

struct AddMenuItemRow: View {
    let iconName: String
    let name: String
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // 使用 NSImage 渲染，与 FinderSync 扩展保持一致的分层着色
            let isEyeIcon = iconName == "eye" || iconName == "eye.fill" || iconName == "eye.slash" || iconName == "eye.slash.fill"
            if let nsImage = tintedSymbol(named: iconName, color: RCAction.nsIconColor(for: iconName), size: 18, hierarchical: !isEyeIcon) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(RCAction.iconColor(for: iconName))
            }

            Text(name)

            Spacer()

            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
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

// MARK: - 子菜单编辑信息

struct SubmenuEditInfo: Identifiable {
    let id: String
    let name: String
    let icon: String
}

// MARK: - 操作编辑 Sheet

struct ActionEditSheet: View {
    let action: RCAction
    let onResult: (String, String, Bool) -> Void

    @State private var actionName: String = ""
    @State private var actionIcon: String = ""
    @State private var requireSelection: Bool = false
    @State private var showIconPicker = false

    var body: some View {
        VStack(spacing: 0) {
            Text("编辑操作")
                .font(.headline)
                .padding()

            Divider()

            VStack(spacing: 0) {
                // 名称
                HStack(spacing: 6) {
                    Text("名称:")
                        .frame(width: 50, alignment: .trailing)
                    TextField("", text: $actionName)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider().padding(.horizontal)

                // 图标选择器
                HStack(spacing: 6) {
                    Text("图标:")
                        .frame(width: 50, alignment: .trailing)

                    Button {
                        showIconPicker = true
                    } label: {
                        HStack(spacing: 8) {
                            actionIconView(icon: actionIcon, size: 16)
                            Text("点击可修改")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        if let defaultAction = RCAction.all.first(where: { $0.id == action.id }) {
                            actionIcon = defaultAction.icon
                        }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        if let path = Utils.pickAndCopyIcon() {
                            actionIcon = path
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("从访达选择图标")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider().padding(.horizontal)

                // 仅选中文件时显示
                HStack(spacing: 6) {
                    Text("仅选中文件:")
                        .frame(width: 70, alignment: .trailing)
                    Toggle("", isOn: $requireSelection)
                        .labelsHidden()
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            Divider()

            HStack {
                Spacer()

                Button("取消") {
                    onResult(action.name, action.icon, action.requireSelection)
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    onResult(actionName, actionIcon, requireSelection)
                }
                .buttonStyle(.borderedProminent)
                .disabled(actionName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 380, height: 240)
        .sheet(isPresented: $showIconPicker) {
            IconPickerSheet(
                selectedIcon: $actionIcon,
                onDismiss: { showIconPicker = false }
            )
        }
        .onAppear {
            actionName = action.name
            actionIcon = action.icon
            requireSelection = action.requireSelection
        }
    }

    @ViewBuilder
    private func actionIconView(icon: String, size: CGFloat) -> some View {
        if RCAction.isCustomIcon(icon) {
            CustomIconView(path: icon, size: size)
        } else {
            // 使用 NSImage 渲染，与 FinderSync 扩展保持一致的分层着色
            let isEyeIcon = icon == "eye" || icon == "eye.fill" || icon == "eye.slash" || icon == "eye.slash.fill"
            if let nsImage = tintedSymbol(named: icon, color: RCAction.nsIconColor(for: icon), size: size, hierarchical: !isEyeIcon) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: icon)
                    .font(.system(size: size))
                    .foregroundStyle(RCAction.iconColor(for: icon))
                    .frame(width: size, height: size)
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

// MARK: - 自定义图标视图

struct CustomIconView: View {
    let path: String
    let size: CGFloat

    var body: some View {
        Group {
            if let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 图标选择器 Sheet

struct IconPickerSheet: View {
    @Binding var selectedIcon: String
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var selectedCategory = "全部"

    /// 图标分类
    private let categories: [(name: String, items: [String])] = [
        ("全部", []),
        ("文件", [
            "doc", "doc.fill", "doc.text", "doc.plaintext", "doc.richtext",
            "doc.on.doc", "doc.on.doc.fill", "doc.badge.plus",
            "doc.badge.gearshape", "doc.badge.clock",
            "rectangle.and.paperclip", "paperclip", "link", "link.badge.plus",
            "folder", "folder.fill", "externaldrive", "externaldrive.fill",
        ]),
        ("通信", [
            "message", "message.fill", "bubble.left", "bubble.left.fill",
            "bubble.right", "bubble.right.fill", "envelope", "envelope.fill",
            "phone", "phone.fill", "paperplane", "paperplane.fill",
            "bell", "bell.fill", "bell.slash", "bell.slash.fill",
        ]),
        ("人物", [
            "person", "person.fill", "person.2", "person.2.fill",
            "person.circle", "person.circle.fill", "person.crop.circle",
            "person.crop.circle.fill", "person.badge.plus", "person.badge.minus",
            "person.3", "person.3.fill", "person.crop.square", "person.crop.square.fill",
        ]),
        ("设备", [
            "desktopcomputer", "laptopcomputer", "ipad", "iphone",
            "externaldrive", "externaldrive.fill", "internaldrive", "internaldrive.fill",
            "opticaldisc", "opticaldisc.fill",
            "printer", "printer.fill", "keyboard", "keyboard.fill",
            "computermouse", "computermouse.fill", "power", "power.circle.fill",
            "app.badge", "app.badge.fill", "app.badge.checkmark", "app.badge.checkmark.fill",
            "square.grid.2x2", "square.grid.3x2", "rectangle.grid.2x2",
        ]),
        ("媒体", [
            "photo", "photo.fill", "camera", "camera.fill",
            "video", "video.fill", "film", "film.fill",
            "music.note", "music.mic", "headphones", "speaker",
            "speaker.wave.2.fill", "mic", "mic.fill",
            "rectangle.stack", "rectangle.stack.fill", "play.rectangle", "play.rectangle.fill",
            "play.circle", "play.circle.fill", "pause.circle", "pause.circle.fill",
        ]),
        ("编辑", [
            "pencil", "pencil.circle.fill", "paintbrush", "paintbrush.fill",
            "scissors", "ruler", "ruler.fill", "hammer", "hammer.fill",
            "wrench", "wrench.fill",
            "textformat", "bold", "italic", "underline",
            "doc.on.doc", "doc.on.doc.fill",
            "character.cursor.ibeam", "textformat.size",
            "textformat.abc", "textformat.abc.dottedunderline",
        ]),
        ("天气", [
            "cloud", "cloud.fill", "cloud.rain", "cloud.rain.fill",
            "cloud.snow", "cloud.snow.fill", "cloud.bolt", "cloud.bolt.fill",
            "cloud.sun", "cloud.sun.fill", "cloud.moon", "cloud.moon.fill",
            "sun.max", "sun.max.fill", "moon", "moon.fill",
            "star", "star.fill", "thermometer.medium", "thermometer.high",
            "humidity", "wind", "drop", "drop.fill", "flame", "flame.fill",
            "leaf", "leaf.fill", "cloud.fog", "snowflake",
        ]),
        ("系统", [
            "gearshape", "gearshape.fill", "gearshape.2", "gearshape.2.fill",
            "gear", "slider.horizontal.3",
            "lock", "lock.fill", "lock.open", "lock.open.fill",
            "key", "key.fill", "shield", "shield.fill", "shield.checkered",
            "eye", "eye.slash", "eye.fill", "eye.slash.fill",
            "wifi", "antenna.radiowaves.left.and.right",
            "bolt", "bolt.fill", "bolt.slash", "bolt.slash.fill",
            "checkmark.circle", "checkmark.circle.fill",
            "xmark.circle", "xmark.circle.fill",
        ]),
        ("图形", [
            "square", "square.fill", "rectangle", "rectangle.fill",
            "circle", "circle.fill", "triangle", "triangle.fill",
            "diamond", "diamond.fill", "hexagon", "hexagon.fill",
            "octagon", "octagon.fill", "star.square", "star.square.fill",
            "heart", "heart.fill", "sparkles",
            "plus", "plus.circle", "plus.circle.fill",
            "minus", "minus.circle", "minus.circle.fill",
            "xmark", "xmark.circle", "xmark.circle.fill",
            "arrow.up", "arrow.down", "arrow.left", "arrow.right",
        ]),
    ]

    /// 当前分类下的图标
    private var currentIcons: [String] {
        let icons: [String]
        if selectedCategory == "全部" {
            icons = categories.dropFirst().flatMap { $0.items }
        } else {
            icons = categories.first(where: { $0.name == selectedCategory })?.items ?? []
        }

        if searchText.isEmpty {
            return icons
        }
        return icons.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("选择图标")
                    .font(.headline)

                Spacer()

                Color.clear.frame(width: 14, height: 14)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // 内容区域
            HStack(spacing: 0) {
                // 左侧分类列表
                VStack(spacing: 2) {
                    ForEach(categories, id: \.name) { category in
                        Button {
                            selectedCategory = category.name
                        } label: {
                            Text(category.name)
                                .font(.system(size: 13))
                                .foregroundStyle(selectedCategory == category.name ? .white : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(selectedCategory == category.name ? Color.accentColor : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .offset(y: -4)
                .padding(.bottom, 6)
                .padding(.horizontal, 6)
                .frame(width: 90)

                // 右侧内容区
                VStack(spacing: 0) {
                    // 搜索框
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                        TextField("搜索", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                            )
                    )
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                    // 图标网格
                    if currentIcons.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                                .font(.title2)
                            Text("未找到匹配的图标")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                                ForEach(Array(Set(currentIcons)).sorted(), id: \.self) { icon in
                                    IconGridItem(
                                        icon: icon,
                                        isSelected: selectedIcon == icon
                                    ) {
                                        selectedIcon = icon
                                        onDismiss()
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                        }
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
            }
        }
        .frame(width: 420, height: 440)
    }
}

// MARK: - 图标网格项

struct IconGridItem: View {
    let icon: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                )
        }
        .buttonStyle(.plain)
        .help(icon)
    }
}

// MARK: - 子菜单编辑 Sheet

struct SubmenuEditSheet: View {
    let id: String
    let name: String
    let icon: String
    let onResult: (String, String) -> Void

    @State private var submenuName: String = ""
    @State private var submenuIcon: String = ""
    @State private var showIconPicker = false

    var body: some View {
        VStack(spacing: 0) {
            Text("编辑子菜单")
                .font(.headline)
                .padding()

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("名称:")
                        .frame(width: 50, alignment: .trailing)
                    TextField("", text: $submenuName)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider().padding(.horizontal)

                // 图标选择器
                HStack(spacing: 6) {
                    Text("图标:")
                        .frame(width: 50, alignment: .trailing)

                    Button {
                        showIconPicker = true
                    } label: {
                        HStack(spacing: 8) {
                            if submenuIcon.contains("/") {
                                CustomIconView(path: submenuIcon, size: 16)
                            } else {
                                Image(systemName: submenuIcon)
                                    .font(.system(size: 16))
                                    .foregroundStyle(submenuIconColor)
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
                        submenuIcon = ActionSettingsTabView.defaultSubmenuIcons[id] ?? "folder"
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        if let path = Utils.pickAndCopyIcon() {
                            submenuIcon = path
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
                    onResult(name, icon)
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    onResult(submenuName, submenuIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(submenuName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420, height: 200)
        .sheet(isPresented: $showIconPicker) {
            IconPickerSheet(
                selectedIcon: $submenuIcon,
                onDismiss: { showIconPicker = false }
            )
        }
        .onAppear {
            submenuName = name
            submenuIcon = icon
        }
    }

    private var submenuIconColor: Color {
        switch id {
        case "newFiles": return .blue
        case "submenuApps": return .purple
        case "commonDirs": return .green
        default: return .secondary
        }
    }
}
