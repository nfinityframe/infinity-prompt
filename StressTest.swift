// Stresstest: doet tijdens het scrollen duizenden keren wat de oude app liet crashen.
// Gebruik: InfinityPrompt -demo -stress   (sluit af met regel "stress: ok ..." of crasht)
import AppKit

@MainActor enum StressTest {
    static func run(acties totaal: Int = 4000) {
        let p = Prompter.shared
        // Nooit op de echte scripts: deze test typt en wist tekst.
        guard p.isUsingTemporaryDataFolder else {
            print("stress: geweigerd, dit is de echte datamap"); fflush(stdout); exit(4)
        }
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
                switch Int.random(in: 0..<32, using: &generator) {
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
                case 24:
                    p.setHoldSlow(Bool.random(using: &generator))
                    let voor = p.speed
                    p.setHoldFast(true); p.setHoldFast(false)
                    if p.speed != voor { print("stress: FOUT ctrl veranderde snelheid"); exit(3) }
                    p.setHoldFast(Bool.random(using: &generator))
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
                case 29: (NSApp.delegate as? AppDelegate)?.toggleEditText(nil)
                case 30:
                    let v = p.speed
                    p.backToTakeStart()
                    if p.isScrolling || p.speed != v { print("stress: FOUT terug naar begin take"); exit(3) }
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
                InvoerTest.run { exit(0) }
            }
        }
        stap()
    }
}

// Fase 2: echte toetsen, schuiven en typen, zoals Alex ze gebruikt. Gaat via de event-wachtrij,
// zodat de toetsmonitor ze ziet zoals echte toetsen.
@MainActor enum InvoerTest {
    static func toets(_ code: UInt16, _ tekens: String = "", _ mods: NSEvent.ModifierFlags = []) {
        let w = NSApp.keyWindow ?? NSApp.mainWindow
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w?.windowNumber ?? 0, context: nil, characters: tekens,
                                        charactersIgnoringModifiers: tekens, isARepeat: false, keyCode: code) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }
    static func vlag(_ code: UInt16, _ mods: NSEvent.ModifierFlags) {
        let w = NSApp.keyWindow ?? NSApp.mainWindow
        if let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: w?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: false, keyCode: code) {
            NSApp.postEvent(e, atStart: false)
        }
    }
    static func fout(_ t: String) -> Never { print("invoer: FOUT \(t)"); fflush(stdout); exit(5) }

    static func run(klaar: @escaping () -> Void) {
        let p = Prompter.shared
        NSApp.activate(ignoringOtherApps: true)
        p.updateCurrentBody("# Begin\nEen korte tekst om te typen.\n# Midden\nNog een regel.")
        p.setSpeed(20); p.start()
        var stap = 0
        let totaal = 400
        var bewaard = p.speed
        func volgende() {
            stap += 1
            if stap > totaal { typen(klaar: klaar); return }
            if !(0...1).contains(p.position) || !(0...100).contains(p.speed) { fout("positie of snelheid buiten bereik") }
            switch stap % 10 {
            case 0: if stap % 30 == 0 { toets(51, "\u{7F}") } else { toets(49, " ") }   // delete = begin take, anders spatie
            case 1: toets(126, "\u{F700}", [.function])                // pijl omhoog
            case 2: toets(125, "\u{F701}", [.function])                // pijl omlaag
            case 3: toets(126, "\u{F700}", [.function, .option])       // sprong
            case 4: bewaard = p.speed; vlag(56, NSEvent.ModifierFlags(rawValue: 0x20000 | 0x02))   // linker shift in
            case 5: vlag(56, [])                                       // shift los
            case 6: if p.isHoldingSlow { fout("shift bleef hangen") }
                    if p.speed != bewaard { fout("shift veranderde de snelheid") }
            case 7: bewaard = p.speed; vlag(60, NSEvent.ModifierFlags(rawValue: 0x20000 | 0x04))   // rechter shift in
            case 8: vlag(60, [])
            default:
                if p.isHoldingFast { fout("rechter shift bleef hangen") }
                if p.speed != bewaard { fout("rechter shift veranderde de snelheid") }
                UITestHooks.setSlider(section: Int.random(in: 0...2), row: Int.random(in: 0...3), fraction: Double.random(in: 0...1))
            }
            // Na het loslaten van Shift de wachtrij even de tijd geven voordat we controleren.
            let wacht = (stap % 10 == 5 || stap % 10 == 8) ? 0.25 : 0.012
            DispatchQueue.main.asyncAfter(deadline: .now() + wacht) { volgende() }
        }
        volgende()
    }

    static func typen(klaar: @escaping () -> Void) {
        let p = Prompter.shared
        ExternalScreens.shared.showTestWindow()
        if !UITestHooks.isEditing { (NSApp.delegate as? AppDelegate)?.toggleEditText(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard UITestHooks.isEditing, let tv = UITestHooks.editTextView() else { fout("bewerken ging niet aan") }
            tv.window?.makeFirstResponder(tv)
            let merk = "Zebrapad"
            for ch in merk { toets(0, String(ch)) }
            toets(36, "\r")                                             // return
            toets(51, "\u{7F}")                                         // backspace
            for ch in "#Nieuw" { toets(0, String(ch)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                (NSApp.delegate as? AppDelegate)?.toggleEditText(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let body = p.currentScript?.body ?? ""
                    if !body.contains(merk) { fout("getypte tekst niet bewaard: \(body.prefix(80))") }
                    if UITestHooks.isEditing { fout("bewerken bleef aan") }
                    if !(0...1).contains(p.position) { fout("positie na typen") }
                    ExternalScreens.shared.closeAll()
                    print("invoer: ok toetsen, schuiven en typen")
                    fflush(stdout)
                    klaar()
                }
            }
        }
    }
}
