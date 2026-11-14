#if canImport(CoreGraphics) && canImport(CoreText) && canImport(ImageIO)
import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// Ảnh trang phục đã được rasterize + mặt nạ alpha để kiểm tra va chạm / chạm chuột.
final class CostumeImage {
    let cgImage: CGImage
    let width: Double            // đơn vị Scratch
    let height: Double
    let pixelsPerUnit: Double
    private let context: CGContext

    init?(context: CGContext, width: Double, height: Double, pixelsPerUnit: Double) {
        guard let img = context.makeImage() else { return nil }
        self.cgImage = img
        self.context = context
        self.width = width
        self.height = height
        self.pixelsPerUnit = pixelsPerUnit
    }

    /// Alpha tại toạ độ (đơn vị, gốc ở góc trên trái, y hướng xuống).
    func alpha(x lx: Double, y ly: Double) -> UInt8 {
        let px = Int((lx * pixelsPerUnit).rounded(.down))
        let py = Int((ly * pixelsPerUnit).rounded(.down))
        guard px >= 0, py >= 0, px < context.width, py < context.height, let data = context.data else { return 0 }
        let row = context.bytesPerRow
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        return ptr[py * row + px * 4 + 3]
    }
}

/// Vẽ sân khấu bằng CoreGraphics, đồng thời cung cấp va chạm và lớp bút vẽ.
public final class StageRenderer: SpatialProvider, PenSurface {
    private let runtime: Runtime
    private var cache: [String: CostumeImage] = [:]
    private var missing: Set<String> = []
    private let penScale: CGFloat = 2
    private let penContext: CGContext?

