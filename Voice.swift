import Foundation
import AppKit
import AVFoundation
import Speech
import Combine

// Voice follow: the script follows the speaker's voice.
// Speech framework fed by AVAudioEngine. Matching is a pure function (Voice.match) so it can be
// tested without audio. All state lives on the main actor; only the audio tap and the recognizer
// callbacks run elsewhere, and they hop back to the main actor straight away.

/// Thread-safe holder between the audio tap (audio thread) and the main actor.
private final class VoiceTapBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var smoothed: Double = 0
    private var lastPublish: CFTimeInterval = 0

    func setRequest(_ newValue: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        request = newValue
        lock.unlock()
    }

    func reset() {
        lock.lock()
        request = nil
        smoothed = 0
        lastPublish = 0
        lock.unlock()
    }

    /// Feeds the buffer to the current request and returns a smoothed level when it is time to publish (about 20 per second).
    func process(_ buffer: AVAudioPCMBuffer) -> Double? {
        var rms: Double = 0
        let frames = Int(buffer.frameLength)
        if frames > 0, let channels = buffer.floatChannelData {
            let data = channels[0]
            var sum: Float = 0
            for i in 0..<frames {
                let v = data[i]
                sum += v * v
            }
            rms = Double(sqrt(sum / Float(frames)))
        }
        var level: Double = 0
        if rms.isFinite, rms > 0 {
            let db = 20 * log10(rms)
            level = min(max((db + 50) / 45, 0), 1)
        }
        lock.lock()
        defer { lock.unlock() }
        request?.append(buffer)
        smoothed += (level - smoothed) * (level > smoothed ? 0.5 : 0.15)
        let now = CACurrentMediaTime()
        if now - lastPublish >= 0.05 {
            lastPublish = now
            return smoothed
        }
        return nil
    }
}

@MainActor final class Voice: ObservableObject {
    static let shared = Voice()

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var status: String = "Uit"
    @Published private(set) var level: Double = 0

    // Audio and recognition
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let box = VoiceTapBox()
    private var preferOnDevice = true
    private var usingServer = false
    private var generation = 0
    private var taskStartedAt = Date()
    private var restartAt: Date?
    private var consecutiveErrors = 0
    private var tickTask: Task<Void, Never>?
    private var configObserver: AnyCancellable?

    // Start bookkeeping
    private var isStarting = false
    private var startToken = 0

    // Matching state
    private var tokens: [(word: String, offset: Int)] = []
    private var tokenWords: [String] = []
    private var tokenVersion: Int = -1
    private var tokenScriptID: UUID?
    private var spokenIndex = 0
    private var lastSpoken: [String] = []
    private var observedTarget: Double?

    private var subscriptions = Set<AnyCancellable>()

