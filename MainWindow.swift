// MainWindow.swift, Infinity Prompt
// Main window: script cards on the left, editor on the right, prompter mode over it all.
// Every background is drawn in draw(_:), so a cacheDisplay photo shows what is on screen.

import AppKit
import Combine

// MARK: - Small building blocks

private func makeLabel(_ text: String = "", size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = Theme.text) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = NSFont.systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    l.maximumNumberOfLines = 1
    l.cell?.truncatesLastVisibleLine = true
    return l
}

private func fileURLs(from info: NSDraggingInfo) -> [URL] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
}

func scriptStats(_ body: String) -> String {
    let words = body.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        .filter { $0 != "#" }.count
    guard words > 0 else { return "Leeg" }
    let minutes = max(1, Int((Double(words) / 140).rounded(.up)))
    return "\(minutes) min · \(words) woorden"
}

/// White pill with black bold text. Primary action.
final class PillButton: NSView {
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var onClick: (() -> Void)?
    private var pressed = false

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }

    private var attributed: NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.black,
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributed.size().width) + 48, height: 42)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        let a = attributed
        let s = a.size()
        a.draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        NSAnimationContext.runAnimationGroup { c in c.duration = Theme.fast; animator().alphaValue = 0.7 }
    }

    override func mouseUp(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { c in c.duration = Theme.fast; animator().alphaValue = 1 }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if pressed && inside { onClick?() }
        pressed = false
    }
}

/// Borderless icon button with an SF Symbol.
@MainActor func iconButton(_ symbol: String, _ tip: String, size: CGFloat = 17, target: AnyObject?, action: Selector) -> NSButton {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
        ?? NSImage(size: NSSize(width: size, height: size))
    let b = NSButton(image: image, target: target, action: action)
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.contentTintColor = Theme.text
    b.toolTip = tip
    b.setButtonType(.momentaryChange)
    b.translatesAutoresizingMaskIntoConstraints = false
    b.widthAnchor.constraint(equalToConstant: size + 20).isActive = true
    b.heightAnchor.constraint(equalToConstant: size + 20).isActive = true
    return b
}

@MainActor func setSymbol(_ b: NSButton, _ symbol: String, size: CGFloat = 17) {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
    if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: b.toolTip)?.withSymbolConfiguration(config) {
        b.image = image
    }
}

// MARK: - Script card

final class ScriptCard: NSView {
    var number = 1 { didSet { if number != oldValue { needsDisplay = true } } }
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var stats = "" { didSet { if stats != oldValue { needsDisplay = true } } }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var onSelect: (() -> Void)?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        (isSelected ? Theme.cardSelected : Theme.card).setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let num = NSAttributedString(string: String(format: "%02d", min(max(number, 0), 99)), attributes: [
            .font: NSFont.systemFont(ofSize: 76, weight: .heavy),
            .foregroundColor: NSColor(white: 1, alpha: isSelected ? 0.12 : 0.08),
            .kern: -3,
        ])
        let ns = num.size()
        num.draw(at: NSPoint(x: bounds.width - ns.width - 10, y: bounds.height - ns.height + 16))
        NSGraphicsContext.restoreGraphicsState()

