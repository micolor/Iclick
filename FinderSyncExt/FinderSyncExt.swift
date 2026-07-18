//
//  FinderSyncExt.swift
//  FinderSyncExt
//
//  Created by 李旭 on 2024/4/4.
//

import AppKit
import Cocoa
@preconcurrency import FinderSync
import UniformTypeIdentifiers

// MARK: DELETE

import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "IClick", category: "FinderOpen")

class FinderSyncExt: FIFinderSync, @unchecked Sendable {
    var myFolderURL = URL(fileURLWithPath: "/Users/")
    var isHostAppOpen = false
    lazy var appState: AppState = {
        MainActor.assumeIsolated { AppState(inExt: true) }
    }()

    let messager = Messager.shared

    var triggerManKind = FIMenuKind.contextualMenuForContainer

    // 菜单缓存：按 menuKind 区分，避免不同触发类型的菜单混淆
    private var cachedMenus: [FIMenuKind: NSMenu] = [:]
    // 每个 menuKind 对应的数据版本号
    private var cachedDataVersions: [FIMenuKind: Int] = [:]

    // 文件图标缓存（按路径）
    private var iconCache: [String: NSImage] = [:]
    // SF Symbol 图标缓存（按 "name:colorHex:size" 键）
    private var sfSymbolCache: [String: NSImage] = [:]

    // tag -> id 映射（Finder 不保留 representedObject/toolTip）
    private var tagToId: [Int: String] = [:]
    // tag -> path 映射（避免依赖 appState.cdirs，确保路径始终可查）
    private var tagToPath: [Int: String] = [:]
    private var nextTag: Int = 1

