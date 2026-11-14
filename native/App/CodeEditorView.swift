import SwiftUI
import UIKit
import ScratchCore

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

private func colorFor(_ spec: BlockSpec?) -> Color {
    return Color(hex: spec?.category.colorHex ?? 0x8A8A8A)
}

// MARK: - Màn hình chính của trình chỉnh sửa

struct CodeEditorView: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        let _ = store.revision
        if let t = store.selectedTarget {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        let roots = t.scriptRoots()
                        if roots.isEmpty {
                            Text("Chưa có khối nào. Nhấn nút + để thêm khối đầu tiên.")
                                .font(.footnote).foregroundColor(.secondary).padding(.top, 20)
                        }
                        ForEach(roots, id: \.id) { r in
                            StackView(target: t, firstId: r.id)
                                .padding(8)
                                .background(Color.gray.opacity(0.10))
                                .cornerRadius(10)
                        }
                        Spacer(minLength: 80)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ActionBar(target: t)
            }
            .overlay(alignment: .bottomTrailing) {
                Button { store.showPalette = true } label: {
                    Image(systemName: "plus").font(.title2.bold()).foregroundColor(.white)
                        .frame(width: 52, height: 52).background(Color.accentColor).clipShape(Circle())
                        .shadow(radius: 3)
                }
                .padding(.trailing, 14).padding(.bottom, store.selectedBlock == nil ? 14 : 70)
            }
            .coordinateSpace(name: "editor")
            .overlay(DragGhost(target: t))
            .onPreferenceChange(DropZoneKey.self) { store.dropZones = $0 }
            .sheet(isPresented: $store.showPalette) { PaletteView().environmentObject(store) }
            .sheet(item: $store.inputEdit) { req in InputEditSheet(request: req).environmentObject(store) }
            .sheet(isPresented: $store.showCustomBlock) { CustomBlockSheet().environmentObject(store) }
        } else {
            Text("Chọn một sprite").foregroundColor(.secondary)
        }
    }
}

// MARK: - Thanh thao tác với khối đang chọn

struct ActionBar: View {
    let target: Target
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        if let id = store.selectedBlock, let b = target.blocks[id] {
            let spec = BlockCatalog.spec(for: b, in: target)
            VStack(spacing: 4) {
                if let name = store.insertInside {
                    Text(name == "SUBSTACK2" ? "Khối mới sẽ chèn vào phần “ngược lại”" : "Khối mới sẽ chèn vào bên trong")
                        .font(.caption2).foregroundColor(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        bar("arrow.up", "Lên") { store.moveSelected(up: true) }
                        bar("arrow.down", "Xuống") { store.moveSelected(up: false) }
                        if let names = spec?.substackNames, !names.isEmpty {
                            bar("arrow.down.right.square", "Vào trong") { store.insertInside = names[0] }
                            if names.count > 1 {
                                bar("arrow.down.right.square.fill", "Vào “ngược lại”") { store.insertInside = names[1] }
                            }
                        }
                        bar("play.fill", "Chạy script") { store.runSelectedScript() }
                        bar("trash", "Xoá khối") { store.deleteSelectedBlock() }
                        bar("trash.slash", "Xoá script") { store.deleteSelectedScript() }
                        bar("xmark", "Bỏ chọn") { store.selectedBlock = nil; store.insertInside = nil }
                    }
                    .padding(.horizontal, 10)
                }
            }
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
    }

    private func bar(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                Text(title).font(.caption2)
            }
            .frame(minWidth: 52)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Chuỗi khối

struct StackView: View {
    let target: Target
    let firstId: String
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(chain(), id: \.self) { id in
                BlockRowView(target: target, id: id)
            }
        }
    }

    private func chain() -> [String] {
        var out: [String] = []
        var cur: String? = firstId
        while let c = cur, let b = target.blocks[c], out.count < 2000 {
            out.append(c)
            cur = b.next
        }
        return out
    }
}

// MARK: - Kéo thả

struct DropZone: Equatable {
    enum Kind { case after, into }
    let kind: Kind
    let blockId: String
    let input: String
    let frame: CGRect
    var key: String { kind == .after ? "after:\(blockId)" : "in:\(blockId):\(input)" }
}

