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
    static let messageFromFinder = "ICLICK_FINDER_Main"
    static let messageFromMain = "ICLICK_MAIN_FINDER"

    static let apps = "ICLICK_APPs"
    static let actions = "ICLICK_ACTIONS"
    static let fileTypes = "ICLICK_FILE_TYPES"
    static let permDirs = "ICLICK_PERMISSIVE_DIRS"
    static let commonDirs = "ICLICK_COMMON_DIRS"
    static let showMenuBarExtra = "showMenuBarExtra"
    static let showInDock = "SHOW_IN_DOCK"

    // 配置变更通知
    static let configChangedNotification = "ICLICK_CONFIG_CHANGED"
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

extension UserDefaults {
    static var group: UserDefaults {
        UserDefaults(suiteName: Constants.suitName) ?? UserDefaults.standard
    }
}
