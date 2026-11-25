//
//  File.swift
//  IClick
//
//  Created by 李旭 on 2024/9/26.
//

import Combine
import Foundation

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @AppLog(category: "AppState")
    private var logger

    @Published var apps: [OpenWithApp] = []
    @Published var dirs: [PermissiveDir] = []
    @Published var actions: [RCAction] = []
    @Published var newFiles: [NewFile] = []
    @Published var cdirs: [CommonDir] = []
    @Published var inExt: Bool

    /// 本次 `load()` 解码失败的配置键。`save()` 必须跳过这些键，否则会把内存里
    /// 的默认值（常见是空数组）写回磁盘，把用户只是「暂时读不出来」的数据永久抹掉。
    /// 重新 load 成功后会自动移出。
    private var failedKeys: Set<String> = []

    // 注意：这些是计算属性，不是 @Published。写入之后必须手动发 objectWillChange，
    // 否则设置界面里的 Toggle 读到的还是本次视图更新时捕获的旧值，开关会「回弹」——
    // plist 和 Finder 菜单其实已经变了，界面却显示没变。
    var showCommonDirs: Bool {
        get { SharedSettings.bool(forKey: "showCommonDirs") }
        set {
            SharedSettings.set(newValue, forKey: "showCommonDirs")
            SharedSettings.synchronize()
            objectWillChange.send()
            notifyConfigChanged()
        }
    }
    var showNewFiles: Bool {
        get { SharedSettings.bool(forKey: "showNewFiles") }
        set {
            SharedSettings.set(newValue, forKey: "showNewFiles")
            SharedSettings.synchronize()
            objectWillChange.send()
            notifyConfigChanged()
        }
    }
    /// 「常用 App」子菜单的显示开关。键不存在时默认开启（老配置里没有这个键）。
    var showApps: Bool {
        get {
            // 只读一次：原来的三元表达式会先 object 再 bool，触发两次整份配置加载。
            guard let value = SharedSettings.object(forKey: "showSubmenuApps") else { return true }
            return (value as? Bool) ?? false
        }
        set {
            SharedSettings.set(newValue, forKey: "showSubmenuApps")
            SharedSettings.synchronize()
            objectWillChange.send()
            notifyConfigChanged()
        }
    }
    /// 初始化默认值
    private func initDefaults() {
        if SharedSettings.object(forKey: "showCommonDirs_init") == nil {
            SharedSettings.set(true, forKey: "showCommonDirs_init")
            if SharedSettings.object(forKey: "showCommonDirs") == nil {
                SharedSettings.set(true, forKey: "showCommonDirs")
            }
            if SharedSettings.object(forKey: "showNewFiles") == nil {
                SharedSettings.set(true, forKey: "showNewFiles")
            }
        }
    }

    /// 子菜单项的排序顺序（ID 数组）
    @Published var submenuOrder: [String] = [] {
        didSet {
            // 初始化 / 从快照同步时给这个属性赋值不是用户操作：不能顺手落盘 +
            // 递增版本号，否则每次启动都白写一遍 plist，还会让扩展多一次无意义的重载。
            guard !suppressSubmenuOrderPersist else { return }
            SharedSettings.set(submenuOrder, forKey: "submenuOrder")
            // 必须通知扩展：否则右键菜单顺序仍是旧的，直到下次其它配置变更才刷新
            notifyConfigChanged()
        }
    }

    /// 仅为初始化 / 快照同步期间的赋值屏蔽 didSet 的副作用
    private var suppressSubmenuOrderPersist = false

    /// 默认子菜单顺序
    static let defaultSubmenuOrder = ["submenuApps", "newFiles", "commonDirs"]

    /// 清理已废弃的配置键。
    /// 这两个键在当前代码里已无任何引用，留在 plist 里只会让人误以为它们在起作用；
    /// 其中 launchAtLoginInitialized 是早期一版「首次启动自动开启登录项」留下的哨兵。
    /// 幂等：键不存在时 isExtension 之外的 removeObject 不会改动文件内容。
    private func cleanupStaleKeys() {
        let staleKeys = ["SANDBOX_TEST", "launchAtLoginInitialized"]
        for key in staleKeys where SharedSettings.object(forKey: key) != nil {
            SharedSettings.removeObject(forKey: key)
            logger.info("已清理废弃的配置键: \(key)")
        }
    }

    init(inExt: Bool = false) {
        self.inExt = inExt
        // 确保默认值存在
        initDefaults()
        // 数据迁移：从旧 App Group suite 迁移到新共享 suite（只需主应用执行一次）
        if !inExt {
            migrateFromLegacyIfNeeded()
            cleanupStaleKeys()
        }
        // 加载子菜单排序（初始化赋值不落盘，见 didSet 里的 suppress 标志）
        suppressSubmenuOrderPersist = true
        if let saved = SharedSettings.array(forKey: "submenuOrder") as? [String] {
            submenuOrder = saved
        } else {
            submenuOrder = Self.defaultSubmenuOrder
            // 首次运行仍把默认顺序写一次，保持「键总在」的既有数据形状；
            // 不触发版本号（扩展读不到时会回退到同一份默认值）。
            SharedSettings.set(submenuOrder, forKey: "submenuOrder")
        }
        suppressSubmenuOrderPersist = false
        // 扩展中同步加载，避免首次右键时数据为空
        if inExt {
            load()
        } else {
            Task {
                await MainActor.run {
                    logger.info("start load")
                    load()
                }
            }
        }
    }

    /// 将旧 App Group UserDefaults 数据迁移到新共享 suite（无 App Group 权限也能读写）
    private func migrateFromLegacyIfNeeded() {
        let migrationKey = "_migrated_to_shared_suite"
        // 必须用 object(forKey:)：哨兵是以 Bool 写入的，string(forKey:) 对 Bool 返回 nil，
        // 会导致 guard 永远通过、迁移每次启动都重跑（历史 bug：apps 被旧值 ima.copilot 顶掉）
        guard SharedSettings.object(forKey: migrationKey) == nil else { return }

        let legacyKeys: [String] = [
            Key.apps, Key.actions, Key.fileTypes, Key.permDirs, Key.commonDirs,
            "submenuOrder", Key.configVersion,
        ]
        for key in legacyKeys {
            // 只填缺、不覆盖：shared 里已存在的键（用户当前的配置）绝不能被动旧值顶掉
            guard SharedSettings.object(forKey: key) == nil,
                  let value = UserDefaults.group.object(forKey: key) else { continue }
            SharedSettings.set(value, forKey: key)
        }
        SharedSettings.set(true, forKey: migrationKey)
        SharedSettings.synchronize()
        logger.info("数据已从旧 App Group suite 迁移到新共享 suite")
    }
    
    // Apps
    @MainActor func deleteApp(index: Int) {
        apps.remove(at: index)
        do {
            try save()
            // 使用 result
        } catch {
            // 处理错误
            logger.info("save error: \(error.localizedDescription)")
        }
    }

    /// 批量删除（onDelete 可能一次传入多个 index）。
    ///
    /// 不用 SwiftUI 的 `remove(atOffsets:)`：那是 SwiftUI 给
    /// RangeReplaceableCollection 加的扩展，而 AppState 也编译进 FinderSync 扩展 ——
    /// 只这一处调用就会让扩展把整个 SwiftUI 链接进来。
    /// 重建数组与它等价（一次 @Published 更新、越界索引忽略），也不会因索引位移删错项。
    @MainActor func deleteApps(at offsets: IndexSet) {
        apps = apps.enumerated().compactMap { offsets.contains($0.offset) ? nil : $0.element }
        do {
            try save()
        } catch {
            logger.info("save error: \(error.localizedDescription)")
        }
    }

    @MainActor func addApp(item: OpenWithApp) {
        logger.info("start add app")
        // 同一个 App 加两次，右键菜单里就会出现两条一模一样的「打开方式」，
        // 用户只能靠肉眼比对再删一条。这里直接忽略重复项。
        let newPath = item.url.standardizedFileURL.path
        guard !apps.contains(where: { $0.url.standardizedFileURL.path == newPath }) else {
            logger.info("add app skipped: \(newPath) 已在列表中")
            return
        }
        apps.append(item)
        
        do {
            try save()
            // 使用 result
        } catch {
            // 处理错误
            logger.info("save error: \(error.localizedDescription)")
        }
    }
    
    /// 更新应用配置。未传入的字段保持原值（传 nil 表示“不修改”），
    /// 避免编辑名称时顺带把 arguments/environment 覆盖成空。
    @MainActor
    func updateApp(
        id: String,
        itemName: String,
        arguments: [String]? = nil,
        environment: [String: String]? = nil,
        url: URL? = nil,
        icon: String? = nil,
        replaceIcon: Bool = false
    ) {
        if let index = apps.firstIndex(where: { $0.id == id }) {
            var updatedApp = apps[index]
            updatedApp.itemName = itemName
            if let arguments { updatedApp.arguments = arguments }
            if let environment { updatedApp.environment = environment }
            if let url { updatedApp.url = url }
            if replaceIcon { updatedApp.icon = icon }
            apps[index] = updatedApp
            try? save()
        }
    }
    
    func getAppItem(rid: String) -> OpenWithApp? {
        // 先按 id 精确匹配（固定 id 如 com.apple.Terminal）
        if let app = apps.first(where: { rid == $0.id }) { return app }
        // 再按 URL 路径匹配：rid 包含 app 名称
        return apps.first { rid.localizedCaseInsensitiveContains($0.url.deletingPathExtension().lastPathComponent) }
    }
    
    func getFileType(rid: String) -> NewFile? {
        return newFiles.first(where: { nf in
            rid == nf.id
        })
    }
    
    @MainActor func addNewFile(_ item: NewFile) {
        logger.info("start add new file type")
        newFiles.append(item)
        
        do {
            try save()
            // 使用 result
        } catch {
            // 处理错误
            logger.info("save error: \(error.localizedDescription)")
        }
    }
    
    func getActionItem(rid: String) -> RCAction? {
        actions.first(where: { rcAtion in
            rcAtion.id == rid
        })
    }
    
    // Action
    @MainActor func toggleActionItem() {
        try? save()
    }

    @MainActor func resetActionItems() {
        actions = RCAction.defaultActions
        try? save()
    }

    /// 重置右键菜单所有设置（操作项、子菜单顺序、子菜单开关）
    @MainActor func resetMenuItems() {
        actions = RCAction.defaultActions
        submenuOrder = Self.defaultSubmenuOrder
        showNewFiles = true
        showCommonDirs = true
        // 漏掉这个开关时，用户关掉「常用 App」子菜单后点「重置」，
        // 其余菜单项都恢复了，只有它还是关的。默认值见 showApps getter。
        showApps = true
        // 原来这里还有个 try? save() 紧跟着 sync()，一次重置要整份配置写两遍
        sync()
    }
    
    @MainActor func resetFiletypeItems() {
        newFiles = NewFile.all
        try? save()
    }
    
    // Permission
    @MainActor func deletePermissiveDir(index: Int) {
        dirs.remove(at: index)

        try? save()
    }

    @MainActor func hasParentBookmark(of url: URL) -> Bool {
        let path = normalizePath(url.path)
        return dirs.contains { existingDir in
            let existingPath = normalizePath(existingDir.url.path)
            // 已有目录是新目录的父路径（且不是同一个路径）
            return isStrictlyInside(path, existingPath)
        }
    }

    /// 检查新目录是否是已有目录的父路径，如果是则移除子目录
    @MainActor func removeChildDirs(of url: URL) {
        let newPath = normalizePath(url.path)
        dirs.removeAll { existingDir in
            let existingPath = normalizePath(existingDir.url.path)
            // 新目录是已有目录的父路径（且不是同一个路径）
            return isStrictlyInside(existingPath, newPath)
        }
    }

    /// path 是否严格位于 dir 之内（带分隔符边界，且不含 dir 自身）。
    /// 原实现是裸 `path.hasPrefix(dir)`："/Users/a/bc" 会被判成 "/Users/a/b" 的子项。
    /// 写法与 IClickApp.swift 里同一判断保持一致，避免两处日后漂移。
    private func isStrictlyInside(_ path: String, _ dir: String) -> Bool {
        path != dir && path.hasPrefix(dir + "/")
    }

    /// 标准化路径（移除末尾斜杠）
    private func normalizePath(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }
    
    /// 注意：原先这里把每个数组都包成 `OrderedSet` 再编码，但
    /// `OrderedSet.encode(to:)` 走的是 singleValueContainer，写出的是和 `Array`
    /// **逐字节相同**的 plist 数组（二进制/XML 均已实测），包一层纯属浪费：
    /// 每次保存都要多建一个 Set、多算一遍哈希。直接用数组编码。
    @MainActor
    private func save() throws {
        let encoder = PropertyListEncoder()
        // 解码失败过的段一律不写：内存里是默认值，写回去等于覆盖磁盘数据。
        // 这是「用户随后任意点一下设置」就永久丢数据的最后一层保护。
        //
        // 5 个段合并成一次读-改-写：逐个 set 会做 5 次整份配置读取 + 10 次
        // 原子写（共享 plist 与快照各一份），改一个开关就有几十次文件 I/O。
        var values: [String: Any?] = [:]
        if !failedKeys.contains(Key.apps) {
            values[Key.apps] = try encoder.encode(apps)
        }
        if !failedKeys.contains(Key.actions) {
            values[Key.actions] = try encoder.encode(actions)
        }
        if !failedKeys.contains(Key.fileTypes) {
            values[Key.fileTypes] = try encoder.encode(newFiles)
        }
        if !failedKeys.contains(Key.permDirs) {
            values[Key.permDirs] = try encoder.encode(dirs)
        }
        if !failedKeys.contains(Key.commonDirs) {
            values[Key.commonDirs] = try encoder.encode(cdirs)
        }
        // 一次落盘（内部已同步写共享 plist 与快照），扩展立刻能读到
        SharedSettings.setMany(values)
        // 仅主应用发送通知，扩展自身不需要通知自己
        if !inExt {
            notifyConfigChanged()
        }
    }

    @MainActor
    func savePermissiveDir() throws {
        guard !failedKeys.contains(Key.permDirs) else {
            logger.warning("permDirs 解码失败过，跳过保存以免覆盖磁盘上的原始数据")
            return
        }
        let encoder = PropertyListEncoder()
        let permDirsData = try encoder.encode(dirs)
        SharedSettings.set(permDirsData, forKey: Key.permDirs)
        SharedSettings.synchronize()
        if !inExt {
            notifyConfigChanged()
        }
    }

    //  保存常用路径
    @MainActor
    func saveCommonDir() throws {
        guard !failedKeys.contains(Key.commonDirs) else {
            logger.warning("commonDirs 解码失败过，跳过保存以免覆盖磁盘上的原始数据")
            return
        }
        let encoder = PropertyListEncoder()
        let commonDirsData = try encoder.encode(cdirs)
        SharedSettings.set(commonDirsData, forKey: Key.commonDirs)
        // 立即同步到磁盘，确保扩展进程能读取
        SharedSettings.synchronize()
        logger.info("save common dirs success")
        if !inExt {
            notifyConfigChanged()
        }
    }
    
    @MainActor func refresh() {
        load()
    }

    /// 待推送的配置任务，用于把短时间内的多次变更合并成一次推送
    private var pendingVersionBump: Task<Void, Never>?

    /// 配置变更后递增快照版本号。
    ///
    /// 扩展不再通过 DNC 接收配置，而是在每次建菜单前比较快照里的
    /// `configVersion`（见 FinderSyncExt.syncFromSnapshotIfNewer）。所以这里
    /// 只要把版本号写进共享 plist，扩展下一次右键就会自动重新加载。
    ///
    /// 一次「重置右键菜单」会连着触发约 6 次 setter/save；80ms 窗口内合并，
    /// 只递增一次版本、只写一次文件。
    @MainActor private func notifyConfigChanged() {
        guard !inExt else { return }

        pendingVersionBump?.cancel()
        pendingVersionBump = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingVersionBump = nil
            let next = SharedSettings.incrementInteger(forKey: Key.configVersion)
            DiagnosticLog.shared.write("config version bumped to \(next)")
        }
    }

    /// 退出前把防抖中的版本号立刻落盘。
    ///
    /// 数据在 setter/save 里已经写进 plist，版本号却要等 80ms 防抖；用户改完设置
    /// 立刻退出（或注销）时，这个 Task 会随进程一起消失，扩展就永远认为配置没变，
    /// 直到下一次修改才恢复。正常退出路径上补一次即可。
    @MainActor func flushPendingConfigChange() {
        guard !inExt, pendingVersionBump != nil else { return }
        pendingVersionBump?.cancel()
        pendingVersionBump = nil
        let next = SharedSettings.incrementInteger(forKey: Key.configVersion)
        DiagnosticLog.shared.write("config version flushed to \(next)")
    }

    @MainActor func sync() {
        _ = try? save()
    }
    
    @MainActor
    private func load() {
        let decoder = PropertyListDecoder()
        // 一次读出整份配置，避免每一段都触发一次 plist 解析。
        // 扩展侧未收到主应用推送时，原先 5 段 = 5 次磁盘读取 + 解析。
        let settings = SharedSettings.load()

        // 子菜单顺序也必须跟着快照刷新。原来只在 init 里读一次：用户在设置里
        // 调整顺序或点「重置」后，扩展进程不重启就永远用旧顺序（版本号变了、
        // 菜单结构缓存也清了，唯独这个数组还是旧的）。
        // 只给扩展读：主应用是唯一写者，内存里的值就是最新的；重新赋值反而会
        // 触发 didSet 把同一个值再写一遍。
        if inExt,
           let savedOrder = settings["submenuOrder"] as? [String],
           savedOrder != submenuOrder {
            suppressSubmenuOrderPersist = true
            submenuOrder = savedOrder
            suppressSubmenuOrderPersist = false
        }
        // 有任意一段解码失败就置位：本次加载不做「首次落盘」，
        // 避免用内存里的默认值覆盖磁盘上可能只是暂时读不出来的用户数据
        var skipInitialSave = false
        // 记录失败段：save() 会跳过这些键，直到下一次成功 load。
        failedKeys.removeAll()

        // 注意：下面每一段都用 try? 单独解码。
        // 之前是整函数 throws，任意一段解码失败都会中断后面的加载，
        // 留下一半新一半旧的中间状态（并且失败段保持默认值）。
        if !inExt {
            if let permDirsData = settings[Key.permDirs] as? Data {
                if let decoded = try? decoder.decode([PermissiveDir].self, from: permDirsData) {
                    dirs = decoded
                    failedKeys.remove(Key.permDirs)
                    logger.info("load permDir success")
                } else {
                    logger.error("permDirs 解码失败，保留原值")
                    DiagnosticLog.shared.write("load permDirs failed")
                    failedKeys.insert(Key.permDirs)
                    skipInitialSave = true
                }
            } else {
                dirs = []
                failedKeys.remove(Key.permDirs)
            }
        }

        if let commonDirsData = settings[Key.commonDirs] as? Data {
            if let dirs = try? decoder.decode([CommonDir].self, from: commonDirsData) {
                cdirs = dirs
                failedKeys.remove(Key.commonDirs)
                logger.info("load common dirs success")
            } else {
                // 空的「兼容旧版 OrderedSet 格式」分支已删除：OrderedSet 与 Array 的
                // plist 编码逐字节相同（已实测），凡是 OrderedSet 能解码的字节
                // [CommonDir] 必然也能解码，所以那个分支永远不可达。
                //
                // 失败时必须置位：这是本函数里唯一漏掉 skipInitialSave 的一段。
                // 一旦同时满足「fileTypes 键缺失」（needsInitialSave 为真），
                // 函数末尾的首次落盘就会把空数组写回磁盘，直接抹掉用户的常用目录。
                logger.error("commonDirs 解码失败，保留原值且不写回")
                DiagnosticLog.shared.write("load commonDirs failed")
                failedKeys.insert(Key.commonDirs)
                skipInitialSave = true
            }
        } else {
            cdirs = []
            failedKeys.remove(Key.commonDirs)
        }

        if let actionData = settings[Key.actions] as? Data {
            if let decodedActions = try? decoder.decode([RCAction].self, from: actionData) {
                actions = decodedActions
                    // 过滤掉已移除的操作（如旧版的 screenshot-annotate）
                    .filter { action in RCAction.all.contains(where: { $0.id == action.id }) }
                // 图标迁移：仅在用户未自定义过（仍使用旧默认图标）时更新。
                //
                // 注意不要再把 requireSelection 覆盖成默认值：设置页的
                // 「仅选中文件」是可编辑项，每次加载都覆盖等于编辑永远不生效
                // （界面里改了、下次启动就退回默认）。默认值自 init 起没有变过，
                // 因此也不需要为老配置做一次性的纠正迁移。
                for (idx, action) in actions.enumerated() {
                    if let defaultAction = RCAction.all.first(where: { $0.id == action.id }) {
                        // 同步图标——仅在用户未自定义过（仍使用旧默认图标）时更新
                        if defaultAction.icon == "paperplane.fill" && action.icon == "airplane" {
                            actions[idx].icon = defaultAction.icon
                        }
                        // 迁移眼睛图标到月亮/太阳图标（SF Symbol 在菜单中比例失真）
                        if action.id == "hide" && action.icon == "eye.slash" {
                            actions[idx].icon = "moon.fill"
                        }
                        if action.id == "unhide" && action.icon == "eye" {
                            actions[idx].icon = "sun.max.fill"
                        }
                    }
                }
                failedKeys.remove(Key.actions)
                logger.info("load actions success")
            } else {
                logger.error("actions 解码失败，保留原值")
                DiagnosticLog.shared.write("load actions failed")
                failedKeys.insert(Key.actions)
                skipInitialSave = true
            }
        } else {
            actions = RCAction.defaultActions
            failedKeys.remove(Key.actions)
        }

        var needsInitialSave = false
        if let filetypeItemData = settings[Key.fileTypes] as? Data {
            if let decodedFiles = try? decoder.decode([NewFile].self, from: filetypeItemData) {
                newFiles = decodedFiles
                failedKeys.remove(Key.fileTypes)
                logger.info("load filetype success")
            } else {
                logger.error("fileTypes 解码失败，保留原值")
                DiagnosticLog.shared.write("load fileTypes failed")
                failedKeys.insert(Key.fileTypes)
                skipInitialSave = true
            }
        } else {
            newFiles = NewFile.all
            failedKeys.remove(Key.fileTypes)
            // 首次加载：延迟到全部字段载入后再落盘。
            // 否则 save() 会把此刻尚未赋值的 apps（空数组）写回，把用户的常用 App 清空。
            needsInitialSave = !inExt
        }

        if let appItemData = settings[Key.apps] as? Data {
            if let decodedApps = try? decoder.decode([OpenWithApp].self, from: appItemData) {
                apps = decodedApps
                failedKeys.remove(Key.apps)
                logger.info("load apps success, count=\(decodedApps.count)")
            } else {
                // 关键：解码失败时不能退回默认列表并落盘，那会把用户数据直接抹掉
                logger.error("apps 解码失败，保留原值且不写回")
                DiagnosticLog.shared.write("load apps failed")
                failedKeys.insert(Key.apps)
                skipInitialSave = true
            }
        } else {
            let fallback = OpenWithApp.defaultApps
            apps = fallback
            failedKeys.remove(Key.apps)
            logger.info("no saved apps, using defaults: \(fallback.map { $0.name })")
        }

        // 首次加载时保存默认数据到共享 suite，确保扩展和主应用使用相同的 ID。
        // 注意要放在 apps 载入之后：提前落盘会把还没赋值的 apps 写成空数组。
        if needsInitialSave && !skipInitialSave {
            try? save()
        }
    }
}
