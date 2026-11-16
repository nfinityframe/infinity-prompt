// PrompterView.swift, Infinity Prompt
// The text that scrolls. AppKit + TextKit 1. render(position:) only moves the clip bounds.
// Mirror and flip are a layer transform on a host view, never a re-layout.

import AppKit
import Combine

// MARK: - Theme

enum Theme {
    static let black = NSColor.black
    static let card = NSColor(srgbRed: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0, alpha: 1)
    static let cardSelected = NSColor(srgbRed: 0x2C / 255.0, green: 0x2C / 255.0, blue: 0x2E / 255.0, alpha: 1)
    static let mint = NSColor(srgbRed: 0x75 / 255.0, green: 0xFA / 255.0, blue: 0x9D / 255.0, alpha: 1)
    static let text = NSColor.white
    static let grey = NSColor(white: 0.60, alpha: 1)
    static let faint = NSColor(white: 1, alpha: 0.08)
    static let fast: TimeInterval = 0.12
    static let soft: TimeInterval = 0.28

    /// Small, grey, uppercase, letter-spaced label text.
    static func label(_ s: String, size: CGFloat = 11, color: NSColor = Theme.grey) -> NSAttributedString {
        NSAttributedString(string: s.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color,
            .kern: size * 0.14,
        ])
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? NSColor.white
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    static func clock(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "0:00" }
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Runs a block once on the next main-queue turn, however often it is asked in between.
/// Needed because @Published emits before the new value is stored.
@MainActor final class Coalescer {
    private var pending = false
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    func ask() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.pending = false
                self.block()
            }
        }
    }
}

// MARK: - Clip view that allows any origin (the text starts below the cue line)

final class FreeClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
    override var isFlipped: Bool { true }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Cue line overlay

final class CueOverlay: NSView {
    var cueFraction: CGFloat = 0.33 { didSet { if cueFraction != oldValue { needsDisplay = true } } }
    var showCue = true { didSet { if showCue != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard showCue, bounds.width > 0, bounds.height > 0 else { return }
        let y = (bounds.height * cueFraction).rounded() + 0.5
        Theme.mint.withAlphaComponent(0.55).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 22, y: y))
        line.line(to: NSPoint(x: bounds.width - 22, y: y))
        line.lineWidth = 1
        line.stroke()
        Theme.mint.setFill()
        let s: CGFloat = 11
        let left = NSBezierPath()
        left.move(to: NSPoint(x: 4, y: y - s / 1.4))
        left.line(to: NSPoint(x: 4 + s, y: y))
        left.line(to: NSPoint(x: 4, y: y + s / 1.4))
        left.close()
        left.fill()
        let right = NSBezierPath()
        right.move(to: NSPoint(x: bounds.width - 4, y: y - s / 1.4))
        right.line(to: NSPoint(x: bounds.width - 4 - s, y: y))
        right.line(to: NSPoint(x: bounds.width - 4, y: y + s / 1.4))
        right.close()
        right.fill()
    }
}

// MARK: - PrompterView

@MainActor final class PrompterView: NSView, PrompterRenderer {
    let isExternal: Bool

    private(set) var contentHeight: Double = 0
    var viewportHeight: Double { Double(max(bounds.height, 0)) }
    private(set) var cueFractions: [Double] = []

    /// Called after every render with the position, for a progress line. Must stay cheap.
    var onRender: ((Double) -> Void)?
    /// Called after a re-layout (cue points may have moved).
    var onLayoutChange: (() -> Void)?

    private let host = FlippedView()
    private let clip = FreeClipView()
    private let textView: NSTextView
    private let cueOverlay = CueOverlay()

    private var firstMid: CGFloat = 0
    private var scrollDistance: CGFloat = 0
    private var lastPosition: Double = 0
    private var layoutKey = ""
    private var bag = Set<AnyCancellable>()
    private lazy var refresher = Coalescer { [weak self] in self?.applyAll() }

    init(isExternal: Bool) {
        self.isExternal = isExternal
        // TextKit 1, explicitly.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 100), textContainer: container)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))

        wantsLayer = true
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.isRichText = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.allowsUndo = false

        clip.drawsBackground = false
        clip.documentView = textView
        host.addSubview(clip)
        host.addSubview(cueOverlay)
        host.wantsLayer = true
        addSubview(host)

        let p = Prompter.shared
        p.$settings.sink { [weak self] _ in self?.refresher.ask() }.store(in: &bag)
        p.$scripts.sink { [weak self] _ in self?.refresher.ask() }.store(in: &bag)
        p.$currentScriptID.sink { [weak self] _ in self?.refresher.ask() }.store(in: &bag)
        applyAll()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        Prompter.shared.settings.backgroundColor.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        host.frame = bounds
        clip.frame = host.bounds
        cueOverlay.frame = host.bounds
        applyAll()
    }

    // MARK: Settings and text

    private func applyAll() {
        let s = Prompter.shared.settings
        needsDisplay = true
        cueOverlay.showCue = s.showCue
        cueOverlay.cueFraction = CGFloat(s.cuePosition)
        relayoutIfNeeded(s)
        applyMirror(s)
        render(position: Prompter.shared.position)
    }

