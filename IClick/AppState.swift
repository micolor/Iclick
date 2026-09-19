//
//  File.swift
//  IClick
//
//  Created by 李旭 on 2024/9/26.
//

import Combine
import Foundation
import SwiftUI

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

    var showCommonDirs: Bool {
        get { SharedSettings.bool(forKey: "showCommonDirs") }
        set { SharedSettings.set(newValue, forKey: "showCommonDirs"); SharedSettings.synchronize(); notifyConfigChanged() }
    }
    var showNewFiles: Bool {
        get { SharedSettings.bool(forKey: "showNewFiles") }
        set { SharedSettings.set(newValue, forKey: "showNewFiles"); SharedSettings.synchronize(); notifyConfigChanged() }
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
            SharedSettings.set(submenuOrder, forKey: "submenuOrder")
            SharedSettings.synchronize()
            // 必须通知扩展：否则右键菜单顺序仍是旧的，直到下次其它配置变更才刷新
            notifyConfigChanged()
        }
    }

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
        // 加载子菜单排序
        if let saved = SharedSettings.array(forKey: "submenuOrder") as? [String] {
            submenuOrder = saved
        } else {
            submenuOrder = Self.defaultSubmenuOrder
        }
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
    /// 注意：必须一次性 remove，逐个删会因为索引位移删错项。
    @MainActor func deleteApps(at offsets: IndexSet) {
        apps.remove(atOffsets: offsets)
        do {
            try save()
        } catch {
            logger.info("save error: \(error.localizedDescription)")
        }
    }

    @MainActor func addApp(item: OpenWithApp) {
        logger.info("start add app")
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
        try? save()
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
            return existingPath != path && path.hasPrefix(existingPath)
        }
    }

    /// 检查新目录是否是已有目录的父路径，如果是则移除子目录
    @MainActor func removeChildDirs(of url: URL) {
        let newPath = normalizePath(url.path)
        dirs.removeAll { existingDir in
            let existingPath = normalizePath(existingDir.url.path)
            // 新目录是已有目录的父路径（且不是同一个路径）
            return existingPath != newPath && existingPath.hasPrefix(newPath)
        }
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
        let appItemsData = try encoder.encode(apps)
        let actionItemsData = try encoder.encode(actions)
        let filetypeItemsData = try encoder.encode(newFiles)
        let permDirsData = try encoder.encode(dirs)
        let commonDirsData = try encoder.encode(cdirs)
        SharedSettings.set(appItemsData, forKey: Key.apps)
        SharedSettings.set(actionItemsData, forKey: Key.actions)
        SharedSettings.set(filetypeItemsData, forKey: Key.fileTypes)
        SharedSettings.set(permDirsData, forKey: Key.permDirs)
        SharedSettings.set(commonDirsData, forKey: Key.commonDirs)
        // 立即同步到磁盘，确保扩展进程能立即读取
        SharedSettings.synchronize()
        // 仅主应用发送通知，扩展自身不需要通知自己
        if !inExt {
            notifyConfigChanged()
        }
    }

    @MainActor
    func savePermissiveDir() throws {
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
    private var pendingConfigPush: Task<Void, Never>?

    /// 通知扩展配置已变更。
    ///
    /// 做了两件事：
    /// 1. **合并**。一次「重置右键菜单」会连着触发约 6 次（三个 setter / didSet 加上
    ///    save()），每次都做全量导出 + 所有 Data 转 base64 + JSON + DNC 广播。
    ///    80ms 窗口内的多次调用只保留最后一次。
    /// 2. **不推给自己**。原来没有 inExt 判断，扩展在 `AppState.init` 里给
    ///    submenuOrder 赋默认值就会触发 didSet → 发出一条 "running"，
    ///    而扩展自己正监听着 "running" —— 于是它把自己的 isHostAppOpen 置为 true，
    ///    主应用没运行也以为在运行，存活检测被架空。
    @MainActor private func notifyConfigChanged() {
        guard !inExt else { return }

        pendingConfigPush?.cancel()
        pendingConfigPush = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pushConfigToExtension()
        }
    }

    /// 立即推送完整配置（合并窗口结束时执行一次）
    @MainActor private func pushConfigToExtension() {
        pendingConfigPush = nil

        let currentVersion = SharedSettings.integer(forKey: Key.configVersion)
        SharedSettings.set(currentVersion + 1, forKey: Key.configVersion)

        // 直接推送完整配置给扩展，不依赖 DNC 通知 + heartbeat 往返
        let allConfig = SharedSettings.exportAllForIPC()
        let configJSON: String? = (try? JSONSerialization.data(withJSONObject: allConfig, options: .fragmentsAllowed))
            .flatMap { String(data: $0, encoding: .utf8) }
        Messager.shared.sendMessage(
            name: "running",
            data: MessagePayload(action: "running", target: ["/"], configJSON: configJSON)
        )
    }
    
    @MainActor func sync() {
        _ = try? save()
    }
    
    @MainActor
    private func load() {
        let decoder = PropertyListDecoder()
        // 有任意一段解码失败就置位：本次加载不做「首次落盘」，
        // 避免用内存里的默认值覆盖磁盘上可能只是暂时读不出来的用户数据
        var skipInitialSave = false

        // 注意：下面每一段都用 try? 单独解码。
        // 之前是整函数 throws，任意一段解码失败都会中断后面的加载，
        // 留下一半新一半旧的中间状态（并且失败段保持默认值）。
        if !inExt {
            if let permDirsData = SharedSettings.data(forKey: Key.permDirs) {
                if let decoded = try? decoder.decode([PermissiveDir].self, from: permDirsData) {
                    dirs = decoded
                    logger.info("load permDir success")
                } else {
                    logger.error("permDirs 解码失败，保留原值")
                    skipInitialSave = true
                }
            } else {
                dirs = []
            }
        }

        if let commonDirsData = SharedSettings.data(forKey: Key.commonDirs) {
            if let dirs = try? decoder.decode([CommonDir].self, from: commonDirsData) {
                cdirs = dirs
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
                skipInitialSave = true
            }
        } else {
            cdirs = []
        }

        if let actionData = SharedSettings.data(forKey: Key.actions) {
            if let decodedActions = try? decoder.decode([RCAction].self, from: actionData) {
                actions = decodedActions
                    // 过滤掉已移除的操作（如旧版的 screenshot-annotate）
                    .filter { action in RCAction.all.contains(where: { $0.id == action.id }) }
                // 确保预定义操作的属性与默认值一致
                for (idx, action) in actions.enumerated() {
                    if let defaultAction = RCAction.all.first(where: { $0.id == action.id }) {
                        actions[idx].requireSelection = defaultAction.requireSelection
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
                logger.info("load actions success")
            } else {
                logger.error("actions 解码失败，保留原值")
                skipInitialSave = true
            }
        } else {
            actions = RCAction.defaultActions
        }

        var needsInitialSave = false
        if let filetypeItemData = SharedSettings.data(forKey: Key.fileTypes) {
            if let decodedFiles = try? decoder.decode([NewFile].self, from: filetypeItemData) {
                newFiles = decodedFiles
                logger.info("load filetype success")
            } else {
                logger.error("fileTypes 解码失败，保留原值")
                skipInitialSave = true
            }
        } else {
            newFiles = NewFile.all
            // 首次加载：延迟到全部字段载入后再落盘。
            // 否则 save() 会把此刻尚未赋值的 apps（空数组）写回，把用户的常用 App 清空。
            needsInitialSave = !inExt
        }

        if let appItemData = SharedSettings.data(forKey: Key.apps) {
            if let decodedApps = try? decoder.decode([OpenWithApp].self, from: appItemData) {
                apps = decodedApps
                logger.info("load apps success, count=\(decodedApps.count)")
            } else {
                // 关键：解码失败时不能退回默认列表并落盘，那会把用户数据直接抹掉
                logger.error("apps 解码失败，保留原值且不写回")
                skipInitialSave = true
            }
        } else {
            let fallback = OpenWithApp.defaultApps
            apps = fallback
            logger.info("no saved apps, using defaults: \(fallback.map { $0.name })")
        }

        // 首次加载时保存默认数据到共享 suite，确保扩展和主应用使用相同的 ID。
        // 注意要放在 apps 载入之后：提前落盘会把还没赋值的 apps 写成空数组。
        if needsInitialSave && !skipInitialSave {
            try? save()
        }
    }
}