    private init() {
        let p = Prompter.shared
        p.$isPrompterActive
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] active in
                guard let self = self, !active, self.isRunning || self.isStarting else { return }
                self.stop()
            }
            .store(in: &subscriptions)
        p.$currentScriptID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self, self.isRunning || self.isStarting else { return }
                self.stop()
            }
            .store(in: &subscriptions)
        // Keeps the model flag and the recognizer in step when someone flips the flag directly.
        p.$isFollowingVoice
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)   // @Published fires in willSet; act after the change
            .sink { [weak self] on in
                guard let self = self else { return }
                if on, !self.isRunning, !self.isStarting {
                    self.start()
                } else if !on, self.isRunning || self.isStarting {
                    self.stop()
                }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                guard let self = self, self.isRunning || self.isStarting else { return }
                self.stop()
            }
            .store(in: &subscriptions)
    }

    // MARK: Public API

    func toggle() {
        if isRunning || isStarting { stop() } else { start() }
    }

    /// Asks permission (speech and microphone), starts recognition and turns voice follow on.
    func start() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        startToken &+= 1
        let token = startToken
        status = "Toegang vragen"
        Task { @MainActor [weak self] in
            let speech = await Voice.speechAuthorization()
            guard let self = self, self.startToken == token, self.isStarting else { return }
            guard speech else {
                self.fail("Geen toegang tot spraakherkenning")
                return
            }
            let mic = await Voice.microphoneAccess()
            guard self.startToken == token, self.isStarting else { return }
            guard mic else {
                self.fail("Geen toegang tot microfoon")
                return
            }
            self.beginListening()
        }
    }

    func stop() {
        stop(status: "Gestopt")
    }

    // MARK: Start and stop

    private func fail(_ message: String) {
        stop(status: message)
    }

    private func stop(status message: String) {
        startToken &+= 1
        isStarting = false
        tickTask?.cancel()
        tickTask = nil
        configObserver = nil
        restartAt = nil
        box.reset()
        generation &+= 1
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        recognizer = nil
        teardownAudio()
        isRunning = false
        level = 0
        lastSpoken = []
        observedTarget = nil
        if Prompter.shared.isFollowingVoice { Prompter.shared.isFollowingVoice = false }
        status = message
    }

    private func beginListening() {
        let p = Prompter.shared
        let identifier = p.settings.voiceLocale.trimmingCharacters(in: .whitespacesAndNewlines)
        let locale = Locale(identifier: identifier.isEmpty ? "nl-NL" : identifier)
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            fail(identifier.lowercased().hasPrefix("nl") || identifier.isEmpty ? "Nederlands niet beschikbaar" : "Taal niet beschikbaar")
            return
        }
        recognizer = rec
        preferOnDevice = true
        consecutiveErrors = 0
        guard startAudio() else { return }   // startAudio reports its own failure
        isStarting = false
        isRunning = true
        tokenVersion = -1          // re-tokenize and re-anchor at the current position
        ensureTokens()
        beginTask()
        observedTarget = nil
        if !p.isFollowingVoice { p.isFollowingVoice = true }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.tick()
            }
        }
    }

    /// Creates the engine, installs the tap and starts it. On failure it stops with a status and returns false.
    private func startAudio() -> Bool {
        teardownAudio()
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("Geen microfoon gevonden")
            return false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Voice.makeTap(box: box))
        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            fail("Microfoon start niet")
            return false
        }
        engine = newEngine
        configObserver = NotificationCenter.default
            .publisher(for: .AVAudioEngineConfigurationChange, object: newEngine)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.audioConfigurationChanged() }
        return true
    }

    private func teardownAudio() {
        configObserver = nil
        guard let e = engine else { return }
        e.inputNode.removeTap(onBus: 0)
        if e.isRunning { e.stop() }
        engine = nil
    }

    /// Microphone switched or unplugged: rebuild the audio side, keep the recognition task.
    private func audioConfigurationChanged() {
        guard isRunning else { return }
        if startAudio() {
            status = usingServer ? "Luistert via internet" : "Luistert"
        }
    }

    // MARK: Recognition task

    private func beginTask() {
        guard isRunning, let rec = recognizer else { return }
        generation &+= 1
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation
        newRequest.addsPunctuation = false
        if preferOnDevice && rec.supportsOnDeviceRecognition {
            newRequest.requiresOnDeviceRecognition = true
            usingServer = false
        } else {
            usingServer = true
        }
        let oldRequest = request
        let oldTask = task
        // New request first, so no audio is lost between the two tasks.
        box.setRequest(newRequest)
        request = newRequest
        task = rec.recognitionTask(with: newRequest, resultHandler: Voice.makeResultHandler(generation: generation))
        oldRequest?.endAudio()
        oldTask?.cancel()
        taskStartedAt = Date()
        restartAt = nil
        lastSpoken = []
        status = usingServer ? "Luistert via internet" : "Luistert"
    }

    private func tick() {
        guard isRunning else { return }
        let now = Date()
        if let at = restartAt {
            if now >= at { beginTask() }
        } else if now.timeIntervalSince(taskStartedAt) >= 50 {
            beginTask()
        }
    }

    fileprivate func handleResult(generation gen: Int, text: String?, isFinal: Bool, errorDomain: String?, errorCode: Int) {
        guard isRunning, gen == generation else { return }
        if let text = text {
            let spoken = Voice.normalizedWords(text)
            if !spoken.isEmpty {
                consecutiveErrors = 0
                if restartAt == nil { status = usingServer ? "Luistert via internet" : "Luistert" }
                follow(spoken)
            }
        }
        guard isFinal || errorDomain != nil else { return }
        // The task has ended. Silence ("no speech", kAFAssistantErrorDomain 1110) is not a real error.
        let silence = errorDomain == "kAFAssistantErrorDomain" && (errorCode == 1110 || errorCode == 203)
        // A task that ends within a second also counts, so a fast failure never loops without backoff.
        let quick = Date().timeIntervalSince(taskStartedAt) < 1
        if (errorDomain != nil && !silence) || quick {
            consecutiveErrors += 1
        }
        if consecutiveErrors >= 3 && preferOnDevice {
            preferOnDevice = false   // on-device keeps failing: try the server
        }
        box.setRequest(nil)
        if consecutiveErrors == 0 {
            beginTask()
        } else {
            let delay = min(0.5 * pow(2, Double(consecutiveErrors - 1)), 15)
            restartAt = Date().addingTimeInterval(delay)
            status = consecutiveErrors >= 4 ? "Spraakherkenning hapert, probeert opnieuw" : "Opnieuw verbinden"
        }
    }

    fileprivate func publishLevel(_ value: Double) {
        guard isRunning, value.isFinite else { return }
        level = min(max(value, 0), 1)
    }

    // MARK: Following

    private func ensureTokens() {
        let p = Prompter.shared
        guard tokenVersion != p.textVersion || tokenScriptID != p.currentScriptID else { return }
        tokenVersion = p.textVersion
        tokenScriptID = p.currentScriptID
        tokens = Voice.tokenize(p.currentScript?.body ?? "", skipCueLines: true)
        tokenWords = tokens.map { $0.word }
        reanchor(at: p.position)
    }

    private func follow(_ spoken: [String]) {
        guard spoken != lastSpoken else { return }
        lastSpoken = spoken
        ensureTokens()
        guard !tokenWords.isEmpty else { return }
        checkManualJump()
        guard let index = Voice.match(spoken: Array(spoken.suffix(5)), in: tokenWords, from: spokenIndex) else { return }
        spokenIndex = index
        let p = Prompter.shared
        guard let f = p.leadRenderer?.fraction(forCharacterOffset: tokens[index].offset), f.isFinite else { return }
        p.setVoiceTarget(f)
        observedTarget = p.voiceTarget
    }

    /// A manual command resets the model's voice target; a big drag moves the position away from the spoken index.
    private func checkManualJump() {
        let p = Prompter.shared
        if let observed = observedTarget, abs(p.voiceTarget - observed) > 1e-6 {
            reanchor(at: p.voiceTarget)
            observedTarget = p.voiceTarget
            return
        }
        guard let viewport = viewportFraction(),
              spokenIndex >= 0, spokenIndex < tokens.count,
              let f = p.leadRenderer?.fraction(forCharacterOffset: tokens[spokenIndex].offset) else { return }
        let settled = abs(p.position - p.voiceTarget) < viewport * 0.1
        if settled && abs(p.position - f) > viewport * 1.5 {
            reanchor(at: p.position)
        }
    }

    /// Sets the spoken index to the first word of the line on the cue line at `fraction`.
    private func reanchor(at fraction: Double) {
        guard !tokens.isEmpty else { spokenIndex = 0; return }
        guard let lead = Prompter.shared.leadRenderer, fraction.isFinite else { spokenIndex = 0; return }
        let epsilon = (viewportFraction() ?? 0.02) * 0.05
        var lo = 0
        var hi = tokens.count
        while lo < hi {
            let mid = (lo + hi) / 2
            guard let f = lead.fraction(forCharacterOffset: tokens[mid].offset) else { spokenIndex = 0; return }
            if f < fraction - epsilon { lo = mid + 1 } else { hi = mid }
        }
        spokenIndex = max(0, min(lo, tokens.count - 1) - 1)
    }

    private func viewportFraction() -> Double? {
        guard let lead = Prompter.shared.leadRenderer else { return nil }
        let h = lead.contentHeight
        let v = lead.viewportHeight
        guard h.isFinite, v.isFinite, h > 0, v > 0 else { return nil }
        return v / h
    }

    // MARK: Callbacks (not main-actor isolated; they hop back)

    nonisolated private static func makeTap(box: VoiceTapBox) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            if let value = box.process(buffer) {
                Task { @MainActor in Voice.shared.publishLevel(value) }
            }
        }
    }

    nonisolated private static func makeResultHandler(generation: Int) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let ns = error.map { $0 as NSError }
            let domain = ns?.domain
            let code = ns?.code ?? 0
            Task { @MainActor in
                Voice.shared.handleResult(generation: generation, text: text, isFinal: isFinal, errorDomain: domain, errorCode: code)
            }
        }
    }

    nonisolated private static func speechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        @unknown default: return false
        }
    }

    nonisolated private static func microphoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    // MARK: Text (pure, testable)

    /// Lowercase, no diacritics, letters and digits only.
    nonisolated static func normalize(_ word: String) -> String {
        let folded = word.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "nl_NL"))
        return String(folded.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Normalized words with their UTF-16 offset into `body`. Lines starting with "#" are skipped when asked.
    nonisolated static func tokenize(_ body: String, skipCueLines: Bool) -> [(word: String, offset: Int)] {
        var out: [(word: String, offset: Int)] = []
        var offset = 0                 // UTF-16 offset of the current character
        var lineStart = true
        var skipLine = false
        var current = ""
        var currentStart = 0
        func flush() {
            if !current.isEmpty {
                let n = normalize(current)
                if !n.isEmpty { out.append((n, currentStart)) }
            }
            current = ""
        }
        for ch in body {
            let width = ch.utf16.count
            if ch.isNewline {
                flush()
                lineStart = true
                skipLine = false
                offset += width
                continue
            }
            if lineStart && !ch.isWhitespace {
                lineStart = false
                skipLine = skipCueLines && ch == "#"
            }
            if !skipLine {
                if ch.isLetter || ch.isNumber {
                    if current.isEmpty { currentStart = offset }
                    current.append(ch)
                } else if (ch == "'" || ch == "\u{2019}") && !current.isEmpty {
                    // zo'n, auto's: the apostrophe stays inside the word and is dropped by normalize
                } else {
                    flush()
                }
            }
            offset += width
        }
        flush()
        return out
    }

    /// Normalized words of a transcription.
    nonisolated static func normalizedWords(_ text: String) -> [String] {
        tokenize(text, skipCueLines: false).map { $0.word }
    }

    /// Fuzzy word equality: exact up to 3 letters, then 1 edit up to 7 letters, 2 up to 11, 3 beyond.
    nonisolated static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a.unicodeScalars)
        let y = Array(b.unicodeScalars)
        let longest = max(x.count, y.count)
        let tolerance = longest <= 3 ? 0 : (longest <= 7 ? 1 : (longest <= 11 ? 2 : 3))
        guard tolerance > 0, min(x.count, y.count) >= 3, abs(x.count - y.count) <= tolerance else { return false }
        var previous = Array(0...y.count)
        var row = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            row[0] = i
            var rowMin = row[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, row[j])
            }
            if rowMin > tolerance { return false }
            swap(&previous, &row)
        }
        return previous[y.count] <= tolerance
    }

    /// Finds where the last spoken words are in the script. Returns the index of the script word that
    /// matches the newest spoken word, or nil when not confident. Searches 10 words behind to 60 ahead of `index`.
    /// If the newest word itself is not found (often still being revised), it retries without it.
    nonisolated static func match(spoken: [String], in words: [String], from index: Int) -> Int? {
        let clean = spoken.filter { !$0.isEmpty }
        let tail = Array(clean.suffix(5))
        if let hit = matchTail(tail, in: words, from: index) { return hit }
        if tail.count >= 4, let hit = matchTail(Array(tail.dropLast()), in: words, from: index) { return hit }
        return nil
    }

    nonisolated private static func matchTail(_ s: [String], in words: [String], from index: Int) -> Int? {
        let k = s.count
        guard k >= 2, !words.isEmpty else { return nil }
        let from = min(max(index, 0), words.count - 1)
        let lo = max(0, from - 10)
        let hi = min(words.count - 1, from + 60)
        let required = max(2, Int((Double(k) * 2.0 / 3.0).rounded(.up)))
        let head = Array(s.dropLast())
        var best: (score: Double, index: Int)?
        for e in lo...hi {
            guard similar(s[k - 1], words[e]) else { continue }
            // Fuzzy LCS between the earlier spoken words and up to k+1 script words before e.
            // That allows dropped words on either side. Ties go to the alignment with more letters.
            let start = max(0, e - (k + 1))
            let segment = Array(words[start..<e])
            let n = head.count
            let m = segment.count
            var count = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
            var chars = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
            if n > 0 && m > 0 {
                for i in 1...n {
                    for j in 1...m {
                        var c = count[i - 1][j]
                        var l = chars[i - 1][j]
                        if count[i][j - 1] > c || (count[i][j - 1] == c && chars[i][j - 1] > l) {
                            c = count[i][j - 1]
                            l = chars[i][j - 1]
                        }
                        if similar(head[i - 1], segment[j - 1]) {
                            let dc = count[i - 1][j - 1] + 1
                            let dl = chars[i - 1][j - 1] + segment[j - 1].count
                            if dc > c || (dc == c && dl > l) {
                                c = dc
                                l = dl
                            }
                        }
                        count[i][j] = c
                        chars[i][j] = l
                    }
                }
            }
            let matches = 1 + count[n][m]
            let letters = words[e].count + chars[n][m]
            guard matches >= required else { continue }
            // Short common words ("de en", "in het") alone are never enough.
            guard matches >= 4 || letters >= 8 else { continue }
            // Going back needs every word to agree.
            if e < from && matches < k { continue }
            let penalty = e >= from ? Double(e - from) * 0.04 : 0.5 + Double(from - e) * 0.1
            let score = Double(matches) - penalty
            if best == nil || score > (best?.score ?? -Double.infinity) {
                best = (score, e)
            }
        }
        return best?.index
    }
}
