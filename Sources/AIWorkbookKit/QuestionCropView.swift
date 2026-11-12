import PDFKit
import SwiftUI
import UIKit

@MainActor
struct QuestionCropView: View {
    @Environment(\.dismiss) private var dismiss
    let page: PDFPage
    let initialCrop: NormalizedCrop?
    let onSave: (NormalizedCrop) throws -> Void

    @State private var display: QuestionPDFDisplay? = nil
    @State private var didPrepare = false
    @State private var selection: NormalizedCrop?
    @State private var selectionTooSmall = false
    @State private var saveError: String? = nil
    @State private var isSelecting = true
    @State private var isDragging = false
    @State private var zoomRequest: QuestionPDFZoomRequest? = nil

    init(page: PDFPage, initialCrop: NormalizedCrop?, onSave: @escaping (NormalizedCrop) throws -> Void) {
        self.page = page
        self.initialCrop = initialCrop
        self.onSave = onSave
        _selection = State(initialValue: initialCrop)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                if let display {
                    Picker("操作", selection: $isSelecting) {
                        Text("框选").tag(true)
                        Text("移动与缩放").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isDragging)
                    .frame(maxWidth: 480)
                    .padding(.horizontal)

                    Text(instructions)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    QuestionPDFViewport(
                        display: display, accessibilityTitle: "PDF 题目框选页面",
                        interactive: true, startsFittedToContent: true,
                        selection: selection, isSelecting: isSelecting, zoomRequest: zoomRequest,
                        onSelection: { crop in
                            selection = crop
                            selectionTooSmall = crop == nil
                        },
                        onDraggingChanged: { isDragging = $0 }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    QuestionPDFZoomControls(hasContentFit: display.contentRegion != nil,
                                            wholePageTitle: "适合整页") { action in
                        zoomRequest = QuestionPDFZoomRequest(action: action)
                    }
                    .disabled(isDragging)
                } else if didPrepare {
                    ContentUnavailableView("无法显示这页 PDF", systemImage: "doc.text")
                } else {
                    ProgressView("正在显示 PDF…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.top, 8)
            .background(Color(uiColor: .secondarySystemBackground))
            .navigationTitle(initialCrop == nil ? "框选题目" : "重选题目区域")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: saveSelection)
                        .disabled(display == nil || selection?.isValid != true || isDragging)
                }
            }
            .alert("无法保存题目区域", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) {
                Button("好", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
        .task {
            guard !didPrepare else { return }
            display = QuestionPDFDisplay(source: page, crop: nil)
            didPrepare = true
        }
    }

    private var instructions: String {
        if !isSelecting { return "双指捏合缩放，拖动查看页面。" }
        if selectionTooSmall { return "选区太小，请拖出更大的矩形。" }
        return "用手指或 Apple Pencil 拖出题目范围。"
    }

    private func saveSelection() {
        guard let selection, selection.isValid else { return }
        do {
            try onSave(selection)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

@MainActor
struct QuestionCropPreview: View {
    let page: PDFPage
    let crop: NormalizedCrop?
    let allowsZoom: Bool
    let onOpen: (() -> Void)?
    let onViewSource: (() -> Void)?
    let onRecrop: (() -> Void)?

    @State private var display: QuestionPDFDisplay? = nil
    @State private var didPrepare = false
    @State private var zoomRequest: QuestionPDFZoomRequest? = nil

    init(page: PDFPage, crop: NormalizedCrop, allowsZoom: Bool = false,
         onOpen: (() -> Void)? = nil, onViewSource: (() -> Void)? = nil,
         onRecrop: (() -> Void)? = nil) {
        self.page = page
        self.crop = crop
        self.allowsZoom = allowsZoom
        self.onOpen = onOpen
        self.onViewSource = onViewSource
        self.onRecrop = onRecrop
    }

    fileprivate init(sourcePage: PDFPage) {
        page = sourcePage
        crop = nil
        allowsZoom = true
        onOpen = nil
        onViewSource = nil
        onRecrop = nil
    }

    private struct RenderKey: Equatable {
        let page: ObjectIdentifier
        let crop: NormalizedCrop?
    }

    static func aspectRatio(page: PDFPage, crop: NormalizedCrop) -> CGFloat {
        guard crop.isValid, let geometry = QuestionPDFGeometry(page: page) else { return 1 }
        return geometry.rotatedSize.width * CGFloat(crop.width)
            / (geometry.rotatedSize.height * CGFloat(crop.height))
    }

    var body: some View {
        VStack(spacing: 8) {
            if let display {
                if let onOpen, !allowsZoom {
                    Button(action: onOpen) {
                        viewport(display)
                            .allowsHitTesting(false)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("全屏查看题目")
                } else {
                    viewport(display)
                }

                if allowsZoom {
                    QuestionPDFZoomControls(hasContentFit: display.contentRegion != nil,
                                            wholePageTitle: crop == nil ? "适合整页" : "适合窗口") { action in
                        zoomRequest = QuestionPDFZoomRequest(action: action)
                    }
                }
                if display.looksEmpty && crop != nil {
                    previewMessage("选区看起来是空白。")
                }
            } else if didPrepare {
                previewMessage(crop == nil ? "无法显示这页 PDF。" : "无法显示题目区域。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("正在显示 PDF…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: RenderKey(page: ObjectIdentifier(page), crop: crop), initial: true) {
            display = QuestionPDFDisplay(source: page, crop: crop)
            didPrepare = true
        }
    }

    private func viewport(_ display: QuestionPDFDisplay) -> some View {
        QuestionPDFViewport(
            display: display, accessibilityTitle: crop == nil ? "原 PDF 页面" : "题目区域",
            interactive: allowsZoom, startsFittedToContent: crop == nil,
            zoomRequest: zoomRequest
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewMessage(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if onViewSource != nil || onRecrop != nil {
                HStack {
                    if let onViewSource { Button("查看原页", action: onViewSource) }
                    if let onRecrop { Button("重新框选", action: onRecrop) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(8)
    }
}

@MainActor
struct QuestionSourcePreview: View {
    let page: PDFPage

    var body: some View {
        QuestionCropPreview(sourcePage: page)
    }
}

private struct QuestionPDFZoomRequest {
    enum Action {
        case smaller, fitPage, fitContent, larger
    }

    let id = UUID()
    let action: Action
}

private struct QuestionPDFZoomControls: View {
    let hasContentFit: Bool
    let wholePageTitle: String
    let onZoom: (QuestionPDFZoomRequest.Action) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("缩小", systemImage: "minus.magnifyingglass") { onZoom(.smaller) }
                .labelStyle(.iconOnly)
            Button(wholePageTitle) { onZoom(.fitPage) }
            if hasContentFit {
                Button("适合内容") { onZoom(.fitContent) }
            }
            Button("放大", systemImage: "plus.magnifyingglass") { onZoom(.larger) }
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .padding(.bottom, 8)
    }
}

@MainActor
private struct QuestionPDFViewport: UIViewRepresentable {
    let display: QuestionPDFDisplay
    let accessibilityTitle: String
    let interactive: Bool
    let startsFittedToContent: Bool
    var selection: NormalizedCrop? = nil
    var isSelecting = false
    var zoomRequest: QuestionPDFZoomRequest? = nil
    var onSelection: ((NormalizedCrop?) -> Void)? = nil
    var onDraggingChanged: ((Bool) -> Void)? = nil

    func makeUIView(context: Context) -> QuestionPDFViewportView {
        QuestionPDFViewportView(frame: .zero)
    }

    func updateUIView(_ view: QuestionPDFViewportView, context: Context) {
        view.setDisplay(display, interactive: interactive, startsFittedToContent: startsFittedToContent)
        view.setAccessibilityTitle(accessibilityTitle)
        view.onSelection = onSelection
        view.onDraggingChanged = onDraggingChanged
        view.setSelection(selection, isSelecting: isSelecting)
        if let zoomRequest { view.apply(zoomRequest) }
    }
}

@MainActor
private final class QuestionPDFViewportView: UIView {
    private let pdfView = PDFView(frame: .zero)
    private let selectionInput = UIView()
    private let outline = CAShapeLayer()
    private var display: QuestionPDFDisplay?
    private var selection: NormalizedCrop?
    private var dragOrigin: CGPoint?
    private var dragRect: CGRect?
    private var lastViewportSize = CGSize.zero
    private var fitScale: CGFloat = 1
    private var startsFittedToContent = false
    private var lastZoomRequest: UUID?

    var onSelection: ((NormalizedCrop?) -> Void)?
    var onDraggingChanged: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        pdfView.autoScales = false
        pdfView.displayMode = .singlePage
        pdfView.displayBox = .cropBox
        pdfView.displaysPageBreaks = false
        pdfView.pageShadowsEnabled = false
        pdfView.backgroundColor = .secondarySystemBackground
        addSubview(pdfView)

        selectionInput.isUserInteractionEnabled = false
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(dragSelection(_:)))
        recognizer.maximumNumberOfTouches = 1
        recognizer.allowedTouchTypes = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
        selectionInput.addGestureRecognizer(recognizer)
        addSubview(selectionInput)

        outline.strokeColor = UIColor.systemBlue.cgColor
        outline.fillColor = UIColor.systemBlue.withAlphaComponent(0.18).cgColor
        outline.lineWidth = 2
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged(_:)),
                                               name: .PDFViewScaleChanged, object: pdfView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setAccessibilityTitle(_ title: String) {
        pdfView.accessibilityLabel = title
    }

    func setDisplay(_ display: QuestionPDFDisplay, interactive: Bool, startsFittedToContent: Bool) {
        pdfView.isUserInteractionEnabled = interactive
        guard self.display !== display else { return }
        self.display = display
        self.startsFittedToContent = startsFittedToContent
        lastViewportSize = .zero
        pdfView.document = display.document
        pdfView.go(to: display.page)
        setNeedsLayout()
    }

    func setSelection(_ selection: NormalizedCrop?, isSelecting: Bool) {
        self.selection = selection
        selectionInput.isUserInteractionEnabled = isSelecting
        drawSelection()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let newSize = bounds.size
        let oldCenter = normalizedCenter()
        let oldRelativeScale = pdfView.scaleFactor / fitScale
        pdfView.frame = bounds
        selectionInput.frame = bounds
        pdfView.layoutIfNeeded()

        if let display, newSize != lastViewportSize, newSize.width > 0, newSize.height > 0 {
            let firstLayout = lastViewportSize == .zero
            lastViewportSize = newSize
            fitScale = scaleFitting(display.region)
            pdfView.maxScaleFactor = max(pdfView.maxScaleFactor, fitScale * 8)
            pdfView.minScaleFactor = fitScale
            pdfView.maxScaleFactor = fitScale * 8
            if firstLayout {
                let initialRegion = startsFittedToContent ? display.contentRegion ?? display.region : display.region
                focus(on: initialRegion)
            } else {
                setScale(fitScale * oldRelativeScale, centeredAt: oldCenter)
            }
        }

        drawSelection()
    }

    func apply(_ request: QuestionPDFZoomRequest) {
        guard request.id != lastZoomRequest, let display else { return }
        layoutIfNeeded()
        guard lastViewportSize != .zero else { return }
        lastZoomRequest = request.id
        switch request.action {
        case .fitPage:
            focus(on: display.region)
        case .fitContent:
            focus(on: display.contentRegion ?? display.region)
        case .smaller:
            setScale(pdfView.scaleFactor / 1.5, centeredAt: normalizedCenter())
        case .larger:
            setScale(pdfView.scaleFactor * 1.5, centeredAt: normalizedCenter())
        }
    }

    private func focus(on region: CGRect) {
        let scale = min(scaleFitting(region), fitScale * 6)
        setScale(scale, centeredAt: CGPoint(x: region.midX, y: region.midY))
    }

    private func scaleFitting(_ region: CGRect) -> CGFloat {
        guard let display else { return 1 }
        let pageSize = display.geometry.rotatedSize
        return min(max(1, bounds.width - 12) / (region.width * pageSize.width),
                   max(1, bounds.height - 12) / (region.height * pageSize.height))
    }

    private func normalizedCenter() -> CGPoint? {
        guard let display, lastViewportSize != .zero else { return nil }
        let center = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        return display.geometry.normalizedPoint(pdfView.convert(center, to: display.page))
    }

    private func setScale(_ scale: CGFloat, centeredAt center: CGPoint?) {
        guard let display else { return }
        let targetScale = min(max(scale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        pdfView.scaleFactor = targetScale

        let region = display.region
        let focus = center ?? CGPoint(x: region.midX, y: region.midY)
        let pageSize = display.geometry.rotatedSize
        let visibleWidth = bounds.width / (pageSize.width * targetScale)
        let visibleHeight = bounds.height / (pageSize.height * targetScale)
        let left = max(region.minX, min(region.maxX - visibleWidth, focus.x - visibleWidth / 2))
        let top = max(region.minY, min(region.maxY - visibleHeight, focus.y - visibleHeight / 2))
        let point = display.geometry.pagePoint(CGPoint(x: left, y: top))
        let destination = PDFDestination(page: display.page, at: point)
        destination.zoom = targetScale
        pdfView.go(to: destination)
        drawSelection()
    }

    @objc private func scaleChanged(_ notification: Notification) {
        setNeedsLayout()
    }

    private func drawSelection() {
        let selectionRect = selection.map(QuestionPDFGeometry.normalizedRect)
        guard let display, let region = dragRect ?? selectionRect, !region.isEmpty,
              let documentView = pdfView.documentView else {
            outline.path = nil
            return
        }

        let pageRect = display.geometry.pageRect(region)
        let viewRect = pdfView.convert(pageRect, from: display.page)
        let documentRect = documentView.convert(viewRect, from: pdfView)
        if outline.superlayer !== documentView.layer {
            outline.removeFromSuperlayer()
            documentView.layer.addSublayer(outline)
        }
        let layerBounds = documentView.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.frame = layerBounds
        outline.path = UIBezierPath(rect: documentRect.offsetBy(dx: -layerBounds.minX, dy: -layerBounds.minY)).cgPath
        CATransaction.commit()
    }

    @objc private func dragSelection(_ gesture: UIPanGestureRecognizer) {
        guard let display else { return }
        let point = gesture.location(in: pdfView)
        switch gesture.state {
        case .began:
            let translation = gesture.translation(in: pdfView)
            let start = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            let pageFrame = pdfView.convert(display.geometry.pageBounds, from: display.page)
            guard pageFrame.insetBy(dx: -4, dy: -4).contains(start) else { return }
            dragOrigin = normalizedPoint(start, on: display)
            dragRect = CGRect(origin: dragOrigin ?? .zero, size: .zero)
            onDraggingChanged?(true)
        case .changed, .ended:
            guard let start = dragOrigin else { return }
            let end = normalizedPoint(point, on: display)
            let region = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                width: abs(end.x - start.x), height: abs(end.y - start.y))
            dragRect = region
            if gesture.state == .ended {
                let visible = pdfView.convert(display.geometry.pageRect(region), from: display.page)
                let crop = NormalizedCrop(x: Double(region.minX), y: Double(region.minY),
                                          width: Double(region.width), height: Double(region.height))
                selection = visible.width >= 6 && visible.height >= 6 && crop.isValid ? crop : nil
                dragOrigin = nil
                dragRect = nil
                onSelection?(selection)
                onDraggingChanged?(false)
            }
        case .cancelled, .failed:
            guard dragOrigin != nil else { return }
            dragOrigin = nil
            dragRect = nil
            onDraggingChanged?(false)
        default:
            return
        }
        drawSelection()
    }

    private func normalizedPoint(_ point: CGPoint, on display: QuestionPDFDisplay) -> CGPoint {
        let pagePoint = pdfView.convert(point, to: display.page)
        return QuestionPDFGeometry.clamp(display.geometry.normalizedPoint(pagePoint))
    }
}