    private func font(_ s: PrompterSettings, bold: Bool) -> NSFont {
        let size = CGFloat(s.fontSize)
        if !s.fontName.isEmpty, let f = NSFont(name: s.fontName, size: size) {
            if bold { return NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
            return f
        }
        if !s.fontName.isEmpty, let f = NSFontManager.shared.font(withFamily: s.fontName, traits: bold ? .boldFontMask : [], weight: 5, size: size) {
            return f
        }
        return NSFont.systemFont(ofSize: size, weight: bold ? .bold : .medium)
    }

    private func relayoutIfNeeded(_ s: PrompterSettings) {
        let body = Prompter.shared.currentScript?.body ?? ""
        let width = max(bounds.width, 1)
        let key = "\(s.fontName)|\(s.fontSize)|\(s.lineSpacing)|\(s.marginFraction)|\(s.textColorHex)|\(Int(width))|\(body.hashValue)|\(body.count)"
        guard key != layoutKey else { return }
        layoutKey = key

        let regular = font(s, bold: false)
        let bold = font(s, bold: true)
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = CGFloat(s.lineSpacing)
        para.paragraphSpacing = CGFloat(s.fontSize) * 0.35
        let cuePara = (para.mutableCopy() as? NSMutableParagraphStyle) ?? para
        cuePara.paragraphSpacingBefore = CGFloat(s.fontSize) * 0.3

        let out = NSMutableAttributedString()
        var cueStarts: [Int] = []
        let lines = body.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let isCue = trimmed.hasPrefix("#")
            var line = raw
            if isCue {
                line = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                cueStarts.append(out.length)
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isCue ? bold : regular,
                .foregroundColor: isCue ? Theme.mint : s.textColor,
                .paragraphStyle: isCue ? cuePara : para,
            ]
            out.append(NSAttributedString(string: line + (i < lines.count - 1 ? "\n" : ""), attributes: attrs))
        }

        let margin = (width * CGFloat(s.marginFraction)).rounded()
        textView.textContainerInset = NSSize(width: margin, height: 0)
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        textView.textContainer?.containerSize = NSSize(width: max(width - 2 * margin, 10), height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(out)

        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        textView.setFrameSize(NSSize(width: width, height: max(used.maxY + 4, 1)))

        let glyphCount = manager.numberOfGlyphs
        var fractions: [Double] = []
        if glyphCount > 0 {
            let first = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let last = manager.lineFragmentRect(forGlyphAt: max(glyphCount - 1, 0), effectiveRange: nil)
            firstMid = first.midY
            let distance = last.midY - first.midY
            scrollDistance = distance.isFinite ? max(distance, 0) : 0
            if scrollDistance > 0 {
                for start in cueStarts where start < out.length {
                    let g = manager.glyphIndexForCharacter(at: start)
                    guard g < glyphCount else { continue }
                    let r = manager.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                    let f = Double((r.midY - firstMid) / scrollDistance)
                    if f.isFinite { fractions.append(min(max(f, 0), 1)) }
                }
            }
        } else {
            firstMid = CGFloat(s.fontSize) * 0.6
            scrollDistance = 0
        }
        contentHeight = Double(scrollDistance)
        cueFractions = fractions.sorted()
        onLayoutChange?()
    }

    private func applyMirror(_ s: PrompterSettings) {
        guard let layer = host.layer else { return }
        let mirror = isExternal ? s.mirrorExternal : s.mirrorMain
        let flip = s.flipVertical
        let w = layer.bounds.width
        let h = layer.bounds.height
        let ax = layer.anchorPoint.x * w
        let ay = layer.anchorPoint.y * h
        // Mirror around the centre of the layer, whatever its anchor point is.
        var t = CGAffineTransform.identity
        if mirror { t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w - 2 * ax, ty: 0) }
        if flip { t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h - 2 * ay)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(t)
        CATransaction.commit()
    }

    // MARK: PrompterRenderer

    func render(position: Double) {
        let p = position.isFinite ? min(max(position, 0), 1) : 0
        lastPosition = p
        let cueY = CGFloat(Prompter.shared.settings.cuePosition) * max(bounds.height, 0)
        let y = firstMid + CGFloat(p) * scrollDistance - cueY
        guard y.isFinite else { return }
        let origin = NSPoint(x: 0, y: y.rounded(.toNearestOrEven))
        if clip.bounds.origin != origin { clip.setBoundsOrigin(origin) }
        onRender?(p)
    }

    // MARK: Mouse

    private var dragged = false

    override func scrollWheel(with event: NSEvent) {
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let dy = -event.scrollingDeltaY * factor
        guard dy.isFinite, dy != 0 else { return }
        Prompter.shared.nudge(points: Double(dy))
    }

    override func mouseDown(with event: NSEvent) {
        dragged = false
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        let dy = -event.deltaY
        if dy != 0 { Prompter.shared.nudge(points: Double(dy)) }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { Prompter.shared.toggleScrolling() }
        dragged = false
    }
}
