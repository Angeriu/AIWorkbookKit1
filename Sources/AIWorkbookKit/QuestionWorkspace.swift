import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Open this workspace for the already imported local PDF. Reuse that PDF's
/// persisted key every time it is restored. The key identifies one immutable copy.
@MainActor
struct QuestionWorkspace: View {
    let document: PDFDocument
    let sourcePageIndex: Int
    let title: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: QuestionStore
    @State private var showsCropEditor = false
    @State private var errorMessage: String?
    @State private var isPreparingExport = false
    @State private var showsExporter = false
    @State private var exportDocument: WorkbookPDFFile?

    init(document: PDFDocument, documentKey: String, sourcePageIndex: Int, title: String) {
        self.document = document
        self.sourcePageIndex = sourcePageIndex
        self.title = title
        _store = StateObject(wrappedValue: QuestionStore(documentKey: documentKey,
                                                        pageCount: document.pageCount))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch store.loadState {
                case .loading:
                    ProgressView("正在读取题目…")
                case .failed(let message):
                    VStack(spacing: 16) {
                        Text("无法读取题目记录").font(.headline)
                        Text(message).foregroundStyle(.secondary)
                        Button("重新读取") { store.reload() }
                    }
                    .padding()
                case .ready:
                    questionList
                }
            }
            .disabled(isPreparingExport)
            .overlay {
                if isPreparingExport {
                    ProgressView("正在生成 PDF…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("逐题作答")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回原 PDF") { dismiss() }
                        .disabled(isPreparingExport)
                }
                ToolbarItem(placement: .primaryAction) {
                    if store.questions.count > 1 { EditButton().disabled(isPreparingExport) }
                }
            }
            .task { store.loadIfNeeded() }
            .fullScreenCover(isPresented: $showsCropEditor) {
                if let page = document.page(at: sourcePageIndex) {
                    QuestionCropView(page: page, initialCrop: nil) { crop in
                        try store.addQuestion(sourcePageIndex: sourcePageIndex, crop: crop)
                    }
                }
            }
            .questionError($errorMessage)
            .fileExporter(isPresented: $showsExporter, document: exportDocument, contentTypes: [.pdf],
                          defaultFilename: exportFilename, onCompletion: finishExport,
                          onCancellation: { exportDocument = nil })
        }
    }

    private var questionList: some View {
        List {
            Button {
                showsCropEditor = true
            } label: {
                Label("在原 PDF 第 \(sourcePageIndex + 1) 页框选题目", systemImage: "crop")
            }
            .disabled(!(0..<document.pageCount).contains(sourcePageIndex))

            if store.questions.isEmpty {
                Text("框选并保存一道题，即可开始书写。")
                    .foregroundStyle(.secondary)
            } else {
                Button(action: prepareExport) {
                    Label("导出作答 PDF", systemImage: "square.and.arrow.up")
                }
                .disabled(isPreparingExport || showsExporter)
            }

            ForEach(store.questions) { question in
                NavigationLink {
                    QuestionDetailView(document: document, questionID: question.id, store: store)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(question.title)
                        Text("原 PDF 第 \(question.sourcePageIndex + 1) 页 · 答题纸 \(question.answerPages.count) 张")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onMove { offsets, destination in
                var reordered = store.questions
                reordered.move(fromOffsets: offsets, toOffset: destination)
                do {
                    try store.reorder(reordered)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var exportFilename: String {
        let separators = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let sourceName = (title as NSString).deletingPathExtension
        let cleanName = sourceName.components(separatedBy: separators).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleanName.isEmpty ? "AI Workbook" : String(cleanName.prefix(80))
        return "\(base)-作答"
    }

    private func prepareExport() {
        guard case .ready = store.loadState, !store.questions.isEmpty,
              !isPreparingExport, !showsExporter else { return }
        let questions = store.questions
        isPreparingExport = true
        Task { @MainActor in
            await Task.yield()
            defer { isPreparingExport = false }
            do {
                let data = try WorkbookPDFExport.render(document: document, questions: questions) { questionID, sheetID in
                    let url = try store.drawingURL(questionID: questionID, answerPageID: sheetID)
                    return try AnswerDrawingFiles.read(url.standardizedFileURL)
                }
                exportDocument = WorkbookPDFFile(data: data)
                showsExporter = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishExport(_ result: Result<URL, Error>) {
        exportDocument = nil
        if case .failure(let error) = result { errorMessage = error.localizedDescription }
    }
}

private struct WorkbookPDFFile: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
private struct QuestionDetailView: View {
    let document: PDFDocument
    let questionID: UUID
    @ObservedObject var store: QuestionStore

    @State private var selectedPageID: UUID?
    @State private var showsQuestion = true
    @State private var showsCropEditor = false
    @State private var activePreview: Preview?
    @State private var isFullScreen = false
    @State private var fitWidthRequest = 0
    @State private var showsRename = false
    @State private var draftTitle = ""
    @State private var errorMessage: String?

    private enum Preview: String, Identifiable {
        case cropped, source

        var id: Self { self }
    }

    var body: some View {
        if let question = store.questions.first(where: { $0.id == questionID }),
           let sourcePage = document.page(at: question.sourcePageIndex) {
            answer(for: question, sourcePage: sourcePage)
                .navigationTitle(question.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(isFullScreen ? .hidden : .visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                draftTitle = question.title
                                showsRename = true
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            Button {
                                showsCropEditor = true
                            } label: {
                                Label("调整题目范围", systemImage: "crop")
                            }
                        } label: {
                            Label("编辑题目", systemImage: "ellipsis.circle")
                        }
                    }
                }
                .fullScreenCover(isPresented: $showsCropEditor) {
                    QuestionCropView(page: sourcePage, initialCrop: question.crop) { crop in
                        try store.updateCrop(questionID, crop: crop)
                    }
                }
                .fullScreenCover(item: $activePreview) { preview in
                    NavigationStack {
                        Group {
                            switch preview {
                            case .cropped:
                                QuestionCropPreview(page: sourcePage, crop: question.crop, allowsZoom: true)
                            case .source:
                                QuestionSourcePreview(page: sourcePage)
                            }
                        }
                            .navigationTitle(question.title)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("完成") { activePreview = nil }
                                }
                            }
                    }
                }
                .alert("重命名题目", isPresented: $showsRename) {
                    TextField("题目名称", text: $draftTitle)
                    Button("取消", role: .cancel) {}
                    Button("保存") {
                        do {
                            try store.renameQuestion(questionID, title: draftTitle)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .questionError($errorMessage)
        } else {
            Text("找不到题目或源页面。")
        }
    }

    private func answer(for question: WorkbookQuestion, sourcePage: PDFPage) -> some View {
        GeometryReader { geometry in
            VStack(spacing: 10) {
                if isFullScreen {
                    HStack {
                        Button {
                            isFullScreen = false
                        } label: {
                            Label("退出全屏", systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                        Spacer()
                        Button("查看题目") { activePreview = .cropped }
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                } else {
                    let ratio = QuestionCropPreview.aspectRatio(page: sourcePage, crop: question.crop)
                    let naturalHeight = max(1, geometry.size.width - 32) / ratio
                    let availableHeight = geometry.size.height * 0.40
                    questionPreview(for: question, sourcePage: sourcePage,
                                    height: min(max(110, naturalHeight), max(110, availableHeight)))
                        .padding(.horizontal)
                }
                answerSheet(for: question)
            }
            .padding(.top, 8)
        }
    }

    private func questionPreview(for question: WorkbookQuestion, sourcePage: PDFPage,
                                 height: CGFloat) -> some View {
        DisclosureGroup(isExpanded: $showsQuestion) {
            VStack(alignment: .trailing, spacing: 6) {
                QuestionCropPreview(page: sourcePage, crop: question.crop,
                                    onOpen: { activePreview = .cropped },
                                    onViewSource: { activePreview = .source },
                                    onRecrop: { showsCropEditor = true })
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Button {
                    activePreview = .cropped
                } label: {
                    Label("全屏查看", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote)
                }
                .accessibilityLabel("全屏查看题目")
            }
            .padding(.top, 6)
        } label: {
            Text("题目截图 · 原 PDF 第 \(question.sourcePageIndex + 1) 页")
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private func answerSheet(for question: WorkbookQuestion) -> some View {
        let pages = question.answerPages
        let currentIndex = pages.firstIndex(where: { $0.id == selectedPageID }) ?? 0
        if pages.indices.contains(currentIndex) {
            HStack {
                Button {
                    selectedPageID = pages[currentIndex - 1].id
                } label: {
                    Label("上一张答题纸", systemImage: "chevron.left").labelStyle(.iconOnly)
                }
                .disabled(currentIndex == 0)

                Text("答题纸 \(currentIndex + 1) / \(pages.count)")
                    .monospacedDigit()

                Button {
                    selectedPageID = pages[currentIndex + 1].id
                } label: {
                    Label("下一张答题纸", systemImage: "chevron.right").labelStyle(.iconOnly)
                }
                .disabled(currentIndex + 1 >= pages.count)

                Spacer()
                Button {
                    fitWidthRequest += 1
                } label: {
                    Label("适合宽度", systemImage: "arrow.left.and.right").labelStyle(.iconOnly)
                }
                if !isFullScreen {
                    Button {
                        isFullScreen = true
                    } label: {
                        Label("全屏作答", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                Button {
                    do {
                        selectedPageID = try store.addContinuation(to: questionID)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Label("加续页", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            let sheet = pages[currentIndex]
            if let file = try? store.drawingURL(questionID: questionID, answerPageID: sheet.id) {
                QuestionAnswerCanvas(fileURL: file,
                                     showsTools: activePreview == nil && !showsCropEditor && !showsRename,
                                     fitWidthRequest: fitWidthRequest)
                    .id(sheet.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("无法确定答题纸的存储位置。")
            }
        }
    }
}

private extension View {
    func questionError(_ message: Binding<String?>) -> some View {
        alert("操作失败", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("确定", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
