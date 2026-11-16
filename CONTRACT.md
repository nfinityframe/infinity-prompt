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

## Ronde 2 (16-11-2026), wishes from Alex plus Teleprompter Pro features

### Model.swift (Agent A) additions
- **Data safety first:** `PrompterSettings` and `Script` get custom `init(from:)` using `decodeIfPresent` for every field, so old saved data always loads. Never fall back to defaults on decode failure of the whole file (keep a `.bak` and refuse to overwrite instead).
- **Countdown:** default `countdown = 0`. One-time migration (UserDefaults flag `migratie-ronde2`) sets the saved countdown to 0. Countdown only happens when starting from the top (position == 0), never on resume.
- **Shift-hold slowdown:**
  - `func setHoldSlow(_ on: Bool)` and `@Published private(set) var isHoldingSlow: Bool`.
  - New setting `holdSlowSteps: Double = 2` (clamp 1...5).
  - While holding, the engine target becomes `max(0, speed - holdSlowSteps) * direction`. `speed` itself never changes, so releasing returns to exactly the old tempo, and faster()/slower() while holding move the base speed.
  - Reset the hold in stop(), goToStart(), when isPrompterActive becomes false, and on NSApplication.didResignActiveNotification.
- **Timed scrolling:**
  - `@Published var timedDuration: TimeInterval?`: nil = normal; a value = finish the script in that many seconds from the current position.
  - The engine computes the needed speed from the remaining content height each tick, and recomputes on relayout. It may exceed 0...100 internally, but `speed` (published, shown) stays clamped.
  - faster()/slower()/setSpeed() clear timedDuration. Hold-slow still works on top.
  - `func setTimedDuration(_ t: TimeInterval?)`.
- **Rich text:**
  - `Script` gets `rtf: Data?`, optional; nil = plain body.
  - `func updateCurrentRich(_ attributed: NSAttributedString)` stores the RTF and also updates `body` with the plain string, so stats, cue points and the phone remote keep working.
  - `var currentAttributed: NSAttributedString { get }` builds from rtf, or from body if nil.
  - Import keeps formatting for rtf/rtfd/docx/doc/html/odt. Strip foreground colours that are near black or too close to the background, so Word's black text does not vanish.
  - Bold, italic, underline and colour are kept; the font family and size always come from settings.
- **Colour per script:** `Script` gets `textColorHex: String?` and `backgroundColorHex: String?`. nil = global. `func effectiveTextColor` / `effectiveBackgroundColor` on Prompter for the current script, plus setters.
- **Cue indicator style:** settings `cueStyle: String = "lijn"` ("lijn" | "pijl" | "beide"), `cueColorHex: String = "#75FA9D"`, `cueOpacity: Double = 1` (clamp 0.1...1).
- **Floating window:** settings `floatingWindow: Bool = false`, `windowOpacity: Double = 1` (clamp 0.3...1, background only, text stays opaque), `transparentBackground: Bool = false`.
- **Welcome script fix:** if the stored welcome script body still says "pijltje omhoog gaat de tekst langzamer", rewrite that sentence to the new keys (see the key table below). Nothing else in his scripts changes.
- **Key table** (the welcome script must state it):

  | Key | Action |
  |---|---|
  | Space | start/stop |
  | ↑ / ↓ | faster/slower |
  | Shift held | temporarily slower, back on release |
  | ⌥↑ / ⌥↓ | speed jump |
  | ← / → | cue |
  | M | mirror |
  | Esc | back |

### Remote.swift (Agent C)
- Add `.flagsChanged` to the monitor: Shift down → `setHoldSlow(true)`, Shift up → `setHoldSlow(false)`. Covers both Shift keys. Only when isPrompterActive and not editing.
- ⇧↑/⇧↓ no longer jump; arrows with Shift behave like plain arrows. Jump moves to ⌥↑/⌥↓.
- Game controller: holding L1 = hold-slow, and the speed jump moves to R1 / the triggers' existing mapping. Keep it simple and report the mapping.
- Phone page: add a "Even trager" button that holds slow while pressed (touchstart/touchend → `/cmd/holdon`, `/cmd/holdoff`, with a safety release after 10 s without a new holdon). Add a timed-scroll display, if any.
- If a controller gets `GCController.shouldMonitorBackgroundEvents = true`, it keeps working while Zoom has focus (floating mode).

### UI (Agent B)
- **Settings become their own window** (⌘, and the gear), with a sidebar of sections:
  - Tekst (font, size, spacing, margins, colours),
  - Cue-lijn (style, colour, opacity, height),
  - Scrollen (speed jump, Shift-trager steps, countdown, timed duration, drag stops),
  - Spiegelen,
  - Venster (floating, transparency),
  - Dit script (colour per script).

  Remove the settings popover. The prompter stays visible behind it, so changes show live. Slider drags coalesce: relayout at most once per tick.
- **Editor:** a small format bar plus ⌘B, ⌘I and ⌘U, and a text colour choice. Saves via updateCurrentRich. Keep the approved layout otherwise.
- **Prompter:** renders `currentAttributed` with the font family and size from settings, keeping bold, italic, underline and colour. The `#` mint styling is display only. Draw the cue indicator by style. Apply per-script colours.
- **Floating mode:** `.floating` level, `.canJoinAllSpaces` and `.fullScreenAuxiliary`, and a background alpha from windowOpacity / transparentBackground.
- **Timed scrolling** control in the bar: tap the time to set "klaar in mm:ss".
- **Menus:** the jump moves to ⌥↑/⌥↓, plus a "Instellingen…" ⌘, item.
- **Launch arg** `-instellingen` together with `-foto` photographs the settings window.