        let titleWidth = max(bounds.width - 36 - 70, 40)
        let t = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .bold),
            .foregroundColor: Theme.text,
            .kern: -0.2,
        ])
        t.draw(with: NSRect(x: 18, y: 22, width: titleWidth, height: 24),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        Theme.label(stats, size: 10.5).draw(with: NSRect(x: 18, y: 54, width: titleWidth + 40, height: 16),
                                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func mouseDown(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { c in c.duration = Theme.fast; animator().alphaValue = 0.8 }
        if event.clickCount == 2 { onRename?() } else { onSelect?() }
    }

    override func mouseUp(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { c in c.duration = Theme.fast; animator().alphaValue = 1 }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onSelect?()
        let m = NSMenu()
        m.addItem(withTitle: "Hernoemen…", action: #selector(renameClicked), keyEquivalent: "").target = self
        m.addItem(withTitle: "Verwijderen…", action: #selector(deleteClicked), keyEquivalent: "").target = self
        return m
    }

    @objc private func renameClicked() { onRename?() }
    @objc private func deleteClicked() { onDelete?() }
}

// MARK: - Editor text view

final class EditorTextView: NSTextView {
    var onFiles: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        if !urls.isEmpty { onFiles?(urls); return true }
        return super.performDragOperation(sender)
    }
}

/// A rounded card behind the editor.
final class CardBackground: NSView {
    var color = Theme.card
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
    }
}

// MARK: - Root view

final class RootView: NSView {
    var onFiles: (([URL]) -> Void)?
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { nil }

    /// True in floating prompter mode: the prompter draws its own (see-through) background.
    var transparent = false { didSet { if transparent != oldValue { needsDisplay = true } } }
    override var isOpaque: Bool { !transparent }
    override func draw(_ dirtyRect: NSRect) {
        if transparent {
            NSColor.clear.setFill()
            dirtyRect.fill(using: .copy)
            return
        }
        Theme.black.setFill()
        dirtyRect.fill()
    }
    override func layout() {
        super.layout()
        onLayout?()
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }
}

// MARK: - Main window controller

@MainActor final class MainWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let root = RootView(frame: NSRect(x: 0, y: 0, width: 1200, height: 780))
    private let listHeader = makeLabel(size: 11)
    private var plusButton: NSButton?
    private var importButton: NSButton?
    private let listScroll = NSScrollView()
    private let listDocument = FlippedView()
    private var cards: [UUID: ScriptCard] = [:]

    private let titleLabel = makeLabel(size: 34, weight: .heavy)
    private let statsLabel = makeLabel(size: 11)
    private let startPill = PillButton(title: "Start prompter")
    private let editorCard = CardBackground()
    private let editorScroll = NSScrollView()
    private let editor = EditorTextView(usingTextLayoutManager: false)
    private let emptyLabel = makeLabel("Maak een script met +", size: 20, weight: .semibold, color: Theme.grey)
    private let formatBar = NSStackView()
    private var colorButton: NSButton?
    private let problemCard = CardBackground()
    private let problemLabel = NSTextField(wrappingLabelWithString: "")
    private var loadedScriptID: UUID?
    static let editorTextColor = NSColor(srgbRed: 0xE1 / 255.0, green: 0xE0 / 255.0, blue: 0xE3 / 255.0, alpha: 1)
    static let editorFont = NSFont.systemFont(ofSize: 22, weight: .regular)
    /// Text colours to choose in the editor. Mint stays reserved for cue points.
    static let textColors: [(String, String?)] = [
        ("Standaard", nil), ("Geel", "#FFD60A"), ("Oranje", "#FF9F0A"), ("Rood", "#FF453A"),
        ("Blauw", "#64D2FF"), ("Roze", "#FF6FB5"),
    ]

    private(set) var prompterScreen: PrompterScreen?
    private var bag = Set<AnyCancellable>()
    private lazy var listRefresher = Coalescer { [weak self] in self?.refreshList() }
    private lazy var editorRefresher = Coalescer { [weak self] in self?.refreshEditor() }
    private lazy var modeRefresher = Coalescer { [weak self] in self?.applyWindowMode() }

    private let sidebarWidth: CGFloat = 320

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Infinity Prompt"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = root
        window.center()
        build()

        let p = Prompter.shared
        p.$scripts.sink { [weak self] _ in self?.listRefresher.ask(); self?.editorRefresher.ask() }.store(in: &bag)
        p.$currentScriptID.sink { [weak self] _ in self?.listRefresher.ask(); self?.editorRefresher.ask() }.store(in: &bag)
        p.$settings.sink { [weak self] _ in self?.modeRefresher.ask() }.store(in: &bag)
        p.$isPrompterActive.sink { [weak self] _ in self?.modeRefresher.ask() }.store(in: &bag)
        p.$loadProblem.sink { [weak self] _ in self?.listRefresher.ask() }.store(in: &bag)
        refreshList()
        refreshEditor()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Build

    private func build() {
        root.onFiles = { [weak self] urls in self?.importFiles(urls) }
        root.onLayout = { [weak self] in self?.layoutAll() }

        listHeader.attributedStringValue = Theme.label("Scripts", size: 11)
        root.addSubview(listHeader)
        let plus = iconButton("plus", "Nieuw script", size: 15, target: self, action: #selector(newScriptAction))
        let imp = iconButton("square.and.arrow.down", "Importeren", size: 15, target: self, action: #selector(importAction))
        for b in [plus, imp] {
            b.translatesAutoresizingMaskIntoConstraints = true
            root.addSubview(b)
        }
        plusButton = plus
        importButton = imp

        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.scrollerStyle = .overlay
        listScroll.autohidesScrollers = true
        listScroll.documentView = listDocument
        listScroll.contentView.drawsBackground = false
        root.addSubview(listScroll)

        root.addSubview(titleLabel)
        root.addSubview(statsLabel)
        startPill.onClick = { [weak self] in self?.enterPrompter() }
        root.addSubview(startPill)

        root.addSubview(editorCard)
        editorScroll.drawsBackground = false
        editorScroll.hasVerticalScroller = true
        editorScroll.scrollerStyle = .overlay
        editorScroll.autohidesScrollers = true
        editorScroll.contentView.drawsBackground = false
        editor.delegate = self
        editor.isRichText = true
        editor.usesFontPanel = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = NSFont.systemFont(ofSize: 22, weight: .regular)
        editor.textColor = NSColor(srgbRed: 0xE1 / 255.0, green: 0xE0 / 255.0, blue: 0xE3 / 255.0, alpha: 1)
        editor.insertionPointColor = .white
        editor.selectedTextAttributes = [.backgroundColor: NSColor(white: 1, alpha: 0.18)]
        editor.textContainerInset = NSSize(width: 26, height: 24)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.onFiles = { [weak self] urls in self?.importFiles(urls) }
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.35
        para.paragraphSpacing = 6
        editor.defaultParagraphStyle = para
        editor.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 22, weight: .regular),
            .foregroundColor: editor.textColor ?? NSColor.white,
            .paragraphStyle: para,
        ]
        editorScroll.documentView = editor
        root.addSubview(editorScroll)
        root.addSubview(emptyLabel)

        // Format bar: bold, italic, underline, colour. Small, right of the stats line.
        let bold = iconButton("bold", "Vet (⌘B)", size: 13, target: self, action: #selector(toggleBold))
        let italic = iconButton("italic", "Cursief (⌘I)", size: 13, target: self, action: #selector(toggleItalic))
        let under = iconButton("underline", "Onderstreept (⌘U)", size: 13, target: self, action: #selector(toggleUnderline))
        let color = iconButton("paintpalette", "Tekstkleur", size: 13, target: self, action: #selector(colorMenu(_:)))
        colorButton = color
        for b in [bold, italic, under, color] { b.contentTintColor = Theme.grey }
        formatBar.setViews([bold, italic, under, color], in: .trailing)
        formatBar.spacing = 2
        root.addSubview(formatBar)

        problemLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        problemLabel.textColor = Theme.text
        problemCard.addSubview(problemLabel)
        problemCard.isHidden = true
        root.addSubview(problemCard)
    }

    private func layoutAll() {
        let b = root.bounds
        let side = sidebarWidth
        listHeader.frame = NSRect(x: 22, y: 50, width: 120, height: 16)
        importButton?.frame = NSRect(x: side - 22 - 35, y: 40, width: 35, height: 35)
        plusButton?.frame = NSRect(x: side - 22 - 35 - 38, y: 40, width: 35, height: 35)
        var listBottom = b.height
        if !problemCard.isHidden {
            let w = side - 32
            let h = max(problemLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w - 28, height: 400)).height ?? 40, 20) + 24
            problemCard.frame = NSRect(x: 16, y: b.height - h - 16, width: w, height: h)
            problemLabel.frame = NSRect(x: 14, y: 12, width: w - 28, height: h - 24)
            listBottom = problemCard.frame.minY - 8
        }
        listScroll.frame = NSRect(x: 0, y: 84, width: side, height: max(listBottom - 84, 0))
        layoutCards()

        let x = side + 8
        let w = max(b.width - x - 28, 100)
        let pill = startPill.intrinsicContentSize
        startPill.frame = NSRect(x: b.width - 28 - pill.width, y: 40, width: pill.width, height: pill.height)
        titleLabel.frame = NSRect(x: x, y: 34, width: max(w - pill.width - 24, 60), height: 44)
        statsLabel.frame = NSRect(x: x + 2, y: 84, width: w - 160, height: 16)
        formatBar.frame = NSRect(x: x + w - 160, y: 76, width: 160, height: 32)
        editorCard.frame = NSRect(x: x, y: 116, width: w, height: max(b.height - 116 - 24, 50))
        editorScroll.frame = editorCard.frame.insetBy(dx: 2, dy: 2)
        let es = emptyLabel.intrinsicContentSize
        emptyLabel.frame = NSRect(x: editorCard.frame.midX - es.width / 2, y: editorCard.frame.midY - es.height / 2,
                                  width: es.width, height: es.height)
        prompterScreen?.frame = b
    }

    private func layoutCards() {
        let scripts = Prompter.shared.scripts
        let width = sidebarWidth - 32
        var y: CGFloat = 6
        for s in scripts {
            if let card = cards[s.id] {
                card.frame = NSRect(x: 16, y: y, width: width, height: 92)
                y += 92 + 10
            }
        }
        listDocument.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: max(y + 16, listScroll.contentSize.height))
    }

    // MARK: Refresh

    private func refreshList() {
        let p = Prompter.shared
        let scripts = p.scripts
        let ids = Set(scripts.map { $0.id })
        for (id, card) in cards where !ids.contains(id) {
            card.removeFromSuperview()
            cards.removeValue(forKey: id)
        }
        for (i, s) in scripts.enumerated() {
            let card: ScriptCard
            if let c = cards[s.id] {
                card = c
            } else {
                card = ScriptCard(frame: .zero)
                let id = s.id
                card.onSelect = { [weak self] in self?.select(id) }
                card.onRename = { [weak self] in self?.askRename(id) }
                card.onDelete = { [weak self] in self?.askDelete(id) }
                listDocument.addSubview(card)
                cards[s.id] = card
            }
            card.number = i + 1
            card.title = s.title
            card.stats = scriptStats(s.body)
            card.isSelected = s.id == p.currentScriptID
        }
        let problem = p.loadProblem
        problemLabel.stringValue = problem ?? ""
        if problemCard.isHidden != (problem == nil) {
            problemCard.isHidden = problem == nil
            root.needsLayout = true
        }
        layoutCards()
    }

    private func refreshEditor() {
        let p = Prompter.shared
        let script = p.currentScript
        titleLabel.stringValue = script?.title ?? "Infinity Prompt"
        statsLabel.attributedStringValue = Theme.label(script.map { scriptStats($0.body) } ?? "Geen script", size: 11)
        emptyLabel.isHidden = script != nil
        editorScroll.isHidden = script == nil
        editor.isEditable = script != nil
        formatBar.isHidden = script == nil
        guard !p.isPrompterActive else { return }   // sync once on leaving the prompter
        let body = script?.body ?? ""
        if editor.string != body || loadedScriptID != script?.id {
            loadedScriptID = script?.id
            let selected = editor.selectedRange()
            editor.textStorage?.setAttributedString(editorDisplay(p.currentAttributed))
            let len = (body as NSString).length
            editor.setSelectedRange(NSRange(location: min(selected.location, len), length: 0))
            editor.undoManager?.removeAllActions()
            highlightCues()
        }
    }

    /// Editor view of the rich script: fixed editor font and size, keeping bold, italic, underline and colour.
    private func editorDisplay(_ src: NSAttributedString) -> NSAttributedString {
        let fm = NSFontManager.shared
        let out = NSMutableAttributedString(string: src.string)
        let para = editor.defaultParagraphStyle ?? NSParagraphStyle.default
        let full = NSRange(location: 0, length: out.length)
        guard full.length > 0 else { return out }
        src.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            var f = MainWindowController.editorFont
            if let sf = attrs[.font] as? NSFont {
                let t = fm.traits(of: sf)
                if t.contains(.boldFontMask) { f = fm.convert(f, toHaveTrait: .boldFontMask) }
                if t.contains(.italicFontMask) { f = fm.convert(f, toHaveTrait: .italicFontMask) }
            }
            var a: [NSAttributedString.Key: Any] = [
                .font: f,
                .foregroundColor: (attrs[.foregroundColor] as? NSColor) ?? MainWindowController.editorTextColor,
                .paragraphStyle: para,
            ]
            if let u = attrs[.underlineStyle] as? Int, u != 0 { a[.underlineStyle] = u }
            if let st = attrs[.strikethroughStyle] as? Int, st != 0 { a[.strikethroughStyle] = st }
            out.setAttributes(a, range: range)
        }
        return out
    }

    /// Saves the editor as rich text. The editor's default colour is not stored, so the global
    /// (or per-script) prompter colour still applies to normal text.
    private func saveEditor() {
        guard Prompter.shared.currentScript != nil, let storage = editor.textStorage else { return }
        let copy = NSMutableAttributedString(attributedString: storage)
        let full = NSRange(location: 0, length: copy.length)
        let base = Theme.hex(MainWindowController.editorTextColor)
        copy.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            if let c = value as? NSColor, Theme.hex(c) == base { copy.removeAttribute(.foregroundColor, range: range) }
        }
        Prompter.shared.updateCurrentRich(copy)
    }

    // MARK: Formatting

    private var formatAllowed: Bool {
        !Prompter.shared.isPrompterActive && Prompter.shared.currentScript != nil && editor.isEditable
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard formatAllowed else { return }
        let fm = NSFontManager.shared
        let r = editor.selectedRange()
        if r.length == 0 {
            var attrs = editor.typingAttributes
            let f = (attrs[.font] as? NSFont) ?? MainWindowController.editorFont
            let on = fm.traits(of: f).contains(trait)
            attrs[.font] = on ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait)
            editor.typingAttributes = attrs
            return
        }
        guard let storage = editor.textStorage, NSMaxRange(r) <= storage.length else { return }
        let first = (storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont) ?? MainWindowController.editorFont
        let makeOn = !fm.traits(of: first).contains(trait)
        guard editor.shouldChangeText(in: r, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: r, options: []) { value, range, _ in
            let f = (value as? NSFont) ?? MainWindowController.editorFont
            storage.addAttribute(.font, value: makeOn ? fm.convert(f, toHaveTrait: trait) : fm.convert(f, toNotHaveTrait: trait), range: range)
        }
        storage.endEditing()
        editor.didChangeText()
    }

    @objc func toggleBold() { toggleTrait(.boldFontMask) }
    @objc func toggleItalic() { toggleTrait(.italicFontMask) }

    @objc func toggleUnderline() {
        guard formatAllowed else { return }
        let r = editor.selectedRange()
        if r.length == 0 {
            var attrs = editor.typingAttributes
            let on = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
            attrs[.underlineStyle] = on ? 0 : NSUnderlineStyle.single.rawValue
            editor.typingAttributes = attrs
            return
        }
        guard let storage = editor.textStorage, NSMaxRange(r) <= storage.length else { return }
        let on = ((storage.attribute(.underlineStyle, at: r.location, effectiveRange: nil) as? Int) ?? 0) != 0
        guard editor.shouldChangeText(in: r, replacementString: nil) else { return }
        if on { storage.removeAttribute(.underlineStyle, range: r) } else { storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r) }
        editor.didChangeText()
    }

    @objc private func colorMenu(_ sender: NSButton) {
        guard formatAllowed else { return }
        let m = NSMenu()
        for (i, entry) in MainWindowController.textColors.enumerated() {
            let item = NSMenuItem(title: entry.0, action: #selector(colorChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.image = swatch(entry.1.flatMap(colorFromHexString) ?? MainWindowController.editorTextColor)
            m.addItem(item)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func colorChosen(_ item: NSMenuItem) {
        guard MainWindowController.textColors.indices.contains(item.tag) else { return }
        let color = MainWindowController.textColors[item.tag].1.flatMap(colorFromHexString) ?? MainWindowController.editorTextColor
        let r = editor.selectedRange()
        if r.length == 0 {
            editor.typingAttributes[.foregroundColor] = color
            return
        }
        guard let storage = editor.textStorage, NSMaxRange(r) <= storage.length,
              editor.shouldChangeText(in: r, replacementString: nil) else { return }
        storage.addAttribute(.foregroundColor, value: color, range: r)
        editor.didChangeText()
    }

    private func swatch(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            c.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    // MARK: Window mode (floating prompter)

    func applyWindowMode() {
        guard let window = window else { return }
        let p = Prompter.shared
        let floating = p.isPrompterActive && p.settings.floatingWindow
        let wantLevel: NSWindow.Level = floating ? .floating : .normal
        if window.level != wantLevel { window.level = wantLevel }
        var behavior: NSWindow.CollectionBehavior = [.fullScreenPrimary]
        if floating { behavior = [.canJoinAllSpaces, .fullScreenAuxiliary] }
        if window.collectionBehavior != behavior { window.collectionBehavior = behavior }
        window.isOpaque = !floating
        window.backgroundColor = floating ? .clear : .black
        window.hasShadow = !floating || p.settings.windowOpacity > 0.95
        root.transparent = floating
        prompterScreen?.prompter.needsDisplay = true
    }

    private func highlightCues() {
        guard let manager = editor.layoutManager else { return }
        let text = editor.string as NSString
        let full = NSRange(location: 0, length: text.length)
        manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let content = text.substring(with: line).trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("#") {
                manager.addTemporaryAttribute(.foregroundColor, value: Theme.mint, forCharacterRange: line)
            }
            let next = NSMaxRange(line)
            guard next > location else { break }
            location = next
        }
    }

    func textDidChange(_ notification: Notification) {
        highlightCues()
        saveEditor()
    }

    // MARK: Script actions

    private func select(_ id: UUID) {
        guard Prompter.shared.currentScriptID != id else { return }
        Prompter.shared.select(id)
    }

    @objc func newScriptAction() {
        if Prompter.shared.isPrompterActive { leavePrompter() }
        Prompter.shared.newScript()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.window?.makeFirstResponder(self.editor)
            }
        }
    }

    @objc func importAction() {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Importeer"
        panel.message = "Kies een tekst, Word-bestand of pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                self?.importFiles(panel.urls)
            }
        }
    }

    func importFiles(_ urls: [URL]) {
        var failures: [String] = []
        for url in urls {
            do { try Prompter.shared.importFile(url) } catch { failures.append(error.localizedDescription) }
        }
        if Prompter.shared.isPrompterActive && failures.isEmpty == false { return }
        if !failures.isEmpty, let window = window {
            let alert = NSAlert()
            alert.messageText = failures.count == 1 ? "Import lukte niet" : "Niet alles is geïmporteerd"
            alert.informativeText = failures.joined(separator: "\n")
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        }
    }

    private func askRename(_ id: UUID) {
        guard let window = window, let script = Prompter.shared.scripts.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Script hernoemen"
        let field = NSTextField(string: script.title)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Bewaar")
        alert.addButton(withTitle: "Annuleer")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { Prompter.shared.rename(id, to: field.stringValue) }
            }
        }
    }

    private func askDelete(_ id: UUID) {
        guard let window = window, let script = Prompter.shared.scripts.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "\(script.title) verwijderen?"
        alert.informativeText = "Dit kun je niet terugdraaien."
        let del = alert.addButton(withTitle: "Verwijder")
        del.hasDestructiveAction = true
        alert.addButton(withTitle: "Annuleer")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { Prompter.shared.delete(id) }
            }
        }
    }

    // MARK: Prompter mode

    func enterPrompter() {
        let p = Prompter.shared
        guard !p.isPrompterActive, p.currentScript != nil else { NSSound.beep(); return }
        saveEditor()
        let screen: PrompterScreen
        if let s = prompterScreen {
            screen = s
        } else {
            screen = PrompterScreen(frame: root.bounds)
            screen.onClose = { [weak self] in self?.leavePrompter() }
            prompterScreen = screen
        }
        screen.frame = root.bounds
        if screen.superview == nil { root.addSubview(screen) }
        screen.alphaValue = 0
        screen.isHidden = false
        p.isPrompterActive = true
        screen.activate()
        applyWindowMode()
        setWindowButtonsHidden(true)
        window?.makeFirstResponder(screen.prompter)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = Theme.soft
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            screen.animator().alphaValue = 1
        }
    }

    func leavePrompter() {
        let p = Prompter.shared
        guard p.isPrompterActive, let screen = prompterScreen else { return }
        p.stop()
        p.isPrompterActive = false
        screen.deactivate()
        applyWindowMode()
        setWindowButtonsHidden(false)
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = Theme.soft
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            screen.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if !Prompter.shared.isPrompterActive { screen.isHidden = true }
            }
        })
        refreshEditor()
        window?.makeFirstResponder(editor)
    }

    func togglePrompter() {
        if Prompter.shared.isPrompterActive { leavePrompter() } else { enterPrompter() }
    }

    func toggleSecondScreen() {
        prompterScreen?.toggleSecondScreen() ?? PrompterScreen.toggleSecondScreenStatic(toast: nil)
    }

    private func setWindowButtonsHidden(_ hidden: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = hidden
        }
    }

    // MARK: Photo

    /// PNG of the whole window content via cacheDisplay (no screen recording).
    func photo(to path: String) -> Bool {
        prompterScreen?.prompter.flushNow()
        return photoOfWindow(window, to: path)
    }

    /// PNG of the content view's layer tree via layer.render(in:), so layer transforms (mirror) show.
    func layerPhoto(to path: String) -> Bool {
        guard let view = window?.contentView, let layer = view.layer else { return false }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = window?.backingScaleFactor ?? 2
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        // Bitmap contexts are bottom-up; flip so the PNG reads the right way up.
        ctx.translateBy(x: 0, y: view.bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        guard let image = ctx.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path)); return true } catch { return false }
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            if Prompter.shared.isPrompterActive { leavePrompter(); return false }
            NSApp.terminate(nil)
            return false
        }
    }
}

