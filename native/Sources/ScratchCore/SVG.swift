#if canImport(CoreGraphics) && canImport(CoreText)
import Foundation
import CoreGraphics
import CoreText

// MARK: - Cây XML

final class SVGNode {
    let name: String
    var attrs: [String: String]
    var children: [SVGNode] = []
    var text = ""
    init(name: String, attrs: [String: String]) { self.name = name; self.attrs = attrs }
}

private final class SVGXMLParser: NSObject, XMLParserDelegate {
    var root: SVGNode?
    var stack: [SVGNode] = []

    func parse(_ data: Data) -> SVGNode? {
        let p = XMLParser(data: data)
        p.delegate = self
        p.shouldProcessNamespaces = false
        p.parse()
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        let node = SVGNode(name: name, attrs: attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }
}

// MARK: - Kiểu

private enum SVGPaint {
    case none
    case color(CGColor)
    case gradient(String)
}

private struct SVGStyle {
    var fill: SVGPaint = .color(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    var stroke: SVGPaint = .none
    var strokeWidth: CGFloat = 1
    var fillOpacity: CGFloat = 1
    var strokeOpacity: CGFloat = 1
    var lineCap: CGLineCap = .butt
    var lineJoin: CGLineJoin = .miter
    var miterLimit: CGFloat = 4
    var evenOdd = false
    var fontSize: CGFloat = 16
    var fontFamily = "Helvetica"
    var fontWeightBold = false
    var textAnchor = "start"
}

private struct GradientStop { var offset: CGFloat; var color: CGColor }

private final class SVGGradient {
    var isRadial = false
    var x1: CGFloat = 0, y1: CGFloat = 0, x2: CGFloat = 1, y2: CGFloat = 0     // linear
    var cx: CGFloat = 0.5, cy: CGFloat = 0.5, r: CGFloat = 0.5, fx: CGFloat? = nil, fy: CGFloat? = nil
    var userSpace = false
    var transform = CGAffineTransform.identity
    var stops: [GradientStop] = []
}

// MARK: - Tài liệu SVG

final class SVGDocument {
    let width: Double
    let height: Double
    let minX: Double
    let minY: Double
    private let root: SVGNode
    private var gradients: [String: SVGGradient] = [:]
    private var nodesById: [String: SVGNode] = [:]

    init?(data: Data) {
        guard let root = SVGXMLParser().parse(data), root.name == "svg" else { return nil }
        self.root = root
        var w = SVGDocument.length(root.attrs["width"]) ?? 0
        var h = SVGDocument.length(root.attrs["height"]) ?? 0
        var mx = 0.0, my = 0.0
        if let vb = root.attrs["viewBox"] ?? root.attrs["viewbox"] {
            let n = SVGDocument.numbers(vb)
            if n.count == 4 {
                mx = n[0]; my = n[1]
                w = n[2]; h = n[3]
            }
        }
        if w <= 0 { w = 1 }
        if h <= 0 { h = 1 }
        width = w; height = h; minX = mx; minY = my
        collect(root)
    }

    private func collect(_ n: SVGNode) {
        if let id = n.attrs["id"] { nodesById[id] = n }
        for c in n.children { collect(c) }
    }

    // MARK: Rasterize

    /// Vẽ ra bitmap có kích thước width*scale × height*scale. Context trả về dùng toạ độ y-up (đã lật).
    func rasterize(scale: Double) -> CGContext? {
        let pw = max(1, min(4096, Int((width * scale).rounded(.up))))
        let ph = max(1, min(4096, Int((height * scale).rounded(.up))))
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let sx = Double(pw) / width, sy = Double(ph) / height
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: CGFloat(sx), y: CGFloat(-sy))
        ctx.translateBy(x: CGFloat(-minX), y: CGFloat(-minY))
        ctx.setAllowsAntialiasing(true)
        render(root, parent: SVGStyle(), ctx: ctx, isRoot: true)
        return ctx
    }

    // MARK: Vẽ node

