import SwiftUI
import UIKit
import ScratchCore

/// UIView vẽ sân khấu và nhận chạm/bàn phím.
final class StageUIView: UIView {
    var runtime: Runtime?
    var renderer: StageRenderer?
    private var link: CADisplayLink?

    override var canBecomeFirstResponder: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .white
        contentMode = .redraw
        isMultipleTouchEnabled = false
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.preferredFramesPerSecond = 30
            l.add(to: .main, forMode: .common)
            link = l
            becomeFirstResponder()
        } else {
            link?.invalidate()
            link = nil
        }
    }

    @objc private func tick() {
        runtime?.step()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let renderer = renderer else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        renderer.draw(in: ctx, width: bounds.width, height: bounds.height)
        ctx.restoreGState()
    }

    // MARK: Chạm

    private func stagePoint(_ touch: UITouch) -> (Double, Double) {
        let p = touch.location(in: self)
        return (Double((p.x / bounds.width - 0.5) * 480), Double((0.5 - p.y / bounds.height) * 360))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let (x, y) = stagePoint(t)
        runtime?.mousePressed(x: x, y: y)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let (x, y) = stagePoint(t)
        runtime?.setMouse(x: x, y: y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { runtime?.mouseReleased() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { runtime?.mouseReleased() }

    // MARK: Bàn phím cứng

    private static func name(for key: UIKey) -> String {
        switch key.keyCode {
        case .keyboardUpArrow: return "up arrow"
        case .keyboardDownArrow: return "down arrow"
        case .keyboardLeftArrow: return "left arrow"
        case .keyboardRightArrow: return "right arrow"
        case .keyboardSpacebar: return "space"
        case .keyboardReturnOrEnter: return "enter"
        default: return key.charactersIgnoringModifiers.lowercased()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses { if let k = p.key { runtime?.keyDown(StageUIView.name(for: k)); handled = true } }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses { if let k = p.key { runtime?.keyUp(StageUIView.name(for: k)); handled = true } }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }
}

struct StageView: UIViewRepresentable {
    let runtime: Runtime
    let renderer: StageRenderer

    func makeUIView(context: Context) -> StageUIView {
        let v = StageUIView()
        v.runtime = runtime
        v.renderer = renderer
        return v
    }

    func updateUIView(_ v: StageUIView, context: Context) {
        v.runtime = runtime
        v.renderer = renderer
    }
}
