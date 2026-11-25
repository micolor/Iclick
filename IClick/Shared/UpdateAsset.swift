//
//  UpdateAsset.swift
//  IClick
//
//  更新包资产的挑选规则。
//
//  单独放在只依赖 Foundation 的文件里：这条规则需要有冒烟测试覆盖，
//  而 Updater.swift 本身依赖 SwiftUI/AppKit，不方便编进纯逻辑测试。
//

import Foundation

enum UpdateAssetSelector {
    /// 返回可安装资产的索引：优先 `.app.zip`（解压逻辑最直接），其次 `.dmg`。
    /// 后缀大小写不敏感；都不匹配时返回 nil。
    static func pickIndex(from assetNames: [String]) -> Int? {
        if let idx = assetNames.firstIndex(where: { $0.lowercased().hasSuffix(".app.zip") }) {
            return idx
        }
        return assetNames.firstIndex { $0.lowercased().hasSuffix(".dmg") }
    }
}
