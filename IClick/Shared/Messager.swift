//
//  Messager.swift
//  IClick
//
//  Created by 李旭 on 2024/4/9.
//

import Foundation

/// 跨进程消息载荷。
///
/// DNC 传输层已移除：动作走 LocalIPC（校验对端签名），配置由扩展直接读快照。
/// 仅保留 `MessagePayload` 供 IPC 使用；`configJSON` 字段也保留用于旧版兼容。
struct MessagePayload: Codable {
    var action: String = ""
    var target: [String] = []
    var rid: String = ""
    // ctx-items ctx-container ctx-sidebar toolbar
    var trigger: String = ""
    /// 配置同步：主应用序列化所有设置数据为 JSON 字符串
    var configJSON: String?
    /// 可靠投递用的消息 ID。扩展发出动作时生成，主应用处理前回 ack；
    /// 空字符串表示旧版消息（不 ack、不去重）。
    var messageID: String = ""

    init(
        action: String = "",
        target: [String] = [],
        rid: String = "",
        trigger: String = "",
        configJSON: String? = nil,
        messageID: String = ""
    ) {
        self.action = action
        self.target = target
        self.rid = rid
        self.trigger = trigger
        self.configJSON = configJSON
        self.messageID = messageID
    }

    enum CodingKeys: String, CodingKey {
        case action, target, rid, trigger, configJSON, messageID
    }

    /// 手写解码，让上面的属性默认值真正生效。
    ///
    /// Swift 合成的 `init(from:)` **不会**使用属性默认值：缺任何一个 key 都会抛
    /// keyNotFound，而 IPC 侧解码失败后会整条丢弃，
    /// 于是已经正确解出的字段也一起没了，只留一条日志。
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
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID) ?? ""
    }

    public var description: String {
        return "MessagePayload(action: \(action), target: \(target), rid:\(rid), trigger: \(trigger), id:\(messageID), hasConfig: \(configJSON != nil))"
    }
}

