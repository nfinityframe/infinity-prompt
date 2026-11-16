# Infinity Prompt, broncode (build 4)

Op een andere Mac: maak de map teleprompter, zet elk blok hieronder in een bestand met die naam, en draai ./bouw.sh.

## Model.swift

````
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
    var holdSlowSteps: Double = 2        // clamp 1...5
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
        c.holdSlowSteps = clampValue(holdSlowSteps, 1, 5, fallback: d.holdSlowSteps)
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
        case holdSlowSteps, cueStyle, cueColorHex, cueOpacity, floatingWindow, windowOpacity, transparentBackground
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
        didSet { if !isPrompterActive { setHoldSlow(false) } }
    }

    // MARK: Scroll state

    @Published private(set) var isScrolling: Bool = false
    @Published private(set) var countdownRemaining: Int?
    @Published private(set) var speed: Double = 20
    @Published private(set) var direction: Int = 1
    @Published private(set) var isHoldingSlow: Bool = false
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
            MainActor.assumeIsolated { self?.setHoldSlow(false) }
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
````

## App.swift

````
// App.swift, Infinity Prompt
// Entry point, Dutch menu bar with every command, launch arguments.

import AppKit
import Combine

// Saved settings while a test run (-demo, -foto, -stress) is busy; restored at exit.
private var savedDefaults: [String: Any] = [:]
private let testKeys = ["settings", "speed", "currentScriptID"]

