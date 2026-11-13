import CoreGraphics
import Foundation
import PDFKit
import PencilKit
import UIKit
import XCTest
@testable import AIWorkbookKit

final class WorkbookPDFExportTests: XCTestCase {
    @MainActor
    func testRotatedOffsetCropAndContinuationOrder() throws {
        let source = try XCTUnwrap(PDFDocument(data: Self.fixture()))
        let sourcePage = try XCTUnwrap(source.page(at: 0))
        XCTAssertEqual(sourcePage.rotation, 90)
        XCTAssertEqual(sourcePage.bounds(for: .cropBox).origin, CGPoint(x: 40, y: 50))
        let firstSheet = QuestionAnswerPage()
        let secondSheet = QuestionAnswerPage()
        let thirdSheet = QuestionAnswerPage()
        let rotatedQuestion = WorkbookQuestion(
            id: UUID(), sourcePageIndex: 0,
            crop: NormalizedCrop(x: 0.45, y: 0.25, width: 0.38, height: 0.45),
            title: "Rotated", answerPages: [firstSheet, secondSheet]
        )
        let otherQuestion = WorkbookQuestion(
            id: UUID(), sourcePageIndex: 1,
            crop: NormalizedCrop(x: 0, y: 0, width: 1, height: 1),
            title: "Other", answerPages: [thirdSheet]
        )
        let ink = Self.magentaInk()
        var requested: [(UUID, UUID)] = []
        let exported = try WorkbookPDFExport.render(
            document: source, questions: [otherQuestion, rotatedQuestion],
            drawingForPage: { question, sheet in
                requested.append((question, sheet))
                return sheet == firstSheet.id ? ink : PKDrawing()
            }
        )
        XCTAssertEqual(requested.map(\.0), [otherQuestion.id, rotatedQuestion.id, rotatedQuestion.id])
        XCTAssertEqual(requested.map(\.1), [thirdSheet.id, firstSheet.id, secondSheet.id])
        let output = try XCTUnwrap(PDFDocument(data: exported))
        XCTAssertEqual(output.pageCount, 3)
        for index in 0..<3 {
            let page = try XCTUnwrap(output.page(at: index))
            let size = page.bounds(for: .mediaBox).size
            XCTAssertEqual(size.width, 595.28, accuracy: 1)
            XCTAssertEqual(size.height, 841.89, accuracy: 1)
            let pixels = try Self.colorCounts(on: page)
            XCTAssertGreaterThan(index == 0 ? pixels.blue : pixels.green, 16)
            XCTAssertEqual(index == 0 ? pixels.green : pixels.blue, 0)
            XCTAssertEqual(pixels.red, 0, "Outside-crop marker on output page \(index + 1)")
            if index == 1 {
                XCTAssertGreaterThan(pixels.magenta, 8)
                XCTAssertGreaterThan(pixels.rightmostMagenta, 0.60)
                XCTAssertGreaterThan(pixels.lowestMagenta, 0.60)
            } else {
                XCTAssertEqual(pixels.magenta, 0)
            }
        }
        XCTAssertEqual(sourcePage.rotation, 90)
        XCTAssertEqual(sourcePage.bounds(for: .cropBox).origin, CGPoint(x: 40, y: 50))
    }

    @MainActor
    func testDrawingReadFailurePropagates() throws {
        enum MissingInk: Error { case unreadable }
        let source = try XCTUnwrap(PDFDocument(data: Self.fixture()))
        let question = WorkbookQuestion(
            id: UUID(), sourcePageIndex: 1,
            crop: NormalizedCrop(x: 0, y: 0, width: 1, height: 1),
            title: "Other", answerPages: [QuestionAnswerPage()]
        )
        XCTAssertThrowsError(try WorkbookPDFExport.render(document: source, questions: [question]) { _, _ in
            throw MissingInk.unreadable
        })
    }

    private static func fixture() -> Data {
        func stream(_ instructions: String) -> String {
            "<< /Length \(instructions.utf8.count) >>\nstream\n\(instructions)\nendstream"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 2 /Kids [3 0 R 4 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /CropBox [40 50 330 430] /Rotate 90 /Resources << >> /Contents 5 0 R >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Resources << >> /Contents 6 0 R >>",
            stream("0 1 0 rg 150 250 60 70 re f\n1 0 0 rg 70 100 60 70 re f"),
            stream("0 0 1 rg 100 150 180 180 re f")
        ]
        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    private static func magentaInk() -> PKDrawing {
        let points = (0..<8).map { index in
            PKStrokePoint(location: CGPoint(x: 540 + 19 * index, y: 840 + 9 * index),
                          timeOffset: TimeInterval(index) / 20,
                          size: CGSize(width: 23, height: 23), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .magenta), path: path)])
    }

    private struct ColorCounts {
        var red = 0
        var green = 0
        var blue = 0
        var magenta = 0
        var rightmostMagenta: Double = 0
        var lowestMagenta: Double = 0
    }

    @MainActor
    private static func colorCounts(on page: PDFPage) throws -> ColorCounts {
        let image = try XCTUnwrap(page.thumbnail(of: CGSize(width: 360, height: 510), for: .mediaBox).cgImage)
        let width = image.width
        let height = image.height
        let rowBytes = width * 4
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: rowBytes, space: space, bitmapInfo: info))
        context.setFillColor(UIColor.white.cgColor)
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        context.fill(frame)
        context.draw(image, in: frame)
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var counts = ColorCounts()
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                let r = data[offset], g = data[offset + 1], b = data[offset + 2]
                if r > 180, g < 80, b < 80 { counts.red += 1 }
                if r < 80, g > 160, b < 80 { counts.green += 1 }
                if r < 80, g < 80, b > 180 { counts.blue += 1 }
                if r > 180, g < 100, b > 180 {
                    counts.magenta += 1
                    counts.rightmostMagenta = max(counts.rightmostMagenta, Double(x) / Double(width))
                    counts.lowestMagenta = max(counts.lowestMagenta, Double(y) / Double(height))
                }
            }
        }
        return counts
    }
}