    override init() {
        super.init()
        refreshDataVersion()

        // 清除菜单缓存，确保新逻辑生效
        invalidateMenuCache()

        FIFinderSyncController.default().directoryURLs = [myFolderURL]
        NSLog(">>> FinderSync() launched from \(Bundle.main.bundlePath as NSString)")

        messager.on(name: "quit") { [weak self] _ in
            self?.isHostAppOpen = false
        }
        messager.on(name: "running") { [weak self] payload in
            guard let self else { return }

            self.isHostAppOpen = true

            if payload.target.count > 0 {
                FIFinderSyncController.default().directoryURLs = Set(payload.target.map { URL(fileURLWithPath: $0) })
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshDataVersion()
                self.appState.refresh()
                self.invalidateMenuStructure()  // 配置更新时仅清除菜单结构，保留图标缓存
                self.heartBeat()
            }
        }

        // 监听配置变更通知
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleConfigChanged),
            name: NSNotification.Name(Key.configChangedNotification),
            object: nil
        )

        // 先尝试加载主应用状态，乐观假设已运行
        messager.sendMessage(name: Key.messageFromFinder, data: MessagePayload(action: "heartbeat", target: [], rid: ""))
    }

    func heartBeat() {
        logger.warning("start send message -- heartbeat")
        messager.sendMessage(name: Key.messageFromFinder, data: MessagePayload(action: "heartbeat", target: [], rid: ""))
    }

    // 使所有缓存失效（菜单结构 + 图标），仅在扩展启动时使用
    func invalidateMenuCache() {
        cachedMenus.removeAll()
        cachedDataVersions.removeAll()
        tagToId.removeAll()
        tagToPath.removeAll()
        nextTag = 1
        sfSymbolCache.removeAll()
        iconCache.removeAll()
    }

    /// 仅使菜单结构缓存失效，保留图标缓存（配置变更时使用，图标不会随配置变化）
    private func invalidateMenuStructure() {
        cachedMenus.removeAll()
        cachedDataVersions.removeAll()
        // tagToId/tagToPath 不清除——已显示的菜单项点击后仍需通过标签查找
    }

    /// 主应用配置变更时刷新数据并使菜单缓存失效（下次右键时懒构建，避免阻塞主 actor 触发看门狗）
    @objc func handleConfigChanged() {
        logger.info("收到配置变更通知，刷新数据并清除菜单缓存")
        refreshDataVersion()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.appState.refresh()
            self.invalidateMenuStructure()
        }
    }

    // 内存缓存的配置版本号，避免每次右键都读 UserDefaults（热路径）
    private var cachedDataVersion: Int = 0

    /// 获取当前配置版本号（优先内存缓存，避免热路径 UserDefaults I/O）
    private func currentDataVersion() -> Int { cachedDataVersion }

    /// 从 UserDefaults 刷新配置版本号缓存
    private func refreshDataVersion() {
        cachedDataVersion = UserDefaults.group.integer(forKey: Key.configVersion)
    }

    // MARK: - Primary Finder Sync protocol methods

    override func beginObservingDirectory(at url: URL) {
        // The user is now seeing the container's contents.
        // If they see it in more than one view at a time, we're only told once.
        logger.info("beginObservingDirectoryAtURL: \(url.path as NSString)")
        let dirs = FIFinderSyncController.default().directoryURLs!

        for dir in dirs {
            logger.notice("Sync directory set to \(dir.path)")
        }
    }

    override func endObservingDirectory(at url: URL) {
        // The user is no longer seeing the container's contents.
        logger.info("endObservingDirectoryAtURL: \(url.path as NSString)")
    }

    override func requestBadgeIdentifier(for url: URL) {
        NSLog("requestBadgeIdentifierForURL: %@", url.path as NSString)
    }

    // MARK: - Menu and toolbar item support

    override var toolbarItemName: String {
        return "Iclick"
    }

    override var toolbarItemToolTip: String {
        return "Iclick: Click the toolbar item for a menu."
    }

    override var toolbarItemImage: NSImage {
        return NSImage(named: "toolbar")!
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        // 确保在主线程执行，避免 MainActor.assumeIsolated 在非主线程崩溃
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.menu(for: menuKind) }
        }
        triggerManKind = menuKind
        NSLog("[IClick] menu(for:) 被调用, menuKind=\(String(describing: menuKind)), triggerManKind=\(String(describing: triggerManKind))")

        let dataVersion = currentDataVersion()
        if let cached = cachedMenus[menuKind],
           let cachedVersion = cachedDataVersions[menuKind],
           cachedVersion == dataVersion {
            NSLog("[IClick] 缓存命中, menuKind=\(String(describing: menuKind)), version=\(dataVersion), tagToId.count=\(tagToId.count)")
            return cached
        }

        NSLog(">>> 构建新菜单, version: \(dataVersion)")
        let applicationMenu = NSMenu(title: "Iclick")

        switch menuKind {
        case .toolbarItemMenu, .contextualMenuForItems, .contextualMenuForContainer:
            nonisolated(unsafe) let menu = applicationMenu
            MainActor.assumeIsolated {
                createMenuForToolbar(menu, menuKind: menuKind)
            }

        default:
            logger.warning("not have menuKind ")
        }

        cachedMenus[menuKind] = applicationMenu
        cachedDataVersions[menuKind] = dataVersion

        return applicationMenu
    }

    @MainActor @objc func createMenuForToolbar(_ applicationMenu: NSMenu, menuKind: FIMenuKind) {
        NSLog(">>> createMenuForToolbar 开始构建菜单")
        // tag 映射不做全量清除（不同 menuKind 的菜单会共享映射），
        // 仅依靠递增 nextTag 保证标签唯一，旧映射被新构建覆盖。

        // 1. 一次遍历 apps，分流主菜单和子菜单
        let (mainMenuItems, submenuAppsItem) = buildAppMenuItems()

        for nsmenu in mainMenuItems {
            applicationMenu.addItem(nsmenu)
        }

        // 2. 子菜单项（按 submenuOrder 排序）
        for id in appState.submenuOrder {
            switch id {
            case "submenuApps":
                if let submenuAppsItem = submenuAppsItem {
                    applicationMenu.addItem(submenuAppsItem)
                }
            case "newFiles":
                if let fileMenuItem = createFileCreateMenuItem() {
                    NSLog(">>> 添加新建文件菜单")
                    applicationMenu.addItem(fileMenuItem)
                } else {
                    NSLog(">>> 新建文件菜单为空")
                }
            case "commonDirs":
                if let commonDirMenuItem = createCommonDirMenuItem() {
                    NSLog(">>> 添加常用目录菜单")
                    applicationMenu.addItem(commonDirMenuItem)
                } else {
                    NSLog(">>> 常用目录菜单为空")
                }
            default:
                break
            }
        }

        // 3. 操作项（始终在最后）
        for item in createActionMenuItems(for: menuKind) {
            applicationMenu.addItem(item)
        }
        NSLog(">>> 菜单构建完成，共 \(applicationMenu.items.count) 项")
    }

    /// 一次遍历 apps 数组，同时构建主菜单项和子菜单项
    @MainActor private func buildAppMenuItems() -> (mainMenu: [NSMenuItem], submenuItem: NSMenuItem?) {
        var mainMenuItems: [NSMenuItem] = []
        var submenuApps: [OpenWithApp] = []

        for item in appState.apps where item.enabled {
            if item.showInMainMenu {
                let menuItem = NSMenuItem()
                menuItem.target = self
                menuItem.title = String(localized: "Open With \(item.name)")
                menuItem.action = #selector(appOpen(_:))
                menuItem.tag = nextTag
                tagToId[nextTag] = item.id
                nextTag += 1
                menuItem.image = appIcon(for: item)
                mainMenuItems.append(menuItem)
            } else {
                submenuApps.append(item)
            }
        }

        let submenuItem: NSMenuItem?
        if !submenuApps.isEmpty {
            let submenuMenuItem = NSMenuItem()
            submenuMenuItem.title = String(localized: "Favorite Apps")
            if let tinted = tintedSymbol(named: "app.badge", color: .systemPurple, size: 16) {
                submenuMenuItem.image = tinted
            } else {
                submenuMenuItem.image = sfIcon("app", description: "Favorite Apps")
            }
            let submenu = NSMenu(title: "Favorite Apps submenu")
            for item in submenuApps {
                let menuItem = NSMenuItem()
                menuItem.target = self
                menuItem.title = item.name
                menuItem.action = #selector(appOpen(_:))
                menuItem.tag = nextTag
                tagToId[nextTag] = item.id
                nextTag += 1
                menuItem.image = appIcon(for: item)
                submenu.addItem(menuItem)
            }
            submenuMenuItem.submenu = submenu
            submenuItem = submenuMenuItem
        } else {
            submenuItem = nil
        }

        return (mainMenuItems, submenuItem)
    }

    // 获取缓存的图标
    private func getIcon(for path: String) -> NSImage {
        if let cached = iconCache[path] {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }

    /// 获取 APP 图标，与设置左侧菜单逻辑一致，缩放至标准菜单尺寸
    private func appIcon(for item: OpenWithApp) -> NSImage {
        if let iconStr = item.icon, !iconStr.isEmpty {
            if iconStr.contains("/") {
                // 自定义文件路径图标
                if let custom = menuSizedImage(NSImage(contentsOfFile: iconStr)) {
                    return custom
                }
            } else if let sfImage = sfIcon(iconStr, description: item.name) {
                // SF Symbol 图标（已在 sfIcon 中配置为 16pt），直接返回
                return sfImage
            }
        }
        // 统一回退：系统文件图标 → 缩放至菜单尺寸
        let fallback = getIcon(for: item.url.path)
        return menuSizedImage(fallback) ?? fallback
    }

    // 创建 SF Symbol 图标（非模板模式，显示原生彩色），大小为 16pt 匹配菜单图标标准尺寸
    private func sfIcon(_ name: String, description: String? = nil) -> NSImage? {
        let key = "sf:\(name):16"
        if let cached = sfSymbolCache[key] { return cached }
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: description) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let configured = img.withSymbolConfiguration(config)
        configured?.isTemplate = false
        if let result = configured { sfSymbolCache[key] = result }
        return configured
    }

    /// 缩放图片到标准菜单图标尺寸（16×16 点），保证图标在 Retina 屏幕上也不失真
    private func menuSizedImage(_ image: NSImage?) -> NSImage? {
        guard let image = image else { return nil }
        let targetSize = NSSize(width: 16, height: 16)
        guard image.size != targetSize else { return image }

        // 复制图像并设置尺寸，保留原始像素数据供 Retina 屏幕使用
        let resized = image.copy() as? NSImage ?? image
        resized.size = targetSize
        return resized
    }

    /// 创建着色 SF Symbol 图标，使用分级渲染（hierarchical）保留符号层次细节，统一渲染至 16×16 画布保证菜单中视觉一致
    private func tintedSymbol(named name: String, color: NSColor, size: CGFloat, hierarchical: Bool = true) -> NSImage? {
        // 缓存键：symbol名 + 颜色分量hex + 尺寸 + 是否分层（hex 保证跨色彩空间稳定）
        let colorHex = color.usingColorSpace(.sRGB).flatMap { c in
            String(format: "#%02X%02X%02X",
                   Int(round(c.redComponent * 255)),
                   Int(round(c.greenComponent * 255)),
                   Int(round(c.blueComponent * 255)))
        } ?? "?"
        let key = "tint:\(name):\(colorHex):\(Int(size)):\(hierarchical)"
        if let cached = sfSymbolCache[key] { return cached }

        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        var config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        if hierarchical {
            config = config.applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        } else {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        }
        guard let tinted = sym.withSymbolConfiguration(config) else { return nil }
        tinted.isTemplate = false
        // 统一菜单图标尺寸为 16×16，菜单中视觉大小一致
        tinted.size = NSSize(width: 16, height: 16)
        sfSymbolCache[key] = tinted
        return tinted
    }

    @MainActor @objc func createActionMenuItems(for menuKind: FIMenuKind) -> [NSMenuItem] {
        var actionMenuitems: [NSMenuItem] = []
        logger.info("createActionMenuItems: \(self.appState.actions.count) actions, \(self.appState.actions.filter(\.enabled).count) enabled")

        let hasSelection: Bool
        switch menuKind {
        case .contextualMenuForItems:
            hasSelection = true
        case .toolbarItemMenu:
            hasSelection = !(FIFinderSyncController.default().selectedItemURLs()?.isEmpty ?? true)
        default:
            hasSelection = false
        }

        for item in appState.actions.filter(\.enabled) {
            // 要求选中文件的操作，在未选中时不显示
            if item.requireSelection && !hasSelection {
                continue
            }
            let menuItem = NSMenuItem()
            menuItem.target = self
            menuItem.title = String(localized: String.LocalizationValue(item.name))
            menuItem.action = #selector(actioning(_:))
            menuItem.tag = nextTag
            tagToId[nextTag] = item.id
            nextTag += 1
            if RCAction.isCustomIcon(item.icon) {
                // 自定义图片路径图标，缩放至标准菜单尺寸
                menuItem.image = menuSizedImage(NSImage(contentsOfFile: item.icon))
            } else {
                // SF Symbol：使用分级着色，保留图标色彩和比例
                let color = RCAction.nsIconColor(for: item.icon)
                if let tinted = tintedSymbol(named: item.icon, color: color, size: 16) {
                    menuItem.image = tinted
                } else {
                    // 回退到无色模板 SF Symbol
                    let sym = NSImage(systemSymbolName: item.icon, accessibilityDescription: item.name)
                        ?? NSImage(systemSymbolName: "bolt", accessibilityDescription: item.name)
                    let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
                    let img = sym?.withSymbolConfiguration(config)
                    img?.isTemplate = true
                    menuItem.image = img
                }
            }
            logger.info("  action item: \(item.name), id: \(item.id), tag: \(menuItem.tag)")

            actionMenuitems.append(menuItem)
        }
        return actionMenuitems
    }

    // 创建文件菜单容器
    @MainActor @objc func createCommonDirMenuItem() -> NSMenuItem? {
        guard appState.showCommonDirs else {
            logger.info("常用路径菜单已关闭 (showCommonDirs=false)")
            return nil
        }
        let commonDirs = appState.cdirs.filter { $0.enabled }
        if commonDirs.isEmpty {
            logger.warning("没有启用的常用路径")
            return nil
        }
        logger.info("开始创建常用路径菜单项")

        let menuItem = NSMenuItem()
        menuItem.title = String(localized: "Favorite Folders")
        // 与设置保持一致：使用 folder 图标 + 绿色着色
        if let tinted = tintedSymbol(named: "folder", color: .systemGreen, size: 16) {
            menuItem.image = tinted
        } else {
            menuItem.image = sfIcon("folder", description: "Favorite Folders")
                ?? menuSizedImage(NSWorkspace.shared.icon(forFileType: "public.folder"))
        }
        let submenu = NSMenu(title: "Favorite Folders submenu")

        for dir in commonDirs {
            let menuItem = NSMenuItem()
            menuItem.target = self
            menuItem.title = dir.name
            menuItem.subtitle = dir.url.path
            // 使用 openCommonDir 选择器，直接通过 NSWorkspace 打开目录，同时发送消息作为备份
            menuItem.action = #selector(openCommonDir(_:))
            menuItem.tag = nextTag
            // 存储特殊 rid 以标识是常用路径点击
            tagToId[nextTag] = "common-dir:\(dir.url.path)"
            tagToPath[nextTag] = dir.url.path
            nextTag += 1
            // 与父菜单一致的绿色着色
            if let tinted = tintedSymbol(named: "folder.fill", color: .systemGreen, size: 16) {
                menuItem.image = tinted
            } else {
                menuItem.image = menuSizedImage(NSWorkspace.shared.icon(forFile: dir.url.path))
            }

            submenu.addItem(menuItem)
            logger.info("添加常用路径菜单项: \(dir.name)")
        }

        menuItem.submenu = submenu
        logger.info("常用路径菜单创建完成")
        return menuItem
    }

    @objc dynamic func openCommonDir(_ menuItem: NSMenuItem) {
        let tag = menuItem.tag
        guard let path = tagToPath[tag] else { return }
        let rid = tagToId[tag] ?? ""
        messager.sendMessage(name: Key.messageFromFinder, data: MessagePayload(action: "common-dirs", target: [path], rid: rid))
    }

    @MainActor @objc func createFileCreateMenuItem() -> NSMenuItem? {
        guard appState.showNewFiles else {
            logger.info("新建文件菜单已关闭 (showNewFiles=false)")
            return nil
        }
        let enabledFiletypeItems = appState.newFiles.filter(\.enabled)
        if enabledFiletypeItems.isEmpty {
            return nil
        }
        let menuItem = NSMenuItem()
        menuItem.title = String(localized: "New File")
        // 与设置保持一致：使用 doc.badge.plus 图标 + 蓝色着色
        if let tinted = tintedSymbol(named: "doc.badge.plus", color: .systemBlue, size: 16) {
            menuItem.image = tinted
        } else {
            menuItem.image = menuSizedImage(NSWorkspace.shared.icon(forFileType: "public.plain-text"))
        }
        let submenu = NSMenu(title: "file create menu")
        for item in enabledFiletypeItems {
            let menuItem = NSMenuItem()
            menuItem.target = self
            menuItem.title = "\(item.defaultName)\(item.ext)"
            menuItem.action = #selector(createFile(_:))
            menuItem.tag = nextTag
            tagToId[nextTag] = item.id
            nextTag += 1

            if let app = item.openApp {
                let icon = getIcon(for: app.path)
                icon.isTemplate = true
                menuItem.image = menuSizedImage(icon)
            } else if item.icon.contains("/") {
                // 自定义文件路径图标，缩放至标准菜单尺寸
                menuItem.image = menuSizedImage(NSImage(contentsOfFile: item.icon))
                    ?? menuSizedImage(item.systemIcon)
            } else if let assetImage = NSImage(named: item.icon) {
                // Asset Catalog 图片（与设置 systemIcon 逻辑一致）
                menuItem.image = menuSizedImage(assetImage)
            } else {
                // SF Symbol，与设置保持一致：按文件扩展名取图标名和颜色着色
                let sfName = NewFile.sfSymbolName(for: item.ext)
                let color = NewFile.nsFileIconColor(for: item.ext)
                if let tinted = tintedSymbol(named: sfName, color: color, size: 16) {
                    menuItem.image = tinted
                } else {
                    menuItem.image = sfIcon(sfName, description: item.name)
                }
            }

            submenu.addItem(menuItem)
        }
        menuItem.submenu = submenu
        return menuItem
    }

    @objc func createFile(_ menuItem: NSMenuItem) {
        guard let rid = tagToId[menuItem.tag] else { return }
        guard let target = FIFinderSyncController.default().targetedURL()?.path() else { return }
        messager.sendMessage(name: Key.messageFromFinder, data: MessagePayload(action: "Create File", target: [target], rid: rid))
    }

    @objc func actioning(_ menuItem: NSMenuItem) {
        guard let rid = tagToId[menuItem.tag] else { return }

        // 常用路径已迁移到 openCommonDir，此处保留兼容
        if rid.hasPrefix("common-dir:") {
            let path = rid.replacingOccurrences(of: "common-dir:", with: "")
            messager.sendMessage(name: Key.messageFromFinder, data: MessagePayload(action: "common-dirs", target: [path], rid: rid))
            return
        }

        let target = getTargets()
        if target.isEmpty { return }
        let trigger = getTriggerKind(triggerManKind)
        messager.sendMessage(name: Key.messageFromFinder, data: MessagePayload(action: "actioning", target: target, rid: rid, trigger: trigger))
    }

    func getTargets() -> [String] {
        var target: [String] = []

        switch triggerManKind {
        case FIMenuKind.contextualMenuForItems:
            if let urls = FIFinderSyncController.default().selectedItemURLs() {
                for url in urls {
                    target.append(url.path())
                }
            } else {
                logger.warning("not have selected dirs")
            }

        case FIMenuKind.toolbarItemMenu:
            if let urls = FIFinderSyncController.default().selectedItemURLs() {
                for url in urls {
                    target.append(url.path())
                }
            }
            if target.isEmpty {
                if let targetURL = FIFinderSyncController.default().targetedURL() {
                    target.append(targetURL.path())
                }
            }

        default:
            if let targetURL = FIFinderSyncController.default().targetedURL() {
                target.append(targetURL.path())
            }
        }

        return target
    }

    @objc func appOpen(_ menuItem: NSMenuItem) {
        guard let rid = tagToId[menuItem.tag] else { return }
        let target: [String] = getTargets()
        if !target.isEmpty {
            messager.sendMessage(name: Key.messageFromFinder, data: MessagePayload(action: "open", target: target, rid: rid))
        }
    }

    @objc func getTriggerKind(_ kind: FIMenuKind) -> String {
        switch kind {
        case .contextualMenuForItems:
            return "ctx-items"
        case .contextualMenuForContainer:
            return "ctx-container"
        case .contextualMenuForSidebar:
            return "ctx-sidebar"
        case .toolbarItemMenu:
            return "toolbar"
        default:
            return "unknown"
        }
    }

}
