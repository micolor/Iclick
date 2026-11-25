import AppKit
import SwiftUI

// MARK: - 子菜单编辑 Sheet

enum SubmenuEditResult {
    case save(name: String, icon: String)
    case cancel
}

struct SubmenuEditSheet: View {
    let id: String
    let name: String
    let icon: String
    let onResult: (SubmenuEditResult) -> Void

    @State private var submenuName: String = ""
    @State private var submenuIcon: String = ""
    @State private var showIconPicker = false

    var body: some View {
        VStack(spacing: 0) {
            Text("编辑子菜单")
                .font(.headline)
                .padding()

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("名称:")
                        .frame(width: 50, alignment: .trailing)
                    TextField("", text: $submenuName)
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
                            if submenuIcon.contains("/") {
                                CustomIconView(path: submenuIcon, size: 16)
                            } else {
                                Image(systemName: submenuIcon)
                                    .font(.system(size: 16))
                                    .foregroundStyle(submenuIconColor)
                                    .frame(width: 24, height: 24)
                            }
                            Text("点击可修改")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        submenuIcon = ActionSettingsTabView.defaultSubmenuIcons[id] ?? "folder"
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        if let path = Utils.pickAndCopyIcon() {
                            submenuIcon = path
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
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
                    onResult(.save(name: submenuName, icon: submenuIcon))
                }
                .buttonStyle(.borderedProminent)
                .disabled(submenuName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420, height: 200)
        .sheet(isPresented: $showIconPicker) {
            IconPickerSheet(
                selectedIcon: $submenuIcon,
                onDismiss: { showIconPicker = false }
            )
        }
        .onAppear {
            submenuName = name
            submenuIcon = icon
        }
    }

    private var submenuIconColor: Color {
        switch id {
        case "newFiles": return .blue
        case "submenuApps": return .purple
        case "commonDirs": return .green
        default: return .secondary
        }
    }
}