@main
struct InfinityPromptMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        let isTest = args.contains("-demo") || args.contains("-foto") || args.contains("-stress") || args.contains("-spiegel")
        if isTest {
            // Never touch the real scripts or settings during a test run.
            let dir = NSTemporaryDirectory() + "InfinityPromptTest-\(ProcessInfo.processInfo.processIdentifier)"
            setenv("INFINITY_PROMPT_DATA_DIR", dir, 1)
            let d = UserDefaults.standard
            for k in testKeys { if let v = d.object(forKey: k) { savedDefaults[k] = v } }
            atexit {
                let d = UserDefaults.standard
                for k in testKeys {
                    if let v = savedDefaults[k] { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
                }
                d.synchronize()
                if let dir = ProcessInfo.processInfo.environment["INFINITY_PROMPT_DATA_DIR"] {
                    try? FileManager.default.removeItem(atPath: dir)
                }
            }
        }
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        _ = delegate
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var main: MainWindowController?
    private var pendingFiles: [URL] = []
    private var bag = Set<AnyCancellable>()
    /// Menu items whose shortcut is a bare key. Only active in the prompter, so typing in the editor stays free.
    private var bareKeyItems: [(NSMenuItem, String, NSEvent.ModifierFlags)] = []
    private lazy var keyRefresher = Coalescer { [weak self] in self?.updateBareKeys() }

    private let args = CommandLine.arguments
    private func has(_ flag: String) -> Bool { args.contains(flag) }
    private func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenu()
        let controller = MainWindowController()
        main = controller

        if has("-demo") { loadDemo() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Remote.shared.startAll()
        Prompter.shared.$isPrompterActive.sink { [weak self] _ in self?.keyRefresher.ask() }.store(in: &bag)
        updateBareKeys()

        if !pendingFiles.isEmpty {
            controller.importFiles(pendingFiles)
            pendingFiles = []
        }

        if has("-demo") && !has("-editor") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated {
                    self?.main?.enterPrompter()
                    if self?.has("-scroll") == true { self?.startWithoutCountdown() }
                }
            }
        }

        if has("-stress") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { StressTest.run() }
            }
        }

        if has("-instellingen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { SettingsWindow.shared.show() }
            }
        }

        if let path = value(after: "-foto") {
            let delay: Double = has("-scroll") ? 2.6 : 2.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    let ok: Bool
                    if self?.has("-instellingen") == true {
                        ok = photoOfWindow(SettingsWindow.shared.settingsWindow, to: path)
                    } else {
                        ok = self?.main?.photo(to: path) ?? false
                    }
                    print(ok ? "foto: \(path)" : "foto: mislukt \(path)")
                    fflush(stdout)
                    NSApp.terminate(nil)
                }
            }
        }

        if let path = value(after: "-spiegel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.mirrorCheck(path) }
            }
        }

        if !has("-demo") && !has("-foto") && !has("-stress") && !has("-spiegel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated { Updater.shared.checkAtLaunch() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        ExternalScreens.shared.closeAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let m = main { m.importFiles(urls) } else { pendingFiles += urls }
    }

    // MARK: Demo

    private func loadDemo() {
        let p = Prompter.shared
        p.settings = PrompterSettings()
        p.setSpeed(22)
        _ = p.newScript()
        if let id = p.currentScriptID { p.rename(id, to: "Demo: bedrijfsfilm") }
        p.updateCurrentBody("""
        # Opening
        Goedemorgen. Wij zijn Infinity Frame, en we maken beelden die blijven hangen.
        Vandaag laten we zien hoe een bedrijfsfilm ontstaat, van het eerste gesprek tot de laatste kleurcorrectie.

        # Het verhaal
        Elk bedrijf heeft een verhaal. Soms ligt het voor het oprapen, soms zit het verstopt in de werkplaats.
        Wij zoeken de mensen die het werk doen, en laten hen vertellen wat ze maken.
        Geen script vol mooie woorden, maar echte zinnen van echte mensen.

        # De draaidag
        Op de draaidag zetten we alles in scène. Licht, camera, geluid en tijd.
        Eén locatie per keer, alles daar afmaken, en dan door naar de volgende.

        # Afsluiting
        Zo ontstaat een film die past bij wie je bent.
        Laten we samenwerken!
        """)
        // Some formatting, so photos show rich text: bold, italic, underline and a colour.
        let rich = NSMutableAttributedString(attributedString: p.currentAttributed)
        let ns = rich.string as NSString
        let fm = NSFontManager.shared
        let base = NSFont.systemFont(ofSize: 12)
        func mark(_ phrase: String, _ attrs: [NSAttributedString.Key: Any]) {
            let r = ns.range(of: phrase)
            if r.location != NSNotFound { rich.addAttributes(attrs, range: r) }
        }
        mark("beelden die blijven hangen", [.font: fm.convert(base, toHaveTrait: .boldFontMask)])
        mark("echte mensen", [.font: fm.convert(base, toHaveTrait: .italicFontMask), .underlineStyle: NSUnderlineStyle.single.rawValue])
        mark("Licht, camera, geluid en tijd.", [.foregroundColor: NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1)])
        mark("Laten we samenwerken!", [.font: fm.convert(base, toHaveTrait: .boldFontMask)])
        p.updateCurrentRich(rich)
    }

    /// -spiegel: verifies mirror and flip on the real layers, saves a layer-rendered PNG, quits.
    private func mirrorCheck(_ path: String) {
        let p = Prompter.shared
        guard let screen = main?.prompterScreen else { print("spiegel: geen prompter"); NSApp.terminate(nil); return }
        func step(_ delay: Double, _ work: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
        }
        var s = p.settings
        s.mirrorMain = true
        s.flipVertical = false
        p.settings = s
        step(0.4) {
            let ok = self.main?.layerPhoto(to: path) ?? false
            print("spiegel: hoofd m11=\(screen.prompter.mirrorTransform.m11)")
            print(ok ? "spiegel: foto \(path)" : "spiegel: foto mislukt")
            var f = p.settings
            f.mirrorMain = false
            f.flipVertical = true
            p.settings = f
            step(0.3) {
                print("spiegel: ondersteboven m22=\(screen.prompter.mirrorTransform.m22)")
                var e = p.settings
                e.flipVertical = false
                e.mirrorExternal = true
                p.settings = e
                ExternalScreens.shared.showTestWindow()
                step(0.4) {
                    let m = ExternalScreens.shared.testView?.mirrorTransform.m11 ?? 0
                    print("spiegel: tweede scherm m11=\(m)")
                    fflush(stdout)
                    ExternalScreens.shared.closeAll()
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func startWithoutCountdown() {
        let p = Prompter.shared
        let saved = p.settings.countdown
        var s = p.settings
        s.countdown = 0
        p.settings = s
        p.start()
        var back = p.settings
        back.countdown = saved
        p.settings = back
    }

    // MARK: Commands

    @objc func newScript(_ sender: Any?) { main?.newScriptAction() }
    @objc func importFile(_ sender: Any?) { main?.importAction() }
    @objc func checkUpdate(_ sender: Any?) { Updater.shared.checkNow() }
    @objc func togglePrompterMode(_ sender: Any?) { main?.togglePrompter() }
    @objc func leavePrompter(_ sender: Any?) { main?.leavePrompter() }
    @objc func toggleScroll(_ sender: Any?) { Prompter.shared.toggleScrolling() }
    @objc func faster(_ sender: Any?) { Prompter.shared.faster() }
    @objc func slower(_ sender: Any?) { Prompter.shared.slower() }
    @objc func jumpFaster(_ sender: Any?) { Prompter.shared.jumpFaster() }
    @objc func jumpSlower(_ sender: Any?) { Prompter.shared.jumpSlower() }
    @objc func previousCue(_ sender: Any?) { Prompter.shared.previousCue() }
    @objc func nextCue(_ sender: Any?) { Prompter.shared.nextCue() }
    @objc func pageForward(_ sender: Any?) { Prompter.shared.pageForward() }
    @objc func pageBackward(_ sender: Any?) { Prompter.shared.pageBackward() }
    @objc func goToStart(_ sender: Any?) { Prompter.shared.goToStart() }
    @objc func reverse(_ sender: Any?) { Prompter.shared.reverseDirection() }
    @objc func mirrorMain(_ sender: Any?) { Prompter.shared.toggleMirrorMain() }
    @objc func mirrorExternal(_ sender: Any?) { Prompter.shared.toggleMirrorExternal() }
    @objc func bigger(_ sender: Any?) { Prompter.shared.biggerFont() }
    @objc func smaller(_ sender: Any?) { Prompter.shared.smallerFont() }
    @objc func secondScreen(_ sender: Any?) { main?.toggleSecondScreen() }
    @objc func openSettings(_ sender: Any?) { SettingsWindow.shared.show() }
    @objc func formatBold(_ sender: Any?) { main?.toggleBold() }
    @objc func formatItalic(_ sender: Any?) { main?.toggleItalic() }
    @objc func formatUnderline(_ sender: Any?) { main?.toggleUnderline() }
    @objc func testScreen(_ sender: Any?) {
        if ExternalScreens.shared.isShowing { ExternalScreens.shared.closeAll() } else { ExternalScreens.shared.showTestWindow() }
    }

    private let prompterOnly: Set<String> = [
        "toggleScroll:", "faster:", "slower:", "jumpFaster:", "jumpSlower:", "previousCue:", "nextCue:",
        "pageForward:", "pageBackward:", "goToStart:", "reverse:", "leavePrompter:",
    ]

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return true }
        let p = Prompter.shared
        switch NSStringFromSelector(action) {
        case "togglePrompterMode:":
            item.title = p.isPrompterActive ? "Terug naar editor" : "Start prompter"
            return p.isPrompterActive || p.currentScript != nil
        case "toggleScroll:":
            item.title = p.isScrolling || p.countdownRemaining != nil ? "Stop" : "Start"
            return p.isPrompterActive
        case "mirrorMain:":
            item.state = p.settings.mirrorMain ? .on : .off
        case "mirrorExternal:":
            item.state = p.settings.mirrorExternal ? .on : .off
        case "secondScreen:":
            item.state = ExternalScreens.shared.isShowing ? .on : .off
        default:
            break
        }
        if prompterOnly.contains(NSStringFromSelector(action)) { return p.isPrompterActive }
        if ["formatBold:", "formatItalic:", "formatUnderline:"].contains(NSStringFromSelector(action)) {
            return !p.isPrompterActive && p.currentScript != nil
        }
        return true
    }

    private func updateBareKeys() {
        let active = Prompter.shared.isPrompterActive
        for (item, key, mods) in bareKeyItems {
            item.keyEquivalent = active ? key : ""
            item.keyEquivalentModifierMask = mods
        }
    }

    // MARK: Menu

    private func key(_ code: Int) -> String {
        guard let scalar = UnicodeScalar(code) else { return "" }
        return String(Character(scalar))
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                     _ mods: NSEvent.ModifierFlags = [.command], bare: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: bare ? "" : key)
        item.keyEquivalentModifierMask = mods
        if action != nil, action != #selector(NSApplication.terminate(_:)) { item.target = nil }
        menu.addItem(item)
        if bare { bareKeyItems.append((item, key, mods)) }
        return item
    }

    private func buildMenu() {
        let bar = NSMenu()

        // App
        let appMenu = NSMenu(title: "Infinity Prompt")
        add(appMenu, "Over Infinity Prompt", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", [])
        add(appMenu, "Instellingen…", #selector(openSettings(_:)), ",")
        add(appMenu, "Zoek naar update…", #selector(checkUpdate(_:)), "", [])
        appMenu.addItem(.separator())
        add(appMenu, "Verberg Infinity Prompt", #selector(NSApplication.hide(_:)), "h")
        add(appMenu, "Verberg andere", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(appMenu, "Toon alles", #selector(NSApplication.unhideAllApplications(_:)), "", [])
        appMenu.addItem(.separator())
        add(appMenu, "Stop Infinity Prompt", #selector(NSApplication.terminate(_:)), "q")
        addTop(bar, appMenu)

        // Bestand
        let file = NSMenu(title: "Bestand")
        add(file, "Nieuw script", #selector(newScript(_:)), "n")
        add(file, "Importeer…", #selector(importFile(_:)), "o")
        file.addItem(.separator())
        add(file, "Sluit venster", #selector(NSWindow.performClose(_:)), "w")
        addTop(bar, file)

        // Wijzig (nodig voor de editor)
        let edit = NSMenu(title: "Wijzig")
        add(edit, "Herstel", Selector(("undo:")), "z")
        add(edit, "Opnieuw", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Knip", #selector(NSText.cut(_:)), "x")
        add(edit, "Kopieer", #selector(NSText.copy(_:)), "c")
        add(edit, "Plak", #selector(NSText.paste(_:)), "v")
        add(edit, "Selecteer alles", #selector(NSText.selectAll(_:)), "a")
        addTop(bar, edit)

        // Opmaak (editor)
        let fmt = NSMenu(title: "Opmaak")
        add(fmt, "Vet", #selector(formatBold(_:)), "b")
        add(fmt, "Cursief", #selector(formatItalic(_:)), "i")
        add(fmt, "Onderstreept", #selector(formatUnderline(_:)), "u")
        addTop(bar, fmt)

        // Prompter
        let up = key(NSUpArrowFunctionKey), down = key(NSDownArrowFunctionKey)
        let left = key(NSLeftArrowFunctionKey), right = key(NSRightArrowFunctionKey)
        let pr = NSMenu(title: "Prompter")
        add(pr, "Start prompter", #selector(togglePrompterMode(_:)), "\r")
        add(pr, "Terug naar editor", #selector(leavePrompter(_:)), "\u{1b}", [], bare: true)
        pr.addItem(.separator())
        add(pr, "Start", #selector(toggleScroll(_:)), " ", [], bare: true)
        add(pr, "Sneller", #selector(faster(_:)), up, [], bare: true)
        add(pr, "Langzamer", #selector(slower(_:)), down, [], bare: true)
        add(pr, "Sprong sneller", #selector(jumpFaster(_:)), up, [.option], bare: true)
        add(pr, "Sprong langzamer", #selector(jumpSlower(_:)), down, [.option], bare: true)
        add(pr, "Richting omdraaien", #selector(reverse(_:)), "r", [], bare: true)
        pr.addItem(.separator())
        add(pr, "Vorig cue-punt", #selector(previousCue(_:)), left, [], bare: true)
        add(pr, "Volgend cue-punt", #selector(nextCue(_:)), right, [], bare: true)
        add(pr, "Pagina terug", #selector(pageBackward(_:)), key(NSPageUpFunctionKey), [], bare: true)
        add(pr, "Pagina verder", #selector(pageForward(_:)), key(NSPageDownFunctionKey), [], bare: true)
        add(pr, "Naar begin", #selector(goToStart(_:)), left, [.command])
        pr.addItem(.separator())
        add(pr, "Spiegelen", #selector(mirrorMain(_:)), "m", [], bare: true)
        add(pr, "Spiegel tweede scherm", #selector(mirrorExternal(_:)), "m", [.shift], bare: true)
        add(pr, "Groter", #selector(bigger(_:)), "+")
        add(pr, "Kleiner", #selector(smaller(_:)), "-")
        pr.addItem(.separator())
        add(pr, "Tweede scherm", #selector(secondScreen(_:)), "2")
        add(pr, "Testvenster tweede scherm", #selector(testScreen(_:)), "2", [.command, .shift])
        addTop(bar, pr)

        // Venster
        let win = NSMenu(title: "Venster")
        add(win, "Minimaliseer", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(win, "Zoom", #selector(NSWindow.performZoom(_:)), "", [])
        add(win, "Schermvullend", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        addTop(bar, win)
        NSApp.windowsMenu = win

        NSApp.mainMenu = bar
    }

    private func addTop(_ bar: NSMenu, _ menu: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        bar.addItem(item)
    }
}
````

## MainWindow.swift

````
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
        NSAnimationContext.runAnimationGroup { c in c.duration = Theme.fast; bar.animator().alphaValue = 1 }
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
                slider("Marges", 0, 0.4, read: { $0.marginFraction }, format: pct) { $0.marginFraction = ($1 * 100).rounded() / 100 },
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
````

## PrompterView.swift

````
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
````

## ExternalScreen.swift

````
// ExternalScreen.swift, Infinity Prompt
// Fullscreen prompter windows on every non-main screen. A screen that disappears closes cleanly.

import AppKit
import Combine

@MainActor final class ExternalScreens: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = ExternalScreens()

    @Published private(set) var showing = false
    var isShowing: Bool { showing }

    private struct Entry { let window: NSWindow; let view: PrompterView }
    private var wantsExternal = false
    private var windows: [CGDirectDisplayID: Entry] = [:]
    private var testEntry: Entry?
    private var observer: NSObjectProtocol?

    private override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// The renderer of the test window, if open (for the -spiegel check).
    var testView: PrompterView? { testEntry?.view }

    /// Number of screens other than the main one.
    var externalScreenCount: Int { externalScreens().count }

    func showOnAllExternal() {
        wantsExternal = true
        screensChanged()
        updateShowing()
    }

    func showTestWindow() {
        guard testEntry == nil else {
            testEntry?.window.makeKeyAndOrderFront(nil)
            return
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(width: min(900, frame.width * 0.6), height: min(560, frame.height * 0.6))
        let rect = NSRect(x: frame.maxX - size.width - 40, y: frame.minY + 40, width: size.width, height: size.height)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Tweede scherm (test)"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        let view = PrompterView(isExternal: true)
        window.contentView = view
        window.delegate = self
        testEntry = Entry(window: window, view: view)
        window.orderFront(nil)
        Prompter.shared.register(view)
        updateShowing()
    }

    func closeAll() {
        wantsExternal = false
        // Remove from storage and unregister first: close() re-enters windowWillClose.
        let all = Array(windows.values) + (testEntry.map { [$0] } ?? [])
        windows.removeAll()
        testEntry = nil
        for e in all {
            Prompter.shared.unregister(e.view)
            e.window.delegate = nil
            e.window.orderOut(nil)
            e.window.close()
        }
        updateShowing()
    }

    // MARK: Private

    private func updateShowing() {
        let now = wantsExternal || !windows.isEmpty || testEntry != nil
        if showing != now { showing = now }
    }

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let n = screen.deviceDescription[key] as? NSNumber { return CGDirectDisplayID(n.uint32Value) }
        return nil
    }

    private func externalScreens() -> [(CGDirectDisplayID, NSScreen)] {
        let all = NSScreen.screens
        guard let main = all.first else { return [] }   // screens[0] holds the menu bar
        let mainID = displayID(main)
        return all.compactMap { s in
            guard let id = displayID(s), id != mainID else { return nil }
            return (id, s)
        }
    }

    private func screensChanged() {
        let current = externalScreens()
        let ids = Set(current.map { $0.0 })

        // Screens that are gone: unregister, then close.
        for (id, e) in windows where !ids.contains(id) {
            windows.removeValue(forKey: id)
            Prompter.shared.unregister(e.view)
            e.window.delegate = nil
            e.window.orderOut(nil)
            e.window.close()
        }

        if wantsExternal {
            for (id, screen) in current {
                if let e = windows[id] {
                    if e.window.frame != screen.frame { e.window.setFrame(screen.frame, display: true) }
                } else {
                    windows[id] = makeWindow(for: screen)
                }
            }
        }
        updateShowing()
    }

    private func makeWindow(for screen: NSScreen) -> Entry {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .none
        window.backgroundColor = .black
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        let view = PrompterView(isExternal: true)
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        window.delegate = self
        window.orderFront(nil)
        Prompter.shared.register(view)
        return Entry(window: window, view: view)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let w = notification.object as? NSWindow else { return }
            if let t = testEntry, t.window === w {
                testEntry = nil
                Prompter.shared.unregister(t.view)
            }
            for (id, e) in windows where e.window === w {
                windows.removeValue(forKey: id)
                Prompter.shared.unregister(e.view)
            }
            updateShowing()
        }
    }
}
````

## Remote.swift

````
// Remote.swift
// Infinity Prompt: bediening van buitenaf.
// 1. Toetsenbord, voetpedaal en presentatieklikker (lokale key monitor).
// 2. Gamecontroller (GameController framework).
// 3. Telefoon via wifi (klein HTTP-servertje met Network.framework).
// Alles roept alleen methodes van Prompter.shared aan, altijd op de main thread.

import AppKit
import CoreImage
import Darwin
import GameController
import Network

@MainActor final class Remote {
    static let shared = Remote()

    private var started = false

    private init() {}

    /// Eén keer aanroepen bij het opstarten.
    func startAll() {
        guard !started else { return }
        started = true
        startKeyboard()
        startGameControllers()
        startPhoneServer()
    }

    // MARK: - 1. Toetsenbord, pedaal, klikker

    private var keyMonitor: Any?

    private func startKeyboard() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Lokale monitors lopen op de main thread.
            let handled = MainActor.assumeIsolated { () -> Bool in
                if event.type == .flagsChanged {
                    Remote.shared.handleFlagsChanged(event)
                    return false          // modifiers altijd doorlaten
                }
                return Remote.shared.handleKeyDown(event)
            }
            return handled ? nil : event
        }
    }

    /// Shift via het toetsenbord ingedrukt (welke Shift dan ook).
    private var keyboardShiftHeld = false

    /// Mag het toetsenbord nu de prompter bedienen?
    private func keyboardGateOpen() -> Bool {
        guard Prompter.shared.isPrompterActive, !isEditingText() else { return false }
        // Een dialoog of sheet (bijvoorbeeld de updatemelding) houdt zijn eigen toetsen.
        if NSApp.modalWindow != nil { return false }
        if let w = NSApp.keyWindow, w.attachedSheet != nil || w.isSheet { return false }
        return true
    }

    /// Shift vasthouden = tijdelijk trager, loslaten = terug naar het oude tempo.
    /// Kijkt naar de vlag zelf: beide Shift-toetsen werken, en de ene loslaten
    /// terwijl de andere nog ingedrukt is houdt hem vast.
    func handleFlagsChanged(_ event: NSEvent) {
        guard keyboardGateOpen() else {
            releaseKeyboardHold()
            return
        }
        let shiftNow = event.modifierFlags.contains(.shift)
        guard shiftNow != keyboardShiftHeld else { return }   // een andere modifier veranderde
        keyboardShiftHeld = shiftNow
        Prompter.shared.setHoldSlow(shiftNow)
    }

    /// De hold van het toetsenbord loslaten (poort dicht).
    private func releaseKeyboardHold() {
        guard keyboardShiftHeld else { return }
        keyboardShiftHeld = false
        Prompter.shared.setHoldSlow(false)
    }

    /// Wordt er nu tekst bewerkt? Dan blijft het toetsenbord van de editor.
    private func isEditingText() -> Bool {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        guard let responder = window?.firstResponder else { return false }
        if let tv = responder as? NSTextView, tv.isEditable { return true }
        if responder is NSTextField { return true }
        return false
    }

    /// Geeft true als de toets is afgehandeld (en dus niet verder mag).
    /// Intern zichtbaar zodat hij te testen is met nagemaakte NSEvents.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let p = Prompter.shared
        guard keyboardGateOpen() else {
            releaseKeyboardHold()
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Cmd en Ctrl laten we aan de menu's.
        if !flags.intersection([.command, .control]).isEmpty { return false }
        let shift = flags.contains(.shift)
        let isRepeat = event.isARepeat

        // Option: alleen ⌥↑ / ⌥↓ (snelheidssprong), de rest gaat door.
        if flags.contains(.option) {
            switch event.keyCode {
            case 126:
                if !isRepeat { p.jumpFaster() }
                return true
            case 125:
                if !isRepeat { p.jumpSlower() }
                return true
            default:
                return false
            }
        }

        // Toetscodes (zelfde op elk toetsenbord)
        switch event.keyCode {
        case 49, 36, 76:                       // spatie, return, enter
            if !isRepeat { p.toggleScrolling() }
            return true
        case 126:                              // pijl omhoog = sneller (zelfde als de controller)
            p.faster()                         // met Shift gewoon een stap
            return true
        case 125:                              // pijl omlaag = langzamer
            p.slower()
            return true
        case 123:                              // pijl links
            if !isRepeat { p.previousCue() }
            return true
        case 124:                              // pijl rechts
            if !isRepeat { p.nextCue() }
            return true
        case 116:                              // page up
            if !isRepeat { p.pageBackward() }
            return true
        case 121:                              // page down
            if !isRepeat { p.pageForward() }
            return true
        case 115:                              // home
            if !isRepeat { p.goToStart() }
            return true
        case 69:                               // keypad +
            p.biggerFont()
            return true
        case 78:                               // keypad -
            p.smallerFont()
            return true
        default:
            break
        }

        // Tekentoetsen (lettertoetsen volgen de indeling)
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        switch chars {
        case "m":
            if !isRepeat { if shift { p.toggleMirrorExternal() } else { p.toggleMirrorMain() } }
            return true
        case "r":
            if !isRepeat && !shift { p.reverseDirection() }
            return !shift
        case "+", "=":
            p.biggerFont()
            return true
        case "-", "_":
            p.smallerFont()
            return true
        default:
            return false
        }
    }

    // MARK: - 2. Gamecontroller

    private weak var controller: GCController?
    private var controllerTimer: Timer?
    private var controllerLastTick: CFTimeInterval = 0
    private var controllerObservers: [NSObjectProtocol] = []

    private func startGameControllers() {
        let center = NotificationCenter.default
        controllerObservers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
            let c = note.object as? GCController
            MainActor.assumeIsolated { Remote.shared.controllerConnected(c) }
        })
        controllerObservers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { note in
            let c = note.object as? GCController
            MainActor.assumeIsolated { Remote.shared.controllerDisconnected(c) }
        })
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        if let first = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            controllerConnected(first)
        }
    }

    private func controllerConnected(_ c: GCController?) {
        guard let c, let pad = c.extendedGamepad else { return }
        if controller != nil && controller !== c { return }   // houd de eerste aan
        controller = c
        c.handlerQueue = .main
        // Blijft werken als een ander programma (bijvoorbeeld Zoom) voorop staat.
        GCController.shouldMonitorBackgroundEvents = true

        // Knoppen: alleen op het moment van indrukken
        pad.buttonA.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            Remote.onMain { Prompter.shared.toggleScrolling() }
        }
        pad.rightShoulder.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            Remote.onMain { Prompter.shared.jumpFaster() }
        }
        // L1 vasthouden = tijdelijk trager, loslaten = terug naar het oude tempo
        pad.leftShoulder.pressedChangedHandler = { _, _, pressed in
            Remote.onMain { Remote.shared.setControllerHold(pressed) }
        }
        pad.buttonB.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            Remote.onMain { Prompter.shared.jumpSlower() }
        }
        pad.dpad.up.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            Remote.onMain { Prompter.shared.faster() }
        }
        pad.dpad.down.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            Remote.onMain { Prompter.shared.slower() }
        }
        pad.dpad.left.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            Remote.onMain { Prompter.shared.previousCue() }
        }
        pad.dpad.right.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            Remote.onMain { Prompter.shared.nextCue() }
        }

        // Triggers en stick: analoog, uitgelezen door een kleine timer
        controllerTimer?.invalidate()
        controllerLastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { Remote.shared.controllerTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        controllerTimer = t
    }

    private var controllerHold = false

    fileprivate func setControllerHold(_ on: Bool) {
        guard on != controllerHold else { return }
        controllerHold = on
        Prompter.shared.setHoldSlow(on)
    }

    private func controllerDisconnected(_ c: GCController?) {
        if let c, let current = controller, c !== current { return }
        setControllerHold(false)
        controllerTimer?.invalidate()
        controllerTimer = nil
        controller = nil
        // Is er nog een andere controller? Neem die over.
        if let next = GCController.controllers().first(where: { $0 !== c && $0.extendedGamepad != nil }) {
            controllerConnected(next)
        }
    }

    private func controllerTick() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - controllerLastTick, 0), 0.1)
        controllerLastTick = now
        guard let pad = controller?.extendedGamepad else {
            controllerTimer?.invalidate()
            controllerTimer = nil
            return
        }
        func dead(_ v: Float, _ zone: Double) -> Double {
            let d = Double(v)
            guard d.isFinite, abs(d) > zone else { return 0 }
            return max(-1, min(1, d))
        }
        let rt = dead(pad.rightTrigger.value, 0.05)
        let lt = dead(pad.leftTrigger.value, 0.05)
        let stickY = dead(pad.leftThumbstick.yAxis.value, 0.15)   // omhoog = positief
        let fontScale = max(20, min(220, Prompter.shared.settings.fontSize)) / 64.0
        // Trigger vol ingedrukt: ongeveer 900 punten per seconde bij 64 pt.
        let triggerPoints = (rt - lt) * 900 * fontScale * dt
        // Stick omhoog = terug in de tekst, omlaag = verder.
        let stickPoints = -stickY * 600 * fontScale * dt
        let total = triggerPoints + stickPoints
        if total.isFinite && abs(total) > 0.01 {
            Prompter.shared.nudge(points: total)
        }
    }

    /// GameController-handlers lopen op handlerQueue (main). Toch veilig doorsturen.
    nonisolated private static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }

    // MARK: - 3. Telefoon via wifi

    private static let firstPort: UInt16 = 8765
    private static let lastPort: UInt16 = 8770

    let token: String = Remote.makeToken()
    private var listener: NWListener?
    private var listenerPort: UInt16?
    private var trying: UInt16 = Remote.firstPort
    private let netQueue = DispatchQueue(label: "nl.infinityframe.prompt.remote")
    fileprivate var openConnections = 0

    var phoneURL: String? {
        guard let port = listenerPort, let ip = Remote.lanIPv4() else { return nil }
        return "http://\(ip):\(port)/\(token)"
    }

    private static func makeToken() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var out = ""
        for _ in 0..<4 {
            out.append(alphabet.randomElement() ?? "k")
        }
        return out
    }

    private func startPhoneServer() {
        trying = Remote.firstPort
        tryListen()
    }

    private func tryListen() {
        guard trying <= Remote.lastPort else {
            NSLog("Infinity Prompt: telefoonserver kon geen poort vinden (8765 tot 8770)")
            return
        }
        guard let port = NWEndpoint.Port(rawValue: trying) else { nextPort(); return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        let l: NWListener
        do {
            l = try NWListener(using: params, on: port)
        } catch {
            nextPort()
            return
        }
        let thisPort = trying
        l.stateUpdateHandler = { state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Remote.shared.listenerState(state, port: thisPort) }
            }
        }
        l.newConnectionHandler = { conn in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Remote.shared.accept(conn) }
            }
        }
        listener = l
        l.start(queue: netQueue)
    }

    private func nextPort() {
        listener?.cancel()
        listener = nil
        if trying >= Remote.lastPort {
            trying = Remote.lastPort &+ 1
            NSLog("Infinity Prompt: telefoonserver kon geen poort vinden (8765 tot 8770)")
            return
        }
        trying += 1
        tryListen()
    }

    private func listenerState(_ state: NWListener.State, port: UInt16) {
        guard port == trying else { return }   // oude listener
        switch state {
        case .ready:
            listenerPort = port
            if let url = phoneURL { NSLog("Infinity Prompt: telefoon via \(url)") }
        case .failed:
            listenerPort = nil
            nextPort()
        case .cancelled:
            if listenerPort == port { listenerPort = nil }
        default:
            break
        }
    }

    private func accept(_ conn: NWConnection) {
        guard openConnections < 24 else { conn.cancel(); return }
        openConnections += 1
        let handler = HTTPConnection(conn: conn, queue: netQueue, token: token)
        handler.start()
    }

    fileprivate func connectionClosed() {
        openConnections = max(0, openConnections - 1)
    }

    // MARK: Opdrachten en status

    /// Voert een opdracht van de telefoon uit. false = onbekende opdracht.
    fileprivate func runCommand(_ name: String) -> Bool {
        let p = Prompter.shared
        switch name {
        case "toggle": p.toggleScrolling()
        case "start": p.start()
        case "stop": p.stop()
        case "faster": p.faster()
        case "slower": p.slower()
        case "jumpfaster": p.jumpFaster()
        case "jumpslower": p.jumpSlower()
        case "nextcue": p.nextCue()
        case "prevcue": p.previousCue()
        case "pageforward": p.pageForward()
        case "pageback": p.pageBackward()
        case "begin": p.goToStart()
        case "mirror": p.toggleMirrorMain()
        case "mirrorexternal": p.toggleMirrorExternal()
        case "reverse": p.reverseDirection()
        case "holdon": phoneHold(true)
        case "holdoff": phoneHold(false)
        case "bigger": p.biggerFont()
        case "smaller": p.smallerFont()
        default: return false
        }
        return true
    }

    private var phoneHoldTimer: Timer?

    /// "Even trager" op de telefoon. Zonder nieuwe holdon binnen 10 s laat hij vanzelf los.
    private func phoneHold(_ on: Bool) {
        phoneHoldTimer?.invalidate()
        phoneHoldTimer = nil
        Prompter.shared.setHoldSlow(on)
        guard on else { return }
        let t = Timer(timeInterval: 10, repeats: false) { _ in
            MainActor.assumeIsolated { Remote.shared.phoneHold(false) }
        }
        RunLoop.main.add(t, forMode: .common)
        phoneHoldTimer = t
    }

    fileprivate func stateJSON() -> Data {
        let p = Prompter.shared
        func finite(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
            guard v.isFinite else { return lo }
            return max(lo, min(hi, v))
        }
        var dict: [String: Any] = [
            "scrolling": p.isScrolling,
            "speed": finite(p.speed, 0, 100),
            "position": finite(p.position, 0, 1),
            "elapsed": finite(p.elapsed, 0, 864_000),
            "title": p.currentScript?.title ?? "",
            "mirror": p.settings.mirrorMain,
            "direction": p.direction >= 0 ? 1 : -1,
            "holding": p.isHoldingSlow,
        ]
        if let t = p.timedDuration, t.isFinite { dict["timed"] = finite(t, 0, 864_000) }
        if let c = p.countdownRemaining { dict["countdown"] = max(0, min(99, c)) }
        if let r = p.remaining, r.isFinite { dict["remaining"] = finite(r, 0, 864_000) }
        return (try? JSONSerialization.data(withJSONObject: dict, options: [])) ?? Data("{}".utf8)
    }

    // MARK: LAN-adres

    static func lanIPv4() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var found: [String: String] = [:]
        var order: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let ifa = cur.pointee
            cursor = ifa.ifa_next
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let namePtr = ifa.ifa_name else { continue }
            let name = String(cString: namePtr)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") || ip.isEmpty { continue }
            if found[name] == nil { found[name] = ip; order.append(name) }
        }
        for preferred in ["en0", "en1"] {
            if let ip = found[preferred] { return ip }
        }
        if let name = order.first(where: { $0.hasPrefix("en") }), let ip = found[name] { return ip }
        if let name = order.first(where: { !$0.hasPrefix("utun") && !$0.hasPrefix("bridge") }), let ip = found[name] { return ip }
        return nil
    }

    // MARK: QR-code

    /// Zwart op wit met een stille rand, scherp geschaald (geen vervaging).
    func phoneQRCode(size: CGFloat) -> NSImage? {
        guard let url = phoneURL, size.isFinite, size > 0 else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let raw = filter.outputImage else { return nil }
        let modules = raw.extent.width
        guard modules.isFinite, modules > 0 else { return nil }
        let target = min(size, 4000) * 2          // pixels voor retina
        let scale = max(1, (target / (modules + 4)).rounded(.down))
        let scaled = raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Extra witte rand van twee modules, zodat telefoons hem ook op zwart goed lezen.
        let padded = scaled.extent.insetBy(dx: -2 * scale, dy: -2 * scale)
        let withMargin = scaled.composited(over: CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: padded))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(withMargin, from: padded) else { return nil }
        let pointSize = NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)
        return NSImage(cgImage: cg, size: pointSize)
    }

    // MARK: Telefoonpagina

    fileprivate func pageHTML() -> String {
        Remote.pageTemplate.replacingOccurrences(of: "__TOKEN__", with: token)
    }

    private static let pageTemplate = """
<!doctype html>
<html lang="nl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#000000">
<title>Infinity Prompt</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent;-webkit-user-select:none;user-select:none}
html,body{background:#000;color:#fff;height:100%}
body{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","Helvetica Neue",sans-serif;touch-action:manipulation;
 padding:max(20px,env(safe-area-inset-top)) 16px max(20px,env(safe-area-inset-bottom));display:flex;flex-direction:column;gap:12px;max-width:520px;margin:0 auto}
button{font:inherit;color:inherit;border:0;background:none;touch-action:manipulation;cursor:pointer;transition:transform 120ms ease,opacity 120ms ease,background-color 120ms ease}
button:active,button.hit{transform:scale(.95);opacity:.8}
.label{font-size:12px;letter-spacing:.14em;text-transform:uppercase;color:#8E8E93;font-weight:600}
.top{display:flex;justify-content:space-between;align-items:flex-end;padding:4px 4px 0}
h1{font-size:28px;font-weight:800;letter-spacing:-.02em;line-height:1.1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:70vw}
.dot{width:10px;height:10px;border-radius:50%;background:#3A3A3C;transition:background-color 280ms ease}
.dot.on{background:#75FA9D}
.card{background:#1C1C1E;border-radius:14px;padding:18px}
.speed{display:flex;align-items:center;justify-content:space-between;gap:8px}
.round{width:76px;height:76px;border-radius:38px;background:#2C2C2E;font-size:40px;font-weight:500;line-height:1}
.num{text-align:center}
.num b{display:block;font-size:84px;font-weight:800;letter-spacing:-.04em;line-height:1;font-variant-numeric:tabular-nums}
.pill{width:100%;height:84px;border-radius:42px;background:#fff;color:#000;font-size:28px;font-weight:800;letter-spacing:-.01em}
.pill.run{background:#fff}
.row{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.pair{display:flex;flex-direction:column;gap:10px}
.pair .btns{display:flex;gap:10px}
.pair .btns button{flex:1;height:64px;border-radius:14px;background:#2C2C2E;font-size:34px;font-weight:600}
.wide{height:64px;border-radius:14px;background:#2C2C2E;font-size:18px;font-weight:700}
.wide.on{color:#75FA9D}
.hold{width:100%;height:72px;font-size:20px}
.hold.on{background:#fff;color:#000}
.timed{font-size:13px;color:#8E8E93;font-variant-numeric:tabular-nums;white-space:nowrap}
.bar{display:flex;align-items:center;gap:12px;padding:4px 4px 0}
.time{font-size:15px;font-weight:600;font-variant-numeric:tabular-nums;color:#fff;min-width:52px}
.track{flex:1;height:3px;border-radius:2px;background:#2C2C2E;overflow:hidden}
.fill{height:100%;width:0;background:#fff;transition:width 400ms linear}
.off{position:fixed;left:16px;right:16px;bottom:max(16px,env(safe-area-inset-bottom));background:#1C1C1E;color:#fff;border-radius:14px;padding:14px;text-align:center;font-weight:600;opacity:0;transition:opacity 280ms ease;pointer-events:none}
.off.show{opacity:1}
</style>
</head>
<body>
<div class="top">
  <div><div class="label">Script</div><h1 id="title">Infinity Prompt</h1></div>
  <div class="dot" id="dot"></div>
</div>

<button class="pill" id="toggle" data-cmd="toggle">Start</button>

<div class="card speed">
  <button class="round" data-cmd="slower" aria-label="Langzamer">&minus;</button>
  <div class="num"><div class="label">Snelheid</div><b id="speed">0</b></div>
  <button class="round" data-cmd="faster" aria-label="Sneller">+</button>
</div>

<div class="row">
  <div class="card pair"><div class="label">Cue</div>
    <div class="btns"><button data-cmd="prevcue" aria-label="Vorige cue">&lsaquo;</button><button data-cmd="nextcue" aria-label="Volgende cue">&rsaquo;</button></div></div>
  <div class="card pair"><div class="label">Pagina</div>
    <div class="btns"><button data-cmd="pageback" aria-label="Pagina terug">&lsaquo;</button><button data-cmd="pageforward" aria-label="Pagina verder">&rsaquo;</button></div></div>
</div>

<button class="wide hold" id="hold">Even trager</button>

<div class="row">
  <button class="wide" data-cmd="begin">Begin</button>
  <button class="wide" id="mirror" data-cmd="mirror">Spiegel</button>
</div>

<div class="bar">
  <div class="time" id="time">0:00</div>
  <div class="track"><div class="fill" id="fill"></div></div>
  <div class="timed" id="timed"></div>
</div>

<div class="off" id="off">Geen verbinding met de Mac</div>

<script>
(function(){
  var base = "/__TOKEN__";
  var el = function(id){ return document.getElementById(id); };
  var state = null, fails = 0, holding = false, keepAlive = null;
  function fmt(s){ s = Math.max(0, Math.floor(s||0)); var m = Math.floor(s/60), r = s%60; return m + ":" + (r<10?"0":"") + r; }
  function show(s){
    state = s;
    el("title").textContent = s.title || "Infinity Prompt";
    el("speed").textContent = Math.round(s.speed||0);
    var t = el("toggle");
    if (s.countdown != null) { t.textContent = String(s.countdown); }
    else { t.textContent = s.scrolling ? "Stop" : "Start"; }
    el("dot").className = "dot" + (s.scrolling ? " on" : "");
    el("mirror").className = "wide" + (s.mirror ? " on" : "");
    el("time").textContent = fmt(s.elapsed);
    el("hold").className = "wide hold" + ((s.holding || holding) ? " on" : "");
    el("timed").textContent = (s.timed != null && s.remaining != null) ? ("klaar in " + fmt(s.remaining)) : "";
    el("fill").style.width = (Math.max(0, Math.min(1, s.position||0))*100).toFixed(2) + "%";
  }
  function poll(){
    fetch(base + "/state", {cache:"no-store"}).then(function(r){ return r.json(); })
      .then(function(s){ fails = 0; el("off").className = "off"; show(s); })
      .catch(function(){ if (++fails > 2) el("off").className = "off show"; });
  }
  function send(cmd, b){
    b.classList.add("hit"); setTimeout(function(){ b.classList.remove("hit"); }, 120);
    if (state) {
      if (cmd === "faster") { state.speed = Math.min(100, (state.speed||0) + 1); show(state); }
      if (cmd === "slower") { state.speed = Math.max(0, (state.speed||0) - 1); show(state); }
    }
    fetch(base + "/cmd/" + cmd, {method:"POST", cache:"no-store"}).then(poll).catch(function(){});
  }
  Array.prototype.forEach.call(document.querySelectorAll("[data-cmd]"), function(b){
    b.addEventListener("click", function(e){ e.preventDefault(); send(b.getAttribute("data-cmd"), b); });
  });
  var hb = el("hold");
  function post(cmd){ return fetch(base + "/cmd/" + cmd, {method:"POST", cache:"no-store"}).catch(function(){}); }
  function holdOn(e){
    if (e) e.preventDefault();
    if (holding) return;
    holding = true; hb.className = "wide hold on";
    post("holdon");
    keepAlive = setInterval(function(){ post("holdon"); }, 4000);
  }
  function holdOff(e){
    if (e) e.preventDefault();
    if (!holding) return;
    holding = false; hb.className = "wide hold";
    if (keepAlive) { clearInterval(keepAlive); keepAlive = null; }
    post("holdoff").then(poll);
  }
  hb.addEventListener("pointerdown", holdOn);
  ["pointerup","pointercancel","pointerleave","lostpointercapture"].forEach(function(n){ hb.addEventListener(n, holdOff); });
  hb.addEventListener("contextmenu", function(e){ e.preventDefault(); });
  document.addEventListener("visibilitychange", function(){ if (document.hidden) holdOff(); });
  window.addEventListener("pagehide", function(){ holdOff(); });
  document.addEventListener("dblclick", function(e){ e.preventDefault(); }, {passive:false});
  poll(); setInterval(poll, 400);
})();
</script>
</body>
</html>
"""
}

// MARK: - Eén HTTP-verbinding

/// Minimale, veilige HTTP/1.1-afhandeling: één verzoek per verbinding, daarna dicht.
private final class HTTPConnection {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let token: String
    private var buffer = Data()
    private var finished = false
    private var timeout: DispatchWorkItem?
    private var selfRef: HTTPConnection?          // houdt zichzelf vast tot de verbinding dicht is

    private static let maxHeaderBytes = 8 * 1024
    private static let timeoutSeconds = 5.0

    init(conn: NWConnection, queue: DispatchQueue, token: String) {
        self.conn = conn
        self.queue = queue
        self.token = token
    }

    func start() {
        selfRef = self
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        timeout = work
        queue.asyncAfter(deadline: .now() + HTTPConnection.timeoutSeconds, execute: work)
        conn.start(queue: queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if self.buffer.count > HTTPConnection.maxHeaderBytes {
                self.respond(status: 431, reason: "Request Header Fields Too Large", type: "text/plain", body: Data("Te groot".utf8))
                return
            }
            if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = self.buffer.subdata(in: self.buffer.startIndex..<end.lowerBound)
                self.handle(head: head)
                return
            }
            if error != nil || isComplete {
                if self.buffer.isEmpty { self.finish() }
                else { self.respond(status: 400, reason: "Bad Request", type: "text/plain", body: Data("Ongeldig verzoek".utf8)) }
                return
            }
            self.receive()
        }
    }

    private func handle(head: Data) {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            notFound(); return
        }
        let requestLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            respond(status: 400, reason: "Bad Request", type: "text/plain", body: Data("Ongeldig verzoek".utf8))
            return
        }
        let method = String(parts[0])
        var path = String(parts[1])
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[path.startIndex..<q]) }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        guard let first = segments.first, first == token else { notFound(); return }
        let rest = Array(segments.dropFirst())

        if rest.isEmpty {
            guard method == "GET" || method == "HEAD" else { notFound(); return }
            DispatchQueue.main.async { [weak self] in
                let html = MainActor.assumeIsolated { Remote.shared.pageHTML() }
                self?.respond(status: 200, reason: "OK", type: "text/html; charset=utf-8", body: Data(html.utf8), headOnly: method == "HEAD")
            }
            return
        }
        if rest.count == 1, rest[0] == "state" {
            guard method == "GET" else { notFound(); return }
            DispatchQueue.main.async { [weak self] in
                let json = MainActor.assumeIsolated { Remote.shared.stateJSON() }
                self?.respond(status: 200, reason: "OK", type: "application/json", body: json)
            }
            return
        }
        if rest.count == 2, rest[0] == "cmd" {
            guard method == "POST" else { notFound(); return }
            let name = rest[1].lowercased()
            guard name.count <= 32 else { notFound(); return }
            DispatchQueue.main.async { [weak self] in
                let ok = MainActor.assumeIsolated { Remote.shared.runCommand(name) }
                if ok { self?.respond(status: 204, reason: "No Content", type: nil, body: Data()) }
                else { self?.notFound() }
            }
            return
        }
        notFound()
    }

    private func notFound() {
        respond(status: 404, reason: "Not Found", type: "text/plain", body: Data("Niet gevonden".utf8))
    }

    private func respond(status: Int, reason: String, type: String?, body: Data, headOnly: Bool = false) {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            var header = "HTTP/1.1 \(status) \(reason)\r\n"
            if let type { header += "Content-Type: \(type)\r\n" }
            header += "Content-Length: \(status == 204 ? 0 : body.count)\r\n"
            header += "Cache-Control: no-store\r\n"
            header += "Connection: close\r\n\r\n"
            var out = Data(header.utf8)
            if status != 204 && !headOnly { out.append(body) }
            self.conn.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.finish()
            })
        }
    }

    private func finish() {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.timeout?.cancel()
            self.timeout = nil
            self.conn.stateUpdateHandler = nil
            self.conn.cancel()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Remote.shared.connectionClosed() }
            }
            self.selfRef = nil
        }
    }
}
````

## Updater.swift

````
// Infinity Prompt, zelf bijwerken (16-11-2026). Zelfde werkwijze als Infinity Pool.
// bouw.sh zet na een build drie bestanden in iCloud Drive › Infinity Frame › Apps › Infinity Prompt:
//   Infinity Prompt.zip, Infinity Prompt.zip.sig (Ed25519 over de SHA-256 van de zip) en versie.txt ("<versie> <build>").
// De app werkt alleen bij als de build hoger is en de handtekening klopt met de sleutel in Info.plist
// (InfinityPromptUpdateKey). Geen sleutel of een foute handtekening: geen update. Niets gebeurt zonder klik.

import AppKit
import CryptoKit

@MainActor final class Updater {
    static let shared = Updater()
    private init() {}

    nonisolated static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Infinity Frame/Apps/Infinity Prompt")
    nonisolated static let zipName = "Infinity Prompt.zip"
    nonisolated static let appName = "Infinity Prompt.app"

    private var busy = false

    private var ownBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    // MARK: Contract

    /// Bij het starten: alleen iets zeggen als er een nieuwere build klaarstaat.
    func checkAtLaunch() { check(quiet: true) }

    /// Menu "Zoek naar update…": altijd een antwoord.
    func checkNow() { check(quiet: false) }

    // MARK: Kijken

    private func check(quiet: Bool) {
        guard !busy else {
            if !quiet { say("Even geduld", "Er loopt al een controle.") }
            return
        }
        busy = true
        let versionFile = Updater.folder.appendingPathComponent("versie.txt")
        DispatchQueue.global(qos: .utility).async {
            // Staat versie.txt nog alleen in de wolk, dan eerst laten ophalen (klein bestand).
            try? FileManager.default.startDownloadingUbiquitousItem(at: versionFile)
            var found: (version: String, build: Int)?
            for attempt in 0..<10 {
                found = Updater.readVersion(versionFile)
                if found != nil || quiet || attempt == 9 { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            let result = found
            DispatchQueue.main.async { self.offer(result, quiet: quiet) }
        }
    }

    nonisolated static func readVersion(_ url: URL) -> (version: String, build: Int)? {
        guard let t = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = t.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count >= 2, let b = Int(parts[1]), b > 0 else { return nil }
        return (String(parts[0]), b)
    }

    private func offer(_ found: (version: String, build: Int)?, quiet: Bool) {
        guard let found, found.build > ownBuild else {
            busy = false
            if !quiet {
                if found == nil {
                    say("Geen update gevonden", "Er staat niets klaar in iCloud Drive.")
                } else {
                    say("Je hebt de nieuwste versie", "Dit is build \(ownBuild).")
                }
            }
            return
        }
        let a = NSAlert()
        a.messageText = "Infinity Prompt \(found.version) staat klaar"
        a.informativeText = "Dit is build \(found.build). Jij hebt build \(ownBuild). Bijwerken duurt een paar seconden. Daarna start de app opnieuw."
        a.addButton(withTitle: "Bijwerken")
        a.addButton(withTitle: "Later")
        guard a.runModal() == .alertFirstButtonReturn else { busy = false; return }
        install()
    }

    // MARK: Installeren

    private func install() {
        let here = Bundle.main.bundleURL
        // Door macOS vanuit Downloads gestart: een tijdelijke plek die niet te vervangen is.
        if here.path.contains("/AppTranslocation/") {
            busy = false
            say("Zet de app eerst in Programma's", "Sleep Infinity Prompt naar de map Programma's en open hem daar. Dan kan hij zichzelf bijwerken.")
            return
        }
        let keyText = Bundle.main.object(forInfoDictionaryKey: "InfinityPromptUpdateKey") as? String
        let myBuild = ownBuild
        let myID = Bundle.main.bundleIdentifier ?? ""
        let pid = ProcessInfo.processInfo.processIdentifier

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Updater.prepare(keyText: keyText, ownBuild: myBuild, bundleID: myID)
            DispatchQueue.main.async {
                switch outcome {
                case .failure(let title, let text):
                    self.busy = false
                    self.say(title, text)
                case .ready(let newApp, let work):
                    if Updater.launchSwap(pid: pid, here: here, newApp: newApp, work: work) {
                        NSApp.terminate(nil)
                    } else {
                        self.busy = false
                        try? FileManager.default.removeItem(at: work)
                        self.say("Bijwerken lukt niet", "De app kon zichzelf niet vervangen. Je huidige versie blijft gewoon werken.")
                    }
                }
            }
        }
    }

    enum Outcome {
        case ready(newApp: URL, work: URL)
        case failure(String, String)
    }

    /// Ophalen, kopiëren, controleren en uitpakken. Draait op de achtergrond.
    nonisolated static func prepare(keyText: String?, ownBuild: Int, bundleID: String) -> Outcome {
        let fm = FileManager.default
        let zip = folder.appendingPathComponent(zipName)
        let sig = folder.appendingPathComponent(zipName + ".sig")
        let notArrived = Outcome.failure("De update is nog niet binnen", "iCloud is nog bezig. Probeer het straks opnieuw.")

        guard let keyText, !keyText.isEmpty else {
            return .failure("Update niet geïnstalleerd", "Deze versie heeft geen sleutel om updates te controleren.")
        }

        // iCloud kan een bestand als plaatshouder hebben: eerst laten ophalen, hooguit twee minuten.
        try? fm.startDownloadingUbiquitousItem(at: zip)
        try? fm.startDownloadingUbiquitousItem(at: sig)
        for _ in 0..<120 {
            if isLocal(zip) && isLocal(sig) { break }
            Thread.sleep(forTimeInterval: 1)
        }
        guard isLocal(zip), isLocal(sig) else { return notArrived }

        // Eerst kopiëren, dan controleren en uitpakken. Zo kan iCloud er tussendoor niets anders neerzetten.
        let work = fm.temporaryDirectory.appendingPathComponent("infinityprompt-update-\(UUID().uuidString.prefix(8))")
        do { try fm.createDirectory(at: work, withIntermediateDirectories: true) } catch { return notArrived }
        let zipCopy = work.appendingPathComponent(zipName)
        let sigCopy = work.appendingPathComponent(zipName + ".sig")
        guard (try? fm.copyItem(at: zip, to: zipCopy)) != nil, (try? fm.copyItem(at: sig, to: sigCopy)) != nil else {
            try? fm.removeItem(at: work)
            return notArrived
        }

        guard verify(file: zipCopy, signatureFile: sigCopy, publicKeyBase64: keyText) else {
            try? fm.removeItem(at: work)
            return .failure("Update niet geïnstalleerd", "De handtekening klopt niet. Deze update komt niet van je eigen Mac.")
        }

        let unpacked = work.appendingPathComponent("uitgepakt")
        try? fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let newApp = unpacked.appendingPathComponent(appName)
        guard run("/usr/bin/ditto", ["-x", "-k", zipCopy.path, unpacked.path]) == 0,
              fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS").path),
              let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) else {
            try? fm.removeItem(at: work)
            return .failure("De update is beschadigd", "Uitpakken lukte niet. Probeer het straks opnieuw.")
        }
        guard (info["CFBundleIdentifier"] as? String) == bundleID, !bundleID.isEmpty else {
            try? fm.removeItem(at: work)
            return .failure("Update niet geïnstalleerd", "Dit is een andere app dan Infinity Prompt.")
        }
        // De build in de app zelf telt, niet wat er in versie.txt staat.
        let newBuild = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
        guard newBuild > ownBuild else {
            try? fm.removeItem(at: work)
            return .failure("Update niet geïnstalleerd", "Deze versie is niet nieuwer dan wat je hebt.")
        }
        try? fm.removeItem(at: zipCopy)
        return .ready(newApp: newApp, work: work)
    }

    /// Klopt de handtekening (base64, Ed25519 over de SHA-256 van het bestand) met de openbare sleutel?
    nonisolated static func verify(file: URL, signatureFile: URL, publicKeyBase64: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sigText = try? String(contentsOf: signatureFile, encoding: .utf8),
              let sigData = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return false }
        return key.isValidSignature(sigData, for: Data(SHA256.hash(data: data)))
    }

    nonisolated static func isLocal(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if v?.isUbiquitousItem != true { return true }
        return v?.ubiquitousItemDownloadingStatus == .current
    }

    nonisolated static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Een klein script wacht tot de app dicht is, zet de oude opzij, de nieuwe erin, en zet bij een fout de oude terug.
    /// Paden gaan als argumenten mee, nooit in de tekst van het script.
    nonisolated static func launchSwap(pid: Int32, here: URL, newApp: URL, work: URL) -> Bool {
        let script = work.appendingPathComponent("vervang.sh")
        let text = """
        #!/bin/bash
        PID="$1"; HIER="$2"; NIEUW="$3"; WERK="$4"
        for i in $(seq 1 600); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        kill -0 "$PID" 2>/dev/null && exit 1
        [ -d "$NIEUW/Contents/MacOS" ] || exit 1
        OUD="$HIER.oud-$$"
        mv "$HIER" "$OUD" || { open "$HIER"; exit 1; }
        if mv "$NIEUW" "$HIER"; then
          rm -rf "$OUD"
        else
          rm -rf "$HIER"; mv "$OUD" "$HIER"; open "$HIER"; exit 1
        fi
        xattr -cr "$HIER" 2>/dev/null
        open "$HIER"
        rm -rf "$WERK"
        """
        guard (try? text.write(to: script, atomically: true, encoding: .utf8)) != nil else { return false }
        let p = Process()
        // Los van de app, zodat het script blijft lopen als de app stopt.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/bash", script.path, "\(pid)", here.path, newApp.path, work.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        return true
    }

    // MARK: Melden

    private func say(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
````

## StressTest.swift

````
// Stresstest: doet tijdens het scrollen duizenden keren wat de oude app liet crashen.
// Gebruik: InfinityPrompt -demo -stress   (sluit af met regel "stress: ok ..." of crasht)
import AppKit

@MainActor enum StressTest {
    static func run(acties totaal: Int = 4000) {
        let p = Prompter.shared
        var gedaan = 0
        var buiten = 0
        var generator = SystemRandomNumberGenerator()
        p.setSpeed(20)
        p.start()

        func stap() {
            // Elke stap een handvol acties, daarna krijgt de display link weer een beurt.
            for _ in 0..<8 {
                guard gedaan < totaal else { return }
                gedaan += 1
                switch Int.random(in: 0..<30, using: &generator) {
                case 0: p.faster()
                case 1: p.slower()
                case 2: p.jumpFaster()
                case 3: p.jumpSlower()
                case 4: p.setSpeed(Double.random(in: -50...500, using: &generator))
                case 5: p.toggleScrolling()
                case 6: p.reverseDirection()
                case 7: p.pageForward()
                case 8: p.pageBackward()
                case 9: p.nextCue()
                case 10: p.previousCue()
                case 11: p.biggerFont()
                case 12: p.smallerFont()
                case 13: p.toggleMirrorMain()
                case 14: p.toggleMirrorExternal()
                case 15: p.nudge(points: Double.random(in: -800...800, using: &generator))
                case 16: p.setPosition(Double.random(in: -1...2, using: &generator))
                case 17:
                    var s = p.settings
                    s.marginFraction = Double.random(in: -1...1, using: &generator)
                    s.lineSpacing = Double.random(in: 0...5, using: &generator)
                    s.cuePosition = Double.random(in: -1...2, using: &generator)
                    s.flipVertical.toggle()
                    s.countdown = Int.random(in: -3...20, using: &generator)
                    p.settings = s
                case 18:
                    // Tekst aanpassen terwijl hij loopt
                    var t = p.currentScript?.body ?? ""
                    if Bool.random(using: &generator) || t.count < 50 {
                        t += "\n# Nieuw cue-punt\nExtra regel tijdens het scrollen."
                    } else {
                        t = String(t.prefix(max(0, t.count / 2)))
                    }
                    p.updateCurrentBody(t)
                case 19:
                    if ExternalScreens.shared.isShowing { ExternalScreens.shared.closeAll() }
                    else { ExternalScreens.shared.showTestWindow(); buiten += 1 }
                case 20: p.goToStart()
                case 21: p.start()
                case 22: p.stop()
                case 23:
                    // Shift vasthouden: snelheid moet daarna precies gelijk zijn
                    let voor = p.speed
                    p.setHoldSlow(true); p.setHoldSlow(true); p.setHoldSlow(false)
                    if p.speed != voor { print("stress: FOUT shift veranderde snelheid \(voor) -> \(p.speed)"); exit(3) }
                case 24: p.setHoldSlow(Bool.random(using: &generator))
                case 25: p.setTimedDuration(Bool.random(using: &generator) ? Double.random(in: -10...600, using: &generator) : nil)
                case 26:
                    if SettingsWindow.shared.isShown { SettingsWindow.shared.close() } else { SettingsWindow.shared.show() }
                case 27:
                    var s = p.settings
                    s.floatingWindow.toggle(); s.transparentBackground.toggle()
                    s.windowOpacity = Double.random(in: -1...2, using: &generator)
                    s.cueStyle = ["lijn", "pijl", "beide", "onzin"].randomElement(using: &generator) ?? "lijn"
                    s.cueOpacity = Double.random(in: -1...2, using: &generator)
                    s.holdSlowSteps = Double.random(in: -5...20, using: &generator)
                    p.settings = s
                case 28:
                    let a = NSMutableAttributedString(string: "Vet stuk\n# Cue\nRode tekst.")
                    a.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 20), range: NSRange(location: 0, length: 3))
                    a.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 15, length: 4))
                    p.updateCurrentRich(a)
                default: p.updateCurrentBody("")
                }
                let pos = p.position
                if !(0...1).contains(pos) || pos.isNaN || !(0...100).contains(p.speed) {
                    print("stress: FOUT positie=\(pos) snelheid=\(p.speed) na \(gedaan) acties")
                    exit(2)
                }
            }
            if gedaan < totaal {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { stap() }
            } else {
                ExternalScreens.shared.closeAll()
                SettingsWindow.shared.close()
                print(String(format: "stress: ok acties=%d tweedeScherm=%d positie=%.3f snelheid=%.0f", gedaan, buiten, p.position, p.speed))
                fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            }
        }
        stap()
    }
}
````

