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
