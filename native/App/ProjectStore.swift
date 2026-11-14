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

struct InputEditRequest: Identifiable {
    let id = UUID()
    let target: Target
    let blockId: String
    let input: InputSpec
}

enum NameKind { case variable, list, broadcast, rename }

struct NamePrompt: Identifiable {
    let id = UUID()
    let kind: NameKind
    let initial: String
    let onDone: (String, Bool) -> Void     // (tên, dùng cho mọi sprite)
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

    // Trình chỉnh sửa
    @Published var selectedTarget: Target?
    @Published var selectedBlock: String?
    @Published var insertInside: String?          // tên ô SUBSTACK sẽ chèn vào, nil = chèn phía sau
    @Published var revision = 0
    @Published var showPalette = false
    @Published var inputEdit: InputEditRequest?
    @Published var namePrompt: NamePrompt?

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
        selectedBlock = nil
        insertInside = nil
        selectedTarget = rt.targets.first(where: { !$0.isStage && !$0.isClone }) ?? rt.stage
        revision += 1
    }

    func newProject() {
        install(Project.blank(), name: "Dự án mới")
    }

    // MARK: Sprite

    var sprites: [Target] { (runtime?.targets ?? []).filter { !$0.isClone } }

    func select(target t: Target) {
        selectedTarget = t
        selectedBlock = nil
        insertInside = nil
    }

    func addBlankSprite() {
        guard let rt = runtime else { return }
        let t = rt.project.makeBlankSprite(existingNames: rt.targets.map { $0.name })
        rt.addSprite(t)
        select(target: t)
        revision += 1
    }

    func importSprite(url: URL) {
        guard let rt = runtime else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { errorMessage = "Không đọc được tệp ảnh."; return }
        var format = url.pathExtension.lowercased()
        if format == "jpeg" { format = "jpg" }
        var cx = 0.0, cy = 0.0, res = 1.0
        if format == "svg" {
            guard let size = svgIntrinsicSize(data) else { errorMessage = "SVG không hợp lệ."; return }
            cx = size.width / 2; cy = size.height / 2
        } else if format == "png" || format == "jpg" {
            guard let img = UIImage(data: data), let cg = img.cgImage else { errorMessage = "Ảnh không hợp lệ."; return }
            let w = Double(cg.width), h = Double(cg.height)
            res = max(1, (w / 150).rounded(.up))
            cx = w / 2; cy = h / 2
        } else {
            errorMessage = "Chỉ hỗ trợ ảnh PNG, JPG hoặc SVG."
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        let t = rt.project.makeSprite(name: name, existingNames: rt.targets.map { $0.name }, assetData: data,
                                      dataFormat: format, centerX: cx, centerY: cy, bitmapResolution: res)
        rt.addSprite(t)
        select(target: t)
        revision += 1
    }

    func deleteSprite(_ t: Target) {
        guard let rt = runtime, !t.isStage else { return }
        rt.removeSprite(t)
        if selectedTarget === t { selectedTarget = rt.targets.first(where: { !$0.isStage && !$0.isClone }) ?? rt.stage }
        selectedBlock = nil
        revision += 1
    }

    func renameSprite(_ t: Target, to name: String) {
        guard let rt = runtime, !t.isStage else { return }
        let others = rt.targets.filter { $0 !== t }.map { $0.name }
        var unique = name
        var n = 2
        while others.contains(unique) { unique = "\(name)\(n)"; n += 1 }
        t.name = unique
        revision += 1
    }

    // MARK: Chỉnh sửa khối

    func context(for t: Target) -> EditorContext? {
        guard let rt = runtime else { return nil }
        let real = rt.targets.filter { !$0.isClone }
        let names = real.filter { !$0.isStage }.map { $0.name }
        var b = Set(Project.usedBroadcastNames(in: real))
        for n in rt.project.declaredBroadcasts { b.insert(n) }
        if b.isEmpty { b.insert("message1") }
        return EditorContext(target: t, stage: rt.stage, spriteNames: names, broadcasts: b.sorted())
    }

    func selectBlock(_ id: String) {
        selectedBlock = id
        insertInside = nil
    }

    func insert(spec: BlockSpec) {
        guard let t = selectedTarget, let ctx = context(for: t) else { return }
        let block = t.makeBlock(spec, context: ctx)
        var placed = false

        if spec.shape != .hat, let selId = selectedBlock, let sel = t.blocks[selId], !sel.shadow {
            let selSpec = BlockCatalog.spec(for: sel.opcode)
            if let name = insertInside, selSpec?.substackNames.contains(name) == true {
                var hasChild = false
                if case .block? = sel.inputs[name] { hasChild = true }
                if spec.hasNext || !hasChild {
                    t.insertBlock(block.id, intoSubstackOf: sel.id, input: name)
                    placed = true
                }
            } else if selSpec?.hasNext ?? true {
                if spec.hasNext || sel.next == nil {
                    t.insertBlock(block.id, after: sel.id)
                    placed = true
                }
            }
        }
        if !placed {
            t.addScript(block.id)
            if spec.shape != .hat && selectedBlock != nil { statusMessage = "Khối này không chèn được ở đó, đã tạo script mới" }
        }
        t.finishEdit()
        selectedBlock = block.id
        insertInside = nil
        revision += 1
    }

    func deleteSelectedBlock() {
        guard let t = selectedTarget, let id = selectedBlock else { return }
        t.removeBlock(id)
        selectedBlock = nil
        insertInside = nil
        revision += 1
    }

    func deleteSelectedScript() {
        guard let t = selectedTarget, let id = selectedBlock else { return }
        t.removeScript(containing: id)
        selectedBlock = nil
        insertInside = nil
        revision += 1
    }

    func moveSelected(up: Bool) {
        guard let t = selectedTarget, let id = selectedBlock else { return }
        let ok = up ? t.moveBlockUp(id) : t.moveBlockDown(id)
        if !ok { statusMessage = "Không di chuyển được khối này" }
        revision += 1
    }

    func runSelectedScript() {
        guard let rt = runtime, let t = selectedTarget, let id = selectedBlock else { return }
        rt.runScript(of: t, rootId: t.scriptRoot(of: id))
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