## icoon.swift

````
// Tekent het app-icoon (1024 px). Gebruik: swift icoon.swift <uitvoer.png>
// Zwart vlak, drie tekstregels die omhoog lopen, mint cue-lijn.
import AppKit

let s: CGFloat = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func kleur(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}

kleur(0x000000).setFill()
NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
kleur(0x1C1C1E).setFill()
NSBezierPath(roundedRect: NSRect(x: 190, y: 190, width: 644, height: 644), xRadius: 110, yRadius: 110).fill()

// Tekstregels, bovenste het zwakst
let regels: [(CGFloat, CGFloat, CGFloat)] = [(640, 420, 0.25), (530, 470, 1.0), (420, 360, 0.55), (310, 300, 0.3)]
for (y, w, a) in regels {
    kleur(0xFFFFFF, a).setFill()
    NSBezierPath(roundedRect: NSRect(x: 290, y: y, width: w, height: 54), xRadius: 27, yRadius: 27).fill()
}
// Cue-lijn
kleur(0x75FA9D).setFill()
NSBezierPath(roundedRect: NSRect(x: 230, y: 552, width: 30, height: 10), xRadius: 5, yRadius: 5).fill()
NSBezierPath(roundedRect: NSRect(x: 764, y: 552, width: 30, height: 10), xRadius: 5, yRadius: 5).fill()

