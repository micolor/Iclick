//
//  ActionSettingsView.swift
//  IClick
//
//  Created by 李旭 on 2024/4/9.
//

import AppKit
import SwiftUI

// MARK: - 设置页专用的图标颜色
//
// 原来放在 RCBase.swift 里，而 RCBase 也编译进 FinderSync 扩展：那一行
// `import SwiftUI` 会让扩展在启动时把整个 SwiftUI 框架拉进内存。
// 这些 `Color` 只被设置界面使用，因此挪到只属于主应用目标的文件里。

extension RCAction {
    /// 操作图标对应的颜色
    static func iconColor(for icon: String) -> Color {
        switch icon {
        case "document.on.document": return .blue
        case "trash.fill": return .red
        case "moon.fill": return .secondary
        case "sun.max.fill": return .orange
        case "eye.slash", "eye.slash.fill": return .secondary
        case "eye", "eye.fill": return .secondary
        case "airplane", "airdrop", "wifi.radar", "bonjour", "paperplane.fill": return .teal
        case "camera.viewfinder": return .orange
        case "pencil.tip.cropview": return .orange
        default: return .accentColor
        }
    }
}

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
    @State private var showResetConfirm = false


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

    /// 默认子菜单名称（与扩展端 String(localized:) 保持一致，用于判断“是否自定义”）
    static let defaultSubmenuNames: [String: String] = [
        "newFiles": String(localized: "New File"),
        "submenuApps": String(localized: "Favorite Apps"),
        "commonDirs": String(localized: "Favorite Folders"),
    ]

    /// 读取子菜单自定义图标
    private func submenuIcon(for id: String) -> String {
        SharedSettings.string(forKey: "submenu_icon_\(id)") ?? Self.defaultSubmenuIcons[id] ?? "folder"
    }

    /// 读取子菜单显示名称
    private func submenuName(for id: String) -> String {
        if let custom = SharedSettings.string(forKey: "submenu_name_\(id)"), !custom.isEmpty {
            return custom
        }
        return Self.defaultSubmenuNames[id] ?? id
    }

    /// 保存子菜单的名称与图标。
    /// 等于内置默认值时删除键（= 未自定义），这样扩展端才能区分「用户显式设置」和「默认」，
    /// 避免用户只是打开弹窗点保存就把默认的着色图标覆盖成无着色图标。
    private func saveSubmenu(name: String, icon: String, for id: String) {
        let defaultName = Self.defaultSubmenuNames[id] ?? id
        let defaultIcon = Self.defaultSubmenuIcons[id] ?? "folder"

        if name.isEmpty || name == defaultName {
            SharedSettings.removeObject(forKey: "submenu_name_\(id)")
        } else {
            SharedSettings.set(name, forKey: "submenu_name_\(id)")
        }
        if icon.isEmpty || icon == defaultIcon {
            SharedSettings.removeObject(forKey: "submenu_icon_\(id)")
        } else {
            SharedSettings.set(icon, forKey: "submenu_icon_\(id)")
        }
        SharedSettings.synchronize()
        // 推送给扩展，否则右键菜单不会刷新
        appState.sync()
    }

    /// 根据子菜单 ID 构建 MenuItemWrapper
    private func buildSubmenuItem(id: String) -> MenuItemWrapper? {
        switch id {
        case "newFiles":
            guard hasEnabledNewFiles else { return nil }
            return .submenu(id: "newFiles", name: submenuName(for: "newFiles"), icon: submenuIcon(for: "newFiles"), iconColor: .blue, enabled: appState.showNewFiles)
        case "submenuApps":
            guard hasSubmenuApps else { return nil }
            // 原来这里写的是 hasSubmenuApps（恒为 true），开关永远显示为开、
            // 点击也没有任何持久化 —— 典型「点了没反应」。改用真实开关。
            return .submenu(id: "submenuApps", name: submenuName(for: "submenuApps"), icon: submenuIcon(for: "submenuApps"), iconColor: .purple, enabled: appState.showApps)
        case "commonDirs":
            guard hasEnabledCommonDirs else { return nil }
            return .submenu(id: "commonDirs", name: submenuName(for: "commonDirs"), icon: submenuIcon(for: "commonDirs"), iconColor: .green, enabled: appState.showCommonDirs)
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
                        showResetConfirm = true
                    } label: {
                        Label("重置", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .confirmationDialog("确定要重置右键菜单吗？", isPresented: $showResetConfirm, titleVisibility: .visible) {
                        // 操作项、顺序、子菜单开关会恢复默认，自定义的子菜单名称/图标
                        // 以及 App 在菜单里的位置也会一并清除。
                        Button("重置", role: .destructive) {
                            appState.resetMenuItems()
                        }
                        Button("取消", role: .cancel) {}
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingApp) { app in
            AppEditSheet(item: app) { result in
                switch result {
                case .save(let name, let url, let icon):
                    // 图标与路径一并交给 updateApp 落盘（之前是直接改内存数组，永远不保存）
                    appState.updateApp(
                        id: app.id,
                        itemName: name,
                        url: url,
                        icon: icon,
                        replaceIcon: true
                    )
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
                },
                onDismiss: { showAddSheet = false }
            )
        }
        .sheet(item: $editingAction) { action in
            ActionEditSheet(action: action) { result in
                switch result {
                case .save(let name, let icon, let requireSelection):
                    if let idx = appState.actions.firstIndex(where: { $0.id == action.id }) {
                        appState.actions[idx].name = name
                        appState.actions[idx].icon = icon
                        appState.actions[idx].requireSelection = requireSelection
                        appState.toggleActionItem()
                    }
                case .cancel:
                    break
                }
                editingAction = nil
            }
        }
        .sheet(item: $editingSubmenu) { submenu in
            SubmenuEditSheet(id: submenu.id, name: submenu.name, icon: submenuIcon(for: submenu.id)) { result in
                switch result {
                case .save(let newName, let newIcon):
                    // 之前这里把 newName 丢掉了，改名字等于没改
                    saveSubmenu(name: newName, icon: newIcon, for: submenu.id)
                case .cancel:
                    break
                }
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
                    Image(nsImage: Utils.fileIcon(forPath: app.url.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                }
                Text(app.name)
            case .action(let action):
                actionIconView(icon: action.icon, size: 18)
                Text(LocalizedStringKey(action.name))
            case .submenu(_, let name, let icon, let iconColor, _):
                // 子菜单图标可以是 SF Symbol，也可以是自定义图片路径（SubmenuEditSheet
                // 允许选图）。原来这里一律按 systemName 显示，选过自定义图片的子菜单
                // 在设置列表里就是一个空白图标 —— Finder 里其实是正常的。
                if icon.contains("/") {
                    if let image = NSImage(contentsOfFile: icon) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "folder")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)
                            .foregroundStyle(iconColor)
                    }
                } else {
                    Image(systemName: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                        .foregroundStyle(iconColor)
                }
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
                        }
                    case .submenu(let id, _, _, _, _):
                        switch id {
                        case "newFiles":
                            appState.showNewFiles = newVal
                        case "commonDirs":
                            appState.showCommonDirs = newVal
                        case "submenuApps":
                            appState.showApps = newVal
                        default:
                            break
                        }
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

    /// 界面上可见的 App 在 appState.apps 里的下标。
    /// 列表只展示 showInMainMenu 的 App，「移除」又会把 App 留在数组里只翻这个标志，
    /// 所以可见项是全量数组的**子序列**。
    private var visibleAppIndices: [Int] {
        appState.apps.enumerated().compactMap { $0.element.showInMainMenu ? $0.offset : nil }
    }

    /// 界面上可见的子菜单在 appState.submenuOrder 里的下标
    /// （buildSubmenuItem 返回 nil 的会被 menuItems 跳过，不显示）。
    private var visibleSubmenuIndices: [Int] {
        appState.submenuOrder.enumerated().compactMap {
            buildSubmenuItem(id: $0.element) != nil ? $0.offset : nil
        }
    }

    /// 把「可见列表里的上移/下移」翻译成**全量数组**中的两个下标。
    ///
    /// 原来直接用全量下标 ±1：只要中间夹着一个不可见的项，轻则顺序错乱
    /// （swapAt 换到了看不见的那一项上），重则点了「上移」界面毫无变化
    /// （换的是另一个不可见项，可见顺序不变）。
    private func moveTargets(visibleIndices: [Int], current: Int, direction: MoveDirection) -> (Int, Int)? {
        guard let vi = visibleIndices.firstIndex(of: current) else { return nil }
        let ni = direction == .up ? vi - 1 : vi + 1
        guard visibleIndices.indices.contains(ni) else { return nil }
        return (current, visibleIndices[ni])
    }

    private func canMove(item: MenuItemWrapper, direction: MoveDirection) -> Bool {
        switch item {
        case .app(let app):
            guard let current = appState.apps.firstIndex(where: { $0.id == app.id }) else { return false }
            return moveTargets(visibleIndices: visibleAppIndices, current: current, direction: direction) != nil
        case .action(let action):
            guard let idx = appState.actions.firstIndex(where: { $0.id == action.id }) else { return false }
            return direction == .up ? idx > 0 : idx < appState.actions.count - 1
        case .submenu(let id, _, _, _, _):
            guard let current = appState.submenuOrder.firstIndex(of: id) else { return false }
            return moveTargets(visibleIndices: visibleSubmenuIndices, current: current, direction: direction) != nil
        }
    }

    private func moveItem(item: MenuItemWrapper, direction: MoveDirection) {
        let offset = direction == .up ? -1 : 1
        switch item {
        case .app(let app):
            guard let current = appState.apps.firstIndex(where: { $0.id == app.id }),
                  let (from, to) = moveTargets(visibleIndices: visibleAppIndices, current: current, direction: direction)
            else { return }
            appState.apps.swapAt(from, to)
            appState.sync()
        case .action(let action):
            if let idx = appState.actions.firstIndex(where: { $0.id == action.id }) {
                let newIdx = idx + offset
                appState.actions.swapAt(idx, newIdx)
                appState.toggleActionItem()
            }
        case .submenu(let id, _, _, _, _):
            guard let current = appState.submenuOrder.firstIndex(of: id),
                  let (from, to) = moveTargets(visibleIndices: visibleSubmenuIndices, current: current, direction: direction)
            else { return }
            appState.submenuOrder.swapAt(from, to)
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

    /// 与 FinderSync 扩展保持一致的分层着色方法。渲染与缓存统一在
    /// Utils.tintedSymbol（扩展与设置页共用同一份缓存），重复绘制同一图标
    /// 不再重新光栅化；字重沿用设置页原有的 .medium。
    private func tintedSymbol(named name: String, color: NSColor, size: CGFloat, hierarchical: Bool = true) -> NSImage? {
        Utils.tintedSymbol(named: name, color: color, size: size, weight: .medium, hierarchical: hierarchical)
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

    /// 与 FinderSync 扩展保持一致的分层着色方法。渲染与缓存统一在
    /// Utils.tintedSymbol（扩展与设置页共用同一份缓存），重复绘制同一图标
    /// 不再重新光栅化；字重沿用设置页原有的 .medium。
    private func tintedSymbol(named name: String, color: NSColor, size: CGFloat, hierarchical: Bool = true) -> NSImage? {
        Utils.tintedSymbol(named: name, color: color, size: size, weight: .medium, hierarchical: hierarchical)
    }
}

// MARK: - 子菜单编辑信息

struct SubmenuEditInfo: Identifiable {
    let id: String
    let name: String
    let icon: String
}

