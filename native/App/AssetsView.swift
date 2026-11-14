import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers
import ScratchCore

// MARK: - Tab trang phục

struct CostumesView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var showImporter = false
    @State private var showPaint = false

    var body: some View {
        let _ = store.revision
        if let t = store.selectedTarget, let r = store.renderer {
            VStack(spacing: 8) {
                HStack {
                    Button { showPaint = true } label: { Label("Vẽ mới", systemImage: "pencil.tip") }
                        .buttonStyle(.bordered)
                    Button { showImporter = true } label: { Label("Nhập ảnh", systemImage: "photo") }
                        .buttonStyle(.bordered)
                    Spacer()
                    Text(t.isStage ? "Phông nền" : "Trang phục").font(.caption).foregroundColor(.secondary)
                }
                List {
                    ForEach(t.costumes.indices, id: \.self) { i in
                        let c = t.costumes[i]
                        HStack(spacing: 10) {
                            thumb(r, c)
                            Text("\(i + 1). \(c.name)")
                            Spacer()
                            if i == t.currentCostume { Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectCostume(i) }
                        .contextMenu {
                            Button {
                                store.namePrompt = NamePrompt(kind: .rename, initial: c.name) { name, _ in
                                    t.renameCostume(at: i, to: name)
                                    store.revision += 1
                                }
                            } label: { Label("Đổi tên", systemImage: "pencil") }
                            if t.costumes.count > 1 {
                                Button(role: .destructive) {
                                    t.removeCostume(at: i)
                                    store.revision += 1
                                } label: { Label("Xoá", systemImage: "trash") }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                Text("Nhấn giữ một mục để đổi tên hoặc xoá.").font(.caption2).foregroundColor(.secondary)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.png, .jpeg, .svg]) { result in
                if case .success(let url) = result { store.importCostume(url: url) }
                else if case .failure(let e) = result { store.errorMessage = e.localizedDescription }
            }
            .sheet(isPresented: $showPaint) {
                PaintSheet(isStage: t.isStage) { png, w, h, res in
                    store.addPaintedCostume(png: png, pixelWidth: w, pixelHeight: h, resolution: res)
                }
            }
        }
    }

    private func thumb(_ r: StageRenderer, _ c: Costume) -> some View {
        Group {
            if let cg = r.thumbnail(for: c) {
                Image(uiImage: UIImage(cgImage: cg)).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundColor(.secondary)
            }
        }
        .frame(width: 48, height: 48)
        .background(Color.gray.opacity(0.15))
        .cornerRadius(6)
    }
}

// MARK: - Tab âm thanh

struct SoundsView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var showImporter = false
    @State private var showRecorder = false

    var body: some View {
        let _ = store.revision
        if let t = store.selectedTarget {
            VStack(spacing: 8) {
                HStack {
                    Button { showRecorder = true } label: { Label("Ghi âm", systemImage: "mic") }
                        .buttonStyle(.bordered)
                    Button { showImporter = true } label: { Label("Nhập WAV/MP3", systemImage: "waveform") }
                        .buttonStyle(.bordered)
                    Spacer()
                }
                if t.sounds.isEmpty {
                    Text("Chưa có âm thanh nào.").font(.footnote).foregroundColor(.secondary).padding(.top, 20)
                    Spacer()
                } else {
                    List {
                        ForEach(t.sounds.indices, id: \.self) { i in
                            let s = t.sounds[i]
                            HStack(spacing: 10) {
                                Button { store.previewSound(s) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                                    .buttonStyle(.plain)
                                VStack(alignment: .leading) {
                                    Text(s.name)
                                    Text(durationText(s)).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .contextMenu {
                                Button {
                                    store.namePrompt = NamePrompt(kind: .rename, initial: s.name) { name, _ in
                                        t.renameSound(at: i, to: name)
                                        store.revision += 1
                                    }
                                } label: { Label("Đổi tên", systemImage: "pencil") }
                                Button(role: .destructive) {
                                    t.removeSound(at: i)
                                    store.revision += 1
                                } label: { Label("Xoá", systemImage: "trash") }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.wav, .mp3]) { result in
                if case .success(let url) = result { store.importSound(url: url) }
                else if case .failure(let e) = result { store.errorMessage = e.localizedDescription }
            }
            .sheet(isPresented: $showRecorder) { RecorderSheet().environmentObject(store) }
        }
    }

    private func durationText(_ s: Sound) -> String {
        guard s.rate > 0, s.sampleCount > 0 else { return s.dataFormat.uppercased() }
        return String(format: "%.1f giây · %@", Double(s.sampleCount) / s.rate, s.dataFormat.uppercased())
    }
}

// MARK: - Ghi âm

final class SoundRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var message: String?
    private var recorder: AVAudioRecorder?
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording.wav")

    func start() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard granted else { self.message = "Chưa cấp quyền micro. Bật trong Cài đặt > Quyền riêng tư."; return }
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                    try session.setActive(true)
                    try? FileManager.default.removeItem(at: self.url)
                    let settings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatLinearPCM),
                        AVSampleRateKey: 22050,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false
                    ]
                    self.recorder = try AVAudioRecorder(url: self.url, settings: settings)
                    self.recorder?.record()
                    self.isRecording = true
                    self.message = nil
                } catch {
                    self.message = "Không bắt đầu ghi âm được: \(error.localizedDescription)"
                }
            }
        }
    }

    func stop() -> URL? {
        recorder?.stop()
        isRecording = false
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

struct RecorderSheet: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var rec = SoundRecorder()

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: rec.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 64)).foregroundColor(rec.isRecording ? .red : .secondary)
                Text(rec.isRecording ? "Đang ghi âm…" : "Nhấn để bắt đầu ghi")
                if let m = rec.message { Text(m).font(.footnote).foregroundColor(.orange).multilineTextAlignment(.center) }
                Button {
                    if rec.isRecording {
                        if let url = rec.stop() { store.importSound(url: url) }
                        dismiss()
                    } else {
                        rec.start()
                    }
                } label: {
                    Text(rec.isRecording ? "Dừng và lưu" : "Ghi âm")
                        .frame(minWidth: 160).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(rec.isRecording ? .red : .accentColor)
                Spacer()
            }
            .padding()
            .navigationTitle("Ghi âm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Huỷ") { _ = rec.stop(); dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Vẽ trang phục

final class PaintCanvas: UIView {
    struct Stroke {
        var points: [CGPoint]
        var color: UIColor
        var width: CGFloat
        var erase: Bool
    }

    var strokes: [Stroke] = []
    private var current: Stroke?
    var color: UIColor = .black
    var width: CGFloat = 6
    var erase = false
    var whiteBackground = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func undo() {
        if !strokes.isEmpty { strokes.removeLast() }
        setNeedsDisplay()
    }

    func clearAll() {
        strokes.removeAll()
        setNeedsDisplay()
    }

    func render(in ctx: CGContext) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        var all = strokes
        if let c = current { all.append(c) }
        for s in all where !s.points.isEmpty {
            ctx.saveGState()
            let useClear = s.erase && !whiteBackground
            ctx.setBlendMode(useClear ? .clear : .normal)
            let col = (s.erase && whiteBackground) ? UIColor.white : s.color
            ctx.setStrokeColor(col.cgColor)
            ctx.setFillColor(col.cgColor)
            ctx.setLineWidth(s.width)
            if s.points.count == 1 {
                let p = s.points[0]
                ctx.fillEllipse(in: CGRect(x: p.x - s.width / 2, y: p.y - s.width / 2, width: s.width, height: s.width))
            } else {
                ctx.move(to: s.points[0])
                for p in s.points.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }

    override func draw(_ rect: CGRect) {
        if let ctx = UIGraphicsGetCurrentContext() { render(in: ctx) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first?.location(in: self) else { return }
        current = Stroke(points: [p], color: color, width: width, erase: erase)
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first?.location(in: self) else { return }
        current?.points.append(p)
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let c = current { strokes.append(c) }
        current = nil
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    func exportPNG(scale: CGFloat) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        return renderer.pngData { c in
            if whiteBackground {
                UIColor.white.setFill()
                c.fill(CGRect(origin: .zero, size: bounds.size))
            }
            render(in: c.cgContext)
        }
    }
}

final class PaintBox {
    var canvas: PaintCanvas?
}

struct PaintCanvasView: UIViewRepresentable {
    let box: PaintBox
    let color: UIColor
    let width: CGFloat
    let erase: Bool
    let whiteBackground: Bool

    func makeUIView(context: Context) -> PaintCanvas {
        let c = PaintCanvas()
        box.canvas = c
        return c
    }

    func updateUIView(_ c: PaintCanvas, context: Context) {
        c.color = color
        c.width = width
        c.erase = erase
        c.whiteBackground = whiteBackground
        box.canvas = c
    }
}

struct PaintSheet: View {
    let isStage: Bool
    /// (dữ liệu PNG, chiều rộng px, chiều cao px, độ phân giải)
    let onSave: (Data, Double, Double, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var color = Color.black
    @State private var width: Double = 6
    @State private var erase = false
    @State private var box = PaintBox()

    private var pixelSize: (w: Double, h: Double) { isStage ? (960, 720) : (480, 480) }

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                ZStack {
                    Color.white
                    CheckerBackground().opacity(isStage ? 0 : 1)
                    PaintCanvasView(box: box, color: UIColor(color), width: CGFloat(width), erase: erase, whiteBackground: isStage)
                }
                .aspectRatio(CGFloat(pixelSize.w / pixelSize.h), contentMode: .fit)
                .overlay(Rectangle().stroke(Color.gray.opacity(0.5), lineWidth: 1))
                .padding(.horizontal, 12)

                HStack {
                    ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
                    Slider(value: $width, in: 1...40)
                    Text("\(Int(width))").frame(width: 28)
                }
                .padding(.horizontal, 16)

                HStack(spacing: 12) {
                    Button { erase = false } label: { Label("Bút", systemImage: "pencil") }
                        .buttonStyle(.bordered).tint(erase ? .gray : .accentColor)
                    Button { erase = true } label: { Label("Tẩy", systemImage: "eraser") }
                        .buttonStyle(.bordered).tint(erase ? .accentColor : .gray)
                    Button { box.canvas?.undo() } label: { Label("Hoàn tác", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.bordered)
                    Button(role: .destructive) { box.canvas?.clearAll() } label: { Image(systemName: "trash") }
                        .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
            }
            .navigationTitle("Vẽ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Lưu") { save() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        guard let canvas = box.canvas, !canvas.strokes.isEmpty, canvas.bounds.width > 0 else { dismiss(); return }
        let scale = CGFloat(pixelSize.w) / canvas.bounds.width
        if let png = canvas.exportPNG(scale: scale) {
            onSave(png, pixelSize.w, pixelSize.h, 2)
        }
        dismiss()
    }
}

struct CheckerBackground: View {
    var body: some View {
        GeometryReader { geo in
            let size: CGFloat = 16
            let cols = Int(geo.size.width / size) + 1
            let rows = Int(geo.size.height / size) + 1
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<cols, id: \.self) { c in
                            Rectangle()
                                .fill((r + c) % 2 == 0 ? Color.gray.opacity(0.12) : Color.white)
                                .frame(width: size, height: size)
                        }
                    }
                }
            }
            .clipped()
        }
    }
}
