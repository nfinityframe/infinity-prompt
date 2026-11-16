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
        NotificationCenter.default.addObserver(forName: .ipEditingChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyRefresher.ask() }
        }
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
                    if self?.has("-wijzig") == true {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            MainActor.assumeIsolated { self?.main?.toggleEditInPrompter() }
                        }
                    }
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
                MainActor.assumeIsolated {
                    SettingsWindow.shared.show()
                    if let v = self.value(after: "-onderdeel"), let i = Int(v) { SettingsWindow.shared.select(i) }
                }
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
                    // Edit mode: main view unmirrored while editing, mirror back after; second screen keeps its mirror.
                    var mm = p.settings
                    mm.mirrorMain = true
                    p.settings = mm
                    step(0.3) {
                        self.main?.toggleEditInPrompter()
                        step(0.3) {
                            let on = screen.prompter.isEditingText
                            print("spiegel: wijzig aan=\(on) hoofd m11=\(screen.prompter.mirrorTransform.m11) tweede m11=\(ExternalScreens.shared.testView?.mirrorTransform.m11 ?? 0)")
                            self.main?.toggleEditInPrompter()
                            step(0.3) {
                                print("spiegel: wijzig uit=\(!screen.prompter.isEditingText) hoofd m11=\(screen.prompter.mirrorTransform.m11)")
                                fflush(stdout)
                                ExternalScreens.shared.closeAll()
                                NSApp.terminate(nil)
                            }
                        }
                    }
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
    @objc func leavePrompter(_ sender: Any?) { main?.escape() }
    /// Prompter › Tekst wijzigen (⌘E). Also usable from StressTest.
    @objc func toggleEditText(_ sender: Any?) { main?.toggleEditInPrompter() }
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
    @objc func narrower(_ sender: Any?) { TextWidth.step(-0.05) }
    @objc func wider(_ sender: Any?) { TextWidth.step(0.05) }
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
            return p.currentScript != nil && (!p.isPrompterActive || main?.isEditingInPrompter == true)
        }
        if NSStringFromSelector(action) == "toggleEditText:" {
            item.title = main?.isEditingInPrompter == true ? "Klaar met wijzigen" : "Tekst wijzigen"
            return p.isPrompterActive && p.currentScript != nil
        }
        return true
    }

    private func updateBareKeys() {
        let active = Prompter.shared.isPrompterActive
        let editing = main?.isEditingInPrompter == true
        for (item, key, mods) in bareKeyItems {
            // While editing, keys type text. Only Esc (end editing) stays.
            let on = active && (!editing || key == "\u{1b}")
            item.keyEquivalent = on ? key : ""
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
        add(pr, "Tekst smaller", #selector(narrower(_:)), "[")
        add(pr, "Tekst breder", #selector(wider(_:)), "]")
        add(pr, "Tekst wijzigen", #selector(toggleEditText(_:)), "e")
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
