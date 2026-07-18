//
//  RCBase.swift
//  IClick
//
//  Created by 李旭 on 2024/9/26.
//
import AppKit
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "IClick", category: "folder_item")

protocol RCBase: Hashable, Identifiable, Codable {
    var id: String { get }
}

struct OpenWithApp: RCBase {
    var id: String

    init(id: String = UUID().uuidString, appURL url: URL) {
        self.id = id
        self.url = url
        itemName = url.deletingPathExtension().lastPathComponent
    }

    var url: URL
    var itemName: String
    var enabled: Bool = true
    var showInMainMenu: Bool = false
    var inheritFromGlobalArguments = true
    var inheritFromGlobalEnvironment = true
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var icon: String? = nil

    var appName: String {
        FileManager.default.displayName(atPath: url.path)
    }

    var name: String {
        itemName.isEmpty ? appName : itemName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        itemName = try container.decode(String.self, forKey: .itemName)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        showInMainMenu = try container.decodeIfPresent(Bool.self, forKey: .showInMainMenu) ?? true
        inheritFromGlobalArguments = try container.decodeIfPresent(Bool.self, forKey: .inheritFromGlobalArguments) ?? true
        inheritFromGlobalEnvironment = try container.decodeIfPresent(Bool.self, forKey: .inheritFromGlobalEnvironment) ?? true
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
    }
}

extension OpenWithApp {
    init?(bundleIdentifier identifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            return nil
        }
        self.init(appURL: url)
    }

    static let vscode = OpenWithApp(bundleIdentifier: "com.microsoft.VSCode")
    static let terminal = OpenWithApp(bundleIdentifier: "com.apple.Terminal")
    static var defaultApps: [OpenWithApp] {
        [
            .terminal,
            .vscode
        ].compactMap { $0 }
    }
}

struct PermissiveDir: RCBase {
    var id: String
    var url: URL
    var bookmark: Data

    init(id: String = UUID().uuidString, permUrl url: URL) {
        self.id = id
        self.url = url
        do {
            bookmark = try url.bookmarkData(options: .withSecurityScope)
        } catch {
            logger.warning("创建 bookmark 失败: \(error.localizedDescription)")
            bookmark = Data()
        }
    }

    init(id: String, url: URL, bookmark: Data) {
        self.id = id
        self.url = url
        self.bookmark = bookmark
    }

//    enum CodingKeys: String, CodingKey {
//        case url, bookmark
//    }
//
//    init(from decoder: any Decoder) throws {
//        let values = try decoder.container(keyedBy: CodingKeys.self)
//        bookmark = try values.decode(Data.self, forKey: .bookmark)
//        var isStale = false
//        do {
//            url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
//            let result = url.startAccessingSecurityScopedResource()
//
//            if !result {
//                logger.error("Fail to start access security scoped resource on \(path)")
//            }
//        } catch {
//            // Show for the main app
//            url = try values.decode(URL.self, forKey: .url)
//        }
//        id = UUID().uuidString
//    }
}

extension PermissiveDir {
    static var home: PermissiveDir? {
        guard let pw = getpwuid(getuid()),
              let home = pw.pointee.pw_dir
        else {
            return nil
        }
        let path = FileManager.default.string(withFileSystemRepresentation: home, length: strlen(home))
        let url = URL(fileURLWithPath: path)
        return PermissiveDir(permUrl: url)
    }

    static var application: PermissiveDir? {
        PermissiveDir(permUrl: URL(fileURLWithPath: "/Applications"))
    }

    static var volumns: [PermissiveDir] {
        let volumns = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [], options: .skipHiddenVolumes) ?? []).dropFirst()
        return volumns.compactMap { PermissiveDir(permUrl: $0) }
    }

    static var defaultFolders: [PermissiveDir] {
        [.home].compactMap { $0 } + volumns
    }
}