NSGraphicsContext.current = nil
if let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icoon.png"))
}
````

## teken.swift

````
// Infinity Prompt, updates ondertekenen (16-11-2026). Kopie van teken.swift uit Infinity Pool.
// bouw.sh geeft altijd -sleutel mee met een eigen pad voor Infinity Prompt
// (~/Library/Application Support/Infinity Frame/Infinity Prompt/update-sleutel),
// zodat deze app nooit een sleutel maakt op de plek van Infinity Pool.
// Hieronder de uitleg van het origineel (18-10-2026, op verzoek van Alex).
// De Mac die bouwt heeft een geheime sleutel (Ed25519) in ~/Library/Application Support/Infinity Frame/Infinity Pool/update-sleutel,
// alleen leesbaar voor de gebruiker, net als een SSH-sleutel. bouw.sh zet het openbare deel in de app en ondertekent
// elke zip die naar iCloud gaat. De app installeert alleen een update met een geldige handtekening.
//
// Gebruik: swift teken.swift publiek          het openbare deel (base64), maakt de sleutel als die er nog niet is
//          swift teken.swift teken <bestand>   de handtekening (base64) van het bestand

import Foundation
import CryptoKit

// 28-10-2026: één map voor alles van Infinity Pool (Infinity Frame/Infinity Pool). De sleutel van de oude plek wordt
// één keer gekopieerd (niet verplaatst: de oude blijft als reserve staan). Met -sleutel <pad> een eigen sleutel,
// voor de testbank, zodat een test nooit een echte sleutel maakt of gebruikt.
var args = CommandLine.arguments
let thuis = FileManager.default.homeDirectoryForCurrentUser
let map = thuis.appendingPathComponent("Library/Application Support/Infinity Frame/Infinity Pool")
var pad = map.appendingPathComponent("update-sleutel")
if let i = args.firstIndex(of: "-sleutel"), i + 1 < args.count {
    pad = URL(fileURLWithPath: args[i + 1]); args.removeSubrange(i...(i + 1))
} else {
    let oud = thuis.appendingPathComponent("Library/Application Support/Infinity Pool/update-sleutel")
    if !FileManager.default.fileExists(atPath: pad.path), let d = try? Data(contentsOf: oud) {
        try? FileManager.default.createDirectory(at: map, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: pad.path, contents: d, attributes: [.posixPermissions: 0o600])
    }
}