    private func render(_ node: SVGNode, parent: SVGStyle, ctx: CGContext, isRoot: Bool = false) {
        switch node.name {
        case "defs", "linearGradient", "radialGradient", "clipPath", "mask", "style", "title", "desc", "metadata", "symbol", "pattern":
            return
        default: break
        }
        if node.attrs["display"] == "none" || node.attrs["visibility"] == "hidden" { return }

        var style = parent
        applyStyle(&style, node)

        ctx.saveGState()
        if let t = node.attrs["transform"] { ctx.concatenate(SVGDocument.parseTransform(t)) }

        let opacity = CGFloat(Double(node.attrs["opacity"] ?? "") ?? Double(inlineStyle(node)["opacity"] ?? "") ?? 1)
        let useLayer = opacity < 1
        if useLayer {
            ctx.setAlpha(opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }

        switch node.name {
        case "svg", "g", "a", "switch":
            for c in node.children { render(c, parent: style, ctx: ctx) }
        case "path":
            if let d = node.attrs["d"] { drawShape(SVGDocument.parsePath(d), style: style, ctx: ctx) }
        case "rect":
            let x = a(node, "x"), y = a(node, "y"), w = a(node, "width"), h = a(node, "height")
            if w > 0 && h > 0 {
                var rx = a(node, "rx"), ry = a(node, "ry")
                if node.attrs["rx"] == nil { rx = ry }
                if node.attrs["ry"] == nil { ry = rx }
                rx = min(rx, w / 2); ry = min(ry, h / 2)
                let rect = CGRect(x: x, y: y, width: w, height: h)
                let path: CGPath
                if rx > 0 && ry > 0 {
                    path = CGPath(roundedRect: rect, cornerWidth: rx, cornerHeight: ry, transform: nil)
                } else {
                    path = CGPath(rect: rect, transform: nil)
                }
                drawShape(path, style: style, ctx: ctx)
            }
        case "circle":
            let r = a(node, "r")
            if r > 0 {
                let rect = CGRect(x: a(node, "cx") - r, y: a(node, "cy") - r, width: r * 2, height: r * 2)
                drawShape(CGPath(ellipseIn: rect, transform: nil), style: style, ctx: ctx)
            }
        case "ellipse":
            let rx = a(node, "rx"), ry = a(node, "ry")
            if rx > 0 && ry > 0 {
                let rect = CGRect(x: a(node, "cx") - rx, y: a(node, "cy") - ry, width: rx * 2, height: ry * 2)
                drawShape(CGPath(ellipseIn: rect, transform: nil), style: style, ctx: ctx)
            }
        case "line":
            let p = CGMutablePath()
            p.move(to: CGPoint(x: a(node, "x1"), y: a(node, "y1")))
            p.addLine(to: CGPoint(x: a(node, "x2"), y: a(node, "y2")))
            var s = style
            s.fill = .none
            drawShape(p, style: s, ctx: ctx)
        case "polyline", "polygon":
            let n = SVGDocument.numbers(node.attrs["points"] ?? "")
            if n.count >= 4 {
                let p = CGMutablePath()
                p.move(to: CGPoint(x: n[0], y: n[1]))
                var i = 2
                while i + 1 < n.count { p.addLine(to: CGPoint(x: n[i], y: n[i + 1])); i += 2 }
                if node.name == "polygon" { p.closeSubpath() }
                drawShape(p, style: style, ctx: ctx)
            }
        case "text":
            drawText(node, style: style, ctx: ctx)
        default:
            break
        }

        if useLayer { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    private func a(_ node: SVGNode, _ key: String) -> CGFloat {
        return CGFloat(SVGDocument.length(node.attrs[key]) ?? 0)
    }

    // MARK: Style

    private func inlineStyle(_ node: SVGNode) -> [String: String] {
        guard let s = node.attrs["style"] else { return [:] }
        var out: [String: String] = [:]
        for part in s.split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    private func applyStyle(_ st: inout SVGStyle, _ node: SVGNode) {
        var props = node.attrs
        for (k, v) in inlineStyle(node) { props[k] = v }

        if let f = props["fill"] { st.fill = parsePaint(f) }
        if let s = props["stroke"] { st.stroke = parsePaint(s) }
        if let w = props["stroke-width"], let d = SVGDocument.length(w) { st.strokeWidth = CGFloat(d) }
        if let o = props["fill-opacity"], let d = Double(o) { st.fillOpacity = CGFloat(d) }
        if let o = props["stroke-opacity"], let d = Double(o) { st.strokeOpacity = CGFloat(d) }
        if let c = props["stroke-linecap"] {
            st.lineCap = c == "round" ? .round : (c == "square" ? .square : .butt)
        }
        if let j = props["stroke-linejoin"] {
            st.lineJoin = j == "round" ? .round : (j == "bevel" ? .bevel : .miter)
        }
        if let m = props["stroke-miterlimit"], let d = Double(m) { st.miterLimit = CGFloat(d) }
        if let r = props["fill-rule"] { st.evenOdd = (r == "evenodd") }
        if let fs = props["font-size"], let d = SVGDocument.length(fs) { st.fontSize = CGFloat(d) }
        if let ff = props["font-family"] {
            let first = ff.split(separator: ",").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) } ?? ff
            st.fontFamily = first
        }
        if let fw = props["font-weight"] { st.fontWeightBold = (fw == "bold" || (Int(fw) ?? 400) >= 600) }
        if let ta = props["text-anchor"] { st.textAnchor = ta }
    }

    private func parsePaint(_ raw: String) -> SVGPaint {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s == "none" || s == "transparent" { return .none }
        if s.hasPrefix("url(") {
            if let open = s.firstIndex(of: "#"), let close = s.firstIndex(of: ")") {
                return .gradient(String(s[s.index(after: open)..<close]))
            }
            return .none
        }
        if let c = SVGDocument.parseColor(s) { return .color(c) }
        return .none
    }

    // MARK: Vẽ hình

    private func drawShape(_ path: CGPath, style: SVGStyle, ctx: CGContext) {
        switch style.fill {
        case .none: break
        case .color(let c):
            ctx.saveGState()
            ctx.setFillColor(c.copy(alpha: c.alpha * style.fillOpacity) ?? c)
            ctx.addPath(path)
            ctx.fillPath(using: style.evenOdd ? .evenOdd : .winding)
            ctx.restoreGState()
        case .gradient(let id):
            fillGradient(id, path: path, evenOdd: style.evenOdd, opacity: style.fillOpacity, ctx: ctx)
        }

        var strokeColor: CGColor?
        switch style.stroke {
        case .none: break
        case .color(let c): strokeColor = c.copy(alpha: c.alpha * style.strokeOpacity) ?? c
        case .gradient(let id):
            // Gradient viền: dùng màu của điểm dừng đầu tiên.
            if let g = resolveGradient(id), let s = g.stops.first { strokeColor = s.color }
        }
        if let sc = strokeColor, style.strokeWidth > 0 {
            ctx.saveGState()
            ctx.setStrokeColor(sc)
            ctx.setLineWidth(style.strokeWidth)
            ctx.setLineCap(style.lineCap)
            ctx.setLineJoin(style.lineJoin)
            ctx.setMiterLimit(style.miterLimit)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func resolveGradient(_ id: String) -> SVGGradient? {
        if let g = gradients[id] { return g }
        guard let node = nodesById[id], node.name == "linearGradient" || node.name == "radialGradient" else { return nil }
        let g = SVGGradient()
        var chain: [SVGNode] = [node]
        var cur = node
        var guardCount = 0
        while let href = cur.attrs["xlink:href"] ?? cur.attrs["href"], href.hasPrefix("#"),
              let next = nodesById[String(href.dropFirst())], guardCount < 8 {
            chain.append(next); cur = next; guardCount += 1
        }
        g.isRadial = node.name == "radialGradient"
        g.userSpace = (node.attrs["gradientUnits"] ?? chain.compactMap { $0.attrs["gradientUnits"] }.first) == "userSpaceOnUse"

        func attr(_ k: String) -> String? { chain.compactMap { $0.attrs[k] }.first }
        func frac(_ k: String, _ def: CGFloat) -> CGFloat {
            guard let v = attr(k) else { return def }
            if v.hasSuffix("%"), let d = Double(v.dropLast()) { return CGFloat(d / 100) }
            return CGFloat(Double(v) ?? Double(def))
        }
        if g.isRadial {
            g.cx = frac("cx", 0.5); g.cy = frac("cy", 0.5); g.r = frac("r", 0.5)
            if attr("fx") != nil { g.fx = frac("fx", g.cx) }
            if attr("fy") != nil { g.fy = frac("fy", g.cy) }
        } else {
            g.x1 = frac("x1", 0); g.y1 = frac("y1", 0); g.x2 = frac("x2", 1); g.y2 = frac("y2", 0)
        }
        if let t = attr("gradientTransform") { g.transform = SVGDocument.parseTransform(t) }

        // Điểm dừng lấy từ node đầu tiên trong chuỗi href có <stop>.
        for n in chain {
            let stops = n.children.filter { $0.name == "stop" }
            if stops.isEmpty { continue }
            for s in stops {
                var props = s.attrs
                for (k, v) in inlineStyle(s) { props[k] = v }
                var offset: CGFloat = 0
                if let o = props["offset"] {
                    if o.hasSuffix("%"), let d = Double(o.dropLast()) { offset = CGFloat(d / 100) }
                    else { offset = CGFloat(Double(o) ?? 0) }
                }
                var color = SVGDocument.parseColor(props["stop-color"] ?? "#000") ?? CGColor(red: 0, green: 0, blue: 0, alpha: 1)
                if let so = props["stop-opacity"], let d = Double(so) { color = color.copy(alpha: color.alpha * CGFloat(d)) ?? color }
                g.stops.append(GradientStop(offset: min(1, max(0, offset)), color: color))
            }
            break
        }
        gradients[id] = g
        return g
    }

    private func fillGradient(_ id: String, path: CGPath, evenOdd: Bool, opacity: CGFloat, ctx: CGContext) {
        guard let g = resolveGradient(id), !g.stops.isEmpty else { return }
        let colors = g.stops.map { $0.color.copy(alpha: $0.color.alpha * opacity) ?? $0.color }
        var locs = g.stops.map { $0.offset }
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: &locs) else { return }

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip(using: evenOdd ? .evenOdd : .winding)
        let bbox = path.boundingBoxOfPath
        if !g.userSpace {
            ctx.concatenate(CGAffineTransform(translationX: bbox.minX, y: bbox.minY).scaledBy(x: max(bbox.width, 0.0001), y: max(bbox.height, 0.0001)))
        }
        ctx.concatenate(g.transform)
        let opts: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        if g.isRadial {
            let c = CGPoint(x: g.cx, y: g.cy)
            let f = CGPoint(x: g.fx ?? g.cx, y: g.fy ?? g.cy)
            ctx.drawRadialGradient(grad, startCenter: f, startRadius: 0, endCenter: c, endRadius: g.r, options: opts)
        } else {
            ctx.drawLinearGradient(grad, start: CGPoint(x: g.x1, y: g.y1), end: CGPoint(x: g.x2, y: g.y2), options: opts)
        }
        ctx.restoreGState()
    }

    // MARK: Text

    private func drawText(_ node: SVGNode, style: SVGStyle, ctx: CGContext) {
        var lines: [(String, CGFloat, CGFloat)] = []   // text, x, y
        var x = a(node, "x"), y = a(node, "y")
        let direct = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty && node.children.isEmpty { lines.append((direct, x, y)) }
        for c in node.children where c.name == "tspan" {
            if let xs = c.attrs["x"], let d = SVGDocument.length(xs) { x = CGFloat(d) }
            if let ys = c.attrs["y"], let d = SVGDocument.length(ys) { y = CGFloat(d) }
            if let dy = c.attrs["dy"] {
                if dy.hasSuffix("em"), let d = Double(dy.dropLast(2)) { y += CGFloat(d) * style.fontSize }
                else if let d = SVGDocument.length(dy) { y += CGFloat(d) }
            }
            let t = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines.append((t, x, y)) }
        }
        guard !lines.isEmpty, case .color(let color) = style.fill else { return }

        var family = style.fontFamily
        switch family.lowercased() {
        case "sans serif", "sans-serif", "scratch": family = "Helvetica"
        case "serif": family = "Times New Roman"
        case "handwriting": family = "Noteworthy"
        case "marker": family = "Marker Felt"
        case "curly": family = "Snell Roundhand"
        case "pixel": family = "Courier"
        default: break
        }
        let baseFont = CTFontCreateWithName(family as CFString, style.fontSize, nil)
        let font = style.fontWeightBold
            ? (CTFontCreateCopyWithSymbolicTraits(baseFont, style.fontSize, nil, .boldTrait, .boldTrait) ?? baseFont)
            : baseFont

        for (text, lx, ly) in lines {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
                NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): color
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            var px = lx
            if style.textAnchor == "middle" { px -= w / 2 } else if style.textAnchor == "end" { px -= w }
            ctx.saveGState()
            ctx.translateBy(x: px, y: ly)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    // MARK: Phân tích số / màu / transform

    static func length(_ s: String?) -> Double? {
        guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        for unit in ["px", "pt"] where t.hasSuffix(unit) { t = String(t.dropLast(unit.count)) }
        return Double(t)
    }

    static func numbers(_ s: String) -> [Double] {
        var out: [Double] = []
        var scanner = NumberScanner(s)
        while let n = scanner.nextNumber() { out.append(n) }
        return out
    }

    static func parseTransform(_ s: String) -> CGAffineTransform {
        var total = CGAffineTransform.identity
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")"), open < close {
            let name = rest[rest.startIndex..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\t"))
            let n = numbers(String(rest[rest.index(after: open)..<close]))
            var t = CGAffineTransform.identity
            switch name {
            case "matrix" where n.count == 6:
                t = CGAffineTransform(a: CGFloat(n[0]), b: CGFloat(n[1]), c: CGFloat(n[2]), d: CGFloat(n[3]), tx: CGFloat(n[4]), ty: CGFloat(n[5]))
            case "translate" where n.count >= 1:
                t = CGAffineTransform(translationX: CGFloat(n[0]), y: CGFloat(n.count > 1 ? n[1] : 0))
            case "scale" where n.count >= 1:
                t = CGAffineTransform(scaleX: CGFloat(n[0]), y: CGFloat(n.count > 1 ? n[1] : n[0]))
            case "rotate" where n.count >= 1:
                let r = CGFloat(n[0] * .pi / 180)
                if n.count >= 3 {
                    t = CGAffineTransform(translationX: CGFloat(n[1]), y: CGFloat(n[2])).rotated(by: r)
                        .translatedBy(x: CGFloat(-n[1]), y: CGFloat(-n[2]))
                } else {
                    t = CGAffineTransform(rotationAngle: r)
                }
            case "skewX" where n.count >= 1:
                t = CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(n[0] * .pi / 180)), d: 1, tx: 0, ty: 0)
            case "skewY" where n.count >= 1:
                t = CGAffineTransform(a: 1, b: CGFloat(tan(n[0] * .pi / 180)), c: 0, d: 1, tx: 0, ty: 0)
            default: break
            }
            total = t.concatenating(total)
            rest = rest[rest.index(after: close)...]
        }
        return total
    }

    static func parseColor(_ raw: String) -> CGColor? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        func make(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
            return CGColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
        }
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            if hex.count == 6 {
                return make(Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
            }
            return make(Double((v >> 24) & 0xff) / 255, Double((v >> 16) & 0xff) / 255,
                        Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
        }
        if s.hasPrefix("rgb") , let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")") {
            let parts = s[s.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            let vals = parts.map { p -> Double in
                if p.hasSuffix("%") { return (Double(p.dropLast()) ?? 0) * 2.55 }
                return Double(p) ?? 0
            }
            if vals.count >= 3 { return make(vals[0] / 255, vals[1] / 255, vals[2] / 255, vals.count > 3 ? vals[3] : 1) }
        }
        let named: [String: (Double, Double, Double)] = [
            "black": (0, 0, 0), "white": (1, 1, 1), "red": (1, 0, 0), "green": (0, 0.5, 0), "blue": (0, 0, 1),
            "yellow": (1, 1, 0), "orange": (1, 0.647, 0), "gray": (0.5, 0.5, 0.5), "grey": (0.5, 0.5, 0.5),
            "purple": (0.5, 0, 0.5), "pink": (1, 0.753, 0.796), "brown": (0.647, 0.165, 0.165),
            "cyan": (0, 1, 1), "magenta": (1, 0, 1), "lime": (0, 1, 0), "navy": (0, 0, 0.5)
        ]
        if let n = named[s] { return make(n.0, n.1, n.2) }
        return nil
    }

    // MARK: Path

    static func parsePath(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var sc = NumberScanner(d)
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCtrl: CGPoint?
        var lastCmd: Character = " "
        var cmd: Character = " "

        func pt(_ x: Double, _ y: Double, _ rel: Bool) -> CGPoint {
            return rel ? CGPoint(x: cur.x + CGFloat(x), y: cur.y + CGFloat(y)) : CGPoint(x: CGFloat(x), y: CGFloat(y))
        }

        while true {
            sc.skipSeparators()
            guard let ch = sc.peek() else { break }
            if ch.isLetter { cmd = ch; sc.advance() }
            else if cmd == " " { break }
            else if cmd == "M" { cmd = "L" } else if cmd == "m" { cmd = "l" }
            // (lặp lại tham số cho lệnh hiện tại)

            let rel = cmd.isLowercase
            switch cmd {
            case "M", "m":
                guard let x = sc.nextNumber(), let y = sc.nextNumber() else { return path }
                cur = pt(x, y, rel); start = cur
                path.move(to: cur); lastCtrl = nil
                cmd = rel ? "l" : "L"
            case "L", "l":
                guard let x = sc.nextNumber(), let y = sc.nextNumber() else { return path }
                cur = pt(x, y, rel); path.addLine(to: cur); lastCtrl = nil
            case "H", "h":
                guard let x = sc.nextNumber() else { return path }
                cur = CGPoint(x: rel ? cur.x + CGFloat(x) : CGFloat(x), y: cur.y); path.addLine(to: cur); lastCtrl = nil
            case "V", "v":
                guard let y = sc.nextNumber() else { return path }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + CGFloat(y) : CGFloat(y)); path.addLine(to: cur); lastCtrl = nil
            case "C", "c":
                guard let x1 = sc.nextNumber(), let y1 = sc.nextNumber(), let x2 = sc.nextNumber(),
                      let y2 = sc.nextNumber(), let x = sc.nextNumber(), let y = sc.nextNumber() else { return path }
                let c1 = pt(x1, y1, rel), c2 = pt(x2, y2, rel), e = pt(x, y, rel)
                path.addCurve(to: e, control1: c1, control2: c2)
                lastCtrl = c2; cur = e
            case "S", "s":
                guard let x2 = sc.nextNumber(), let y2 = sc.nextNumber(), let x = sc.nextNumber(), let y = sc.nextNumber() else { return path }
                var c1 = cur
                if "CcSs".contains(lastCmd), let lc = lastCtrl { c1 = CGPoint(x: 2 * cur.x - lc.x, y: 2 * cur.y - lc.y) }
                let c2 = pt(x2, y2, rel), e = pt(x, y, rel)
                path.addCurve(to: e, control1: c1, control2: c2)
                lastCtrl = c2; cur = e
            case "Q", "q":
                guard let x1 = sc.nextNumber(), let y1 = sc.nextNumber(), let x = sc.nextNumber(), let y = sc.nextNumber() else { return path }
                let c = pt(x1, y1, rel), e = pt(x, y, rel)
                path.addQuadCurve(to: e, control: c)
                lastCtrl = c; cur = e
            case "T", "t":
                guard let x = sc.nextNumber(), let y = sc.nextNumber() else { return path }
                var c = cur
                if "QqTt".contains(lastCmd), let lc = lastCtrl { c = CGPoint(x: 2 * cur.x - lc.x, y: 2 * cur.y - lc.y) }
                let e = pt(x, y, rel)
                path.addQuadCurve(to: e, control: c)
                lastCtrl = c; cur = e
            case "A", "a":
                guard let rx = sc.nextNumber(), let ry = sc.nextNumber(), let rot = sc.nextNumber(),
                      let large = sc.nextFlag(), let sweep = sc.nextFlag(),
                      let x = sc.nextNumber(), let y = sc.nextNumber() else { return path }
                let e = pt(x, y, rel)
                addArc(path, from: cur, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep, to: e)
                cur = e; lastCtrl = nil
            case "Z", "z":
                path.closeSubpath(); cur = start; lastCtrl = nil
                cmd = " "   // Z không có tham số: dừng nếu theo sau không phải lệnh mới
            default:
                return path
            }
            lastCmd = cmd
        }
        return path
    }