struct DropZoneKey: PreferenceKey {
    static var defaultValue: [DropZone] = []
    static func reduce(value: inout [DropZone], nextValue: () -> [DropZone]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Đăng ký vùng này làm điểm thả khối (toạ độ trong không gian "editor").
    func dropZone(_ kind: DropZone.Kind, _ blockId: String, _ input: String = "") -> some View {
        background(
            GeometryReader { g in
                Color.clear.preference(
                    key: DropZoneKey.self,
                    value: [DropZone(kind: kind, blockId: blockId, input: input, frame: g.frame(in: .named("editor")))])
            }
        )
    }
}

/// Trạng thái đang kéo (chỉ khối "ma" quan sát để không vẽ lại cả vùng làm việc).
final class DragModel: ObservableObject {
    @Published var blockId: String?
    @Published var location: CGPoint = .zero
    var draggedIds: Set<String> = []
}

/// Vùng thả đang được tô sáng.
final class DropHighlight: ObservableObject {
    @Published var key: String?
}

struct DragGhost: View {
    let target: Target
    @EnvironmentObject var dragModel: DragModel

    var body: some View {
        if let id = dragModel.blockId, let b = target.blocks[id] {
            Group {
                if let spec = BlockCatalog.spec(for: b, in: target) {
                    SpecPreview(spec: spec)
                } else {
                    Text(b.opcode).padding(8).background(Color.gray).cornerRadius(8)
                }
            }
            .frame(maxWidth: 260)
            .opacity(0.88)
            .shadow(radius: 6)
            .position(x: dragModel.location.x + 70, y: dragModel.location.y - 24)
            .allowsHitTesting(false)
        }
    }
}

struct BlockRowView: View {
    let target: Target
    let id: String
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var highlight: DropHighlight

    var body: some View {
        if let b = target.blocks[id] {
            let spec = BlockCatalog.spec(for: b, in: target)
            let color = colorFor(spec)
            let selected = store.selectedBlock == id
            let isC = !(spec?.substackNames.isEmpty ?? true)
            VStack(alignment: .leading, spacing: 0) {
                header(b, spec, color, isC: isC)
                if let spec = spec {
                    ForEach(spec.substackNames, id: \.self) { name in
                        if name == "SUBSTACK2" {
                            HStack { Text("ngược lại").font(.subheadline.bold()).foregroundColor(.white); Spacer() }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(color)
                                .dropZone(.into, id, "SUBSTACK2")
                                .overlay(alignment: .bottom) { bar(highlight.key == "in:\(id):SUBSTACK2") }
                        }
                        HStack(alignment: .top, spacing: 0) {
                            Rectangle().fill(color).frame(width: 14)
                            substack(b, name)
                                .padding(.leading, 4).padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if isC {
                        Rectangle().fill(color).frame(height: 8)
                            .dropZone(.after, id)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.primary : Color.clear, lineWidth: 2))
            .overlay(alignment: .bottom) { bar(highlight.key == "after:\(id)") }
        }
    }

    @ViewBuilder
    private func bar(_ on: Bool) -> some View {
        if on { Rectangle().fill(Color.primary).frame(height: 4) }
    }

    @ViewBuilder
    private func substack(_ b: Block, _ name: String) -> some View {
        if case .block(let cid)? = b.inputs[name], target.blocks[cid] != nil {
            StackView(target: target, firstId: cid)
        } else {
            Button {
                store.selectedBlock = b.id
                store.insertInside = name
            } label: {
                Text("(trống) — thả khối vào đây")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.gray.opacity(0.2)).cornerRadius(6)
            }
            .buttonStyle(.plain)
            .dropZone(.into, b.id, name)
        }
    }

    private func handle(_ b: Block) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.85))
            .frame(width: 30, height: 38)
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.2)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("editor")))
                    .onChanged { value in
                        if case .second(true, let drag?) = value { store.dragMoved(b.id, to: drag.location) }
                    }
                    .onEnded { value in
                        if case .second(true, let drag?) = value { store.dragEnded(at: drag.location) }
                        else { store.cancelDrag() }
                    }
            )
    }

    private func header(_ b: Block, _ spec: BlockSpec?, _ color: Color, isC: Bool) -> some View {
        HStack(spacing: 0) {
            handle(b)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let spec = spec {
                        SegmentsView(target: target, block: b, spec: spec)
                    } else {
                        Text(b.opcode).font(.subheadline.bold()).foregroundColor(.white)
                    }
                }
                .padding(.trailing, 10).padding(.vertical, 8)
            }
            .contentShape(Rectangle())
            .onTapGesture { store.selectBlock(b.id) }
        }
        .background(color)
        .dropZone(isC ? .into : .after, b.id, isC ? "SUBSTACK" : "")
        .overlay(alignment: .bottom) { bar(isC && highlight.key == "in:\(b.id):SUBSTACK") }
    }
}

