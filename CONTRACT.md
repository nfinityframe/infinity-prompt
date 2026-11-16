# Infinity Prompt — contract between the source files

macOS app in Swift, built with Command Line Tools only (no Xcode):
`swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 *.swift`
Minimum macOS 14. All UI and model code runs on the main thread (`@MainActor`).

## Hard rules (the reason this app exists)
The App Store teleprompter crashes when speed or settings change while scrolling. So:
- One source of truth: `Prompter.shared`. Everything (UI, keyboard, pedal, game controller, phone) only calls its methods.
- No force unwraps (`!`), no `try!`, no unchecked array indexing. Clamp every number.
- A speed change only changes a *target*; the engine eases toward it on the next tick. Never rebuild a view, timer or display link on a speed/setting change.
- Position is a fraction 0…1, so relayout (font, margins, window size, text edits) never loses the place.
- Do not use Swift macros: no `@State`, `@Observable`, `#Preview` (the CLT lack the macro plugin). `@Published`, `@ObservedObject`, `ObservableObject` are fine. AppKit is preferred for the prompter view itself.
- All user-facing text in Dutch. No em dashes in Dutch text.

## Files and owners
| File | Owner |
|---|---|
| `Model.swift` | Agent A: settings, scripts, persistence, import, scroll engine |
| `App.swift`, `MainWindow.swift`, `PrompterView.swift`, `ExternalScreen.swift` | Agent B: all UI |
| `Remote.swift` | Agent C: keyboard/pedal, game controller, phone remote |
| `Updater.swift`, `teken.swift` | Agent D: self-update via iCloud Drive, signed |
| `StressTest.swift`, `bouw.sh`, `Info.plist`, `icoon.swift` | Coordinator |

Never edit another owner's file. If you need something from another file that is not in this contract, write it in your report instead.

## Model.swift API (Agent A implements exactly this; others rely on it)

```swift
import AppKit
import Combine

struct PrompterSettings: Codable, Equatable {
    var fontName: String = ""            // "" = system font
    var fontSize: Double = 64            // clamp 20...220
    var lineSpacing: Double = 1.3        // multiplier, clamp 1.0...2.5
    var marginFraction: Double = 0.12    // per side, clamp 0...0.4
    var textColorHex: String = "#E1E0E3"
    var backgroundColorHex: String = "#000000"
    var mirrorMain: Bool = false         // horizontal mirror in the main window
    var mirrorExternal: Bool = true      // horizontal mirror on second screens
    var flipVertical: Bool = false       // upside down, both
    var showCue: Bool = true
    var cuePosition: Double = 0.33       // fraction from top of viewport, clamp 0.1...0.9
    var countdown: Int = 3               // seconds, 0 = off, clamp 0...10
    var speedJump: Double = 5            // clamp 1...20
    var dragStopsScrolling: Bool = true
    var hideControlsWhileScrolling: Bool = true
    var textColor: NSColor { get }       // parsed from hex, safe fallback
    var backgroundColor: NSColor { get }
}

struct Script: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var body: String          // plain text. A line starting with "#" is a cue point (shown without the "#", in the accent colour)
    var updated: Date
}

@MainActor protocol PrompterRenderer: AnyObject {
    var isExternal: Bool { get }
    var contentHeight: Double { get }   // full height of laid-out text in points
    var viewportHeight: Double { get }
    var cueFractions: [Double] { get }  // sorted 0...1 positions of cue lines
    func render(position: Double)       // called every display-link tick while visible
}

@MainActor final class Prompter: ObservableObject {
    static let shared: Prompter

    // Settings: setter clamps and persists (UserDefaults, key "settings").
    @Published var settings: PrompterSettings

    // Scripts, persisted as JSON in ~/Library/Application Support/Infinity Prompt/scripts.json
    @Published private(set) var scripts: [Script]
    @Published private(set) var currentScriptID: UUID?
    var currentScript: Script? { get }
    func newScript() -> Script                     // selects it
    func select(_ id: UUID?)                        // resets position to 0, stops scrolling
    func updateCurrentBody(_ body: String)          // live edit; keeps position fraction; debounced save
    func rename(_ id: UUID, to title: String)
    func delete(_ id: UUID)
    func importFile(_ url: URL) throws -> Script    // txt, md, rtf, rtfd, docx, doc, pdf, html. Title = filename. Selects it.

    // Mode: UI sets this true while the prompter (not the editor) is in front.
    @Published var isPrompterActive: Bool

    // Scroll state
    @Published private(set) var isScrolling: Bool
    @Published private(set) var countdownRemaining: Int?   // non-nil while counting down
    @Published private(set) var speed: Double              // target speed shown to user, 0...100, step 1
    @Published private(set) var direction: Int             // +1 forward, -1 backward
    private(set) var position: Double                      // 0...1, NOT published (changes every frame)
    private(set) var elapsed: TimeInterval                  // seconds actually scrolled since last goToStart
    var remaining: TimeInterval? { get }                    // estimate at current speed, nil if speed 0

    // Commands (all safe to call at any time, any number of times, in any order)
    func toggleScrolling()        // start uses countdown if settings.countdown > 0
    func start()
    func stop()
    func faster(_ step: Double = 1)
    func slower(_ step: Double = 1)
    func jumpFaster()             // + settings.speedJump
    func jumpSlower()
    func setSpeed(_ value: Double)
    func reverseDirection()
    func pageForward()            // ~80% of lead viewport, eased
    func pageBackward()
    func nextCue()
    func previousCue()
    func goToStart()
    func nudge(points: Double)    // scroll wheel / drag. Stops scrolling if settings.dragStopsScrolling
    func setPosition(_ fraction: Double)
    func biggerFont()             // +4
    func smallerFont()            // -4
    func toggleMirrorMain()
    func toggleMirrorExternal()

    // Renderers
    func register(_ r: PrompterRenderer)
    func unregister(_ r: PrompterRenderer)
}
```

