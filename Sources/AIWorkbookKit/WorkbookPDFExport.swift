import PDFKit
import PencilKit
import UIKit

@MainActor
enum WorkbookPDFExport {
    private static let pageBounds = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    private static let margin: CGFloat = 32

    static func render(
        document: PDFDocument,
        questions: [WorkbookQuestion],
        drawingForPage: (UUID, UUID) throws -> PKDrawing
    ) throws -> Data {
        let pageCount = questions.reduce(0) { $0 + $1.answerPages.count }
        guard pageCount > 0 else { throw ExportError.noAnswers }

        var renderError: Error?
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        let data = renderer.pdfData { context in
            do {
                for question in questions {
                    guard let page = document.page(at: question.sourcePageIndex),
                          let crop = SourceCrop(page: page, crop: question.crop) else {
                        throw ExportError.invalidQuestion(question.title)
                    }
                    for (index, sheet) in question.answerPages.enumerated() {
                        try autoreleasepool {
                            let drawing: PKDrawing
                            do {
                                drawing = try drawingForPage(question.id, sheet.id)
                            } catch {
                                throw ExportError.drawingRead(question.title, index + 1, error)
                            }

                            context.beginPage()
                            try drawPage(question: question, sheetIndex: index, crop: crop,
                                         drawing: drawing, in: context.cgContext)
                        }
                    }
                }
            } catch {
                renderError = error
            }
        }

        if let renderError { throw renderError }
        guard PDFDocument(data: data)?.pageCount == pageCount else {
            throw ExportError.invalidOutput
        }
        return data
    }

    private static func drawPage(
        question: WorkbookQuestion,
        sheetIndex: Int,
        crop: SourceCrop,
        drawing: PKDrawing,
        in context: CGContext
    ) throws {
        context.setFillColor(UIColor.white.cgColor)
        context.fill(pageBounds)

        let contentWidth = pageBounds.width - margin * 2
        let titleRect = CGRect(x: margin, y: margin, width: contentWidth, height: 26)
        drawLabel(question.title, font: .boldSystemFont(ofSize: 20), in: titleRect)
        let subtitleRect = CGRect(x: margin, y: titleRect.maxY + 2, width: contentWidth, height: 18)
        let subtitle = "原 PDF 第 \(question.sourcePageIndex + 1) 页 · 答题纸 \(sheetIndex + 1) / \(question.answerPages.count)"
        drawLabel(subtitle, font: .systemFont(ofSize: 10), in: subtitleRect)

        let questionArea = CGRect(x: margin, y: subtitleRect.maxY + 12, width: contentWidth,
                                  height: pageBounds.height * 0.32)
        let questionRect = fittedRect(for: crop.size, in: questionArea)
        crop.draw(in: questionRect, context: context)

        let answerTop = questionRect.maxY + 14
        let answerArea = CGRect(x: margin, y: answerTop, width: contentWidth,
                                height: pageBounds.maxY - margin - answerTop)
        let answerRect = fittedRect(for: WorkbookAnswerPaper.size, in: answerArea)
        try drawAnswer(drawing, in: answerRect, context: context,
                       questionTitle: question.title, sheetNumber: sheetIndex + 1)
    }

    private static func drawLabel(_ text: String, font: UIFont, in rect: CGRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ])
    }

    private static func fittedRect(for size: CGSize, in area: CGRect) -> CGRect {
        let scale = min(area.width / size.width, area.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: area.midX - width / 2, y: area.minY, width: width, height: height)
    }

    private static func drawAnswer(
        _ drawing: PKDrawing,
        in rect: CGRect,
        context: CGContext,
        questionTitle: String,
        sheetNumber: Int
    ) throws {
        let paper = CGRect(origin: .zero, size: WorkbookAnswerPaper.size)
        let scale = rect.width / paper.width
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)
        WorkbookAnswerPaper.draw(in: context, rect: paper)

        guard !drawing.strokes.isEmpty else { return }
        let inkBounds = drawing.bounds.intersection(paper)
        guard !inkBounds.isEmpty else {
            throw ExportError.drawingOutsideSheet(questionTitle, sheetNumber)
        }
        let imageRect = inkBounds.insetBy(dx: -2, dy: -2).integral.intersection(paper)
        let traits = UITraitCollection(userInterfaceStyle: .light)
        traits.performAsCurrent {
            drawing.image(from: imageRect, scale: 2).draw(in: imageRect)
        }
    }

    private struct SourceCrop {
        let size: CGSize
        private let page: PDFPage
        private let source: CGPDFPage
        private let box: CGPDFBox
        private let geometry: QuestionPDFGeometry
        private let region: CGRect

        init?(page: PDFPage, crop: NormalizedCrop) {
            guard crop.isValid, let source = page.pageRef,
                  let geometry = QuestionPDFGeometry(page: page) else { return nil }
            let region = QuestionPDFGeometry.normalizedRect(crop).intersection(QuestionPDFGeometry.wholePage)
            let size = CGSize(width: region.width * geometry.rotatedSize.width,
                              height: region.height * geometry.rotatedSize.height)
            guard size.width > 0, size.height > 0,
                  size.width.isFinite, size.height.isFinite,
                  !geometry.pageRect(region).isEmpty else { return nil }

            self.size = size
            self.page = page
            self.source = source
            self.geometry = geometry
            self.region = region
            box = source.getBoxRect(.cropBox).isEmpty ? .mediaBox : .cropBox
        }

        func draw(in rect: CGRect, context: CGContext) {
            let scale = rect.width / size.width
            let fullWidth = geometry.rotatedSize.width * scale
            let fullHeight = geometry.rotatedSize.height * scale
            let target = CGRect(x: -region.minX * fullWidth,
                                y: (region.maxY - 1) * fullHeight,
                                width: fullWidth, height: fullHeight)

            context.saveGState()
            defer { context.restoreGState() }
            context.clip(to: rect)
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.concatenate(source.getDrawingTransform(box, rect: target,
                                                            rotate: 0, preserveAspectRatio: true))
            context.clip(to: geometry.pageBounds)
            context.drawPDFPage(source)

            // PDFAnnotation draws in page-space coordinates relative to the chosen box origin.
            guard page.displaysAnnotations else { return }
            let pageRegion = geometry.pageRect(region)
            let mediaOrigin = page.bounds(for: .mediaBox).origin
            context.translateBy(x: mediaOrigin.x, y: mediaOrigin.y)
            for annotation in page.annotations
                where annotation.shouldDisplay && annotation.bounds.intersects(pageRegion) {
                context.saveGState()
                annotation.draw(with: .mediaBox, in: context)
                context.restoreGState()
            }
        }
    }

    private enum ExportError: LocalizedError {
        case noAnswers
        case invalidQuestion(String)
        case drawingRead(String, Int, Error)
        case drawingOutsideSheet(String, Int)
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .noAnswers:
                return "请先框选一道题。"
            case .invalidQuestion(let title):
                return "无法读取「\(title)」的原题区域，请查看原页或重新框选。"
            case .drawingRead(let title, let number, let error):
                return "无法读取「\(title)」第 \(number) 张答题纸的笔迹。\(error.localizedDescription)"
            case .drawingOutsideSheet(let title, let number):
                return "「\(title)」第 \(number) 张答题纸的笔迹位于纸张范围之外。"
            case .invalidOutput:
                return "生成的 PDF 页数不完整。"
            }
        }
    }
}