// MARK: - Prompter screen (prompter mode)

final class ProgressLine: NSView {
    var progress: Double = 0 { didSet { if abs(progress - oldValue) > 0.0004 { needsDisplay = true } } }
    var cues: [Double] = [] { didSet { if cues != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        guard w > 4 else { return }
        let gap: CGFloat = 4
        var stops = [0.0] + cues.filter { $0 > 0.01 && $0 < 0.99 } + [1.0]
        stops = Array(Set(stops)).sorted()
        let p = CGFloat(min(max(progress, 0), 1))
        for i in 0..<(stops.count - 1) {
            let a = CGFloat(stops[i]) * w + (i == 0 ? 0 : gap / 2)
            let b = CGFloat(stops[i + 1]) * w - (i == stops.count - 2 ? 0 : gap / 2)
            guard b > a else { continue }
            let seg = NSRect(x: a, y: 0, width: b - a, height: bounds.height)
            NSColor(white: 1, alpha: 0.18).setFill()
            NSBezierPath(roundedRect: seg, xRadius: 1, yRadius: 1).fill()
            let fillEnd = min(max(p * w, a), b)
            if fillEnd > a {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: a, y: 0, width: fillEnd - a, height: bounds.height), xRadius: 1, yRadius: 1).fill()
            }
        }
    }
}

