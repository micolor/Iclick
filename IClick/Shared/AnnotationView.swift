//
//  AnnotationView.swift
//  IClick
//
//  Created by 李旭 on 2025/6/28.
//

import AppKit
import SwiftUI
import CoreImage

// MARK: - 标注工具类型

enum AnnotationTool: String, CaseIterable {
    case pen, arrow, rect, oval, mosaic, text
}

// MARK: - 标注元素

struct AnnotationElement: Identifiable {
    let id = UUID()
    let type: ElementType
    let color: Color
    let lineWidth: CGFloat
    let points: [CGPoint]       // freehand / mosaic
    let startPoint: CGPoint     // shape
    let endPoint: CGPoint       // shape
    let text: String?                 // text
    let textPosition: CGPoint?        // text

    enum ElementType: String {
        case freehand, arrow, rect, oval, mosaic, text
    }
}

// MARK: - 工具栏

struct AnnotationToolbar: View {
    @Binding var selectedTool: AnnotationTool
    @Binding var selectedColor: Color
    @Binding var selectedLineWidth: CGFloat
    let canUndo: Bool
    let onUndo: () -> Void
    let onRotateCW: () -> Void
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var showColorPopover = false
    @State private var windowDragStart: CGPoint?

    let presetColors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]

    var body: some View {
        HStack(spacing: 0) {
            // ——— 拖拽把手 ———
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.5))
                .padding(.trailing, 4)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let window = NSApp.keyWindow else { return }
                            if windowDragStart == nil {
                                windowDragStart = window.frame.origin
                            }
                            let origin = windowDragStart!
                            window.setFrameOrigin(NSPoint(
                                x: origin.x + value.translation.width,
                                y: origin.y - value.translation.height
                            ))
                        }
                        .onEnded { _ in windowDragStart = nil }
                )

            // ——— 工具 ———
            HStack(spacing: 2) {
                toolButton(icon: "rectangle",       tool: .rect)
                toolButton(icon: "circle",          tool: .oval)
                toolButton(icon: "arrow.right",     tool: .arrow)
                toolButton(icon: "pencil.tip",      tool: .pen)
                toolButton(icon: "character.cursor.ibeam", tool: .text)
                toolButton(icon: "square.grid.3x3.topleft.filled", tool: .mosaic)
            }

            Divider().frame(height: 26).padding(.horizontal, 6)

            // ——— 颜色 ———
            Button(action: { showColorPopover = true }) {
                Circle()
                    .fill(selectedColor)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.15), radius: 2)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showColorPopover, arrowEdge: .top) {
                colorPopoverContent
            }
            .help("选择颜色")

            // ——— 粗细：三个圆点 ———
            HStack(spacing: 6) {
                Circle().fill(selectedColor).frame(width: 4, height: 4).opacity(selectedLineWidth == 3 ? 1 : 0.4)
                    .onTapGesture { selectedLineWidth = 3 }
                    .help("细")

                Circle().fill(selectedColor).frame(width: 8, height: 8).opacity(selectedLineWidth == 6 ? 1 : 0.4)
                    .onTapGesture { selectedLineWidth = 6 }
                    .help("中")

                Circle().fill(selectedColor).frame(width: 13, height: 13).opacity(selectedLineWidth == 10 ? 1 : 0.4)
                    .onTapGesture { selectedLineWidth = 10 }
                    .help("粗")
            }
            .padding(.leading, 10)

            Divider().frame(height: 26).padding(.horizontal, 6)

            // ——— 旋转（系统标准图标） ———
            Button(action: onRotateCW) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("向右旋转 90°")

            Spacer()

            // ——— 操作 ———
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 14))
            }
            .disabled(!canUndo)
            .buttonStyle(.plain)
            .help("撤销")
            .padding(.trailing, 12)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)

            Button(action: onDone) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 26)
                    .background(Color.accentColor)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 工具按钮

    private func toolButton(icon: String, tool: AnnotationTool) -> some View {
        let isSelected = selectedTool == tool
        return Image(systemName: icon)
            .font(.system(size: 14))
            .frame(width: 32, height: 28)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.2))
            .contentShape(Rectangle())
            .onTapGesture { selectedTool = tool }
    }

    // MARK: - 颜色弹出

    private var colorPopoverContent: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(presetColors, id: \.self) { color in
                    Circle()
                        .fill(color)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .stroke(selectedColor == color ? Color.primary : Color.gray.opacity(0.3), lineWidth: selectedColor == color ? 3 : 1)
                        )
                        .onTapGesture {
                            selectedColor = color
                            showColorPopover = false
                        }
                }
            }

            Divider()

            HStack {
                Text("自定义")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                ColorPicker("", selection: $selectedColor, supportsOpacity: false)
                    .labelsHidden()
                    .scaleEffect(0.9)
            }
        }
        .padding(12)
        .frame(width: 170)
    }
}

