// Model.swift, Infinity Prompt
// Settings, scripts, persistence, import and the scroll engine.
// One source of truth: Prompter.shared. Everything runs on the main thread.
// Rules: no force unwraps, no try!, every number clamped, speed only sets a target.

import AppKit
import Combine
import PDFKit
import QuartzCore

// MARK: - Helpers

@inline(__always)
private func clampValue(_ v: Double, _ lo: Double, _ hi: Double, fallback: Double) -> Double {
    guard v.isFinite else { return fallback }
    return min(max(v, lo), hi)
}

private func parseHex(_ hex: String) -> NSColor? {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
    guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
    let r, g, b, a: Double
    if s.count == 8 {
        r = Double((value >> 24) & 0xFF) / 255
        g = Double((value >> 16) & 0xFF) / 255
        b = Double((value >> 8) & 0xFF) / 255
        a = Double(value & 0xFF) / 255
    } else {
        r = Double((value >> 16) & 0xFF) / 255
        g = Double((value >> 8) & 0xFF) / 255
        b = Double(value & 0xFF) / 255
        a = 1
    }
    return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

private func colorFromHex(_ hex: String, fallback: NSColor) -> NSColor {
    parseHex(hex) ?? fallback
}

/// WCAG relative luminance, 0 (black) ... 1 (white).
private func luminance(_ color: NSColor) -> Double {
    guard let c = color.usingColorSpace(.sRGB) else { return 0.5 }
    func lin(_ v: CGFloat) -> Double {
        let d = Double(v)
        return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
    }
    let l = 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    return l.isFinite ? min(max(l, 0), 1) : 0.5
}

private func contrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

// MARK: - Settings

struct PrompterSettings: Codable, Equatable {
    var fontName: String = ""            // "" = system font
    var fontSize: Double = 64            // clamp 20...220
    var lineSpacing: Double = 1.3        // multiplier, clamp 1.0...2.5
    var marginFraction: Double = 0.12    // per side, clamp 0...0.4
    var textColorHex: String = "#E1E0E3"
    var backgroundColorHex: String = "#000000"
    var mirrorMain: Bool = false
    var mirrorExternal: Bool = true
    var flipVertical: Bool = false
    var showCue: Bool = true
    var cuePosition: Double = 0.33       // clamp 0.1...0.9
    var countdown: Int = 0               // clamp 0...10 (ronde 2: default off)
    var speedJump: Double = 5            // clamp 1...20
    var dragStopsScrolling: Bool = true
    var hideControlsWhileScrolling: Bool = true
    // Ronde 2
    var holdSlowSteps: Double = 2        // clamp 1...10
    var holdFastSteps: Double = 2        // clamp 1...10, Control held
    var cueStyle: String = "lijn"        // "lijn" | "pijl" | "beide"
    var cueColorHex: String = "#75FA9D"
    var cueOpacity: Double = 1           // clamp 0.1...1
    var floatingWindow: Bool = false
    var windowOpacity: Double = 1        // clamp 0.3...1, background only
    var transparentBackground: Bool = false

    static let cueStyles = ["lijn", "pijl", "beide"]

    var textColor: NSColor {
        colorFromHex(textColorHex, fallback: NSColor(srgbRed: 0xE1 / 255.0, green: 0xE0 / 255.0, blue: 0xE3 / 255.0, alpha: 1))
    }
    var backgroundColor: NSColor {
        colorFromHex(backgroundColorHex, fallback: .black)
    }
    /// Cue colour with cueOpacity applied.
    var cueColor: NSColor {
        let base = colorFromHex(cueColorHex, fallback: NSColor(srgbRed: 0x75 / 255.0, green: 0xFA / 255.0, blue: 0x9D / 255.0, alpha: 1))
        return base.withAlphaComponent(CGFloat(clampValue(cueOpacity, 0.1, 1, fallback: 1)))
    }

    /// Returns a copy with every value inside its range. NaN and infinity fall back to defaults,
    /// so the result is always Equatable to itself.
    func clamped() -> PrompterSettings {
        let d = PrompterSettings()
        var c = self
        c.fontSize = clampValue(fontSize, 20, 220, fallback: d.fontSize)
        c.lineSpacing = clampValue(lineSpacing, 1.0, 2.5, fallback: d.lineSpacing)
        c.marginFraction = clampValue(marginFraction, 0, 0.4, fallback: d.marginFraction)
        c.cuePosition = clampValue(cuePosition, 0.1, 0.9, fallback: d.cuePosition)
        c.countdown = min(max(countdown, 0), 10)
        c.speedJump = clampValue(speedJump, 1, 20, fallback: d.speedJump)
        c.holdSlowSteps = clampValue(holdSlowSteps, 1, 10, fallback: d.holdSlowSteps)
        c.holdFastSteps = clampValue(holdFastSteps, 1, 10, fallback: d.holdFastSteps)
        if !PrompterSettings.cueStyles.contains(cueStyle) { c.cueStyle = d.cueStyle }
        c.cueOpacity = clampValue(cueOpacity, 0.1, 1, fallback: d.cueOpacity)
        c.windowOpacity = clampValue(windowOpacity, 0.3, 1, fallback: d.windowOpacity)
        return c
    }
}

extension PrompterSettings {
    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, lineSpacing, marginFraction, textColorHex, backgroundColorHex
        case mirrorMain, mirrorExternal, flipVertical, showCue, cuePosition, countdown, speedJump
        case dragStopsScrolling, hideControlsWhileScrolling
        case holdSlowSteps, holdFastSteps, cueStyle, cueColorHex, cueOpacity, floatingWindow, windowOpacity, transparentBackground
    }

    // Tolerant decoding: missing or broken keys fall back to defaults instead of losing all settings.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(String.self, forKey: .fontName) { fontName = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .fontSize) { fontSize = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .lineSpacing) { lineSpacing = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .marginFraction) { marginFraction = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .textColorHex) { textColorHex = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .backgroundColorHex) { backgroundColorHex = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .mirrorMain) { mirrorMain = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .mirrorExternal) { mirrorExternal = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .flipVertical) { flipVertical = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .showCue) { showCue = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .cuePosition) { cuePosition = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .countdown) { countdown = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .speedJump) { speedJump = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .dragStopsScrolling) { dragStopsScrolling = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .hideControlsWhileScrolling) { hideControlsWhileScrolling = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .holdSlowSteps) { holdSlowSteps = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .holdFastSteps) { holdFastSteps = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .cueStyle) { cueStyle = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .cueColorHex) { cueColorHex = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .cueOpacity) { cueOpacity = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .floatingWindow) { floatingWindow = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .windowOpacity) { windowOpacity = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .transparentBackground) { transparentBackground = v }
        self = self.clamped()
    }
}