final class BarBackground: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.card.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
    }
}

final class CountdownView: NSView {
    var value: Int? { didSet { if value != oldValue { needsDisplay = true; pulse() } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let v = value else { return }
        NSColor(white: 0, alpha: 0.6).setFill()
        bounds.fill()
        let size = min(bounds.height * 0.42, 320)
        let s = NSAttributedString(string: "\(v)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .heavy),
            .foregroundColor: NSColor.white,
        ])
        let sz = s.size()
        s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
    }

    private func pulse() {
        guard value != nil else { alphaValue = 1; return }
        alphaValue = 0.25
        NSAnimationContext.runAnimationGroup { c in
            c.duration = Theme.soft
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }
}

@MainActor final class PrompterScreen: NSView {
    let prompter = PrompterView(isExternal: false)
    var onClose: (() -> Void)?

    private let countdown = CountdownView()
    private let bar = BarBackground()
    private let progress = ProgressLine()
    private let stack = NSStackView()
    private let timeLabel = makeLabel(size: 10)
    private let timeValue = makeLabel("0:00", size: 17, weight: .semibold)
    private let speedLabel = makeLabel(size: 10)
    private let timeClick = ClickView()
    private let leftHandle = WidthHandle()
    private let rightHandle = WidthHandle()
    private let speedValue = makeLabel("20", size: 30, weight: .heavy)
    private let toast = makeLabel(size: 13, weight: .semibold)
    private var playButton: NSButton?
    private var mirrorButton: NSButton?
    private var screenButton: NSButton?
    private var phoneButton: NSButton?
    private var gearButton: NSButton?
    private var bag = Set<AnyCancellable>()
    private var clockTimer: Timer?
    private var hideWork: DispatchWorkItem?
    private var barVisible = true
    private var phonePopover: NSPopover?
    private lazy var stateRefresher = Coalescer { [weak self] in self?.refreshState() }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(prompter)
        addSubview(countdown)
        addSubview(leftHandle)
        addSubview(rightHandle)
        for h in [leftHandle, rightHandle] {
            h.onDrag = { [weak self] x in self?.dragWidth(toX: x) }
        }
        addSubview(bar)
        bar.addSubview(progress)
        toast.alignment = .center
        toast.alphaValue = 0
        addSubview(toast)

        prompter.onRender = { [weak self] p in self?.progress.progress = p }
        prompter.onLayoutChange = { [weak self] in
            guard let self = self else { return }
            self.progress.cues = self.prompter.cueFractions
        }

        let play = iconButton("play.fill", "Start of stop (spatie)", size: 18, target: self, action: #selector(playClicked))
        playButton = play
        timeLabel.attributedStringValue = Theme.label("Tijd", size: 9.5)
        timeValue.font = NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        let timeStack = NSStackView(views: [timeLabel, timeValue])
        timeStack.orientation = .vertical
        timeStack.alignment = .leading
        timeStack.spacing = 2
        timeStack.translatesAutoresizingMaskIntoConstraints = false
        timeClick.addSubview(timeStack)
        timeClick.toolTip = "Klik: klaar in een vaste tijd"
        timeClick.onClick = { [weak self] in self?.timeClicked() }
        timeClick.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            timeStack.leadingAnchor.constraint(equalTo: timeClick.leadingAnchor),
            timeStack.trailingAnchor.constraint(equalTo: timeClick.trailingAnchor),
            timeStack.topAnchor.constraint(equalTo: timeClick.topAnchor),
            timeStack.bottomAnchor.constraint(equalTo: timeClick.bottomAnchor),
            timeClick.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
        ])

