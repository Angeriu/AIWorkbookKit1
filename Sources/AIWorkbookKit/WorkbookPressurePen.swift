import PencilKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

private enum PressurePenPreferences {
    static let sensitivityKey = "AIWorkbook.PressurePen.Sensitivity"
    static let widthKey = "AIWorkbook.PressurePen.Width"
    static let defaultSensitivity = 0.65
    static let defaultWidth: CGFloat = 3.0
}

@MainActor
final class WorkbookPressurePen: NSObject, PKToolPickerObserver {
    private static let itemID = "aiworkbook.pressure-pen"

    let toolPicker: PKToolPicker
    private weak var canvas: PKCanvasView?
    private var onDrawingChange: ((PKCanvasView) -> Void)?
    private var onStrokeActivity: ((Bool) -> Void)?
    private let gesture = PressurePenGesture(target: nil, action: nil)
    private var overlay = PressurePenOverlay()
    private var stroke: Stroke?
    private var finishTask: Task<Void, Never>?
    private var handoffs: [InkHandoff] = []

    private struct InkHandoff {
        let id: UUID
        let overlay: PressurePenOverlay
        let fallback: Task<Void, Never>
        let submittedAt: CFTimeInterval
    }

    private struct Sample {
        let location: CGPoint
        let time: TimeInterval
        var force: CGFloat
        var altitude: CGFloat
        var azimuth: CGFloat

        @MainActor
        init(touch: UITouch, in view: UIView, previousForce: CGFloat?) {
            location = touch.preciseLocation(in: view)
            time = touch.timestamp
            let measuredForce = touch.force
            force = measuredForce == 0 && touch.estimatedPropertiesExpectingUpdates.contains(.force)
                ? previousForce ?? 0 : measuredForce
            altitude = touch.altitudeAngle
            azimuth = touch.azimuthAngle(in: view)
        }
    }

    private struct Stroke {
        let startedAt: Date
        let color: UIColor
        let baseWidth: CGFloat
        let sensitivity: CGFloat
        var samples: [Sample] = []
        var predictions: [Sample] = []
        var pendingEstimates: [NSNumber: Int] = [:]
        var isActive = true

        var previewCount: Int { samples.count + predictions.count }

        func width(forForce force: CGFloat) -> CGFloat {
            let force = force.isFinite ? max(0, force) : 0
            let response = force / (force + 0.45)
            let relativeWidth = 1 + sensitivity * (response - 0.55) * 2.2
            return baseWidth * max(0.30, relativeWidth)
        }

        func node(at index: Int) -> PressureInkNode {
            if index >= samples.count {
                return PressureInkNode(location: predictions[index - samples.count].location,
                                       width: confirmedWidth(at: samples.count - 1))
            }
            return PressureInkNode(location: samples[index].location, width: confirmedWidth(at: index))
        }

        private func confirmedWidth(at index: Int) -> CGFloat {
            let force = samples[index].force
            let previous = samples[max(0, index - 1)].force
            return width(forForce: force * 0.85 + previous * 0.15)
        }
    }

    init(baseWidth: CGFloat = 3) {
        let savedWidth = UserDefaults.standard.object(forKey: PressurePenPreferences.widthKey) as? Double
        let item = Self.makePressurePenItem(baseWidth: savedWidth.map { CGFloat($0) } ?? baseWidth)
        toolPicker = PKToolPicker(toolItems: [item] + PKToolPicker.defaultToolItems)
        super.init()

        toolPicker.stateAutosaveName = nil
        toolPicker.colorUserInterfaceStyle = .light
        toolPicker.overrideUserInterfaceStyle = .light
        toolPicker.showsDrawingPolicyControls = false
        toolPicker.selectedToolItem = item

        gesture.pen = self
        gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        gesture.cancelsTouchesInView = false
    }

    func attach(to canvas: PKCanvasView,
                onDrawingChange: @escaping (PKCanvasView) -> Void,
                onStrokeActivity: ((Bool) -> Void)? = nil) {
        if self.canvas != nil { detach() }
        self.canvas = canvas
        self.onDrawingChange = onDrawingChange
        self.onStrokeActivity = onStrokeActivity
        canvas.overrideUserInterfaceStyle = .light
        canvas.addGestureRecognizer(gesture)
        toolPicker.addObserver(self)
        toolPickerSelectedToolItemDidChange(toolPicker)
    }