// MARK: - Script

struct Script: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var body: String          // plain text. A line starting with "#" is a cue point
    var updated: Date
    var rtf: Data? = nil                  // nil = plain body
    var textColorHex: String? = nil       // nil = global setting
    var backgroundColorHex: String? = nil // nil = global setting
}

extension Script {
    private enum CodingKeys: String, CodingKey {
        case id, title, body, updated, rtf, textColorHex, backgroundColorHex
    }

    // Tolerant decoding, every field optional, so old saved data always loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil
        let title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        let body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? nil
        let updated = (try? c.decodeIfPresent(Date.self, forKey: .updated)) ?? nil
        self.init(id: id ?? UUID(),
                  title: title ?? "Naamloos",
                  body: body ?? "",
                  updated: updated ?? Date())
        rtf = (try? c.decodeIfPresent(Data.self, forKey: .rtf)) ?? nil
        textColorHex = (try? c.decodeIfPresent(String.self, forKey: .textColorHex)) ?? nil
        backgroundColorHex = (try? c.decodeIfPresent(String.self, forKey: .backgroundColorHex)) ?? nil
    }
}

/// Decodes one array element without failing the whole array.
private struct LenientScript: Decodable {
    let script: Script?
    init(from decoder: Decoder) throws {
        script = try? Script(from: decoder)
    }
}

// MARK: - Renderer

@MainActor protocol PrompterRenderer: AnyObject {
    var isExternal: Bool { get }
    var contentHeight: Double { get }
    var viewportHeight: Double { get }
    var cueFractions: [Double] { get }
    func render(position: Double)
}

private struct WeakRenderer {
    weak var value: PrompterRenderer?
    let id: ObjectIdentifier
}

// MARK: - Import errors

enum ImportFout: LocalizedError {
    case nietLeesbaar(String)
    case geenTekst(String)

    var errorDescription: String? {
        switch self {
        case .nietLeesbaar(let naam): return "Het bestand \(naam) kan niet gelezen worden."
        case .geenTekst(let naam): return "In \(naam) staat geen tekst."
        }
    }
}

// MARK: - Display link proxy (holds the owner weakly, so the link never keeps Prompter alive)

@MainActor private final class DisplayLinkProxy: NSObject {
    weak var owner: Prompter?
    init(owner: Prompter) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.engineTick() }
}

// MARK: - Prompter

@MainActor final class Prompter: ObservableObject {
    static let shared = Prompter()

    // MARK: Settings

    @Published var settings: PrompterSettings {
        didSet {
            let c = settings.clamped()
            if c != settings { settings = c }   // assigning inside didSet does not re-run didSet
            if c != oldValue { persistSettings() }
        }
    }

    // MARK: Scripts

    @Published private(set) var scripts: [Script] = []
    @Published private(set) var currentScriptID: UUID?
    /// Non-nil when scripts.json could not be read completely. Dutch text for the UI.
    /// The original file is then never overwritten; saves go to "scripts-nieuw.json".
    @Published private(set) var loadProblem: String?

