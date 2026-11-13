import SwiftUI
import PDFKit
import PencilKit
import UniformTypeIdentifiers
import UIKit

@MainActor
public struct AIWorkbookView: View {
    @AppStorage("AIWorkbook_LastPDF") private var lastPDFName = ""
    @AppStorage("AIWorkbook_PDFDisplayNames") private var pdfDisplayNamesData = Data()
    @State private var pdf: PDFDocument?
    @State private var currentFileName = ""
    @State private var pageIndex = 0
    @State private var showsImporter = false
    @State private var showsLibrary = false
    @State private var showsQuestions = false
    @State private var importedPDFs: [ImportedPDF] = []
    @State private var errorMessage: String?
    @State private var libraryErrorMessage: String?

    private var pdfDisplayNames: [String: String] {
        (try? PropertyListDecoder().decode([String: String].self, from: pdfDisplayNamesData)) ?? [:]
    }
    
    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory,
                                 in: .userDomainMask)[0]
    }
    
    private var handwritingFile: URL {
        documentsDirectory.appendingPathComponent(
            "drawing_\(currentFileName)_page_\(pageIndex).data"
        )
    }
    
    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if let pdf = pdf {
                    VStack(spacing: 10) {
                        HStack {
                            Button("上一页") { pageIndex -= 1 }
                                .disabled(pageIndex == 0)
                            Spacer()
                            Text("原 PDF 第 \(pageIndex + 1) / \(pdf.pageCount) 页")
                                .font(.subheadline)
                            Spacer()
                            Button("下一页") { pageIndex += 1 }
                                .disabled(pageIndex + 1 >= pdf.pageCount)
                        }
                        .padding(.horizontal)
                        
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("原题预览")
                                    .font(.headline)
                                PDFPagePreview(document: pdf, pageIndex: $pageIndex)
                                    .frame(height: 340)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                
                                Text("整页作答区")
                                    .font(.headline)
                                Group {
                                    if showsQuestions {
                                        Color.white
                                    } else {
                                        HandwritingCanvas(fileURL: handwritingFile)
                                            .id("\(currentFileName)-\(pageIndex)")
                                    }
                                }
                                .frame(height: 620)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.gray.opacity(0.3))
                                }
                            }
                            .padding()
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "还没有导入作业",
                        systemImage: "doc.text",
                        description: Text("导入 PDF，或打开已导入的作业。")
                    )
                }
            }
            .navigationTitle("AI Workbook")
            .toolbar {
                Button("逐题作答") { showsQuestions = true }
                    .disabled(pdf == nil || currentFileName.isEmpty)
                Button("已导入 PDF", action: showLibrary)
                Button("导入 PDF") { showsImporter = true }
            }
            .sheet(isPresented: $showsLibrary) {
                libraryView
            }
            .fullScreenCover(isPresented: $showsQuestions) {
                if let pdf, !currentFileName.isEmpty {
                    QuestionWorkspace(document: pdf,
                                      documentKey: currentFileName,
                                      sourcePageIndex: pageIndex,
                                      title: pdfDisplayNames[currentFileName] ?? "AI Workbook")
                        .id(currentFileName)
                }
            }
            .fileImporter(isPresented: $showsImporter,
                          allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url): importPDF(from: url)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .alert("发生错误", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "未知错误")
            }
            .onAppear(perform: restoreLastPDF)
        }
    }
    
    private func importPDF(from url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer {
            if granted { url.stopAccessingSecurityScopedResource() }
        }
        
        do {
            // First copy into the app sandbox, so the document can be reopened.
            let data = try Data(contentsOf: url)
            guard let loaded = PDFDocument(data: data), loaded.pageCount > 0 else {
                errorMessage = "文件不是可读取的 PDF，或 PDF 为空。"
                return
            }
            let name = UUID().uuidString + ".pdf"
            let destination = documentsDirectory.appendingPathComponent(name)
            try data.write(to: destination, options: .atomic)
            var names = pdfDisplayNames
            names[name] = url.lastPathComponent
            if let encoded = try? PropertyListEncoder().encode(names) {
                pdfDisplayNamesData = encoded
            }
            openPDF(loaded, named: name)
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
        }
    }
    
    private func restoreLastPDF() {
        guard pdf == nil, !lastPDFName.isEmpty else { return }
        let url = documentsDirectory.appendingPathComponent(lastPDFName)
        guard let loaded = PDFDocument(url: url), loaded.pageCount > 0 else {
            errorMessage = "上次导入的 PDF 已无法读取，请重新导入。"
            return
        }
        openPDF(loaded, named: lastPDFName)
    }

    private func openPDF(_ document: PDFDocument, named name: String) {
        currentFileName = name
        lastPDFName = name
        pageIndex = 0
        pdf = document
    }

    private var libraryView: some View {
        NavigationStack {
            Group {
                if importedPDFs.isEmpty {
                    ContentUnavailableView("没有已导入的 PDF", systemImage: "doc.text")
                } else {
                    List(importedPDFs) { item in
                        Button {
                            openImportedPDF(item)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                    if let date = item.importDate {
                                        Text(date.formatted(date: .abbreviated, time: .standard))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if item.id == currentFileName {
                                    Image(systemName: "checkmark")
                                        .accessibilityLabel("当前打开")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("已导入 PDF")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showsLibrary = false }
                }
            }
            .alert("无法打开 PDF", isPresented: Binding(
                get: { libraryErrorMessage != nil },
                set: { if !$0 { libraryErrorMessage = nil } }
            )) {
                Button("确定", role: .cancel) { libraryErrorMessage = nil }
            } message: {
                Text(libraryErrorMessage ?? "未知错误")
            }
        }
    }

    private func showLibrary() {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: documentsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: .skipsHiddenFiles
            )
            let names = pdfDisplayNames
            importedPDFs = files.compactMap { url -> ImportedPDF? in
                guard url.pathExtension == "pdf",
                      let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { return nil }

                let name = url.lastPathComponent
                return ImportedPDF(
                    id: name,
                    title: names[name] ?? "已导入 PDF \(id.uuidString.prefix(8))",
                    importDate: values.contentModificationDate
                )
            }.sorted { lhs, rhs in
                let leftDate = lhs.importDate ?? .distantPast
                let rightDate = rhs.importDate ?? .distantPast
                return leftDate == rightDate ? lhs.id < rhs.id : leftDate > rightDate
            }
            showsLibrary = true
        } catch {
            errorMessage = "无法读取已导入的 PDF：\(error.localizedDescription)"
        }
    }

    private func openImportedPDF(_ item: ImportedPDF) {
        if item.id != currentFileName || pdf == nil {
            let url = documentsDirectory.appendingPathComponent(item.id)
            guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                libraryErrorMessage = "这份 PDF 已无法读取。"
                return
            }
            openPDF(document, named: item.id)
        }
        showsLibrary = false
    }

    private struct ImportedPDF: Identifiable {
        let id: String
        let title: String
        let importDate: Date?
    }
}

