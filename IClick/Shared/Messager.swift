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

    init(
        action: String = "",
        target: [String] = [],
        rid: String = "",
        trigger: String = "",
        configJSON: String? = nil
    ) {
        self.action = action
        self.target = target
        self.rid = rid
        self.trigger = trigger
        self.configJSON = configJSON
    }

    enum CodingKeys: String, CodingKey {
        case action, target, rid, trigger, configJSON
    }

    /// 手写解码，让上面的属性默认值真正生效。
    ///
    /// Swift 合成的 `init(from:)` **不会**使用属性默认值：缺任何一个 key 都会抛
    /// keyNotFound，而 `Messager.reconstructEntry` 把异常吞掉后返回一个全空载荷，
    /// 于是整条消息连同已经正确解出的字段一起被丢弃，只留一条 warning。
    /// （已用编译探针实测确认：`{"action":"open"}` 在合成版本下解码返回 nil。）
    /// 以后任何一边新增字段而另一边没跟上，现象就是「点了没反应」。
    /// 改成 decodeIfPresent + 默认值后，缺 key 只影响该字段本身。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decodeIfPresent(String.self, forKey: .action) ?? ""
        target = try container.decodeIfPresent([String].self, forKey: .target) ?? []
        rid = try container.decodeIfPresent(String.self, forKey: .rid) ?? ""
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger) ?? ""
        configJSON = try container.decodeIfPresent(String.self, forKey: .configJSON)
    }

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
