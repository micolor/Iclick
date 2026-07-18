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
    static let protectedDirs = [
        HomedirPath + "/Desktop/",
        HomedirPath + "/Desktop/danger/",
        HomedirPath + "/Applications/",
        "/Applications/",
        "/System/",
        "/Library/",
        "/Users/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/var/"
    ]
    static let suitName = "group.33WRMMC62L.cn.anwen.IClick"

    /// 检测是否拥有完全磁盘访问权限
    static var hasFullDiskAccess: Bool {
        // 尝试访问系统保护目录，如果可以读取则说明有完全磁盘访问权限
        let testPath = "/Library/Preferences"
        return FileManager.default.isReadableFile(atPath: testPath)
    }
}
