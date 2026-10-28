import Foundation
import DiskArbitration

// Les clés (et disques externes) sur lesquelles on a le droit d'écrire. Jamais un disque
// interne, jamais le disque qui fait démarrer le Mac, jamais une image disque montée
// (sauf en mode test, et seulement celles nommées dans OSABOOT_TEST_DISKS).
struct Drive: Identifiable, Hashable {
    let id: String              // « disk4 »
    let name: String
    let size: Int64
    let bus: String
    let volumes: [String]
    let writable: Bool
    let virtual: Bool

    var node: String { "/dev/\(id)" }
    var rawNode: String { "/dev/r\(id)" }
    /// Au-delà, ce n'est probablement pas une clé : on prévient avant d'effacer.
    var large: Bool { size > 128_000_000_000 }
}

final class DriveList: ObservableObject {
    @Published private(set) var drives: [Drive] = []
    private var session: DASession?
    private var pending: DispatchWorkItem?

    /// Mode test : images disque autorisées, par nom exact (« disk14,disk15 »).
    static let testDisks: Set<String> = Set((ProcessInfo.processInfo.environment["OSABOOT_TEST_DISKS"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })

    init() {
        // DiskArbitration prévient quand une clé arrive ou part : on relit la liste.
        if let s = DASessionCreate(kCFAllocatorDefault) {
            session = s
            DASessionScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            DARegisterDiskAppearedCallback(s, nil, { _, c in Unmanaged<DriveList>.fromOpaque(c!).takeUnretainedValue().scheduleRefresh() }, ctx)
            DARegisterDiskDisappearedCallback(s, nil, { _, c in Unmanaged<DriveList>.fromOpaque(c!).takeUnretainedValue().scheduleRefresh() }, ctx)
        }
        refresh()
    }

    func scheduleRefresh() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Self.scan()
            DispatchQueue.main.async { if list != self.drives { self.drives = list } }
        }
    }

    static func scan() -> [Drive] {
        let external = (try? Shell.plist("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"]))?["WholeDisks"] as? [String] ?? []
        let boot = bootDisks()
        var seen = Set<String>()
        return (external + testDisks.sorted()).filter { seen.insert($0).inserted }.compactMap { info($0, boot: boot) }
    }

    /// Le disque relu à l'instant (nil s'il n'est plus là ou plus autorisé).
    static func info(_ id: String, boot: Set<String>? = nil) -> Drive? {
        guard let d = try? Shell.plist("/usr/sbin/diskutil", ["info", "-plist", id]),
              d["WholeDisk"] as? Bool == true,
              d["Internal"] as? Bool != true,
              !(boot ?? bootDisks()).contains(id) else { return nil }
        let virtual = (d["VirtualOrPhysical"] as? String) == "Virtual" || (d["BusProtocol"] as? String) == "Disk Image"
        if virtual && !testDisks.contains(id) { return nil }
        var name = (d["MediaName"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "Disk Image" && !virtual {
            name = (d["IORegistryEntryName"] as? String ?? "Clé USB").replacingOccurrences(of: " Media", with: "")
        }
        return Drive(id: id, name: name.isEmpty ? "Clé USB" : name,
                     size: (d["TotalSize"] as? NSNumber)?.int64Value ?? (d["Size"] as? NSNumber)?.int64Value ?? 0,
                     bus: d["BusProtocol"] as? String ?? "",
                     volumes: volumes(of: id),
                     writable: d["WritableMedia"] as? Bool ?? d["Writable"] as? Bool ?? true,
                     virtual: virtual)
    }

    /// Noms des volumes de la clé, pour qu'on la reconnaisse (« SANDISK », « Ubuntu 24.04 »…).
    static func volumes(of id: String) -> [String] {
        guard let d = try? Shell.plist("/usr/sbin/diskutil", ["list", "-plist", id]),
              let all = d["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        var names: [String] = []
        for disk in all {
            for p in (disk["Partitions"] as? [[String: Any]] ?? []) + (disk["APFSVolumes"] as? [[String: Any]] ?? []) {
                if let n = p["VolumeName"] as? String, !n.isEmpty, n != "EFI" { names.append(n) }
            }
        }
        return names
    }

    /// Disques physiques sous le volume de démarrage (APFS : ses « physical stores »).
    static func bootDisks() -> Set<String> {
        var out = Set<String>()
        guard let root = try? Shell.plist("/usr/sbin/diskutil", ["info", "-plist", "/"]) else { return ["disk0", "disk1", "disk3"] }
        if let p = root["ParentWholeDisk"] as? String { out.insert(p) }
        for store in root["APFSPhysicalStores"] as? [[String: Any]] ?? [] {
            if let s = store["APFSPhysicalStore"] as? String, let d = try? Shell.plist("/usr/sbin/diskutil", ["info", "-plist", s]),
               let p = d["ParentWholeDisk"] as? String { out.insert(p) }
        }
        return out
    }

    /// Juste avant d'effacer : c'est toujours la même clé (les numéros changent quand on
    /// débranche et rebranche) ?
    static func confirm(_ drive: Drive) throws {
        guard let now = info(drive.id), now.size == drive.size, now.name == drive.name else {
            throw Fail("La clé « \(drive.name) » a changé ou a été débranchée. Choisis-la de nouveau.")
        }
        guard now.writable else { throw Fail("La clé « \(drive.name) » est protégée en écriture.") }
    }
}