Engine: one display link owned by `Prompter` (macOS 14 `NSScreen.displayLink(target:selector:)` on the main screen, recreated only when the screen set changes; a fallback 60 Hz `Timer` is fine if no screen). Each tick: ease current velocity toward `speed * direction` (≈0.25 s time constant; stopping eases out in ≈0.15 s), convert points/second to a fraction using the *lead renderer* (first registered external renderer, else the main one) `contentHeight`, clamp 0...1, stop at the end, then call `render(position:)` on every renderer. Points per second = `speed * settings.fontSize * 0.06`, so reading pace stays the same when the font grows. Renderers are held weakly. Position semantics: fraction 0 = first line sits on the cue line, 1 = last line sits on the cue line.

## UI side (Agent B) must also provide, for the coordinator's stress test
```swift
@MainActor final class ExternalScreens {
    static let shared: ExternalScreens
    var isShowing: Bool { get }
    func showOnAllExternal()          // fullscreen window on every non-main NSScreen
    func showTestWindow()             // normal window on the main screen, acts as external renderer (for testing without a monitor)
    func closeAll()
}
```
`App.swift` handles launch arguments:
- `-demo` : load a built-in Dutch demo script with a few `#` cue lines, open the prompter.
- `-foto <pad.png>` : after ~2 s, write a PNG of the main window (`cacheDisplay`, no screen recording), print `foto: <pad>`, quit.
- `-stress` : call `StressTest.run()` (coordinator writes this) after the window is up.
- `-scroll` : start scrolling right away (with `-demo`).

## Remote.swift (Agent C) must provide
```swift
@MainActor final class Remote {
    static let shared: Remote
    func startAll()        // called once by App.swift at launch: keyboard monitor, game controller, phone server
    var phoneURL: String? { get }      // e.g. "http://192.168.1.20:8765/k7q2" (token in path), nil if not running
    func phoneQRCode(size: CGFloat) -> NSImage?
}
```

## Updater.swift (Agent D) must provide
```swift
@MainActor final class Updater {
    static let shared: Updater
    func checkAtLaunch()             // called by App.swift ~3 s after launch; quiet unless a newer signed build exists
    func checkNow()                  // menu item "Zoek naar update…"; always reports the result
}
```
Same mechanism as Infinity Pool (`../infinity-pool/`): `bouw.sh` puts `Infinity Prompt.zip`, `.zip.sig` and `versie.txt` in iCloud Drive › Infinity Frame › Apps › Infinity Prompt. Signature Ed25519, public key embedded in Info.plist by bouw.sh.

## Design direction (Alex supplied a reference, 16-11-2026)
Pure black background. Dark grey cards (about #1C1C1E, 14 pt radius), separated by tone, never by lines. White, heavy, large titles (SF Pro, bold, tight). Small letter-spaced uppercase labels in grey (like "SETS", "LAST TIME"). Each script card shows its number huge and faint in the right corner ("01", "02", about 8% white). Primary action is a white pill button with black text. Progress as thin segmented white lines. A bottom bar with a small timer, a thin progress line and pause/close icons. Mint #75FA9D only as the single accent (cue line, cue points). Few things per screen, one thing big. Motion: soft (≈280 ms spring) for transitions, fast (≈120 ms) for button feedback. Text contrast stays hard.
