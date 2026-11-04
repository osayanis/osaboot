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
    /// Version de ShredOS testée avec l'interface EraseKEY (son lanceur est retouché par
    /// erasekey/build-overlay.sh, qui doit viser la même).
    static let tag = "v2025.11_32_x86-64_0.43.1"

    /// L'interface EraseKEY (erasekey/, Go) et le lanceur retouché, en initrd ajouté au noyau.
    static var overlay: URL? {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("erasekey-overlay.cpio.gz"),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("erasekey-overlay.cpio.gz"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/erasekey-overlay.cpio.gz")]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    struct Release { let version: String; let image: URL; let sha1: URL; let name: String; let size: Int64 }

    static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.osalabs.osaboot/EraseKEY", isDirectory: true)
    }

    // MARK: Téléchargement

    /// La dernière version de ShredOS : l'image USB 64 bits « lite » et son empreinte.
    static func latest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/tags/\(tag)")!)
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
    // MARK: Image « standard »
    //
    // L'image de ShredOS a une partition non alignée (secteur 1263) et un FAT32 fait sur Linux
    // (secteurs cachés à 0, partition non « active »). Certains PC (Dell Latitude 5175…) ne la
    // voient pas du tout en UEFI. On refait donc une image comme celles de Rufus ou de Windows :
    // partition active au secteur 2048, FAT32 formaté par macOS, mêmes fichiers. Le code de
    // démarrage BIOS de GRUB (MBR + secteurs avant la partition) est gardé tel quel : il désigne
    // la partition par son numéro, pas par sa position, donc il marche toujours.

    static let partStart = 2048
    static let partSectors = 160 * 2048   // 160 Mio : ShredOS (~100 Mio) + place pour les rapports

    /// Adresse CHS (255 têtes, 63 secteurs) d'un secteur, pour la table MBR ; FE FF FF au-delà.
    static func chs(_ lba: Int) -> [UInt8] {
        let c = lba / (255 * 63), h = (lba / 63) % 255, sec = lba % 63 + 1
        guard c < 1024 else { return [0xFE, 0xFF, 0xFF] }
        return [UInt8(h), UInt8(sec | ((c >> 8) << 6)), UInt8(c & 0xFF)]
    }

    static func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }

    /// Attache une image disque sans la monter ; renvoie (disque entier, première partition).
    static func attach(_ url: URL, readOnly: Bool = false) throws -> (whole: String, part: String) {
        var args = ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", "-nobrowse", "-plist"]
        if readOnly { args.append("-readonly") }
        let d = try Shell.plist("/usr/bin/hdiutil", args + [url.path])
        let devs = (d["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["dev-entry"] as? String }
        guard let whole = devs.min(by: { $0.count < $1.count }) else { throw Fail("Impossible d'ouvrir l'image de l'effaceur.") }
        guard let part = devs.filter({ $0 != whole }).sorted().first else {
            _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-force", whole])
            throw Fail("L'image de l'effaceur n'a pas la partition attendue.")
        }
        return (whole, part)
    }

    static func mount(_ part: String, at dir: URL, readOnly: Bool = false) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var args = ["mount"]
        if readOnly { args.append("readOnly") }
        let m = try Shell.run("/usr/sbin/diskutil", args + ["-mountOptions", "nobrowse", "-mountPoint", dir.path, part])
        guard m.status == 0 else { throw Fail("Impossible de monter l'image de l'effaceur : \(m.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    static func buildStandard(from source: URL, to out: URL, work dir: URL) throws {
        let fm = FileManager.default
        // 1. MBR et code de démarrage BIOS repris de ShredOS, nouvelle table de partitions
        let src = try FileHandle(forReadingFrom: source)
        let head = try src.read(upToCount: partStart * 512) ?? Data()
        try src.close()
        guard head.count == partStart * 512, head[510] == 0x55, head[511] == 0xAA else {
            throw Fail("L'image de l'effaceur n'a pas de table de partitions MBR.")
        }
        let oldStart = Int(head[454]) | Int(head[455]) << 8 | Int(head[456]) << 16 | Int(head[457]) << 24
        guard oldStart > 1, oldStart <= partStart else { throw Fail("L'image de l'effaceur n'a pas la forme attendue.") }
        var lead = [UInt8](head.prefix(oldStart * 512)) + [UInt8](repeating: 0, count: (partStart - oldStart) * 512)
        let entry: [UInt8] = [0x80] + chs(partStart) + [0x0C] + chs(partStart + partSectors - 1) + le32(partStart) + le32(partSectors)
        lead.replaceSubrange(446..<510, with: entry + [UInt8](repeating: 0, count: 48))
        try? fm.removeItem(at: out)
        guard fm.createFile(atPath: out.path, contents: Data(lead)) else { throw Fail("Impossible de créer l'image de l'EraseKEY.") }
        let h = try FileHandle(forWritingTo: out)
        try h.truncate(atOffset: UInt64(partStart + partSectors) * 512)
        try h.close()

        // 2. FAT32 propre, fait par macOS (clusters de 512 octets comme l'original)
        let new = try attach(out)
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-force", new.whole]) }
        let raw = new.part.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        let f = try Shell.run("/sbin/newfs_msdos", ["-F", "32", "-c", "1", "-v", "SHREDOS", raw])
        guard f.status == 0 else { throw Fail("Le formatage de l'EraseKEY a échoué : \(f.err.trimmingCharacters(in: .whitespacesAndNewlines))") }

        // 3. les fichiers de ShredOS
        let old = try attach(source, readOnly: true)
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-force", old.whole]) }
        let from = dir.appendingPathComponent("source", isDirectory: true), to = dir.appendingPathComponent("cle", isDirectory: true)
        try mount(old.part, at: from, readOnly: true)
        defer { _ = try? Shell.run("/usr/sbin/diskutil", ["unmount", "force", from.path]) }
        try mount(new.part, at: to)
        defer { _ = try? Shell.run("/usr/sbin/diskutil", ["unmount", "force", to.path]) }
        let c = try Shell.run("/usr/bin/ditto", ["--norsrc", "--noextattr", "--noqtn", "--noacl", from.path, to.path])
        guard c.status == 0 else { throw Fail("La copie de ShredOS a échoué : \(c.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        for junk in [".fseventsd", ".Spotlight-V100", ".Trashes"] { try? fm.removeItem(at: to.appendingPathComponent(junk)) }
        sync()
    }

    static func customize(_ source: URL, keyboard: String, into dir: URL) throws -> URL {
        let fm = FileManager.default
        let out = dir.appendingPathComponent("EraseKEY.img")
        try? fm.removeItem(at: out)
        try buildStandard(from: source, to: out, work: dir)

        let disk = try attach(out)
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-force", disk.whole]) }
        let mnt = dir.appendingPathComponent("montage", isDirectory: true)
        try mount(disk.part, at: mnt)
        defer { _ = try? Shell.run("/usr/sbin/diskutil", ["unmount", "force", mnt.path]) }

        // l'interface EraseKEY ; sans elle (build de développement), c'est l'écran de nwipe
        let ui = overlay
        if let ui { try fm.copyItem(at: ui, to: mnt.appendingPathComponent("boot/osa.cpio.gz")) }
        for rel in ["boot/grub/grub.cfg", "EFI/BOOT/grub.cfg"] {
            let f = mnt.appendingPathComponent(rel)
            let original = try String(contentsOf: f, encoding: .utf8)
            try grub(original, keyboard: keyboard, overlay: ui != nil).write(to: f, atomically: false, encoding: .utf8)
        }
        let etc = mnt.appendingPathComponent("etc/shredos", isDirectory: true)
        try fm.createDirectory(at: etc, withIntermediateDirectories: true)
        fm.createFile(atPath: etc.appendingPathComponent("shredos_exclude_disc").path, contents: Data())
        try (ui != nil ? readme : readmeNwipe).write(to: mnt.appendingPathComponent("LISEZMOI-EraseKEY.txt"), atomically: false, encoding: .utf8)
        _ = try? Shell.run("/usr/sbin/dot_clean", ["-m", mnt.path])
        for junk in [".fseventsd", ".Spotlight-V100", ".Trashes"] { try? fm.removeItem(at: mnt.appendingPathComponent(junk)) }
        sync()
        return out
    }

    /// Le menu de démarrage adapté. Chaque ligne qui lance ShredOS reçoit les options ; s'il n'y
    /// en a aucune, le format a changé et on refuse plutôt que d'écrire une clé qui s'efface elle-même.
    static func grub(_ cfg: String, keyboard: String, overlay: Bool = false) throws -> String {
        let options = " loadkeys=\(keyboard) shredos_exclude_boot_disc=\"yes\""
        var launches = 0
        let lines = cfg.components(separatedBy: "\n").map { line -> String in
            var l = line
            if l.contains("/boot/bzImage") {
                launches += 1
                l = l.replacingOccurrences(of: #"\s*loadkeys=\S+"#, with: "", options: .regularExpression) + options
                // l'initrd d'OsaBoot, chargé après le système de ShredOS : ses fichiers priment
                if overlay {
                    let indent = String(l.prefix { $0 == " " || $0 == "\t" })
                    l += "\n" + indent + "initrd /boot/osa.cpio.gz"
                }
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

    Cette clé démarre un PC sur un petit système dont le seul rôle est d'effacer
    complètement un disque. Rien n'est installé ni réinstallé : le disque choisi est
    entièrement réécrit, et ce qu'il contenait ne peut plus être récupéré.

    1. Branche la clé sur le PC, allume-le et choisis-la au démarrage
       (F12, F11, F8 ou Échap selon la marque). Si le Secure Boot bloque, désactive-le
       dans le BIOS le temps de l'effacement.
    2. L'écran EraseKEY s'ouvre tout seul et liste les disques du PC. Cette clé n'est
       jamais proposée.
    3. Flèches pour choisir le disque (Espace pour en cocher plusieurs), Entrée.
    4. Choisis la méthode : Conseillée (aléatoire, remise à zéro, relecture),
       Rapide (zéros, relecture) ou Renforcée (trois passes DoD).
    5. Tape EFFACER pour confirmer. L'effacement peut durer de quelques minutes à
       plusieurs heures : laisse le PC allumé et la clé branchée.
    6. À la fin, le journal et un rapport PDF par disque sont enregistrés sur cette clé.
       E éteint le PC, R le redémarre, Entrée pour effacer un autre disque.

    Besoin des réglages avancés ? La console Alt+F2 donne accès à nwipe, hdparm et
    nvme-cli (effacement intégré des SSD et NVMe).

    Interface EraseKEY : OsaLabs (code public, github.com/osayanis/osaboot).
    Système et moteur d'effacement : ShredOS et nwipe (licence GPL),
    https://github.com/PartialVolume/shredos.x86_64
    """

    /// Mode d'emploi quand l'interface EraseKEY n'est pas incluse (écran de nwipe).
    static let readmeNwipe = """
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