func sleutel() -> Curve25519.Signing.PrivateKey {
    if let d = try? Data(contentsOf: pad), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) { return k }
    let k = Curve25519.Signing.PrivateKey()
    try? FileManager.default.createDirectory(at: pad.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: pad.path, contents: k.rawRepresentation, attributes: [.posixPermissions: 0o600])
    return k
}

switch args.count > 1 ? args[1] : "" {
case "publiek":
    print(sleutel().publicKey.rawRepresentation.base64EncodedString())
case "teken" where args.count > 2:
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe) else { FileHandle.standardError.write(Data("kan bestand niet lezen\n".utf8)); exit(1) }
    // De hash ondertekenen: dezelfde zekerheid, zonder 100 MB door de handtekening te halen.
    let hash = Data(SHA256.hash(data: d))
    guard let sig = try? sleutel().signature(for: hash) else { exit(1) }
    print(sig.base64EncodedString())
case "controleer" where args.count > 3:
    // Voor de test: klopt de handtekening (bestand 3) bij bestand 2, met de openbare kant van deze sleutel?
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe),
          let t = try? String(contentsOfFile: args[3], encoding: .utf8),
          let s = Data(base64Encoded: t.trimmingCharacters(in: .whitespacesAndNewlines)) else { print("fout"); exit(1) }
    let goed = sleutel().publicKey.isValidSignature(s, for: Data(SHA256.hash(data: d)))
    print(goed ? "goed" : "fout"); exit(goed ? 0 : 1)
