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

    override func draw(_ dirtyRect: NSRect) {
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

    private(set) var prompterScreen: PrompterScreen?
    private var bag = Set<AnyCancellable>()
    private lazy var listRefresher = Coalescer { [weak self] in self?.refreshList() }
    private lazy var editorRefresher = Coalescer { [weak self] in self?.refreshEditor() }

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
        editor.isRichText = false
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
    }

    private func layoutAll() {
        let b = root.bounds
        let side = sidebarWidth
        listHeader.frame = NSRect(x: 22, y: 50, width: 120, height: 16)
        importButton?.frame = NSRect(x: side - 22 - 35, y: 40, width: 35, height: 35)
        plusButton?.frame = NSRect(x: side - 22 - 35 - 38, y: 40, width: 35, height: 35)
        listScroll.frame = NSRect(x: 0, y: 84, width: side, height: max(b.height - 84, 0))
        layoutCards()

        let x = side + 8
        let w = max(b.width - x - 28, 100)
        let pill = startPill.intrinsicContentSize
        startPill.frame = NSRect(x: b.width - 28 - pill.width, y: 40, width: pill.width, height: pill.height)
        titleLabel.frame = NSRect(x: x, y: 34, width: max(w - pill.width - 24, 60), height: 44)
        statsLabel.frame = NSRect(x: x + 2, y: 84, width: w, height: 16)
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
        guard !p.isPrompterActive else { return }   // sync once on leaving the prompter
        let body = script?.body ?? ""
        if editor.string != body {
            let selected = editor.selectedRange()
            editor.string = body
            if let storage = editor.textStorage, let para = editor.defaultParagraphStyle {
                storage.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: storage.length))
            }
            let len = (body as NSString).length
            editor.setSelectedRange(NSRange(location: min(selected.location, len), length: 0))
            highlightCues()
        }
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
        Prompter.shared.updateCurrentBody(editor.string)
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
        p.updateCurrentBody(editor.string)
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
        guard let view = window?.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
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
    private var settingsPopover: NSPopover?
    private var phonePopover: NSPopover?
    private lazy var stateRefresher = Coalescer { [weak self] in self?.refreshState() }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(prompter)
        addSubview(countdown)
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

        let minus = iconButton("minus", "Langzamer (pijl omhoog)", size: 17, target: self, action: #selector(slowerClicked))
        let plus = iconButton("plus", "Sneller (pijl omlaag)", size: 17, target: self, action: #selector(fasterClicked))
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
        stack.setViews([play, timeStack], in: .leading)
        stack.setViews([minus, speedStack, plus], in: .center)
        stack.setViews([mirror, screen2, phone, gear, close], in: .trailing)
        stack.setCustomSpacing(14, after: play)
        bar.addSubview(stack)

        let p = Prompter.shared
        p.$speed.sink { [weak self] _ in self?.stateRefresher.ask() }.store(in: &bag)
        p.$isScrolling.sink { [weak self] _ in self?.stateRefresher.ask() }.store(in: &bag)
        p.$countdownRemaining.sink { [weak self] _ in self?.stateRefresher.ask() }.store(in: &bag)
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
        settingsPopover?.close()
        phonePopover?.close()
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    // MARK: State

    private func refreshState() {
        let p = Prompter.shared
        let s = p.settings
        speedValue.stringValue = "\(Int(p.speed.rounded()))"
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
        if timeValue.stringValue != text { timeValue.stringValue = text }
    }

    private func showBar() {
        guard !barVisible else { return }
        barVisible = true
        NSAnimationContext.runAnimationGroup { c in c.duration = Theme.fast; bar.animator().alphaValue = 1 }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let p = Prompter.shared
        guard p.isScrolling, p.settings.hideControlsWhileScrolling,
              settingsPopover?.isShown != true, phonePopover?.isShown != true else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, Prompter.shared.isScrolling, Prompter.shared.settings.hideControlsWhileScrolling else { return }
                self.barVisible = false
                NSAnimationContext.runAnimationGroup { c in c.duration = Theme.soft; self.bar.animator().alphaValue = 0 }
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

    @objc private func gearClicked() {
        guard let b = gearButton else { return }
        if let pop = settingsPopover, pop.isShown { pop.close(); return }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.appearance = NSAppearance(named: .darkAqua)
        pop.contentViewController = SettingsPanel()
        pop.show(relativeTo: b.bounds, of: b, preferredEdge: .maxY)
        settingsPopover = pop
        hideWork?.cancel()
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

// MARK: - Settings popover

@MainActor final class SettingsPanel: NSViewController {
    private struct SliderRow {
        let slider: NSSlider
        let value: NSTextField
        let read: (PrompterSettings) -> Double
        let format: (Double) -> String
    }

    private var rows: [SliderRow] = []
    private var checks: [(NSButton, (PrompterSettings) -> Bool)] = []
    private let textWell = NSColorWell(style: .minimal)
    private let backWell = NSColorWell(style: .minimal)
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var bag = Set<AnyCancellable>()
    private lazy var refresher = Coalescer { [weak self] in self?.refresh() }

    private func change(_ f: (inout PrompterSettings) -> Void) {
        var s = Prompter.shared.settings
        f(&s)
        Prompter.shared.settings = s
    }

    override func loadView() {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 10
        v.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        // Font
        v.addArrangedSubview(header("Lettertype"))
        fontPopup.addItem(withTitle: "Systeem")
        for family in NSFontManager.shared.availableFontFamilies where !family.hasPrefix(".") {
            fontPopup.addItem(withTitle: family)
        }
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)
        fontPopup.translatesAutoresizingMaskIntoConstraints = false
        fontPopup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        v.addArrangedSubview(fontPopup)

        addSlider(v, "Grootte", 20, 220, { $0.fontSize }, { "\(Int($0.rounded()))" }) { s, x in s.fontSize = x.rounded() }
        addSlider(v, "Regelafstand", 1.0, 2.5, { $0.lineSpacing }, { String(format: "%.1f", $0).replacingOccurrences(of: ".", with: ",") }) { s, x in s.lineSpacing = (x * 10).rounded() / 10 }
        addSlider(v, "Marges", 0, 0.4, { $0.marginFraction }, { "\(Int(($0 * 100).rounded()))%" }) { s, x in s.marginFraction = (x * 100).rounded() / 100 }
        addSlider(v, "Cue-hoogte", 0.1, 0.9, { $0.cuePosition }, { "\(Int(($0 * 100).rounded()))%" }) { s, x in s.cuePosition = (x * 100).rounded() / 100 }
        addSlider(v, "Aftellen", 0, 10, { Double($0.countdown) }, { $0 < 0.5 ? "Uit" : "\(Int($0.rounded())) s" }) { s, x in s.countdown = Int(x.rounded()) }
        addSlider(v, "Snelheidssprong", 1, 20, { $0.speedJump }, { "\(Int($0.rounded()))" }) { s, x in s.speedJump = x.rounded() }

        // Colours
        v.addArrangedSubview(header("Kleuren"))
        textWell.target = self
        textWell.action = #selector(colorChanged(_:))
        backWell.target = self
        backWell.action = #selector(colorChanged(_:))
        let colors = NSStackView(views: [smallText("Tekst"), textWell, smallText("Achtergrond"), backWell])
        colors.spacing = 10
        v.addArrangedSubview(colors)

        // Switches
        v.addArrangedSubview(header("Spiegelen"))
        addCheck(v, "Spiegel dit scherm", { $0.mirrorMain }) { s, on in s.mirrorMain = on }
        addCheck(v, "Spiegel tweede scherm", { $0.mirrorExternal }) { s, on in s.mirrorExternal = on }
        addCheck(v, "Ondersteboven", { $0.flipVertical }) { s, on in s.flipVertical = on }
        v.addArrangedSubview(header("Bediening"))
        addCheck(v, "Cue-lijn tonen", { $0.showCue }) { s, on in s.showCue = on }
        addCheck(v, "Slepen stopt het scrollen", { $0.dragStopsScrolling }) { s, on in s.dragStopsScrolling = on }
        addCheck(v, "Balk verbergen tijdens scrollen", { $0.hideControlsWhileScrolling }) { s, on in s.hideControlsWhileScrolling = on }

        view = v
        Prompter.shared.$settings.sink { [weak self] _ in self?.refresher.ask() }.store(in: &bag)
        refresh()
    }

    private func header(_ s: String) -> NSView {
        let l = NSTextField(labelWithAttributedString: Theme.label(s, size: 10))
        return l
    }

    private func smallText(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        l.textColor = Theme.text
        return l
    }

    private var sliderSetters: [ObjectIdentifier: (inout PrompterSettings, Double) -> Void] = [:]
    private var checkSetters: [ObjectIdentifier: (inout PrompterSettings, Bool) -> Void] = [:]

    private func addSlider(_ v: NSStackView, _ title: String, _ lo: Double, _ hi: Double,
                           _ read: @escaping (PrompterSettings) -> Double, _ format: @escaping (Double) -> String,
                           _ write: @escaping (inout PrompterSettings, Double) -> Void) {
        let name = NSTextField(labelWithAttributedString: Theme.label(title, size: 10))
        let value = smallText("")
        value.alignment = .right
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let top = NSStackView(views: [name, NSView(), value])
        top.translatesAutoresizingMaskIntoConstraints = false
        top.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let slider = NSSlider(value: lo, minValue: lo, maxValue: hi, target: self, action: #selector(sliderChanged(_:)))
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let group = NSStackView(views: [top, slider])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 2
        v.addArrangedSubview(group)
        rows.append(SliderRow(slider: slider, value: value, read: read, format: format))
        sliderSetters[ObjectIdentifier(slider)] = write
    }

    private func addCheck(_ v: NSStackView, _ title: String, _ read: @escaping (PrompterSettings) -> Bool,
                          _ write: @escaping (inout PrompterSettings, Bool) -> Void) {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkChanged(_:)))
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: Theme.text, .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        ])
        v.addArrangedSubview(b)
        checks.append((b, read))
        checkSetters[ObjectIdentifier(b)] = write
    }

    private func refresh() {
        let s = Prompter.shared.settings
        for r in rows {
            let x = r.read(s)
            if abs(r.slider.doubleValue - x) > 0.0001 { r.slider.doubleValue = x }
            r.value.stringValue = r.format(x)
        }
        for (b, read) in checks { b.state = read(s) ? .on : .off }
        if Theme.hex(textWell.color) != s.textColorHex.uppercased() { textWell.color = s.textColor }
        if Theme.hex(backWell.color) != s.backgroundColorHex.uppercased() { backWell.color = s.backgroundColor }
        let wanted = s.fontName.isEmpty ? "Systeem" : s.fontName
        if fontPopup.titleOfSelectedItem != wanted {
            if fontPopup.item(withTitle: wanted) != nil { fontPopup.selectItem(withTitle: wanted) } else { fontPopup.selectItem(at: 0) }
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let write = sliderSetters[ObjectIdentifier(sender)] else { return }
        let x = sender.doubleValue
        change { write(&$0, x) }
    }

    @objc private func checkChanged(_ sender: NSButton) {
        guard let write = checkSetters[ObjectIdentifier(sender)] else { return }
        let on = sender.state == .on
        change { write(&$0, on) }
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        let hex = Theme.hex(sender.color)
        if sender === textWell { change { $0.textColorHex = hex } } else { change { $0.backgroundColorHex = hex } }
    }

    @objc private func fontChanged() {
        let title = fontPopup.titleOfSelectedItem ?? "Systeem"
        change { $0.fontName = title == "Systeem" ? "" : title }
    }
}