## Ronde 5 (16-11-2026): leesband, terug naar begin take, stem volgen

### Model.swift (Agent A)
- Settings (with `decodeIfPresent`):
  - `readingBand: Bool = true`
  - `readingBandStrength: Double = 0.45` (0 = no dimming, 0.8 = strong; clamp 0...0.8)
  - `readingBandHeight: Double = 2.0` (lines of clear text around the cue line; clamp 1...6)
  - `voiceLocale: String = "nl-NL"`
- **Take start.**
  - `private(set) var takeStartPosition: Double` is set every time scrolling starts from stopped, including after the countdown.
  - `func backToTakeStart()` stops scrolling, cancels any hold, and glides to `takeStartPosition` in about 0.3 s. Speed is unchanged.
- **Voice follow.**
  - `@Published var isFollowingVoice: Bool`. While true, the engine does not advance by speed. It eases toward `voiceTarget`, a time constant of about 0.35 s, never jumping more than 1.5 viewport heights per second.
  - `func setVoiceTarget(_ fraction: Double)`: clamped. Ignores targets more than 0.5 viewport heights *behind* the current position unless called 3 times in a row with consistent values; this guards against false matches.
  - Turning voice off keeps the position.
  - Manual commands (nudge, page, cue, goToStart, backToTakeStart) still work and also reset the voice target to the new position.
- **Lead renderer access.** `var leadRenderer: PrompterRenderer? { get }`.

### PrompterRenderer protocol addition (Agent A declares it, Agent B implements it)
- `func fraction(forCharacterOffset offset: Int) -> Double?`: the position fraction that puts the line containing that character offset (into `currentScript.body`'s plain string) on the cue line.
- Provide a default extension implementation returning nil, so old conformers still compile.

### UI (Agent B)
- **Leesband.** Two static gradient overlay layers above and below the clear band around the cue line. They dim the text toward the background colour by `readingBandStrength`, with a soft edge. Never per-frame work; update only on settings or size change. Works mirrored and on the second screen.
- **Settings.**
  - Cue-lijn section: Leesband switch, Sterkte slider, Hoogte slider.
  - New "Stem" section: a "Volg mijn stem" switch, plus a status line from `Voice.shared.status`.
- **Prompter menu.**
  - "Terug naar begin take" with ⌫ (Delete) as the bare key while the prompter is active; the menu shows it.
  - "Volg mijn stem" with ⌘J.
- **Bar.**
  - A mic icon toggles voice follow.
  - While it is on, the speed number shows "STEM" and the mic is mint.
  - A small level meter from `Voice.shared.level` (0...1) is optional.
- Implement `fraction(forCharacterOffset:)` in PrompterView via the layout manager.

### Remote.swift (Agent C)
- **Keyboard.** ⌫ Delete (keyCode 51) = `backToTakeStart()`, only when the gate is open (not editing).
- **Game controller.** X / Square = backToTakeStart.
- **Phone page.**
  - "Take opnieuw" button, `/cmd/takestart`.
  - Voice toggle, `/cmd/voice`, which calls `Voice.shared.toggle()`.
  - The state JSON gains `followingVoice`.

### Voice.swift (Agent E, new file)
```swift
@MainActor final class Voice: ObservableObject {
    static let shared: Voice
    @Published private(set) var isRunning: Bool
    @Published private(set) var status: String        // Dutch, short: "Luistert", "Geen toegang tot microfoon", "Nederlands niet beschikbaar"...
    @Published private(set) var level: Double         // 0...1 mic level, for a meter
    func start()     // asks permission (mic + speech), starts recognition, sets Prompter.shared.isFollowingVoice = true
    func stop()
    func toggle()
}
```
- **Recognition.**
  - Use `SFSpeechRecognizer(locale: settings.voiceLocale)` with `requiresOnDeviceRecognition = true` when `supportsOnDeviceRecognition`, otherwise the server, with a status note.
  - Feed it from `AVAudioEngine`.
  - Restart the recognition task every ~50 s or on its end/error, seamlessly.
- **Matching.**
  - Tokenize the script body once per `textVersion` into normalized words: lowercase, no punctuation or diacritics, plus each word's character offset. Ignore `#` cue lines.
  - On each partial result, take the last 3–5 spoken words and search a window ahead of the current spoken index (about 60 words ahead, 10 behind), with a fuzzy match (small edit distance).
  - Advance the spoken index on a confident match only.
  - Convert it to a fraction via `Prompter.shared.leadRenderer?.fraction(forCharacterOffset:)` and call `setVoiceTarget`.
- Voice stops cleanly on: stop(), the prompter becoming inactive, script select, and app quit.
- No crash without a mic, without permission, or with an empty script.
- Dutch user text, no em dashes.
- For tests, include a pure function `static func match(spoken: [String], in words: [String], from index: Int) -> Int?` so it can be unit-tested without audio.