    private static func addArc(_ path: CGMutablePath, from p0: CGPoint, rx rxIn: Double, ry ryIn: Double,
                               rotation: Double, large: Bool, sweep: Bool, to p1: CGPoint) {
        if p0 == p1 { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let x0 = Double(p0.x), y0 = Double(p0.y), x1 = Double(p1.x), y1 = Double(p1.y)
        let dx2 = (x0 - x1) / 2, dy2 = (y0 - y1) / 2
        let x1p = cosP * dx2 + sinP * dy2
        let y1p = -sinP * dx2 + cosP * dy2
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = lambda.squareRoot(); rx *= s; ry *= s }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : max(0, num / den).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = coef * -(ry * x1p / rx)
        let cx = cosP * cxp - sinP * cyp + (x0 + x1) / 2
        let cy = sinP * cxp + cosP * cyp + (y0 + y1) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let len = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dtheta > 0 { dtheta -= 2 * .pi }
        else if sweep && dtheta < 0 { dtheta += 2 * .pi }

        let segs = max(1, Int((abs(dtheta) / (.pi / 2)).rounded(.up)))
        let delta = dtheta / Double(segs)
        let t = 4.0 / 3.0 * tan(delta / 4)

        func point(_ th: Double) -> (Double, Double) {
            return (cx + rx * cos(th) * cosP - ry * sin(th) * sinP,
                    cy + rx * cos(th) * sinP + ry * sin(th) * cosP)
        }
        func deriv(_ th: Double) -> (Double, Double) {
            return (-rx * sin(th) * cosP - ry * cos(th) * sinP,
                    -rx * sin(th) * sinP + ry * cos(th) * cosP)
        }
        var th = theta1
        for _ in 0..<segs {
            let th2 = th + delta
            let (px, py) = point(th), (qx, qy) = point(th2)
            let (dx1, dy1) = deriv(th), (dx2b, dy2b) = deriv(th2)
            path.addCurve(to: CGPoint(x: qx, y: qy),
                          control1: CGPoint(x: px + t * dx1, y: py + t * dy1),
                          control2: CGPoint(x: qx - t * dx2b, y: qy - t * dy2b))
            th = th2
        }
    }
}

// MARK: - Bộ quét số

struct NumberScanner {
    private let chars: [Character]
    private var i = 0

