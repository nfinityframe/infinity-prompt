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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Lokale monitors lopen op de main thread.
            let handled = MainActor.assumeIsolated { Remote.shared.handleKeyDown(event) }
            return handled ? nil : event
        }
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
        guard p.isPrompterActive else { return false }
        guard !isEditingText() else { return false }
        // Een dialoog of sheet (bijvoorbeeld de updatemelding) houdt zijn eigen toetsen.
        if NSApp.modalWindow != nil { return false }
        if let w = NSApp.keyWindow, w.attachedSheet != nil || w.isSheet { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Cmd, Ctrl en Option laten we aan de menu's.
        if !flags.intersection([.command, .control, .option]).isEmpty { return false }
        let shift = flags.contains(.shift)
        let isRepeat = event.isARepeat

        // Toetscodes (zelfde op elk toetsenbord)
        switch event.keyCode {
        case 49, 36, 76:                       // spatie, return, enter
            if !isRepeat { p.toggleScrolling() }
            return true
        case 126:                              // pijl omhoog
            if shift { if !isRepeat { p.jumpSlower() } } else { p.slower() }
            return true
        case 125:                              // pijl omlaag
            if shift { if !isRepeat { p.jumpFaster() } } else { p.faster() }
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

        // Knoppen: alleen op het moment van indrukken
        pad.buttonA.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            Remote.onMain { Prompter.shared.toggleScrolling() }
        }
        pad.rightShoulder.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            Remote.onMain { Prompter.shared.jumpFaster() }
        }
        pad.leftShoulder.pressedChangedHandler = { _, _, pressed in
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

    private func controllerDisconnected(_ c: GCController?) {
        if let c, let current = controller, c !== current { return }
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
        case "bigger": p.biggerFont()
        case "smaller": p.smallerFont()
        default: return false
        }
        return true
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
        ]
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

<div class="row">
  <button class="wide" data-cmd="begin">Begin</button>
  <button class="wide" id="mirror" data-cmd="mirror">Spiegel</button>
</div>

<div class="bar">
  <div class="time" id="time">0:00</div>
  <div class="track"><div class="fill" id="fill"></div></div>
</div>

<div class="off" id="off">Geen verbinding met de Mac</div>

<script>
(function(){
  var base = "/__TOKEN__";
  var el = function(id){ return document.getElementById(id); };
  var state = null, fails = 0;
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
