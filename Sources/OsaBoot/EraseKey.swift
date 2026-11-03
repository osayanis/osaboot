import Foundation
import CryptoKit

// L'EraseKEY : une clé qui démarre un PC sur un petit système dont le seul rôle est d'effacer
// complètement le disque qu'on choisit. Rien n'est réinstallé.
//
// Le système est ShredOS (github.com/PartialVolume/shredos.x86_64, GPL) : un Linux minuscule qui
// démarre en BIOS comme en UEFI et ouvre directement nwipe, l'outil d'effacement (choix du disque,
// méthode, vérification, rapport PDF enregistré sur la clé). OsaBoot télécharge l'image officielle,
// vérifie son empreinte, puis en adapte une copie avant de l'écrire :
// - le menu de démarrage s'appelle EraseKEY et attend 5 s au lieu de 15 ;
// - le clavier est en AZERTY (ou QWERTY) dès le démarrage ;
// - la clé elle-même est exclue de la liste des disques (deux méthodes de ShredOS à la fois) ;
// - un mode d'emploi en français est posé à la racine.
enum EraseKey {
    static let repo = "PartialVolume/shredos.x86_64"

    struct Release { let version: String; let image: URL; let sha1: URL; let name: String; let size: Int64 }

    static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.osalabs.osaboot/EraseKEY", isDirectory: true)
    }

    // MARK: Téléchargement

    /// La dernière version de ShredOS : l'image USB 64 bits « lite » et son empreinte.
    static func latest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("OsaBoot", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else {
            throw Fail("Impossible de joindre GitHub pour récupérer l'effaceur. Vérifie la connexion.")
        }
        func url(_ a: [String: Any]) -> URL? { (a["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        guard let img = assets.first(where: {
                  let n = $0["name"] as? String ?? ""
                  return n.contains("x86-64") && n.hasSuffix("_lite.img")
              }),
              let name = img["name"] as? String, let imgURL = url(img),
              let sha = assets.first(where: { $0["name"] as? String == name + ".sha1" }), let shaURL = url(sha)
        else { throw Fail("La dernière version de ShredOS n'a pas l'image attendue. Réessaie plus tard.") }
        let tag = json["tag_name"] as? String ?? ""
        // « v2025.11_32_x86-64_0.43.1 » → « 0.43.1 »
        let version = tag.split(separator: "_").last.map(String.init) ?? tag
        return Release(version: version, image: imgURL, sha1: shaURL, name: name, size: (img["size"] as? NSNumber)?.int64Value ?? 0)
    }

    /// L'image officielle, téléchargée une fois puis gardée en cache, empreinte SHA-1 vérifiée.
    static func fetch(progress: @escaping (Double) -> Void) async throws -> (url: URL, version: String) {
        let r = try await latest()
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let dest = cacheDir.appendingPathComponent(r.name)

        let (shaData, shaResp) = try await URLSession.shared.data(from: r.sha1)
        guard (shaResp as? HTTPURLResponse)?.statusCode == 200,
              let expected = String(decoding: shaData, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map({ $0.lowercased() }),
              expected.count == 40 else { throw Fail("L'empreinte de l'effaceur est introuvable.") }

        if fm.fileExists(atPath: dest.path), (try? sha1(of: dest)) == expected {
            progress(1)
            return (dest, r.version)
        }
        // les anciennes versions ne servent plus
        for old in (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: old) }

        let tmp = try await Download(progress: progress).run(r.image, to: cacheDir.appendingPathComponent(r.name + ".part"))
        guard try sha1(of: tmp) == expected else {
            try? fm.removeItem(at: tmp)
            throw Fail("L'image téléchargée ne correspond pas à son empreinte : rien n'a été écrit. Réessaie.")
        }
        try fm.moveItem(at: tmp, to: dest)
        return (dest, r.version)
    }

    static func sha1(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = Insecure.SHA1()
        while let d = try autoreleasepool(invoking: { try h.read(upToCount: 8 << 20) }), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Adaptation

    /// Copie l'image officielle et l'adapte (menu, clavier, exclusion de la clé, mode d'emploi).
    /// Rend le chemin de la copie, à écrire telle quelle sur la clé.
    static func customize(_ source: URL, keyboard: String, into dir: URL) throws -> URL {
        let fm = FileManager.default
        let out = dir.appendingPathComponent("EraseKEY.img")
        try? fm.removeItem(at: out)
        try fm.copyItem(at: source, to: out)

        let d = try Shell.plist("/usr/bin/hdiutil", ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", "-nobrowse", "-plist", out.path])
        let entities = d["system-entities"] as? [[String: Any]] ?? []
        guard let whole = entities.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count }) else {
            throw Fail("Impossible d'ouvrir l'image de l'effaceur.")
        }
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-force", whole]) }
        guard let part = entities.first(where: { ($0["content-hint"] as? String ?? "").contains("FAT") })?["dev-entry"] as? String else {
            throw Fail("L'image de l'effaceur n'a pas la partition attendue.")
        }
        let mnt = dir.appendingPathComponent("montage", isDirectory: true)
        try fm.createDirectory(at: mnt, withIntermediateDirectories: true)
        let m = try Shell.run("/usr/sbin/diskutil", ["mount", "-mountOptions", "nobrowse", "-mountPoint", mnt.path, part])
        guard m.status == 0 else { throw Fail("Impossible de monter l'image de l'effaceur : \(m.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        defer { _ = try? Shell.run("/usr/sbin/diskutil", ["unmount", "force", mnt.path]) }

        for rel in ["boot/grub/grub.cfg", "EFI/BOOT/grub.cfg"] {
            let f = mnt.appendingPathComponent(rel)
            let original = try String(contentsOf: f, encoding: .utf8)
            try grub(original, keyboard: keyboard).write(to: f, atomically: false, encoding: .utf8)
        }
        let etc = mnt.appendingPathComponent("etc/shredos", isDirectory: true)
        try fm.createDirectory(at: etc, withIntermediateDirectories: true)
        fm.createFile(atPath: etc.appendingPathComponent("shredos_exclude_disc").path, contents: Data())
        try readme.write(to: mnt.appendingPathComponent("LISEZMOI-EraseKEY.txt"), atomically: false, encoding: .utf8)
        _ = try? Shell.run("/usr/sbin/dot_clean", ["-m", mnt.path])
        for junk in [".fseventsd", ".Spotlight-V100", ".Trashes"] { try? fm.removeItem(at: mnt.appendingPathComponent(junk)) }
        sync()
        return out
    }

    /// Le menu de démarrage adapté. Chaque ligne qui lance ShredOS reçoit les options ; s'il n'y
    /// en a aucune, le format a changé et on refuse plutôt que d'écrire une clé qui s'efface elle-même.
    static func grub(_ cfg: String, keyboard: String) throws -> String {
        let options = " loadkeys=\(keyboard) shredos_exclude_boot_disc=\"yes\""
        var launches = 0
        let lines = cfg.components(separatedBy: "\n").map { line -> String in
            var l = line
            if l.contains("/boot/bzImage") {
                launches += 1
                l = l.replacingOccurrences(of: #"\s*loadkeys=\S+"#, with: "", options: .regularExpression) + options
            }
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("menuentry") {
                l = l.replacingOccurrences(of: "ShredOS (nomodeset - display issues? try this)", with: "EraseKEY - ecran noir ? essaie celui-ci")
                    .replacingOccurrences(of: "\"ShredOS\"", with: "\"EraseKEY par OsaBoot - effacer un disque\"")
            }
            if l.hasPrefix("set timeout=") { l = "set timeout=\"5\"" }
            return l
        }
        guard launches > 0 else { throw Fail("Le menu de démarrage de ShredOS a changé : OsaBoot ne sait pas encore l'adapter.") }
        return lines.joined(separator: "\n")
    }

    static let readme = """
    EraseKEY, fabriquée par OsaBoot
    ================================

    Cette clé démarre un PC sur ShredOS, un petit système dont le seul rôle est d'effacer
    complètement un disque. Rien n'est installé ni réinstallé : le disque choisi est
    entièrement réécrit, et ce qu'il contenait ne peut plus être récupéré.

    1. Branche la clé sur le PC, allume-le et choisis-la au démarrage
       (F12, F11, F8 ou Échap selon la marque). Si le Secure Boot bloque, désactive-le
       dans le BIOS le temps de l'effacement.
    2. L'outil d'effacement (nwipe) s'ouvre tout seul. La clé n'apparaît pas dans la liste.
    3. Flèches pour se déplacer, Espace pour cocher le ou les disques à effacer.
       M : méthode (PRNG Stream par défaut, Zero pour aller plus vite)
       V : vérification · R : nombre de passes
       E : effacement intégré au disque (Secure Erase), conseillé pour les SSD et NVMe
    4. Majuscule + S lance l'effacement. Il peut durer de quelques minutes à plusieurs heures.
    5. À la fin, Entrée enregistre sur cette clé le journal et un rapport PDF par disque.

    ShredOS : https://github.com/PartialVolume/shredos.x86_64 (licence GPL)
    """
}

/// Téléchargement avec avancement (URLSession ne le donne pas en async simple).
final class Download: NSObject, URLSessionDownloadDelegate {
    private let progress: (Double) -> Void
    private var dest: URL?
    private var cont: CheckedContinuation<URL, Error>?

    init(progress: @escaping (Double) -> Void) { self.progress = progress }

    func run(_ url: URL, to dest: URL) async throws -> URL {
        self.dest = dest
        return try await withCheckedThrowingContinuation { c in
            cont = c
            URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil).downloadTask(with: url).resume()
        }
    }

    private func finish(_ r: Result<URL, Error>) { cont?.resume(with: r); cont = nil }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        if t > 0 { progress(Double(w) / Double(t)) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200, let dest else {
            return finish(.failure(Fail("Le téléchargement de l'effaceur a été refusé.")))
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: loc, to: dest)
            finish(.success(dest))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
        if let e { finish(.failure(Fail("Téléchargement de l'effaceur interrompu : \(e.localizedDescription)"))) }
        s.finishTasksAndInvalidate()
    }
}