        let minus = iconButton("minus", "Langzamer (pijl omlaag)", size: 17, target: self, action: #selector(slowerClicked))
        let plus = iconButton("plus", "Sneller (pijl omhoog)", size: 17, target: self, action: #selector(fasterClicked))
        speedLabel.attributedStringValue = Theme.label("Snelheid", size: 9.5)
        speedLabel.alignment = .center
        speedValue.font = NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .heavy)
        speedValue.alignment = .center
        let speedStack = NSStackView(views: [speedLabel, speedValue])
        speedStack.orientation = .vertical
        speedStack.alignment = .centerX
        speedStack.spacing = 0
        speedStack.translatesAutoresizingMaskIntoConstraints = false
        speedStack.widthAnchor.constraint(equalToConstant: 76).isActive = true

        let mirror = iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Spiegelen (M)", target: self, action: #selector(mirrorClicked))
        let screen2 = iconButton("display.2", "Tweede scherm", target: self, action: #selector(screenClicked))
        let phone = iconButton("iphone", "Bedienen met je telefoon", target: self, action: #selector(phoneClicked))
        let gear = iconButton("gearshape", "Instellingen", target: self, action: #selector(gearClicked))
        let close = iconButton("xmark", "Terug naar de editor (Esc)", target: self, action: #selector(closeClicked))
        mirrorButton = mirror
        screenButton = screen2
        phoneButton = phone
        gearButton = gear

        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.setViews([play, timeClick], in: .leading)
        stack.setViews([minus, speedStack, plus], in: .center)
        stack.setViews([mirror, screen2, phone, gear, close], in: .trailing)
        stack.setCustomSpacing(14, after: play)
        bar.addSubview(stack)

        let p = Prompter.shared
        p.$speed.sink { [weak self] _ in self?.stateRefresher.ask() }.store(in: &bag)
        p.$isScrolling.sink { [weak self] _ in self?.stateRefresher.ask() }.store(in: &bag)
        p.$countdownRemaining.sink { [weak self] _ in self?.stateRefresher.ask() }.store(in: &bag)
        p.$isHoldingSlow.sink { [weak self] _ in self?.stateRefresher.ask() }.store(in: &bag)
        p.$timedDuration.sink { [weak self] _ in self?.stateRefresher.ask() }.store(in: &bag)
        p.$settings.sink { [weak self] _ in self?.stateRefresher.ask() }.store(in: &bag)
        ExternalScreens.shared.$showing.sink { [weak self] _ in self?.stateRefresher.ask() }.store(in: &bag)
        refreshState()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        prompter.frame = bounds
        countdown.frame = bounds
        let w = min(860, max(bounds.width - 32, 200))
        let h: CGFloat = 78
        bar.frame = NSRect(x: (bounds.width - w) / 2, y: bounds.height - h - 18, width: w, height: h)
        layoutHandles()
        progress.frame = NSRect(x: 22, y: 10, width: w - 44, height: 3)
        stack.frame = NSRect(x: 0, y: 16, width: w, height: h - 18)
        toast.frame = NSRect(x: 0, y: bar.frame.minY - 34, width: bounds.width, height: 20)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        showBar()
        scheduleHide()
    }

    // MARK: Activation

    func activate() {
        Prompter.shared.register(prompter)
        progress.cues = prompter.cueFractions
        clockTimer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshClock() }
        }
        RunLoop.main.add(t, forMode: .common)
        clockTimer = t
        showBar()
        refreshState()
        refreshClock()
    }

    func deactivate() {
        Prompter.shared.unregister(prompter)
        clockTimer?.invalidate()
        clockTimer = nil
        hideWork?.cancel()
        phonePopover?.close()
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    // MARK: State

    private func refreshState() {
        let p = Prompter.shared
        let s = p.settings
        layoutHandles()
        if p.isHoldingSlow {
            speedValue.stringValue = "\(Int(max(0, p.speed - s.holdSlowSteps).rounded()))"
            speedLabel.attributedStringValue = Theme.label("Trager", size: 9.5, color: Theme.mint)
        } else {
            speedValue.stringValue = p.timedDuration == nil ? "\(Int(p.speed.rounded()))" : "AUTO"
            speedLabel.attributedStringValue = Theme.label("Snelheid", size: 9.5)
        }
        speedValue.font = NSFont.monospacedDigitSystemFont(ofSize: p.timedDuration == nil || p.isHoldingSlow ? 30 : 20, weight: .heavy)
        refreshClock()
        if let b = playButton { setSymbol(b, p.isScrolling || p.countdownRemaining != nil ? "pause.fill" : "play.fill", size: 18) }
        countdown.value = p.countdownRemaining
        mirrorButton?.contentTintColor = s.mirrorMain ? Theme.text : Theme.grey
        screenButton?.contentTintColor = ExternalScreens.shared.isShowing ? Theme.text : Theme.grey
        if p.isScrolling && s.hideControlsWhileScrolling {
            scheduleHide()
            if p.isPrompterActive { NSCursor.setHiddenUntilMouseMoves(true) }
        } else {
            hideWork?.cancel()
            showBar()
        }
    }

    private func refreshClock() {
        let p = Prompter.shared
        var text = Theme.clock(p.elapsed)
        if let r = p.remaining { text += "  ·  nog " + Theme.clock(r) }
        let timed = p.timedDuration != nil
        if timed != showingTimed {
            showingTimed = timed
            timeLabel.attributedStringValue = Theme.label(timed ? "Klaar in" : "Tijd", size: 9.5, color: timed ? Theme.mint : Theme.grey)
        }
        if timed, let r = p.remaining { text = Theme.clock(r) }
        if timeValue.stringValue != text { timeValue.stringValue = text }
    }
    private var showingTimed = false

    private func showBar() {
        guard !barVisible else { return }
        barVisible = true
        NSAnimationContext.runAnimationGroup { c in
            c.duration = Theme.fast
            bar.animator().alphaValue = 1
            leftHandle.animator().alphaValue = 1
            rightHandle.animator().alphaValue = 1
        }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let p = Prompter.shared
        guard p.isScrolling, p.settings.hideControlsWhileScrolling,
              phonePopover?.isShown != true else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, Prompter.shared.isScrolling, Prompter.shared.settings.hideControlsWhileScrolling else { return }
                self.barVisible = false
                NSAnimationContext.runAnimationGroup { c in
                    c.duration = Theme.soft
                    self.bar.animator().alphaValue = 0
                    self.leftHandle.animator().alphaValue = 0
                    self.rightHandle.animator().alphaValue = 0
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    func showToast(_ text: String) {
        toast.stringValue = text
        toast.textColor = Theme.text
        toast.alphaValue = 1
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 1.6
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            toast.animator().alphaValue = 0
        }
    }

    // MARK: Actions

    @objc private func playClicked() { Prompter.shared.toggleScrolling() }
    @objc private func fasterClicked() { Prompter.shared.faster() }
    @objc private func slowerClicked() { Prompter.shared.slower() }
    @objc private func mirrorClicked() { Prompter.shared.toggleMirrorMain() }
    @objc private func closeClicked() { onClose?() }
    @objc private func screenClicked() { toggleSecondScreen() }

    // MARK: Text width handles

    /// Handles sit on the edges of the text column. The column is symmetric, so mirroring does not move them.
    private func layoutHandles() {
        let w = bounds.width
        guard w > 0 else { return }
        let margin = (w * CGFloat(Prompter.shared.settings.marginFraction)).rounded()
        let hw: CGFloat = 24
        let top: CGFloat = 40
        let height = max(bar.frame.minY - top - 24, 40)
        leftHandle.frame = NSRect(x: margin - hw / 2, y: top, width: hw, height: height)
        rightHandle.frame = NSRect(x: w - margin - hw / 2, y: top, width: hw, height: height)
    }

    /// Dragging either side moves both: the margin is the distance from the nearest window edge.
    private func dragWidth(toX x: CGFloat) {
        let w = bounds.width
        guard w > 0, x.isFinite else { return }
        let local = min(x, w - x)
        let fraction = Double(local / w)
        let width = ((1 - 2 * fraction) * 100).rounded() / 100
        var s = Prompter.shared.settings
        s.marginFraction = TextWidth.margin(forWidth: width)
        Prompter.shared.settings = s
    }

    func toggleSecondScreen() {
        PrompterScreen.toggleSecondScreenStatic(toast: { [weak self] t in self?.showToast(t) })
    }

    static func toggleSecondScreenStatic(toast: ((String) -> Void)?) {
        let ext = ExternalScreens.shared
        if ext.isShowing {
            ext.closeAll()
        } else if ext.externalScreenCount == 0 {
            toast?("Geen tweede scherm gevonden")
            NSSound.beep()
        } else {
            ext.showOnAllExternal()
        }
    }

    @objc private func phoneClicked() {
        guard let b = phoneButton else { return }
        if let pop = phonePopover, pop.isShown { pop.close(); return }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.appearance = NSAppearance(named: .darkAqua)
        pop.contentViewController = PhonePanel()
        pop.show(relativeTo: b.bounds, of: b, preferredEdge: .maxY)
        phonePopover = pop
        hideWork?.cancel()
    }

    @objc private func gearClicked() { SettingsWindow.shared.show() }

    /// Tap the time: choose "klaar in mm:ss" (timed scrolling) or switch it off.
    @objc private func timeClicked() {
        let m = NSMenu()
        let head = NSMenuItem(title: "Klaar in", action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        let current = Prompter.shared.timedDuration
        let off = NSMenuItem(title: "Uit", action: #selector(timedChosen(_:)), keyEquivalent: "")
        off.target = self
        off.tag = 0
        off.state = current == nil ? .on : .off
        m.addItem(off)
        for sec in TimedChoices.seconds {
            let item = NSMenuItem(title: Theme.clock(Double(sec)), action: #selector(timedChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = sec
            item.state = current.map { Int($0.rounded()) == sec } == true ? .on : .off
            m.addItem(item)
        }
        m.addItem(.separator())
        let own = NSMenuItem(title: "Eigen tijd…", action: #selector(timedOwn), keyEquivalent: "")
        own.target = self
        m.addItem(own)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: timeClick.bounds.height + 6), in: timeClick)
        hideWork?.cancel()
    }

    @objc private func timedChosen(_ item: NSMenuItem) {
        Prompter.shared.setTimedDuration(item.tag > 0 ? TimeInterval(item.tag) : nil)
        refreshClock()
    }

    @objc private func timedOwn() {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "Klaar in"
        alert.informativeText = "Typ minuten en seconden, bijvoorbeeld 2:30."
        let field = NSTextField(string: Prompter.shared.timedDuration.map { Theme.clock($0) } ?? "2:00")
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Annuleer")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let t = TimedChoices.parse(field.stringValue) else { return }
                Prompter.shared.setTimedDuration(t)
            }
        }
    }
}

// MARK: - Phone popover

@MainActor final class PhonePanel: NSViewController {
    override func loadView() {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .centerX
        v.spacing = 12
        v.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        let head = NSTextField(labelWithAttributedString: Theme.label("Bedien met je telefoon", size: 11))
        v.addArrangedSubview(head)
        if let url = Remote.shared.phoneURL {
            if let qr = Remote.shared.phoneQRCode(size: 220) {
                let iv = NSImageView(image: qr)
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.widthAnchor.constraint(equalToConstant: 220).isActive = true
                iv.heightAnchor.constraint(equalToConstant: 220).isActive = true
                v.addArrangedSubview(iv)
            }
            let link = NSTextField(labelWithString: url)
            link.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            link.textColor = Theme.text
            link.isSelectable = true
            v.addArrangedSubview(link)
            let hint = NSTextField(labelWithString: "Zelfde wifi. Scan de code met de camera.")
            hint.font = NSFont.systemFont(ofSize: 12)
            hint.textColor = Theme.grey
            v.addArrangedSubview(hint)
        } else {
            let off = NSTextField(labelWithString: "Telefoon-bediening staat uit.")
            off.font = NSFont.systemFont(ofSize: 14, weight: .medium)
            off.textColor = Theme.text
            v.addArrangedSubview(off)
        }
        view = v
    }
}

// MARK: - Shared helpers (round 2)

enum TimedChoices {
    static let seconds = [30, 60, 90, 120, 180, 300, 600]
    /// "2:30", "2.30", "150" (seconds) or "2" (minutes when small).
    static func parse(_ text: String) -> TimeInterval? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: ":")
        let parts = t.split(separator: ":").map { String($0) }
        if parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]), m >= 0, s >= 0, s < 60 {
            let v = TimeInterval(m * 60 + s)
            return v > 0 ? v : nil
        }
        if parts.count == 1, let n = Int(parts[0]), n > 0 { return TimeInterval(n <= 20 ? n * 60 : n) }
        return nil
    }
}

