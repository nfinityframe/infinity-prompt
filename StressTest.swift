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
