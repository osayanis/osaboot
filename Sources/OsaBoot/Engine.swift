import Foundation
import CryptoKit
import Darwin

struct FlashOptions {
    var verify = true
    /// Windows 11 sur un PC sans TPM 2.0, sans Secure Boot ou avec peu de RAM.
    var bypassChecks = false
    var eject = true
}

/// Où en est l'écriture : étape, octets faits sur le total.
struct Report { var stage: String; var done: Int64; var total: Int64 }

// Le travail lui-même, sur un fil d'arrière-plan. Ne touche jamais à l'interface.
final class Engine {
    let image: SourceImage
    let drive: Drive
    let options: FlashOptions
    var onReport: (Report) -> Void = { _ in }

    private let lock = NSLock()
    private var _cancelled = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    private func check() throws { if cancelled { throw Fail("Annulé.") } }

    init(image: SourceImage, drive: Drive, options: FlashOptions) {
        self.image = image; self.drive = drive; self.options = options
    }

    /// Lance tout, et renvoie la phrase à afficher à la fin.
    func run() throws -> String {
        try DriveList.confirm(drive)
        guard drive.size >= image.needed else {
            throw Fail("La clé est trop petite : il faut \(image.needed.bytes), elle fait \(drive.size.bytes).")
        }
        switch image.kind {
        case .raw: try flashRaw()
        case .windows(let w): try flashWindows(w)
        }
        if options.eject {
            onReport(Report(stage: "Éjection", done: 1, total: 1))
            _ = try? Shell.run("/usr/sbin/diskutil", ["eject", drive.node])
        }
        return image.isWindows
            ? "Branche la clé sur le PC, allume-le et choisis-la au démarrage (F12, F11, F8 ou Échap selon la marque)."
            : "Tu peux débrancher la clé : elle est prête à démarrer."
    }

    // MARK: Copie brute

    private static let chunk = 4 << 20

