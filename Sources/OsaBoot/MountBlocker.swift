import DiskArbitration
import Foundation

/// Empêche macOS de monter les volumes d'une clé tant qu'on écrit dessus.
/// Sans ça, macOS peut monter la partition à moitié écrite et y écrire ses propres fichiers
/// (.fseventsd, réparation du FAT…) en plein milieu de la copie.
final class MountBlocker {
    private let session: DASession
    private let queue = DispatchQueue(label: "com.osalabs.osaboot.mountblocker")
    let bsdName: String

    private static let refuse: DADiskMountApprovalCallback = { disk, context in
        guard let context, let raw = DADiskGetBSDName(disk) else { return nil }
        let name = String(cString: raw)
        let me = Unmanaged<MountBlocker>.fromOpaque(context).takeUnretainedValue()
        // la clé elle-même (diskN) et ses partitions (diskNsM)
        guard name == me.bsdName || name.hasPrefix(me.bsdName + "s") else { return nil }
        return Unmanaged.passRetained(DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnBusy), "OsaBoot écrit sur cette clé" as CFString))
    }

    init?(_ bsdName: String) {
        guard let s = DASessionCreate(kCFAllocatorDefault) else { return nil }
        session = s
        self.bsdName = bsdName
        DASessionSetDispatchQueue(session, queue)
        DARegisterDiskMountApprovalCallback(session, nil, Self.refuse, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        DAUnregisterCallback(session, unsafeBitCast(Self.refuse, to: UnsafeMutableRawPointer.self), Unmanaged.passUnretained(self).toOpaque())
        queue.sync {}
        DASessionSetDispatchQueue(session, nil)
    }
}
