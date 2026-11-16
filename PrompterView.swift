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

/// The prompter's text view. Never scrolls itself: the engine owns the position.
final class PrompterTextView: NSTextView {
    override func scrollRangeToVisible(_ range: NSRange) {}
    override func scrollToVisible(_ rect: NSRect) -> Bool { false }
    override func scroll(_ point: NSPoint) {}
}

/// Marks a colour the prompter added for display (default text colour, cue colour), so it is not saved.
extension NSAttributedString.Key {
    static let ipDisplayColor = NSAttributedString.Key("InfinityPromptDisplayColor")
}

extension Notification.Name {
    static let ipEditingChanged = Notification.Name("InfinityPromptEditingChanged")
}

// MARK: - Bold, italic, underline on any text view (editor and prompter)

@MainActor enum TextStyling {
    static func isOn(_ f: NSFont, _ trait: NSFontDescriptor.SymbolicTraits) -> Bool {
        if f.fontDescriptor.symbolicTraits.contains(trait) { return true }
        let t = NSFontManager.shared.traits(of: f)
        return trait == .bold ? t.contains(.boldFontMask) : t.contains(.italicFontMask)
    }

    static func set(_ f: NSFont, _ trait: NSFontDescriptor.SymbolicTraits, on: Bool) -> NSFont {
        var traits = f.fontDescriptor.symbolicTraits
        if on { traits.insert(trait) } else { traits.remove(trait) }
        if let n = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(traits), size: f.pointSize),
           isOn(n, trait) == on { return n }
        let mask: NSFontTraitMask = trait == .bold ? .boldFontMask : .italicFontMask
        return on ? NSFontManager.shared.convert(f, toHaveTrait: mask) : NSFontManager.shared.convert(f, toNotHaveTrait: mask)
    }

    static func toggle(_ trait: NSFontDescriptor.SymbolicTraits, in tv: NSTextView, fallback: NSFont) {
        let r = tv.selectedRange()
        if r.length == 0 {
            let f = (tv.typingAttributes[.font] as? NSFont) ?? fallback
            tv.typingAttributes[.font] = set(f, trait, on: !isOn(f, trait))
            return
        }
        guard let storage = tv.textStorage, NSMaxRange(r) <= storage.length,
              tv.shouldChangeText(in: r, replacementString: nil) else { return }
        let first = (storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont) ?? fallback
        let makeOn = !isOn(first, trait)
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: r, options: []) { value, range, _ in
            storage.addAttribute(.font, value: set((value as? NSFont) ?? fallback, trait, on: makeOn), range: range)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    static func toggleUnderline(in tv: NSTextView) {
        let r = tv.selectedRange()
        if r.length == 0 {
            let on = ((tv.typingAttributes[.underlineStyle] as? Int) ?? 0) != 0
            tv.typingAttributes[.underlineStyle] = on ? 0 : NSUnderlineStyle.single.rawValue
            return
        }
        guard let storage = tv.textStorage, NSMaxRange(r) <= storage.length,
              tv.shouldChangeText(in: r, replacementString: nil) else { return }
        let on = ((storage.attribute(.underlineStyle, at: r.location, effectiveRange: nil) as? Int) ?? 0) != 0
        if on { storage.removeAttribute(.underlineStyle, range: r) } else { storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r) }
        tv.didChangeText()
    }
}

// MARK: - Reading band (leesband)

