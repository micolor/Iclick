---
name: Bug report
about: 报告一个可复现的问题
title: "[Bug] "
labels: bug
---

## 现象

<!-- 发生了什么？例如：右键菜单不出现 / 点了没反应 / 设置窗口打不开 -->

## 复现步骤

1.
2.
3.

## 环境

- macOS 版本：
- IClick 版本（设置 → 关于）：
- Finder 扩展是否已启用：
- 是否显示菜单栏图标 / 程序坞图标：
- 是否从 `/Applications` 运行（而不是 Xcode/DerivedData）：

## 诊断信息

最快：在仓库里运行 `./scripts/collect-diagnostics.sh`，把桌面上生成的
`IClick-diagnostics-*.tar.gz` 附上。

手工收集（注意日志里会包含你操作过的文件路径）：

- `~/Library/Application Support/IClick/diagnostics.log`
- `~/Library/Group Containers/group.33WRMMC62L.cn.anwen.IClick/diagnostics-extension.log`
- 下面命令的输出：

```bash
pluginkit -m -v -p com.apple.FinderSync | grep -i iclick
lsregister -dump | grep -E "^path:.*Iclick.app"
sfltool dumpbtm | grep -B7 -A2 "Bundle Identifier: cn.anwen.IClick"
```

## 备注

<!-- 其他你觉得相关的信息 -->
