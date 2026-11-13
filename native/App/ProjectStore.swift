import SwiftUI
import UniformTypeIdentifiers
import ScratchCore

extension UTType {
    /// Khai báo trong Info.plist (UTExportedTypeDeclarations).
    static let sb3 = UTType("com.scratchios.sb3") ?? UTType(filenameExtension: "sb3") ?? .data
}

struct SB3Document: FileDocument {
    static var readableContentTypes: [UTType] { [.sb3] }
    static var writableContentTypes: [UTType] { [.sb3] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct AskRequest: Identifiable {
    let id = UUID()
    let question: String
    let completion: (String) -> Void
}

final class ProjectStore: ObservableObject {
    @Published var runtime: Runtime?
    @Published var renderer: StageRenderer?
    @Published var projectName = ""
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var ask: AskRequest?
    @Published var unsupported: [String] = []
    @Published var statusMessage: String?

    private var audio: AudioPlayer?

    // MARK: Thư mục lưu dự án

    static var projectsDirectory: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func savedProjects() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: ProjectStore.projectsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "sb3" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    // MARK: Mở

    func open(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let project = try Project(sb3: data)
                let name = url.deletingPathExtension().lastPathComponent
                DispatchQueue.main.async { self.install(project, name: name) }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Không mở được “\(url.lastPathComponent)”: \(error.localizedDescription)"
                }
            }
        }
    }

    private func install(_ project: Project, name: String) {
        runtime?.stopAll()
        let rt = Runtime(project: project)
        let r = StageRenderer(runtime: rt)
        let player = AudioPlayer(project: project)
        rt.soundPlayer = player
        rt.askHandler = { [weak self] question, done in
            DispatchQueue.main.async { self?.ask = AskRequest(question: question, completion: done) }
        }
        rt.onRunningChanged = { [weak self] running in
            DispatchQueue.main.async { self?.isRunning = running }
        }
        audio = player
        renderer = r
        runtime = rt
        projectName = name
        isRunning = false
        unsupported = []
        ask = nil
    }

    // MARK: Lưu / xuất

    func exportData() -> Data? {
        guard let rt = runtime else { return nil }
        do { return try rt.exportSB3() }
        catch { errorMessage = "Không thể ghi dự án: \(error.localizedDescription)"; return nil }
    }

    /// Lưu vào thư mục Projects của ứng dụng.
    func saveToDocuments() {
        guard let data = exportData() else { return }
        let safe = projectName.isEmpty ? "Project" : projectName
        let url = ProjectStore.projectsDirectory.appendingPathComponent("\(safe).sb3")
        do {
            try data.write(to: url, options: .atomic)
            statusMessage = "Đã lưu “\(safe).sb3”"
        } catch {
            errorMessage = "Không thể lưu: \(error.localizedDescription)"
        }
    }

    func refreshDiagnostics() {
        let list = (runtime?.unsupportedOpcodes ?? []).sorted()
        if list != unsupported { unsupported = list }
    }
}