    private func flashRaw() throws {
        onReport(Report(stage: "Préparation", done: 0, total: image.size))
        let un = try Shell.run("/usr/sbin/diskutil", ["unmountDisk", "force", drive.node])
        guard un.status == 0 else { throw Fail("Impossible de démonter la clé : \(un.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        let fd = try RawDisk.open(drive.rawNode)
        defer { Darwin.close(fd) }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Self.chunk, alignment: 4096)
        defer { buf.deallocate() }

        // écriture, en calculant l'empreinte de l'image au passage
        let src = try FileHandle(forReadingFrom: image.url)
        defer { try? src.close() }
        var hasher = SHA256()
        var offset: Int64 = 0
        while true {
            try check()
            let data = try autoreleasepool { try src.read(upToCount: Self.chunk) ?? Data() }
            if data.isEmpty { break }
            hasher.update(data: data)
            data.copyBytes(to: buf.assumingMemoryBound(to: UInt8.self), count: data.count)
            // un disque brut ne s'écrit que par blocs entiers : on complète la fin avec des zéros
            let len = (data.count + 4095) / 4096 * 4096
            if len > data.count { memset(buf + data.count, 0, len - data.count) }
            try writeAll(fd, buf, len, at: offset)
            offset += Int64(data.count)
            onReport(Report(stage: "Écriture", done: offset, total: image.size))
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw Fail("La clé n'a pas confirmé l'écriture.") }
        let expected = hasher.finalize()

        guard options.verify else { return }
        var readBack = SHA256()
        var pos: Int64 = 0
        while pos < image.size {
            try check()
            let want = Int(min(Int64(Self.chunk), image.size - pos))
            let len = (want + 4095) / 4096 * 4096
            var got = 0
            while got < len {
                let n = pread(fd, buf + got, len - got, off_t(pos) + off_t(got))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Fail("Lecture de la clé impossible pendant la vérification.") }
                got += n
            }
            readBack.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: want))
            pos += Int64(want)
            onReport(Report(stage: "Vérification", done: pos, total: image.size))
        }
        guard readBack.finalize() == expected else {
            throw Fail("La vérification a échoué : la clé ne contient pas exactement l'image. Elle est peut-être abîmée ou contrefaite.")
        }
    }

    private func writeAll(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ len: Int, at offset: Int64) throws {
        var done = 0
        while done < len {
            let n = pwrite(fd, buf + done, len - done, off_t(offset) + off_t(done))
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw Fail("Écriture impossible sur la clé (\(String(cString: strerror(errno)))).") }
            done += n
        }
    }

    // MARK: ISO Windows

    private func flashWindows(_ w: SourceImage.WindowsInfo) throws {
        let wimlib = Tools.wimlib()
        if w.needsSplit && wimlib == nil {
            throw Fail("Le fichier \(w.install) de cette ISO dépasse 4 Go et doit être découpé, mais l'outil wimlib est introuvable.")
        }
        onReport(Report(stage: "Ouverture de l'ISO", done: 0, total: w.totalSize))
        let iso = try MountedISO(image.url)
        defer { iso.detach() }

        // 1. la clé : une seule partition FAT32, table MBR (démarre en UEFI sur tous les PC)
        try check()
        onReport(Report(stage: "Formatage de la clé", done: 0, total: w.totalSize))
        var r = try Shell.run("/usr/sbin/diskutil", ["eraseDisk", "MS-DOS", "OSABOOT", "MBR", drive.node])
        if r.status != 0 { r = try Shell.runAsAdmin("/usr/sbin/diskutil", ["eraseDisk", "MS-DOS", "OSABOOT", "MBR", drive.node]) }
        guard r.status == 0 else { throw Fail("Le formatage de la clé a échoué : \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        let dest = try mountPoint(of: "\(drive.id)s1")
        // Spotlight n'indexe pas la clé (sinon il y laisse un dossier .Spotlight-V100)
        _ = try? Shell.run("/usr/bin/mdutil", ["-i", "off", dest.path])

        // 2. les fichiers, sauf install.wim s'il est trop gros
        let fm = FileManager.default
        let root = iso.mountPoint
        let big = root.appendingPathComponent("sources/\(w.install)")
        var done: Int64 = 0
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else {
            throw Fail("Impossible de lire l'ISO.")
        }
        for case let f as URL in e {
            try check()
            let rel = String(f.path.dropFirst(root.path.count + 1))
            let to = dest.appendingPathComponent(rel)
            let v = try f.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if v.isDirectory == true { try fm.createDirectory(at: to, withIntermediateDirectories: true); continue }
            guard v.isRegularFile == true else { continue }
            if w.needsSplit && f.standardizedFileURL == big.standardizedFileURL { continue }
            let size = Int64(v.fileSize ?? 0)
            guard size <= SourceImage.fat32Max else { throw Fail("« \(rel) » dépasse 4 Go : impossible en FAT32.") }
            try copy(f, to: to) { n in
                done += n
                self.onReport(Report(stage: "Copie des fichiers", done: done, total: w.totalSize))
            }
            let copied = (try? to.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
            guard copied == size else { throw Fail("« \(rel) » n'a pas été copié entièrement.") }
        }

        // 3. install.wim découpé en install.swm, install2.swm… (Windows les réunit tout seul)
        if w.needsSplit, let wimlib {
            try check()
            let base = done
            onReport(Report(stage: "Découpage de \(w.install)", done: base, total: w.totalSize))
            let regex = try NSRegularExpression(pattern: #"\((\d+)%\)"#)
            let r = try Shell.run(wimlib, ["split", big.path, dest.appendingPathComponent("sources/install.swm").path, SourceImage.splitAt < SourceImage.fat32Max ? "\(max(1, SourceImage.splitAt >> 20))" : "3800"]) { line in
                let ns = line as NSString
                if let m = regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).last,
                   let pct = Double(ns.substring(with: m.range(at: 1))) {
                    self.onReport(Report(stage: "Découpage de \(w.install)", done: base + Int64(Double(w.installSize) * pct / 100), total: w.totalSize))
                }
            }
            guard r.status == 0 else { throw Fail("Le découpage de \(w.install) a échoué : \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
            done = base + w.installSize
        }

        // 4. Windows 11 sans TPM / Secure Boot / 4 Go de RAM
        if options.bypassChecks {
            try Unattend.bypassChecks.write(to: dest.appendingPathComponent("autounattend.xml"), atomically: true, encoding: .utf8)
        }

        // macOS range ses métadonnées dans des fichiers « ._ » sur les clés FAT32 : inutiles sur PC
        onReport(Report(stage: "Finalisation", done: w.totalSize, total: w.totalSize))
        _ = try? Shell.run("/usr/sbin/dot_clean", ["-m", dest.path])
        for junk in [".fseventsd", ".Spotlight-V100", ".Trashes"] { try? fm.removeItem(at: dest.appendingPathComponent(junk)) }
        sync()
    }

    /// Point de montage d'une partition, en attendant que macOS la monte après le formatage.
    private func mountPoint(of id: String) throws -> URL {
        for attempt in 0..<20 {
            if let d = try? Shell.plist("/usr/sbin/diskutil", ["info", "-plist", id]),
               let mp = d["MountPoint"] as? String, !mp.isEmpty { return URL(fileURLWithPath: mp) }
            if attempt == 4 { _ = try? Shell.run("/usr/sbin/diskutil", ["mount", id]) }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw Fail("La clé formatée n'est pas apparue.")
    }

    private func copy(_ from: URL, to: URL, progress: (Int64) -> Void) throws {
        let input = try FileHandle(forReadingFrom: from)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: to.path, contents: nil)
        let output = try FileHandle(forWritingTo: to)
        defer { try? output.close() }
        while true {
            try check()
            let data = try autoreleasepool { try input.read(upToCount: 8 << 20) ?? Data() }
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            progress(Int64(data.count))
        }
    }
}

enum Tools {
    /// wimlib-imagex : fourni dans l'app, sinon celui de Homebrew.
    static func wimlib() -> String? {
        let candidates: [String?] = [Bundle.main.resourceURL?.appendingPathComponent("wimlib-imagex").path,
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("wimlib-imagex").path,
                          "/opt/homebrew/bin/wimlib-imagex", "/usr/local/bin/wimlib-imagex"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
