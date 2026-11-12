import PDFKit
import UIKit

/// The persisted crop is measured from the top-left of the rotated, visible PDF page.
struct QuestionPDFGeometry {
    let pageBounds: CGRect
    let rotatedSize: CGSize
    private let pageToRotated: CGAffineTransform

    static let wholePage = CGRect(x: 0, y: 0, width: 1, height: 1)

    init?(page: PDFPage) {
        guard let source = page.pageRef else { return nil }
        let media = source.getBoxRect(.mediaBox)
        let crop = source.getBoxRect(.cropBox)
        let box: CGPDFBox = crop.isEmpty ? .mediaBox : .cropBox
        let bounds = box == .cropBox ? crop.intersection(media) : media
        guard !bounds.isEmpty,
              [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite)
        else { return nil }

        pageBounds = bounds
        rotatedSize = source.rotationAngle % 180 == 0 ? bounds.size
            : CGSize(width: bounds.height, height: bounds.width)
        pageToRotated = source.getDrawingTransform(
            box, rect: CGRect(origin: .zero, size: rotatedSize),
            rotate: 0, preserveAspectRatio: true
        )
    }

    func normalizedPoint(_ pagePoint: CGPoint) -> CGPoint {
        let point = pagePoint.applying(pageToRotated)
        return CGPoint(x: point.x / rotatedSize.width, y: 1 - point.y / rotatedSize.height)
    }

    func normalizedRect(_ pageRect: CGRect) -> CGRect {
        let rect = pageRect.applying(pageToRotated)
        return CGRect(x: rect.minX / rotatedSize.width, y: 1 - rect.maxY / rotatedSize.height,
                      width: rect.width / rotatedSize.width, height: rect.height / rotatedSize.height)
    }

    func pagePoint(_ normalizedPoint: CGPoint) -> CGPoint {
        let point = CGPoint(x: normalizedPoint.x * rotatedSize.width,
                            y: (1 - normalizedPoint.y) * rotatedSize.height)
        return point.applying(pageToRotated.inverted())
    }

    func pageRect(_ normalizedRect: CGRect) -> CGRect {
        let rect = CGRect(x: normalizedRect.minX * rotatedSize.width,
                          y: (1 - normalizedRect.maxY) * rotatedSize.height,
                          width: normalizedRect.width * rotatedSize.width,
                          height: normalizedRect.height * rotatedSize.height)
        return rect.applying(pageToRotated.inverted()).intersection(pageBounds)
    }

    static func normalizedRect(_ crop: NormalizedCrop) -> CGRect {
        CGRect(x: CGFloat(crop.x), y: CGFloat(crop.y),
               width: CGFloat(crop.width), height: CGFloat(crop.height))
    }

    static func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }
}

@MainActor
final class QuestionPDFDisplay {
    let geometry: QuestionPDFGeometry
    let document: PDFDocument
    let page: PDFPage
    let region: CGRect
    let contentRegion: CGRect?
    let looksEmpty: Bool

    init?(source: PDFPage, crop: NormalizedCrop?) {
        guard let geometry = QuestionPDFGeometry(page: source) else { return nil }

        let document: PDFDocument
        let copy: PDFPage
        if let pageCopy = source.copy() as? PDFPage, pageCopy !== source {
            document = PDFDocument()
            document.insert(pageCopy, at: 0)
            copy = pageCopy
        } else if let data = source.dataRepresentation,
                  let standalone = PDFDocument(data: data),
                  let standalonePage = standalone.page(at: 0),
                  standalonePage.bounds(for: .mediaBox) == source.bounds(for: .mediaBox),
                  standalonePage.rotation == source.rotation {
            document = standalone
            copy = standalonePage
        } else {
            return nil
        }
        copy.displaysAnnotations = source.displaysAnnotations

        let region: CGRect
        if let crop {
            guard crop.isValid else { return nil }
            region = QuestionPDFGeometry.normalizedRect(crop)
                .intersection(QuestionPDFGeometry.wholePage)
            let bounds = geometry.pageRect(region)
            guard !bounds.isEmpty else { return nil }
            copy.setBounds(bounds, for: .cropBox)
        } else {
            region = QuestionPDFGeometry.wholePage
        }

        self.geometry = geometry
        self.document = document
        page = copy
        self.region = region

        let sampleSize = CGSize(width: region.width * geometry.rotatedSize.width,
                                height: region.height * geometry.rotatedSize.height)
        let sample = PDFInkSample.make(page: copy, pageSize: sampleSize)
        var foreground = CGRect.null
        if let localBounds = sample?.foreground {
            foreground = CGRect(x: region.minX + localBounds.minX * region.width,
                                y: region.minY + localBounds.minY * region.height,
                                width: localBounds.width * region.width,
                                height: localBounds.height * region.height)
        }

        // Keep visible PDF annotations in frame even if a thumbnail omits them.
        for annotation in copy.annotations where copy.displaysAnnotations && annotation.shouldDisplay {
            let bounds = geometry.normalizedRect(annotation.bounds).intersection(region)
            if !bounds.isEmpty { foreground = foreground.union(bounds) }
        }
        looksEmpty = sample?.looksEmpty == true && foreground.isEmpty

        if foreground.isEmpty {
            contentRegion = nil
        } else {
            contentRegion = foreground
                .insetBy(dx: -region.width * 0.035, dy: -region.height * 0.035)
                .intersection(region)
        }
    }
}