/// Dims the text above and below a clear band around the cue line, with a soft edge.
/// Static drawing: redrawn only when settings or size change, never per frame.
final class ReadingBandOverlay: NSView {
    struct Look: Equatable {
        var on = true
        var strength: CGFloat = 0.45
        var cueY: CGFloat = 0        // in this view, flipped
        var halfBand: CGFloat = 60   // half the clear band
        var soft: CGFloat = 40       // fade length
        var color = NSColor.black
    }
    var look = Look() { didSet { if look != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let l = look
        guard l.on, l.strength > 0.001, bounds.height > 0 else { return }
        let base = l.color.usingColorSpace(.sRGB) ?? NSColor.black
        let solid = base.withAlphaComponent(l.strength)
        let clear = base.withAlphaComponent(0)
        let top = l.cueY - l.halfBand        // clear band starts here
        let bottom = l.cueY + l.halfBand
        // Above: solid from the top down to the fade, then fade to clear at the band edge.
        let aboveSolidEnd = max(top - l.soft, 0)
        if aboveSolidEnd > 0 {
            solid.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: aboveSolidEnd).fill(using: .sourceOver)
        }
        if top > 0, let g = NSGradient(starting: solid, ending: clear) {
            g.draw(in: NSRect(x: 0, y: aboveSolidEnd, width: bounds.width, height: max(top - aboveSolidEnd, 0)), angle: 90)
        }
        // Below: fade from clear at the band edge to solid, then solid to the bottom.
        let belowSolidStart = min(bottom + l.soft, bounds.height)
        if bottom < bounds.height, let g = NSGradient(starting: clear, ending: solid) {
            g.draw(in: NSRect(x: 0, y: bottom, width: bounds.width, height: max(belowSolidStart - bottom, 0)), angle: 90)
        }
        if belowSolidStart < bounds.height {
            solid.setFill()
            NSRect(x: 0, y: belowSolidStart, width: bounds.width, height: bounds.height - belowSolidStart).fill(using: .sourceOver)
        }
    }
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

@MainActor final class PrompterView: NSView, PrompterRenderer, NSTextViewDelegate {
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
    private let textView: PrompterTextView
    /// True while the text is edited in place (main view only).
    private(set) var isEditingText = false
    private var editingScriptID: UUID?
    private var saveWork: DispatchWorkItem?
    /// The text view, only while editing in place.
    var editTextView: NSTextView? { isEditingText ? textView : nil }