    func detach() {
        flush()
        clearHandoffs()
        overlay.clear()
        canvas?.undoManager?.removeAllActions(withTarget: self)
        canvas?.isDrawingEnabled = true
        canvas?.drawingGestureRecognizer.isEnabled = true
        canvas?.removeGestureRecognizer(gesture)
        overlay.removeFromSuperview()
        toolPicker.removeObserver(self)
        canvas = nil
        onDrawingChange = nil
        onStrokeActivity = nil
    }

    func flush() {
        if stroke?.isActive == true { onStrokeActivity?(false) }
        commitStroke()
    }

    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        let usesPressurePen = toolPicker.selectedToolItem.identifier == Self.itemID
        if !usesPressurePen { flush() }
        // Keep the initial canvas consistent even before its picker observation starts.
        let usesNativeDrawing = !usesPressurePen && toolPicker.selectedToolItem.tool != nil
        canvas?.isDrawingEnabled = usesNativeDrawing
        canvas?.drawingGestureRecognizer.isEnabled = usesNativeDrawing
        gesture.isEnabled = usesPressurePen
    }

    fileprivate func begin(_ touch: UITouch, event: UIEvent) -> Bool {
        guard let canvas,
              let item = toolPicker.selectedToolItem as? PKToolPickerCustomItem,
              item.identifier == Self.itemID else { return false }
        flush()
        canvas.drawingGestureRecognizer.isEnabled = false
        let defaults = UserDefaults.standard
        let sensitivity = defaults.object(forKey: PressurePenPreferences.sensitivityKey) as? Double
            ?? PressurePenPreferences.defaultSensitivity
        let width = item.width > 0 ? item.width : PressurePenPreferences.defaultWidth
        if defaults.double(forKey: PressurePenPreferences.widthKey) != Double(width) {
            defaults.set(Double(width), forKey: PressurePenPreferences.widthKey)
        }
        stroke = Stroke(startedAt: Date(),
                        color: item.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)),
                        baseWidth: width,
                        sensitivity: CGFloat(min(max(sensitivity, 0), 1)))
        overlay.frame = canvas.bounds
        canvas.addSubview(overlay)
        onStrokeActivity?(true)
        addSamples(for: touch, event: event, predicts: true)
        return true
    }

    fileprivate func move(_ touch: UITouch, event: UIEvent) {
        addSamples(for: touch, event: event, predicts: true)
    }

    fileprivate func end(_ touch: UITouch, event: UIEvent) {
        guard stroke?.isActive == true else { return }
        addSamples(for: touch, event: event, predicts: false)
        stroke?.isActive = false
        onStrokeActivity?(false)
        finishIfReady()
        if stroke != nil {
            finishTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                self?.commitStroke()
            }
        }
    }

    fileprivate func cancel() {
        guard stroke?.isActive == true else { return }
        stroke = nil
        overlay.clear()
        overlay.removeFromSuperview()
        onStrokeActivity?(false)
    }

    fileprivate func updateEstimates(_ touches: Set<UITouch>) {
        guard let canvas, stroke != nil else { return }
        var dirtyFrom: Int?
        for touch in touches {
            guard let key = touch.estimationUpdateIndex,
                  let index = stroke?.pendingEstimates[key] else { continue }
            let expecting = touch.estimatedPropertiesExpectingUpdates
            if !expecting.contains(.force) { stroke?.samples[index].force = touch.force }
            if !expecting.contains(.altitude) { stroke?.samples[index].altitude = touch.altitudeAngle }
            if !expecting.contains(.azimuth) { stroke?.samples[index].azimuth = touch.azimuthAngle(in: canvas) }
            if !expecting.contains(.force) {
                stroke?.pendingEstimates.removeValue(forKey: key)
            }
            dirtyFrom = min(dirtyFrom ?? index, index)
        }
        if let dirtyFrom { renderPreview(from: dirtyFrom) }
        finishIfReady()
    }

    private func addSamples(for touch: UITouch, event: UIEvent, predicts: Bool) {
        guard let canvas, stroke?.isActive == true else { return }
        let oldCount = stroke?.samples.count ?? 0
        let coalesced = event.coalescedTouches(for: touch) ?? []
        for sampleTouch in coalesced + [touch] {
            let sample = Sample(touch: sampleTouch, in: canvas, previousForce: stroke?.samples.last?.force)
            if let last = stroke?.samples.last, sample.time <= last.time { continue }
            if !predicts, sampleTouch.phase == .ended,
               let last = stroke?.samples.last,
               hypot(last.location.x - sample.location.x, last.location.y - sample.location.y) < 0.15 { continue }
            let index = stroke?.samples.count ?? 0
            stroke?.samples.append(sample)
            if let key = sampleTouch.estimationUpdateIndex,
               sampleTouch.estimatedPropertiesExpectingUpdates.contains(.force) {
                stroke?.pendingEstimates[key] = index
            }
        }
        let predictions = predicts ? event.predictedTouches(for: touch) ?? [] : []
        let latest = stroke?.samples.last
        stroke?.predictions = predictions.lazy.filter { $0.timestamp > (latest?.time ?? touch.timestamp) }
            .prefix(3).map { Sample(touch: $0, in: canvas, previousForce: latest?.force) }
        renderPreview(from: oldCount)
    }

    private func renderPreview(from dirtyFrom: Int) {
        guard let stroke else { return }
        overlay.display(count: stroke.previewCount, dirtyFrom: dirtyFrom,
                        color: stroke.color, nodeAt: stroke.node(at:))
    }

    private func finishIfReady() {
        if let stroke, !stroke.isActive,
           stroke.pendingEstimates.isEmpty { commitStroke() }
    }

    private func commitStroke() {
        finishTask?.cancel()
        finishTask = nil
        guard var stroke else { return }
        self.stroke = nil
        guard let canvas, let first = stroke.samples.first else { return }
        stroke.predictions.removeAll()
        var points = stroke.samples.indices.map { index in
            let sample = stroke.samples[index]
            let width = stroke.node(at: index).width
            return PKStrokePoint(location: sample.location, timeOffset: sample.time - first.time,
                          size: CGSize(width: width, height: width), opacity: 1,
                          force: sample.force, azimuth: sample.azimuth, altitude: sample.altitude)
        }
        if let point = points.first, points.allSatisfy({ $0.location == point.location }) {
            // A subpoint segment makes a tap visible as a round dot on a cubic path.
            points = (0..<4).map { index in
                let location = CGPoint(x: point.location.x + CGFloat(index) * 0.05, y: point.location.y)
                return PKStrokePoint(location: location, timeOffset: Double(index) * 0.001,
                                     size: point.size, opacity: point.opacity, force: point.force,
                                     azimuth: point.azimuth, altitude: point.altitude)
            }
        }
        let path = PKStrokePath(controlPoints: points, creationDate: stroke.startedAt)
        let ink = PKInk(.pen, color: stroke.color)
        let penStroke = PKStroke(ink: ink, path: path)
        overlay.display(count: stroke.samples.count, dirtyFrom: stroke.samples.count,
                        color: stroke.color, nodeAt: stroke.node(at:))
        let id = UUID()
        let fallback = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(72))
            guard !Task.isCancelled else { return }
            self?.finishHandoff(id)
        }
        handoffs.append(InkHandoff(id: id, overlay: overlay, fallback: fallback,
                                    submittedAt: CACurrentMediaTime()))
        overlay = PressurePenOverlay()
        replaceDrawing(canvas.drawing.appending(PKDrawing(strokes: [penStroke])), keepsHandoffs: true)
    }

    func canvasDidFinishRendering(_ canvas: PKCanvasView) {
        guard canvas === self.canvas else { return }
        // A callback can also be for earlier tiles or scrolling. Keep the most
        // recent submission visible for at least one display frame in that case.
        let refreshRate = max(60, canvas.window?.screen.maximumFramesPerSecond ?? 60)
        let cutoff = CACurrentMediaTime() - 1 / Double(refreshRate)
        for id in handoffs.filter({ $0.submittedAt <= cutoff }).map(\.id) {
            finishHandoff(id)
        }
    }

    private func finishHandoff(_ id: UUID) {
        guard let index = handoffs.firstIndex(where: { $0.id == id }) else { return }
        let handoff = handoffs.remove(at: index)
        handoff.fallback.cancel()
        handoff.overlay.removeFromSuperview()
    }

    private func clearHandoffs() {
        for handoff in handoffs {
            handoff.fallback.cancel()
            handoff.overlay.removeFromSuperview()
        }
        handoffs.removeAll()
    }

    private func replaceDrawing(_ drawing: PKDrawing, keepsHandoffs: Bool = false) {
        guard let canvas else { return }
        if !keepsHandoffs { clearHandoffs() }
        let previous = canvas.drawing
        if let undo = canvas.undoManager {
            undo.disableUndoRegistration()
            canvas.drawing = drawing
            undo.enableUndoRegistration()
            undo.registerUndo(withTarget: self) { pen in pen.replaceDrawing(previous) }
            undo.setActionName("书写")
        } else {
            canvas.drawing = drawing
        }
        onDrawingChange?(canvas)
    }

    private static func makePressurePenItem(baseWidth: CGFloat) -> PKToolPickerCustomItem {
        var configuration = PKToolPickerCustomItem.Configuration(identifier: itemID, name: "压感笔")
        configuration.defaultColor = UIColor(white: 0.04, alpha: 1)
        configuration.allowsColorSelection = true
        let widths: [CGFloat] = [1.5, 2, 3, 4.5, 6]
        configuration.defaultWidth = widths.min(by: { abs($0 - baseWidth) < abs($1 - baseWidth) })
            ?? PressurePenPreferences.defaultWidth
        configuration.widthVariants = Dictionary(uniqueKeysWithValues: widths.map { ($0, widthIcon($0)) })
        configuration.imageProvider = { item in
            UIImage(systemName: "pencil.tip")?.withTintColor(item.color, renderingMode: .alwaysOriginal) ?? UIImage()
        }
        configuration.viewControllerProvider = { _ in
            let controller = UIHostingController(rootView: PressurePenSettings())
            controller.preferredContentSize = CGSize(width: 240, height: 76)
            controller.view.backgroundColor = .clear
            return controller
        }
        return PKToolPickerCustomItem(configuration: configuration)
    }

    private static func widthIcon(_ width: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 36, height: 20)).image { context in
            let drawing = context.cgContext
            drawing.setStrokeColor(UIColor.darkGray.cgColor)
            drawing.setLineWidth(width)
            drawing.setLineCap(.round)
            drawing.move(to: CGPoint(x: 6, y: 10))
            drawing.addLine(to: CGPoint(x: 30, y: 10))
            drawing.strokePath()
        }.withRenderingMode(.alwaysTemplate)
    }
}