/// A bounded thumbnail is used only to choose a starting camera position.
@MainActor
private struct PDFInkSample {
    let foreground: CGRect?
    let looksEmpty: Bool

    private struct Pixel {
        let red: Int
        let green: Int
        let blue: Int

        func distance(to other: Pixel) -> Int {
            max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
        }
    }

    static func make(page: PDFPage, pageSize: CGSize) -> PDFInkSample? {
        guard pageSize.width > 0, pageSize.height > 0,
              pageSize.width.isFinite, pageSize.height.isFinite else { return nil }
        let scale = 768 / max(pageSize.width, pageSize.height)
        guard scale.isFinite else { return nil }
        let size = CGSize(width: max(1, (pageSize.width * scale).rounded()),
                          height: max(1, (pageSize.height * scale).rounded()))
        let thumbnail = page.thumbnail(of: size, for: .cropBox)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let frame = CGRect(origin: .zero, size: size)
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.fill(frame)
            thumbnail.draw(in: frame)
        }
        guard let image = upright.cgImage,
              image.width <= 3072, image.height <= 3072 else { return nil }
        let width = Int(size.width)
        let height = Int(size.height)
        let bytesPerRow = width * 4
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                     space: colorSpace, bitmapInfo: bitmapInfo),
              let data = bitmap.data else { return nil }

        bitmap.draw(image, in: frame)
        let bytes = data.assumingMemoryBound(to: UInt8.self)

        func pixel(_ x: Int, _ y: Int) -> Pixel {
            let index = y * bytesPerRow + x * 4
            return Pixel(red: Int(bytes[index]), green: Int(bytes[index + 1]), blue: Int(bytes[index + 2]))
        }

        var edges: [Pixel] = []
        for x in stride(from: 0, to: width, by: 4) {
            edges.append(pixel(x, 0))
            edges.append(pixel(x, height - 1))
        }
        for y in stride(from: 0, to: height, by: 4) {
            edges.append(pixel(0, y))
            edges.append(pixel(width - 1, y))
        }
        func median(_ channel: KeyPath<Pixel, Int>) -> Int {
            edges.map { $0[keyPath: channel] }.sorted()[edges.count / 2]
        }
        let background = Pixel(red: median(\.red), green: median(\.green), blue: median(\.blue))
        let borderIsConsistent = edges.filter { $0.distance(to: background) <= 18 }.count * 10
            >= edges.count * 9
        let nearWhiteBackground = min(background.red, background.green, background.blue) >= 235
        var looksEmpty = nearWhiteBackground
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let distance = pixel(x, y).distance(to: background)
                if distance > 6 { looksEmpty = false }
                if borderIsConsistent && distance > 18 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else {
            return PDFInkSample(foreground: nil, looksEmpty: looksEmpty)
        }

        let foreground = CGRect(x: CGFloat(minX) / CGFloat(width),
                                y: CGFloat(minY) / CGFloat(height),
                                width: CGFloat(maxX - minX + 1) / CGFloat(width),
                                height: CGFloat(maxY - minY + 1) / CGFloat(height))
        return PDFInkSample(foreground: foreground, looksEmpty: false)
    }
}
