import Foundation
import PencilKit
import SwiftUI
import UIKit

@MainActor
enum WorkbookPen {
    static func makeToolPicker() -> PKToolPicker {
        let inkType = PKInkingTool.InkType.fountainPen
        let widthRange = inkType.validWidthRange
        let width = min(max(3, widthRange.lowerBound), widthRange.upperBound)
        let fountainPen = PKToolPickerInkingItem(type: inkType, color: .black, width: width)
        let otherTools = PKToolPicker.defaultToolItems.filter {
            ($0 as? PKToolPickerInkingItem)?.inkingTool.inkType != inkType
        }
        let picker = PKToolPicker(toolItems: [fountainPen] + otherTools)
        picker.selectedToolItem = fountainPen
        return picker
    }
}

@MainActor
struct QuestionAnswerCanvas: View {
    let fileURL: URL

    @Environment(\.scenePhase) private var scenePhase
    @State private var loadState = LoadState.loading
    @State private var saveError: String?

    private enum LoadState {
        case loading
        case ready(AnswerDrawingSnapshot)
        case failed(String)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch loadState {
            case .loading:
                ProgressView("正在读取答题纸")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                Text("无法读取答题笔迹").font(.headline)
                Text(message).font(.footnote)
                Button("重试读取", action: load)
            case let .ready(snapshot):
                if let saveError {
                    Text("笔迹尚未保存").font(.headline)
                    Text(saveError).font(.footnote)
                    Button("重试保存", action: flush)
                }
                AnswerCanvasHost(fileURL: fileURL, snapshot: snapshot, onSave: reportSaveResult)
                    .accessibilityLabel("答题纸")
                    .accessibilityHint("使用 Apple Pencil 书写，双指移动答题纸")
            }
        }
        .onAppear {
            switch loadState {
            case .loading: load()
            case .ready: flush()
            case .failed: break
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                flush()
            }
        }
    }

    private func load() {
        do {
            loadState = .ready(AnswerDrawingSnapshot(try AnswerDrawingFiles.read(fileURL)))
            flush()
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func flush() {
        do {
            try AnswerDrawingFiles.flush(fileURL)
            reportSaveResult(nil)
        } catch {
            reportSaveResult(error.localizedDescription)
        }
    }

    private func reportSaveResult(_ message: String?) {
        if saveError != message {
            saveError = message
        }
    }
}

@MainActor
private final class AnswerDrawingSnapshot {
    var drawing: PKDrawing

    init(_ drawing: PKDrawing) {
        self.drawing = drawing
    }
}

@MainActor
private enum AnswerDrawingFiles {
    // Retain the latest unsaved drawing if its canvas is closed before a retry.
    private static var pending: [URL: Data] = [:]

    static func read(_ url: URL) throws -> PKDrawing {
        if let data = pending[url] {
            return try PKDrawing(data: data)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return PKDrawing()
        }
        return try PKDrawing(data: data)
    }

    static func save(_ drawing: PKDrawing, to url: URL) throws {
        pending[url] = drawing.dataRepresentation()
        try flush(url)
    }

    static func flush(_ url: URL) throws {
        guard let data = pending[url] else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        pending.removeValue(forKey: url)
    }
}

@MainActor
private struct AnswerCanvasHost: UIViewRepresentable {
    let fileURL: URL
    let snapshot: AnswerDrawingSnapshot
    let onSave: @MainActor (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL, snapshot: snapshot, onSave: onSave)
    }

    func makeUIView(context: Context) -> AnswerSheetScrollView {
        let view = AnswerSheetScrollView()
        view.canvas.drawing = snapshot.drawing
        view.canvas.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: AnswerSheetScrollView, context: Context) {
        context.coordinator.onSave = onSave
    }

    static func dismantleUIView(_ uiView: AnswerSheetScrollView, coordinator: Coordinator) {
        uiView.canvas.delegate = nil
        // A failed write stays queued and is retried when the answer sheet reopens.
        try? coordinator.saveLatest(from: uiView.canvas)
        uiView.hideToolPicker()
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let fileURL: URL
        let snapshot: AnswerDrawingSnapshot
        var onSave: @MainActor (String?) -> Void

        init(fileURL: URL, snapshot: AnswerDrawingSnapshot, onSave: @escaping @MainActor (String?) -> Void) {
            self.fileURL = fileURL
            self.snapshot = snapshot
            self.onSave = onSave
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            do {
                try saveLatest(from: canvasView)
                onSave(nil)
            } catch {
                onSave(error.localizedDescription)
            }
        }

        func saveLatest(from canvasView: PKCanvasView) throws {
            let drawing = canvasView.drawing
            guard drawing != snapshot.drawing else {
                try AnswerDrawingFiles.flush(fileURL)
                return
            }
            snapshot.drawing = drawing
            try AnswerDrawingFiles.save(drawing, to: fileURL)
        }
    }
}

@MainActor
private final class AnswerSheetScrollView: UIScrollView {
    let canvas: PKCanvasView
    private let toolPicker = WorkbookPen.makeToolPicker()
    private var observingTools = false

    init() {
        let sheetSize = CGSize(width: 768, height: 1_024)
        canvas = AnswerPencilCanvas(frame: CGRect(origin: .zero, size: sheetSize))
        super.init(frame: .zero)

        backgroundColor = .secondarySystemBackground
        contentInsetAdjustmentBehavior = .never
        contentSize = sheetSize
        delaysContentTouches = false
        panGestureRecognizer.minimumNumberOfTouches = 2
        panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        canvas.backgroundColor = .white
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = .pencilOnly
        if let ink = toolPicker.selectedToolItem as? PKToolPickerInkingItem {
            canvas.tool = ink.inkingTool
        }
        canvas.contentSize = sheetSize
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.panGestureRecognizer.isEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.showsVerticalScrollIndicator = false
        addSubview(canvas)
    }

    required init?(coder: NSCoder) {
        fatalError("AnswerSheetScrollView is created in code")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            hideToolPicker()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.showToolPicker()
            }
        }
    }

    private func showToolPicker() {
        guard window != nil, canvas.delegate != nil, !observingTools else { return }
        observingTools = true
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        _ = canvas.becomeFirstResponder()
    }

    func hideToolPicker() {
        guard observingTools else { return }
        observingTools = false
        toolPicker.setVisible(false, forFirstResponder: canvas)
        toolPicker.removeObserver(canvas)
        _ = canvas.resignFirstResponder()
    }
}

@MainActor
private final class AnswerPencilCanvas: PKCanvasView {
    private let sheetUndoManager = UndoManager()

    override var undoManager: UndoManager? { sheetUndoManager }
}
