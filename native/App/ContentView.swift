import SwiftUI
import UniformTypeIdentifiers
import ScratchCore

struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var showImporter = false
    @State private var showLibrary = false
    @State private var showExporter = false
    @State private var exportDoc = SB3Document(data: Data())
    @State private var showKeys = false
    @State private var answerText = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            Group {
                if let rt = store.runtime, let r = store.renderer {
                    editor(rt, r)
                } else {
                    emptyState
                }
            }
            .navigationTitle(store.projectName.isEmpty ? "Scratch" : store.projectName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button { showImporter = true } label: { Image(systemName: "folder") }
                    Button { showLibrary = true } label: { Image(systemName: "tray.full") }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { store.saveToDocuments() } label: { Image(systemName: "square.and.arrow.down") }
                        .disabled(store.runtime == nil)
                    Button {
                        if let data = store.exportData() {
                            exportDoc = SB3Document(data: data)
                            showExporter = true
                        }
                    } label: { Image(systemName: "square.and.arrow.up") }
                        .disabled(store.runtime == nil)
                }
            }
        }
        .navigationViewStyle(.stack)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.sb3, .zip, .data]) { result in
            if case .success(let url) = result { store.open(url: url) }
            else if case .failure(let e) = result { store.errorMessage = e.localizedDescription }
        }
        .fileExporter(isPresented: $showExporter, document: exportDoc, contentType: .sb3,
                      defaultFilename: store.projectName.isEmpty ? "Project" : store.projectName) { _ in }
        .sheet(isPresented: $showLibrary) { LibraryView(isPresented: $showLibrary) }
        .alert("Lỗi", isPresented: Binding(get: { store.errorMessage != nil },
                                           set: { if !$0 { store.errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) {} },
               message: { Text(store.errorMessage ?? "") })
        .overlay(alignment: .bottom) {
            if let msg = store.statusMessage {
                Text(msg).font(.footnote).padding(10)
                    .background(.thinMaterial).cornerRadius(10).padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .onChange(of: store.statusMessage) { msg in
            guard msg != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { store.statusMessage = nil }
        }
        .onReceive(timer) { _ in store.refreshDiagnostics() }
    }

    // MARK: Màn hình trống

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "cat.fill").font(.system(size: 64)).foregroundColor(.orange)
            Text("Chưa có dự án nào").font(.title3.bold())
            Text("Mở một tệp .sb3 để chạy ngay trên máy.")
                .foregroundColor(.secondary).multilineTextAlignment(.center)
            HStack {
                Button { showImporter = true } label: { Label("Mở dự án", systemImage: "folder") }
                    .buttonStyle(.borderedProminent)
                Button { showLibrary = true } label: { Label("Đã lưu", systemImage: "tray.full") }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    // MARK: Trình chạy

    private func editor(_ rt: Runtime, _ r: StageRenderer) -> some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            if landscape {
                HStack(alignment: .top, spacing: 12) {
                    let w = min(geo.size.width * 0.62, (geo.size.height - 70) * 4 / 3)
                    VStack(spacing: 8) {
                        stageArea(rt, r).frame(width: w, height: w * 3 / 4)
                        controls(rt)
                    }
                    spriteList(rt, r, vertical: true)
                }
                .padding(12)
            } else {
                VStack(spacing: 10) {
                    stageArea(rt, r).aspectRatio(4 / 3, contentMode: .fit)
                    controls(rt)
                    spriteList(rt, r, vertical: false)
                    Spacer(minLength: 0)
                }
                .padding(12)
            }
        }
    }

    private func stageArea(_ rt: Runtime, _ r: StageRenderer) -> some View {
        ZStack(alignment: .bottom) {
            StageView(runtime: rt, renderer: r)
                .background(Color.white)
                .overlay(Rectangle().stroke(Color.gray.opacity(0.4), lineWidth: 1))
            if let ask = store.ask {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ask.question).font(.footnote)
                    HStack {
                        TextField("Nhập câu trả lời", text: $answerText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { submit(ask) }
                        Button("OK") { submit(ask) }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(8)
                .background(.ultraThinMaterial)
            }
        }
    }

    private func submit(_ ask: AskRequest) {
        let text = answerText
        answerText = ""
        store.ask = nil
        ask.completion(text)
    }

    private func controls(_ rt: Runtime) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button { rt.greenFlag() } label: {
                    Image(systemName: "flag.fill").font(.title2).foregroundColor(.green)
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.bordered)
                Button { rt.stopAll() } label: {
                    Image(systemName: "stop.fill").font(.title2).foregroundColor(.red)
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.bordered)
                Button { showKeys.toggle() } label: {
                    Image(systemName: "gamecontroller").font(.title2).frame(width: 44, height: 36)
                }
                .buttonStyle(.bordered)
                Spacer()
                if store.isRunning { ProgressView() }
            }
            if showKeys { keyPad(rt) }
            if !store.unsupported.isEmpty {
                Text("Chưa hỗ trợ: " + store.unsupported.joined(separator: ", "))
                    .font(.caption2).foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func keyPad(_ rt: Runtime) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                KeyButton(label: "◀", key: "left arrow", runtime: rt)
                VStack(spacing: 6) {
                    KeyButton(label: "▲", key: "up arrow", runtime: rt)
                    KeyButton(label: "▼", key: "down arrow", runtime: rt)
                }
                KeyButton(label: "▶", key: "right arrow", runtime: rt)
            }
            KeyButton(label: "Space", key: "space", runtime: rt, width: 96)
        }
    }

    private func spriteList(_ rt: Runtime, _ r: StageRenderer, vertical: Bool) -> some View {
        let items = rt.targets.filter { !$0.isClone }
        let content = ForEach(items.indices, id: \.self) { i in
            SpriteChip(target: items[i], renderer: r)
        }
        return Group {
            if vertical {
                ScrollView { VStack(spacing: 8) { content } }.frame(maxWidth: 140)
            } else {
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { content } }
            }
        }
    }
}

