//
//  Updater.swift
//  IClick
//
//  Created by 李旭 on 2025/9/21.
//

#if !APP_STORE

import CryptoKit
import Foundation
import Security
import SwiftUI

// MARK: - 数据模型

struct GitHubRelease: Codable, Identifiable {
    let id: Int
    let tagName: String
    let name: String
    let body: String
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date
    let assets: [Asset]
    let htmlUrl: String

    var version: String {
        // 只去掉开头的 "v"，不能全局替换：
        // "v2.1.0-dev" 之类会被 replaceOccurrences 破坏成 "2.1.0-de"
        if tagName.hasPrefix("v") || tagName.hasPrefix("V") {
            return String(tagName.dropFirst())
        }
        return tagName
    }

    struct Asset: Codable {
        let id: Int
        let name: String
        let browserDownloadUrl: String
        let size: Int
        let contentType: String?
        /// GitHub 对新上传的资源会返回 "sha256:<hex>"；老资源为 nil
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case id, name, size, digest
            case browserDownloadUrl = "browser_download_url"
            case contentType = "content_type"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name, body, draft, prerelease, assets
        case publishedAt = "published_at"
        case htmlUrl = "html_url"
    }
}

// MARK: - 用户偏好设置

class UpdatePreferences: ObservableObject {
    @AppStorage("ignoredVersion") private var ignoredVersionData: Data = .init()

    // 获取忽略的版本列表
    var ignoredVersions: [String] {
        get {
            do {
                return try JSONDecoder().decode([String].self, from: ignoredVersionData)
            } catch {
                return []
            }
        }
        set {
            do {
                ignoredVersionData = try JSONEncoder().encode(newValue)
            } catch {
            }
        }
    }

    // 忽略特定版本
    func ignoreVersion(_ version: String) {
        var ignored = ignoredVersions
        if !ignored.contains(version) {
            ignored.append(version)
            ignoredVersions = ignored
        }
    }

    // 检查版本是否被忽略
    func isVersionIgnored(_ version: String) -> Bool {
        ignoredVersions.contains(version)
    }
}

// MARK: - GitHub API 服务

class GitHubReleaseChecker: @unchecked Sendable {
    private let owner: String
    private let repo: String

    init(owner: String, repo: String) {
        self.owner = owner
        self.repo = repo
    }

    // 获取最新release
    func fetchLatestRelease() async throws -> GitHubRelease? {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }
}

// MARK: - 更新管理器

@MainActor
class UpdateManager: ObservableObject {
    @Published var availableUpdate: GitHubRelease?
    @Published var isChecking = false
    @Published var updateError: String?
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var showUpdateSheet = false

    private let githubChecker: GitHubReleaseChecker
    private let preferences: UpdatePreferences
    private let currentVersion: String
    private var downloadTask: URLSessionDownloadTask?

    init(owner: String, repo: String, currentVersion: String) {
        self.githubChecker = GitHubReleaseChecker(owner: owner, repo: repo)
        self.preferences = UpdatePreferences()
        self.currentVersion = currentVersion
    }

    // 关闭更新提示
    func dismissUpdateSheet() {
        if isDownloading {
            downloadTask?.cancel()
            downloadTask = nil
        }
        showUpdateSheet = false
        availableUpdate = nil
        updateError = nil
        isDownloading = false
        downloadProgress = 0
    }

    // 检查更新
    func checkForUpdates(force: Bool = false) async {
        isChecking = true
        updateError = nil
        availableUpdate = nil
        showUpdateSheet = true

        defer { isChecking = false }

        do {
            guard let release = try await githubChecker.fetchLatestRelease() else {
                return
            }

            if release.draft || release.prerelease {
                return
            }

            let comparison = compareVersions(currentVersion, release.version)
            if comparison != .orderedAscending {
                return
            }

            if !force && preferences.isVersionIgnored(release.version) {
                return
            }

            availableUpdate = release
        } catch {
            updateError = error.localizedDescription
        }
    }

