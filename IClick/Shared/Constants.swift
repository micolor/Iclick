//
//  Constants.swift
//  IClick
//
//  Created by 李旭 on 2024/9/25.
//

import Foundation


public enum Constants {
    static let HomedirPath = Utils.getRealHomeDir()
    /// The identifier for the settings window.
    static let settingsWindowID = "iclick-settings"

    /// Get the app version string.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }
    /// 系统目录：不属于用户，破坏性或批量操作都不该落在它们头上。
    static let systemDirs = [
        "/Applications/",
        "/System/",
        "/Library/",
        "/Users/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/var/"
    ]

    /// 受保护目录 = 需要保护的用户目录 + 全部系统目录。
    /// 用户目录单独列出来是因为「删除」这类操作落在 ~/Desktop 上同样危险；
    /// 但「隐藏该目录下全部子项」不是 —— 那个只在系统目录上才只可能是误操作，
    /// 所以后者用的是更窄的 systemDirs（见 Utils.isSystemFolder）。
    /// 写成拼接而非手抄两份，是为了结构上保证 systemDirs 恒为 protectedDirs 的子集。
    static let protectedDirs = [
        HomedirPath + "/Desktop/",
        HomedirPath + "/Desktop/danger/",
        HomedirPath + "/Applications/"
    ] + systemDirs
    static let suitName = "group.33WRMMC62L.cn.anwen.IClick"

    /// 检测是否拥有完全磁盘访问权限
    static var hasFullDiskAccess: Bool {
        // 尝试访问系统保护目录，如果可以读取则说明有完全磁盘访问权限
        let testPath = "/Library/Preferences"
        return FileManager.default.isReadableFile(atPath: testPath)
    }
}
