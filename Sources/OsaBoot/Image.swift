import Foundation

// L'image choisie. Deux familles :
// - les images « hybrides » (Linux, Raspberry Pi, outils…) : déjà prêtes, on les copie octet
//   par octet, comme balenaEtcher ;
// - les ISO Windows : elles ne démarrent pas copiées telles quelles. On prépare une clé FAT32
//   (lisible par tous les PC en UEFI), on y copie les fichiers, et install.wim, souvent plus
//   gros que les 4 Go permis par FAT32, est découpé en morceaux que Windows sait relire.
struct SourceImage: Equatable {
    enum Kind: Equatable {
        case raw(bootable: Bool)
        case windows(WindowsInfo)
    }
    struct WindowsInfo: Equatable {
        let label: String
        let install: String         // « install.wim » ou « install.esd »
        let installSize: Int64
        let totalSize: Int64        // tous les fichiers de l'ISO
        let arch: String
        var needsSplit: Bool { installSize > SourceImage.splitAt }
    }

    let url: URL
    let size: Int64
    let kind: Kind

    var name: String { url.lastPathComponent }
    var isWindows: Bool { if case .windows = kind { return true }; return false }
    /// Place nécessaire sur la clé.
    var needed: Int64 { if case .windows(let w) = kind { return w.totalSize + 64 << 20 }; return size }

    static let fat32Max: Int64 = 4_294_967_295
    /// Au-delà, install.wim est découpé (tests : OSABOOT_SPLIT_AT abaisse le seuil).
    static let splitAt: Int64 = Int64(ProcessInfo.processInfo.environment["OSABOOT_SPLIT_AT"] ?? "") ?? fat32Max
    static let extensions = ["iso", "img", "raw", "bin"]

    static func inspect(_ url: URL) throws -> SourceImage {
        guard extensions.contains(url.pathExtension.lowercased()) else {
            throw Fail("OsaBoot lit les fichiers .iso, .img, .raw et .bin.")
        }
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size > 0 else { throw Fail("Ce fichier est vide.") }
        let h = try FileHandle(forReadingFrom: url)
        let head = try h.read(upToCount: 0x8010) ?? Data()
        try h.close()
        let at = { (o: Int, n: Int) -> [UInt8] in head.count >= o + n ? Array(head[o..<o + n]) : [] }
        let mbr = at(510, 2) == [0x55, 0xAA]
        let gpt = at(512, 8) == Array("EFI PART".utf8)
        let iso = [Array("CD001".utf8), Array("BEA01".utf8)].contains(at(0x8001, 5))

        if iso, let w = try? windowsInfo(url) { return SourceImage(url: url, size: size, kind: .windows(w)) }
        return SourceImage(url: url, size: size, kind: .raw(bootable: mbr || gpt))
    }

    /// Monte l'ISO un instant pour voir si c'est un installateur Windows.
    private static func windowsInfo(_ url: URL) throws -> WindowsInfo? {
        let iso = try MountedISO(url)
        defer { iso.detach() }
        let fm = FileManager.default
        let root = iso.mountPoint
        let sources = root.appendingPathComponent("sources")
        guard fm.fileExists(atPath: sources.appendingPathComponent("boot.wim").path) else { return nil }
        guard let install = ["install.wim", "install.esd"].first(where: { fm.fileExists(atPath: sources.appendingPathComponent($0).path) }) else { return nil }
        let installSize = (try? sources.appendingPathComponent(install).resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        let efi = root.appendingPathComponent("efi/boot")
        let arch = fm.fileExists(atPath: efi.appendingPathComponent("bootaa64.efi").path) ? "ARM64"
            : fm.fileExists(atPath: efi.appendingPathComponent("bootx64.efi").path) ? "x64" : "?"
        var total: Int64 = 0
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let f as URL in e {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
            }
        }
        return WindowsInfo(label: root.lastPathComponent, install: install, installSize: installSize, totalSize: total, arch: arch)
    }
}

/// Une ISO montée en lecture seule, invisible dans le Finder.
final class MountedISO {
    let mountPoint: URL
    private let device: String
    private var attached = true

    init(_ url: URL) throws {
        let d = try Shell.plist("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-plist", url.path])
        let entities = d["system-entities"] as? [[String: Any]] ?? []
        guard let mp = entities.compactMap({ $0["mount-point"] as? String }).first,
              let dev = entities.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count }) else {
            throw Fail("Impossible d'ouvrir l'ISO.")
        }
        mountPoint = URL(fileURLWithPath: mp)
        device = dev
    }

    func detach() {
        guard attached else { return }
        attached = false
        if (try? Shell.run("/usr/bin/hdiutil", ["detach", device]))?.status != 0 {
            _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-force", device])
        }
    }

    deinit { detach() }
}
