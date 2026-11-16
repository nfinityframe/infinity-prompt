// Infinity Prompt, updates ondertekenen (16-11-2026). Kopie van teken.swift uit Infinity Pool.
// bouw.sh geeft altijd -sleutel mee met een eigen pad voor Infinity Prompt
// (~/Library/Application Support/Infinity Frame/Infinity Prompt/update-sleutel),
// zodat deze app nooit een sleutel maakt op de plek van Infinity Pool.
// Hieronder de uitleg van het origineel (18-10-2026, op verzoek van Alex).
// De Mac die bouwt heeft een geheime sleutel (Ed25519) in ~/Library/Application Support/Infinity Frame/Infinity Pool/update-sleutel,
// alleen leesbaar voor de gebruiker, net als een SSH-sleutel. bouw.sh zet het openbare deel in de app en ondertekent
// elke zip die naar iCloud gaat. De app installeert alleen een update met een geldige handtekening.
//
// Gebruik: swift teken.swift publiek          het openbare deel (base64), maakt de sleutel als die er nog niet is
//          swift teken.swift teken <bestand>   de handtekening (base64) van het bestand

import Foundation
import CryptoKit

// 28-10-2026: één map voor alles van Infinity Pool (Infinity Frame/Infinity Pool). De sleutel van de oude plek wordt
// één keer gekopieerd (niet verplaatst: de oude blijft als reserve staan). Met -sleutel <pad> een eigen sleutel,
// voor de testbank, zodat een test nooit een echte sleutel maakt of gebruikt.
var args = CommandLine.arguments
let thuis = FileManager.default.homeDirectoryForCurrentUser
let map = thuis.appendingPathComponent("Library/Application Support/Infinity Frame/Infinity Pool")
var pad = map.appendingPathComponent("update-sleutel")
if let i = args.firstIndex(of: "-sleutel"), i + 1 < args.count {
    pad = URL(fileURLWithPath: args[i + 1]); args.removeSubrange(i...(i + 1))
} else {
    let oud = thuis.appendingPathComponent("Library/Application Support/Infinity Pool/update-sleutel")
    if !FileManager.default.fileExists(atPath: pad.path), let d = try? Data(contentsOf: oud) {
        try? FileManager.default.createDirectory(at: map, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: pad.path, contents: d, attributes: [.posixPermissions: 0o600])
    }
}

func sleutel() -> Curve25519.Signing.PrivateKey {
    if let d = try? Data(contentsOf: pad), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) { return k }
    let k = Curve25519.Signing.PrivateKey()
    try? FileManager.default.createDirectory(at: pad.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: pad.path, contents: k.rawRepresentation, attributes: [.posixPermissions: 0o600])
    return k
}

switch args.count > 1 ? args[1] : "" {
case "publiek":
    print(sleutel().publicKey.rawRepresentation.base64EncodedString())
case "teken" where args.count > 2:
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe) else { FileHandle.standardError.write(Data("kan bestand niet lezen\n".utf8)); exit(1) }
    // De hash ondertekenen: dezelfde zekerheid, zonder 100 MB door de handtekening te halen.
    let hash = Data(SHA256.hash(data: d))
    guard let sig = try? sleutel().signature(for: hash) else { exit(1) }
    print(sig.base64EncodedString())
case "controleer" where args.count > 3:
    // Voor de test: klopt de handtekening (bestand 3) bij bestand 2, met de openbare kant van deze sleutel?
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe),
          let t = try? String(contentsOfFile: args[3], encoding: .utf8),
          let s = Data(base64Encoded: t.trimmingCharacters(in: .whitespacesAndNewlines)) else { print("fout"); exit(1) }
    let goed = sleutel().publicKey.isValidSignature(s, for: Data(SHA256.hash(data: d)))
    print(goed ? "goed" : "fout"); exit(goed ? 0 : 1)
default:
    FileHandle.standardError.write(Data("gebruik: swift teken.swift [-sleutel <pad>] publiek | teken <bestand>\n".utf8)); exit(2)
}