default:
    FileHandle.standardError.write(Data("gebruik: swift teken.swift [-sleutel <pad>] publiek | teken <bestand>\n".utf8)); exit(2)
}
````

## bouw.sh

````
#!/bin/bash
# Bouwt Infinity Prompt.app en zet hem in Apps/ in de vault-root, in Programma's en in iCloud (update voor de andere Mac).
# Elke geslaagde build gaat in git en naar GitHub (als er een remote is).
# Gebruik: ./bouw.sh          echte build, buildnummer +1
#          ./bouw.sh proef    alleen bouwen naar /tmp, niets bijwerken
set -e
cd "$(dirname "$0")"
HIER="$PWD"
APP="$HIER/../../../Apps/Infinity Prompt.app"
SLEUTEL="$HOME/Library/Application Support/Infinity Frame/Infinity Prompt/update-sleutel"
WOLK="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Infinity Frame/Apps/Infinity Prompt"
TMP="$(mktemp -d)"
NIEUW="$TMP/Infinity Prompt.app"
PROEF=0; [ "$1" = "proef" ] && PROEF=1

# Eerst in een tijdelijke map bouwen. Mislukt het, dan blijft de werkende app staan.
mkdir -p "$NIEUW/Contents/MacOS" "$NIEUW/Contents/Resources/nl.lproj"
BRON=(Model.swift App.swift MainWindow.swift PrompterView.swift ExternalScreen.swift Remote.swift Updater.swift StressTest.swift)
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 "${BRON[@]}" -o "$NIEUW/Contents/MacOS/InfinityPrompt"

