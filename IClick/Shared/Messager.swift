//
//  Messager.swift
//  IClick
//
//  Created by 李旭 on 2024/4/9.
//

import Foundation

struct MessagePayload: Codable {
    var action: String = ""
    var target: [String] = []
    var rid: String = ""
    // ctx-items ctx-container ctx-sidebar toolbar
    var trigger: String = ""
    /// 配置同步：主应用序列化所有设置数据为 JSON 字符串
    var configJSON: String?

    public var description: String {
        return "MessagePayload(action: \(action), target: \(target), rid:\(rid), trigger: \(trigger), hasConfig: \(configJSON != nil))"
    }
}

class Messager: @unchecked Sendable {
    static let shared = Messager()

    @AppLog(category: "messager")
    private var logger

    let center: DistributedNotificationCenter = .default()
    private let lock = NSLock()
    private var bus: [String: (_ payload: MessagePayload) -> Void] = [:]

    func sendMessage(name: String, data: MessagePayload) {
        let message: String = createMessageData(messagePayload: data)
        // 原来是 warning：心跳每 3 秒一条，等于永久往统一日志写 warning（warning 默认落盘）
        logger.debug("sendMessage to \(name, privacy: .public)")
        center.postNotificationName(NSNotification.Name(name), object: message, userInfo: nil, deliverImmediately: true)
    }

    private func createMessageData(messagePayload: MessagePayload) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(messagePayload),
              let str = String(data: data, encoding: .utf8) else {
            logger.warning("Failed to encode MessagePayload")
            return "{}"
        }
        return str
    }

    private func reconstructEntry(messagePayload: String) -> MessagePayload {
        guard let jsonData = messagePayload.data(using: .utf8) else {
            logger.warning("Failed to convert messagePayload to Data")
            return MessagePayload()
        }
        do {
            let messagePayloadCacheEntry = try JSONDecoder().decode(MessagePayload.self, from: jsonData)
            return messagePayloadCacheEntry
        } catch {
            logger.warning("Failed to decode MessagePayload: \(error), jsondata:\(jsonData)")
            return MessagePayload()
        }
    }

    func on(name: String, handler: @escaping (MessagePayload) -> Void) {
        // 防止重复注册观察者
        lock.lock()
        let alreadyRegistered = bus[name] != nil
        bus[name] = handler
        lock.unlock()
        if !alreadyRegistered {
            center.addObserver(self, selector: #selector(receivedMessage(_:)), name: NSNotification.Name(name), object: nil)
        }
    }

    @objc func receivedMessage(_ notification: NSNotification) {
        guard let messageStr = notification.object as? String else {
            logger.warning("received notification with invalid object type")
            return
        }
        let payload = reconstructEntry(messagePayload: messageStr)
        lock.lock()
        let handler = bus[notification.name.rawValue]
        lock.unlock()
        if let handler = handler {
            // Dispatch to main thread since handlers access @MainActor state
            DispatchQueue.main.async {
                handler(payload)
            }
        } else {
            logger.warning("there no handler for \(notification.name.rawValue)")
        }
    }
}