func colorFromHexString(_ hex: String) -> NSColor? {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

/// PNG of a window's content via cacheDisplay (no screen recording).
@MainActor func photoOfWindow(_ window: NSWindow?, to path: String) -> Bool {
    guard let view = window?.contentView else { return false }
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    do { try data.write(to: URL(fileURLWithPath: path)); return true } catch { return false }
}

/// PNG of a window's layer tree (layer.render), for windows whose drawing lives in layers.
@MainActor func layerPhotoOfWindow(_ window: NSWindow?, to path: String) -> Bool {
    guard let view = window?.contentView, let layer = view.layer else { return false }
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let scale = window?.backingScaleFactor ?? 2
    let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
    guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: view.bounds.height)
    ctx.scaleBy(x: 1, y: -1)
    layer.render(in: ctx)
    guard let image = ctx.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
    do { try data.write(to: URL(fileURLWithPath: path)); return true } catch { return false }
}

final class ClickView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { c in c.duration = Theme.fast; animator().alphaValue = 0.6 }
    }
    override func mouseUp(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { c in c.duration = Theme.fast; animator().alphaValue = 1 }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - Settings window

/// One setting per row: label left, control right. Drawn on a #1C1C1E card.
private final class SettingRow: NSView {
    let refresh: () -> Void
    override var isFlipped: Bool { true }
    init(_ title: String, control: NSView, refresh: @escaping () -> Void) {
        self.refresh = refresh
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        label.textColor = Theme.text
        label.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(control)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 58),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 24),
        ])
    }
    required init?(coder: NSCoder) { nil }
}

private final class SidebarItem: NSView {
    let title: String
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    init(_ title: String) { self.title = title; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        if selected {
            Theme.card.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
        let a = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: selected ? .bold : .medium),
            .foregroundColor: selected ? Theme.text : Theme.grey,
        ])
        a.draw(at: NSPoint(x: 14, y: (bounds.height - a.size().height) / 2))
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

