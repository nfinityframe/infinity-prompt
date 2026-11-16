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

private func colorFromHex(_ hex: String, fallback: NSColor) -> NSColor {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
    guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return fallback }
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
    var countdown: Int = 3               // clamp 0...10
    var speedJump: Double = 5            // clamp 1...20
    var dragStopsScrolling: Bool = true
    var hideControlsWhileScrolling: Bool = true

    var textColor: NSColor {
        colorFromHex(textColorHex, fallback: NSColor(srgbRed: 0xE1 / 255.0, green: 0xE0 / 255.0, blue: 0xE3 / 255.0, alpha: 1))
    }
    var backgroundColor: NSColor {
        colorFromHex(backgroundColorHex, fallback: .black)
    }

    /// Returns a copy with every number inside its range. NaN and infinity fall back to defaults,
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
        return c
    }
}

extension PrompterSettings {
    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, lineSpacing, marginFraction, textColorHex, backgroundColorHex
        case mirrorMain, mirrorExternal, flipVertical, showCue, cuePosition, countdown, speedJump
        case dragStopsScrolling, hideControlsWhileScrolling
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
        self = self.clamped()
    }
}

// MARK: - Script

struct Script: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var body: String          // plain text. A line starting with "#" is a cue point
    var updated: Date
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

    var currentScript: Script? {
        guard let id = currentScriptID else { return nil }
        return scripts.first { $0.id == id }
    }

    // MARK: Mode

    @Published var isPrompterActive: Bool = false

    // MARK: Scroll state

    @Published private(set) var isScrolling: Bool = false
    @Published private(set) var countdownRemaining: Int?
    @Published private(set) var speed: Double = 20
    @Published private(set) var direction: Int = 1
    private(set) var position: Double = 0
    private(set) var elapsed: TimeInterval = 0

    var remaining: TimeInterval? {
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
    private var velocity: Double = 0                 // in speed units, eases toward speed * direction
    private var engineClock: Double = 0              // seconds of engine time, drives animations
    private var lastTickTime: CFTimeInterval?
    private var displayLink: CADisplayLink?
    private var fallbackTimer: Timer?
    private var proxy: DisplayLinkProxy?

    private struct Glide { var from: Double; var to: Double; var start: Double; var duration: Double }
    private var glide: Glide?

    private var countdownTimer: Timer?
    private var countdownToken = 0

    private var saveWorkItem: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    private let defaults = UserDefaults.standard
    private static let settingsKey = "settings"
    private static let speedKey = "speed"
    private static let currentScriptKey = "currentScriptID"

    // MARK: Init

    private init() {
        var loaded = PrompterSettings()
        if let data = UserDefaults.standard.data(forKey: Prompter.settingsKey),
           let decoded = try? JSONDecoder().decode(PrompterSettings.self, from: data) {
            loaded = decoded.clamped()
        }
        settings = loaded

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
        velocity = 0
        glide = nil
        position = 0
        elapsed = 0
        if let id = id, scripts.contains(where: { $0.id == id }) {
            currentScriptID = id
        } else {
            currentScriptID = nil
        }
        defaults.set(currentScriptID?.uuidString, forKey: Prompter.currentScriptKey)
        renderAll()
    }

    func updateCurrentBody(_ body: String) {
        guard let id = currentScriptID, let index = scripts.firstIndex(where: { $0.id == id }),
              scripts.indices.contains(index) else { return }
        guard scripts[index].body != body else { return }
        scripts[index].body = body
        scripts[index].updated = Date()
        // Position is a fraction, so it stays put when contentHeight changes.
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

    @discardableResult
    func importFile(_ url: URL) throws -> Script {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        var text: String

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
            if let attr = try? NSAttributedString(url: url, options: options, documentAttributes: nil) {
                text = attr.string
            } else if let attr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
                text = attr.string
            } else {
                throw ImportFout.nietLeesbaar(name)
            }
        case "pdf":
            guard let doc = PDFDocument(url: url) else { throw ImportFout.nietLeesbaar(name) }
            text = doc.string ?? ""
        default:
            guard let data = try? Data(contentsOf: url) else { throw ImportFout.nietLeesbaar(name) }
            if let s = String(data: data, encoding: .utf8) {
                text = s
            } else if let s = String(data: data, encoding: .isoLatin1) {
                text = s
            } else {
                throw ImportFout.nietLeesbaar(name)
            }
        }

        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportFout.geenTekst(name) }

        var title = url.deletingPathExtension().lastPathComponent
        if title.isEmpty { title = "Geïmporteerd script" }
        let script = Script(id: UUID(), title: title, body: text, updated: Date())
        scripts.insert(script, at: 0)
        select(script.id)
        scheduleSave()
        return script
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
        let seconds = settings.countdown
        if seconds > 0 {
            beginCountdown(seconds)
        } else {
            beginScrolling()
        }
    }

    func stop() {
        cancelCountdown()
        isScrolling = false   // velocity eases out on the next ticks
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
        let v = clampValue(value.rounded(), 0, 100, fallback: speed)
        guard v != speed else { return }
        speed = v
        defaults.set(v, forKey: Prompter.speedKey)
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
        // Small tolerance: just past a cue, "previous" goes to the one before it.
        if let target = cues.last(where: { $0 < base - 0.002 }) {
            glideTo(target)
        } else {
            glideTo(0)
        }
    }

    func goToStart() {
        cancelCountdown()
        isScrolling = false
        velocity = 0
        glide = nil
        position = 0
        elapsed = 0
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

    /// Advances the engine by dt seconds (clamped), then renders. Safe with or without renderers.
    func advance(by rawDt: Double) {
        let dt = clampValue(rawDt, 0, 0.1, fallback: 1.0 / 60.0)
        engineClock += dt

        // 1. Ease velocity toward the target. Speed changes only ever move this target.
        let target = isScrolling ? speed * Double(direction >= 0 ? 1 : -1) : 0
        let tau = isScrolling ? 0.25 : 0.15
        let k = dt > 0 ? 1 - exp(-dt / tau) : 0
        velocity += (target - velocity) * k
        if !velocity.isFinite { velocity = 0 }
        velocity = min(max(velocity, -100), 100)
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
            if isScrolling { elapsed += dt }

            // 3. Stop at the ends.
            if velocity > 0 && position >= 1 {
                position = 1
                stopAtEnd()
            } else if velocity < 0 && position <= 0 {
                position = 0
                stopAtEnd()
            }
        }

        // 4. Render on a copy, so renderers may register or unregister during the tick.
        renderAll()
    }

    // MARK: - Private engine helpers

    private func pointsPerSecond(forSpeed s: Double) -> Double {
        let v = s * settings.fontSize * 0.06
        return v.isFinite ? v : 0
    }

    private func setPositionClamped(_ value: Double) {
        position = clampValue(value, 0, 1, fallback: position.isFinite ? min(max(position, 0), 1) : 0)
    }

    private func stopAtEnd() {
        isScrolling = false
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

    private func loadScripts() {
        let url = Prompter.scriptsURL
        let fm = FileManager.default
        var loaded: [Script] = []
        var fileExisted = false

        if fm.fileExists(atPath: url.path) {
            fileExisted = true
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let data = try? Data(contentsOf: url), let decoded = try? decoder.decode([Script].self, from: data) {
                loaded = decoded
            } else {
                // Never overwrite a file we could not read: keep it aside.
                let stamp = Int(Date().timeIntervalSince1970)
                let backup = Prompter.dataDirectory.appendingPathComponent("scripts-onleesbaar-\(stamp).json")
                try? fm.moveItem(at: url, to: backup)
                fileExisted = false
            }
        }

        if loaded.isEmpty && !fileExisted {
            loaded = [Prompter.welcomeScript()]
            scripts = loaded
            saveScriptsNow()
        } else {
            scripts = loaded
        }

        if let raw = defaults.string(forKey: Prompter.currentScriptKey), let id = UUID(uuidString: raw),
           scripts.contains(where: { $0.id == id }) {
            currentScriptID = id
        } else {
            currentScriptID = scripts.first?.id
        }
    }

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
        do {
            try FileManager.default.createDirectory(at: Prompter.dataDirectory, withIntermediateDirectories: true)
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
        Met pijltje omhoog gaat de tekst langzamer. Met pijltje omlaag gaat hij sneller.
        Je kunt de snelheid gerust aanpassen terwijl de tekst loopt.

        # Cue-punten
        Een regel die begint met een hekje is een cue-punt, zoals deze kop.
        Met pijltje links ga je naar het vorige cue-punt, met pijltje rechts naar het volgende.
        Druk op M om de tekst te spiegelen, handig voor een prompter met glas.
        Veel succes met de opname.
        """
        return Script(id: UUID(), title: "Welkom", body: body, updated: Date())
    }
}
