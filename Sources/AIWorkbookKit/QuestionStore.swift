import Combine
import CryptoKit
import Foundation

/// Fractions of the visible PDF crop box after the PDF's own rotation.
/// The origin is the top-left corner of the rendered page.
struct NormalizedCrop: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var isValid: Bool {
        let tolerance = 1e-12
        return [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0 && y >= 0 && x < 1 && y < 1
            && width > 0 && height > 0
            && x + width <= 1 + tolerance && y + height <= 1 + tolerance
    }
}

struct QuestionAnswerPage: Codable, Identifiable {
    let id: UUID

    init() {
        id = UUID()
    }
}

struct WorkbookQuestion: Codable, Identifiable {
    let id: UUID
    let sourcePageIndex: Int
    var crop: NormalizedCrop
    var title: String
    var answerPages: [QuestionAnswerPage]
}

@MainActor
final class QuestionStore: ObservableObject {
    enum LoadState {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var questions: [WorkbookQuestion] = []
    @Published private(set) var loadState = LoadState.loading

    private let documentKey: String
    private let pageCount: Int
    private let directory: URL?

    init(documentKey: String, pageCount: Int) {
        self.documentKey = documentKey
        self.pageCount = pageCount
        let digest = SHA256.hash(data: Data(documentKey.utf8))
        let folderName = digest.map { String(format: "%02x", $0) }.joined()
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("AIWorkbookQuestions", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    func loadIfNeeded() {
        if case .loading = loadState { reload() }
    }

    func reload() {
        do {
            let file = try storageDirectory().appendingPathComponent("questions.json")
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch let error as CocoaError
                where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                questions = []
                loadState = .ready
                return
            }
            let decoder = JSONDecoder()
            let header = try decoder.decode(ManifestHeader.self, from: data)
            guard header.schemaVersion == Self.schemaVersion else {
                throw StoreError.unsupportedSchema
            }
            let manifest = try decoder.decode(Manifest.self, from: data)
            guard manifest.documentKey == documentKey else { throw StoreError.invalidManifest }
            try validate(manifest.questions)
            questions = manifest.questions
            loadState = .ready
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func addQuestion(sourcePageIndex: Int, crop: NormalizedCrop) throws {
        let question = WorkbookQuestion(
            id: UUID(),
            sourcePageIndex: sourcePageIndex,
            crop: crop,
            title: "第 \(questions.count + 1) 题",
            answerPages: [QuestionAnswerPage()]
        )
        try commit(questions + [question])
    }

    func renameQuestion(_ id: UUID, title: String) throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.emptyTitle }
        try updateQuestion(id) { $0.title = name }
    }

    func updateCrop(_ id: UUID, crop: NormalizedCrop) throws {
        try updateQuestion(id) { $0.crop = crop }
    }

    func addContinuation(to id: UUID) throws -> UUID {
        let page = QuestionAnswerPage()
        try updateQuestion(id) { $0.answerPages.append(page) }
        return page.id
    }

    func reorder(_ orderedQuestions: [WorkbookQuestion]) throws {
        try commit(orderedQuestions)
    }

    func drawingURL(questionID: UUID, answerPageID: UUID) throws -> URL {
        try storageDirectory()
            .appendingPathComponent("Drawings", isDirectory: true)
            .appendingPathComponent(questionID.uuidString, isDirectory: true)
            .appendingPathComponent(answerPageID.uuidString + ".pkdrawing")
    }

    private func storageDirectory() throws -> URL {
        guard !documentKey.isEmpty, let directory else { throw StoreError.missingDocument }
        return directory
    }

    private func updateQuestion(_ id: UUID, edit: (inout WorkbookQuestion) -> Void) throws {
        var updated = questions
        guard let index = updated.firstIndex(where: { $0.id == id }) else {
            throw StoreError.missingQuestion
        }
        edit(&updated[index])
        try commit(updated)
    }

    private func validate(_ questions: [WorkbookQuestion]) throws {
        guard Set(questions.map(\.id)).count == questions.count else {
            throw StoreError.invalidManifest
        }
        for question in questions {
            let pages = question.answerPages
            guard (0..<pageCount).contains(question.sourcePageIndex), question.crop.isValid,
                  !question.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !pages.isEmpty, Set(pages.map(\.id)).count == pages.count else {
                throw StoreError.invalidManifest
            }
        }
    }

    private func commit(_ updated: [WorkbookQuestion]) throws {
        guard case .ready = loadState else { throw StoreError.unavailable }
        try validate(updated)
        let manifest = Manifest(schemaVersion: Self.schemaVersion,
                                documentKey: documentKey,
                                questions: updated)
        let data = try JSONEncoder().encode(manifest)
        let folder = try storageDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("questions.json"), options: .atomic)
        questions = updated
    }

    private static let schemaVersion = 1

    private struct ManifestHeader: Decodable {
        let schemaVersion: Int
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let documentKey: String
        let questions: [WorkbookQuestion]
    }

    private enum StoreError: LocalizedError {
        case missingDocument, missingQuestion, emptyTitle, invalidManifest, unsupportedSchema, unavailable

        var errorDescription: String? {
            switch self {
            case .missingDocument: return "无法确定这份 PDF 的本地存储位置。"
            case .missingQuestion: return "找不到这道题。"
            case .emptyTitle: return "请输入题目名称。"
            case .invalidManifest: return "题目记录与源 PDF 不匹配，或记录已损坏。"
            case .unsupportedSchema: return "当前版本无法读取这份题目记录。"
            case .unavailable: return "题目记录尚未成功读取。"
            }
        }
    }
}