// MARK: - Các đoạn trong một khối

struct SegmentsView: View {
    let target: Target
    let block: Block
    let spec: BlockSpec
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        ForEach(Array(spec.segments.enumerated()), id: \.offset) { _, seg in
            switch seg {
            case .text(let s):
                Text(s).font(.subheadline.bold()).foregroundColor(.white).fixedSize()
            case .field(let f):
                fieldView(f)
            case .input(let i):
                InputSlotView(target: target, block: block, spec: i)
            }
        }
    }

    @ViewBuilder
    private func fieldView(_ f: FieldSpec) -> some View {
        if let ctx = store.context(for: target) {
            let cur = block.fields[f.name]?.asString ?? ""
            MenuPill(options: ctx.options(f.source),
                     display: ctx.label(for: cur, source: f.source),
                     dark: true,
                     onNew: nil,
                     onSelect: { opt in
                         target.setField(block: block.id, field: f.name, option: opt)
                         store.revision += 1
                     })
        }
    }
}

struct InputSlotView: View {
    let target: Target
    let block: Block
    let spec: InputSpec
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        switch block.inputs[spec.name] {
        case .some(.block(let cid)):
            if let child = target.blocks[cid] {
                if child.shadow { shadowMenu(child) } else { ReporterPill(target: target, id: cid, onTap: openEditor) }
            } else {
                emptyPill
            }
        case .some(.literal(let v)):
            literalPill(v.asString)
        case .some(.broadcast(let name)):
            broadcastMenu(name)
        default:
            emptyPill
        }
    }

    private func openEditor() {
        store.inputEdit = InputEditRequest(target: target, blockId: block.id, input: spec)
    }

    private var isBoolean: Bool {
        if case .boolean = spec.kind { return true }
        return false
    }

    private var isNumber: Bool {
        switch spec.kind {
        case .number, .color: return true
        default: return false
        }
    }

    private var emptyPill: some View {
        Button(action: openEditor) {
            Text("   ").font(.subheadline)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: isBoolean ? 12 : 6))
        }
        .buttonStyle(.plain)
    }

    private func literalPill(_ text: String) -> some View {
        Button(action: openEditor) {
            HStack(spacing: 4) {
                if case .color = spec.kind, let c = Color(hexString: text) {
                    Circle().fill(c).frame(width: 14, height: 14)
                }
                Text(text.isEmpty ? " " : text).font(.subheadline).foregroundColor(.black).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(minWidth: 26)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: isNumber ? 12 : 4))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func shadowMenu(_ child: Block) -> some View {
        if case .menu(_, let field, let src) = spec.kind, let ctx = store.context(for: target) {
            let cur = child.fields[field]?.asString ?? ""
            MenuPill(options: ctx.options(src),
                     display: ctx.label(for: cur, source: src),
                     dark: false,
                     onNew: nil,
                     onSelect: { opt in
                         target.setField(block: child.id, field: field, option: opt)
                         store.revision += 1
                     })
        } else {
            literalPill(child.fields.values.first?.asString ?? "")
        }
    }

    @ViewBuilder
    private func broadcastMenu(_ name: String) -> some View {
        if let ctx = store.context(for: target) {
            MenuPill(options: ctx.options(.broadcasts),
                     display: name,
                     dark: false,
                     onNew: {
                         store.namePrompt = NamePrompt(kind: .broadcast, initial: "") { newName, _ in
                             target.setBroadcast(block: block.id, input: spec.name, name: newName)
                             store.revision += 1
                         }
                     },
                     onSelect: { opt in
                         target.setBroadcast(block: block.id, input: spec.name, name: opt.value)
                         store.revision += 1
                     })
        }
    }
}

