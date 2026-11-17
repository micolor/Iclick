//
//  main.swift
//  IClick smoke tests
//
//  只测不依赖界面的纯逻辑：消息解码、路径保护、模型编解码。
//  用 scripts/smoke-test.sh 编译运行；CI 里也会跑。
//

import Foundation
import Darwin

// 手动验证崩溃标记：`.build/smoke --crash-test` 会先写一行标记，再按默认方式崩溃。
// 仅用于本地排查，不参与普通 smoke test。
if CommandLine.arguments.contains("--crash-test") {
    DiagnosticLog.shared.installCrashHandlers()
    DiagnosticLog.shared.writeSync("crash test: raising SIGABRT")
    raise(SIGABRT)
}

var failures = 0

@MainActor
func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name)")
        failures += 1
    }
}

// MARK: - MessagePayload 解码

let fullJSON = #"{"action":"open","target":["/tmp/a","/tmp/b"],"rid":"abc","trigger":"ctx-items"}"#
do {
    let payload = try JSONDecoder().decode(MessagePayload.self, from: Data(fullJSON.utf8))
    check(payload.action == "open" && payload.target.count == 2 && payload.rid == "abc" && payload.trigger == "ctx-items",
          "MessagePayload 完整字段")
} catch {
    check(false, "MessagePayload 完整字段（解码抛错: \(error)）")
}

let partialJSON = #"{"action":"heartbeat"}"#
do {
    let payload = try JSONDecoder().decode(MessagePayload.self, from: Data(partialJSON.utf8))
    check(payload.action == "heartbeat" && payload.target.isEmpty && payload.rid.isEmpty && payload.trigger.isEmpty,
          "MessagePayload 缺字段时用默认值")
    check(payload.messageID.isEmpty, "MessagePayload 旧消息 messageID 为空")
} catch {
    check(false, "MessagePayload 缺字段时用默认值（解码抛错: \(error)）")
}

do {
    let json = #"{"action":"open","messageID":"m-1"}"#
    let payload = try JSONDecoder().decode(MessagePayload.self, from: Data(json.utf8))
    check(payload.messageID == "m-1", "MessagePayload 保留 messageID")
} catch {
    check(false, "MessagePayload 保留 messageID（解码抛错: \(error)）")
}

// MARK: - 可靠投递去重

do {
    var dedupe = MessageDeduplicator(capacity: 3)
    check(dedupe.accept("a"), "去重: 第一次接受 a")
    check(dedupe.accept("b"), "去重: 第一次接受 b")
    check(!dedupe.accept("a"), "去重: 重复的 a 被拒绝")
    check(dedupe.accept(""), "去重: 空 ID 放行")
    check(dedupe.accept("c"), "去重: 第一次接受 c")
    check(dedupe.accept("d"), "去重: 容量满后接受 d")
    check(dedupe.accept("a"), "去重: 被淘汰的 a 可以再次接受")
}

// MARK: - 受保护目录判断

check(Utils.isProtectedFolder("/System"), "受保护: /System")
check(Utils.isProtectedFolder("/system"), "受保护: 大小写不敏感")
check(Utils.isProtectedFolder("/System/../System"), "受保护: 规范化 ..")
check(Utils.isProtectedFolder("/Users/anwen/Desktop"), "受保护: ~/Desktop")
check(Utils.isProtectedFolder("~/Desktop"), "受保护: 字面 ~/Desktop")
check(Utils.isProtectedFolder(""), "空路径按危险处理")
check(!Utils.isProtectedFolder("/tmp"), "不受保护: /tmp")
check(!Utils.isProtectedFolder("/Users/anwen/Documents"), "不受保护: ~/Documents")

check(Utils.isSystemFolder("/Applications"), "系统目录: /Applications")
check(Utils.isSystemFolder("/Library"), "系统目录: /Library")
check(!Utils.isSystemFolder("/Users/anwen/Desktop"), "桌面不是系统目录（允许整目录隐藏）")

// MARK: - 模型编解码往返

do {
    let app = OpenWithApp(id: "com.example.Test", appURL: URL(fileURLWithPath: "/Applications/Test.app"))
    let data = try PropertyListEncoder().encode([app])
    let decoded = try PropertyListDecoder().decode([OpenWithApp].self, from: data)
    check(decoded.count == 1
            && decoded[0].id == "com.example.Test"
            && decoded[0].url.path == "/Applications/Test.app",
          "OpenWithApp 编解码往返")
} catch {
    check(false, "OpenWithApp 编解码往返（抛错: \(error)）")
}

do {
    let data = try PropertyListEncoder().encode([RCAction.copyPath])
    let decoded = try PropertyListDecoder().decode([RCAction].self, from: data)
    check(decoded.count == 1 && decoded[0].id == "copy-path", "RCAction 编解码往返")
} catch {
    check(false, "RCAction 编解码往返（抛错: \(error)）")
}

do {
    let file = NewFile(ext: ".md", name: "Markdown", idx: 0, icon: "doc.text", id: "newfile.md")
    let data = try PropertyListEncoder().encode([file])
    let decoded = try PropertyListDecoder().decode([NewFile].self, from: data)
    check(decoded.count == 1 && decoded[0].id == "newfile.md" && decoded[0].ext == ".md",
          "NewFile 编解码往返")
} catch {
    check(false, "NewFile 编解码往返（抛错: \(error)）")
}

// 默认 App 的 id 固定（跨进程匹配依赖它）；环境里装没装这些 App 不影响断言。
check(OpenWithApp.defaultApps.allSatisfy { $0.id.contains(".") }, "默认 App 使用固定 bundle id")

print("")
if failures == 0 {
    print("全部通过")
    exit(0)
} else {
    print("\(failures) 项失败")
    exit(1)
}