    // Live width preview: all prompter views scale their text layer, no relayout.
    private static let all = NSHashTable<PrompterView>.weakObjects()
    private static var previewMarginValue: Double?
    static func previewMargin(_ margin: Double?) {
        previewMarginValue = margin.map { min(max($0, 0), 0.4) }
        for v in all.allObjects { v.applyMirror(Prompter.shared.settings) }
    }
    private let cueOverlay = CueOverlay()
    private let band = ReadingBandOverlay()
    /// Per display line: where it starts in the script body, where in the laid-out text, and how many
    /// leading characters ("#", spaces) the display dropped. For fraction(forCharacterOffset:).
    private var lineMap: [(body: Int, storage: Int, dropped: Int)] = []
    private var bodyLineStarts: [Int] = []

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
        textView = PrompterTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 100), textContainer: container)
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
        host.addSubview(band)       // above the text, below the cue line: the cue line stays fully bright
        host.addSubview(cueOverlay)
        host.wantsLayer = true
        addSubview(host)

        let p = Prompter.shared
        p.$settings.sink { [weak self] _ in self?.refresher.ask() }.store(in: &bag)
        p.$scripts.sink { [weak self] _ in self?.refresher.ask() }.store(in: &bag)
        p.$currentScriptID.sink { [weak self] _ in self?.refresher.ask() }.store(in: &bag)
        p.$isPrompterActive.sink { [weak self] _ in self?.refresher.ask() }.store(in: &bag)
        PrompterView.all.add(self)
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
        band.frame = host.bounds
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
        updateBand(s)
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
        if isEditingText {
            // Never rebuild under the cursor. Another script selected: stop editing without saving.
            if p.currentScriptID != editingScriptID { endEditing(save: false) } else {
                let width = max(bounds.width, 1)
                if abs(textView.frame.width - width) > 0.5 { configureContainer(s, width: width) }
                measure(s, cueStarts: editCueStarts())
                return
            }
        }
        let script = p.currentScript
        let width = max(bounds.width, 1)
        let textColor = p.effectiveTextColor()
        let cueBase = s.cueColor.withAlphaComponent(1)
        let key = "\(s.fontName)|\(s.fontSize)|\(s.lineSpacing)|\(s.marginFraction)|\(Theme.hex(textColor))|\(Theme.hex(cueBase))|\(Int(width))|\(p.textVersion)|\(script?.id.uuidString ?? "")"
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
        var map: [(body: Int, storage: Int, dropped: Int)] = []
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
            map.append((lineRange.location, out.length, contentStart - lineRange.location))
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
        lineMap = map
        // Line starts in the plain body (UTF-16), which is what Voice passes in. Mapped by line index.
        let bodyNS = (script?.body ?? "") as NSString
        var starts: [Int] = []
        var loc = 0
        while loc < bodyNS.length {
            starts.append(loc)
            let r = bodyNS.lineRange(for: NSRange(location: loc, length: 0))
            guard NSMaxRange(r) > loc else { break }
            loc = NSMaxRange(r)
        }
        bodyLineStarts = starts

        configureContainer(s, width: width)
        textView.textStorage?.setAttributedString(out)
        measure(s, cueStarts: cueStarts)
    }

    private func configureContainer(_ s: PrompterSettings, width: CGFloat) {
        let margin = (width * CGFloat(s.marginFraction)).rounded()
        textView.textContainerInset = NSSize(width: margin, height: 0)
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        textView.textContainer?.containerSize = NSSize(width: max(width - 2 * margin, 10), height: CGFloat.greatestFiniteMagnitude)
    }

    /// Geometry from the current layout: scroll distance, first line, cue fractions. Keeps the text as is.
    private func measure(_ s: PrompterSettings, cueStarts: [Int]) {
        let width = max(bounds.width, 1)
        let length = textView.textStorage?.length ?? 0
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
                for start in cueStarts where start < length {
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
        let mirror = (isExternal ? s.mirrorExternal : s.mirrorMain) && !isEditingText
        let flip = s.flipVertical && !isEditingText
        let w = layer.bounds.width
        let h = layer.bounds.height
        let ax = layer.anchorPoint.x * w
        let ay = layer.anchorPoint.y * h
        // Mirror around the centre of the layer, whatever its anchor point is.
        var t = CGAffineTransform.identity
        if mirror { t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w - 2 * ax, ty: 0) }
        if flip { t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h - 2 * ay)) }
        if let m = PrompterView.previewMarginValue, !isEditingText {
            // Horizontal scale around the centre: old column width to the previewed one.
            let oldW = max(1 - 2 * s.marginFraction, 0.05)
            let k = CGFloat(max(1 - 2 * m, 0.05) / oldW)
            if k.isFinite, abs(k - 1) > 0.001 {
                t = t.concatenating(CGAffineTransform(a: k, b: 0, c: 0, d: 1, tx: (1 - k) * (w / 2 - ax), ty: 0))
            }
        }
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

    // MARK: Reading band

    private func updateBand(_ s: PrompterSettings) {
        let h = max(bounds.height, 0)
        let lineHeight = CGFloat(s.fontSize * s.lineSpacing)
        var l = ReadingBandOverlay.Look()
        l.on = s.readingBand && !isEditingText
        l.strength = CGFloat(s.readingBandStrength)
        l.cueY = CGFloat(s.cuePosition) * h
        l.halfBand = lineHeight * CGFloat(s.readingBandHeight) / 2
        l.soft = lineHeight * 0.9
        l.color = Prompter.shared.effectiveBackgroundColor()
        band.look = l
    }

    // MARK: Voice: character offset to position

    /// Fraction that puts the line holding `offset` (into the script body) on the cue line.
    func fraction(forCharacterOffset offset: Int) -> Double? {
        if dirty { flush() }
        guard offset >= 0, let manager = textView.layoutManager, scrollDistance > 0 else { return nil }
        let length = textView.textStorage?.length ?? 0
        guard length > 0 else { return nil }
        var storageOffset = offset
        if !isEditingText, !lineMap.isEmpty, !bodyLineStarts.isEmpty {
            // Line index in the body (binary search), then the same line in the layout, minus the dropped "# ".
            var lo = 0, hi = bodyLineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if bodyLineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            let index = min(lo, lineMap.count - 1)
            let line = lineMap[index]
            let lineEnd = index + 1 < lineMap.count ? lineMap[index + 1].storage : length
            let within = max(0, offset - bodyLineStarts[lo] - line.dropped)
            storageOffset = min(line.storage + within, max(lineEnd - 1, line.storage))
        }
        storageOffset = min(max(storageOffset, 0), length - 1)
        let glyph = manager.glyphIndexForCharacter(at: storageOffset)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let r = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let f = Double((r.midY - firstMid) / scrollDistance)
        return f.isFinite ? min(max(f, 0), 1) : nil
    }

    // MARK: Edit in place

    /// Turns editing on: the text keeps its place, size and font; "#" marks become visible.
    func beginEditing() {
        guard !isExternal, !isEditingText, Prompter.shared.currentScript != nil else { return }
        Prompter.shared.stop()
        flush()
        let s = Prompter.shared.settings
        let content = editContent(s)
        isEditingText = true
        editingScriptID = Prompter.shared.currentScriptID
        configureContainer(s, width: max(bounds.width, 1))
        textView.textStorage?.setAttributedString(content)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.insertionPointColor = Prompter.shared.effectiveTextColor()
        textView.selectedTextAttributes = [.backgroundColor: NSColor(white: 1, alpha: 0.22)]
        textView.delegate = self
        textView.typingAttributes = typing(s)
        measure(s, cueStarts: editCueStarts())
        applyMirror(s)
        updateBand(s)
        render(position: Prompter.shared.position)
        window?.makeFirstResponder(textView)
        placeCaretOnCueLine()
        NotificationCenter.default.post(name: .ipEditingChanged, object: self)
    }

    /// Turns editing off and saves (unless the script changed underneath).
    func endEditing(save: Bool = true) {
        guard isEditingText else { return }
        if save { saveNow() }
        saveWork?.cancel()
        saveWork = nil
        isEditingText = false
        editingScriptID = nil
        textView.delegate = nil
        textView.isEditable = false
        textView.isSelectable = false
        textView.undoManager?.removeAllActions(withTarget: textView.textStorage as Any)
        if window?.firstResponder === textView { window?.makeFirstResponder(self) }
        layoutKey = ""
        flush()
        NotificationCenter.default.post(name: .ipEditingChanged, object: self)
    }

    func toggleBoldEdit() { if isEditingText { TextStyling.toggle(.bold, in: textView, fallback: font(Prompter.shared.settings, bold: false)) } }
    func toggleItalicEdit() { if isEditingText { TextStyling.toggle(.italic, in: textView, fallback: font(Prompter.shared.settings, bold: false)) } }
    func toggleUnderlineEdit() { if isEditingText { TextStyling.toggleUnderline(in: textView) } }

    private func typing(_ s: PrompterSettings) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = CGFloat(s.lineSpacing)
        para.paragraphSpacing = CGFloat(s.fontSize) * 0.35
        return [.font: font(s, bold: false), .foregroundColor: Prompter.shared.effectiveTextColor(),
                .paragraphStyle: para, .ipDisplayColor: true]
    }

    /// Source text with "#" kept, fonts from settings, display colours marked so they are not saved.
    private func editContent(_ s: PrompterSettings) -> NSAttributedString {
        let p = Prompter.shared
        let source = p.currentAttributed
        let ns = source.string as NSString
        let regular = font(s, bold: false)
        let boldFont = font(s, bold: true)
        let textColor = p.effectiveTextColor()
        let cueColor = s.cueColor.withAlphaComponent(1)
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = CGFloat(s.lineSpacing)
        para.paragraphSpacing = CGFloat(s.fontSize) * 0.35
        let out = NSMutableAttributedString(string: source.string)
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            guard line.length > 0 else { break }
            let isCue = ns.substring(with: line).trimmingCharacters(in: .whitespaces).hasPrefix("#")
            source.enumerateAttributes(in: line, options: []) { attrs, range, _ in
                var bold = isCue, italic = false
                if let f = attrs[.font] as? NSFont {
                    bold = bold || TextStyling.isOn(f, .bold)
                    italic = TextStyling.isOn(f, .italic)
                }
                var a: [NSAttributedString.Key: Any] = [
                    .font: styledFont(s, bold: bold, italic: italic, regular: regular, bold: boldFont),
                    .paragraphStyle: para,
                ]
                if isCue {
                    a[.foregroundColor] = cueColor
                    a[.ipDisplayColor] = true
                } else if let c = attrs[.foregroundColor] as? NSColor {
                    a[.foregroundColor] = c
                } else {
                    a[.foregroundColor] = textColor
                    a[.ipDisplayColor] = true
                }
                if let u = attrs[.underlineStyle] as? Int, u != 0 { a[.underlineStyle] = u }
                if let st = attrs[.strikethroughStyle] as? Int, st != 0 { a[.strikethroughStyle] = st }
                out.setAttributes(a, range: range)
            }
            location = NSMaxRange(line)
        }
        return out
    }

    private func editCueStarts() -> [Int] {
        let ns = (textView.textStorage?.string ?? "") as NSString
        var starts: [Int] = []
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            guard line.length > 0 else { break }
            if ns.substring(with: line).trimmingCharacters(in: .whitespaces).hasPrefix("#") { starts.append(line.location) }
            location = NSMaxRange(line)
        }
        return starts
    }

    private func placeCaretOnCueLine() {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        let length = textView.textStorage?.length ?? 0
        guard length > 0 else { textView.setSelectedRange(NSRange(location: 0, length: 0)); return }
        let cueY = clip.bounds.origin.y + CGFloat(Prompter.shared.settings.cuePosition) * bounds.height
        // Container coordinates: start of the line that sits on the cue line.
        let point = NSPoint(x: 0, y: max(cueY - textView.textContainerInset.height, 0))
        let glyph = manager.glyphIndex(for: point, in: container)
        var lineRange = NSRange(location: 0, length: 0)
        _ = manager.lineFragmentRect(forGlyphAt: min(glyph, max(manager.numberOfGlyphs - 1, 0)), effectiveRange: &lineRange)
        let char = min(manager.characterIndexForGlyph(at: lineRange.location), length)
        textView.setSelectedRange(NSRange(location: char, length: 0))
    }

    func textDidChange(_ notification: Notification) {
        guard isEditingText else { return }
        let s = Prompter.shared.settings
        // Recolour cue lines live, then re-measure; position fraction stays.
        if let storage = textView.textStorage {
            let ns = storage.string as NSString
            let cueColor = s.cueColor.withAlphaComponent(1)
            storage.beginEditing()
            var location = 0
            while location < ns.length {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                guard line.length > 0 else { break }
                let isCue = ns.substring(with: line).trimmingCharacters(in: .whitespaces).hasPrefix("#")
                storage.enumerateAttribute(.ipDisplayColor, in: line, options: []) { marked, range, _ in
                    guard marked != nil else { return }
                    storage.addAttribute(.foregroundColor, value: isCue ? cueColor : Prompter.shared.effectiveTextColor(), range: range)
                }
                location = NSMaxRange(line)
            }
            storage.endEditing()
        }
        measure(s, cueStarts: editCueStarts())
        render(position: Prompter.shared.position)
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard isEditingText, Prompter.shared.currentScriptID == editingScriptID,
              let storage = textView.textStorage else { return }
        let copy = NSMutableAttributedString(attributedString: storage)
        let full = NSRange(location: 0, length: copy.length)
        copy.enumerateAttribute(.ipDisplayColor, in: full, options: []) { marked, range, _ in
            if marked != nil { copy.removeAttribute(.foregroundColor, range: range) }
        }
        copy.removeAttribute(.ipDisplayColor, range: full)
        Prompter.shared.updateCurrentRich(copy)
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
        guard !isEditingText else { return }
        let dy = -event.deltaY
        if dy != 0 { Prompter.shared.nudge(points: Double(dy)) }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged && !isEditingText { Prompter.shared.toggleScrolling() }
        dragged = false
    }
}
