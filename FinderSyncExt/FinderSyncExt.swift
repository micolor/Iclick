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
    var myFolderURL = URL(fileURLWithPath: "/")
    /// 主应用进程是否在运行。只由本地 `NSWorkspace.runningApplications` 查询维护，
    /// 不再依赖 DNC 的 running/quit 消息（DNC 不校验发送方）。
    private var isHostAppOpen = false
    /// 主应用 bundle id（用于在扩展内按需拉起 / 判断其是否在运行）
    private static let hostBundleID = "cn.anwen.IClick"


    lazy var appState: AppState = {
        MainActor.assumeIsolated { AppState(inExt: true) }
    }()

    var triggerManKind = FIMenuKind.contextualMenuForContainer

    // macOS 15 上 selectedItemURLs/targetedURL 在点击时可能返回 nil
    // 在菜单构建时缓存，供 action 点击时使用
    private var cachedSelectedURLs: [URL]?
    private var cachedTargetURL: URL?

    // 菜单缓存：键包含 menuKind、配置版本与当前选中数量（见 menuCacheKey）
    private var cachedMenus: [String: NSMenu] = [:]
    // 每个缓存键对应的数据版本号
    private var cachedDataVersions: [String: Int] = [:]
    // 缓存上限：每个 NSMenu 都持有菜单项和图标，选中数量变化时不应无限累积
    private let maxCachedMenus = 16
    private var menuCacheOrder: [String] = []

    // 文件图标缓存（按路径）
    private var iconCache: [String: NSImage] = [:]
    // SF Symbol 图标缓存（按 "name:colorHex:size" 键）
    private var sfSymbolCache: [String: NSImage] = [:]
    // 已缩放到菜单尺寸的图标缓存（系统图标/自定义文件图标）
    private var resizedIconCache: [String: NSImage] = [:]

    // tag -> id 映射（Finder 不保留 representedObject/toolTip）
    private var tagToId: [Int: String] = [:]
    // tag -> path 映射（避免依赖 appState.cdirs，确保路径始终可查）
    private var tagToPath: [Int: String] = [:]
    // 稳定 rid -> tag 映射：同一配置项复用 tag，避免每次重建菜单都新增映射
    private var ridToTag: [String: Int] = [:]
    private var nextTag: Int = 1

    override init() {
        super.init()
        // 主应用没运行时 remotePayload 为空；先把快照放进内存，
        // 避免接下来初始化/建菜单时每读一个 key 都重新解析 plist。
        SharedSettings.adoptSnapshotIfNeeded()
        refreshDataVersion()

        // 清除菜单缓存，确保新逻辑生效
        invalidateMenuCache()
        DiagnosticLog.shared.installCrashHandlers()

        FIFinderSyncController.default().directoryURLs = [myFolderURL]
        logger.info("FinderSync launched from \(Bundle.main.bundlePath, privacy: .public)")

        // 配置不再经 DNC 推送：扩展启动时读快照，之后每次建菜单前按
        // configVersion/mtime 检查快照是否更新（syncFromSnapshotIfNewer）。
        isHostAppOpen = Self.hostAppIsRunning
        // 注意：这里不要碰 appState —— 它是 lazy + MainActor.assumeIsolated，
        // 而扩展的 init 不保证在主线程；只记录快照文件是否存在。
        DiagnosticLog.shared.write(
            "extension init hostRunning=\(isHostAppOpen) "
            + "snapshot=\(FileManager.default.fileExists(atPath: SharedSettings.snapshotURL.path))"
        )

        // 自检认证 IPC：从沙盒扩展里连一次 socket，确认 application-groups 下的
        // Unix socket + 对端签名校验都工作。结果只写诊断日志，不影响正常使用。
        if isHostAppOpen {
            let ping = MessagePayload(action: "ping", messageID: UUID().uuidString)
            DispatchQueue.global(qos: .utility).async {
                let ok = LocalIPCClient.send(ping)
                DiagnosticLog.shared.write("ipc ping \(ok ? "ok" : "failed")")
            }
        }
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

    /// 发送动作消息到主应用。
    ///
    /// 走 App Group 容器里的 Unix socket；主应用会校验对端的代码签名。
    /// 主应用没就绪时先拉起并重试；socket 的响应就是 ack，主应用按
    /// messageID 去重，所以 ack 丢了导致的重复发送不会重复执行动作。
    private func sendMessageToHost(_ payload: MessagePayload) {
        var payload = payload
        if payload.messageID.isEmpty {
            payload.messageID = UUID().uuidString
        }
        deliverViaIPC(payload, attempt: 0)
    }

    private func deliverViaIPC(_ payload: MessagePayload, attempt: Int) {
        if isHostReady, LocalIPCClient.send(payload) {
            DiagnosticLog.shared.write("ipc sent id=\(payload.messageID) action=\(payload.action)")
            return
        }

        if attempt == 0 {
            logger.warning("主应用未就绪或本机 IPC 暂不可用，拉起并重试: \(payload.action)")
            launchHostApp()
        }

        // 主应用已在跑但 socket 没就绪时，给几次重试；没在跑时最多等约 6 秒。
        let maxAttempts = isHostReady ? 3 : 20
        guard attempt < maxAttempts else {
            logger.error("本机 IPC 发送失败: \(payload.action)")
            DiagnosticLog.shared.write("ipc failed id=\(payload.messageID) action=\(payload.action)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.deliverViaIPC(payload, attempt: attempt + 1)
        }
    }

    /// 拉起主应用。
    ///
    /// 用扩展自己所在的 .app，而不是按 bundle id 问 LaunchServices：旧构建
    /// （DerivedData 里的副本、之前注册过的 xcarchive）可能同样带着这个 bundle id，
    /// 查到的未必是「带这个扩展的 /Applications 副本」。拉起一个旧副本会让同一份
    /// SharedSettings.plist 和右键菜单变成两个不一致的世界——菜单里有、点了没反应。
    private func launchHostApp() {
        // 进程已经在跑就别再 open：对运行中的应用再 open 会触发 reopen，
        // 主应用会把设置窗口弹出来（又退回「点一下菜单，界面就冒出来」）。
        // 这里直接返回，下面的重试循环会等它把自己的 "running" 消息推过来。
        if Self.hostAppIsRunning {
            logger.debug("主应用进程已在运行，跳过拉起")
            return
        }

        // FinderSyncExt.appex → PlugIns → Contents → Iclick.app
        var appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: appURL.path) {
            logger.warning("扩展所在 bundle 里找不到主应用，退回按 bundle id 查找")
            guard let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.hostBundleID) else {
                logger.warning("无法定位主应用 \(Self.hostBundleID)")
                return
            }
            appURL = found
        }

        let configuration = NSWorkspace.OpenConfiguration()
        // 告诉主应用这次是扩展拉起的：它不应该把设置窗口弹到用户面前。
        configuration.arguments = ["--launched-by-extension"]
        DiagnosticLog.shared.write("launch host \(appURL.path)")

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                logger.error("拉起主应用失败: \(error.localizedDescription)")
            }
        }
    }

    // 使所有缓存失效（菜单结构 + 图标 + 选中文件），仅在扩展启动时使用
    func invalidateMenuCache() {
        cachedMenus.removeAll()
        cachedDataVersions.removeAll()
        menuCacheOrder.removeAll()
        tagToId.removeAll()
        tagToPath.removeAll()
        ridToTag.removeAll()
        nextTag = 1
        sfSymbolCache.removeAll()
        iconCache.removeAll()
        resizedIconCache.removeAll()
        cachedSelectedURLs = nil
        cachedTargetURL = nil
    }

    /// 仅使菜单结构缓存失效，保留图标缓存（配置变更时使用，图标不会随配置变化）
    private func invalidateMenuStructure() {
        cachedMenus.removeAll()
        cachedDataVersions.removeAll()
        menuCacheOrder.removeAll()
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

    /// DNC 推送丢了也不怕：快照里的版本更新就重新加载。
    /// 每次右键建菜单前调用一次（读一个 5KB 的 plist，成本可接受）。
    @MainActor
    private func syncFromSnapshotIfNewer() {
        guard let dict = SharedSettings.snapshotDictionary(),
              let snapshotVersion = dict[Key.configVersion] as? Int,
              snapshotVersion > currentDataVersion() else {
            return
        }
        SharedSettings.receiveRemote(dict)
        refreshDataVersion()
        appState.refresh()
        invalidateMenuStructure()
        DiagnosticLog.shared.write("config reloaded from snapshot version=\(snapshotVersion)")
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
        // 不要强解包：资源缺失（手工构建漏拷 Assets.car 的将来某次）会让扩展在这里
        // 崩溃，表现为 Finder 工具栏空白、右键菜单也没有，且只留下难查的崩溃日志。
        return NSImage(named: "toolbar")
            ?? NSImage(systemSymbolName: "cursorarrow.click", accessibilityDescription: "Iclick")
            ?? NSImage(size: NSSize(width: 16, height: 16))
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

        // DNC 推送可能丢。每次建菜单前对比一下群组容器快照里的配置版本：
        // 快照更新就重新读，保证最迟在下次右键时看到最新配置。
        MainActor.assumeIsolated {
            syncFromSnapshotIfNewer()
        }

        let dataVersion = currentDataVersion()
        let cacheKey = menuCacheKey(menuKind, version: dataVersion)
        if let cached = cachedMenus[cacheKey],
           let cachedVersion = cachedDataVersions[cacheKey],
           cachedVersion == dataVersion {
            touchMenuCache(cacheKey)
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
        touchMenuCache(cacheKey)
        trimMenuCacheIfNeeded()

        return applicationMenu
    }

    /// 把命中/新插入的菜单移到 LRU 末尾。
    private func touchMenuCache(_ key: String) {
        menuCacheOrder.removeAll { $0 == key }
        menuCacheOrder.append(key)
    }

    /// 菜单缓存超过上限时淘汰最久未使用的项。
    private func trimMenuCacheIfNeeded() {
        while menuCacheOrder.count > maxCachedMenus {
            let oldest = menuCacheOrder.removeFirst()
            cachedMenus.removeValue(forKey: oldest)
            cachedDataVersions.removeValue(forKey: oldest)
        }
    }

    /// 同一条配置项复用同一个 tag。标签映射因此只随配置项数量增长，
    /// 不随“重建菜单次数”增长；已显示的旧菜单也不会因为映射被清掉而失效。
    private func tag(forRid rid: String) -> Int {
        if let existing = ridToTag[rid] { return existing }
        let tag = nextTag
        nextTag += 1
        ridToTag[rid] = tag
        tagToId[tag] = rid
        return tag
    }

    /// 菜单缓存键：菜单内容不仅取决于 menuKind 和配置版本，还取决于当前选中项数量
    /// （requireSelection 的菜单项只在选中文件时出现）。
    /// 只按 (menuKind, version) 做键时，先在空白处右键、再选中文件右键会命中错误的缓存。
    private func menuCacheKey(_ menuKind: FIMenuKind, version: Int) -> String {
        "\(menuKind.rawValue)-\(version)-\(cachedSelectedURLs?.count ?? 0)"
    }

    @MainActor @objc func createMenuForToolbar(_ applicationMenu: NSMenu, menuKind: FIMenuKind) {
        // tag 按 rid 稳定复用（见 tag(forRid:)），不清空映射：
        // 不同 menuKind 的菜单可以共享同一个 tag，旧菜单点击也仍能查到。

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
                menuItem.tag = tag(forRid: item.id)
                menuItem.image = appIcon(for: item)
                mainMenuItems.append(menuItem)
            } else {
                submenuApps.append(item)
            }
        }

        let submenuItem: NSMenuItem?
        // 设置里的「常用 App」子菜单开关（原来那个开关是死的，扩展无条件显示）
        if !submenuApps.isEmpty && appState.showApps {
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
                menuItem.tag = tag(forRid: item.id)
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

    /// 自定义文件图标：按路径 + 修改时间缓存缩放结果，避免每次重建菜单都读盘/缩放。
    private func fileMenuIcon(path: String) -> NSImage? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "file16:\(path):\(mtime)"
        if let cached = resizedIconCache[key] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        let sized = menuSizedImage(image) ?? image
        resizedIconCache[key] = sized
        return sized
    }

    /// 系统文件图标：缓存 16pt 缩放结果。isTemplate 参与 key，
    /// 保留既有「新建文件项会把共享图标改成模板」的行为，不额外改变观感。
    private func appMenuIcon(path: String) -> NSImage {
        let raw = getIcon(for: path)
        let key = "app16:\(path):\(raw.isTemplate)"
        if let cached = resizedIconCache[key] { return cached }
        let sized = menuSizedImage(raw) ?? raw
        resizedIconCache[key] = sized
        return sized
    }

    /// 获取 APP 图标，与设置左侧菜单逻辑一致，缩放至标准菜单尺寸
    private func appIcon(for item: OpenWithApp) -> NSImage {
        if let iconStr = item.icon, !iconStr.isEmpty {
            if iconStr.contains("/") {
                // 自定义文件路径图标
                if let custom = fileMenuIcon(path: iconStr) {
                    return custom
                }
            } else if let sfImage = sfIcon(iconStr, description: item.name) {
                // SF Symbol 图标（已在 sfIcon 中配置为 16pt），直接返回
                return sfImage
            }
        }
        // 统一回退：系统文件图标 → 缩放至菜单尺寸（缩放结果已缓存）
        return appMenuIcon(path: item.url.path)
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
            return fileMenuIcon(path: icon)
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
            // macOS 15 上 selectedItemURLs() 在回调里可能返回 nil；菜单构建时
            // 缓存的值（cachedSelectedURLs）才是可靠的。否则「要求选中文件」的操作
            // 明明有选中项也会被藏掉，而 getTargets 却又拿得到路径。
            let urls = FIFinderSyncController.default().selectedItemURLs() ?? cachedSelectedURLs
            hasSelection = !(urls?.isEmpty ?? true)
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
            menuItem.tag = tag(forRid: item.id)
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
            // 存储特殊 rid 以标识是常用路径点击
            let rid = "common-dir:\(dir.url.path)"
            let tag = tag(forRid: rid)
            menuItem.tag = tag
            tagToPath[tag] = dir.url.path
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
            menuItem.tag = tag(forRid: item.id)

            if let app = item.openApp {
                // 注意：getIcon 返回缓存里的同一个实例，这里改 isTemplate 会永久污染缓存，
                // 使子菜单里同一个 App 的图标也变成单色模板。这是 HEAD 的既有行为，按用户
                // 「不要改变 UI」的要求原样保留，不要在这里加 copy()。
                let icon = getIcon(for: app.path)
                icon.isTemplate = true
                menuItem.image = menuSizedImage(icon)
            } else if item.icon.contains("/") {
                // 自定义文件路径图标，缩放至标准菜单尺寸（结果已缓存）
                menuItem.image = fileMenuIcon(path: item.icon)
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