// 常用目录
struct CommonDir: RCBase {
    var id: String
    var name: String
    var url: URL
    var icon: String
    var enabled: Bool = true
    init(id: String, name: String, url: URL, icon: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.icon = icon
        self.enabled = enabled
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(URL.self, forKey: .url)
        icon = try container.decode(String.self, forKey: .icon)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct RCAction: RCBase {
    static func == (lhs: RCAction, rhs: RCAction) -> Bool {
        lhs.id == rhs.id
    }

    var id: String

    var name: String
    var enabled = true
    var idx: Int
    var icon: String
    /// 是否只在选中文件时显示（仅 contextualMenuForItems）
    var requireSelection: Bool = false

    init(id: String, name: String, enabled: Bool = true, idx: Int, icon: String, requireSelection: Bool = false) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.idx = idx
        self.icon = icon
        self.requireSelection = requireSelection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        idx = try container.decode(Int.self, forKey: .idx)
        icon = try container.decode(String.self, forKey: .icon)
        requireSelection = try container.decodeIfPresent(Bool.self, forKey: .requireSelection) ?? false
    }
}

extension RCAction {

    static let copyPath = RCAction(id: "copy-path", name: "Copy Path", idx: 0, icon: "document.on.document")
    static let deleteDirect = RCAction(id: "delete-direct", name: "Delete Direct", idx: 1, icon: "trash.fill", requireSelection: true)
    static let hideFileDir = RCAction(id: "hide", name: "Hide", idx: 2, icon: "moon.fill", requireSelection: true)
    static let unhideFileDir = RCAction(id: "unhide", name: "Unhide", idx: 3, icon: "sun.max.fill")
    static let airdrop = RCAction(id: "airdrop", name: "AirDrop", idx: 4, icon: "paperplane.fill")
    static let cutFiles = RCAction(id: "cut-files", name: "Cut", idx: 5, icon: "scissors", requireSelection: true)
    static let pasteFiles = RCAction(id: "paste-files", name: "Paste", idx: 6, icon: "clipboard")
    /// 所有预定义操作（用于待添加列表）
    nonisolated(unsafe) static var all: [RCAction] = [.copyPath, .deleteDirect, .airdrop, .hideFileDir, .unhideFileDir, .cutFiles, .pasteFiles]

    /// 默认启用的操作（新用户首次加载）
    nonisolated(unsafe) static var defaultActions: [RCAction] = [.copyPath, .deleteDirect, .hideFileDir, .unhideFileDir]

    /// 操作图标对应的颜色
    static func iconColor(for icon: String) -> Color {
        switch icon {
        case "document.on.document": return .blue
        case "trash.fill": return .red
        case "moon.fill": return .secondary
        case "sun.max.fill": return .orange
        case "eye.slash", "eye.slash.fill": return .secondary
        case "eye", "eye.fill": return .secondary
        case "airplane", "airdrop", "wifi.radar", "bonjour", "paperplane.fill": return .teal
        case "camera.viewfinder": return .orange
        case "pencil.tip.cropview": return .orange
        default: return .accentColor
        }
    }

    /// 操作图标对应的 NSColor（用于 FinderSync 扩展）
    static func nsIconColor(for icon: String) -> NSColor {
        switch icon {
        case "document.on.document": return .systemBlue
        case "trash.fill": return .systemRed
        case "moon.fill": return .secondaryLabelColor
        case "sun.max.fill": return .systemOrange
        case "airplane", "airdrop", "wifi.radar", "bonjour", "paperplane.fill": return .systemTeal
        case "camera.viewfinder": return .systemOrange
        case "pencil.tip.cropview": return .systemOrange
        case "eye.slash", "eye.slash.fill": return .secondaryLabelColor
        case "eye", "eye.fill": return .secondaryLabelColor
        default: return .controlAccentColor
        }
    }

    /// 判断是否为自定义图标（文件路径）
    static func isCustomIcon(_ icon: String) -> Bool {
        icon.contains("/") || icon.hasSuffix(".png") || icon.hasSuffix(".jpg") || icon.hasSuffix(".icns")
    }
}

// New File Type
struct NewFile: RCBase {
    static func == (lhs: NewFile, rhs: NewFile) -> Bool {
        lhs.id == rhs.id
    }

