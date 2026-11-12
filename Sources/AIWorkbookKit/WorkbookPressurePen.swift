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
    private static let estimatedProperties: UITouch.Properties = [.location, .force, .altitude, .azimuth]

    let toolPicker: PKToolPicker
    private weak var canvas: PKCanvasView?
    private var onDrawingChange: ((PKCanvasView) -> Void)?
    private var onStrokeActivity: ((Bool) -> Void)?
    private let gesture = PressurePenGesture(target: nil, action: nil)
    private let overlay = PressurePenOverlay()
    private var stroke: Stroke?
    private var finishTask: Task<Void, Never>?
    private var clearOverlayTask: Task<Void, Never>?

    private struct Sample {
        var location: CGPoint
        let time: TimeInterval
        var force: CGFloat
        var altitude: CGFloat
        var azimuth: CGFloat

        @MainActor
        init(touch: UITouch, in view: UIView) {
            location = touch.preciseLocation(in: view)
            time = touch.timestamp
            force = touch.force
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

        func width(forForce force: CGFloat) -> CGFloat {
            // UIKit's nominal writing force is 1.0. Map it to the base width.
            let normalized = max(0, force) / (1 + max(0, force))
            return baseWidth * (1 + sensitivity * (normalized - 0.5) * 1.65)
        }

        func widths(for samples: [Sample], taperEnd: Bool) -> [CGFloat] {
            let widths = samples.indices.map { index in
                let before = samples[max(samples.startIndex, index - 1)].force
                let after = samples[min(samples.count - 1, index + 1)].force
                return width(forForce: (before + samples[index].force * 2 + after) / 4)
            }
            var distances: [CGFloat] = [0]
            for index in samples.indices.dropFirst() {
                let previous = samples[index - 1].location
                let point = samples[index].location
                distances.append(distances[index - 1] + hypot(point.x - previous.x, point.y - previous.y))
            }
            guard let length = distances.last, length > 6 else { return widths }
            let taperLength = min(baseWidth * 2.5, length / 4)
            return zip(widths, distances).map { width, distance in
                let start = 0.82 + 0.18 * min(distance / taperLength, 1)
                let end = taperEnd ? 0.72 + 0.28 * min((length - distance) / taperLength, 1) : 1
                return width * start * end
            }
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
        overlay.isUserInteractionEnabled = false
        overlay.isAccessibilityElement = false
        overlay.isOpaque = false
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    func attach(to canvas: PKCanvasView,
                onDrawingChange: @escaping (PKCanvasView) -> Void,
                onStrokeActivity: ((Bool) -> Void)? = nil) {
        if self.canvas != nil { detach() }
        self.canvas = canvas
        self.onDrawingChange = onDrawingChange
        self.onStrokeActivity = onStrokeActivity
        canvas.overrideUserInterfaceStyle = .light
        overlay.frame = canvas.bounds
        canvas.addSubview(overlay)
        canvas.addGestureRecognizer(gesture)
        toolPicker.addObserver(self)
        toolPickerSelectedToolItemDidChange(toolPicker)
    }

    func detach() {
        flush()
        clearOverlayTask?.cancel()
        clearOverlayTask = nil
        overlay.clear()
        canvas?.undoManager?.removeAllActions(withTarget: self)
        canvas?.isDrawingEnabled = true
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
        canvas?.isDrawingEnabled = !usesPressurePen && toolPicker.selectedToolItem.tool != nil
        gesture.isEnabled = usesPressurePen
    }

    fileprivate func begin(_ touch: UITouch, event: UIEvent) -> Bool {
        guard let canvas,
              let item = toolPicker.selectedToolItem as? PKToolPickerCustomItem,
              item.identifier == Self.itemID else { return false }
        flush()
        clearOverlayTask?.cancel()
        clearOverlayTask = nil
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
        canvas.bringSubviewToFront(overlay)
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
        renderPreview()
        onStrokeActivity?(false)
        finishIfReady()
        if stroke != nil {
            finishTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(45))
                guard !Task.isCancelled else { return }
                self?.commitStroke()
            }
        }
    }

    fileprivate func cancel() {
        guard stroke?.isActive == true else { return }
        stroke = nil
        overlay.clear()
        onStrokeActivity?(false)
    }

    fileprivate func updateEstimates(_ touches: Set<UITouch>) {
        guard let canvas, stroke != nil else { return }
        for touch in touches {
            guard let key = touch.estimationUpdateIndex,
                  let index = stroke?.pendingEstimates[key] else { continue }
            let expecting = touch.estimatedPropertiesExpectingUpdates
            if !expecting.contains(.location), stroke?.isActive == true {
                stroke?.samples[index].location = touch.preciseLocation(in: canvas)
            }
            if !expecting.contains(.force) { stroke?.samples[index].force = touch.force }
            if !expecting.contains(.altitude) { stroke?.samples[index].altitude = touch.altitudeAngle }
            if !expecting.contains(.azimuth) { stroke?.samples[index].azimuth = touch.azimuthAngle(in: canvas) }
            if expecting.isDisjoint(with: Self.estimatedProperties) {
                stroke?.pendingEstimates.removeValue(forKey: key)
            }
        }
        renderPreview()
        finishIfReady()
    }

    private func addSamples(for touch: UITouch, event: UIEvent, predicts: Bool) {
        guard let canvas, stroke?.isActive == true else { return }
        let coalesced = event.coalescedTouches(for: touch) ?? []
        for sampleTouch in coalesced.isEmpty ? [touch] : coalesced {
            let sample = Sample(touch: sampleTouch, in: canvas)
            if let last = stroke?.samples.last, sample.time <= last.time { continue }
            let index = stroke?.samples.count ?? 0
            stroke?.samples.append(sample)
            if let key = sampleTouch.estimationUpdateIndex,
               !sampleTouch.estimatedPropertiesExpectingUpdates.isDisjoint(with: Self.estimatedProperties) {
                stroke?.pendingEstimates[key] = index
            }
        }
        let predictions = predicts ? event.predictedTouches(for: touch) ?? [] : []
        stroke?.predictions = predictions.map { Sample(touch: $0, in: canvas) }
        if predicts { renderPreview() }
    }

    private func renderPreview() {
        guard let stroke else { return }
        let samples = stroke.samples + stroke.predictions
        overlay.display(points: samples.map(\.location),
                        widths: stroke.widths(for: samples, taperEnd: !stroke.isActive),
                        color: stroke.color)
    }

    private func finishIfReady() {
        if let stroke, !stroke.isActive, stroke.pendingEstimates.isEmpty { commitStroke() }
    }

    private func commitStroke() {
        finishTask?.cancel()
        finishTask = nil
        guard let stroke else { return }
        self.stroke = nil
        guard let canvas, let first = stroke.samples.first else { return }
        let widths = stroke.widths(for: stroke.samples, taperEnd: true)
        var points = zip(stroke.samples, widths).map { sample, width in
            PKStrokePoint(location: sample.location, timeOffset: sample.time - first.time,
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
        overlay.display(points: stroke.samples.map(\.location), widths: widths, color: stroke.color)
        replaceDrawing(canvas.drawing.appending(PKDrawing(strokes: [penStroke])))

        // Keep the live ink visible for one brief tile-rendering handoff.
        clearOverlayTask?.cancel()
        clearOverlayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            self?.overlay.clear()
        }
    }

    private func replaceDrawing(_ drawing: PKDrawing) {
        guard let canvas else { return }
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

@MainActor
private final class PressurePenOverlay: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }

    private var inkLayer: CAShapeLayer { layer as! CAShapeLayer }

    func display(points: [CGPoint], widths: [CGFloat], color: UIColor) {
        let shape = CGMutablePath()
        for index in points.indices {
            let point = points[index]
            let radius = widths[index] / 2
            shape.move(to: CGPoint(x: point.x + radius, y: point.y))
            shape.addArc(center: point, radius: radius, startAngle: 0, endAngle: -.pi, clockwise: true)
            shape.addArc(center: point, radius: radius, startAngle: -.pi, endAngle: -.pi * 2, clockwise: true)
            shape.closeSubpath()
            guard index > 0 else { continue }
            let previous = points[index - 1]
            let length = hypot(point.x - previous.x, point.y - previous.y)
            guard length > 0 else { continue }
            let normal = CGVector(dx: (previous.y - point.y) / length, dy: (point.x - previous.x) / length)
            let previousRadius = widths[index - 1] / 2
            shape.move(to: CGPoint(x: previous.x + normal.dx * previousRadius,
                                   y: previous.y + normal.dy * previousRadius))
            shape.addLine(to: CGPoint(x: point.x + normal.dx * radius, y: point.y + normal.dy * radius))
            shape.addLine(to: CGPoint(x: point.x - normal.dx * radius, y: point.y - normal.dy * radius))
            shape.addLine(to: CGPoint(x: previous.x - normal.dx * previousRadius,
                                      y: previous.y - normal.dy * previousRadius))
            shape.closeSubpath()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.fillColor = color.cgColor
        inkLayer.path = shape
        CATransaction.commit()
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.path = nil
        CATransaction.commit()
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