    public init(runtime: Runtime) {
        self.runtime = runtime
        let ctx = CGContext(data: nil, width: 960, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.translateBy(x: 480, y: 360)
        ctx?.scaleBy(x: 2, y: 2)
        ctx?.setLineCap(.round)
        ctx?.setLineJoin(.round)
        penContext = ctx
        runtime.spatial = self
        runtime.pen = self
    }

    // MARK: Ảnh trang phục

    func image(for costume: Costume?) -> CostumeImage? {
        guard let costume = costume else { return nil }
        let key = costume.md5ext
        if let c = cache[key] { return c }
        if missing.contains(key) { return nil }
        guard let data = runtime.project.assets[key] else { missing.insert(key); return nil }

        var result: CostumeImage?
        if costume.isSVG {
            if let doc = SVGDocument(data: data) {
                let scale = 2.0
                if let ctx = doc.rasterize(scale: scale) {
                    result = CostumeImage(context: ctx, width: doc.width, height: doc.height, pixelsPerUnit: Double(ctx.width) / doc.width)
                }
            }
        } else if let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let w = img.width, h = img.height
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                result = CostumeImage(context: ctx, width: Double(w) / costume.bitmapResolution,
                                      height: Double(h) / costume.bitmapResolution, pixelsPerUnit: costume.bitmapResolution)
            }
        }
        if let r = result { cache[key] = r } else { missing.insert(key) }
        return result
    }

    /// Xoá cache (khi mở project khác).
    public func resetCache() { cache.removeAll(); missing.removeAll() }

    /// Ảnh của một trang phục bất kỳ (dùng cho danh sách trang phục).
    public func thumbnail(for costume: Costume) -> CGImage? {
        return image(for: costume)?.cgImage
    }

    /// Ảnh trang phục hiện tại của target (dùng cho hình thu nhỏ trong danh sách sprite).
    public func costumeImage(for target: Target) -> CGImage? {
        return image(for: target.costume)?.cgImage
    }

    // MARK: Biến đổi

    private struct Placement {
        var cx: Double, cy: Double        // tâm xoay (đơn vị trang phục, gốc trên trái)
        var phi: Double                   // góc xoay CCW (rad)
        var scale: Double
        var mirror: Bool
    }

    private func placement(for t: Target, image: CostumeImage) -> Placement? {
        guard let c = t.costume else { return nil }
        let res = c.isSVG ? 1.0 : c.bitmapResolution
        var phi = 0.0
        var mirror = false
        if !t.isStage {
            switch t.rotationStyle {
            case .allAround: phi = (90 - t.direction) * .pi / 180
            case .leftRight: mirror = t.direction < 0
            case .none: break
            }
        }
        return Placement(cx: c.rotationCenterX / res, cy: c.rotationCenterY / res,
                         phi: phi, scale: t.isStage ? 1 : t.size / 100, mirror: mirror)
    }

    private func transform(for t: Target, _ p: Placement) -> CGAffineTransform {
        let x = t.isStage ? 0 : t.x, y = t.isStage ? 0 : t.y
        return CGAffineTransform(translationX: CGFloat(x), y: CGFloat(y))
            .rotated(by: CGFloat(p.phi))
            .scaledBy(x: CGFloat(p.scale * (p.mirror ? -1 : 1)), y: CGFloat(p.scale))
    }

    /// Chuyển toạ độ sân khấu sang toạ độ trang phục (gốc trên trái, y xuống).
    private func localPoint(_ t: Target, _ p: Placement, stageX: Double, stageY: Double) -> (Double, Double) {
        let s = p.scale == 0 ? 0.0001 : p.scale
        let dx = (stageX - (t.isStage ? 0 : t.x)) / s
        let dy = (stageY - (t.isStage ? 0 : t.y)) / s
        let cosP = cos(-p.phi), sinP = sin(-p.phi)
        var u = dx * cosP - dy * sinP
        let v = dx * sinP + dy * cosP
        if p.mirror { u = -u }
        return (u + p.cx, p.cy - v)
    }

    // MARK: SpatialProvider

    public func bounds(of target: Target) -> Rect? {
        guard let img = image(for: target.costume), let p = placement(for: target, image: img) else { return nil }
        let m = transform(for: target, p)
        let corners = [CGPoint(x: -p.cx, y: p.cy), CGPoint(x: img.width - p.cx, y: p.cy),
                       CGPoint(x: -p.cx, y: p.cy - img.height), CGPoint(x: img.width - p.cx, y: p.cy - img.height)]
            .map { $0.applying(m) }
        let xs = corners.map { Double($0.x) }, ys = corners.map { Double($0.y) }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public func touching(_ target: Target, x: Double, y: Double) -> Bool {
        guard let img = image(for: target.costume), let p = placement(for: target, image: img) else { return false }
        let (lx, ly) = localPoint(target, p, stageX: x, stageY: y)
        guard lx >= 0, ly >= 0, lx < img.width, ly < img.height else { return false }
        return img.alpha(x: lx, y: ly) > 0
    }

    public func touching(_ a: Target, _ b: Target) -> Bool {
        guard let ra = bounds(of: a), let rb = bounds(of: b) else { return false }
        let minX = max(ra.minX, rb.minX), maxX = min(ra.maxX, rb.maxX)
        let minY = max(ra.minY, rb.minY), maxY = min(ra.maxY, rb.maxY)
        guard minX < maxX, minY < maxY else { return false }
        guard let ia = image(for: a.costume), let pa = placement(for: a, image: ia),
              let ib = image(for: b.costume), let pb = placement(for: b, image: ib) else { return true }
        let area = (maxX - minX) * (maxY - minY)
        let step = area > 60_000 ? 2.0 : 1.0
        var y = minY
        while y < maxY {
            var x = minX
            while x < maxX {
                let (ax, ay) = localPoint(a, pa, stageX: x, stageY: y)
                if ax >= 0, ay >= 0, ax < ia.width, ay < ia.height, ia.alpha(x: ax, y: ay) > 0 {
                    let (bx, by) = localPoint(b, pb, stageX: x, stageY: y)
                    if bx >= 0, by >= 0, bx < ib.width, by < ib.height, ib.alpha(x: bx, y: by) > 0 { return true }
                }
                x += step
            }
            y += step
        }
        return false
    }

    // MARK: PenSurface

    public func clear() {
        penContext?.clear(CGRect(x: -240, y: -180, width: 480, height: 360))
    }

    public func line(fromX: Double, fromY: Double, toX: Double, toY: Double, pen: PenState) {
        guard let ctx = penContext else { return }
        let c = Runtime.rgb(of: pen)
        let color = CGColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
        if fromX == toX && fromY == toY {
            ctx.setFillColor(color)
            let r = CGFloat(pen.size / 2)
            ctx.fillEllipse(in: CGRect(x: CGFloat(toX) - r, y: CGFloat(toY) - r, width: r * 2, height: r * 2))
        } else {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(CGFloat(pen.size))
            ctx.move(to: CGPoint(x: fromX, y: fromY))
            ctx.addLine(to: CGPoint(x: toX, y: toY))
            ctx.strokePath()
        }
    }

    public func stamp(_ target: Target) {
        guard let ctx = penContext else { return }
        drawSprite(target, in: ctx)
    }

    // MARK: Vẽ

    /// Vẽ toàn bộ sân khấu vào `ctx`. `ctx` phải dùng toạ độ y hướng lên (gốc dưới trái) và có kích thước width × height.
    public func draw(in ctx: CGContext, width: CGFloat, height: CGFloat) {
        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: width / 480, y: height / 360)
        ctx.translateBy(x: 240, y: 180)
        ctx.interpolationQuality = .medium
        ctx.clip(to: CGRect(x: -240, y: -180, width: 480, height: 360))

        // Phông nền
        drawSprite(runtime.stage, in: ctx)

        // Lớp bút
        if let pen = penContext?.makeImage() {
            ctx.draw(pen, in: CGRect(x: -240, y: -180, width: 480, height: 360))
        }

        // Sprite (từ sau ra trước)
        for t in runtime.targets where !t.isStage && t.visible {
            drawSprite(t, in: ctx)
        }

        // Monitor biến
        for m in runtime.monitors where m.visible {
            drawMonitor(m, in: ctx)
        }

        // Bong bóng thoại
        for t in runtime.targets where !t.isStage && t.visible {
            if let b = t.bubble, let r = bounds(of: t) { drawBubble(b, near: r, in: ctx) }
        }
        ctx.restoreGState()
    }

    private func drawSprite(_ t: Target, in ctx: CGContext) {
        guard let img = image(for: t.costume), let p = placement(for: t, image: img) else { return }
        let ghost = t.effects["ghost"] ?? 0
        let alpha = CGFloat(max(0, min(1, 1 - ghost / 100)))
        if alpha <= 0 { return }
        ctx.saveGState()
        ctx.concatenate(transform(for: t, p))
        ctx.setAlpha(alpha)
        ctx.draw(img.cgImage, in: CGRect(x: -p.cx, y: p.cy - img.height, width: img.width, height: img.height))
        ctx.restoreGState()
    }

    // MARK: Chữ

    private func font(size: CGFloat, bold: Bool) -> CTFont {
        return CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    }

    @discardableResult
    private func drawText(_ s: String, at p: CGPoint, size: CGFloat, bold: Bool, color: CGColor, in ctx: CGContext) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font(size: size, bold: bold),
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.saveGState()
        ctx.textPosition = p
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func textWidth(_ s: String, size: CGFloat, bold: Bool) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font(size: size, bold: bold)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func drawMonitor(_ m: Monitor, in ctx: CGContext) {
        let value = runtime.value(of: m)
        let labelW = textWidth(m.label, size: 11, bold: true)
        let valueW = max(40, textWidth(value, size: 11, bold: true) + 10)
        let h: CGFloat = 22
        let w = labelW + valueW + 18
        // Monitor x,y: gốc trên trái, y hướng xuống.
        let rect = CGRect(x: CGFloat(m.x) - 240, y: 180 - CGFloat(m.y) - h, width: w, height: h)
        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 0.9, green: 0.94, blue: 1, alpha: 1))
        ctx.setStrokeColor(CGColor(red: 0.78, green: 0.83, blue: 0.89, alpha: 1))
        let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(path); ctx.drawPath(using: .fillStroke)
        drawText(m.label, at: CGPoint(x: rect.minX + 6, y: rect.minY + 7), size: 11, bold: true,
                 color: CGColor(red: 0.34, green: 0.37, blue: 0.46, alpha: 1), in: ctx)
        let vr = CGRect(x: rect.minX + labelW + 12, y: rect.minY + 3, width: valueW, height: h - 6)
        ctx.setFillColor(CGColor(red: 1, green: 0.55, blue: 0.1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: vr, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
        drawText(value, at: CGPoint(x: vr.minX + 5, y: vr.minY + 4), size: 11, bold: true,
                 color: CGColor(red: 1, green: 1, blue: 1, alpha: 1), in: ctx)
        ctx.restoreGState()
    }

    private func drawBubble(_ b: Bubble, near r: Rect, in ctx: CGContext) {
        let fontSize: CGFloat = 13
        let maxW: CGFloat = 170
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font(size: fontSize, bold: false),
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(red: 0.34, green: 0.37, blue: 0.46, alpha: 1)
        ]
        let fs = CTFramesetterCreateWithAttributedString(NSAttributedString(string: b.text, attributes: attrs))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                                CGSize(width: maxW, height: 1000), nil)
        let pad: CGFloat = 8
        let w = ceil(size.width) + pad * 2, h = ceil(size.height) + pad * 2
        var x = CGFloat(r.maxX) + 4
        var y = CGFloat(r.maxY) + 10
        if x + w > 240 { x = CGFloat(r.minX) - w - 4 }
        x = max(-240, min(240 - w, x))
        y = max(-180, min(180 - h, y))
        let rect = CGRect(x: x, y: y, width: w, height: h)

        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setStrokeColor(CGColor(red: 0.74, green: 0.78, blue: 0.84, alpha: 1))
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.drawPath(using: .fillStroke)
        if b.isThought {
            for (i, d) in [CGFloat(6), CGFloat(4)].enumerated() {
                let c = CGRect(x: rect.minX - CGFloat(i) * 4 - 2, y: rect.minY - 4 - CGFloat(i) * 5, width: d, height: d)
                ctx.fillEllipse(in: c); ctx.strokeEllipse(in: c)
            }
        }
        let framePath = CGPath(rect: CGRect(x: rect.minX + pad, y: rect.minY + pad, width: size.width + 1, height: size.height + 1), transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), framePath, nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}
#endif