// MARK: - Thành phần nhỏ

struct SpriteChip: View {
    let target: Target
    let renderer: StageRenderer

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let cg = renderer.costumeImage(for: target) {
                    Image(uiImage: UIImage(cgImage: cg)).resizable().scaledToFit()
                } else {
                    Image(systemName: target.isStage ? "photo" : "questionmark.square.dashed").foregroundColor(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            Text(target.isStage ? "Sân khấu" : target.name).font(.caption2).lineLimit(1)
        }
        .padding(6)
        .frame(width: 80)
        .background(Color.gray.opacity(0.12))
        .cornerRadius(10)
    }
}

struct KeyButton: View {
    let label: String
    let key: String
    let runtime: Runtime
    var width: CGFloat = 48
    @State private var down = false

    var body: some View {
        Text(label)
            .font(.headline)
            .frame(width: width, height: 44)
            .background(down ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.25))
            .cornerRadius(10)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !down { down = true; runtime.keyDown(key) }
                    }
                    .onEnded { _ in
                        down = false
                        runtime.keyUp(key)
                    }
            )
    }
}

struct LibraryView: View {
    @EnvironmentObject var store: ProjectStore
    @Binding var isPresented: Bool
    @State private var items: [URL] = []

    var body: some View {
        NavigationView {
            List {
                if items.isEmpty {
                    Text("Chưa có dự án nào được lưu.").foregroundColor(.secondary)
                }
                ForEach(items, id: \.self) { url in
                    Button {
                        store.open(url: url)
                        isPresented = false
                    } label: {
                        Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc")
                    }
                }
                .onDelete { offsets in
                    for i in offsets { try? FileManager.default.removeItem(at: items[i]) }
                    items = store.savedProjects()
                }
            }
            .navigationTitle("Dự án đã lưu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Xong") { isPresented = false } }
            }
            .onAppear { items = store.savedProjects() }
        }
    }
}