    var ext: String
    var name: String
    var enabled = true
    var idx: Int
    var icon: String
    var id: String
    var defaultName: String = "未命名"
    var openApp: URL?
    var template: URL?

    init(ext: String, name: String, enabled: Bool = true, idx: Int, icon: String = "document", id: String = UUID().uuidString, defaultName: String = "未命名") {
        self.ext = ext
        self.name = name
        self.enabled = enabled
        self.idx = idx
        self.icon = icon
        self.id = id
        self.defaultName = defaultName
    }

    // 获取系统默认图标
    var systemIcon: NSImage {
        let fileExtension = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        let type = UTType(filenameExtension: fileExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ext = try container.decode(String.self, forKey: .ext)
        name = try container.decode(String.self, forKey: .name)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        idx = try container.decode(Int.self, forKey: .idx)
        icon = try container.decode(String.self, forKey: .icon)
        id = try container.decode(String.self, forKey: .id)
        defaultName = try container.decodeIfPresent(String.self, forKey: .defaultName) ?? "未命名"
        openApp = try container.decodeIfPresent(URL.self, forKey: .openApp)
        template = try container.decodeIfPresent(URL.self, forKey: .template)
    }
}

extension NewFile {
    nonisolated(unsafe) static var all: [NewFile] = [.txt, .md, .json, .docx, .pptx, .xlsx]

    // 使用固定的 id 而非随机 UUID，确保扩展和主应用在首次加载时 ID 一致
    static let json = NewFile(ext: ".json", name: "JSON", idx: 0, icon: "curlybraces", id: "newfile.json", defaultName: "未命名")
    static let txt = NewFile(ext: ".txt", name: "TXT", idx: 1, icon: "doc.plaintext", id: "newfile.txt", defaultName: "未命名")
    static let md = NewFile(ext: ".md", name: "Markdown", idx: 2, icon: "icon-file-md", id: "newfile.md", defaultName: "未命名")
    static let docx = NewFile(ext: ".docx", name: "DOCX", idx: 3, icon: "icon-file-docx", id: "newfile.docx", defaultName: "未命名")
    static let pptx = NewFile(ext: ".pptx", name: "PPTX", idx: 4, icon: "icon-file-pptx", id: "newfile.pptx", defaultName: "未命名")
    static let xlsx = NewFile(ext: ".xlsx", name: "XLSX", idx: 5, icon: "icon-file-xlsx", id: "newfile.xlsx", defaultName: "未命名")

    /// 文件扩展名 → SF Symbol 名称
    static func sfSymbolName(for ext: String) -> String {
        switch ext.lowercased() {
        case ".txt":    return "doc.text"
        case ".md":     return "doc.text"
        case ".docx":   return "doc.fill"
        case ".json":   return "curlybraces"
        case ".pptx":   return "rectangle.stack.fill"
        case ".xlsx":   return "tablecells"
        default:        return "doc"
        }
    }

    /// 文件扩展名 → 图标颜色
    static func fileIconColor(for ext: String) -> Color {
        switch ext.lowercased() {
        case ".json": return .orange
        case ".txt":  return .secondary
        case ".md":   return .blue
        case ".docx": return .blue
        case ".pptx": return .red
        case ".xlsx": return .green
        default:      return .accentColor
        }
    }

    /// 文件扩展名 → NSColor 图标颜色（用于 FinderSync 扩展）
    static func nsFileIconColor(for ext: String) -> NSColor {
        switch ext.lowercased() {
        case ".json": return .systemOrange
        case ".txt":  return .secondaryLabelColor
        case ".md":   return .systemBlue
        case ".docx": return .systemBlue
        case ".pptx": return .systemRed
        case ".xlsx": return .systemGreen
        default:      return .controlAccentColor
        }
    }
}