# Icoon
swift icoon.swift "$TMP/icoon.png"
mkdir "$TMP/AppIcon.iconset"
for m in 16 32 128 256 512; do
  sips -z $m $m "$TMP/icoon.png" --out "$TMP/AppIcon.iconset/icon_${m}x${m}.png" >/dev/null
  sips -z $((m*2)) $((m*2)) "$TMP/icoon.png" --out "$TMP/AppIcon.iconset/icon_${m}x${m}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$NIEUW/Contents/Resources/AppIcon.icns"
touch "$NIEUW/Contents/Resources/nl.lproj/.gitkeep"

# Buildnummer: alleen een echte build telt.
if [ $PROEF = 0 ]; then
  B="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((B+1))" Info.plist
fi
VERSIE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)"
cp Info.plist "$NIEUW/Contents/Info.plist"
PUBLIEK="$(swift teken.swift -sleutel "$SLEUTEL" publiek 2>/dev/null || true)"
[ -n "$PUBLIEK" ] && /usr/libexec/PlistBuddy -c "Add :InfinityPromptUpdateKey string $PUBLIEK" "$NIEUW/Contents/Info.plist"
printf 'APPL????' > "$NIEUW/Contents/PkgInfo"
xattr -cr "$NIEUW"
codesign --force --sign - "$NIEUW"

