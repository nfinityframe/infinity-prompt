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
    var style = "lijn" { didSet { if style != oldValue { needsDisplay = true } } }
    var color = Theme.mint { didSet { if color != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// "lijn": thin line with small markers (approved look). "pijl": arrows only. "beide": line plus big arrows.
    override func draw(_ dirtyRect: NSRect) {
        guard showCue, bounds.width > 0, bounds.height > 0 else { return }
        let y = (bounds.height * cueFraction).rounded() + 0.5
        let arrows = style == "pijl" || style == "beide"
        if style != "pijl" {
            color.withAlphaComponent(color.alphaComponent * 0.55).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: arrows ? 40 : 22, y: y))
            line.line(to: NSPoint(x: bounds.width - (arrows ? 40 : 22), y: y))
            line.lineWidth = 1
            line.stroke()
        }
        color.setFill()
        let s: CGFloat = arrows ? 26 : 11
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
    /// The mirror/flip transform we want. AppKit can swap the backing layer (e.g. when the view
    /// joins a window), which drops the transform, so render() re-applies it when it drifted.
    private var wantedTransform = CGAffineTransform.identity
    private var layoutKey = ""
    private var bag = Set<AnyCancellable>()
    private lazy var refresher = Coalescer { [weak self] in self?.applyAll() }
    /// Settings or text changed; the next display tick (render) does the work, at most once per tick.
    private var dirty = false
    private var fallbackPending = false

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
        p.$isPrompterActive.sink { [weak self] _ in self?.refresher.ask() }.store(in: &bag)
        flush()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Background alpha: only the main window in floating mode lets the desktop through. Text stays opaque.
    var backgroundAlpha: CGFloat {
        let s = Prompter.shared.settings
        guard !isExternal, s.floatingWindow, Prompter.shared.isPrompterActive else { return 1 }
        return s.transparentBackground ? 0 : CGFloat(s.windowOpacity)
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let bg = Prompter.shared.effectiveBackgroundColor()
        let a = backgroundAlpha
        if a < 1 { NSColor.clear.setFill(); dirtyRect.fill(using: .copy) }
        bg.withAlphaComponent(bg.alphaComponent * a).setFill()
        dirtyRect.fill(using: a < 1 ? .copy : .sourceOver)
    }

    override func layout() {
        super.layout()
        host.frame = bounds
        clip.frame = host.bounds
        cueOverlay.frame = host.bounds
        flush()
    }

    // MARK: Settings and text

    /// Marks the view dirty. The work happens on the next render tick, with a short fallback
    /// for when no display link is running.
    private func applyAll() {
        dirty = true
        guard !fallbackPending else { return }
        fallbackPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.fallbackPending = false
                if self.dirty { self.flush() }
            }
        }
    }

    private func flush() {
        dirty = false
        let s = Prompter.shared.settings
        needsDisplay = true
        cueOverlay.showCue = s.showCue
        cueOverlay.cueFraction = CGFloat(s.cuePosition)
        cueOverlay.style = s.cueStyle
        cueOverlay.color = s.cueColor
        relayoutIfNeeded(s)
        applyMirror(s)
        render(position: Prompter.shared.position)
    }

    /// Public: force the pending work now (photos, tests).
    func flushNow() { flush() }

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

    /// Font from settings with bold and italic. The system font uses weights, since trait conversion fails on it.
    private func styledFont(_ s: PrompterSettings, bold: Bool, italic: Bool, regular: NSFont, bold boldBase: NSFont) -> NSFont {
        var f = bold ? boldBase : regular
        if italic {
            if s.fontName.isEmpty || NSFontManager.shared.traits(of: f).contains(.italicFontMask) == false {
                let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
                f = NSFont(descriptor: d, size: f.pointSize) ?? NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
            }
        }
        return f
    }

    private func relayoutIfNeeded(_ s: PrompterSettings) {
        let p = Prompter.shared
        let script = p.currentScript
        let body = script?.body ?? ""
        let width = max(bounds.width, 1)
        let textColor = p.effectiveTextColor()
        let cueBase = s.cueColor.withAlphaComponent(1)
        let key = "\(s.fontName)|\(s.fontSize)|\(s.lineSpacing)|\(s.marginFraction)|\(Theme.hex(textColor))|\(Theme.hex(cueBase))|\(Int(width))|\(body.hashValue)|\(body.count)|\(script?.rtf?.hashValue ?? 0)|\(script?.id.uuidString ?? "")"
        guard key != layoutKey else { return }
        layoutKey = key

        let fm = NSFontManager.shared
        let regular = font(s, bold: false)
        let boldFont = font(s, bold: true)
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = CGFloat(s.lineSpacing)
        para.paragraphSpacing = CGFloat(s.fontSize) * 0.35
        let cuePara = (para.mutableCopy() as? NSMutableParagraphStyle) ?? para
        cuePara.paragraphSpacingBefore = CGFloat(s.fontSize) * 0.3

        // Rich source: keep bold, italic, underline, strikethrough and colour. Family and size come from settings.
        let source = p.currentAttributed
        let ns = source.string as NSString
        let out = NSMutableAttributedString()
        var cueStarts: [Int] = []
        var location = 0
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            guard lineRange.length > 0 else { break }
            let lineText = ns.substring(with: lineRange)
            let leadingSpaces = lineText.prefix(while: { $0 == " " || $0 == "\t" }).utf16.count
            let afterSpaces = (lineText as NSString).substring(from: min(leadingSpaces, (lineText as NSString).length))
            let isCue = afterSpaces.hasPrefix("#")
            var contentStart = lineRange.location
            if isCue {
                // Display only: drop the leading "#" marks and the spaces after them.
                let rest = afterSpaces.drop(while: { $0 == "#" })
                let restTrim = rest.drop(while: { $0 == " " || $0 == "\t" })
                contentStart = lineRange.location + (lineText.utf16.count - String(restTrim).utf16.count)
                cueStarts.append(out.length)
            }
            let contentRange = NSRange(location: contentStart, length: NSMaxRange(lineRange) - contentStart)
            if contentRange.length > 0 {
                source.enumerateAttributes(in: contentRange, options: []) { attrs, range, _ in
                    var wantBold = isCue
                    var wantItalic = false
                    if let srcFont = attrs[.font] as? NSFont {
                        let t = fm.traits(of: srcFont)
                        let sym = srcFont.fontDescriptor.symbolicTraits
                        if t.contains(.boldFontMask) || sym.contains(.bold) { wantBold = true }
                        if t.contains(.italicFontMask) || sym.contains(.italic) { wantItalic = true }
                    }
                    let f = self.styledFont(s, bold: wantBold, italic: wantItalic, regular: regular, bold: boldFont)
                    var a: [NSAttributedString.Key: Any] = [
                        .font: f,
                        .foregroundColor: isCue ? cueBase : ((attrs[.foregroundColor] as? NSColor) ?? textColor),
                        .paragraphStyle: isCue ? cuePara : para,
                    ]
                    if let u = attrs[.underlineStyle] as? Int, u != 0 { a[.underlineStyle] = u }
                    if let st = attrs[.strikethroughStyle] as? Int, st != 0 { a[.strikethroughStyle] = st }
                    out.append(NSAttributedString(string: ns.substring(with: range), attributes: a))
                }
            }
            location = NSMaxRange(lineRange)
        }
        if out.length == 0 { cueStarts = [] }
        _ = boldFont

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
        wantedTransform = t
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(t)
        CATransaction.commit()
    }

    private func ensureMirror() {
        guard let layer = host.layer else { return }
        if layer.affineTransform() != wantedTransform {
            applyMirror(Prompter.shared.settings)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyMirror(Prompter.shared.settings)
    }

    /// The live mirror/flip transform on the text host layer (for the -spiegel check).
    var mirrorTransform: CATransform3D { host.layer?.transform ?? CATransform3DIdentity }

    // MARK: PrompterRenderer

    func render(position: Double) {
        if dirty { flush(); return }   // flush renders at the current position itself
        let p = position.isFinite ? min(max(position, 0), 1) : 0
        lastPosition = p
        let cueY = CGFloat(Prompter.shared.settings.cuePosition) * max(bounds.height, 0)
        let y = firstMid + CGFloat(p) * scrollDistance - cueY
        guard y.isFinite else { return }
        let origin = NSPoint(x: 0, y: y.rounded(.toNearestOrEven))
        if clip.bounds.origin != origin { clip.setBoundsOrigin(origin) }
        ensureMirror()
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