    // 语义化版本比较
    private func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        let c1 = v1.components(separatedBy: ".")
        let c2 = v2.components(separatedBy: ".")
        for i in 0 ..< max(c1.count, c2.count) {
            let a = i < c1.count ? c1[i] : "0"
            let b = i < c2.count ? c2[i] : "0"
            if let n1 = Int(a), let n2 = Int(b) {
                if n1 < n2 { return .orderedAscending }
                if n1 > n2 { return .orderedDescending }
            } else {
                let r = a.compare(b)
                if r != .orderedSame { return r }
            }
        }
        return .orderedSame
    }

    // MARK: - 下载和安装方法

    func downloadAndInstallUpdate() async {
        guard let release = availableUpdate else {
            updateError = "没有可用的更新"
            return
        }

        guard let appZipAsset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".app.zip") }) else {
            updateError = "未找到 .app.zip 格式的应用程序包"
            return
        }

        isDownloading = true
        downloadProgress = 0

        var downloadedURL: URL?
        var extractionRoot: URL?

        do {
            let zipURL = try await downloadAsset(asset: appZipAsset)
            downloadedURL = zipURL

            // GitHub 对新上传的资源会给出 sha256，有就先校验再解压
            if let digest = appZipAsset.digest, digest.lowercased().hasPrefix("sha256:") {
                try verifySHA256(fileURL: zipURL, expectedHex: String(digest.dropFirst("sha256:".count)))
            }

            let extracted = try await extractAppZip(zipURL: zipURL)
            extractionRoot = extracted.root

            try verifyAppBundle(extracted.app)
            try await installApplication(appURL: extracted.app)

            showInstallationCompleteAlert()
        } catch {
            updateError = "安装失败: \(error.localizedDescription)"
        }

        // 失败路径之前不清理，临时目录里会一直堆积几十 MB 的下载包和解压结果
        if let downloadedURL { try? FileManager.default.removeItem(at: downloadedURL) }
        if let extractionRoot { try? FileManager.default.removeItem(at: extractionRoot) }

        isDownloading = false
    }

    /// 校验下载文件的 SHA-256（仅当 release 提供了 digest 时调用）
    private func verifySHA256(fileURL: URL, expectedHex: String) throws {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let actualHex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actualHex.caseInsensitiveCompare(expectedHex) == .orderedSame else {
            throw InstallationError.integrityCheckFailed("下载文件校验失败，可能已损坏或被篡改")
        }
    }

    /// 安装前的安全校验：必须是与当前应用同一个签名主体的合法副本。
    /// 没有这层校验时，任何被替换的 zip 都能直接覆盖已安装的应用。
    private func verifyAppBundle(_ appURL: URL) throws {
        // 1. bundle id 必须与当前应用一致
        guard let bundle = Bundle(url: appURL), let newBundleID = bundle.bundleIdentifier else {
            throw InstallationError.invalidAppBundle("应用程序包无效或损坏")
        }
        guard let expectedBundleID = Bundle.main.bundleIdentifier, newBundleID == expectedBundleID else {
            throw InstallationError.invalidAppBundle("应用程序标识不匹配，已中止安装")
        }

        // 2. 代码签名必须有效
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--verify", "--deep", "--strict", appURL.path]
        let errPipe = Pipe()
        codesign.standardOutput = Pipe()
        codesign.standardError = errPipe
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            let detail = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw InstallationError.integrityCheckFailed("更新包签名校验失败：\(detail)")
        }

        // 3. 签名 Team ID 必须与当前应用一致
        if let currentTeam = teamIdentifier(of: Bundle.main.bundleURL),
           let newTeam = teamIdentifier(of: appURL),
           currentTeam != newTeam {
            throw InstallationError.integrityCheckFailed("更新包签名主体与当前应用不一致，已中止安装")
        }
    }

    /// 读取 bundle 的签名 Team ID；未签名或读取失败时返回 nil
    private func teamIdentifier(of bundleURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    func downloadAsset(asset: GitHubRelease.Asset) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let downloadURL = tempDir.appendingPathComponent(asset.name)

        // 不再强制解包：一个空的/非法的 download_url 会直接崩溃
        guard let url = URL(string: asset.browserDownloadUrl), url.scheme?.lowercased() == "https" else {
            throw DownloadError.downloadFailed("下载地址无效")
        }
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let delegate = DownloadProgressDelegate { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let config = URLSessionConfiguration.default
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
            let task = session.downloadTask(with: request) { tempURL, response, error in
                // session 会强引用 delegate，不 invalidate 的话每次更新都会泄漏一个 URLSession
                defer { session.finishTasksAndInvalidate() }
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let tempURL = tempURL,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200
                else {
                    continuation.resume(throwing: DownloadError.downloadFailed("下载失败"))
                    return
                }

                do {
                    try? FileManager.default.removeItem(at: downloadURL)
                    try FileManager.default.moveItem(at: tempURL, to: downloadURL)
                    continuation.resume(returning: downloadURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            Task { @MainActor [weak self] in
                self?.downloadTask = task
            }
            task.resume()
        }
    }

    // MARK: - 下载进度代理

    private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
        let onProgress: @Sendable (Double) -> Void

        init(onProgress: @escaping @Sendable (Double) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            onProgress(progress)
        }
    }

    // MARK: - 解压 APP Zip 文件

    /// 解压 .app.zip，返回 (app 路径, 解压根目录)。
    /// 返回根目录是给调用方做清理用的（解压失败时也要能删掉残留）。
    private func extractAppZip(zipURL: URL) async throws -> (app: URL, root: URL) {
        let extractionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("app_extraction-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: extractionDir, withIntermediateDirectories: true)

        // unzip 是同步阻塞调用，放到主线程之外执行，否则安装期间整个界面卡住
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", zipURL.path, "-d", extractionDir.path]

            let errorPipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "未知错误"
                throw InstallationError.zipExtractionFailed("解压失败: \(errorString)")
            }
        }.value

        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: extractionDir, includingPropertiesForKeys: nil)

        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw InstallationError.noAppFound("在ZIP文件中未找到.app应用程序")
        }

        return (appURL, extractionDir)
    }

    // MARK: - 请求文件夹权限
    @MainActor
    private func requestApplicationsFolderAccess() async throws {
        let openPanel = NSOpenPanel()
        openPanel.message = "IClick 需要权限以将更新安装到您的“应用程序”文件夹中。"
        openPanel.prompt = "授予权限"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first

        let response = await openPanel.begin()

        guard response == .OK, let selectedURL = openPanel.url else {
            throw InstallationError.permissionDenied("用户取消了授权。")
        }

        let applicationsURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first!
        guard selectedURL.path == applicationsURL.path else {
            throw InstallationError.permissionDenied("请选择正确的‘应用程序’文件夹。")
        }
    }
    // MARK: - 安装应用到应用程序目录
    private func installApplication(appURL: URL) async throws {
        let fileManager = FileManager.default
        let applicationsURL = fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first!
        let destinationAppURL = applicationsURL.appendingPathComponent(appURL.lastPathComponent)

        if !fileManager.isWritableFile(atPath: applicationsURL.path) {
            try await requestApplicationsFolderAccess()
        }

        // 先在同卷的隐藏名字下完成复制，再替换目标。
        // 之前是「先 trash 掉旧应用 → 再 copy 新的」，copy 一旦失败用户就没有应用了。
        let stagingURL = applicationsURL.appendingPathComponent(".iclick-staging-\(UUID().uuidString).app")
        try? fileManager.removeItem(at: stagingURL)
        try fileManager.copyItem(at: appURL, to: stagingURL)

        guard Bundle(url: stagingURL) != nil else {
            try? fileManager.removeItem(at: stagingURL)
            throw InstallationError.invalidAppBundle("应用程序包无效或损坏")
        }

        var backupURL: URL?
        if fileManager.fileExists(atPath: destinationAppURL.path) {
            let backup = applicationsURL.appendingPathComponent(".iclick-backup-\(UUID().uuidString).app")
            try fileManager.moveItem(at: destinationAppURL, to: backup)
            backupURL = backup
        }

        do {
            try fileManager.moveItem(at: stagingURL, to: destinationAppURL)
        } catch {
            // 替换失败就把旧应用放回去，避免用户失去已安装的应用
            if let backupURL, !fileManager.fileExists(atPath: destinationAppURL.path) {
                try? fileManager.moveItem(at: backupURL, to: destinationAppURL)
            }
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        if let backupURL {
            try? fileManager.trashItem(at: backupURL, resultingItemURL: nil)
        }
    }

    // MARK: - 显示安装完成提示

    private func showInstallationCompleteAlert() {
        let alert = NSAlert()
        alert.messageText = "更新安装完成"
        alert.informativeText = "应用程序已成功更新。需要重启应用来完成更新过程。"
        alert.addButton(withTitle: "立即重启")
        alert.addButton(withTitle: "稍后重启")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            launchNewApplicationAndExit()
        }
    }

    // MARK: - 启动新应用并退出

    private func launchNewApplicationAndExit() {
        let fileManager = FileManager.default
        let applicationsURL = fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first!
        let currentAppName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "IClick"
        let newAppURL = applicationsURL.appendingPathComponent("\(currentAppName).app")

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: newAppURL, configuration: configuration) { _, error in
            if error != nil {
            }
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    // 忽略当前可用更新
    func ignoreCurrentUpdate() {
        if let version = availableUpdate?.version {
            preferences.ignoreVersion(version)
            availableUpdate = nil
        }
    }

    // 打开GitHub发布页面
    func openReleasesPage() {
        if let url = URL(string: "https://github.com/anwen/IClick/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 错误类型

    enum DownloadError: LocalizedError, Sendable {
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let message):
                return message
            }
        }
    }

    enum InstallationError: LocalizedError, Sendable {
        case zipExtractionFailed(String)
        case noAppFound(String)
        case invalidAppBundle(String)
        case permissionDenied(String)
        case integrityCheckFailed(String)

        var errorDescription: String? {
            switch self {
            case .zipExtractionFailed(let message):
                return message
            case .noAppFound(let message):
                return message
            case .invalidAppBundle(let message):
                return message
            case .permissionDenied(let message):
                return message
            case .integrityCheckFailed(let message):
                return message
            }
        }
    }
}

#endif
