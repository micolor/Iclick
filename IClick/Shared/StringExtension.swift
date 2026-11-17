//
//  StringExtension.swift
//  IClick
//
//  Created by 李旭 on 2024/4/5.
//

import Foundation

import os.log

let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
var subsystem: String { bundleIdentifier }

private let logger = Logger(subsystem: subsystem, category: "user_defaults")

enum Key {
    static let apps = "ICLICK_APPs"
    static let actions = "ICLICK_ACTIONS"
    static let fileTypes = "ICLICK_FILE_TYPES"
    static let permDirs = "ICLICK_PERMISSIVE_DIRS"
    static let commonDirs = "ICLICK_COMMON_DIRS"
    static let showMenuBarExtra = "showMenuBarExtra"
    static let showInDock = "SHOW_IN_DOCK"

    // 配置版本号，用于扩展检测变更
    static let configVersion = "ICLICK_CONFIG_VERSION"
}

extension String {
    func toDictionary(separator: Character = " ") -> [String: String] {
        split(separator: separator)
            .map { $0.split(separator: "=") }
            .filter { $0.count == 2 }
            .reduce(into: [String: String]()) { result, pair in
                let key = String(pair[0])
                let value = String(pair[1])
                result[key] = value
            }
    }
}

extension Dictionary {
    func toString(separator: String = " ") -> String {
        compactMap { "\($0)=\($1)" }.joined(separator: separator)
    }
}