if [ $PROEF = 1 ]; then
  rm -rf "/tmp/Infinity Prompt.app"; cp -R "$NIEUW" "/tmp/Infinity Prompt.app"
  echo "Proefbuild: /tmp/Infinity Prompt.app"; rm -rf "$TMP"; exit 0
fi

rm -rf "$APP"; cp -R "$NIEUW" "$APP"
echo "Gebouwd: $VERSIE (build $BUILD)"
rm -rf "/Applications/Infinity Prompt.app"; cp -R "$NIEUW" "/Applications/Infinity Prompt.app"
echo "Programma's bijgewerkt"

# Update voor de andere Mac. versie.txt komt als laatste.
if mkdir -p "$WOLK" 2>/dev/null && ditto -c -k --keepParent "$NIEUW" "$WOLK/Infinity Prompt.zip.tmp" 2>/dev/null; then
  mv -f "$WOLK/Infinity Prompt.zip.tmp" "$WOLK/Infinity Prompt.zip"
  swift teken.swift -sleutel "$SLEUTEL" teken "$WOLK/Infinity Prompt.zip" > "$WOLK/Infinity Prompt.zip.sig" || echo "Let op: update niet ondertekend" >&2
  echo "$VERSIE $BUILD" > "$WOLK/versie.txt"
  echo "In iCloud gezet voor de andere Mac"
else
  echo "Let op: kon de update niet in iCloud Drive zetten" >&2
fi

# Broncode als tekst voor de Mac Mini (Obsidian Sync neemt alleen tekst betrouwbaar mee).
{
  echo "# Infinity Prompt, broncode (build $BUILD)"
  echo
  echo "Op een andere Mac: maak de map teleprompter, zet elk blok hieronder in een bestand met die naam, en draai ./bouw.sh."
  for f in "${BRON[@]}" icoon.swift teken.swift bouw.sh Info.plist; do
    echo; echo "## $f"; echo; echo '````'; cat "$f"; echo '````'
  done
} > "Broncode (voor de andere Mac).md"

# Git en GitHub
if [ -d "$HIER/.git" ]; then
  git -C "$HIER" add -A
  git -C "$HIER" -c user.name="Alexander de Wit" -c user.email="alexander@infinityframe.nl" \
    commit -q -m "Build $BUILD ($VERSIE)" >/dev/null 2>&1 && echo "Vastgelegd in git: build $BUILD"
  if git -C "$HIER" remote get-url origin >/dev/null 2>&1; then
    GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" git -C "$HIER" push -q origin main 2>/dev/null \
      && echo "Op GitHub gezet" || echo "Let op: GitHub niet bereikt, de volgende build probeert het opnieuw" >&2
  fi
fi
rm -rf "$TMP"
````

## Info.plist

````
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>nl</string>
	<key>CFBundleDisplayName</key>
	<string>Infinity Prompt</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Tekst</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.plain-text</string>
				<string>public.rtf</string>
				<string>com.adobe.pdf</string>
				<string>org.openxmlformats.wordprocessingml.document</string>
			</array>
		</dict>
	</array>
	<key>CFBundleExecutable</key>
	<string>InfinityPrompt</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>nl.infinityframe.infinity-prompt</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>nl</string>
	</array>
	<key>CFBundleName</key>
	<string>Infinity Prompt</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>4</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSBonjourServices</key>
	<array>
		<string>_http._tcp</string>
	</array>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Om de teleprompter met je iPhone te bedienen via wifi.</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSQuitAlwaysKeepsWindows</key>
	<false/>
</dict>
</plist>
````
