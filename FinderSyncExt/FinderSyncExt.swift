//
//  FinderSyncExt.swift
//  FinderSyncExt
//
//  Created by 李旭 on 2024/4/4.
//

import AppKit
@preconcurrency import FinderSync
import UniformTypeIdentifiers
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "IClick", category: "FinderOpen")

class FinderSyncExt: FIFinderSync, @unchecked Sendable {
    var myFolderURL = URL(fileURLWithPath: "/Users/")
    /// 主应用是否已就绪（进程在运行 **且** 它的消息观察者已注册）。
    /// 由主应用推来的 "running" 置 true、"quit" 置 false；读取请用 isHostReady，它会兜底校正过期值。
    private var isHostAppOpen = false
    /// 主应用 bundle id（用于在扩展内按需拉起 / 判断其是否在运行）
    private static let hostBundleID = "cn.anwen.IClick"

    lazy var appState: AppState = {
        MainActor.assumeIsolated { AppState(inExt: true) }
    }()

    let messager = Messager.shared

    var triggerManKind = FIMenuKind.contextualMenuForContainer

    // macOS 15 上 selectedItemURLs/targetedURL 在点击时可能返回 nil
    // 在菜单构建时缓存，供 action 点击时使用
    private var cachedSelectedURLs: [URL]?
    private var cachedTargetURL: URL?

    // 菜单缓存：键包含 menuKind、配置版本与当前选中数量（见 menuCacheKey）
    private var cachedMenus: [String: NSMenu] = [:]
    // 每个缓存键对应的数据版本号
    private var cachedDataVersions: [String: Int] = [:]

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
        logger.info("FinderSync launched from \(Bundle.main.bundlePath, privacy: .public)")

        messager.on(name: Key.hostQuit) { [weak self] _ in
            self?.isHostAppOpen = false
        }
        messager.on(name: Key.hostRunning) { [weak self] payload in
            guard let self else { return }

            // 接收主应用推送的配置数据
            if let configJSON = payload.configJSON, !configJSON.isEmpty {
                if let jsonData = configJSON.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    SharedSettings.receiveRemote(dict)
                }
            }

            self.isHostAppOpen = true

            // 心跳每 3 秒会重复推送同一份 target，值没变就别再赋值：
            // 反复设置 directoryURLs 会让 Finder 重新评估监控范围
            if payload.target.count > 0 {
                let newDirs = Set(payload.target.map { URL(fileURLWithPath: $0) })
                if FIFinderSyncController.default().directoryURLs != newDirs {
                    FIFinderSyncController.default().directoryURLs = newDirs
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 仅当配置版本变化时才刷新菜单；周期心跳会重复推送相同配置，
                // 若每次都 invalidateMenuStructure 会导致右键菜单频繁重建。
                let oldVersion = self.currentDataVersion()
                self.refreshDataVersion()
                if self.currentDataVersion() != oldVersion {
                    self.appState.refresh()
                    self.invalidateMenuStructure()
                }
            }
        }

        // 扩展启动时主应用可能已经在跑了（它没机会给我们推 "running"），本地实测一次
        isHostAppOpen = Self.hostAppIsRunning

