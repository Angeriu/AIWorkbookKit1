import Foundation
import PencilKit
import SwiftUI
import UIKit

@MainActor
struct QuestionAnswerCanvas: View {
    let fileURL: URL
    let showsTools: Bool
    let fitWidthRequest: Int

    @Environment(\.scenePhase) private var scenePhase
    @State private var loadState = LoadState.loading
    @State private var saveError: String?

    private enum LoadState {
        case loading
        case ready(AnswerDrawingSnapshot)
        case failed(String)
    }

    init(fileURL: URL, showsTools: Bool, fitWidthRequest: Int) {
        self.fileURL = fileURL.standardizedFileURL
        self.showsTools = showsTools
        self.fitWidthRequest = fitWidthRequest
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
                AnswerCanvasHost(fileURL: fileURL, snapshot: snapshot,
                                 showsTools: showsTools && scenePhase == .active,
                                 fitWidthRequest: fitWidthRequest, onSave: reportSaveResult)
                    .accessibilityLabel("答题纸")
                    .accessibilityHint("使用 Apple Pencil 书写，双指移动和缩放答题纸")
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
    let showsTools: Bool
    let fitWidthRequest: Int
    let onSave: @MainActor (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL, snapshot: snapshot, onSave: onSave)
    }

    func makeUIView(context: Context) -> AnswerSheetScrollView {
        let view = AnswerSheetScrollView()
        view.canvas.drawing = snapshot.drawing
        view.canvas.delegate = context.coordinator
        view.attachPressurePen { [weak coordinator = context.coordinator] canvas in
            coordinator?.canvasViewDrawingDidChange(canvas)
        }
        return view
    }

    func updateUIView(_ uiView: AnswerSheetScrollView, context: Context) {
        context.coordinator.onSave = onSave
        uiView.setToolsVisible(showsTools)
        uiView.fitWidthIfRequested(fitWidthRequest)
    }

    static func dismantleUIView(_ uiView: AnswerSheetScrollView, coordinator: Coordinator) {
        uiView.detachPressurePen()
        uiView.canvas.delegate = nil
        // A failed write stays queued and is retried when the answer sheet reopens.
        try? coordinator.saveLatest(from: uiView.canvas)
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
private final class AnswerSheetScrollView: UIScrollView, UIScrollViewDelegate {
    private static let sheetSize = CGSize(width: 768, height: 1_024)
    let canvas: PKCanvasView
    private let paper: RuledAnswerPaper
    private let pressurePen = WorkbookPressurePen()
    private var toolPicker: PKToolPicker { pressurePen.toolPicker }
    private var observingTools = false
    private var wantsTools = false
    private var viewportSize = CGSize.zero
    private var lastFitWidthRequest: Int?

    init() {
        let frame = CGRect(origin: .zero, size: Self.sheetSize)
        paper = RuledAnswerPaper(frame: frame)
        canvas = WorkbookPencilCanvas(frame: frame)
        super.init(frame: .zero)

        delegate = self
        backgroundColor = .secondarySystemBackground
        contentInsetAdjustmentBehavior = .never
        contentSize = Self.sheetSize
        delaysContentTouches = false
        bouncesZoom = false
        panGestureRecognizer.minimumNumberOfTouches = 2
        let fingerTouches = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        panGestureRecognizer.allowedTouchTypes = fingerTouches
        pinchGestureRecognizer?.allowedTouchTypes = fingerTouches

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = .pencilOnly
        canvas.contentSize = Self.sheetSize
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.panGestureRecognizer.isEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.showsVerticalScrollIndicator = false
        paper.addSubview(canvas)
        addSubview(paper)
    }

    required init?(coder: NSCoder) {
        fatalError("AnswerSheetScrollView is created in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if viewportSize != bounds.size {
            let previousSize = viewportSize
            let priorWidthScale = previousSize.width / Self.sheetSize.width
            let oldCenter = CGPoint(x: bounds.minX + previousSize.width / 2,
                                    y: bounds.minY + previousSize.height / 2)
            let focus = convert(oldCenter, to: paper)
            let previousZoom = zoomScale
            viewportSize = bounds.size
            let widthScale = viewportSize.width / Self.sheetSize.width
            let heightScale = viewportSize.height / Self.sheetSize.height
            maximumZoomScale = max(maximumZoomScale, widthScale * 4)
            minimumZoomScale = min(widthScale, heightScale)
            maximumZoomScale = widthScale * 4
            if priorWidthScale > 0 {
                let scale = min(maximumZoomScale, max(minimumZoomScale, previousZoom * widthScale / priorWidthScale))
                let target = CGSize(width: bounds.width / scale, height: bounds.height / scale)
                zoom(to: CGRect(x: focus.x - target.width / 2, y: focus.y - target.height / 2,
                                width: target.width, height: target.height), animated: false)
            } else {
                fitToWidth()
            }
        }
        centerPaper()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { paper }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPaper() }

    private func centerPaper() {
        paper.center = CGPoint(x: max(bounds.width, Self.sheetSize.width * zoomScale) / 2,
                               y: max(bounds.height, Self.sheetSize.height * zoomScale) / 2)
    }

    func fitWidthIfRequested(_ request: Int) {
        defer { lastFitWidthRequest = request }
        guard let lastFitWidthRequest, request != lastFitWidthRequest else { return }
        fitToWidth()
    }

    private func fitToWidth() {
        guard bounds.width > 0 else { return }
        setZoomScale(bounds.width / Self.sheetSize.width, animated: false)
        setContentOffset(.zero, animated: false)
    }

    func attachPressurePen(onDrawingChange: @escaping (PKCanvasView) -> Void) {
        pressurePen.attach(to: canvas, onDrawingChange: onDrawingChange) { [weak self] active in
            self?.panGestureRecognizer.isEnabled = !active
            self?.pinchGestureRecognizer?.isEnabled = !active
        }
    }

    func detachPressurePen() {
        hideToolPicker()
        pressurePen.detach()
    }

    func setToolsVisible(_ visible: Bool) {
        wantsTools = visible
        if visible {
            showToolPicker()
        } else {
            pressurePen.flush()
            hideToolPicker()
        }
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
        guard wantsTools, window != nil, canvas.delegate != nil, !observingTools else { return }
        observingTools = true
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        _ = canvas.becomeFirstResponder()
    }

    private func hideToolPicker() {
        guard observingTools else { return }
        observingTools = false
        toolPicker.setVisible(false, forFirstResponder: canvas)
        toolPicker.removeObserver(canvas)
        _ = canvas.resignFirstResponder()
    }
}

@MainActor
private final class RuledAnswerPaper: UIView {
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor(red: 0.98, green: 0.97, blue: 0.92, alpha: 1).cgColor)
        context.fill(rect)
        context.setStrokeColor(UIColor(red: 0.77, green: 0.80, blue: 0.82, alpha: 1).cgColor)
        context.setLineWidth(0.75)
        for y in stride(from: 32, to: Int(bounds.height), by: 32) {
            context.move(to: CGPoint(x: 0, y: CGFloat(y)))
            context.addLine(to: CGPoint(x: bounds.width, y: CGFloat(y)))
        }
        context.strokePath()
    }
}

@MainActor
final class WorkbookPencilCanvas: PKCanvasView {
    private let sheetUndoManager = UndoManager()

    override var undoManager: UndoManager? { sheetUndoManager }
}