@MainActor final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    static let sections = ["Tekst", "Cue-lijn", "Scrollen", "Spiegelen", "Venster", "Dit script"]

    private var window: NSWindow?
    private let root = RootView(frame: NSRect(x: 0, y: 0, width: 780, height: 580))
    private let pageScroll = NSScrollView()
    private let page = FlippedView()
    private var items: [SidebarItem] = []
    private var rows: [SettingRow] = []
    private(set) var section = 0
    private var bag = Set<AnyCancellable>()
    private lazy var refresher = Coalescer { [weak self] in self?.refreshRows() }

    var isShown: Bool { window?.isVisible == true }
    var settingsWindow: NSWindow? { window }

    func show() {
        let w = window ?? build()
        if !w.isVisible {
            // Open on the screen of the main window, next to the prompter, so changes show live.
            let anchor = NSApp.windows.first(where: { $0 !== w && $0.isVisible && $0.contentView is RootView })
            if let screen = anchor?.screen ?? NSScreen.main {
                let f = screen.visibleFrame
                w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2))
            } else {
                w.center()
            }
        }
        w.makeKeyAndOrderFront(nil)
        refreshRows()
    }

    /// Hides the window. Safe to call any number of times; the window is reused.
    func close() {
        window?.orderOut(nil)
    }

    func select(_ index: Int) {
        guard SettingsWindow.sections.indices.contains(index) else { return }
        if window == nil { _ = build() }
        section = index
        for (i, item) in items.enumerated() { item.selected = i == index }
        buildPage()
    }

    private func build() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Instellingen"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.animationBehavior = .none
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = .black
        w.level = .floating
        w.tabbingMode = .disallowed
        w.delegate = self
        root.wantsLayer = true
        w.contentView = root

        let head = NSTextField(labelWithAttributedString: Theme.label("Instellingen", size: 11))
        head.frame = NSRect(x: 26, y: 26, width: 160, height: 16)
        root.addSubview(head)
        for (i, name) in SettingsWindow.sections.enumerated() {
            let item = SidebarItem(name)
            item.frame = NSRect(x: 14, y: 56 + CGFloat(i) * 44, width: 176, height: 38)
            item.onClick = { [weak self] in self?.select(i) }
            root.addSubview(item)
            items.append(item)
        }
        pageScroll.frame = NSRect(x: 204, y: 0, width: 576, height: 580)
        pageScroll.autoresizingMask = [.width, .height]
        pageScroll.drawsBackground = false
        pageScroll.contentView.drawsBackground = false
        pageScroll.hasVerticalScroller = true
        pageScroll.scrollerStyle = .overlay
        pageScroll.autohidesScrollers = true
        pageScroll.documentView = page
        root.addSubview(pageScroll)

        window = w
        let p = Prompter.shared
        p.$settings.sink { [weak self] _ in self?.refresher.ask() }.store(in: &bag)
        p.$scripts.sink { [weak self] _ in self?.refresher.ask() }.store(in: &bag)
        p.$currentScriptID.sink { [weak self] _ in self?.refresher.ask() }.store(in: &bag)
        p.$timedDuration.sink { [weak self] _ in self?.refresher.ask() }.store(in: &bag)
        select(section)
        return w
    }

    // MARK: Page

    private func buildPage() {
        for v in page.subviews { v.removeFromSuperview() }
        rows = []
        let width = pageScroll.contentSize.width
        let title = NSTextField(labelWithString: SettingsWindow.sections[section])
        title.font = NSFont.systemFont(ofSize: 30, weight: .heavy)
        title.textColor = Theme.text
        title.frame = NSRect(x: 24, y: 16, width: width - 48, height: 40)
        page.addSubview(title)

        let card = CardBackground()
        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = 0
        list.alignment = .leading
        for row in makeRows(section) {
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            rows.append(row)
        }
        let height = CGFloat(rows.count) * 58 + 16
        card.frame = NSRect(x: 24, y: 76, width: width - 48, height: height)
        list.frame = NSRect(x: 0, y: 8, width: card.frame.width, height: height - 16)
        card.addSubview(list)
        page.addSubview(card)
        page.frame = NSRect(x: 0, y: 0, width: width, height: max(card.frame.maxY + 40, pageScroll.contentSize.height))
        refreshRows()
    }

    private func refreshRows() {
        for r in rows { r.refresh() }
    }

    private func change(_ f: (inout PrompterSettings) -> Void) {
        var s = Prompter.shared.settings
        f(&s)
        Prompter.shared.settings = s
    }

    // MARK: Row factories

    private func valueLabel() -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        l.textColor = Theme.text
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 56).isActive = true
        return l
    }

    private func slider(_ title: String, _ lo: Double, _ hi: Double, read: @escaping (PrompterSettings) -> Double,
                        format: @escaping (Double) -> String, write: @escaping (inout PrompterSettings, Double) -> Void) -> SettingRow {
        let value = valueLabel()
        let s = ActionSlider(value: lo, minValue: lo, maxValue: hi, target: nil, action: nil)
        s.isContinuous = true
        s.trackFillColor = .white
        s.translatesAutoresizingMaskIntoConstraints = false
        s.widthAnchor.constraint(equalToConstant: 200).isActive = true
        s.onChange = { [weak self] x in self?.change { write(&$0, x) } }
        let group = NSStackView(views: [s, value])
        group.spacing = 14
        return SettingRow(title, control: group) {
            let x = read(Prompter.shared.settings)
            if abs(s.doubleValue - x) > 0.0001 { s.doubleValue = x }
            value.stringValue = format(x)
        }
    }

    private func toggle(_ title: String, read: @escaping (PrompterSettings) -> Bool,
                        write: @escaping (inout PrompterSettings, Bool) -> Void) -> SettingRow {
        let sw = ActionSwitch()
        sw.onChange = { [weak self] on in self?.change { write(&$0, on) } }
        return SettingRow(title, control: sw) {
            let on = read(Prompter.shared.settings)
            sw.state = on ? .on : .off
        }
    }

    private func colorRow(_ title: String, read: @escaping () -> NSColor, write: @escaping (NSColor) -> Void,
                          reset: (() -> Void)? = nil, isCustom: (() -> Bool)? = nil) -> SettingRow {
        let well = ActionColorWell(style: .minimal)
        well.onChange = write
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 28).isActive = true
        var views: [NSView] = [well]
        var resetButton: NSButton?
        if let reset = reset {
            let b = ActionButton(title: "Standaard")
            b.onClick = reset
            resetButton = b
            views.insert(b, at: 0)
        }
        let group = NSStackView(views: views)
        group.spacing = 12
        return SettingRow(title, control: group) {
            let c = read()
            if Theme.hex(well.color) != Theme.hex(c) { well.color = c }
            if let b = resetButton, let isCustom = isCustom { b.isEnabled = isCustom() }
        }
    }

    private func makeRows(_ index: Int) -> [SettingRow] {
        let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
        switch index {
        case 0:
            let font = ActionPopUp()
            font.addItem(withTitle: "Systeem")
            for family in NSFontManager.shared.availableFontFamilies where !family.hasPrefix(".") { font.addItem(withTitle: family) }
            font.onChange = { [weak self] title in self?.change { $0.fontName = title == "Systeem" ? "" : title } }
            font.translatesAutoresizingMaskIntoConstraints = false
            font.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let fontRow = SettingRow("Lettertype", control: font) {
                let n = Prompter.shared.settings.fontName
                let want = n.isEmpty ? "Systeem" : n
                if font.titleOfSelectedItem != want {
                    if font.item(withTitle: want) != nil { font.selectItem(withTitle: want) } else { font.selectItem(at: 0) }
                }
            }
            return [
                fontRow,
                slider("Grootte", 20, 220, read: { $0.fontSize }, format: { "\(Int($0.rounded()))" }) { $0.fontSize = $1.rounded() },
                slider("Regelafstand", 1.0, 2.5, read: { $0.lineSpacing },
                       format: { String(format: "%.1f", $0).replacingOccurrences(of: ".", with: ",") }) { $0.lineSpacing = ($1 * 10).rounded() / 10 },
                slider("Breedte tekst", 0.2, 1, read: { 1 - 2 * $0.marginFraction }, format: pct) {
                    $0.marginFraction = TextWidth.margin(forWidth: ($1 * 100).rounded() / 100)
                },
                colorRow("Tekstkleur", read: { Prompter.shared.settings.textColor },
                         write: { [weak self] c in self?.change { $0.textColorHex = Theme.hex(c) } }),
                colorRow("Achtergrond", read: { Prompter.shared.settings.backgroundColor },
                         write: { [weak self] c in self?.change { $0.backgroundColorHex = Theme.hex(c) } }),
            ]
        case 1:
            let style = ActionSegmented(labels: ["Lijn", "Pijl", "Beide"])
            style.onChange = { [weak self] i in
                guard PrompterSettings.cueStyles.indices.contains(i) else { return }
                self?.change { $0.cueStyle = PrompterSettings.cueStyles[i] }
            }
            let styleRow = SettingRow("Stijl", control: style) {
                style.selectedSegment = PrompterSettings.cueStyles.firstIndex(of: Prompter.shared.settings.cueStyle) ?? 0
            }
            return [
                toggle("Cue-lijn tonen", read: { $0.showCue }) { $0.showCue = $1 },
                styleRow,
                colorRow("Kleur", read: { Prompter.shared.settings.cueColor.withAlphaComponent(1) },
                         write: { [weak self] c in self?.change { $0.cueColorHex = Theme.hex(c) } }),
                slider("Dekking", 0.1, 1, read: { $0.cueOpacity }, format: pct) { $0.cueOpacity = ($1 * 100).rounded() / 100 },
                slider("Hoogte", 0.1, 0.9, read: { $0.cuePosition }, format: pct) { $0.cuePosition = ($1 * 100).rounded() / 100 },
            ]
        case 2:
            let timed = ActionPopUp()
            timed.addItem(withTitle: "Uit")
            for sec in TimedChoices.seconds { timed.addItem(withTitle: Theme.clock(Double(sec))) }
            timed.onChange = { _ in
                let i = timed.indexOfSelectedItem
                Prompter.shared.setTimedDuration(i > 0 && TimedChoices.seconds.indices.contains(i - 1) ? TimeInterval(TimedChoices.seconds[i - 1]) : nil)
            }
            let timedRow = SettingRow("Klaar in", control: timed) {
                guard let t = Prompter.shared.timedDuration else { timed.selectItem(at: 0); return }
                let title = Theme.clock(t)
                if timed.item(withTitle: title) == nil { timed.addItem(withTitle: title) }
                timed.selectItem(withTitle: title)
            }
            return [
                slider("Snelheidssprong", 1, 20, read: { $0.speedJump }, format: { "\(Int($0.rounded()))" }) { $0.speedJump = $1.rounded() },
                slider("Shift: trager met", 1, 5, read: { $0.holdSlowSteps }, format: { "\(Int($0.rounded()))" }) { $0.holdSlowSteps = $1.rounded() },
                slider("Aftellen", 0, 10, read: { Double($0.countdown) }, format: { $0 < 0.5 ? "Uit" : "\(Int($0.rounded())) s" }) { $0.countdown = Int($1.rounded()) },
                timedRow,
                toggle("Slepen stopt het scrollen", read: { $0.dragStopsScrolling }) { $0.dragStopsScrolling = $1 },
                toggle("Balk verbergen tijdens scrollen", read: { $0.hideControlsWhileScrolling }) { $0.hideControlsWhileScrolling = $1 },
            ]
        case 3:
            return [
                toggle("Spiegel dit scherm", read: { $0.mirrorMain }) { $0.mirrorMain = $1 },
                toggle("Spiegel tweede scherm", read: { $0.mirrorExternal }) { $0.mirrorExternal = $1 },
                toggle("Ondersteboven", read: { $0.flipVertical }) { $0.flipVertical = $1 },
            ]
        case 4:
            return [
                toggle("Zwevend venster", read: { $0.floatingWindow }) { $0.floatingWindow = $1 },
                slider("Dekking achtergrond", 0.3, 1, read: { $0.windowOpacity }, format: pct) { $0.windowOpacity = ($1 * 100).rounded() / 100 },
                toggle("Doorzichtige achtergrond", read: { $0.transparentBackground }) { $0.transparentBackground = $1 },
            ]
        default:
            guard Prompter.shared.currentScript != nil else {
                let none = NSTextField(labelWithString: "")
                return [SettingRow("Geen script gekozen", control: none) {}]
            }
            return [
                colorRow("Tekstkleur", read: { Prompter.shared.effectiveTextColor() },
                         write: { c in Prompter.shared.setCurrentTextColorHex(Theme.hex(c)) },
                         reset: { Prompter.shared.setCurrentTextColorHex(nil) },
                         isCustom: { Prompter.shared.currentScript?.textColorHex != nil }),
                colorRow("Achtergrond", read: { Prompter.shared.effectiveBackgroundColor() },
                         write: { c in Prompter.shared.setCurrentBackgroundColorHex(Theme.hex(c)) },
                         reset: { Prompter.shared.setCurrentBackgroundColorHex(nil) },
                         isCustom: { Prompter.shared.currentScript?.backgroundColorHex != nil }),
            ]
        }
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { close() }
        return false
    }
}