/// Khối reporter đặt trong một ô nhập.
struct ReporterPill: View {
    let target: Target
    let id: String
    let onTap: () -> Void
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        if let b = target.blocks[id] {
            let spec = BlockCatalog.spec(for: b, in: target)
            HStack(spacing: 5) {
                if let spec = spec {
                    SegmentsView(target: target, block: b, spec: spec)
                } else {
                    Text(b.opcode).font(.caption.bold()).foregroundColor(.white)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(colorFor(spec).opacity(0.9))
            .overlay(RoundedRectangle(cornerRadius: spec?.shape == .boolean ? 12 : 10).stroke(Color.white.opacity(0.6), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: spec?.shape == .boolean ? 12 : 10))
            .onTapGesture(perform: onTap)
        }
    }
}

struct MenuPill: View {
    let options: [MenuOption]
    let display: String
    let dark: Bool
    let onNew: (() -> Void)?
    let onSelect: (MenuOption) -> Void

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button(options[i].label) { onSelect(options[i]) }
            }
            if let n = onNew {
                Divider()
                Button("Tin nhắn mới…") { n() }
            }
        } label: {
            HStack(spacing: 3) {
                Text(display.isEmpty ? "—" : display).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.subheadline)
            .foregroundColor(dark ? .white : .black)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(dark ? Color.black.opacity(0.25) : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

extension Color {
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

// MARK: - Bản xem trước khối (trong bảng khối)

struct SpecPreview: View {
    let spec: BlockSpec

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(spec.segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let s):
                    Text(s).font(.subheadline.bold()).foregroundColor(.white).fixedSize()
                case .field(let f):
                    Text(f.defaultValue.isEmpty ? "▾" : f.defaultValue + " ▾").font(.subheadline)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.25)).foregroundColor(.white).cornerRadius(5)
                case .input(let i):
                    Text(label(i)).font(.subheadline).foregroundColor(.black)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .frame(minWidth: 22)
                        .background(Color.white).cornerRadius(8)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colorFor(spec))
        .cornerRadius(8)
    }

    private func label(_ i: InputSpec) -> String {
        switch i.kind {
        case .menu, .broadcast: return "▾"
        case .boolean: return " "
        default: return i.defaultValue.isEmpty ? " " : i.defaultValue
        }
    }
}

// MARK: - Bảng khối

struct PaletteView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var category: BlockCategory = .events

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(BlockCategory.allCases, id: \.self) { c in
                            Button { category = c } label: {
                                Text(c.title).font(.subheadline.bold())
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(category == c ? Color(hex: c.colorHex) : Color(hex: c.colorHex).opacity(0.25))
                                    .foregroundColor(category == c ? .white : .primary)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(10)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if category == .data { dataButtons }
                        if category == .custom { customSection }
                        ForEach(BlockCatalog.specs(in: category).filter { !$0.isReporter }, id: \.opcode) { spec in
                            Button {
                                store.insert(spec: spec)
                                store.showPalette = false
                            } label: { SpecPreview(spec: spec) }
                            .buttonStyle(.plain)
                        }
                        Text("Khối giá trị (số, chữ, biến…) được chèn bằng cách chạm vào ô nhập trong một khối.")
                            .font(.caption).foregroundColor(.secondary).padding(.top, 8)
                    }
                    .padding(10)
                }
            }
            .navigationTitle("Thêm khối")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Xong") { store.showPalette = false } }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var customSection: some View {
        Button { openCustomBlockSheet() } label: { Label("Tạo khối mới", systemImage: "plus.circle") }
            .buttonStyle(.bordered)
        if let t = store.selectedTarget {
            ForEach(t.customBlockCodes, id: \.self) { code in
                let spec = BlockCatalog.callSpec(proccode: code, argIds: [])
                Button {
                    store.insertCall(code: code)
                    store.showPalette = false
                } label: { SpecPreview(spec: spec) }
                .buttonStyle(.plain)
            }
        }
    }

    private func openCustomBlockSheet() {
        store.showPalette = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { store.showCustomBlock = true }
    }

    private var dataButtons: some View {
        HStack {
            Button { prompt(.variable) } label: { Label("Tạo biến", systemImage: "plus.circle") }
                .buttonStyle(.bordered)
            Button { prompt(.list) } label: { Label("Tạo danh sách", systemImage: "plus.circle") }
                .buttonStyle(.bordered)
        }
    }

    private func prompt(_ kind: NameKind) {
        guard let t = store.selectedTarget, let rt = store.runtime else { return }
        store.showPalette = false
        // Đợi bảng khối đóng rồi mới mở hộp thoại tên.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            store.namePrompt = NamePrompt(kind: kind, initial: "") { name, forAll in
                if kind == .variable { t.createVariable(named: name, forAllSprites: forAll, stage: rt.stage) }
                else { t.createList(named: name, forAllSprites: forAll, stage: rt.stage) }
                store.revision += 1
            }
        }
    }
}

