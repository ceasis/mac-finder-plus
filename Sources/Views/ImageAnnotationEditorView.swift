import AppKit
import SwiftUI

struct ImageAnnotationEditorView: View {
    @Environment(AppState.self) private var appState

    private let title: String
    private let imageURL: URL
    private let saveButtonTitle: String
    private let onCancel: (() -> Void)?
    private let onSaveURL: ((URL) -> Void)?

    @State private var image: NSImage?
    @State private var imageSize = CGSize(width: 1, height: 1)
    @State private var marks: [ImageAnnotationMark] = []
    @State private var draftMark: ImageAnnotationMark?
    @State private var tool: ImageAnnotationTool = .arrow
    @State private var selectedColor = AnnotationColor.red
    @State private var lineWidth = 5.0
    @State private var annotationText = "Text"
    @State private var selectedMarkID: ImageAnnotationMark.ID?
    @State private var undoStack: [[ImageAnnotationMark]] = []
    @State private var redoStack: [[ImageAnnotationMark]] = []
    @State private var errorMessage: String?

    init(target: FileItem) {
        self.title = target.name
        self.imageURL = target.url
        self.saveButtonTitle = "Save Copy"
        self.onCancel = nil
        self.onSaveURL = nil
    }

    init(
        title: String,
        imageURL: URL,
        saveButtonTitle: String = "Save",
        onCancel: @escaping () -> Void,
        onSave: @escaping (URL) -> Void
    ) {
        self.title = title
        self.imageURL = imageURL
        self.saveButtonTitle = saveButtonTitle
        self.onCancel = onCancel
        self.onSaveURL = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let image {
                AnnotationCanvas(
                    image: image,
                    imageSize: imageSize,
                    marks: $marks,
                    draftMark: $draftMark,
                    selectedMarkID: $selectedMarkID,
                    tool: tool,
                    color: selectedColor,
                    lineWidth: lineWidth,
                    annotationText: annotationText,
                    recordUndo: recordUndoSnapshot
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, idealWidth: 980, minHeight: 560, idealHeight: 700)
        .task(id: imageURL) { loadImage() }
        .alert("Annotation Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 180, idealWidth: 260, maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    Button {
                        undoEdit()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(undoStack.isEmpty)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo")
                    .frame(width: 30, height: 30)

                    Button {
                        redoEdit()
                    } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(redoStack.isEmpty)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("Redo")
                    .frame(width: 30, height: 30)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)

                toolbarSeparator

                HStack(spacing: 4) {
                    Button {
                        duplicateSelectedMark()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .disabled(selectedMarkIndex == nil)
                    .keyboardShortcut("d", modifiers: .command)
                    .help("Duplicate selected annotation")
                    .frame(width: 30, height: 30)

                    Button {
                        sendSelectedBackward()
                    } label: {
                        Label("Send Backward", systemImage: "square.2.layers.3d.bottom.filled")
                    }
                    .disabled(!canSendSelectedBackward)
                    .help("Send selected annotation backward")
                    .frame(width: 30, height: 30)

                    Button {
                        bringSelectedForward()
                    } label: {
                        Label("Bring Forward", systemImage: "square.2.layers.3d.top.filled")
                    }
                    .disabled(!canBringSelectedForward)
                    .help("Bring selected annotation forward")
                    .frame(width: 30, height: 30)

                    Button {
                        deleteSelectedMark()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selectedMarkIndex == nil)
                    .keyboardShortcut(.delete, modifiers: [])
                    .help("Delete selected annotation")
                    .frame(width: 30, height: 30)

                    Button {
                        clearMarks()
                    } label: {
                        Label("Clear", systemImage: "trash.slash")
                    }
                    .disabled(marks.isEmpty)
                    .help("Clear annotations")
                    .frame(width: 30, height: 30)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)

                Button("Cancel") {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)
                .help("Cancel annotation")

                Button {
                    save()
                } label: {
                    Label(saveButtonTitle, systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(marks.isEmpty || image == nil)
                .help("Save annotated copy")
            }

            HStack(spacing: 12) {
                Picker("Tool", selection: toolBinding) {
                    ForEach(ImageAnnotationTool.allCases) { item in
                        Image(systemName: item.systemImage)
                            .tag(item)
                            .help(item.title)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 216)
                .help("Annotation tool")

                toolbarSeparator

                HStack(spacing: 6) {
                    ForEach(AnnotationColor.presets) { color in
                        ColorSwatchButton(
                            color: color,
                            isSelected: color == activeColor
                        ) {
                            applyColor(color)
                        }
                    }
                }

                toolbarSeparator

                HStack(spacing: 6) {
                    Image(systemName: "lineweight")
                        .foregroundStyle(.secondary)
                    Slider(value: lineWidthBinding, in: 2...14, step: 1)
                        .frame(width: 110)
                    Text("\(Int(activeLineWidth))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                }
                .help("Line width")

                if activeTool == .text {
                    TextField("Text", text: textBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .help("Text label")
                }

                Spacer(minLength: 8)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var toolbarSeparator: some View {
        Divider()
            .frame(height: 22)
    }

    private var selectedMarkIndex: Int? {
        guard let selectedMarkID else { return nil }
        return marks.firstIndex { $0.id == selectedMarkID }
    }

    private var canSendSelectedBackward: Bool {
        guard let index = selectedMarkIndex else { return false }
        return index > 0
    }

    private var canBringSelectedForward: Bool {
        guard let index = selectedMarkIndex else { return false }
        return index < marks.count - 1
    }

    private var activeTool: ImageAnnotationTool {
        selectedMarkIndex.map { marks[$0].tool } ?? tool
    }

    private var activeColor: AnnotationColor {
        selectedMarkIndex.map { marks[$0].color } ?? selectedColor
    }

    private var activeLineWidth: Double {
        selectedMarkIndex.map { marks[$0].lineWidth } ?? lineWidth
    }

    private var toolBinding: Binding<ImageAnnotationTool> {
        Binding(
            get: { activeTool },
            set: { newTool in
                if let index = selectedMarkIndex {
                    recordUndoSnapshot()
                    marks[index].tool = newTool
                    if newTool == .text,
                       marks[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        marks[index].text = annotationText
                    }
                } else {
                    tool = newTool
                }
            }
        )
    }

    private var lineWidthBinding: Binding<Double> {
        Binding(
            get: { activeLineWidth },
            set: { newValue in
                if let index = selectedMarkIndex {
                    recordUndoSnapshot()
                    marks[index].lineWidth = newValue
                } else {
                    lineWidth = newValue
                }
            }
        )
    }

    private var textBinding: Binding<String> {
        Binding(
            get: {
                if let index = selectedMarkIndex {
                    let text = marks[index].text
                    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Text" : text
                }
                return annotationText
            },
            set: { newValue in
                if let index = selectedMarkIndex {
                    recordUndoSnapshot()
                    marks[index].text = newValue
                } else {
                    annotationText = newValue
                }
            }
        )
    }

    private func applyColor(_ color: AnnotationColor) {
        if let index = selectedMarkIndex {
            recordUndoSnapshot()
            marks[index].color = color
        } else {
            selectedColor = color
        }
    }

    private func recordUndoSnapshot() {
        guard undoStack.last != marks else { return }
        undoStack.append(marks)
        if undoStack.count > 80 {
            undoStack.removeFirst(undoStack.count - 80)
        }
        redoStack.removeAll()
    }

    private func undoEdit() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(marks)
        marks = previous
        pruneSelection()
    }

    private func redoEdit() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(marks)
        marks = next
        pruneSelection()
    }

    private func clearMarks() {
        guard !marks.isEmpty else { return }
        recordUndoSnapshot()
        marks.removeAll()
        selectedMarkID = nil
    }

    private func deleteSelectedMark() {
        guard let index = selectedMarkIndex else { return }
        recordUndoSnapshot()
        marks.remove(at: index)
        selectedMarkID = nil
    }

    private func duplicateSelectedMark() {
        guard let index = selectedMarkIndex else { return }
        recordUndoSnapshot()
        let original = marks[index]
        let duplicate = ImageAnnotationMark(
            tool: original.tool,
            start: offset(original.start, by: 0.025),
            end: offset(original.end, by: 0.025),
            text: original.text,
            color: original.color,
            lineWidth: original.lineWidth
        )
        marks.insert(duplicate, at: index + 1)
        selectedMarkID = duplicate.id
    }

    private func sendSelectedBackward() {
        guard let index = selectedMarkIndex, index > 0 else { return }
        recordUndoSnapshot()
        marks.swapAt(index, index - 1)
    }

    private func bringSelectedForward() {
        guard let index = selectedMarkIndex, index < marks.count - 1 else { return }
        recordUndoSnapshot()
        marks.swapAt(index, index + 1)
    }

    private func offset(_ point: AnnotationPoint, by amount: Double) -> AnnotationPoint {
        AnnotationPoint(
            x: min(max(point.x + amount, 0), 1),
            y: min(max(point.y + amount, 0), 1)
        )
    }

    private func pruneSelection() {
        if let selectedMarkID, !marks.contains(where: { $0.id == selectedMarkID }) {
            self.selectedMarkID = nil
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func loadImage() {
        guard let loadedImage = NSImage(contentsOf: imageURL) else {
            errorMessage = "“\(title)” could not be opened as an image."
            return
        }
        image = loadedImage
        imageSize = ImageAnnotationRenderer.pixelSize(for: loadedImage)
    }

    private func cancel() {
        if let onCancel {
            onCancel()
        } else {
            appState.annotationTarget = nil
        }
    }

    private func save() {
        guard let image else { return }
        do {
            let output = try ImageAnnotationRenderer.export(
                image: image,
                sourceURL: imageURL,
                marks: marks
            )
            if let onSaveURL {
                onSaveURL(output)
            } else {
                // annotationDidSave clears annotationTarget, which closes the modal.
                appState.annotationDidSave(output)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ColorSwatchButton: View {
    let color: AnnotationColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.swiftUIColor)
                .frame(width: 20, height: 20)
                .overlay {
                    Circle()
                        .stroke(
                            isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 3 : 1
                        )
                }
                .overlay {
                    if color == .white {
                        Circle()
                            .stroke(Color.black.opacity(0.18), lineWidth: 1)
                            .padding(2)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
        .help(color.name)
    }
}

private enum AnnotationCanvasDragMode {
    case move
    case resizeStart
    case resizeEnd
}

private struct AnnotationCanvas: View {
    let image: NSImage
    let imageSize: CGSize
    @Binding var marks: [ImageAnnotationMark]
    @Binding var draftMark: ImageAnnotationMark?
    @Binding var selectedMarkID: ImageAnnotationMark.ID?
    let tool: ImageAnnotationTool
    let color: AnnotationColor
    let lineWidth: Double
    let annotationText: String
    let recordUndo: () -> Void

    @State private var dragStart: AnnotationPoint?
    @State private var movingMarkID: ImageAnnotationMark.ID?
    @State private var movingOriginalMark: ImageAnnotationMark?
    @State private var dragMode: AnnotationCanvasDragMode?
    @State private var didRecordUndoForDrag = false

    var body: some View {
        GeometryReader { proxy in
            let imageRect = fittedRect(for: imageSize, in: proxy.size)
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                    AnnotationMarksLayer(
                        marks: marks,
                        draftMark: draftMark,
                        selectedMarkID: selectedMarkID
                    )
                        .allowsHitTesting(false)
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(dragGesture(in: imageRect.size))
                }
                .frame(width: imageRect.width, height: imageRect.height)
                .position(x: imageRect.midX, y: imageRect.midY)
                .shadow(color: .black.opacity(0.12), radius: 9, y: 2)
            }
        }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let current = normalized(value.location, in: size)
                if dragStart == nil {
                    dragStart = current
                    if let selectedMarkID,
                       let selectedMark = marks.first(where: { $0.id == selectedMarkID }),
                       let mode = hitResizeHandle(at: current, in: size, for: selectedMark) {
                        movingMarkID = selectedMark.id
                        movingOriginalMark = selectedMark
                        dragMode = mode
                        draftMark = nil
                        return
                    }
                    if let mark = hitMark(at: current, in: size) {
                        selectedMarkID = mark.id
                        movingMarkID = mark.id
                        movingOriginalMark = mark
                        dragMode = .move
                        draftMark = nil
                        return
                    }
                    selectedMarkID = nil
                }

                if let movingMarkID,
                   let movingOriginalMark,
                   let dragStart,
                   let dragMode {
                    if dragDistance(from: dragStart, to: current, in: size) >= 1 {
                        transformMark(
                            id: movingMarkID,
                            from: movingOriginalMark,
                            dragStart: dragStart,
                            current: current,
                            mode: dragMode
                        )
                    }
                    return
                }

                let start = dragStart ?? current
                draftMark = mark(start: start, end: current)
            }
            .onEnded { value in
                let current = normalized(value.location, in: size)
                if let movingMarkID,
                   let movingOriginalMark,
                   let dragStart,
                   let dragMode {
                    guard dragDistance(from: dragStart, to: current, in: size) >= 1 else {
                        resetDragState()
                        return
                    }
                    transformMark(
                        id: movingMarkID,
                        from: movingOriginalMark,
                        dragStart: dragStart,
                        current: current,
                        mode: dragMode
                    )
                    resetDragState()
                    return
                }

                let start = dragStart ?? current
                if tool != .text, dragDistance(from: start, to: current, in: size) < 2 {
                    resetDragState()
                    return
                }
                recordUndo()
                let newMark = mark(start: start, end: current)
                marks.append(newMark)
                selectedMarkID = newMark.id
                resetDragState()
            }
    }

    private func mark(start: AnnotationPoint, end: AnnotationPoint) -> ImageAnnotationMark {
        ImageAnnotationMark(
            tool: tool,
            start: start,
            end: end,
            text: annotationText,
            color: color,
            lineWidth: lineWidth
        )
    }

    private func normalized(_ location: CGPoint, in size: CGSize) -> AnnotationPoint {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let x = min(max(location.x, 0), width) / width
        let y = min(max(location.y, 0), height) / height
        return AnnotationPoint(x: Double(x), y: Double(y))
    }

    private func hitMark(at point: AnnotationPoint, in size: CGSize) -> ImageAnnotationMark? {
        let hitPoint = CGPoint(
            x: CGFloat(point.x) * size.width,
            y: CGFloat(point.y) * size.height
        )
        for mark in marks.reversed() {
            let isHit: Bool
            switch mark.tool {
            case .text:
                isHit = textHitRect(for: mark, in: size).contains(hitPoint)
            case .rectangle, .ellipse, .highlight:
                isHit = rect(for: mark, in: size)
                    .insetBy(dx: -hitPadding(for: mark), dy: -hitPadding(for: mark))
                    .contains(hitPoint)
            case .arrow, .line:
                isHit = distance(
                    from: hitPoint,
                    toSegmentFrom: canvasPoint(for: mark.start, in: size),
                    to: canvasPoint(for: mark.end, in: size)
                ) <= hitPadding(for: mark)
            }
            if isHit { return mark }
        }
        return nil
    }

    private func hitResizeHandle(
        at point: AnnotationPoint,
        in size: CGSize,
        for mark: ImageAnnotationMark
    ) -> AnnotationCanvasDragMode? {
        guard mark.tool != .text else { return nil }
        let hitPoint = canvasPoint(for: point, in: size)
        let start = canvasPoint(for: mark.start, in: size)
        let end = canvasPoint(for: mark.end, in: size)
        let radius = max(CGFloat(mark.lineWidth) * 1.7, 10)
        if hypot(hitPoint.x - end.x, hitPoint.y - end.y) <= radius {
            return .resizeEnd
        }
        if hypot(hitPoint.x - start.x, hitPoint.y - start.y) <= radius {
            return .resizeStart
        }
        return nil
    }

    private func textHitRect(for mark: ImageAnnotationMark, in size: CGSize) -> CGRect {
        let text = mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Text" : mark.text
        let fontSize = max(CGFloat(mark.lineWidth) * 4, 13)
        let textSize = (text as NSString).size(
            withAttributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            ]
        )
        let padding = CGSize(width: 6, height: 4)
        let markCenter = CGPoint(
            x: CGFloat(mark.end.x) * size.width,
            y: CGFloat(mark.end.y) * size.height
        )
        return CGRect(
            x: markCenter.x - textSize.width / 2 - padding.width,
            y: markCenter.y - textSize.height / 2 - padding.height,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        .insetBy(dx: -6, dy: -6)
    }

    private func rect(for mark: ImageAnnotationMark, in size: CGSize) -> CGRect {
        let start = canvasPoint(for: mark.start, in: size)
        let end = canvasPoint(for: mark.end, in: size)
        return CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: max(abs(start.x - end.x), 1),
            height: max(abs(start.y - end.y), 1)
        )
    }

    private func canvasPoint(for point: AnnotationPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: CGFloat(point.x) * size.width,
            y: CGFloat(point.y) * size.height
        )
    }

    private func hitPadding(for mark: ImageAnnotationMark) -> CGFloat {
        max(CGFloat(mark.lineWidth) * 1.8, 9)
    }

    private func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private func dragDistance(from start: AnnotationPoint, to end: AnnotationPoint, in size: CGSize) -> CGFloat {
        let startPoint = canvasPoint(for: start, in: size)
        let endPoint = canvasPoint(for: end, in: size)
        return hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)
    }

    private func transformMark(
        id: ImageAnnotationMark.ID,
        from original: ImageAnnotationMark,
        dragStart: AnnotationPoint,
        current: AnnotationPoint,
        mode: AnnotationCanvasDragMode
    ) {
        guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
        prepareUndoForDrag()
        switch mode {
        case .move:
            let delta = AnnotationPoint(
                x: current.x - dragStart.x,
                y: current.y - dragStart.y
            )
            marks[index].start = moved(original.start, by: delta)
            marks[index].end = moved(original.end, by: delta)
        case .resizeStart:
            marks[index].start = current
        case .resizeEnd:
            marks[index].end = current
        }
    }

    private func moved(_ point: AnnotationPoint, by delta: AnnotationPoint) -> AnnotationPoint {
        AnnotationPoint(
            x: min(max(point.x + delta.x, 0), 1),
            y: min(max(point.y + delta.y, 0), 1)
        )
    }

    private func resetDragState() {
        draftMark = nil
        dragStart = nil
        movingMarkID = nil
        movingOriginalMark = nil
        dragMode = nil
        didRecordUndoForDrag = false
    }

    private func prepareUndoForDrag() {
        guard !didRecordUndoForDrag else { return }
        recordUndo()
        didRecordUndoForDrag = true
    }

    private func fittedRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        let inset: CGFloat = 18
        let available = CGSize(
            width: max(container.width - inset * 2, 1),
            height: max(container.height - inset * 2, 1)
        )
        let scale = min(
            available.width / max(imageSize.width, 1),
            available.height / max(imageSize.height, 1)
        )
        let width = max(imageSize.width * scale, 1)
        let height = max(imageSize.height * scale, 1)
        return CGRect(
            x: (container.width - width) / 2,
            y: (container.height - height) / 2,
            width: width,
            height: height
        )
    }
}

private struct AnnotationMarksLayer: View {
    let marks: [ImageAnnotationMark]
    let draftMark: ImageAnnotationMark?
    let selectedMarkID: ImageAnnotationMark.ID?

    private var visibleMarks: [ImageAnnotationMark] {
        if let draftMark {
            return marks + [draftMark]
        }
        return marks
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(visibleMarks) { mark in
                    AnnotationMarkView(
                        mark: mark,
                        size: proxy.size,
                        isSelected: mark.id == selectedMarkID
                    )
                }
            }
        }
    }
}

private struct AnnotationMarkView: View {
    let mark: ImageAnnotationMark
    let size: CGSize
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            markContent
            if isSelected {
                Path { path in
                    path.addRoundedRect(
                        in: selectionRect(),
                        cornerSize: CGSize(width: 6, height: 6)
                    )
                }
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 1.25, dash: [4, 3])
                )

                ForEach(selectionHandles.indices, id: \.self) { index in
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle()
                                .stroke(Color.accentColor, lineWidth: 1.5)
                        )
                        .position(selectionHandles[index])
                }
            }
        }
    }

    @ViewBuilder
    private var markContent: some View {
        switch mark.tool {
        case .arrow:
            path(includeArrowHead: true)
                .stroke(
                    mark.color.swiftUIColor,
                    style: StrokeStyle(
                        lineWidth: CGFloat(mark.lineWidth),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
        case .line:
            path(includeArrowHead: false)
                .stroke(
                    mark.color.swiftUIColor,
                    style: StrokeStyle(
                        lineWidth: CGFloat(mark.lineWidth),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
        case .rectangle:
            Path { path in
                path.addRect(rect())
            }
            .stroke(mark.color.swiftUIColor, lineWidth: CGFloat(mark.lineWidth))
        case .ellipse:
            Path { path in
                path.addEllipse(in: rect())
            }
            .stroke(mark.color.swiftUIColor, lineWidth: CGFloat(mark.lineWidth))
        case .highlight:
            Path { path in
                path.addRect(rect())
            }
            .fill(mark.color.swiftUIColor.opacity(0.24))
            .overlay {
                Path { path in
                    path.addRect(rect())
                }
                .stroke(
                    mark.color.swiftUIColor.opacity(0.65),
                    lineWidth: CGFloat(max(mark.lineWidth * 0.6, 1))
                )
            }
        case .text:
            let end = point(mark.end)
            Text(
                mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Text" : mark.text
            )
                .font(.system(size: max(CGFloat(mark.lineWidth) * 4, 13), weight: .semibold))
                .foregroundStyle(mark.color.swiftUIColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                .fixedSize()
                .position(end)
        }
    }

    private func path(includeArrowHead: Bool) -> Path {
        var path = Path()
        let start = point(mark.start)
        let end = point(mark.end)
        path.move(to: start)
        path.addLine(to: end)

        if includeArrowHead {
            let dx = end.x - start.x
            let dy = end.y - start.y
            if abs(dx) + abs(dy) > 0.5 {
                let angle = atan2(dy, dx)
                let headLength = max(CGFloat(mark.lineWidth) * 4, 12)
                let wingAngle = CGFloat.pi / 7
                let left = CGPoint(
                    x: end.x - headLength * cos(angle - wingAngle),
                    y: end.y - headLength * sin(angle - wingAngle)
                )
                let right = CGPoint(
                    x: end.x - headLength * cos(angle + wingAngle),
                    y: end.y - headLength * sin(angle + wingAngle)
                )
                path.move(to: end)
                path.addLine(to: left)
                path.move(to: end)
                path.addLine(to: right)
            }
        }
        return path
    }

    private func rect() -> CGRect {
        let start = point(mark.start)
        let end = point(mark.end)
        return CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: max(abs(start.x - end.x), 1),
            height: max(abs(start.y - end.y), 1)
        )
    }

    private func selectionRect() -> CGRect {
        switch mark.tool {
        case .text:
            return textRect().insetBy(dx: -4, dy: -4)
        case .arrow, .line:
            return rect().insetBy(dx: -max(CGFloat(mark.lineWidth), 8), dy: -max(CGFloat(mark.lineWidth), 8))
        case .rectangle, .ellipse, .highlight:
            return rect().insetBy(dx: -5, dy: -5)
        }
    }

    private var selectionHandles: [CGPoint] {
        guard mark.tool != .text else { return [] }
        return [point(mark.start), point(mark.end)]
    }

    private func textRect() -> CGRect {
        let text = mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Text" : mark.text
        let fontSize = max(CGFloat(mark.lineWidth) * 4, 13)
        let textSize = (text as NSString).size(
            withAttributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            ]
        )
        let center = point(mark.end)
        return CGRect(
            x: center.x - textSize.width / 2 - 6,
            y: center.y - textSize.height / 2 - 4,
            width: textSize.width + 12,
            height: textSize.height + 8
        )
    }

    private func point(_ point: AnnotationPoint) -> CGPoint {
        CGPoint(
            x: CGFloat(point.x) * size.width,
            y: CGFloat(point.y) * size.height
        )
    }
}
