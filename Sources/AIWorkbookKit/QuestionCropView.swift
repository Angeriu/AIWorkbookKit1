import PDFKit
import SwiftUI
import UIKit

@MainActor
struct QuestionCropView: View {
    @Environment(\.dismiss) private var dismiss

    let page: PDFPage
    let initialCrop: NormalizedCrop?
    let onSave: (NormalizedCrop) throws -> Void

    @State private var image: UIImage? = nil
    @State private var didRender = false
    @State private var selection: NormalizedCrop?
    @State private var selectionTooSmall = false
    @State private var saveError: String? = nil
    @State private var isSelecting = true
    @State private var isDragging = false

    init(
        page: PDFPage,
        initialCrop: NormalizedCrop?,
        onSave: @escaping (NormalizedCrop) throws -> Void
    ) {
        self.page = page
        self.initialCrop = initialCrop
        self.onSave = onSave
        _selection = State(initialValue: initialCrop)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let image {
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

                    ZoomablePDFImage(
                        image: image,
                        accessibilityTitle: "PDF 题目框选页面",
                        selection: selection,
                        isSelecting: isSelecting,
                        isDragging: isDragging,
                        onSelection: { crop in
                            selection = crop
                            selectionTooSmall = crop == nil
                        },
                        onDraggingChanged: { isDragging = $0 }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if didRender {
                    Text("无法显示这页 PDF。")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        .disabled(image == nil || selection?.isValid != true || isDragging)
                }
            }
            .alert("无法保存题目区域", isPresented: showingSaveError) {
                Button("好", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
        .onAppear {
            if !didRender {
                image = QuestionPDFRenderer.render(page: page, maximumDimension: 3600)
                didRender = true
            }
        }
    }

    private var showingSaveError: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    private var instructions: String {
        if !isSelecting { return "双指捏合缩放，拖动查看页面。" }
        if selectionTooSmall { return "选区太小，请拖出更大的矩形。" }
        return "在 PDF 页面上拖出一个矩形。再次拖动可重新选区。"
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
    let crop: NormalizedCrop
    let allowsZoom: Bool

    @State private var image: UIImage? = nil

    init(page: PDFPage, crop: NormalizedCrop, allowsZoom: Bool = false) {
        self.page = page
        self.crop = crop
        self.allowsZoom = allowsZoom
    }

    private struct RenderKey: Equatable {
        let page: ObjectIdentifier
        let crop: NormalizedCrop
    }

    private var renderKey: RenderKey {
        RenderKey(page: ObjectIdentifier(page), crop: crop)
    }

    var body: some View {
        Group {
            if let image {
                if allowsZoom {
                    ZoomablePDFImage(image: image, accessibilityTitle: "题目区域")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("题目区域")
                }
            } else {
                Text("无法显示题目区域。")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: renderKey, initial: true) { render() }
    }

    private func render() {
        image = QuestionPDFRenderer.render(page: page, crop: crop,
                                           maximumDimension: allowsZoom ? 3200 : 1600)
    }
}

@MainActor
private struct ZoomablePDFImage: View {
    let image: UIImage
    let accessibilityTitle: String
    var selection: NormalizedCrop? = nil
    var isSelecting = false
    var isDragging = false
    var onSelection: ((NormalizedCrop?) -> Void)? = nil
    var onDraggingChanged: ((Bool) -> Void)? = nil

    @State private var zoomRequest: ZoomRequest? = nil

    var body: some View {
        VStack(spacing: 6) {
            PDFImageViewport(image: image, accessibilityTitle: accessibilityTitle,
                             selection: selection, isSelecting: isSelecting,
                             onSelection: onSelection, onDraggingChanged: onDraggingChanged,
                             zoomRequest: zoomRequest)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 16) {
                Button("缩小", systemImage: "minus.magnifyingglass") {
                    zoomRequest = ZoomRequest(action: .smaller)
                }
                .labelStyle(.iconOnly)

                Button("适合屏幕") { zoomRequest = ZoomRequest(action: .fit) }

                Button("放大", systemImage: "plus.magnifyingglass") {
                    zoomRequest = ZoomRequest(action: .larger)
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(isDragging)
            .padding(.bottom, 8)
        }
    }
}

private struct ZoomRequest {
    enum Action {
        case smaller, fit, larger
    }

    let id = UUID()
    let action: Action
}

@MainActor
private struct PDFImageViewport: UIViewRepresentable {
    let image: UIImage
    let accessibilityTitle: String
    let selection: NormalizedCrop?
    let isSelecting: Bool
    let onSelection: ((NormalizedCrop?) -> Void)?
    let onDraggingChanged: ((Bool) -> Void)?
    let zoomRequest: ZoomRequest?

    func makeUIView(context: Context) -> PDFImageScrollView {
        PDFImageScrollView(frame: .zero)
    }

    func updateUIView(_ view: PDFImageScrollView, context: Context) {
        view.setImage(image, accessibilityTitle: accessibilityTitle)
        view.onSelection = onSelection
        view.onDraggingChanged = onDraggingChanged
        view.setSelection(selection, isSelecting: isSelecting)
        if let zoomRequest { view.apply(zoomRequest) }
    }
}

@MainActor
private final class PDFImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private let outline = CAShapeLayer()
    private lazy var selectGesture = UIPanGestureRecognizer(target: self, action: #selector(dragSelection(_:)))
    private var selection: NormalizedCrop?
    private var dragStart: CGPoint?
    private var previousViewportSize = CGSize.zero
    private var lastZoomRequest: UUID?

    var onSelection: ((NormalizedCrop?) -> Void)?
    var onDraggingChanged: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        delegate = self
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = false
        delaysContentTouches = false

        imageView.isUserInteractionEnabled = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        addSubview(imageView)

        outline.fillColor = UIColor.systemBlue.withAlphaComponent(0.18).cgColor
        outline.strokeColor = UIColor.systemBlue.cgColor
        imageView.layer.addSublayer(outline)

        selectGesture.maximumNumberOfTouches = 1
        selectGesture.allowedTouchTypes = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
        selectGesture.isEnabled = false
        imageView.addGestureRecognizer(selectGesture)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: UIImage, accessibilityTitle: String) {
        imageView.accessibilityLabel = accessibilityTitle
        guard imageView.image !== image else { return }
        minimumZoomScale = min(minimumZoomScale, 1)
        maximumZoomScale = max(maximumZoomScale, 1)
        setZoomScale(1, animated: false)
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        outline.frame = imageView.bounds
        contentSize = image.size
        previousViewportSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let viewportSize = bounds.size
        guard viewportSize != previousViewportSize,
              viewportSize.width > 0, viewportSize.height > 0,
              let image = imageView.image else { return }

        let hasLaidOut = previousViewportSize != .zero
        let oldCenter = CGPoint(x: bounds.minX + previousViewportSize.width / 2,
                                y: bounds.minY + previousViewportSize.height / 2)
        let focus = hasLaidOut ? convert(oldCenter, to: imageView)
            : CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY)
        let relativeScale = hasLaidOut ? max(1, min(6, zoomScale / minimumZoomScale)) : 1
        previousViewportSize = viewportSize

        let fit = min(viewportSize.width / image.size.width, viewportSize.height / image.size.height)
        maximumZoomScale = max(maximumZoomScale, fit * 6)
        minimumZoomScale = fit
        maximumZoomScale = fit * 6
        zoom(at: focus, scale: fit * relativeScale, animated: false)
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    private func centerImage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
        outline.lineWidth = 2 / zoomScale
    }

    func apply(_ request: ZoomRequest) {
        guard request.id != lastZoomRequest else { return }
        layoutIfNeeded()
        guard previousViewportSize != .zero else { return }
        lastZoomRequest = request.id

        let focus = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: imageView)
        switch request.action {
        case .fit:
            setZoomScale(minimumZoomScale, animated: true)
        case .smaller:
            zoom(at: focus, scale: max(minimumZoomScale, zoomScale / 1.5), animated: true)
        case .larger:
            zoom(at: focus, scale: min(maximumZoomScale, zoomScale * 1.5), animated: true)
        }
    }

    private func zoom(at focus: CGPoint, scale: CGFloat, animated: Bool) {
        let width = bounds.width / scale
        let height = bounds.height / scale
        zoom(to: CGRect(x: focus.x - width / 2, y: focus.y - height / 2,
                        width: width, height: height), animated: animated)
    }

    func setSelection(_ selection: NormalizedCrop?, isSelecting: Bool) {
        self.selection = selection
        selectGesture.isEnabled = isSelecting
        panGestureRecognizer.isEnabled = !isSelecting
        pinchGestureRecognizer?.isEnabled = !isSelecting
        if dragStart == nil { showSelection() }
    }

    private func showSelection() {
        guard let selection else {
            outline.path = nil
            return
        }
        let size = imageView.bounds.size
        let rectangle = CGRect(x: CGFloat(selection.x) * size.width, y: CGFloat(selection.y) * size.height,
                               width: CGFloat(selection.width) * size.width,
                               height: CGFloat(selection.height) * size.height)
        outline.path = UIBezierPath(rect: rectangle).cgPath
    }

    @objc private func dragSelection(_ gesture: UIPanGestureRecognizer) {
        // Converting to the image view removes the current scroll offset and zoom.
        let point = gesture.location(in: imageView)
        switch gesture.state {
        case .began:
            let translation = gesture.translation(in: imageView)
            dragStart = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            onDraggingChanged?(true)
            if let dragStart { outline.path = UIBezierPath(rect: rectangle(from: dragStart, to: point)).cgPath }
        case .changed:
            if let dragStart { outline.path = UIBezierPath(rect: rectangle(from: dragStart, to: point)).cgPath }
        case .ended:
            guard let start = dragStart else { return }
            dragStart = nil
            selection = normalizedCrop(for: rectangle(from: start, to: point))
            showSelection()
            onSelection?(selection)
            onDraggingChanged?(false)
        case .cancelled, .failed:
            guard dragStart != nil else { return }
            dragStart = nil
            showSelection()
            onDraggingChanged?(false)
        default:
            break
        }
    }

    private func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        let size = imageView.bounds.size
        let startX = min(max(start.x, 0), size.width)
        let startY = min(max(start.y, 0), size.height)
        let endX = min(max(end.x, 0), size.width)
        let endY = min(max(end.y, 0), size.height)
        return CGRect(x: min(startX, endX), y: min(startY, endY),
                      width: abs(startX - endX), height: abs(startY - endY))
    }

    private func normalizedCrop(for rectangle: CGRect) -> NormalizedCrop? {
        guard rectangle.width * zoomScale >= 6, rectangle.height * zoomScale >= 6 else { return nil }
        let size = imageView.bounds.size
        let x = Double(rectangle.minX / size.width)
        let y = Double(rectangle.minY / size.height)
        let right = min(1, Double(rectangle.maxX / size.width))
        let bottom = min(1, Double(rectangle.maxY / size.height))
        let crop = NormalizedCrop(x: x, y: y, width: right - x, height: bottom - y)
        return crop.isValid ? crop : nil
    }
}

@MainActor
private enum QuestionPDFRenderer {
    static func render(
        page: PDFPage,
        crop: NormalizedCrop = NormalizedCrop(x: 0, y: 0, width: 1, height: 1),
        maximumDimension: CGFloat
    ) -> UIImage? {
        guard crop.isValid, let source = page.pageRef else { return nil }
        let mediaBounds = source.getBoxRect(.mediaBox)
        let cropBounds = source.getBoxRect(.cropBox)
        let displayBox: CGPDFBox = cropBounds.isEmpty ? .mediaBox : .cropBox
        let bounds = displayBox == .cropBox ? cropBounds.intersection(mediaBounds) : mediaBounds
        guard !bounds.isEmpty, bounds.width.isFinite, bounds.height.isFinite else { return nil }

        let swapsAxes = source.rotationAngle % 180 != 0
        let pageWidth = swapsAxes ? bounds.height : bounds.width
        let pageHeight = swapsAxes ? bounds.width : bounds.height
        let cropWidth = pageWidth * CGFloat(crop.width)
        let cropHeight = pageHeight * CGFloat(crop.height)
        let scale = maximumDimension / max(cropWidth, cropHeight)
        let size = CGSize(width: cropWidth * scale, height: cropHeight * scale)
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1 else { return nil }

        let fullWidth = pageWidth * scale
        let fullHeight = pageHeight * scale
        // The crop uses a top-left origin. The PDF drawing target uses a bottom-left origin.
        let target = CGRect(
            x: -CGFloat(crop.x) * fullWidth,
            y: (CGFloat(crop.y + crop.height) - 1) * fullHeight,
            width: fullWidth,
            height: fullHeight
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            // rotate: 0 applies the PDF's own rotation without an additional rotation.
            context.concatenate(source.getDrawingTransform(displayBox, rect: target,
                                                            rotate: 0, preserveAspectRatio: true))
            context.clip(to: bounds)
            context.drawPDFPage(source)
        }
    }
}