@MainActor
struct PDFPagePreview: UIViewRepresentable {
    let document: PDFDocument
    @Binding var pageIndex: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(pageIndex: $pageIndex)
    }
    
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.backgroundColor = .systemGray6
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        return view
    }
    
    func updateUIView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.pageIndex = $pageIndex
        coordinator.isUpdatingView = true
        defer { coordinator.isUpdatingView = false }
        if view.document !== document {
            view.document = document
        }
        if let page = document.page(at: pageIndex), view.currentPage !== page {
            view.go(to: page)
        }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: view)
        coordinator.isAttached = false
    }

    @MainActor
    final class Coordinator: NSObject {
        var pageIndex: Binding<Int>
        var isUpdatingView = false
        var isAttached = true

        init(pageIndex: Binding<Int>) {
            self.pageIndex = pageIndex
        }

        @objc func pageChanged(_ notification: Notification) {
            guard !isUpdatingView, let view = notification.object as? PDFView,
                  let document = view.document else { return }
            let previousIndex = pageIndex.wrappedValue
            // Read PDFKit's final page outside the view update cycle.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, self.isAttached, let view, view.document === document,
                      self.pageIndex.wrappedValue == previousIndex,
                      let page = view.currentPage else { return }
                let index = document.index(for: page)
                if index != previousIndex, (0..<document.pageCount).contains(index) {
                    self.pageIndex.wrappedValue = index
                }
            }
        }
    }
}

@MainActor
struct HandwritingCanvas: UIViewRepresentable {
    let fileURL: URL
    @Environment(\.scenePhase) private var scenePhase
    
    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL)
    }
    
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = WorkbookPencilCanvas(frame: .zero)
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        canvas.contentInsetAdjustmentBehavior = .never
        if let data = try? Data(contentsOf: fileURL),
           let restoredDrawing = try? PKDrawing(data: data) {
            canvas.drawing = restoredDrawing
        }
        context.coordinator.lastSavedDrawing = canvas.drawing
        canvas.delegate = context.coordinator
        
        let pressurePen = context.coordinator.pressurePen
        pressurePen.attach(to: canvas, onDrawingChange: { [weak coordinator = context.coordinator] canvas in
            coordinator?.canvasViewDrawingDidChange(canvas)
        })
        let picker = pressurePen.toolPicker
        picker.addObserver(canvas)
        DispatchQueue.main.async {
            guard canvas.delegate != nil else { return }
            picker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        }
        return canvas
    }
    
    func updateUIView(_ view: PKCanvasView, context: Context) {
        if scenePhase != .active {
            context.coordinator.pressurePen.flush()
            context.coordinator.flushSave(from: view)
        }
    }

    static func dismantleUIView(_ view: PKCanvasView, coordinator: Coordinator) {
        coordinator.pressurePen.detach()
        view.delegate = nil
        coordinator.flushSave(from: view)
        let picker = coordinator.pressurePen.toolPicker
        picker.setVisible(false, forFirstResponder: view)
        picker.removeObserver(view)
        view.resignFirstResponder()
    }
    
    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let fileURL: URL
        let pressurePen = WorkbookPressurePen()
        var lastSavedDrawing: PKDrawing?
        private let saveSchedule = DrawingSaveSchedule()
        
        init(fileURL: URL) {
            self.fileURL = fileURL
        }
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            saveSchedule.schedule { [weak self, weak canvasView] in
                guard let self, let canvasView else { return }
                self.writeLatestDrawing(from: canvasView)
            }
        }

        func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
            pressurePen.canvasDidFinishRendering(canvasView)
        }

        func flushSave(from canvasView: PKCanvasView) {
            saveSchedule.cancel()
            writeLatestDrawing(from: canvasView)
        }

        private func writeLatestDrawing(from canvasView: PKCanvasView) {
            let drawing = canvasView.drawing
            guard drawing != lastSavedDrawing else { return }
            do {
                try drawing.dataRepresentation().write(to: fileURL, options: .atomic)
                lastSavedDrawing = drawing
            } catch {
                print("Failed to save handwriting: \(error)")
            }
        }
    }
}