/// 跨进程共享设置管理器
/// - 主应用（非沙盒）：直接写真实文件，落盘时同步写一份 App Group 快照
/// - 扩展（沙盒）：只读群组容器里的快照，调 `receiveRemote` / `adoptSnapshotIfNeeded`
///   把它载入内存；扩展从不写文件
final class SharedSettings: @unchecked Sendable {
    /// 当前用户的真实 home。
    /// 沙盒进程里的 `NSHomeDirectory()` 是容器路径，不能用来拼真实的
    /// Application Support / Group Containers，所以统一走 `getpwuid`。
    static var realHomeURL: URL {
        let realHome: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            realHome = String(cString: dir)
        } else {
            realHome = NSHomeDirectory()
        }
        return URL(fileURLWithPath: realHome)
    }

    /// 共享 plist 文件路径（仅主应用写入）
    static let sharedURL: URL = {
        let dir = realHomeURL.appendingPathComponent("Library/Application Support/IClick")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SharedSettings.plist")
    }()

    /// 扩展可读的配置快照（App Group 容器）。
    ///
    /// 扩展是沙盒进程，读不到 Application Support；主应用每次落盘后同步写一份到
    /// 群组容器（扩展的 entitlements 里有该 group）。这样扩展启动时立刻就有最新
    /// 配置，不必等主应用的 DNC 推送——主应用没运行时，右键菜单也不会退化成默认项。
    static let snapshotURL: URL = {
        realHomeURL
            .appendingPathComponent("Library/Group Containers")
            .appendingPathComponent(Constants.suitName)
            .appendingPathComponent("SharedSettings-snapshot.plist")
    }()

    /// 扩展进程内的配置内存副本。来源是群组容器快照（`receiveRemote` / `adoptSnapshotIfNeeded`），
    /// 读取路径优先走它，避免每次读 key 都解析 plist。
    nonisolated(unsafe) static var remotePayload: [String: Any]?
    private static let lock = NSLock()

    /// 群组容器快照的内存缓存。扩展每读一个 key 都重新解析 plist 太浪费，
    /// 尤其是主应用没运行时（remotePayload 为空），右键构建菜单会连续读十几项。
    /// 用 mtime 判断是否失效：主应用原子写入后 mtime 会变，下一次读取自然会重新加载。
    nonisolated(unsafe) private static var snapshotCache: [String: Any]?
    nonisolated(unsafe) private static var snapshotStamp: Date?
    /// 主应用共享 plist 的内存缓存。设置页一屏会读很多次，每次都解析整份 plist 太浪费。
    /// 同样按 mtime 失效，旧副本或外部工具改写文件后仍能重新加载。
    nonisolated(unsafe) private static var sharedCache: [String: Any]?
    nonisolated(unsafe) private static var sharedStamp: Date?

    /// 是否为扩展进程（通过 bundle ID 判断）
    static var isExtension: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".FinderSyncExt") ?? false
    }

    /// 从存储加载所有数据
    static func load() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    /// 已持锁版本的 load()。NSLock 不可重入，凡是已经拿锁的路径都必须走这个。
    private static func loadLocked() -> [String: Any] {
        // 扩展优先使用内存里的快照副本（已由 syncFromSnapshotIfNewer 按版本刷新），
        // 其次直接读群组容器快照（主应用落盘时同步写）
        if isExtension, let remote = remotePayload {
            return remote
        }
        if isExtension, let dict = loadSnapshotLocked() {
            return dict
        }
        if let dict = loadSharedLocked() {
            return dict
        }
        return [:]
    }

    /// 扩展启动时先把快照当作远程配置。
    ///
    /// 这样后续 `AppState.load()`、菜单里的 submenu_name/icon 读取都走内存，
    /// 不再每读一个 key 就解析一遍 5KB plist。主应用稍后推来的配置会覆盖它。
    static func adoptSnapshotIfNeeded() {
        guard isExtension else { return }
        lock.lock()
        defer { lock.unlock() }
        guard remotePayload == nil, let dict = loadSnapshotLocked() else { return }
        remotePayload = dict
    }

    /// 读取快照（按 mtime 缓存），供扩展在每次建菜单前比较配置版本。
    static func snapshotDictionary() -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return loadSnapshotLocked()
    }

    /// 必须已持锁调用。
    private static func loadSnapshotLocked() -> [String: Any]? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        let stamp = attrs?[.modificationDate] as? Date
        if let cached = snapshotCache, let stamp, stamp == snapshotStamp {
            return cached
        }
        guard let dict = NSDictionary(contentsOf: snapshotURL) as? [String: Any] else {
            snapshotCache = nil
            snapshotStamp = nil
            return nil
        }
        snapshotCache = dict
        snapshotStamp = stamp
        return dict
    }

    /// 必须已持锁调用。主应用共享 plist 的 mtime 缓存。
    private static func loadSharedLocked() -> [String: Any]? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: sharedURL.path)
        let stamp = attrs?[.modificationDate] as? Date
        if let cached = sharedCache, let stamp, stamp == sharedStamp {
            return cached
        }
        guard let dict = NSDictionary(contentsOf: sharedURL) as? [String: Any] else {
            sharedCache = nil
            sharedStamp = nil
            return nil
        }
        sharedCache = dict
        sharedStamp = stamp
        return dict
    }

    /// 保存（仅主应用写入文件）
    static func save(_ dict: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        saveLocked(dict)
    }

    /// 已持锁版本的 save()
    private static func saveLocked(_ dict: [String: Any]) {
        // 扩展是只读消费者：绝不写共享 plist，避免用旧 remotePayload 快照整文件回写
        // 覆盖主应用的配置（会导致 _migrated_to_shared_suite 标志丢失 → 迁移重跑 → 配置被旧值顶掉）
        if isExtension { return }

        let wroteShared = (dict as NSDictionary).write(to: sharedURL, atomically: true)
        if wroteShared {
            // 写入成功后直接更新内存缓存，省掉下一次读取的磁盘解析。
            sharedCache = dict
            let attrs = try? FileManager.default.attributesOfItem(atPath: sharedURL.path)
            sharedStamp = attrs?[.modificationDate] as? Date
        } else {
            logger.warning("写入共享配置失败: \(sharedURL.path, privacy: .public)")
            sharedCache = nil
            sharedStamp = nil
        }

        // 同步写一份扩展能读的群组容器快照。扩展启动时用它初始化菜单，
        // 不再依赖「主应用已经运行并推送过配置」。
        let snapshotDir = snapshotURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        if !(dict as NSDictionary).write(to: snapshotURL, atomically: true) {
            logger.warning("写入扩展配置快照失败: \(snapshotURL.path, privacy: .public)")
        }
    }

    /// 载入快照配置（扩展使用），将 base64 字符串还原为 Data
    static func receiveRemote(_ dict: [String: Any]) {
        // 将以 "_b64:" 前缀的字符串还原为 Data
        var converted: [String: Any] = [:]
        for (key, value) in dict {
            if let str = value as? String, str.hasPrefix("_b64:"),
               let data = Data(base64Encoded: String(str.dropFirst(5))) {
                converted[key] = data
            } else {
                converted[key] = value
            }
        }
        lock.lock()
        remotePayload = converted
        lock.unlock()
    }

    /// 导出现有数据为字典
    static func exportAll() -> [String: Any] {
        return load()
    }

    static func object(forKey key: String) -> Any? {
        return load()[key]
    }

    static func set(_ value: Any?, forKey key: String) {
        // 扩展只读：直接忽略写操作，不触发 load()+save() 的整文件回写
        if isExtension { return }
        // 整个「读-改-写」必须在同一把锁内完成。
        // 之前是 load() 和 save() 各自加锁，两步之间别的写入会被这次的旧快照覆盖掉。
        lock.lock()
        defer { lock.unlock() }
        var dict = loadLocked()
        if let value {
            dict[key] = value
        } else {
            dict.removeValue(forKey: key)
        }
        saveLocked(dict)
    }

    static func data(forKey key: String) -> Data? {
        return object(forKey: key) as? Data
    }

    static func string(forKey key: String) -> String? {
        return object(forKey: key) as? String
    }

    static func integer(forKey key: String) -> Int {
        return object(forKey: key) as? Int ?? 0
    }

    static func array(forKey key: String) -> [Any]? {
        return object(forKey: key) as? [Any]
    }

    static func bool(forKey key: String) -> Bool {
        return object(forKey: key) as? Bool ?? false
    }

    static func stringArray(forKey key: String) -> [String]? {
        return object(forKey: key) as? [String]
    }

    static func removeObject(forKey key: String) {
        set(nil, forKey: key)
    }

    static func synchronize() {
        // 主应用不需要额外同步；扩展数据已存于 remotePayload
    }
}

extension UserDefaults {
    /// App Group suite。目前有两个用途：
    /// 1. `@AppStorage` 支撑的界面开关（showMenuBarExtra / extensionEnabled）—— 这是它们的历史存储位置，
    ///    不能改到 standard：两个 store 里的取值不同（showMenuBarExtra 在 group 是 1、standard 是 0），
    ///    换 store 会让菜单栏图标直接消失。
    /// 2. `AppState.migrateFromLegacyIfNeeded()` 的一次性迁移来源。
    /// 批量配置数据（apps/actions/dirs/...）已迁到 SharedSettings.plist，不走这里。
    /// 主应用非沙盒，`UserDefaults(suiteName:)` 无需 application-groups 权限即可读写。
    static var group: UserDefaults {
        UserDefaults(suiteName: Constants.suitName) ?? UserDefaults.standard
    }
}