    init(_ s: String) { chars = Array(s) }

    func peek() -> Character? { i < chars.count ? chars[i] : nil }
    mutating func advance() { i += 1 }

    mutating func skipSeparators() {
        while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" || chars[i] == "\r" {
            i += 1
        }
    }

    /// Đọc cờ 0/1 của lệnh cung (có thể viết dính liền).
    mutating func nextFlag() -> Bool? {
        skipSeparators()
        guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
        let v = chars[i] == "1"
        i += 1
        return v
    }

    mutating func nextNumber() -> Double? {
        skipSeparators()
        guard i < chars.count else { return nil }
        let start = i
        var j = i
        if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
        var digits = false
        while j < chars.count, chars[j].isNumber, chars[j].isASCII { j += 1; digits = true }
        if j < chars.count, chars[j] == "." {
            j += 1
            while j < chars.count, chars[j].isNumber, chars[j].isASCII { j += 1; digits = true }
        }
        guard digits else { return nil }
        if j < chars.count, chars[j] == "e" || chars[j] == "E" {
            var k = j + 1
            if k < chars.count, chars[k] == "+" || chars[k] == "-" { k += 1 }
            if k < chars.count, chars[k].isNumber, chars[k].isASCII {
                while k < chars.count, chars[k].isNumber, chars[k].isASCII { k += 1 }
                j = k
            }
        }
        i = j
        return Double(String(chars[start..<j]))
    }
}

/// Kích thước gốc của một tệp SVG (đơn vị Scratch).
public func svgIntrinsicSize(_ data: Data) -> (width: Double, height: Double)? {
    guard let doc = SVGDocument(data: data) else { return nil }
    return (doc.width, doc.height)
}
#endif
