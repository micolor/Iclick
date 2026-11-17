//
//  MessageDeduplicator.swift
//  IClick
//
//  可靠投递的去重表：扩展发动作时会带 messageID，主应用处理前回 ack。
//  如果 ack 丢了，扩展会重发；主应用靠这张表识别重复，避免删除/移动这类
//  非幂等操作被执行两次。
//

import Foundation

struct MessageDeduplicator {
    private var seen: Set<String> = []
    private var order: [String] = []
    private let capacity: Int

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    /// 返回 true 表示第一次见到；false 表示重复。
    /// 空 ID（旧版消息）一律放行，不做去重。
    mutating func accept(_ id: String) -> Bool {
        guard !id.isEmpty else { return true }
        if seen.contains(id) { return false }

        seen.insert(id)
        order.append(id)
        if order.count > capacity {
            let oldest = order.removeFirst()
            seen.remove(oldest)
        }
        return true
    }
}