// MARK: - Sửa một ô nhập

struct InputEditSheet: View {
    let request: InputEditRequest
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var color = Color.red
    @State private var loaded = false

    private var kind: InputKind { request.input.kind }

    private var isReporterNow: Bool {
        guard let b = request.target.blocks[request.blockId],
              case .block(let cid)? = b.inputs[request.input.name],
              let child = request.target.blocks[cid] else { return false }
        return !child.shadow
    }

    private var wantsText: Bool {
        switch kind {
        case .number, .text: return true
        default: return false
        }
    }

    private var isColor: Bool {
        if case .color = kind { return true }
        return false
    }

    private var booleanOnly: Bool {
        if case .boolean = kind { return true }
        return false
    }

    var body: some View {
        NavigationView {
            List {
                if wantsText {
                    Section("Giá trị") {
                        TextField("Nhập giá trị", text: $text)
                            .keyboardType({ if case .number = kind { return UIKeyboardType.numbersAndPunctuation }; return .default }())
                        Button("Đặt giá trị") {
                            request.target.setLiteral(block: request.blockId, input: request.input.name, value: text)
                            finish()
                        }
                    }
                }
                if isColor {
                    Section("Màu") {
                        ColorPicker("Chọn màu", selection: $color, supportsOpacity: false)
                        Button("Đặt màu") {
                            request.target.setLiteral(block: request.blockId, input: request.input.name, value: color.hexString)
                            finish()
                        }
                    }
                }
                if isReporterNow {
                    Section {
                        Button("Bỏ khối này", role: .destructive) {
                            if let ctx = store.context(for: request.target) {
                                request.target.resetInput(block: request.blockId, input: request.input, context: ctx)
                            }
                            finish()
                        }
                    }
                }
                if wantsText || booleanOnly {
                    reporterSections
                }
            }
            .navigationTitle("Ô nhập")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Đóng") { dismiss() } } }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let b = request.target.blocks[request.blockId], case .literal(let v)? = b.inputs[request.input.name] {
                    text = v.asString
                    if let c = Color(hexString: v.asString) { color = c }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var reporterSections: some View {
        let args = request.target.argumentOptions(forScriptContaining: request.blockId)
            .filter { booleanOnly ? $0.isBoolean : true }
        if !args.isEmpty {
            Section("Đối số của khối này") {
                ForEach(args.indices, id: \.self) { i in
                    Button(args[i].name) {
                        let r = request.target.makeArgumentReporter(name: args[i].name, isBoolean: args[i].isBoolean)
                        request.target.setInput(block: request.blockId, input: request.input.name, reporter: r)
                        finish()
                    }
                }
            }
        }
        if !booleanOnly, let ctx = store.context(for: request.target) {
            let vars = ctx.options(.variables)
            if !vars.isEmpty {
                Section("Biến") {
                    ForEach(vars.indices, id: \.self) { i in
                        Button(vars[i].label) { insertReporter(opcode: "data_variable", option: vars[i], field: "VARIABLE") }
                    }
                }
            }
            let lists = ctx.options(.lists)
            if !lists.isEmpty {
                Section("Danh sách") {
                    ForEach(lists.indices, id: \.self) { i in
                        Button(lists[i].label) { insertReporter(opcode: "data_listcontents", option: lists[i], field: "LIST") }
                    }
                }
            }
        }
        ForEach(BlockCategory.allCases, id: \.self) { cat in
            let specs = BlockCatalog.specs(in: cat).filter {
                $0.isReporter && (!booleanOnly || $0.shape == .boolean) && $0.opcode != "data_variable" && $0.opcode != "data_listcontents"
            }
            if !specs.isEmpty {
                Section(cat.title) {
                    ForEach(specs, id: \.opcode) { spec in
                        Button { insertReporter(spec: spec) } label: { SpecPreview(spec: spec) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func insertReporter(spec: BlockSpec) {
        guard let ctx = store.context(for: request.target) else { return }
        let r = request.target.makeBlock(spec, context: ctx)
        request.target.setInput(block: request.blockId, input: request.input.name, reporter: r)
        finish()
    }

    private func insertReporter(opcode: String, option: MenuOption, field: String) {
        guard let ctx = store.context(for: request.target), let spec = BlockCatalog.spec(for: opcode) else { return }
        let r = request.target.makeBlock(spec, context: ctx)
        r.fields[field] = .string(option.value)
        r.fieldIds[field] = option.id
        request.target.setInput(block: request.blockId, input: request.input.name, reporter: r)
        finish()
    }

    private func finish() {
        store.revision += 1
        dismiss()
    }
}

// MARK: - Nhập tên (biến, danh sách, tin nhắn, đổi tên sprite)

struct NamePromptSheet: View {
    let prompt: NamePrompt
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var forAll = true

    private var title: String {
        switch prompt.kind {
        case .variable: return "Biến mới"
        case .list: return "Danh sách mới"
        case .broadcast: return "Tin nhắn mới"
        case .rename: return "Đổi tên"
        }
    }

    var body: some View {
        NavigationView {
            Form {
                TextField("Tên", text: $name)
                if (prompt.kind == .variable || prompt.kind == .list), let t = store.selectedTarget, !t.isStage {
                    Picker("Phạm vi", selection: $forAll) {
                        Text("Cho mọi sprite").tag(true)
                        Text("Chỉ sprite này").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                Button("Xong") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    prompt.onDone(n, forAll)
                    dismiss()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Huỷ") { dismiss() } } }
            .onAppear { name = prompt.initial }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Tạo khối tự định nghĩa

struct CustomBlockSheet: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var args: [ArgDraft] = []
    @State private var warp = false

    struct ArgDraft: Identifiable {
        let id = UUID()
        var name: String
        var isBoolean: Bool
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Tên khối") {
                    TextField("Ví dụ: vẽ hình vuông", text: $name)
                }
                Section("Đối số") {
                    ForEach($args) { $a in
                        HStack {
                            TextField("Tên đối số", text: $a.name)
                            Text(a.isBoolean ? "logic" : "số/chữ").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .onDelete { args.remove(atOffsets: $0) }
                    Button("Thêm đối số số/chữ") { args.append(ArgDraft(name: "đối số\(args.count + 1)", isBoolean: false)) }
                    Button("Thêm đối số logic") { args.append(ArgDraft(name: "điều kiện\(args.count + 1)", isBoolean: true)) }
                }
                Section {
                    Toggle("Chạy một mạch (không vẽ lại giữa chừng)", isOn: $warp)
                }
                Button("Tạo khối") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    store.createProcedure(name: n, args: args.map { (name: $0.name, isBoolean: $0.isBoolean) }, warp: warp)
                    dismiss()
                }
            }
            .navigationTitle("Khối mới")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Huỷ") { dismiss() } } }
        }
        .navigationViewStyle(.stack)
    }
}
