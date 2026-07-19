[![](./IClick/Assets.xcassets/AppIcon.appiconset/AppIcon@1x.png)](https://github.com/micolor/IClick/releases)

# IClick

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-ED523F.svg?style=flat)](https://swift.org/) [![SwiftUI](https://img.shields.io/badge/SwiftUI-✓-orange)](https://developer.apple.com/xcode/swiftui/) [![macOS 15](https://img.shields.io/badge/macOS_15-Sequoia-green)](https://www.apple.com/macos/macos-sequoia/) [![Platform](https://img.shields.io/badge/platform-macOS-blue)]() [![Version](https://img.shields.io/badge/version-1.0.8-blue)](https://github.com/anwen/IClick/releases)

**IClick** 是一款 macOS 右键菜单增强工具，为 Finder 添加丰富实用的右键操作，让你的文件管理效率翻倍。

---

## 📦 安装

最新安装包可以从 [发布页面](https://github.com/anwen/IClick/releases) 下载。

> **使用前请在「系统设置 → 隐私与安全性 → 扩展 → Finder 扩展」中启用 IClick 扩展。**

---

## ✨ 功能特性

### 🎯 右键操作

直接在 Finder 右键菜单中执行以下操作：

| 功能 | 说明 |
|------|------|
| 📋 **复制路径** | 快速复制文件或文件夹的完整路径到剪贴板 |
| 🗑️ **一键删除** | 直接删除文件或文件夹（自动保护系统目录） |
| 🌙 **隐藏文件** | 快速隐藏文件或文件夹（跳过系统保护目录） |
| ☀️ **取消隐藏** | 一键恢复隐藏的文件或文件夹 |
| ✈️ **AirDrop 分享** | 通过隔空投送快速分享文件 |
| ✂️ **剪切文件** | 剪切文件后在目标位置粘贴（移动操作） |
| 📄 **粘贴文件** | 粘贴已剪切/复制的文件到当前目录（支持系统剪贴板） |

所有操作均支持**拖拽排序**、**开关启用**，并支持**自定义图标**（SF Symbol 或自定义图片）。

### 🚀 用外部应用打开

将常用应用添加到右键菜单，一键用指定应用打开文件或文件夹。

- 支持**任何已安装的应用**（通过 NSOpenPanel 选择）
- 默认预置 **Terminal** 和 **VS Code**
- 支持设置**启动参数**（arguments）和**环境变量**（environment）
- 支持选择主菜单/子菜单显示模式
- 自动处理 macOS 系统应用路径（兼容 Cryptexes 安全卷）

### 📝 新建文件

在右键菜单中直接创建多种格式的文件：

| 格式 | 类型 |
|------|------|
| `.txt` | 纯文本 |
| `.json` | JSON 数据文件 |
| `.md` | Markdown 文档 |
| `.docx` | Word 文档 |
| `.pptx` | PowerPoint 演示文稿 |
| `.xlsx` | Excel 电子表格 |

- 文件名冲突时自动添加序号
- 支持自定义模板文件
- 支持自定义扩展名和关联应用

### 📂 常用路径

一键跳转到常用文件夹，无需层层点击 Finder。

- 支持**自定义添加**任意目录
- 从右键菜单直接打开
- 支持自定义名称和图标

### ⚙️ 设置中心

| 设置页 | 功能 |
|--------|------|
| **通用** | 扩展状态查看、登录时启动、菜单栏/Dock 图标显示开关 |
| **右键菜单** | 菜单项拖拽排序、开关控制、子菜单排列顺序编排 |
| **应用管理** | 添加/删除/编辑外部应用、自定义名称和图标、配置参数 |
| **文件类型** | 添加/删除/编辑新建文件类型、自定义默认文件名和图标 |
| **常用路径** | 添加/删除/编辑常用路径、自定义名称和图标 |
| **关于** | 应用版本信息、检查更新 |

---

## 📸 截图

<img src="./截图/b02d5bb5-1f42-4e55-81a3-c5557e9d734f.png" width="40%" style="margin-left:8%"> <img src="./截图/截屏2026-07-18 15.50.52.png" width="40%">
<img src="./截图/42c8ed16-0e44-4fb6-b2cd-eb1546544d92.png" width="100%"> <img src="./截图/5cc82c72-ff7a-4764-9a3d-95dd8e624f5a.png" width="100%">
<img src="./截图/8d51e4a1-dd6a-4f42-aecf-e3921073261d.png" width="100%"> <img src="./截图/b44a4a48-2659-4d02-91e8-3ca3379f0a8c.png" width="100%">

---

## 类似项目

- [SzContext](https://github.com/RoadToDream/SzContext)
- [OpenInTerminal](https://github.com/Ji4n1ng/OpenInTerminal)

---

## 💖 支持

如果你喜欢这个项目

---

## 🤝 问题反馈

发现 Bug 或有功能建议，欢迎在 [Issues](https://github.com/micolor/IClick/issues) 提交反馈。
