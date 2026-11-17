//
//  DiagnosticLog.swift
//  IClick
//
//  纯文本诊断日志。
//
//  为什么需要它：macOS 的统一日志（OSLog）默认把路径、rid 等脱敏成 <private>，
//  而且本机实测 `log show` 会报 "log archive is corrupt or incomplete" ——
//  用户遇到问题时没有任何可读记录可发。这里把关键事件同时写一份到固定文件：
//  主应用 → ~/Library/Application Support/IClick/diagnostics.log
//  扩展   → ~/Library/Group Containers/<group>/diagnostics-extension.log
//  只记录动作、路径、错误描述，不记录文件内容。
//

import Foundation
import Darwin

final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()

    private let queue = DispatchQueue(label: "cn.anwen.IClick.diagnostics", qos: .utility)
    private let fileURL: URL
    private let maxBytes: UInt64 = 2 * 1024 * 1024

    // 崩溃标记：信号处理函数里只能做 async-signal-safe 的事，
    // 所以预先打开 fd、预先准备好一段静态字节，里面不做任何分配。
    private nonisolated(unsafe) static var crashFD: Int32 = -1
    private nonisolated(unsafe) static var crashMarkerPointer: UnsafePointer<UInt8>?
    private nonisolated(unsafe) static var crashMarkerCount = 0
    private nonisolated(unsafe) static var crashHandlersInstalled = false

    private init() {
        let isExtension = Bundle.main.bundleIdentifier?.hasSuffix(".FinderSyncExt") ?? false
        if isExtension {
            fileURL = SharedSettings.realHomeURL
                .appendingPathComponent("Library/Group Containers")
                .appendingPathComponent(Constants.suitName)
                .appendingPathComponent("diagnostics-extension.log")
        } else {
            fileURL = SharedSettings.realHomeURL
                .appendingPathComponent("Library/Application Support/IClick")
                .appendingPathComponent("diagnostics.log")
        }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        write("---- launch pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleURL.path) ----")
    }

    /// 异步追加一行。不要在信号处理函数里调用（信号上下文里 Foundation 不安全）。
    func write(_ message: String) {
        let url = fileURL
        let cap = maxBytes
        queue.async {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let line = "[\(formatter.string(from: Date()))] \(message)\n"

            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64,
               size > cap {
                let backup = url.appendingPathExtension("1")
                try? fm.removeItem(at: backup)
                try? fm.moveItem(at: url, to: backup)
            }

            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// 同步追加（只给未捕获异常处理器用；正常路径请用 write）。
    func writeSync(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 安装崩溃标记。
    ///
    /// - 信号（SIGABRT/SIGSEGV/...）：只做 `write(2)`，然后恢复默认处理并重新 raise，
    ///   让系统照常生成崩溃报告；
    /// - Objective-C 未捕获异常：写一条带调用栈的同步日志。
    ///
    /// 这些标记不能代替真正的崩溃报告（没有寄存器/完整栈），但至少能让用户知道
    /// “是哪一刻崩的”，并且和前后日志对得上。
    func installCrashHandlers() {
        guard !Self.crashHandlersInstalled else { return }
        Self.crashHandlersInstalled = true

        Self.crashFD = fileURL.path.withCString {
            open($0, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }

        // 预先分配，信号处理里不再分配内存
        let marker = Array("IClick crashed (signal)\n".utf8)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: marker.count)
        buffer.initialize(from: marker, count: marker.count)
        Self.crashMarkerPointer = UnsafePointer(buffer)
        Self.crashMarkerCount = marker.count

        for sig in [SIGABRT, SIGSEGV, SIGILL, SIGFPE, SIGBUS] {
            signal(sig) { signalNumber in
                if DiagnosticLog.crashFD >= 0, let pointer = DiagnosticLog.crashMarkerPointer {
                    _ = Darwin.write(DiagnosticLog.crashFD, pointer, DiagnosticLog.crashMarkerCount)
                }
                signal(signalNumber, SIG_DFL)
                raise(signalNumber)
            }
        }

        NSSetUncaughtExceptionHandler { exception in
            DiagnosticLog.shared.writeSync(
                "UNCAUGHT \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.joined(separator: "\n")
            )
        }
    }
}