    var currentScript: Script? {
        guard let id = currentScriptID else { return nil }
        return scripts.first { $0.id == id }
    }

    /// The current script as attributed text: from rtf, else from body. Font family and size
    /// are not meaningful here (the renderer applies settings); bold, italic, underline and colour are.
    var currentAttributed: NSAttributedString {
        guard let script = currentScript else { return NSAttributedString(string: "") }
        if let cache = attributedCache, cache.id == script.id, cache.body == script.body, cache.rtf == script.rtf {
            return cache.value
        }
        var value = NSAttributedString(string: script.body)
        if let data = script.rtf,
           let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                              documentAttributes: nil) {
            value = attr
        }
        attributedCache = (script.id, script.body, script.rtf, value)
        return value
    }

    // MARK: Mode

    @Published var isPrompterActive: Bool = false {
        didSet { if !isPrompterActive { setHoldSlow(false); setHoldFast(false) } }
    }

    // MARK: Scroll state

    @Published private(set) var isScrolling: Bool = false
    @Published private(set) var countdownRemaining: Int?
    @Published private(set) var speed: Double = 20
    @Published private(set) var direction: Int = 1
    @Published private(set) var isHoldingSlow: Bool = false
    @Published private(set) var isHoldingFast: Bool = false
    /// nil = normal. A value = finish the script in that many seconds from the current position.
    @Published var timedDuration: TimeInterval? {
        didSet {
            if let t = timedDuration {
                let clean: TimeInterval? = t.isFinite && t > 0 ? min(max(t, 1), 36_000) : nil
                if clean != timedDuration { timedDuration = clean }   // does not re-run didSet
            }
            timedRemaining = timedDuration ?? 0
        }
    }
    private(set) var position: Double = 0
    private(set) var elapsed: TimeInterval = 0
    /// Current eased velocity in speed units (signed). Read-only, for tests and diagnostics.
    private(set) var velocity: Double = 0

    var remaining: TimeInterval? {
        if timedDuration != nil { return max(0, timedRemaining) }
        guard speed > 0 else { return nil }
        let pps = pointsPerSecond(forSpeed: speed)
        guard pps > 0 else { return nil }
        let height = leadContentHeight()
        guard height > 0 else { return nil }
        let left = direction >= 0 ? (1 - position) : position
        let value = left * height / pps
        return value.isFinite ? max(0, value) : nil
    }

    // MARK: Private engine state

    private var renderers: [WeakRenderer] = []
    private var engineClock: Double = 0
    private var lastTickTime: CFTimeInterval?
    private var displayLink: CADisplayLink?
    private var fallbackTimer: Timer?
    private var proxy: DisplayLinkProxy?
    private var timedRemaining: TimeInterval = 0

    private struct Glide { var from: Double; var to: Double; var start: Double; var duration: Double }
    private var glide: Glide?

    private var countdownTimer: Timer?
    private var countdownToken = 0

    private var saveWorkItem: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var attributedCache: (id: UUID, body: String, rtf: Data?, value: NSAttributedString)?
    private var madeBackupThisSession = false

    private let defaults = UserDefaults.standard
    private static let settingsKey = "settings"
    private static let speedKey = "speed"
    private static let currentScriptKey = "currentScriptID"
    private static let migrationKey = "migratie-ronde2"

    // MARK: Init

    private init() {
        var loaded = PrompterSettings()
        if let data = UserDefaults.standard.data(forKey: Prompter.settingsKey),
           let decoded = try? JSONDecoder().decode(PrompterSettings.self, from: data) {
            loaded = decoded.clamped()
        }
        let needsMigration = !UserDefaults.standard.bool(forKey: Prompter.migrationKey)
        if needsMigration { loaded.countdown = 0 }
        settings = loaded
        if needsMigration {
            if let data = try? JSONEncoder().encode(loaded) {
                UserDefaults.standard.set(data, forKey: Prompter.settingsKey)
            }
            UserDefaults.standard.set(true, forKey: Prompter.migrationKey)
        }

        let storedSpeed = UserDefaults.standard.double(forKey: Prompter.speedKey)
        if UserDefaults.standard.object(forKey: Prompter.speedKey) != nil {
            speed = clampValue(storedSpeed.rounded(), 0, 100, fallback: 20)
        }

        loadScripts()
        proxy = DisplayLinkProxy(owner: self)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildDisplayLink() }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveScriptsNow() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setHoldSlow(false); self?.setHoldFast(false) }
        })
    }

    // MARK: - Script commands

    @discardableResult
    func newScript() -> Script {
        let script = Script(id: UUID(), title: "Nieuw script", body: "", updated: Date())
        scripts.insert(script, at: 0)
        select(script.id)
        scheduleSave()
        return script
    }

    func select(_ id: UUID?) {
        cancelCountdown()
        isScrolling = false
        isHoldingSlow = false
        isHoldingFast = false
        velocity = 0
        glide = nil
        position = 0
        elapsed = 0
        timedRemaining = timedDuration ?? 0
        if let id = id, scripts.contains(where: { $0.id == id }) {
            currentScriptID = id
        } else {
            currentScriptID = nil
        }
        defaults.set(currentScriptID?.uuidString, forKey: Prompter.currentScriptKey)
        renderAll()
    }

    /// Plain-text edit. Drops any rich formatting of the current script (body becomes the source).
    func updateCurrentBody(_ body: String) {
        guard let index = currentIndex() else { return }
        guard scripts[index].body != body || scripts[index].rtf != nil else { return }
        scripts[index].body = body
        scripts[index].rtf = nil
        scripts[index].updated = Date()
        scheduleSave()
    }

    /// Rich edit. Stores RTF (bold, italic, underline, colour) and the plain string in body.
    func updateCurrentRich(_ attributed: NSAttributedString) {
        guard let index = currentIndex() else { return }
        let clean = Prompter.normalized(attributed, background: effectiveBackgroundColor(), stripLowContrast: false)
        let body = clean.string
        let rtf = Prompter.rtfData(for: clean)
        guard scripts[index].body != body || scripts[index].rtf != rtf else { return }
        scripts[index].body = body
        scripts[index].rtf = rtf
        scripts[index].updated = Date()
        scheduleSave()
    }

    func rename(_ id: UUID, to title: String) {
        guard let index = scripts.firstIndex(where: { $0.id == id }), scripts.indices.contains(index) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        scripts[index].title = trimmed.isEmpty ? "Naamloos" : trimmed
        scripts[index].updated = Date()
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard let index = scripts.firstIndex(where: { $0.id == id }), scripts.indices.contains(index) else { return }
        scripts.remove(at: index)
        if currentScriptID == id {
            select(scripts.first?.id)
        }
        scheduleSave()
    }

    // MARK: Colour per script

    func effectiveTextColor() -> NSColor {
        if let hex = currentScript?.textColorHex, let c = parseHex(hex) { return c }
        return settings.textColor
    }

    func effectiveBackgroundColor() -> NSColor {
        if let hex = currentScript?.backgroundColorHex, let c = parseHex(hex) { return c }
        return settings.backgroundColor
    }

    /// nil or an invalid hex = use the global colour.
    func setCurrentTextColorHex(_ hex: String?) {
        guard let index = currentIndex() else { return }
        let clean = hex.flatMap { parseHex($0) == nil ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard scripts[index].textColorHex != clean else { return }
        scripts[index].textColorHex = clean
        scheduleSave()
    }

    func setCurrentBackgroundColorHex(_ hex: String?) {
        guard let index = currentIndex() else { return }
        let clean = hex.flatMap { parseHex($0) == nil ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard scripts[index].backgroundColorHex != clean else { return }
        scripts[index].backgroundColorHex = clean
        scheduleSave()
    }

    // MARK: Import

    @discardableResult
    func importFile(_ url: URL) throws -> Script {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        var text: String
        var rtf: Data?

        switch ext {
        case "rtf", "rtfd", "docx", "doc", "html", "htm", "odt", "webarchive":
            let type: NSAttributedString.DocumentType
            switch ext {
            case "rtf": type = .rtf
            case "rtfd": type = .rtfd
            case "docx": type = .officeOpenXML
            case "doc": type = .docFormat
            case "odt": type = .openDocument
            case "webarchive": type = .webArchive
            default: type = .html
            }
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
            let raw: NSAttributedString
            if let attr = try? NSAttributedString(url: url, options: options, documentAttributes: nil) {
                raw = attr
            } else if let attr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
                raw = attr
            } else {
                throw ImportFout.nietLeesbaar(name)
            }
            let clean = Prompter.normalized(raw, background: settings.backgroundColor, stripLowContrast: true)
            text = clean.string
            rtf = Prompter.rtfData(for: clean)
        case "pdf":
            guard let doc = PDFDocument(url: url) else { throw ImportFout.nietLeesbaar(name) }
            text = Prompter.normalizeLineEndings(doc.string ?? "")
        default:
            guard let data = try? Data(contentsOf: url) else { throw ImportFout.nietLeesbaar(name) }
            if let s = String(data: data, encoding: .utf8) {
                text = s
            } else if let s = String(data: data, encoding: .isoLatin1) {
                text = s
            } else {
                throw ImportFout.nietLeesbaar(name)
            }
            text = Prompter.normalizeLineEndings(text)
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportFout.geenTekst(name) }

        var title = url.deletingPathExtension().lastPathComponent
        if title.isEmpty { title = "Geïmporteerd script" }
        let script = Script(id: UUID(), title: title, body: text, updated: Date(), rtf: rtf)
        scripts.insert(script, at: 0)
        select(script.id)
        scheduleSave()
        return script
    }

    // MARK: Rich text helpers

    private static func normalizeLineEndings(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        return t
    }

    /// Keeps only bold, italic, underline, strikethrough and foreground colour, on a neutral base font.
    /// With stripLowContrast, colours that are near black or too close to the background are removed.
    static func normalized(_ input: NSAttributedString, background: NSColor, stripLowContrast: Bool) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: input)
        for (from, to) in [("\r\n", "\n"), ("\r", "\n"), ("\u{FFFC}", ""), ("\u{2028}", "\n"), ("\u{2029}", "\n"), ("\u{FEFF}", "")] {
            m.mutableString.replaceOccurrences(of: from, with: to, options: [], range: NSRange(location: 0, length: m.length))
        }
        let out = NSMutableAttributedString(string: m.string)
        let full = NSRange(location: 0, length: m.length)
        guard full.length > 0 else { return out }
        let fm = NSFontManager.shared
        let baseFont = NSFont.systemFont(ofSize: 12)
        m.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            var keep: [NSAttributedString.Key: Any] = [:]
            var traits: NSFontTraitMask = []
            if let font = attrs[.font] as? NSFont {
                let t = fm.traits(of: font)
                if t.contains(.boldFontMask) || font.fontDescriptor.symbolicTraits.contains(.bold) { traits.insert(.boldFontMask) }
                if t.contains(.italicFontMask) || font.fontDescriptor.symbolicTraits.contains(.italic) { traits.insert(.italicFontMask) }
            }
            var font = baseFont
            if traits.contains(.boldFontMask) { font = fm.convert(font, toHaveTrait: .boldFontMask) }
            if traits.contains(.italicFontMask) { font = fm.convert(font, toHaveTrait: .italicFontMask) }
            keep[.font] = font
            if let u = attrs[.underlineStyle] as? Int, u != 0 { keep[.underlineStyle] = u }
            if let s = attrs[.strikethroughStyle] as? Int, s != 0 { keep[.strikethroughStyle] = s }
            if let color = attrs[.foregroundColor] as? NSColor, let srgb = color.usingColorSpace(.sRGB) {
                let opaque = srgb.withAlphaComponent(1)
                let lowContrast = luminance(opaque) < 0.03 || contrastRatio(opaque, background) < 2.5
                if !(stripLowContrast && lowContrast) { keep[.foregroundColor] = opaque }
            }
            out.setAttributes(keep, range: range)
        }
        return out
    }

    /// RTF for text that carries formatting; nil when it is effectively plain.
    static func rtfData(for attr: NSAttributedString) -> Data? {
        let full = NSRange(location: 0, length: attr.length)
        guard full.length > 0 else { return nil }
        var formatted = false
        attr.enumerateAttributes(in: full, options: []) { attrs, _, stop in
            if attrs[.foregroundColor] != nil || attrs[.underlineStyle] != nil || attrs[.strikethroughStyle] != nil {
                formatted = true
            } else if let f = attrs[.font] as? NSFont {
                let t = NSFontManager.shared.traits(of: f)
                if t.contains(.boldFontMask) || t.contains(.italicFontMask) { formatted = true }
            }
            if formatted { stop.pointee = true }
        }
        guard formatted else { return nil }
        return attr.rtf(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    // MARK: - Scroll commands

    func toggleScrolling() {
        if countdownRemaining != nil {
            cancelCountdown()
        } else if isScrolling {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !isScrolling, countdownRemaining == nil else { return }
        glide = nil
        if direction >= 0 && position >= 1 { position = 0 }
        if direction < 0 && position <= 0 { direction = 1 }
        let fromTop = position <= 0
        if fromTop { timedRemaining = timedDuration ?? 0 }
        let seconds = settings.countdown
        if seconds > 0 && fromTop {
            beginCountdown(seconds)   // countdown only from the top, never on resume
        } else {
            beginScrolling()
        }
    }

    func stop() {
        cancelCountdown()
        isScrolling = false   // velocity eases out on the next ticks
        isHoldingSlow = false
        isHoldingFast = false
    }

    func faster(_ step: Double = 1) {
        guard step.isFinite else { return }
        setSpeed(speed + abs(step))
    }

    func slower(_ step: Double = 1) {
        guard step.isFinite else { return }
        setSpeed(speed - abs(step))
    }

    func jumpFaster() { faster(settings.speedJump) }
    func jumpSlower() { slower(settings.speedJump) }

    func setSpeed(_ value: Double) {
        if timedDuration != nil { timedDuration = nil }
        let v = clampValue(value.rounded(), 0, 100, fallback: speed)
        guard v != speed else { return }
        speed = v
        defaults.set(v, forKey: Prompter.speedKey)
    }

    /// Shift held: the engine target drops by holdSlowSteps; speed itself never changes.
    func setHoldSlow(_ on: Bool) {
        if isHoldingSlow != on { isHoldingSlow = on }
    }

    /// Control held: the engine target rises by holdFastSteps; speed itself never changes.
    func setHoldFast(_ on: Bool) {
        if isHoldingFast != on { isHoldingFast = on }
    }

    func setTimedDuration(_ t: TimeInterval?) {
        timedDuration = t
    }

    func reverseDirection() {
        direction = direction >= 0 ? -1 : 1
    }

    func pageForward() { page(by: 0.8) }
    func pageBackward() { page(by: -0.8) }

    func nextCue() {
        guard let lead = leadRenderer() else { return }
        let base = glide?.to ?? position
        let cues = sanitizedCues(lead.cueFractions)
        if let target = cues.first(where: { $0 > base + 0.0005 }) {
            glideTo(target)
        }
    }

    func previousCue() {
        guard let lead = leadRenderer() else { return }
        let base = glide?.to ?? position
        let cues = sanitizedCues(lead.cueFractions)
        if let target = cues.last(where: { $0 < base - 0.002 }) {
            glideTo(target)
        } else {
            glideTo(0)
        }
    }

    func goToStart() {
        cancelCountdown()
        isScrolling = false
        isHoldingSlow = false
        isHoldingFast = false
        velocity = 0
        glide = nil
        position = 0
        elapsed = 0
        timedRemaining = timedDuration ?? 0
        renderAll()
    }

    func nudge(points: Double) {
        guard points.isFinite, points != 0 else { return }
        if settings.dragStopsScrolling && (isScrolling || countdownRemaining != nil) {
            stop()
            velocity = 0
        }
        glide = nil
        let height = leadContentHeight()
        guard height > 0 else { return }
        setPositionClamped(position + points / height)
        renderAll()
    }

    func setPosition(_ fraction: Double) {
        guard fraction.isFinite else { return }
        glide = nil
        setPositionClamped(fraction)
        renderAll()
    }

    func biggerFont() { settings.fontSize += 4 }
    func smallerFont() { settings.fontSize -= 4 }
    func toggleMirrorMain() { settings.mirrorMain.toggle() }
    func toggleMirrorExternal() { settings.mirrorExternal.toggle() }

    // MARK: - Renderers

    func register(_ r: PrompterRenderer) {
        let id = ObjectIdentifier(r)
        renderers.removeAll { $0.value == nil }
        if !renderers.contains(where: { $0.id == id }) {
            renderers.append(WeakRenderer(value: r, id: id))
        }
        updateEngineRunning()
        r.render(position: position)
    }

    func unregister(_ r: PrompterRenderer) {
        let id = ObjectIdentifier(r)
        renderers.removeAll { $0.id == id || $0.value == nil }
        updateEngineRunning()
    }

    // MARK: - Engine

    /// Called by the display link. Also callable from tests and the stress test.
    func engineTick() {
        let now = CACurrentMediaTime()
        let dt = lastTickTime.map { now - $0 } ?? (1.0 / 60.0)
        lastTickTime = now
        advance(by: dt)
    }

    /// The speed the engine eases toward right now (signed, may exceed 100 in timed mode).
    var engineTarget: Double {
        guard isScrolling else { return 0 }
        var base = speed
        if timedDuration != nil, let needed = timedSpeedNeeded() { base = needed }
        if isHoldingSlow { base = max(0, base - settings.holdSlowSteps) }
        if isHoldingFast { base = base + settings.holdFastSteps }
        return base * (direction >= 0 ? 1 : -1)
    }

    /// Advances the engine by dt seconds (clamped), then renders. Safe with or without renderers.
    func advance(by rawDt: Double) {
        let dt = clampValue(rawDt, 0, 0.1, fallback: 1.0 / 60.0)
        engineClock += dt

        // 1. Ease velocity toward the target. Speed changes only ever move this target.
        let target = engineTarget
        let tau = isScrolling ? 0.25 : 0.15
        let k = dt > 0 ? 1 - exp(-dt / tau) : 0
        velocity += (target - velocity) * k
        if !velocity.isFinite { velocity = 0 }
        velocity = min(max(velocity, -1000), 1000)
        if !isScrolling && abs(velocity) < 0.05 { velocity = 0 }

        let height = leadContentHeight()

        // 2. Move the position.
        if let g = glide {
            let t = g.duration > 0 ? min(max((engineClock - g.start) / g.duration, 0), 1) : 1
            let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2   // ease in-out cubic
            setPositionClamped(g.from + (g.to - g.from) * eased)
            if t >= 1 { glide = nil }
        } else if velocity != 0 && height > 0 {
            let pps = pointsPerSecond(forSpeed: velocity)
            setPositionClamped(position + pps * dt / height)
            if isScrolling {
                elapsed += dt
                if timedDuration != nil { timedRemaining = max(0, timedRemaining - dt) }
            }

            // 3. Stop at the ends.
            if velocity > 0 && position >= 1 {
                position = 1
                stopAtEnd()
            } else if velocity < 0 && position <= 0 {
                position = 0
                stopAtEnd()
            }
        }

        // 4. Timed mode: show the needed speed, clamped, only when the rounded value changes.
        if isScrolling, timedDuration != nil, let needed = timedSpeedNeeded() {
            let shown = clampValue(needed.rounded(), 0, 100, fallback: speed)
            if shown != speed { speed = shown }
        }

        // 5. Render on a copy, so renderers may register or unregister during the tick.
        renderAll()
    }

    // MARK: - Private engine helpers

    private func currentIndex() -> Int? {
        guard let id = currentScriptID, let index = scripts.firstIndex(where: { $0.id == id }),
              scripts.indices.contains(index) else { return nil }
        return index
    }

    /// Speed units needed to finish the rest of the script in the remaining timed seconds.
    private func timedSpeedNeeded() -> Double? {
        let height = leadContentHeight()
        let perSpeed = pointsPerSecond(forSpeed: 1)
        guard height > 0, perSpeed > 0 else { return nil }
        let left = direction >= 0 ? (1 - position) : position
        let seconds = max(timedRemaining, 0.05)
        let needed = left * height / seconds / perSpeed
        return clampValue(needed, 0, 1000, fallback: speed)
    }

    private func pointsPerSecond(forSpeed s: Double) -> Double {
        let v = s * settings.fontSize * 0.06
        return v.isFinite ? v : 0
    }

    private func setPositionClamped(_ value: Double) {
        position = clampValue(value, 0, 1, fallback: position.isFinite ? min(max(position, 0), 1) : 0)
    }

    private func stopAtEnd() {
        isScrolling = false
        isHoldingSlow = false
        isHoldingFast = false
        velocity = 0
        cancelCountdown()
    }

    private func liveRenderers() -> [PrompterRenderer] {
        renderers.compactMap { $0.value }
    }

    private func leadRenderer() -> PrompterRenderer? {
        let live = liveRenderers()
        return live.first(where: { $0.isExternal }) ?? live.first
    }

    private func leadContentHeight() -> Double {
        guard let lead = leadRenderer() else { return 0 }
        let h = lead.contentHeight
        guard h.isFinite, h > 0 else { return 0 }
        return max(h, 1)
    }

    private func sanitizedCues(_ raw: [Double]) -> [Double] {
        raw.filter { $0.isFinite }.map { min(max($0, 0), 1) }.sorted()
    }

    private func renderAll() {
        let snapshot = liveRenderers()
        let p = position
        for r in snapshot { r.render(position: p) }
        if renderers.contains(where: { $0.value == nil }) {
            renderers.removeAll { $0.value == nil }
            updateEngineRunning()
        }
    }

    private func page(by viewportFactor: Double) {
        guard let lead = leadRenderer() else { return }
        let height = leadContentHeight()
        let viewport = lead.viewportHeight
        guard height > 0, viewport.isFinite, viewport > 0 else { return }
        let base = glide?.to ?? position
        glideTo(base + viewportFactor * viewport / height)
    }

    private func glideTo(_ fraction: Double) {
        let to = clampValue(fraction, 0, 1, fallback: position)
        guard abs(to - position) > 0.000001 else { glide = nil; return }
        glide = Glide(from: position, to: to, start: engineClock, duration: 0.3)
        updateEngineRunning()
    }

    // MARK: Countdown (cancellable)

    private func beginCountdown(_ seconds: Int) {
        cancelCountdown()
        countdownToken &+= 1
        let token = countdownToken
        countdownRemaining = max(1, min(seconds, 10))
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.countdownStep(token: token) }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func countdownStep(token: Int) {
        guard token == countdownToken, let left = countdownRemaining else { return }
        if left <= 1 {
            countdownTimer?.invalidate()
            countdownTimer = nil
            countdownRemaining = nil
            beginScrolling()
        } else {
            countdownRemaining = left - 1
        }
    }

    private func cancelCountdown() {
        countdownToken &+= 1
        countdownTimer?.invalidate()
        countdownTimer = nil
        if countdownRemaining != nil { countdownRemaining = nil }
    }

    private func beginScrolling() {
        isScrolling = true
        updateEngineRunning()
    }

    // MARK: Display link lifecycle

    private func updateEngineRunning() {
        let needed = !renderers.isEmpty
        if needed {
            if displayLink == nil && fallbackTimer == nil { rebuildDisplayLink() }
            displayLink?.isPaused = false
        } else {
            displayLink?.isPaused = true
            lastTickTime = nil
        }
    }

    private func rebuildDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        lastTickTime = nil

        if let screen = NSScreen.main ?? NSScreen.screens.first, let proxy = proxy {
            let link = screen.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
            link.add(to: .main, forMode: .common)
            link.isPaused = renderers.isEmpty
            displayLink = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self, !self.renderers.isEmpty else { return }
                    self.engineTick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    // MARK: - Persistence

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Prompter.settingsKey)
        }
    }

    private static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["INFINITY_PROMPT_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Infinity Prompt", isDirectory: true)
    }

    private static var scriptsURL: URL { dataDirectory.appendingPathComponent("scripts.json") }
    private static var backupURL: URL { dataDirectory.appendingPathComponent("scripts.json.bak") }
    private static var recoveryURL: URL { dataDirectory.appendingPathComponent("scripts-nieuw.json") }

    private func loadScripts() {
        let url = Prompter.scriptsURL
        let fm = FileManager.default
        var loaded: [Script] = []

        if fm.fileExists(atPath: url.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var complete = false
            if let data = try? Data(contentsOf: url),
               let items = try? decoder.decode([LenientScript].self, from: data) {
                loaded = items.compactMap { $0.script }
                complete = loaded.count == items.count
            }
            if !complete {
                // Never overwrite a file we could not read completely. Keep a copy and save elsewhere.
                let stamp = Int(Date().timeIntervalSince1970)
                let copy = Prompter.dataDirectory.appendingPathComponent("scripts-onleesbaar-\(stamp).json")
                try? fm.copyItem(at: url, to: copy)
                loadProblem = "Niet alle scripts konden gelezen worden. Het originele bestand blijft bewaard; wijzigingen gaan naar scripts-nieuw.json."
            }
            scripts = loaded
            if loadProblem == nil && fixWelcomeScript() { saveScriptsNow() }
        } else {
            scripts = [Prompter.welcomeScript()]
            saveScriptsNow()
        }

        if let raw = defaults.string(forKey: Prompter.currentScriptKey), let id = UUID(uuidString: raw),
           scripts.contains(where: { $0.id == id }) {
            currentScriptID = id
        } else {
            currentScriptID = scripts.first?.id
        }
    }

    /// Rewrites only the outdated key sentence in a stored welcome script. Returns true if it changed.
    private func fixWelcomeScript() -> Bool {
        let oldFull = "Met pijltje omhoog gaat de tekst langzamer. Met pijltje omlaag gaat hij sneller."
        let oldShort = "Met pijltje omhoog gaat de tekst langzamer."
        var changed = false
        for i in scripts.indices where scripts[i].body.contains(oldShort) {
            let old = scripts[i].body.contains(oldFull) ? oldFull : oldShort
            scripts[i].body = scripts[i].body.replacingOccurrences(of: old, with: Prompter.newKeySentences)
            scripts[i].rtf = nil
            changed = true
        }
        return changed
    }

    private static let newKeySentences = """
    Met pijltje omhoog gaat de tekst sneller. Met pijltje omlaag gaat hij langzamer.
    Houd Shift ingedrukt om even trager te lezen. Laat je los, dan loopt hij weer op het oude tempo.
    Met Option en pijltje omhoog of omlaag maak je een grote sprong in snelheid.
    Met Esc ga je terug.
    """

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveScriptsNow() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    private func saveScriptsNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(scripts) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Prompter.dataDirectory, withIntermediateDirectories: true)
            if loadProblem != nil {
                try data.write(to: Prompter.recoveryURL, options: .atomic)
                return
            }
            // Once per session, keep the previous good file as scripts.json.bak.
            if !madeBackupThisSession, fm.fileExists(atPath: Prompter.scriptsURL.path) {
                try? fm.removeItem(at: Prompter.backupURL)
                try? fm.copyItem(at: Prompter.scriptsURL, to: Prompter.backupURL)
                madeBackupThisSession = true
            }
            try data.write(to: Prompter.scriptsURL, options: .atomic)
        } catch {
            NSLog("Infinity Prompt: scripts opslaan mislukt: \(error.localizedDescription)")
        }
    }

    private static func welcomeScript() -> Script {
        let body = """
        # Welkom bij Infinity Prompt
        Dit is je eerste script. Je kunt het gewoon aanpassen of een nieuw script maken.
        Druk op de spatiebalk om te starten. Nog een keer drukken en de tekst staat stil.
        Met pijltje omhoog gaat de tekst sneller. Met pijltje omlaag gaat hij langzamer.
        Houd Shift ingedrukt om even trager te lezen. Laat je los, dan loopt hij weer op het oude tempo.
        Met Option en pijltje omhoog of omlaag maak je een grote sprong in snelheid.
        Je kunt de snelheid gerust aanpassen terwijl de tekst loopt.

        # Cue-punten
        Een regel die begint met een hekje is een cue-punt, zoals deze kop.
        Met pijltje links ga je naar het vorige cue-punt, met pijltje rechts naar het volgende.
        Druk op M om de tekst te spiegelen, handig voor een prompter met glas.
        Met Esc ga je terug.
        Veel succes met de opname.
        """
        return Script(id: UUID(), title: "Welkom", body: body, updated: Date())
    }
}
