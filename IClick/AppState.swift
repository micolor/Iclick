//
//  File.swift
//  IClick
//
//  Created by 李旭 on 2024/9/26.
//

import Combine
import Foundation
import OrderedCollections
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

    @AppStorage("showCommonDirs", store: .group) var showCommonDirs: Bool = true
    @AppStorage("showNewFiles", store: .group) var showNewFiles: Bool = true
    @AppStorage("fullDiskAccess") var fullDiskAccess: Bool = true

    /// 子菜单项的排序顺序（ID 数组）
    @Published var submenuOrder: [String] = [] {
        didSet {
            UserDefaults.group.set(submenuOrder, forKey: "submenuOrder")
        }
    }

    /// 默认子菜单顺序
    static let defaultSubmenuOrder = ["submenuApps", "newFiles", "commonDirs"]

    init(inExt: Bool = false) {
        self.inExt = inExt
        // 加载子菜单排序
        if let saved = UserDefaults.group.array(forKey: "submenuOrder") as? [String] {
            submenuOrder = saved
        } else {
            submenuOrder = Self.defaultSubmenuOrder
        }
        // 扩展中同步加载，避免首次右键时数据为空
        if inExt {
            try? load()
        } else {
            Task {
                await MainActor.run {
                    logger.info("start load")
                    try? load()
                }
            }
        }
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
    
    @MainActor
    func updateApp(id: String, itemName: String, arguments: [String], environment: [String: String]) {
        if let index = apps.firstIndex(where: { $0.id == id }) {
            var updatedApp = apps[index]
            updatedApp.itemName = itemName
            updatedApp.arguments = arguments
            updatedApp.environment = environment
            apps[index] = updatedApp
            try? save()
        }
    }
    
    func getAppItem(rid: String) -> OpenWithApp? {
        return apps.first { rid.contains($0.id) }
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
    
    @MainActor
    private func save() throws {
        let encoder = PropertyListEncoder()
        let appItemsData = try encoder.encode(OrderedSet(apps))
        let actionItemsData = try encoder.encode(OrderedSet(actions))
        let filetypeItemsData = try encoder.encode(OrderedSet(newFiles))
        let permDirsData = try encoder.encode(OrderedSet(dirs))
        let commonDirsData = try encoder.encode(cdirs)
        UserDefaults.group.set(appItemsData, forKey: Key.apps)
        UserDefaults.group.set(actionItemsData, forKey: Key.actions)
        UserDefaults.group.set(filetypeItemsData, forKey: Key.fileTypes)
        UserDefaults.group.set(permDirsData, forKey: Key.permDirs)
        UserDefaults.group.set(commonDirsData, forKey: Key.commonDirs)
        // 立即同步到磁盘，确保扩展进程能立即读取
        UserDefaults.group.synchronize()
        // 仅主应用发送通知，扩展自身不需要通知自己
        if !inExt {
            notifyConfigChanged()
        }
    }

    @MainActor
    func savePermissiveDir() throws {
        let encoder = PropertyListEncoder()
        let permDirsData = try encoder.encode(OrderedSet(dirs))
        UserDefaults.group.set(permDirsData, forKey: Key.permDirs)
        UserDefaults.group.synchronize()
        if !inExt {
            notifyConfigChanged()
        }
    }

    //  保存常用路径
    @MainActor
    func saveCommonDir() throws {
        let encoder = PropertyListEncoder()
        let commonDirsData = try encoder.encode(cdirs)
        UserDefaults.group.set(commonDirsData, forKey: Key.commonDirs)
        // 立即同步到磁盘，确保扩展进程能读取
        UserDefaults.group.synchronize()
        logger.info("save common dirs success")
        if !inExt {
            notifyConfigChanged()
        }
    }
    
    @MainActor func refresh() {
        _ = try? load()
    }

    /// 通知扩展配置已变更
    @MainActor private func notifyConfigChanged() {
        // 递增版本号，扩展可通过 UserDefaults 检测
        let currentVersion = UserDefaults.group.integer(forKey: Key.configVersion)
        UserDefaults.group.set(currentVersion + 1, forKey: Key.configVersion)
        // 发送分布式通知，扩展收到后立即失效菜单缓存
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(Key.configChangedNotification),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
    
    @MainActor func sync() {
        _ = try? save()
    }
    
    @MainActor
    private func load() throws {
        let decoder = PropertyListDecoder()

        if !inExt {
            if let permDirsData = UserDefaults.group.data(forKey: Key.permDirs) {
                dirs = try decoder.decode([PermissiveDir].self, from: permDirsData)
                logger.info("load permDir success")
            } else {
                dirs = []
            }
        }

        if let commonDirsData = UserDefaults.group.data(forKey: Key.commonDirs) {
            if let dirs = try? decoder.decode([CommonDir].self, from: commonDirsData) {
                cdirs = dirs
            } else if let dirs = try? decoder.decode(OrderedSet<CommonDir>.self, from: commonDirsData) {
                // 兼容旧版 OrderedSet 编码格式
                cdirs = Array(dirs)
                // 迁到新格式
                if !inExt { try? saveCommonDir() }
                logger.info("load common dirs (migrated from OrderedSet)")
            } else {
                cdirs = []
            }
            logger.info("load common dirs success")
        } else {
            cdirs = []
        }

        if let actionData = UserDefaults.group.data(forKey: Key.actions) {
            actions = try decoder.decode([RCAction].self, from: actionData)
            // 过滤掉已移除的操作（如旧版的 screenshot-annotate）
            actions = actions.filter { action in
                RCAction.all.contains(where: { $0.id == action.id })
            }
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
            actions = RCAction.defaultActions
        }

        if let filetypeItemData = UserDefaults.group.data(forKey: Key.fileTypes) {
            newFiles = try decoder.decode([NewFile].self, from: filetypeItemData)
            logger.info("load filetype success")
        } else {
            newFiles = NewFile.all
            // 首次加载时保存默认数据到 UserDefaults，确保扩展和主应用使用相同的 ID
            if !inExt {
                try? save()
            }
        }

        if let appItemData = UserDefaults.group.data(forKey: Key.apps) {
            apps = try decoder.decode([OpenWithApp].self, from: appItemData)
            logger.info("load apps success")
        } else {
            apps = OpenWithApp.defaultApps
        }
    }
}
