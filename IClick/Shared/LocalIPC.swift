//
//  LocalIPC.swift
//  IClick
//
//  扩展 → 主应用动作通道的本机 IPC。
//
//  为什么不用 DNC：DistributedNotificationCenter 是全局命名空间，不校验发送方，
//  任何本地进程都能伪造一条 "open"/"delete" 消息。这里改用 App Group 容器里的
//  Unix domain socket，并在主应用侧校验对端的代码签名（bundle id + Team ID）。
//
//  为什么不用 Mach service / NSXPCListener：扩展是沙盒进程，lookup 任意 Mach
//  service 需要 mach-lookup 临时例外 entitlements；App Group 容器里的 socket
//  只需要已有的 application-groups 权限。
//

import Foundation
import Darwin
import Security

enum LocalIPC {
    /// socket 放在群组容器里；主应用和扩展都有该容器的读写权限。
    static var socketURL: URL {
        SharedSettings.snapshotURL
            .deletingLastPathComponent()
            .appendingPathComponent("ipc.sock")
    }

    static let maxMessageSize = 4 * 1024 * 1024
    private static let solLocal: Int32 = 0
    private static let localPeerPIDOption: Int32 = 0x002

    // MARK: - 帧格式：4 字节大端长度 + JSON

    static func writeMessage(fd: Int32, data: Data) -> Bool {
        guard data.count > 0, data.count <= maxMessageSize else { return false }
        var length = UInt32(data.count).bigEndian
        let header = Data(bytes: &length, count: 4)
        return writeAll(fd: fd, data: header) && writeAll(fd: fd, data: data)
    }

    static func readMessage(fd: Int32) -> Data? {
        guard let header = readExact(fd: fd, count: 4) else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length > 0, length <= maxMessageSize else { return nil }
        return readExact(fd: fd, count: Int(length))
    }

    static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    static func readExact(fd: Int32, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var offset = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while offset < count {
                let n = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if n > 0 {
                    offset += n
                } else if n == 0 {
                    return false
                } else if errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        return ok ? data : nil
    }

    static func makeAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return addr
    }

    // MARK: - 对端校验

    /// 只有本应用签名主体下的 FinderSyncExt 才能通过。
    /// 这里校验的是操作系统给出的对端 PID 的代码签名，不是消息里的自述。
    static func isTrustedPeer(fd: Int32) -> Bool {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, solLocal, localPeerPIDOption, &pid, &len) == 0, pid > 0 else {
            DiagnosticLog.shared.write("ipc peer: LOCAL_PEERPID failed errno=\(errno)")
            return false
        }

        let attrs: [CFString: Any] = [kSecGuestAttributePid: NSNumber(value: pid)]
        var code: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &code)
        guard guestStatus == errSecSuccess, let code else {
            DiagnosticLog.shared.write("ipc peer pid=\(pid) guest status=\(guestStatus)")
            return false
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            DiagnosticLog.shared.write("ipc peer pid=\(pid) static status=\(staticStatus)")
            return false
        }

        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        guard infoStatus == errSecSuccess, let dict = info as? [String: Any] else {
            DiagnosticLog.shared.write("ipc peer pid=\(pid) info status=\(infoStatus)")
            return false
        }

        let bundleID = dict[kSecCodeInfoIdentifier as String] as? String
        let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        DiagnosticLog.shared.write("ipc peer pid=\(pid) bundle=\(bundleID ?? "nil") team=\(teamID ?? "nil")")
        return bundleID == "cn.anwen.IClick.FinderSyncExt" && teamID == "33WRMMC62L"
    }
}

// MARK: - 客户端（扩展侧）

enum LocalIPCClient {
    /// 发送一条动作并等待主应用 ack。返回 true 表示对端已确认收到。
    static func send(_ payload: MessagePayload, timeout: TimeInterval = 1.0) -> Bool {
        guard let addr = LocalIPC.makeAddress(LocalIPC.socketURL.path) else { return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }

        guard let data = try? JSONEncoder().encode(payload),
              LocalIPC.writeMessage(fd: fd, data: data),
              let ackData = LocalIPC.readMessage(fd: fd),
              let ack = try? JSONDecoder().decode(MessagePayload.self, from: ackData),
              ack.action == "ack" else {
            return false
        }
        return true
    }
}

// MARK: - 服务端（主应用侧）

final class LocalIPCServer: @unchecked Sendable {
    // accept 循环会永久阻塞在 accept() 上，绝不能和 handleClient 共用同一条串行队列：
    // 之前两者都在 queue 上，run() 占住队列后再也轮不到 handleClient，
    // 表现为客户端 connect 成功却等不到 ack（超时后一直重试），服务端一条日志都没有。
    private let acceptQueue = DispatchQueue(label: "cn.anwen.IClick.ipc-accept", qos: .userInitiated)
    private let clientQueue = DispatchQueue(
        label: "cn.anwen.IClick.ipc-client",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let handler: @Sendable (MessagePayload) -> Void
    private var listenFD: Int32 = -1

    init(handler: @escaping @Sendable (MessagePayload) -> Void) {
        self.handler = handler
    }

    func start() {
        acceptQueue.async { [weak self] in self?.run() }
    }

    func stop() {
        let fd = listenFD
        listenFD = -1
        if fd >= 0 {
            close(fd)
        }
        _ = LocalIPC.socketURL.path.withCString { unlink($0) }
    }

    private func run() {
        let path = LocalIPC.socketURL.path
        let dir = LocalIPC.socketURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = path.withCString { unlink($0) }

        guard let addr = LocalIPC.makeAddress(path) else {
            DiagnosticLog.shared.write("ipc server: socket path too long: \(path)")
            return
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            DiagnosticLog.shared.write("ipc server: socket() failed errno=\(errno)")
            return
        }
        listenFD = fd

        let bound = withUnsafePointer(to: addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            DiagnosticLog.shared.write("ipc server: bind/listen failed errno=\(errno)")
            close(fd)
            listenFD = -1
            return
        }

        _ = path.withCString { chmod($0, 0o600) }
        DiagnosticLog.shared.write("ipc server listening \(path)")

        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            clientQueue.async { [weak self] in self?.handleClient(client) }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard LocalIPC.isTrustedPeer(fd: fd) else {
            DiagnosticLog.shared.write("ipc server: rejected untrusted peer")
            return
        }
        guard let data = LocalIPC.readMessage(fd: fd),
              let payload = try? JSONDecoder().decode(MessagePayload.self, from: data) else {
            DiagnosticLog.shared.write("ipc server: invalid message")
            return
        }

        if let ackData = try? JSONEncoder().encode(
            MessagePayload(action: "ack", messageID: payload.messageID)
        ) {
            _ = LocalIPC.writeMessage(fd: fd, data: ackData)
        }
        handler(payload)
    }
}