// Controls with closures, so rows need no selector plumbing.
final class ActionSlider: NSSlider {
    var onChange: ((Double) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(fire) }
    required init?(coder: NSCoder) { nil }
    convenience init(value: Double, minValue: Double, maxValue: Double, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.minValue = minValue
        self.maxValue = maxValue
        self.doubleValue = value
        self.target = self
        self.action = #selector(fire)
    }
    @objc private func fire() { onChange?(doubleValue) }
}

final class ActionSwitch: NSSwitch {
    var onChange: ((Bool) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(fire) }
    required init?(coder: NSCoder) { nil }
    @objc private func fire() { onChange?(state == .on) }
}

final class ActionColorWell: NSColorWell {
    var onChange: ((NSColor) -> Void)?
    convenience init(style: NSColorWell.Style) {
        self.init(frame: NSRect(x: 0, y: 0, width: 44, height: 28))
        colorWellStyle = style
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { onChange?(color) }
}

final class ActionPopUp: NSPopUpButton {
    var onChange: ((String) -> Void)?
    init() { super.init(frame: .zero, pullsDown: false); target = self; action = #selector(fire) }
    required init?(coder: NSCoder) { nil }
    @objc private func fire() { onChange?(titleOfSelectedItem ?? "") }
}

final class ActionSegmented: NSSegmentedControl {
    var onChange: ((Int) -> Void)?
    convenience init(labels: [String]) {
        self.init(frame: .zero)
        segmentCount = labels.count
        for (i, l) in labels.enumerated() { setLabel(l, forSegment: i); setWidth(70, forSegment: i) }
        trackingMode = .selectOne
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { onChange?(selectedSegment) }
}

final class ActionButton: NSButton {
    var onClick: (() -> Void)?
    convenience init(title: String) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .regular
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { onClick?() }
}

// MARK: - Text width

enum TextWidth {
    /// Width of the text column as a fraction of the window, 0.2...1, to the per-side margin.
    static func margin(forWidth width: Double) -> Double {
        guard width.isFinite else { return 0.12 }
        let w = min(max(width, 0.2), 1)
        return ((1 - w) / 2 * 1000).rounded() / 1000
    }
    static func width(of s: PrompterSettings) -> Double { 1 - 2 * s.marginFraction }

    /// ⌘[ / ⌘]: 5% of the window per step.
    @MainActor static func step(_ delta: Double) {
        var s = Prompter.shared.settings
        let w = ((width(of: s) + delta) * 100).rounded() / 100
        s.marginFraction = margin(forWidth: w)
        Prompter.shared.settings = s
    }
}

/// Thin drag handle on an edge of the text column.
final class WidthHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var hover = false { didSet { if hover != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let x = bounds.midX
        NSColor(white: 1, alpha: hover ? 0.5 : 0.22).setFill()
        NSRect(x: x - 0.5, y: 0, width: 1, height: bounds.height).fill(using: .sourceOver)
        let grip = NSRect(x: x - 3, y: bounds.midY - 22, width: 6, height: 44)
        NSColor(white: 1, alpha: hover ? 0.95 : 0.7).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 3, yRadius: 3).fill()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseDown(with event: NSEvent) { hover = true }
    override func mouseDragged(with event: NSEvent) {
        guard let parent = superview else { return }
        onDrag?(parent.convert(event.locationInWindow, from: nil).x)
    }
    override func mouseUp(with event: NSEvent) { hover = false }
}
