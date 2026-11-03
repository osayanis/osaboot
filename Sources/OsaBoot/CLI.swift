import Foundation

enum CLI {
    /// nil : ce n'est pas une commande, on lance l'interface.
    static func run(_ a: [String]) -> Int32? {
        switch a.first {
        case "inspect":
            guard a.count == 2 else { return usage() }
            do {
                let img = try SourceImage.inspect(URL(fileURLWithPath: a[1]))
                switch img.kind {
                case .raw(let b): print("brute · \(img.size.bytes) · \(b ? "table de partitions trouvée" : "sans table de partitions")")
                case .windows(let w): print("Windows \(w.arch) · \(w.label) · \(w.install) \(w.installSize.bytes)\(w.needsSplit ? " (à découper)" : "") · \(w.totalSize.bytes) au total")
                }
                return 0
            } catch { print("erreur : \(error.localizedDescription)"); return 1 }

        case "drives":
            let list = DriveList.scan()
            if list.isEmpty { print("aucune clé") }
            for d in list { print("\(d.id)\t\(d.name)\t\(d.size.bytes)\t\(d.bus)\t\(d.volumes.joined(separator: ", "))\(d.writable ? "" : "\tprotégée")") }
            return 0

        case "flash":
            let flags = Set(a.filter { $0.hasPrefix("--") })
            let pos = a.filter { !$0.hasPrefix("--") }
            guard pos.count == 3 else { return usage() }
            let id = pos[2].replacingOccurrences(of: "/dev/", with: "")
            guard DriveList.testDisks.contains(id) else {
                print("refusé : en ligne de commande, seules les images disque de OSABOOT_TEST_DISKS sont permises.")
                return 2
            }
            do {
                let img = try SourceImage.inspect(URL(fileURLWithPath: pos[1]))
                guard let drive = DriveList.info(id) else { print("disque introuvable ou refusé : \(id)"); return 1 }
                var o = FlashOptions()
                o.verify = !flags.contains("--no-verify")
                o.bypassChecks = flags.contains("--bypass-checks")
                o.eject = !flags.contains("--no-eject")
                let e = Engine(image: img, drive: drive, options: o)
                var last = ""
                e.onReport = { r in
                    let line = "\(r.stage) \(r.total > 0 ? Int(Double(r.done) * 100 / Double(r.total)) : 0) %"
                    if line != last { print(line); fflush(stdout); last = line }
                }
                print(try e.run())
                return 0
            } catch { print("erreur : \(error.localizedDescription)"); return 1 }

        case "erasekey-image":
            // prépare l'image de l'EraseKEY dans un dossier, sans rien écrire sur un disque
            guard a.count >= 2 else { return usage() }
            return wait {
                let r = try await EraseKey.fetch { p in print("Téléchargement \(Int(p * 100)) %", terminator: "\r"); fflush(stdout) }
                let out = try EraseKey.customize(r.url, keyboard: a.contains("--qwerty") ? "us" : "fr", into: URL(fileURLWithPath: a[1]))
                print("\nShredOS \(r.version) adapté : \(out.path)")
            }

        case "erasekey":
            let pos = a.filter { !$0.hasPrefix("--") }
            guard pos.count == 2 else { return usage() }
            let id = pos[1].replacingOccurrences(of: "/dev/", with: "")
            guard DriveList.testDisks.contains(id) else {
                print("refusé : en ligne de commande, seules les images disque de OSABOOT_TEST_DISKS sont permises.")
                return 2
            }
            return wait {
                let r = try await EraseKey.fetch { _ in }
                var img = try SourceImage.inspect(r.url)
                img.eraseKey = r.version
                guard let drive = DriveList.info(id) else { throw Fail("disque introuvable ou refusé : \(id)") }
                var o = FlashOptions()
                o.verify = !a.contains("--no-verify")
                o.eject = false
                o.keyboard = a.contains("--qwerty") ? "us" : "fr"
                let e = Engine(image: img, drive: drive, options: o)
                var last = ""
                e.onReport = { r in
                    let line = "\(r.stage) \(r.total > 0 ? Int(Double(r.done) * 100 / Double(r.total)) : 0) %"
                    if line != last { print(line); fflush(stdout); last = line }
                }
                print(try e.run())
            }

        case "icon":
            guard a.count == 2 else { return usage() }
            do { try MainActor.assumeIsolated { try AppIconView.export(to: URL(fileURLWithPath: a[1])) }; return 0 }
            catch { print("erreur : \(error.localizedDescription)"); return 1 }

        default:
            return nil
        }
    }

    /// Attend une tâche asynchrone sans bloquer la boucle principale (URLSession en a besoin).
    private static func wait(_ work: @escaping () async throws -> Void) -> Int32 {
        var status: Int32?
        Task.detached {
            do { try await work(); status = 0 } catch { print("\nerreur : \(error.localizedDescription)"); status = 1 }
        }
        while status == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return status!
    }

    private static func usage() -> Int32 {
        print("usage : OsaBoot inspect <image> | drives | flash <image> <diskN> [--no-verify] [--bypass-checks] | erasekey <diskN> [--qwerty] | erasekey-image <dossier> [--qwerty]")
        return 64
    }
}