@MainActor
private final class PressurePenGesture: UIGestureRecognizer {
    weak var pen: WorkbookPressurePen?
    private weak var activeTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible else { return }
        guard let touch = touches.first(where: { $0.type == .pencil }),
              pen?.begin(touch, event: event) == true else {
            state = .failed
            return
        }
        activeTouch = touch
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        pen?.move(touch, event: event)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        pen?.end(touch, event: event)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        pen?.cancel()
        state = .cancelled
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        pen?.updateEstimates(touches)
    }

    override func reset() {
        super.reset()
        activeTouch = nil
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

private struct PressureInkNode {
    let location: CGPoint
    let width: CGFloat
}

@MainActor
private final class PressurePenOverlay: UIView {
    private static let segmentsPerLayer = 32
    private var inkLayers: [CAShapeLayer] = []

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isOpaque = false
        layer.allowsGroupOpacity = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    required init?(coder: NSCoder) { fatalError("PressurePenOverlay is created in code") }

    func display(count: Int, dirtyFrom: Int, color: UIColor, nodeAt: (Int) -> PressureInkNode) {
        guard count > 0 else { clear(); return }
        let segmentCount = count - 1
        let requiredLayers = max(1, (segmentCount + Self.segmentsPerLayer - 1) / Self.segmentsPerLayer)
        // Centerline tangents depend on two neighboring points. Repaint only their chunks.
        let firstDirtyLayer = min(requiredLayers - 1, max(0, dirtyFrom - 2) / Self.segmentsPerLayer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = Float(color.cgColor.alpha)
        while inkLayers.count > requiredLayers { inkLayers.removeLast().removeFromSuperlayer() }
        while inkLayers.count < requiredLayers {
            let inkLayer = CAShapeLayer()
            inkLayer.contentsScale = max(1, traitCollection.displayScale)
            inkLayer.fillColor = color.withAlphaComponent(1).cgColor
            layer.addSublayer(inkLayer)
            inkLayers.append(inkLayer)
        }

        for index in firstDirtyLayer..<requiredLayers {
            let start = index * Self.segmentsPerLayer
            let end = min(segmentCount, start + Self.segmentsPerLayer + 1)
            let outline = Self.outline(from: start, to: end, count: count, nodeAt: nodeAt)
            let frame = outline.boundingBoxOfPath.insetBy(dx: -1, dy: -1).integral
            var offset = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
            let inkLayer = inkLayers[index]
            inkLayer.frame = frame
            inkLayer.path = outline.copy(using: &offset)
        }
        CATransaction.commit()
    }

    func clear() {
        for inkLayer in inkLayers { inkLayer.removeFromSuperlayer() }
        inkLayers.removeAll()
    }

    private static func outline(from start: Int, to end: Int, count: Int,
                                nodeAt: (Int) -> PressureInkNode) -> CGPath {
        let shape = CGMutablePath()
        let first = nodeAt(start)
        if start == end {
            let radius = first.width / 2
            shape.addEllipse(in: CGRect(x: first.location.x - radius, y: first.location.y - radius,
                                        width: first.width, height: first.width))
            return shape
        }

        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for index in start..<end {
            let first = nodeAt(index)
            let second = nodeAt(index + 1)
            let previous = index > 0 ? nodeAt(index - 1) : extrapolate(from: first, awayFrom: second)
            let next = index + 2 < count ? nodeAt(index + 2) : extrapolate(from: second, awayFrom: first)
            for subdivision in 0...4 where subdivision > 0 || index == start {
                let t = CGFloat(subdivision) / 4
                let curve = spline(previous.location, first.location, second.location, next.location, t: t)
                let dx = curve.tangent.x
                let dy = curve.tangent.y
                let length = hypot(dx, dy)
                if length < 0.0001, !left.isEmpty { continue }
                let width = spline(previous.width, first.width, second.width, next.width, t: t).value
                let radius = max(0.1, width / 2)
                let normal = length >= 0.0001 ? CGPoint(x: -dy / length, y: dx / length) : CGPoint(x: 0, y: 1)
                left.append(CGPoint(x: curve.point.x + normal.x * radius, y: curve.point.y + normal.y * radius))
                right.append(CGPoint(x: curve.point.x - normal.x * radius, y: curve.point.y - normal.y * radius))
            }
        }

        if let point = left.first {
            shape.move(to: point)
            for point in left.dropFirst() { shape.addLine(to: point) }
            for point in right.reversed() { shape.addLine(to: point) }
            shape.closeSubpath()
        }
        if start == 0, let leftEdge = left.first, let rightEdge = right.first {
            addCap(to: shape, left: leftEdge, right: rightEdge)
        }
        if end == count - 1, let leftEdge = left.last, let rightEdge = right.last {
            addCap(to: shape, left: leftEdge, right: rightEdge)
        }
        return shape
    }

    private static func addCap(to shape: CGMutablePath, left: CGPoint, right: CGPoint) {
        let center = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        let radius = hypot(left.x - right.x, left.y - right.y) / 2
        shape.move(to: CGPoint(x: center.x + radius, y: center.y))
        shape.addArc(center: center, radius: radius, startAngle: 0, endAngle: -.pi, clockwise: true)
        shape.addArc(center: center, radius: radius, startAngle: -.pi, endAngle: -2 * .pi, clockwise: true)
        shape.closeSubpath()
    }

    private static func extrapolate(from end: PressureInkNode, awayFrom next: PressureInkNode) -> PressureInkNode {
        PressureInkNode(location: CGPoint(x: 2 * end.location.x - next.location.x,
                                         y: 2 * end.location.y - next.location.y),
                        width: 2 * end.width - next.width)
    }

    private static func spline(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint,
                               t: CGFloat) -> (point: CGPoint, tangent: CGPoint) {
        let x = spline(a.x, b.x, c.x, d.x, t: t)
        let y = spline(a.y, b.y, c.y, d.y, t: t)
        return (CGPoint(x: x.value, y: y.value), CGPoint(x: x.slope, y: y.slope))
    }

    private static func spline(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat,
                               t: CGFloat) -> (value: CGFloat, slope: CGFloat) {
        // Evaluate the cubic B-spline between two consecutive PencilKit control points.
        let constant = (a + 4 * b + c) / 6
        let linear = (c - a) / 2
        let quadratic = (a - 2 * b + c) / 2
        let cubic = (d - a + 3 * (b - c)) / 6
        let value = constant + t * (linear + t * (quadratic + t * cubic))
        let slope = linear + t * (2 * quadratic + t * 3 * cubic)
        return (value, slope)
    }
}

private struct PressurePenSettings: View {
    @AppStorage(PressurePenPreferences.sensitivityKey) private var sensitivity = PressurePenPreferences.defaultSensitivity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("压感灵敏度").font(.subheadline)
            Slider(value: $sensitivity, in: 0...1)
                .accessibilityLabel("压感灵敏度")
        }
        .padding(.horizontal, 12)
    }
}