// MARK: - 主标注视图

struct AnnotationView: View {
    let tempURL: URL

    @State private var image: NSImage
    @State private var pixelatedImage: Image?      // 马赛克预览用
    @State private var pixelatedNSImage: NSImage?  // 马赛克导出用

    @State private var elements: [AnnotationElement] = []
    @State private var selectedTool: AnnotationTool = .pen
    @State private var selectedColor: Color = .red
    @State private var selectedLineWidth: CGFloat = 6

    // 当前绘制中的元素
    @State private var currentPoints: [CGPoint] = []
    @State private var currentShapeStart: CGPoint?
    @State private var currentShapeEnd: CGPoint?
    @State private var isDrawing = false

    // 文字输入
    @State private var showTextInput = false
    @State private var textInput = ""
    @State private var pendingTextPosition: CGPoint = .zero

    init(image: NSImage, tempURL: URL) {
        self.tempURL = tempURL
        self._image = State(initialValue: image)
        let (pix, nsPix) = Self.makePixelated(from: image)
        self._pixelatedImage = State(initialValue: pix)
        self._pixelatedNSImage = State(initialValue: nsPix)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 图片区域
            GeometryReader { geo in
                let viewSize = geo.size
                let imgSize = image.size
                let s = min(viewSize.width / max(imgSize.width, 1), viewSize.height / max(imgSize.height, 1))
                let scaledW = imgSize.width * s
                let scaledH = imgSize.height * s

                ZStack {
                    Color.black.opacity(0.06)
                        .ignoresSafeArea()

                    // 原图
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: scaledW, height: scaledH)

                    // 马赛克覆盖层（用 mask 只显示涂抹区域）
                    if let pix = pixelatedNSImage {
                        Image(nsImage: pix)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: scaledW, height: scaledH)
                            .mask(
                                Canvas { context, size in
                                    let sx = size.width / max(imgSize.width, 1)
                                    let sy = size.height / max(imgSize.height, 1)
                                    context.scaleBy(x: sx, y: sy)

                                    for el in elements where el.type == .mosaic {
                                        let rect = CGRect(x: min(el.startPoint.x, el.endPoint.x),
                                                          y: min(el.startPoint.y, el.endPoint.y),
                                                          width: abs(el.endPoint.x - el.startPoint.x),
                                                          height: abs(el.endPoint.y - el.startPoint.y))
                                        guard rect.width > 2 || rect.height > 2 else { continue }
                                        context.fill(Path(roundedRect: rect, cornerSize: .zero), with: .color(.black))
                                    }
                                }
                                    .frame(width: scaledW, height: scaledH)
                            )
                    }

                    // 标注层（不含马赛克元素）
                    AnnotationOverlay(
                        elements: elements.filter { $0.type != .mosaic },
                        currentPoints: currentPoints,
                        currentShapeStart: currentShapeStart,
                        currentShapeEnd: currentShapeEnd,
                        selectedTool: selectedTool,
                        selectedColor: selectedColor,
                        selectedLineWidth: selectedLineWidth,
                        imgSize: imgSize
                    )
                    .frame(width: scaledW, height: scaledH)
                }
                .frame(width: viewSize.width, height: viewSize.height)
                .overlay(
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let imgW = imgSize.width
                                    let imgH = imgSize.height
                                    let offsetX = (viewSize.width - scaledW) / 2
                                    let offsetY = (viewSize.height - scaledH) / 2
                                    let pt = CGPoint(
                                        x: (value.location.x - offsetX) / s,
                                        y: (value.location.y - offsetY) / s
                                    )
                                    guard pt.x >= -5, pt.y >= -5, pt.x <= imgW + 5, pt.y <= imgH + 5 else { return }

                                    // 文字工具：点击定位，不走拖拽绘制
                                    if selectedTool == .text { return }

                                    // pen 走自由轨迹，其他走形状
                                    let isFreehand = selectedTool == .pen
                                    if !isDrawing {
                                        isDrawing = true
                                        if isFreehand {
                                            currentPoints = [pt]
                                        } else {
                                            currentShapeStart = pt
                                            currentShapeEnd = pt
                                        }
                                    } else {
                                        if isFreehand {
                                            currentPoints.append(pt)
                                        } else {
                                            currentShapeEnd = pt
                                        }
                                    }
                                }
                                .onEnded { value in
                                    if selectedTool == .text {
                                        let imgW = imgSize.width
                                        let imgH = imgSize.height
                                        let offsetX = (viewSize.width - scaledW) / 2
                                        let offsetY = (viewSize.height - scaledH) / 2
                                        let pt = CGPoint(
                                            x: (value.location.x - offsetX) / s,
                                            y: (value.location.y - offsetY) / s
                                        )
                                        guard pt.x >= -5, pt.y >= -5, pt.x <= imgW + 5, pt.y <= imgH + 5 else { return }
                                        pendingTextPosition = pt
                                        textInput = ""
                                        showTextInput = true
                                        return
                                    }
                                    finalizeStroke()
                                }
                        )
                )
            }

            // 工具栏（底部）
            AnnotationToolbar(
                selectedTool: $selectedTool,
                selectedColor: $selectedColor,
                selectedLineWidth: $selectedLineWidth,
                canUndo: !elements.isEmpty,
                onUndo: { elements.removeLast() },
                onRotateCW: { rotate(clockwise: true) },
                onDone: { exportAndClose() },
                onCancel: { cleanUpAndClose() }
            )
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(Divider(), alignment: .top)
        }
        .onExitCommand { cleanUpAndClose() }
        .frame(minWidth: 200, minHeight: 100)
        .sheet(isPresented: $showTextInput) {
            textInputSheet
        }
    }

    // MARK: - 文字输入弹窗

    private var textInputSheet: some View {
        VStack(spacing: 16) {
            Text("输入文字")
                .font(.headline)

            TextField("在此输入文字…", text: $textInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
                .onSubmit { confirmText() }

            HStack(spacing: 12) {
                Button("取消") { showTextInput = false }
                    .keyboardShortcut(.escape)

                Button("确定") { confirmText() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func confirmText() {
        guard !textInput.isEmpty else { return }
        elements.append(AnnotationElement(
            type: .text, color: selectedColor, lineWidth: 28,
            points: [], startPoint: .zero, endPoint: .zero,
            text: textInput, textPosition: pendingTextPosition
        ))
        showTextInput = false
    }

    // MARK: - 旋转

    private func rotate(clockwise: Bool) {
        let w = image.size.width
        let h = image.size.height

        // 变换已有标注
        elements = elements.map { rotateAnnotation($0, w: w, h: h, cw: clockwise) }

        // 变换当前绘制中的点
        if !currentPoints.isEmpty {
            currentPoints = currentPoints.map { pt in
                clockwise
                    ? CGPoint(x: h - pt.y, y: pt.x)
                    : CGPoint(x: pt.y, y: w - pt.x)
            }
        }
        if let start = currentShapeStart {
            currentShapeStart = clockwise
                ? CGPoint(x: h - start.y, y: start.x)
                : CGPoint(x: start.y, y: w - start.x)
        }
        if let end = currentShapeEnd {
            currentShapeEnd = clockwise
                ? CGPoint(x: h - end.y, y: end.x)
                : CGPoint(x: end.y, y: w - end.x)
        }

        // 旋转图片数据
        image = rotatedImage(image, clockwise: clockwise)

        // 重新生成马赛克图
        let (pix, nsPix) = Self.makePixelated(from: image)
        pixelatedImage = pix
        pixelatedNSImage = nsPix
    }

    /// 用 Core Image 生成马赛克像素化图
    private static func makePixelated(from image: NSImage, blockSize: CGFloat = 8) -> (Image?, NSImage?) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return (nil, nil) }

        let ciImage = CIImage(cgImage: cgImage)
        let filter = CIFilter(name: "CIPixellate")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(Float(blockSize), forKey: kCIInputScaleKey)

        guard let outputImage = filter.outputImage,
              let cgOutput = CIContext().createCGImage(outputImage, from: outputImage.extent) else { return (nil, nil) }

        let pixelated = NSImage(cgImage: cgOutput, size: image.size)
        return (Image(nsImage: pixelated), pixelated)
    }

    private func rotatedImage(_ image: NSImage, clockwise: Bool) -> NSImage {
        let w = image.size.width
        let h = image.size.height
        let rotated = NSImage(size: NSSize(width: h, height: w))
        rotated.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.translateBy(x: h / 2, y: w / 2)
        ctx.rotate(by: clockwise ? .pi / 2 : -.pi / 2)
        image.draw(at: NSPoint(x: -w / 2, y: -h / 2), from: .zero, operation: .copy, fraction: 1)
        rotated.unlockFocus()
        return rotated
    }

    private func rotateAnnotation(_ el: AnnotationElement, w: CGFloat, h: CGFloat, cw: Bool) -> AnnotationElement {
        let transform: (CGPoint) -> CGPoint = { pt in
            cw
                ? CGPoint(x: h - pt.y, y: pt.x)
                : CGPoint(x: pt.y, y: w - pt.x)
        }
        switch el.type {
        case .freehand:
            return AnnotationElement(type: el.type, color: el.color, lineWidth: el.lineWidth,
                                     points: el.points.map(transform), startPoint: .zero, endPoint: .zero,
                                     text: nil, textPosition: nil)
        case .mosaic, .arrow, .rect, .oval:
            return AnnotationElement(type: el.type, color: el.color, lineWidth: el.lineWidth,
                                     points: [], startPoint: transform(el.startPoint), endPoint: transform(el.endPoint),
                                     text: nil, textPosition: nil)
        case .text:
            guard let pos = el.textPosition else { return el }
            return AnnotationElement(type: .text, color: el.color, lineWidth: el.lineWidth,
                                     points: [], startPoint: .zero, endPoint: .zero,
                                     text: el.text, textPosition: transform(pos))
        }
    }

    // MARK: - 完成笔画

    private func finalizeStroke() {
        guard isDrawing else { return }
        isDrawing = false

        if selectedTool == .pen && currentPoints.count > 1 {
            elements.append(AnnotationElement(type: .freehand, color: selectedColor, lineWidth: selectedLineWidth,
                                               points: currentPoints, startPoint: .zero, endPoint: .zero,
                                               text: nil, textPosition: nil))
        } else if let start = currentShapeStart, let end = currentShapeEnd {
            let type: AnnotationElement.ElementType = switch selectedTool {
            case .arrow: .arrow
            case .rect: .rect
            case .oval: .oval
            case .mosaic: .mosaic
            default: .arrow
            }
            if abs(end.x - start.x) > 2 || abs(end.y - start.y) > 2 {
                elements.append(AnnotationElement(type: type, color: selectedColor, lineWidth: selectedLineWidth,
                                                   points: [], startPoint: start, endPoint: end,
                                                   text: nil, textPosition: nil))
            }
        }
        currentPoints = []
        currentShapeStart = nil
        currentShapeEnd = nil
    }

    // MARK: - 导出

    private func exportAndClose() {
        let imgSize = image.size
        let result = NSImage(size: imgSize)
        result.lockFocus()

        image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)

        guard let ctx = NSGraphicsContext.current?.cgContext else {
            result.unlockFocus()
            return
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for el in elements {
            switch el.type {
            case .mosaic:
                guard let pix = pixelatedNSImage else { continue }
                let rect = CGRect(x: min(el.startPoint.x, el.endPoint.x),
                                  y: min(el.startPoint.y, el.endPoint.y),
                                  width: abs(el.endPoint.x - el.startPoint.x),
                                  height: abs(el.endPoint.y - el.startPoint.y))
                guard rect.width > 2 || rect.height > 2 else { continue }
                ctx.saveGState()
                ctx.clip(to: rect)
                pix.draw(in: NSRect(origin: .zero, size: pix.size),
                         from: .zero, operation: .copy, fraction: 1)
                ctx.restoreGState()

            case .freehand:
                ctx.setStrokeColor(NSColor(el.color).cgColor)
                ctx.setLineWidth(el.lineWidth)
                guard el.points.count > 1 else { continue }
                ctx.beginPath()
                ctx.move(to: el.points[0])
                for pt in el.points.dropFirst() { ctx.addLine(to: pt) }
                ctx.strokePath()

            case .arrow:
                ctx.setStrokeColor(NSColor(el.color).cgColor)
                ctx.setLineWidth(el.lineWidth)
                ctx.beginPath()
                ctx.move(to: el.startPoint); ctx.addLine(to: el.endPoint)
                ctx.strokePath()
                let angle = atan2(el.endPoint.y - el.startPoint.y, el.endPoint.x - el.startPoint.x)
                let arrowLen: CGFloat = 15, arrowAngle: CGFloat = .pi / 6
                ctx.beginPath()
                ctx.move(to: el.endPoint)
                ctx.addLine(to: CGPoint(x: el.endPoint.x - arrowLen * cos(angle - arrowAngle),
                                        y: el.endPoint.y - arrowLen * sin(angle - arrowAngle)))
                ctx.move(to: el.endPoint)
                ctx.addLine(to: CGPoint(x: el.endPoint.x - arrowLen * cos(angle + arrowAngle),
                                        y: el.endPoint.y - arrowLen * sin(angle + arrowAngle)))
                ctx.strokePath()

            case .rect:
                ctx.setStrokeColor(NSColor(el.color).cgColor)
                ctx.setLineWidth(el.lineWidth)
                let rect = CGRect(x: min(el.startPoint.x, el.endPoint.x),
                                  y: min(el.startPoint.y, el.endPoint.y),
                                  width: abs(el.endPoint.x - el.startPoint.x),
                                  height: abs(el.endPoint.y - el.startPoint.y))
                ctx.stroke(rect)

            case .oval:
                ctx.setStrokeColor(NSColor(el.color).cgColor)
                ctx.setLineWidth(el.lineWidth)
                let rect = CGRect(x: min(el.startPoint.x, el.endPoint.x),
                                  y: min(el.startPoint.y, el.endPoint.y),
                                  width: abs(el.endPoint.x - el.startPoint.x),
                                  height: abs(el.endPoint.y - el.startPoint.y))
                ctx.strokeEllipse(in: rect)

            case .text:
                guard let text = el.text, let pos = el.textPosition else { continue }
                let fontSize = el.lineWidth
                let font = NSFont.systemFont(ofSize: fontSize)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor(el.color)
                ]
                (text as NSString).draw(at: pos, withAttributes: attributes)
            }
        }

        result.unlockFocus()

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([result])

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let saveURL = desktopURL.appendingPathComponent("截图_\(timestamp).png")
        if let data = result.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: data) {
            let pngData = bitmap.representation(using: .png, properties: [:])
            try? pngData?.write(to: saveURL)
        }

        try? FileManager.default.removeItem(at: tempURL)
        NSApp.keyWindow?.close()

        let notification = NSUserNotification()
        notification.title = "标注截图完成"
        notification.informativeText = "已复制到剪贴板并保存到桌面"
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func cleanUpAndClose() {
        try? FileManager.default.removeItem(at: tempURL)
        NSApp.keyWindow?.close()
    }
}

// MARK: - 标注覆盖层（双 Canvas：马赛克层 + 标注层）

struct AnnotationOverlay: View {
    let elements: [AnnotationElement]
    let currentPoints: [CGPoint]
    let currentShapeStart: CGPoint?
    let currentShapeEnd: CGPoint?
    let selectedTool: AnnotationTool
    let selectedColor: Color
    let selectedLineWidth: CGFloat
    let imgSize: CGSize

    var body: some View {
        ZStack {
            // 标注层
            Canvas { context, size in
                let sx = size.width / max(imgSize.width, 1)
                let sy = size.height / max(imgSize.height, 1)
                let scale = min(sx, sy)

                context.scaleBy(x: sx, y: sy)

                for el in elements where el.type != .mosaic {
                    drawAnnotation(element: el, in: &context, scale: scale)
                }

                // 实时预览
                if let start = currentShapeStart, let end = currentShapeEnd {
                    let p = shapePath(start: start, end: end, tool: selectedTool)
                    context.stroke(p, with: .color(selectedColor), lineWidth: selectedLineWidth / scale)
                }
                if !currentPoints.isEmpty && selectedTool == .pen {
                    let p = Path { path in
                        path.move(to: currentPoints[0])
                        for pt in currentPoints.dropFirst() { path.addLine(to: pt) }
                    }
                    context.stroke(p, with: .color(selectedColor), lineWidth: selectedLineWidth / scale)
                }
            }
        }
    }

    // MARK: - 标注绘制

    private func drawAnnotation(element: AnnotationElement, in context: inout GraphicsContext, scale: CGFloat) {
        switch element.type {
        case .freehand:
            let p = Path { path in
                guard element.points.count > 1 else { return }
                path.move(to: element.points[0])
                for pt in element.points.dropFirst() { path.addLine(to: pt) }
            }
            context.stroke(p, with: .color(element.color), lineWidth: element.lineWidth / scale)

        case .arrow:
            let p = Path { path in
                arrowPath(start: element.startPoint, end: element.endPoint, path: &path)
            }
            context.stroke(p, with: .color(element.color), lineWidth: element.lineWidth / scale)

        case .rect:
            let p = Path { path in
                rectPath(start: element.startPoint, end: element.endPoint, path: &path)
            }
            context.stroke(p, with: .color(element.color), lineWidth: element.lineWidth / scale)

        case .oval:
            let p = Path { path in
                ovalPath(start: element.startPoint, end: element.endPoint, path: &path)
            }
            context.stroke(p, with: .color(element.color), lineWidth: element.lineWidth / scale)

        case .text:
            guard let text = element.text, let pos = element.textPosition else { return }
            let fontSize = element.lineWidth / scale
            context.draw(
                Text(text)
                    .font(.system(size: fontSize))
                    .foregroundColor(element.color),
                at: pos,
                anchor: .topLeading
            )

        default:
            break
        }
    }

    private func shapePath(start: CGPoint, end: CGPoint, tool: AnnotationTool) -> Path {
        Path { path in
            switch tool {
            case .arrow: arrowPath(start: start, end: end, path: &path)
            case .rect, .mosaic: rectPath(start: start, end: end, path: &path)
            case .oval: ovalPath(start: start, end: end, path: &path)
            default: break
            }
        }
    }

    private func arrowPath(start: CGPoint, end: CGPoint, path: inout Path) {
        path.move(to: start)
        path.addLine(to: end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLen: CGFloat = 15, arrowAngle: CGFloat = .pi / 6
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - arrowLen * cos(angle - arrowAngle),
                                 y: end.y - arrowLen * sin(angle - arrowAngle)))
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - arrowLen * cos(angle + arrowAngle),
                                 y: end.y - arrowLen * sin(angle + arrowAngle)))
    }

    private func rectPath(start: CGPoint, end: CGPoint, path: inout Path) {
        path.addRect(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                            width: abs(end.x - start.x), height: abs(end.y - start.y)))
    }

    private func ovalPath(start: CGPoint, end: CGPoint, path: inout Path) {
        path.addEllipse(in: CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                   width: abs(end.x - start.x), height: abs(end.y - start.y)))
    }
}
