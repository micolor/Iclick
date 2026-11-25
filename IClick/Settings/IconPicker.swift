import AppKit
import SwiftUI

// MARK: - 自定义图标视图

struct CustomIconView: View {
    let path: String
    let size: CGFloat

    var body: some View {
        Group {
            if let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 图标选择器 Sheet

struct IconPickerSheet: View {
    @Binding var selectedIcon: String
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var selectedCategory = "全部"

    /// 图标分类（static：分类表不随视图重建变化，下面的预计算也依赖它）
    private static let categories: [(name: String, items: [String])] = [
        ("全部", []),
        ("文件", [
            "doc", "doc.fill", "doc.text", "doc.plaintext", "doc.richtext",
            "doc.on.doc", "doc.on.doc.fill", "doc.badge.plus",
            "doc.badge.gearshape", "doc.badge.clock",
            "rectangle.and.paperclip", "paperclip", "link", "link.badge.plus",
            "folder", "folder.fill", "externaldrive", "externaldrive.fill",
        ]),
        ("通信", [
            "message", "message.fill", "bubble.left", "bubble.left.fill",
            "bubble.right", "bubble.right.fill", "envelope", "envelope.fill",
            "phone", "phone.fill", "paperplane", "paperplane.fill",
            "bell", "bell.fill", "bell.slash", "bell.slash.fill",
        ]),
        ("人物", [
            "person", "person.fill", "person.2", "person.2.fill",
            "person.circle", "person.circle.fill", "person.crop.circle",
            "person.crop.circle.fill", "person.badge.plus", "person.badge.minus",
            "person.3", "person.3.fill", "person.crop.square", "person.crop.square.fill",
        ]),
        ("设备", [
            "desktopcomputer", "laptopcomputer", "ipad", "iphone",
            "externaldrive", "externaldrive.fill", "internaldrive", "internaldrive.fill",
            "opticaldisc", "opticaldisc.fill",
            "printer", "printer.fill", "keyboard", "keyboard.fill",
            "computermouse", "computermouse.fill", "power", "power.circle.fill",
            "app.badge", "app.badge.fill", "app.badge.checkmark", "app.badge.checkmark.fill",
            "square.grid.2x2", "square.grid.3x2", "rectangle.grid.2x2",
        ]),
        ("媒体", [
            "photo", "photo.fill", "camera", "camera.fill",
            "video", "video.fill", "film", "film.fill",
            "music.note", "music.mic", "headphones", "speaker",
            "speaker.wave.2.fill", "mic", "mic.fill",
            "rectangle.stack", "rectangle.stack.fill", "play.rectangle", "play.rectangle.fill",
            "play.circle", "play.circle.fill", "pause.circle", "pause.circle.fill",
        ]),
        ("编辑", [
            "pencil", "pencil.circle.fill", "paintbrush", "paintbrush.fill",
            "scissors", "ruler", "ruler.fill", "hammer", "hammer.fill",
            "wrench", "wrench.fill",
            "textformat", "bold", "italic", "underline",
            "doc.on.doc", "doc.on.doc.fill",
            "character.cursor.ibeam", "textformat.size",
            "textformat.abc", "textformat.abc.dottedunderline",
        ]),
        ("天气", [
            "cloud", "cloud.fill", "cloud.rain", "cloud.rain.fill",
            "cloud.snow", "cloud.snow.fill", "cloud.bolt", "cloud.bolt.fill",
            "cloud.sun", "cloud.sun.fill", "cloud.moon", "cloud.moon.fill",
            "sun.max", "sun.max.fill", "moon", "moon.fill",
            "star", "star.fill", "thermometer.medium", "thermometer.high",
            "humidity", "wind", "drop", "drop.fill", "flame", "flame.fill",
            "leaf", "leaf.fill", "cloud.fog", "snowflake",
        ]),
        ("系统", [
            "gearshape", "gearshape.fill", "gearshape.2", "gearshape.2.fill",
            "gear", "slider.horizontal.3",
            "lock", "lock.fill", "lock.open", "lock.open.fill",
            "key", "key.fill", "shield", "shield.fill", "shield.checkered",
            "eye", "eye.slash", "eye.fill", "eye.slash.fill",
            "wifi", "antenna.radiowaves.left.and.right",
            "bolt", "bolt.fill", "bolt.slash", "bolt.slash.fill",
            "checkmark.circle", "checkmark.circle.fill",
            "xmark.circle", "xmark.circle.fill",
        ]),
        ("图形", [
            "square", "square.fill", "rectangle", "rectangle.fill",
            "circle", "circle.fill", "triangle", "triangle.fill",
            "diamond", "diamond.fill", "hexagon", "hexagon.fill",
            "octagon", "octagon.fill", "star.square", "star.square.fill",
            "heart", "heart.fill", "sparkles",
            "plus", "plus.circle", "plus.circle.fill",
            "minus", "minus.circle", "minus.circle.fill",
            "xmark", "xmark.circle", "xmark.circle.fill",
            "arrow.up", "arrow.down", "arrow.left", "arrow.right",
        ]),
    ]

    /// 每个分类「去重 + 排序」后的图标列表，进程内只算一次。
    ///
    /// 原实现把 `Array(Set(currentIcons)).sorted()` 写在 body 的 ForEach 里：
    /// 搜索框每敲一个字符、视图每刷新一次，都要对约 300 个字符串重新建 Set + 排序。
    private static let sortedIcons: [String: [String]] = {
        var result: [String: [String]] = [:]
        for category in categories where category.name != "全部" {
            result[category.name] = Array(Set(category.items)).sorted()
        }
        // 「全部」：按分类顺序合并并跨分类去重，再排序（与原来的输出一致）
        var all: [String] = []
        var seen = Set<String>()
        for category in categories.dropFirst() {
            for icon in category.items where seen.insert(icon).inserted {
                all.append(icon)
            }
        }
        result["全部"] = all.sorted()
        return result
    }()

    /// 当前分类下的图标（已预排序去重，这里只做搜索过滤）
    private var currentIcons: [String] {
        let icons = Self.sortedIcons[selectedCategory] ?? []
        if searchText.isEmpty {
            return icons
        }
        return icons.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("选择图标")
                    .font(.headline)

                Spacer()

                Color.clear.frame(width: 14, height: 14)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // 内容区域
            HStack(spacing: 0) {
                // 左侧分类列表
                VStack(spacing: 2) {
                    ForEach(Self.categories, id: \.name) { category in
                        Button {
                            selectedCategory = category.name
                        } label: {
                            Text(category.name)
                                .font(.system(size: 13))
                                .foregroundStyle(selectedCategory == category.name ? .white : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(selectedCategory == category.name ? Color.accentColor : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .offset(y: -4)
                .padding(.bottom, 6)
                .padding(.horizontal, 6)
                .frame(width: 90)

                // 右侧内容区
                VStack(spacing: 0) {
                    // 搜索框
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                        TextField("搜索", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                            )
                    )
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                    // 图标网格
                    if currentIcons.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                                .font(.title2)
                            Text("未找到匹配的图标")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                                ForEach(currentIcons, id: \.self) { icon in
                                    IconGridItem(
                                        icon: icon,
                                        isSelected: selectedIcon == icon
                                    ) {
                                        selectedIcon = icon
                                        onDismiss()
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                        }
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
            }
        }
        .frame(width: 420, height: 440)
    }
}

// MARK: - 图标网格项

struct IconGridItem: View {
    let icon: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                )
        }
        .buttonStyle(.plain)
        .help(icon)
    }
}

