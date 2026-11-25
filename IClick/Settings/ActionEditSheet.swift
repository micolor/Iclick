import AppKit
import SwiftUI

// MARK: - 操作编辑 Sheet

enum ActionEditResult {
    case save(name: String, icon: String, requireSelection: Bool)
    /// 取消必须是独立结果：之前「取消」也走保存回调，会白写一次配置并递增
    /// 版本号，还能用弹窗打开时的旧快照把期间的外部改动顶回去。
    case cancel
}

struct ActionEditSheet: View {
    let action: RCAction
    let onResult: (ActionEditResult) -> Void

    @State private var actionName: String = ""
    @State private var actionIcon: String = ""
    @State private var requireSelection: Bool = false
    @State private var showIconPicker = false

    var body: some View {
        VStack(spacing: 0) {
            Text("编辑操作")
                .font(.headline)
                .padding()

            Divider()

            VStack(spacing: 0) {
                // 名称
                HStack(spacing: 6) {
                    Text("名称:")
                        .frame(width: 50, alignment: .trailing)
                    TextField("", text: $actionName)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider().padding(.horizontal)

                // 图标选择器
                HStack(spacing: 6) {
                    Text("图标:")
                        .frame(width: 50, alignment: .trailing)

                    Button {
                        showIconPicker = true
                    } label: {
                        HStack(spacing: 8) {
                            actionIconView(icon: actionIcon, size: 16)
                            Text("点击可修改")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        if let defaultAction = RCAction.all.first(where: { $0.id == action.id }) {
                            actionIcon = defaultAction.icon
                        }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        if let path = Utils.pickAndCopyIcon() {
                            actionIcon = path
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("从访达选择图标")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider().padding(.horizontal)

                // 仅选中文件时显示
                HStack(spacing: 6) {
                    Text("仅选中文件:")
                        .frame(width: 70, alignment: .trailing)
                    Toggle("", isOn: $requireSelection)
                        .labelsHidden()
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            Divider()

            HStack {
                Spacer()

                Button("取消") {
                    onResult(.cancel)
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    onResult(.save(name: actionName, icon: actionIcon, requireSelection: requireSelection))
                }
                .buttonStyle(.borderedProminent)
                .disabled(actionName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 380, height: 240)
        .sheet(isPresented: $showIconPicker) {
            IconPickerSheet(
                selectedIcon: $actionIcon,
                onDismiss: { showIconPicker = false }
            )
        }
        .onAppear {
            actionName = action.name
            actionIcon = action.icon
            requireSelection = action.requireSelection
        }
    }

    @ViewBuilder
    private func actionIconView(icon: String, size: CGFloat) -> some View {
        if RCAction.isCustomIcon(icon) {
            CustomIconView(path: icon, size: size)
        } else {
            // 使用 NSImage 渲染，与 FinderSync 扩展保持一致的分层着色
            let isEyeIcon = icon == "eye" || icon == "eye.fill" || icon == "eye.slash" || icon == "eye.slash.fill"
            if let nsImage = tintedSymbol(named: icon, color: RCAction.nsIconColor(for: icon), size: size, hierarchical: !isEyeIcon) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: icon)
                    .font(.system(size: size))
                    .foregroundStyle(RCAction.iconColor(for: icon))
                    .frame(width: size, height: size)
            }
        }
    }

    /// 与 FinderSync 扩展保持一致的分层着色方法。渲染与缓存统一在
    /// Utils.tintedSymbol（扩展与设置页共用同一份缓存），重复绘制同一图标
    /// 不再重新光栅化；字重沿用设置页原有的 .medium。
    private func tintedSymbol(named name: String, color: NSColor, size: CGFloat, hierarchical: Bool = true) -> NSImage? {
        Utils.tintedSymbol(named: name, color: color, size: size, weight: .medium, hierarchical: hierarchical)
    }
}

