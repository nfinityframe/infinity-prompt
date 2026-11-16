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