        // 向主应用请求配置，重试直到收到响应
        requestConfigFromApp(retry: 0)
    }

    /// 主应用进程当前是否在运行（本地查询，无跨进程开销）
    private static var hostAppIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == hostBundleID }
    }

    /// 主应用是否已就绪，可以安全投递消息。
    ///
    /// 缓存值会过期：主应用被强杀或崩溃时不会发 "quit"，标志会一直停在 true，
    /// 消息就发进了空气里（表现为右键没反应）。所以这里用本地查询兜底校正——
    /// 进程都不在了，就一定是 false。
    ///
    /// 以前靠每 3 秒一次的 DNC 心跳来维持这个标志：扩展发跨进程消息 → 主应用被唤醒 →
    /// 读整个 plist → 所有 Data 转 base64 → 序列化成 JSON → 再发一条 DNC 回来。
    /// 一小时 1200 轮，只为了回答「主应用还在不在」这个本地就能回答的问题。
    /// 本地查询只在真正要发消息时（右键点击）执行一次，不需要轮询。
    private var isHostReady: Bool {
        if isHostAppOpen && !Self.hostAppIsRunning {
            isHostAppOpen = false
            logger.warning("主应用进程已消失（未收到 quit），重置存活标志")
        }
        return isHostAppOpen
    }

    /// 发送消息到主应用；若主应用不在运行，先拉起再等就绪后重发。
    /// DNC 消息是"发出即忘"的，主应用未注册观察者时消息会丢失，因此必须等它就绪。
    private func sendMessageToHost(_ payload: MessagePayload) {
        if isHostReady {
            messager.sendMessage(name: Key.messageFromFinder, data: payload)
            return
        }
        logger.warning("主应用未运行，尝试拉起并重发消息: \(payload.action)")
        launchHostApp()
        func retry(attempt: Int) {
            // 最多等待约 6 秒（20 * 0.3s）
            if attempt > 20 {
                logger.warning("等待主应用就绪超时，仍发送一次（可能丢失）: \(payload.action)")
                messager.sendMessage(name: Key.messageFromFinder, data: payload)
                return
            }
            if isHostReady {
                messager.sendMessage(name: Key.messageFromFinder, data: payload)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { retry(attempt: attempt + 1) }
            }
        }
        retry(attempt: 0)
    }

    /// 通过 bundle id 拉起主应用
    private func launchHostApp() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.hostBundleID) else {
            logger.warning("无法定位主应用 \(Self.hostBundleID)")
            return
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                logger.error("拉起主应用失败: \(error.localizedDescription)")
            }
        }
    }

    func heartBeat() {
        logger.debug("start send message -- heartbeat")
        messager.sendMessage(name: Key.messageFromFinder, data: MessagePayload(action: "heartbeat", target: [], rid: ""))
    }

    /// 向主应用请求配置，失败时重试（最多 10 次，每次间隔 2 秒）
    private func requestConfigFromApp(retry: Int) {
        guard retry < 10 else {
            logger.warning("配置请求重试已达上限，放弃")
            return
        }
        heartBeat()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            // 如果尚未收到配置，继续重试
            if SharedSettings.remotePayload == nil {
                self.requestConfigFromApp(retry: retry + 1)
            }
        }
    }

    // 使所有缓存失效（菜单结构 + 图标 + 选中文件），仅在扩展启动时使用
    func invalidateMenuCache() {
        cachedMenus.removeAll()
        cachedDataVersions.removeAll()
        tagToId.removeAll()
        tagToPath.removeAll()
        nextTag = 1
        sfSymbolCache.removeAll()
        iconCache.removeAll()
        cachedSelectedURLs = nil
        cachedTargetURL = nil
    }

    /// 仅使菜单结构缓存失效，保留图标缓存（配置变更时使用，图标不会随配置变化）
    private func invalidateMenuStructure() {
        cachedMenus.removeAll()
        cachedDataVersions.removeAll()
        // tagToId/tagToPath 不清除——已显示的菜单项点击后仍需通过标签查找
    }

    // 内存缓存的配置版本号，避免每次右键都读 UserDefaults（热路径）
    private var cachedDataVersion: Int = 0

    /// 获取当前配置版本号（优先内存缓存，避免热路径 UserDefaults I/O）
    private func currentDataVersion() -> Int { cachedDataVersion }

    /// 从 UserDefaults 刷新配置版本号缓存
    private func refreshDataVersion() {
        cachedDataVersion = SharedSettings.integer(forKey: Key.configVersion)
    }

    // MARK: - Primary Finder Sync protocol methods

    override func beginObservingDirectory(at url: URL) {
        // The user is now seeing the container's contents.
        // If they see it in more than one view at a time, we're only told once.
        // 这里原本用 info/notice：notice 级别会落盘，而这个回调每次都遍历全部监控目录，
        // 目录多的时候等于持续写磁盘。降为 debug（debug 不落盘、默认不采集）。
        logger.debug("beginObservingDirectoryAtURL: \(url.path, privacy: .public)")
        for dir in FIFinderSyncController.default().directoryURLs ?? [] {
            logger.debug("Sync directory set to \(dir.path, privacy: .public)")
        }
    }

    override func endObservingDirectory(at url: URL) {
        // The user is no longer seeing the container's contents.
        logger.info("endObservingDirectoryAtURL: \(url.path as NSString)")
    }

    override func requestBadgeIdentifier(for url: URL) {
        // 此回调在 Finder 为每个文件请求角标时都会调用，属于热点，保持 debug
        logger.debug("requestBadgeIdentifierForURL: \(url.path, privacy: .public)")
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
        // 缓存当前选中的文件 URL（macOS 15 上点击时 selectedItemURLs 可能返回 nil）
        cachedSelectedURLs = FIFinderSyncController.default().selectedItemURLs()
        cachedTargetURL = FIFinderSyncController.default().targetedURL()

        let dataVersion = currentDataVersion()
        let cacheKey = menuCacheKey(menuKind, version: dataVersion)
        if let cached = cachedMenus[cacheKey],
           let cachedVersion = cachedDataVersions[cacheKey],
           cachedVersion == dataVersion {
            return cached
        }
        let applicationMenu = NSMenu(title: "Iclick")

        switch menuKind {
        case .toolbarItemMenu, .contextualMenuForItems, .contextualMenuForContainer:
            nonisolated(unsafe) let menu = applicationMenu
            MainActor.assumeIsolated {
                createMenuForToolbar(menu, menuKind: menuKind)
            }

        default:
            logger.debug("not have menuKind ")
        }

        cachedMenus[cacheKey] = applicationMenu
        cachedDataVersions[cacheKey] = dataVersion

        return applicationMenu
    }

    /// 菜单缓存键：菜单内容不仅取决于 menuKind 和配置版本，还取决于当前选中项数量
    /// （requireSelection 的菜单项只在选中文件时出现）。
    /// 只按 (menuKind, version) 做键时，先在空白处右键、再选中文件右键会命中错误的缓存。
    private func menuCacheKey(_ menuKind: FIMenuKind, version: Int) -> String {
        "\(menuKind.rawValue)-\(version)-\(cachedSelectedURLs?.count ?? 0)"
    }

    @MainActor @objc func createMenuForToolbar(_ applicationMenu: NSMenu, menuKind: FIMenuKind) {
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
                    applicationMenu.addItem(fileMenuItem)
                }
            case "commonDirs":
                if let commonDirMenuItem = createCommonDirMenuItem() {
                    applicationMenu.addItem(commonDirMenuItem)
                }
            default:
                break
            }
        }

        // 3. 操作项（始终在最后）
        for item in createActionMenuItems(for: menuKind) {
            applicationMenu.addItem(item)
        }
    }

    /// 一次遍历 apps 数组，同时构建主菜单项和子菜单项
    @MainActor private func buildAppMenuItems() -> (mainMenu: [NSMenuItem], submenuItem: NSMenuItem?) {
        var mainMenuItems: [NSMenuItem] = []
        var submenuApps: [OpenWithApp] = []

        // 这里原本每次构建菜单都会把每个 app 打成 error 日志，
        // 右键一次就是 O(n) 次字符串拼接 —— 扩展内存/性能都紧张，去掉逐项诊断即可
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
            submenuMenuItem.title = submenuTitle("submenuApps", fallback: String(localized: "Favorite Apps"))
            if let custom = submenuCustomIcon("submenuApps") {
                submenuMenuItem.image = custom
            } else if let tinted = tintedSymbol(named: "app.badge", color: .systemPurple, size: 16) {
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

    /// 子菜单显示名称：优先用设置里自定义的名字，未自定义时用内置本地化名称。
    /// 主应用推送的配置里包含 submenu_name_* 键。
    private func submenuTitle(_ id: String, fallback: String) -> String {
        if let custom = SharedSettings.string(forKey: "submenu_name_\(id)"), !custom.isEmpty {
            return custom
        }
        return fallback
    }

    /// 子菜单自定义图标：支持自定义图片路径与 SF Symbol。
    /// 返回 nil 表示用户未自定义，调用方继续使用内置的着色图标。
    private func submenuCustomIcon(_ id: String) -> NSImage? {
        guard let icon = SharedSettings.string(forKey: "submenu_icon_\(id)"), !icon.isEmpty else {
            return nil
        }
        if icon.contains("/") {
            return menuSizedImage(NSImage(contentsOfFile: icon))
        }
        return sfIcon(icon, description: id)
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
            actionMenuitems.append(menuItem)
        }
        return actionMenuitems
    }

    // 创建文件菜单容器
    @MainActor @objc func createCommonDirMenuItem() -> NSMenuItem? {
        guard appState.showCommonDirs else { return nil }
        let commonDirs = appState.cdirs.filter { $0.enabled }
        guard !commonDirs.isEmpty else { return nil }

        let menuItem = NSMenuItem()
        menuItem.title = submenuTitle("commonDirs", fallback: String(localized: "Favorite Folders"))
        // 与设置保持一致：默认使用 folder 图标 + 绿色着色；用户自定义了图标则优先用自定义的
        if let custom = submenuCustomIcon("commonDirs") {
            menuItem.image = custom
        } else if let tinted = tintedSymbol(named: "folder", color: .systemGreen, size: 16) {
            menuItem.image = tinted
        } else {
            menuItem.image = sfIcon("folder", description: "Favorite Folders")
                ?? menuSizedImage(NSWorkspace.shared.icon(for: .folder))
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
        }

        menuItem.submenu = submenu
        return menuItem
    }

    @objc dynamic func openCommonDir(_ menuItem: NSMenuItem) {
        let tag = menuItem.tag
        guard let path = tagToPath[tag] else { return }
        let rid = tagToId[tag] ?? ""
        sendMessageToHost(MessagePayload(action: "common-dirs", target: [path], rid: rid))
    }

    @MainActor @objc func createFileCreateMenuItem() -> NSMenuItem? {
        guard appState.showNewFiles else { return nil }
        let enabledFiletypeItems = appState.newFiles.filter(\.enabled)
        guard !enabledFiletypeItems.isEmpty else { return nil }
        let menuItem = NSMenuItem()
        menuItem.title = submenuTitle("newFiles", fallback: String(localized: "New File"))
        // 与设置保持一致：默认 doc.badge.plus + 蓝色着色；用户自定义了图标则优先用自定义的
        if let custom = submenuCustomIcon("newFiles") {
            menuItem.image = custom
        } else if let tinted = tintedSymbol(named: "doc.badge.plus", color: .systemBlue, size: 16) {
            menuItem.image = tinted
        } else {
            menuItem.image = menuSizedImage(NSWorkspace.shared.icon(for: .plainText))
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
                // 注意：getIcon 返回缓存里的同一个实例，这里改 isTemplate 会永久污染缓存，
                // 使子菜单里同一个 App 的图标也变成单色模板。这是 HEAD 的既有行为，按用户
                // 「不要改变 UI」的要求原样保留，不要在这里加 copy()。
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

    @objc dynamic func createFile(_ menuItem: NSMenuItem) {
        guard let rid = tagToId[menuItem.tag] else { return }
        // macOS 15 上 targetedURL 在点击时可能返回 nil，使用菜单构建时缓存的值
        guard let target = (FIFinderSyncController.default().targetedURL() ?? cachedTargetURL)?.path() else { return }
        sendMessageToHost(MessagePayload(action: "Create File", target: [target], rid: rid))
    }

    @objc dynamic func actioning(_ menuItem: NSMenuItem) {
        guard let rid = tagToId[menuItem.tag] else {
            logger.warning("actioning: tag \(menuItem.tag) 无对应 rid，菜单可能已过期")
            return
        }

        // 常用路径已迁移到 openCommonDir，此处保留兼容
        if rid.hasPrefix("common-dir:") {
            let path = rid.replacingOccurrences(of: "common-dir:", with: "")
            sendMessageToHost(MessagePayload(action: "common-dirs", target: [path], rid: rid))
            return
        }

        let target = getTargets()
        if target.isEmpty {
            logger.warning("actioning: rid=\(rid) getTargets 为空，跳过")
            return
        }
        let trigger = getTriggerKind(triggerManKind)
        logger.info("actioning: rid=\(rid), trigger=\(trigger), target=\(target)")
        sendMessageToHost(MessagePayload(action: "actioning", target: target, rid: rid, trigger: trigger))
    }

    func getTargets() -> [String] {
        var target: [String] = []

        switch triggerManKind {
        case FIMenuKind.contextualMenuForItems:
            // macOS 15 上 selectedItemURLs 在点击时可能返回 nil，使用菜单构建时缓存的值
            if let urls = FIFinderSyncController.default().selectedItemURLs() ?? cachedSelectedURLs {
                for url in urls {
                    target.append(url.path())
                }
            } else {
                logger.warning("not have selected dirs")
            }
            if target.isEmpty {
                if let targetURL = FIFinderSyncController.default().targetedURL() ?? cachedTargetURL {
                    target.append(targetURL.path())
                    logger.info("getTargets: selectedItemURLs 为空，降级到 targetedURL: \(targetURL.path)")
                }
            }

        case FIMenuKind.toolbarItemMenu:
            if let urls = FIFinderSyncController.default().selectedItemURLs() ?? cachedSelectedURLs {
                for url in urls {
                    target.append(url.path())
                }
            }
            if target.isEmpty {
                if let targetURL = FIFinderSyncController.default().targetedURL() ?? cachedTargetURL {
                    target.append(targetURL.path())
                }
            }

        default:
            if let targetURL = FIFinderSyncController.default().targetedURL() ?? cachedTargetURL {
                target.append(targetURL.path())
            }
        }

        return target
    }

    @objc dynamic func appOpen(_ menuItem: NSMenuItem) {
        guard let rid = tagToId[menuItem.tag] else {
            logger.warning("appOpen: tag \(menuItem.tag) 无对应 rid")
            return
        }
        let target: [String] = getTargets()
        if target.isEmpty {
            logger.warning("appOpen: rid=\(rid) getTargets 为空，跳过")
            return
        }
        logger.info("appOpen: rid=\(rid), target=\(target)")
        sendMessageToHost(MessagePayload(action: "open", target: target, rid: rid))
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
