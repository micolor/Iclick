# Contributing

## 先读

- [`ARCHITECTURE.md`](ARCHITECTURE.md)：两个进程、数据流、不变量和故障模型。
- [`CLAUDE.md`](CLAUDE.md)：开发约定（Swift 6、SwiftUI、数据持久化规则）。

## 构建

需要 macOS 15+ 与 Xcode 16+：

```bash
xcodebuild -project IClick.xcodeproj -scheme IClick -destination 'platform=macOS' build
```

本机没有同意 Xcode 许可、`xcodebuild` 被门禁挡住时，用：

```bash
./scripts/build-local.sh
```

该脚本会手工编译、签名、安装到 `/Applications`。它**必须**链接
`/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`，否则应用会退化成旧版不透明外观。

## 测试

```bash
./scripts/smoke-test.sh
```

只覆盖不依赖界面的纯逻辑。CI 会同时运行它和 `xcodebuild build`。

## 改动原则

- **不改变现有 UI 风格**：不要新增 Section、弹窗、开关或改动词条，除非先讨论。
- 数据持久化只有一个写者：主应用。扩展是只读消费者（见 `ARCHITECTURE.md`）。
- 破坏性文件操作必须可恢复（废纸篓），并经过 `Utils.isProtectedFolder` 检查。
- 修改配置读写、窗口入口、IPC 时，先看 `ARCHITECTURE.md` 里的不变量，并补一条 smoke test。
- 提交信息用中文，说明“为什么”而不是只写“改了什么”。

## 报问题

请用 issue 模板，并附上 `diagnostics.log`（路径见模板）。里面会包含你操作过的文件路径；
如果介意，请先自行脱敏。
